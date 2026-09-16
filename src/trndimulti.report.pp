(*
 * Trndi
 * Medical and Non-Medical Usage Alert
 *
 * Copyright (c) Björn Lindh
 * GitHub: https://github.com/slicke/trndi
 *
 * This program is distributed under the terms of the GNU General Public License,
 * Version 3, as published by the Free Software Foundation. You may redistribute
 * and/or modify the software under the terms of this license.
 *
 * A copy of the GNU General Public License should have been provided with this
 * program. If not, see <http://www.gnu.org/licenses/gpl.html>.
 *
 * ================================== IMPORTANT ==================================
 * MEDICAL DISCLAIMER:
 * - This software is NOT a medical device and must NOT replace official continuous
 *   glucose monitoring (CGM) systems or any healthcare decision-making process.
 * - The data provided may be delayed, inaccurate, or unavailable.
 * - DO NOT make medical decisions based on this software.
 * - VERIFY all data using official devices and consult a healthcare professional for
 *   medical concerns or emergencies.
 *
 * LIABILITY LIMITATION:
 * - The software is provided "AS IS" and without any warranty—expressed or implied.
 * - Users assume all risks associated with its use. The developers disclaim all
 *   liability for any damage, injury, or harm, direct or incidental, arising
 *   from its use.
 *
 * INSTRUCTIONS TO DEVELOPERS & USERS:
 * - Any modifications to this file must include a prominent notice outlining what was
 *   changed and the date of modification (as per GNU GPL Section 5).
 * - Distribution of a modified version must include this header and comply with the
 *   license terms.
 *
 * BY USING THIS SOFTWARE, YOU AGREE TO THE TERMS AND DISCLAIMERS STATED HERE.
 *
 *)


{**
  The PDF report: one page section per account with its latest reading,
  the last day's time in range, mean and extremes, a chart of the readings
  against the account's own limits, and an hourly table. Something to hand
  to a clinic, which is what a caregiver at a wall display is often asked
  for and what the wall itself cannot give.

  The day's history is fetched on a worker thread through each account's
  existing backend (a second login would revoke a CareLink token), so the
  window starts a report only while no fetch is running and holds its own
  polling until the report is done. The HTML is laid out and written by the
  vendored Pixie engine's PDF exporter, which needs no window.
}
unit trndimulti.report;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, trndi.types, trndi.api, trndimulti.accounts;

const
  {** The window the report covers, ending now. Dexcom Share serves at most
      a day, so that is the day every backend is asked for. }
  REPORT_HOURS = 24;

type
  {** What the report needs from one account, copied on the main thread
      before the worker starts. The api is the account's own and is used
      by the worker alone until the report is done. }
  TReportAccount = record
    info: TAccountInfo;
    api: TrndiAPI;          //< nil: never connected; the section says so
    err: string;            //< The last fetch's failure, for that note
    current: BGReading;
    haveCurrent: boolean;
    stale: boolean;
  end;
  TReportAccounts = array of TReportAccount;

  {** One account's share of the report as the worker leaves it. The
      thresholds are copied out of the backend (mg/dL, the range band
      carrying its sentinels when unset), so the HTML needs no api. }
  TReportSection = record
    acct: TReportAccount;
    system: string;
    interval: integer;
    hi, lo, top, bottom: integer;
    history: BGResults;     //< Ascending, within the window
    fetchErr: string;       //< Why the history is missing or short
  end;
  TReportSections = array of TReportSection;

  {** Called on the main thread when the report is written, or not:
      @param(err) is empty on success. }
  TReportDone = procedure(const fileName, err: string) of object;

{** Fetch, lay out and write the report in the background. The caller
    guarantees no fetch runs on any of the accounts' backends until
    @param(onDone) has been called. }
procedure StartReport(const accounts: TReportAccounts; displayUnit: BGUnit;
  const fileName: string; onDone: TReportDone);

{** True while a report is being prepared. }
function ReportRunning: boolean;

{** Wait for a running report to finish and drop its result. Before the
    accounts' backends are freed. }
procedure AbandonReport;

{** The report's HTML for the sections. Pure; exposed for testing. }
function ReportHtml(const sections: TReportSections; u: BGUnit;
  const fromT, toT: TDateTime): string;

implementation

uses
Math, StrUtils, DateUtils, base64, trndimulti.state, trndimulti.buildinfo, Pixie.PdfExport;

const
  // The tile palette, as CSS.
  CSS_RANGE = '#2E7D32';
  CSS_RANGE_HI = '#C99500';
  CSS_RANGE_LO = '#0A6FA8';
  CSS_HIGH = '#C43C1E';
  CSS_LOW = '#B4142C';
  CSS_NONE = '#45454B';
  // Dexcom Share's hard cap on one history request.
  DEXCOM_MAX_COUNT = 288;

type
  TReportThread = class(TThread)
  private
    FAccounts: TReportAccounts;
    FUnit: BGUnit;
    FFileName: string;
    FOnDone: TReportDone;
    FErr: string;
    procedure Done;
  protected
    procedure Execute; override;
  public
    constructor Create(const accounts: TReportAccounts; displayUnit: BGUnit;
      const fileName: string; onDone: TReportDone);
  end;

  TStats = record
    n, low, inRange, high, aboveTarget, belowTarget: integer;
    mean, sd, minV, maxV: double;
    minAt, maxAt: TDateTime;
  end;

var
  // The report in flight, or nil, and the last one finished, awaiting
  // Free: a thread cannot free itself from inside Synchronize. Main
  // thread only.
  Running: TReportThread = nil;
  Ended: TReportThread = nil;
  // Set by AbandonReport: the result has nowhere to go.
  Abandoned: boolean = false;
  // SVG coordinates and CSS need a dot whatever the locale.
  Dot: TFormatSettings;

{------------------------------------------------------------------------------
  Formatting
 ------------------------------------------------------------------------------}

function H(const s: string): string;
begin
  Result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
end;

// mg/dL to the display unit.
function ToUnit(mgdlV: double; u: BGUnit): double;
begin
  Result := mgdlV * BG_CONVERTIONS[u][mgdl];
end;

// A value as the wall shows it: one decimal for mmol/L, none for mg/dL.
function FmtV(mgdlV: double; u: BGUnit): string;
begin
  Result := Format(BG_MSG_SHORT[u], [ToUnit(mgdlV, u)]);
end;

function Pt(v: double): string;
begin
  Result := FloatToStrF(v, ffFixed, 10, 1, Dot);
end;

function Pct(part, total: integer): string;
begin
  if total = 0 then
    Result := '–'
  else
    Result := Format('%.0f%%', [100 * part / total]);
end;

function Stamp(const dt: TDateTime): string;
begin
  Result := FormatDateTime('yyyy-mm-dd hh:nn', dt);
end;

function Clock(const dt: TDateTime): string;
begin
  Result := FormatDateTime('hh:nn', dt);
end;

// TrndiAPI.getLevel, on the copied thresholds.
function LevelOf(v: double; const s: TReportSection): BGValLevel;
begin
  if v >= s.hi then
    Result := BGHigh
  else if v <= s.lo then
    Result := BGLOW
  else if (s.top <> TrndiAPI.CGM_RANGE_HI_DISABLED) and (v >= s.top) then
    Result := BGRangeHI
  else if (s.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED) and (v <= s.bottom) then
    Result := BGRangeLO
  else
    Result := BGRange;
end;

function LevelCss(lvl: BGValLevel): string;
begin
  case lvl of
    BGHigh: Result := CSS_HIGH;
    BGLOW: Result := CSS_LOW;
    BGRangeHI: Result := CSS_RANGE_HI;
    BGRangeLO: Result := CSS_RANGE_LO;
  else
    Result := CSS_RANGE;
  end;
end;

function HasTarget(const s: TReportSection): boolean;
begin
  Result := (s.top <> TrndiAPI.CGM_RANGE_HI_DISABLED) or
    (s.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED);
end;

{------------------------------------------------------------------------------
  Statistics
 ------------------------------------------------------------------------------}

function Compute(const s: TReportSection): TStats;
var
  i: integer;
  v, sum, sq: double;
begin
  Result := Default(TStats);
  sum := 0;
  sq := 0;
  for i := 0 to High(s.history) do
  begin
    v := s.history[i].convert(mgdl);
    if (Result.n = 0) or (v < Result.minV) then
    begin
      Result.minV := v;
      Result.minAt := s.history[i].date;
    end;
    if (Result.n = 0) or (v > Result.maxV) then
    begin
      Result.maxV := v;
      Result.maxAt := s.history[i].date;
    end;
    Inc(Result.n);
    sum := sum + v;
    sq := sq + v * v;
    case LevelOf(v, s) of
      BGHigh: Inc(Result.high);
      BGLOW: Inc(Result.low);
      BGRangeHI:
      begin
        Inc(Result.inRange);
        Inc(Result.aboveTarget);
      end;
      BGRangeLO:
      begin
        Inc(Result.inRange);
        Inc(Result.belowTarget);
      end;
    else
      Inc(Result.inRange);
    end;
  end;
  if Result.n > 0 then
  begin
    Result.mean := sum / Result.n;
    Result.sd := Sqrt(Max(0, sq / Result.n - Result.mean * Result.mean));
  end;
end;

{------------------------------------------------------------------------------
  The chart
 ------------------------------------------------------------------------------}

// The day's readings as an SVG: the in-range band and the personal target
// band shaded, the limits as dashed lines, a line through the readings
// broken where the data has a gap, and a dot per reading in its range
// colour. Time runs left to right across the whole window, so a sensor
// that was off for hours shows as empty space.
function ChartSvg(const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime): string;
const
  W = 660;
  HT = 210;
  PAD_L = 46;
  PAD_R = 10;
  PAD_T = 10;
  PAD_B = 24;
var
  lo, hi, v: double;
  i, gapMin: integer;
  x, y: double;
  t, tick: TDateTime;
  pts, dots, bands: string;
  topV, bottomV: integer;

  function XOf(const at: TDateTime): double;
  begin
    Result := PAD_L + (at - fromT) / (toT - fromT) * (W - PAD_L - PAD_R);
  end;

  function YOf(val: double): double;
  begin
    Result := HT - PAD_B - (val - lo) / (hi - lo) * (HT - PAD_T - PAD_B);
  end;

  function HLine(val: double; const colour: string): string;
  begin
    Result := '<line x1="' + IntToStr(PAD_L) + '" y1="' + Pt(YOf(val)) +
      '" x2="' + IntToStr(W - PAD_R) + '" y2="' + Pt(YOf(val)) +
      '" stroke="' + colour + '" stroke-width="1" stroke-dasharray="4 3"/>' +
      '<text x="' + IntToStr(PAD_L - 4) + '" y="' + Pt(YOf(val) + 3.5) +
      '" text-anchor="end" font-size="10" fill="' + colour + '">' +
      H(FmtV(val, u)) + '</text>';
  end;

begin
  // Scale: the account's limits with headroom, widened by the readings.
  lo := s.lo;
  hi := s.hi;
  for i := 0 to High(s.history) do
  begin
    v := s.history[i].convert(mgdl);
    lo := Min(lo, v);
    hi := Max(hi, v);
  end;
  lo := Max(0, lo - 18);
  hi := hi + 18;
  if hi - lo < 1 then
    hi := lo + 1;

  bands := '<rect x="' + IntToStr(PAD_L) + '" y="' + Pt(YOf(s.hi)) +
    '" width="' + IntToStr(W - PAD_L - PAD_R) + '" height="' +
    Pt(YOf(s.lo) - YOf(s.hi)) + '" fill="#E8F5E9"/>';
  if HasTarget(s) then
  begin
    topV := s.top;
    if topV = TrndiAPI.CGM_RANGE_HI_DISABLED then
      topV := s.hi;
    bottomV := s.bottom;
    if bottomV = TrndiAPI.CGM_RANGE_LO_DISABLED then
      bottomV := s.lo;
    bands := bands + '<rect x="' + IntToStr(PAD_L) + '" y="' + Pt(YOf(topV)) +
      '" width="' + IntToStr(W - PAD_L - PAD_R) + '" height="' +
      Pt(YOf(bottomV) - YOf(topV)) + '" fill="#C8E6C9"/>';
  end;

  // Hour marks every three hours from the first whole hour in the window.
  tick := IncHour(RecodeTime(fromT, HourOf(fromT), 0, 0, 0), 1);
  while tick < toT do
  begin
    if HourOf(tick) mod 3 = 0 then
      bands := bands + '<line x1="' + Pt(XOf(tick)) + '" y1="' + IntToStr(PAD_T) +
        '" x2="' + Pt(XOf(tick)) + '" y2="' + IntToStr(HT - PAD_B) +
        '" stroke="#DDDDDD" stroke-width="1"/>' +
        '<text x="' + Pt(XOf(tick)) + '" y="' + IntToStr(HT - PAD_B + 14) +
        '" text-anchor="middle" font-size="10" fill="#666666">' +
        Clock(tick) + '</text>';
    tick := IncHour(tick, 1);
  end;

  // The line, broken at gaps of more than three intervals, and the dots.
  gapMin := 3 * Max(1, s.interval);
  pts := '';
  dots := '';
  for i := 0 to High(s.history) do
  begin
    t := s.history[i].date;
    v := s.history[i].convert(mgdl);
    x := XOf(t);
    y := YOf(v);
    if (i > 0) and (MinutesBetween(t, s.history[i - 1].date) > gapMin) then
    begin
      pts := pts + '"/>';
      pts := pts + '<polyline fill="none" stroke="#333333" stroke-width="1.5" points="';
    end
    else if i = 0 then
      pts := '<polyline fill="none" stroke="#333333" stroke-width="1.5" points="'
    else
      pts := pts + ' ';
    pts := pts + Pt(x) + ',' + Pt(y);
    dots := dots + '<circle cx="' + Pt(x) + '" cy="' + Pt(y) +
      '" r="2.2" fill="' + LevelCss(LevelOf(v, s)) + '"/>';
  end;
  if pts <> '' then
    pts := pts + '"/>';

  Result := '<svg xmlns="http://www.w3.org/2000/svg" width="' + IntToStr(W) +
    '" height="' + IntToStr(HT) + '" viewBox="0 0 ' + IntToStr(W) + ' ' +
    IntToStr(HT) + '">' +
    '<rect x="' + IntToStr(PAD_L) + '" y="' + IntToStr(PAD_T) + '" width="' +
    IntToStr(W - PAD_L - PAD_R) + '" height="' + IntToStr(HT - PAD_T - PAD_B) +
    '" fill="#FFFFFF" stroke="#CCCCCC" stroke-width="1"/>' +
    bands + HLine(s.hi, CSS_HIGH) + HLine(s.lo, CSS_LOW) + pts + dots;
  if Length(s.history) = 0 then
    Result := Result + '<text x="' + IntToStr((W + PAD_L - PAD_R) div 2) +
      '" y="' + IntToStr(HT div 2) + '" text-anchor="middle" font-size="12" ' +
      'fill="#888888">No readings in this period</text>';
  Result := Result + '</svg>';
end;

{------------------------------------------------------------------------------
  The HTML
 ------------------------------------------------------------------------------}

function HourlyTable(const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime): string;
var
  bucket, bucketEnd: TDateTime;
  i, n, nLow, nHigh: integer;
  v, sum, minV, maxV: double;
begin
  Result := '<table><tr><th class="l">Hour</th><th>Readings</th><th>Mean</th>' +
    '<th>Lowest</th><th>Highest</th><th>Low</th><th>High</th></tr>';
  bucket := RecodeTime(fromT, HourOf(fromT), 0, 0, 0);
  i := 0;
  while bucket < toT do
  begin
    bucketEnd := IncHour(bucket, 1);
    n := 0;
    nLow := 0;
    nHigh := 0;
    sum := 0;
    minV := 0;
    maxV := 0;
    while (i <= High(s.history)) and (s.history[i].date < bucketEnd) do
    begin
      v := s.history[i].convert(mgdl);
      if (n = 0) or (v < minV) then
        minV := v;
      if (n = 0) or (v > maxV) then
        maxV := v;
      sum := sum + v;
      Inc(n);
      case LevelOf(v, s) of
        BGHigh: Inc(nHigh);
        BGLOW: Inc(nLow);
      end;
      Inc(i);
    end;
    Result := Result + '<tr><td class="l">' + Clock(bucket) + '–' +
      Clock(bucketEnd) + '</td>';
    if n = 0 then
      Result := Result + '<td>–</td><td>–</td><td>–</td><td>–</td><td>–</td><td>–</td>'
    else
      Result := Result + '<td>' + IntToStr(n) + '</td><td>' + H(FmtV(sum / n, u)) +
        '</td><td>' + H(FmtV(minV, u)) + '</td><td>' + H(FmtV(maxV, u)) +
        '</td><td' + IfThen(nLow > 0, ' class="low"', '') + '>' + IntToStr(nLow) +
        '</td><td' + IfThen(nHigh > 0, ' class="high"', '') + '>' +
        IntToStr(nHigh) + '</td>';
    Result := Result + '</tr>';
    bucket := bucketEnd;
  end;
  Result := Result + '</table>';
end;

function SectionHtml(const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime): string;
var
  st: TStats;
  cur: BGReading;
  v: double;
  note, bar, target, cv: string;
begin
  st := Compute(s);
  cv := '–';
  if st.mean > 0 then
    cv := Format('%.0f%%', [100 * st.sd / st.mean]);
  Result := '<hr><div class="acct"><h2>' + H(AccountLabel(s.acct.info)) + '</h2>' +
    '<div class="meta">';
  // The thresholds are the backend's; an account that never connected
  // has none to show.
  if s.acct.api <> nil then
    Result := Result + H(s.system) + ' · limits ' + H(FmtV(s.lo, u)) +
      '–' + H(FmtV(s.hi, u)) + ' ' + BG_UNIT_NAMES[u]
  else
    Result := Result + 'Not connected';
  if (s.acct.api <> nil) and HasTarget(s) then
  begin
    target := '';
    if s.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED then
      target := H(FmtV(s.bottom, u));
    target := target + '–';
    if s.top <> TrndiAPI.CGM_RANGE_HI_DISABLED then
      target := target + H(FmtV(s.top, u));
    Result := Result + ' · personal target ' + target;
  end;
  Result := Result + '</div>';

  // The latest reading, as the tile shows it.
  if s.acct.haveCurrent then
  begin
    cur := s.acct.current;
    v := cur.convert(mgdl);
    note := '';
    if s.acct.stale or (MinutesBetween(Now, cur.date) > 2 * Max(1, s.interval) + 5) then
      note := ' <span class="stale">last known, ' +
        H(FormatAge(MinutesBetween(Now, cur.date))) + ' old</span>';
    Result := Result + '<div class="now"><span class="val" style="background:' +
      LevelCss(LevelOf(v, s)) + '">' + H(FmtV(v, u)) + ' ' +
      H(BG_TREND_ARROWS_UTF[cur.trend]) + '</span>' +
      '<span class="delta">' + H(cur.format(u, BG_MSG_SIGNED, BGDelta)) +
      '</span><span class="when">at ' + Stamp(cur.date) + '</span>' + note + '</div>';
  end
  else
  begin
    Result := Result + '<div class="now"><span class="val" style="background:' +
      CSS_NONE + '">–</span><span class="when">No reading';
    if s.acct.err <> '' then
      Result := Result + ': ' + H(s.acct.err);
    Result := Result + '</span></div>';
  end;

  if s.fetchErr <> '' then
    Result := Result + '<p class="err">The day''s history could not be fetched: ' +
      H(s.fetchErr) + '</p>';

  // The day in numbers.
  if st.n > 0 then
  begin
    bar := '<div class="bar">';
    if st.low > 0 then
      bar := bar + '<div style="width:' + Pt(100 * st.low / st.n) +
        '%;background:' + CSS_LOW + '"></div>';
    if st.inRange > 0 then
      bar := bar + '<div style="width:' + Pt(100 * st.inRange / st.n) +
        '%;background:' + CSS_RANGE + '"></div>';
    if st.high > 0 then
      bar := bar + '<div style="width:' + Pt(100 * st.high / st.n) +
        '%;background:' + CSS_HIGH + '"></div>';
    bar := bar + '</div>';
    Result := Result + '<div class="stats">' + bar +
      '<div class="tir"><span class="low">Low ' + Pct(st.low, st.n) + '</span>' +
      '<span class="range">In range ' + Pct(st.inRange, st.n) + '</span>' +
      '<span class="high">High ' + Pct(st.high, st.n) + '</span>';
    if HasTarget(s) then
      Result := Result + '<span class="target">In personal target ' +
        Pct(st.inRange - st.aboveTarget - st.belowTarget, st.n) + '</span>';
    Result := Result + '</div>' +
      '<table class="kv">' +
      '<tr><th class="l">Readings</th><td class="l">' + IntToStr(st.n) +
      ', from ' + Stamp(s.history[0].date) + ' to ' +
      Stamp(s.history[High(s.history)].date) + '</td></tr>' +
      '<tr><th class="l">Mean</th><td class="l">' + H(FmtV(st.mean, u)) + ' ' +
      BG_UNIT_NAMES[u] + ' (SD ' + H(FmtV(st.sd, u)) + ', CV ' + cv + ')</td></tr>' +
      '<tr><th class="l">Lowest</th><td class="l">' + H(FmtV(st.minV, u)) +
      ' at ' + Stamp(st.minAt) + '</td></tr>' +
      '<tr><th class="l">Highest</th><td class="l">' + H(FmtV(st.maxV, u)) +
      ' at ' + Stamp(st.maxAt) + '</td></tr>' +
      '</table></div>';
  end;

  // As an image rather than inline: that is the route Pixie's PDF canvas
  // renders SVG through (as a vector form, not a bitmap).
  Result := Result + '<div class="chart"><img src="data:image/svg+xml;base64,' +
    EncodeStringBase64(ChartSvg(s, u, fromT, toT)) + '" width="660" height="210"></div>';
  if st.n > 0 then
    Result := Result + HourlyTable(s, u, fromT, toT);
  Result := Result + '</div>';
end;

function ReportHtml(const sections: TReportSections; u: BGUnit;
  const fromT, toT: TDateTime): string;
const
  CSS =
    'body { font-family: "DejaVu Sans", "Liberation Sans", "Noto Sans", ' +
    '"Segoe UI", Arial, Helvetica, sans-serif; font-size: 10.5pt; ' +
    'color: #1F2328; line-height: 1.35; }' +
    'h1 { font-size: 20pt; margin: 0 0 2pt; }' +
    'h2 { font-size: 15pt; margin: 0 0 2pt; }' +
    '.meta { color: #666666; font-size: 9pt; margin-bottom: 8pt; }' +
    '.acct { margin-top: 6pt; }' +
    'hr { border: 0; border-top: 2px solid #DDDDDD; margin: 20pt 0 0; }' +
    '.now { margin: 6pt 0 8pt; }' +
    '.now span { margin-right: 10pt; }' +
    '.val { display: inline-block; font-size: 22pt; font-weight: bold; ' +
    'color: #FFFFFF; padding: 1pt 8pt; border-radius: 4pt; }' +
    '.delta { font-size: 13pt; }' +
    '.when { color: #666666; }' +
    '.stale { color: #9A6B00; }' +
    '.err { color: ' + CSS_HIGH + '; }' +
    '.bar { display: flex; height: 10pt; width: 100%; border-radius: 3pt; ' +
    'overflow: hidden; background: #EEEEEE; margin-bottom: 4pt; }' +
    '.tir span { margin-right: 14pt; font-weight: bold; }' +
    '.tir .low { color: ' + CSS_LOW + '; } .tir .high { color: ' + CSS_HIGH + '; }' +
    '.tir .range { color: ' + CSS_RANGE + '; } .tir .target { color: #1B5E20; }' +
    'table { border-collapse: collapse; font-size: 9pt; margin-top: 8pt; }' +
    'th, td { border: 1px solid #CCCCCC; padding: 2pt 6pt; text-align: right; }' +
    'th { background: #F2F2F2; font-weight: bold; }' +
    'th.l, td.l { text-align: left; }' +
    'td.low { color: ' + CSS_LOW + '; font-weight: bold; }' +
    'td.high { color: ' + CSS_HIGH + '; font-weight: bold; }' +
    'table.kv th { width: 60pt; }' +
    '.chart { margin-top: 10pt; }' +
    '.foot { margin-top: 24pt; padding-top: 6pt; border-top: 1px solid #DDDDDD; ' +
    'color: #666666; font-size: 8.5pt; }';
var
  i: integer;
  build: string;
begin
  {$PUSH}{$WARN 6018 OFF}
  if BUILD_NUMBER = 'dev' then
    build := 'development build'
  else
    build := 'build ' + BUILD_NUMBER;
  {$POP}
  Result := '<!DOCTYPE html><html><head><meta charset="utf-8">' +
    '<title>Trndi Multi report</title><style>' + CSS + '</style></head><body>' +
    '<h1>Trndi Multi report</h1>' +
    '<div class="meta">The last ' + IntToStr(REPORT_HOURS) + ' hours, ' +
    Stamp(fromT) + ' to ' + Stamp(toT) + ', in ' + BG_UNIT_NAMES[u] +
    '. Generated ' + Stamp(toT) + ' by trndi-multi (' + build + ').</div>';
  for i := 0 to High(sections) do
    Result := Result + SectionHtml(sections[i], u, fromT, toT);
  Result := Result + '<div class="foot">Not a medical device. The readings ' +
    'come from each account''s CGM service as trndi-multi received them and ' +
    'may be delayed, incomplete or wrong; verify against the official device ' +
    'and records before acting on anything here. Time in range is the share ' +
    'of readings, not of time, so gaps in the data are not counted.</div>' +
    '</body></html>';
end;

{------------------------------------------------------------------------------
  The worker
 ------------------------------------------------------------------------------}

// The day's history. Dexcom Share raises past its caps of a day and 288
// readings; every other backend takes what it is asked for, and counts
// from its own cadence with slack for uploads that bunch up. So ask for
// the window, and if that is refused, ask for Dexcom's most.
function FetchHistory(api: TrndiAPI; interval: integer): BGResults;
const
  MINUTES = REPORT_HOURS * 60;
var
  count: integer;
begin
  count := MINUTES div Max(1, interval) + 16;
  if count <= DEXCOM_MAX_COUNT then
    Exit(api.getReadings(MINUTES, count));
  try
    Result := api.getReadings(MINUTES, count);
  except
    Result := api.getReadings(MINUTES, DEXCOM_MAX_COUNT);
  end;
end;

constructor TReportThread.Create(const accounts: TReportAccounts;
  displayUnit: BGUnit; const fileName: string; onDone: TReportDone);
begin
  FAccounts := accounts;
  FUnit := displayUnit;
  FFileName := fileName;
  FOnDone := onDone;
  FreeOnTerminate := false;
  inherited Create(false);
end;

procedure TReportThread.Execute;
var
  fromT, toT: TDateTime;
  secs: TReportSections;
  i: integer;
  api: TrndiAPI;
  pdf: TPixiePdfExport;
  m: TPixiePdfMargins;
begin
  FErr := '';
  try
    toT := Now;
    fromT := IncHour(toT, -REPORT_HOURS);
    secs := nil;
    SetLength(secs, Length(FAccounts));
    for i := 0 to High(FAccounts) do
    begin
      secs[i] := Default(TReportSection);
      secs[i].acct := FAccounts[i];
      api := FAccounts[i].api;
      if api = nil then
      begin
        if FAccounts[i].err <> '' then
          secs[i].fetchErr := FAccounts[i].err
        else
          secs[i].fetchErr := 'Not connected yet.';
        continue;
      end;
      secs[i].system := api.systemName;
      secs[i].interval := Max(1, api.getReportingInterval);
      secs[i].hi := api.cgmHi;
      secs[i].lo := api.cgmLo;
      secs[i].top := api.cgmRangeHi;
      secs[i].bottom := api.cgmRangeLo;
      try
        secs[i].history := FetchHistory(api, secs[i].interval);
      except
        on E: Exception do
          secs[i].fetchErr := E.Message;
      end;
      TidyHistory(secs[i].history, fromT);
      if (Length(secs[i].history) = 0) and (secs[i].fetchErr = '') then
        secs[i].fetchErr := api.errormsg;
      if Terminated then
        exit;
    end;
    pdf := TPixiePdfExport.Create;
    try
      pdf.Title := 'Trndi Multi report';
      pdf.Author := 'trndi-multi';
      m := pdf.Margins;
      m.Top := 40;
      m.Bottom := 40;
      m.Left := 40;
      m.Right := 40;
      pdf.Margins := m;
      pdf.SaveToFile(ReportHtml(secs, FUnit, fromT, toT), FFileName);
    finally
      pdf.Free;
    end;
  except
    on E: Exception do
      FErr := E.Message;
  end;
  if not Terminated then
    Synchronize(@Done);
end;

// Main thread.
procedure TReportThread.Done;
begin
  if Running = Self then
    Running := nil;
  Ended := Self;
  if Assigned(FOnDone) and (not Abandoned) then
    FOnDone(FFileName, FErr);
end;

procedure Reap;
begin
  if Ended <> nil then
  begin
    Ended.WaitFor;
    FreeAndNil(Ended);
  end;
end;

procedure StartReport(const accounts: TReportAccounts; displayUnit: BGUnit;
  const fileName: string; onDone: TReportDone);
begin
  Reap;
  if Running <> nil then
    exit;
  Abandoned := false;
  Running := TReportThread.Create(accounts, displayUnit, fileName, onDone);
end;

function ReportRunning: boolean;
begin
  Result := Running <> nil;
end;

// WaitFor on the main thread keeps servicing Synchronize; Execute checks
// Terminated before calling it and Done checks Abandoned inside it, so the
// callback never reaches a window that is closing. The request itself runs
// to its end or its timeout.
procedure AbandonReport;
begin
  Abandoned := true;
  if Running <> nil then
  begin
    Running.Terminate;
    Running.WaitFor;
    FreeAndNil(Running);
  end;
  Reap;
end;

initialization
  Dot := DefaultFormatSettings;
  Dot.DecimalSeparator := '.';
  Dot.ThousandSeparator := #0;

finalization
  AbandonReport;

end.
