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
  The PDF report: one section per account with its latest reading, the
  last day's time in range, mean, variability, GMI, extremes and gaps
  (computed by Trndi's own trndi.report, so both programs report the same
  figures), a chart of the readings against the account's own limits, and
  an hourly table. Something to hand to a clinic, which is what a caregiver
  at a wall display is often asked for and what the wall itself cannot give.

  The day's history is fetched on a worker thread through each account's
  existing backend (a second login would revoke a CareLink token), so the
  window starts a report only while no fetch is running and holds its own
  polling until the report is done. The pages are laid out here and written
  by FPC's own fcl-pdf, with DejaVu Sans (vendored in src/fonts, embedded
  as a subset) so the same glyphs, trend arrows included, come out on every
  platform.
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
      carrying its sentinels when unset), so the layout needs no api. }
  TReportSection = record
    acct: TReportAccount;
    connected: boolean;     //< The backend answered; false: no thresholds
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

{** Lay out the report for the sections and write it to @param(fileName).
    Needs no window; exposed for testing. }
procedure WriteReportPdf(const sections: TReportSections; u: BGUnit;
  const fromT, toT: TDateTime; const fileName: string);

implementation

uses
Math, DateUtils, base64, LCLType, fppdf, fpparsettf, fpimage, fpreadpng,
trndi.report, trndimulti.state, trndimulti.branding, trndimulti.buildinfo,
trndimulti.tile;

const
  // Dexcom Share's hard cap on one history request.
  DEXCOM_MAX_COUNT = 288;

  // A4 portrait in points, with the margins the HTML report had.
  PAGE_W = 595;
  PAGE_H = 842;
  MARGIN = 40;
  CONTENT_W = PAGE_W - 2 * MARGIN;

  // The palette the HTML had, as fcl-pdf wants it ($RRGGBB).
  INK = $1F2328;
  GREY = $666666;
  LIGHT_GREY = $888888;
  RULE = $DDDDDD;
  CELL_RULE = $CCCCCC;
  CELL_HEAD = $F2F2F2;
  BAR_BG = $EEEEEE;
  AMBER = $9A6B00;
  TARGET_INK = $1B5E20;
  BAND_RANGE = $E8F5E9;
  BAND_TARGET = $C8E6C9;
  CHART_LINE = $333333;
  TICK_RULE = $DDDDDD;

  // Resource names of the embedded fonts (see TrndiMulti.lpi, Resources).
  FONT_REGULAR = 'DEJAVUSANS';
  FONT_BOLD = 'DEJAVUSANS_BOLD';

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

  {** The pages as they are written: a cursor down an A4 page that starts
      the next one when a block does not fit, text measured with the
      embedded fonts' own metrics, and the few shapes the report draws.
      Coordinates are points from the page's top-left corner. }
  TSheet = class
  private
    FDoc: TPDFDocument;
    FSection: TPDFSection;
    FPage: TPDFPage;
    FRegular, FBold: integer;             // fcl-pdf font indices
    FMetrics: array[boolean] of TTFFileInfo; // by bold, for measuring
    FFontFiles: array[boolean] of string;    // the embedded fonts on disk
    FLogo: integer;                       // image index, or -1
    FY: double;
    procedure NewPage;
    procedure AddFont(bold: boolean; const resource, name: string);
    function Metrics(bold: boolean): TTFFileInfo;
  public
    constructor Create(const title: string);
    destructor Destroy; override;
    procedure SaveToFile(const fileName: string);
    {** Where the next block goes, from the top of the page. }
    property Cur: double read FY write FY;
    {** Start a new page unless @param(h) points still fit on this one. }
    procedure Need(h: double);
    function TextWidth(const s: string; size: double; bold: boolean): double;
    {** Height of a line of @param(size) text, with the report's leading. }
    function LineHeight(size: double): double;
    {** Draw @param(s) with its top at @param(y). }
    procedure Text(x, y: double; const s: string; size: double; bold: boolean;
      colour: TARGBColor = INK);
    {** Draw @param(s) ending at @param(xRight). }
    procedure TextRight(xRight, y: double; const s: string; size: double;
      bold: boolean; colour: TARGBColor = INK);
    {** @param(s) wrapped to @param(w) points, drawn from the cursor and
        the cursor moved past it, page breaks included. }
    procedure Paragraph(const s: string; size: double; bold: boolean;
      colour: TARGBColor = INK; w: double = CONTENT_W; x: double = MARGIN);
    procedure FillRect(x, y, w, h: double; colour: TARGBColor);
    procedure StrokeRect(x, y, w, h: double; colour: TARGBColor; width: double = 1);
    procedure RoundRect(x, y, w, h, r: double; colour: TARGBColor);
    procedure Line(x1, y1, x2, y2: double; colour: TARGBColor; width: double = 1;
      dashed: boolean = false);
    procedure PolyLine(const pts: array of TPDFCoord; colour: TARGBColor; width: double);
    procedure Dot(x, y, r: double; colour: TARGBColor);
    {** The program's logo, @param(size) points square, or nothing when the
        binary's icon could not be read. }
    procedure Logo(x, y, size: double);
    function HasLogo: boolean;
  end;

var
  // The report in flight, or nil, and the last one finished, awaiting
  // Free: a thread cannot free itself from inside Synchronize. Main
  // thread only.
  Running: TReportThread = nil;
  Ended: TReportThread = nil;
  // Set by AbandonReport: the result has nowhere to go.
  Abandoned: boolean = false;

{------------------------------------------------------------------------------
  Formatting
 ------------------------------------------------------------------------------}

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

function Pick(cond: boolean; a, b: TARGBColor): TARGBColor;
begin
  if cond then
    Result := a
  else
    Result := b;
end;

// '#RRGGBB', as trndimulti.tile hands the range palette out, as a colour.
function CssToArgb(const css: string): TARGBColor;
begin
  Result := StrToIntDef('$' + Copy(css, 2, 6), 0);
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

function HasTarget(const s: TReportSection): boolean;
begin
  Result := (s.top <> TrndiAPI.CGM_RANGE_HI_DISABLED) or
    (s.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED);
end;

{------------------------------------------------------------------------------
  Statistics
 ------------------------------------------------------------------------------}

// The copied thresholds as Trndi's report wants them, in mg/dL. A target
// with one side unset runs to the clinical limit on that side, as the
// chart shades it.
function LimitsOf(const s: TReportSection): TTrndiReportLimits;
var
  topV, bottomV: integer;
begin
  topV := s.top;
  if topV = TrndiAPI.CGM_RANGE_HI_DISABLED then
    topV := s.hi;
  bottomV := s.bottom;
  if bottomV = TrndiAPI.CGM_RANGE_LO_DISABLED then
    bottomV := s.lo;
  Result := TrndiMakeReportLimits(s.lo, s.hi, bottomV, topV, HasTarget(s));
end;

// Trndi's report counts a reading on a limit as inside it, where the tile
// (getLevel) counts it as past it. The history is measured the report's
// way throughout, so the chart, the table and the figures agree.
function BandLevel(v: double; const limits: TTrndiReportLimits): BGValLevel;
begin
  case TrndiReportBandOf(v, limits) of
    rbLow: Result := BGLOW;
    rbBelowRange: Result := BGRangeLO;
    rbAboveRange: Result := BGRangeHI;
    rbHigh: Result := BGHigh;
  else
    Result := BGRange;
  end;
end;

// The statistics over the day, in mg/dL like everything else here.
function Compute(const s: TReportSection; const toT: TDateTime): TTrndiReportStats;
begin
  Result := TrndiBuildReport(s.history, mgdl, LimitsOf(s), REPORT_HOURS * 60, toT);
end;

{------------------------------------------------------------------------------
  The sheet
 ------------------------------------------------------------------------------}

// fcl-pdf's font subsetter reads the font back from a file, so the
// embedded font is written out for the report's duration and the ruler
// reads the same file.
procedure TSheet.AddFont(bold: boolean; const resource, name: string);
var
  rs: TResourceStream;
  fs: TFileStream;
  idx: integer;
begin
  // GetTempFileName picks the first unused '.tmp' name, which is the same
  // one twice when neither file is ever made: name the two apart.
  if bold then
    FFontFiles[bold] := GetTempFileName(GetTempDir(false), 'trndi-multi-bold') + '.ttf'
  else
    FFontFiles[bold] := GetTempFileName(GetTempDir(false), 'trndi-multi-regular') + '.ttf';
  rs := TResourceStream.Create(HInstance, resource, RT_RCDATA);
  try
    if rs.Size < 1024 then
      raise Exception.CreateFmt('Font resource %s is %d bytes', [resource, rs.Size]);
    fs := TFileStream.Create(FFontFiles[bold], fmCreate);
    try
      fs.CopyFrom(rs, rs.Size);
      if fs.Size <> rs.Size then
        raise Exception.CreateFmt('Font file %s is %d of %d bytes',
          [FFontFiles[bold], fs.Size, rs.Size]);
    finally
      fs.Free;
    end;
  finally
    rs.Free;
  end;
  idx := FDoc.AddFont(FFontFiles[bold], name);
  if bold then
    FBold := idx
  else
    FRegular := idx;
  FMetrics[bold] := TTFFileInfo.Create;
  FMetrics[bold].LoadFromFile(FFontFiles[bold]);
end;

constructor TSheet.Create(const title: string);
var
  png: TMemoryStream;
  raw: string;
begin
  inherited Create;
  FLogo := -1;
  FDoc := TPDFDocument.Create(nil);
  FDoc.Infos.Title := title;
  FDoc.Infos.Author := 'trndi-multi';
  FDoc.Infos.Producer := 'trndi-multi (fcl-pdf)';
  FDoc.Infos.CreationDate := Now;
  FDoc.Options := [poPageOriginAtTop, poSubsetFont, poCompressText,
    poCompressFonts, poCompressImages, poUseImageTransparency, poMetadataEntry];
  FDoc.DefaultPaperType := ptA4;
  FDoc.DefaultOrientation := ppoPortrait;
  FDoc.DefaultUnitOfMeasure := uomPixels;
  FDoc.StartDocument;
  FSection := FDoc.Sections.AddSection;

  // The fonts, once for the writer and once for the ruler: fcl-pdf keeps
  // its parsed copy to itself.
  AddFont(false, FONT_REGULAR, 'DejaVuSans');
  AddFont(true, FONT_BOLD, 'DejaVuSans-Bold');

  // The program's own mark on its paperwork, out of the binary's icon
  // (see trndimulti.branding); a build whose icon could not be read
  // simply has the heading without it.
  raw := LogoDataUri;
  if Pos('base64,', raw) > 0 then
  begin
    raw := DecodeStringBase64(Copy(raw, Pos('base64,', raw) + 7, MaxInt));
    png := TMemoryStream.Create;
    try
      png.WriteBuffer(raw[1], Length(raw));
      png.Position := 0;
      try
        FLogo := FDoc.Images.AddFromStream(png, TFPReaderPNG, false);
      except
        FLogo := -1;
      end;
    finally
      png.Free;
    end;
  end;
  NewPage;
end;

destructor TSheet.Destroy;
begin
  FMetrics[false].Free;
  FMetrics[true].Free;
  FDoc.Free;
  if FFontFiles[false] <> '' then
    DeleteFile(FFontFiles[false]);
  if FFontFiles[true] <> '' then
    DeleteFile(FFontFiles[true]);
  inherited Destroy;
end;

procedure TSheet.SaveToFile(const fileName: string);
begin
  FDoc.SaveToFile(fileName);
end;

procedure TSheet.NewPage;
begin
  FPage := FDoc.Pages.AddPage;
  FPage.PaperType := ptA4;
  FPage.Orientation := ppoPortrait;
  FPage.UnitOfMeasure := uomPixels;
  FSection.AddPage(FPage);
  FY := MARGIN;
end;

procedure TSheet.Need(h: double);
begin
  if FY + h > PAGE_H - MARGIN then
    NewPage;
end;

function TSheet.Metrics(bold: boolean): TTFFileInfo;
begin
  Result := FMetrics[bold];
end;

function TSheet.TextWidth(const s: string; size: double; bold: boolean): double;
var
  us: UnicodeString;
  i, w: integer;
  m: TTFFileInfo;
begin
  m := Metrics(bold);
  us := UTF8Decode(s);
  w := 0;
  for i := 1 to Length(us) do
    w := w + m.GetAdvanceWidth(m.GetGlyphIndex(Word(us[i])));
  Result := w * size / m.Head.UnitsPerEm;
end;

function TSheet.LineHeight(size: double): double;
begin
  Result := size * 1.35;
end;

procedure TSheet.Text(x, y: double; const s: string; size: double;
  bold: boolean; colour: TARGBColor);
var
  m: TTFFileInfo;
  ascent: double;
begin
  if s = '' then
    exit;
  m := Metrics(bold);
  // WriteText places the baseline; the caller thinks in line tops.
  ascent := m.Ascender * size / m.Head.UnitsPerEm;
  if bold then
    FPage.SetFont(FBold, size)
  else
    FPage.SetFont(FRegular, size);
  FPage.SetColor(colour, false);
  FPage.WriteText(x, y + (LineHeight(size) - size) / 2 + ascent, s);
end;

procedure TSheet.TextRight(xRight, y: double; const s: string; size: double;
  bold: boolean; colour: TARGBColor);
begin
  Text(xRight - TextWidth(s, size, bold), y, s, size, bold, colour);
end;

procedure TSheet.Paragraph(const s: string; size: double; bold: boolean;
  colour: TARGBColor; w: double; x: double);
var
  words: array of string;
  i, p: integer;
  rest, ln, trial: string;

  procedure Flush;
  begin
    if ln = '' then
      exit;
    Need(LineHeight(size));
    Text(x, FY, ln, size, bold, colour);
    FY := FY + LineHeight(size);
    ln := '';
  end;

begin
  words := nil;
  rest := s;
  while rest <> '' do
  begin
    p := Pos(' ', rest);
    if p = 0 then
      p := Length(rest) + 1;
    SetLength(words, Length(words) + 1);
    words[High(words)] := Copy(rest, 1, p - 1);
    Delete(rest, 1, p);
  end;
  ln := '';
  for i := 0 to High(words) do
  begin
    if ln = '' then
      trial := words[i]
    else
      trial := ln + ' ' + words[i];
    if (ln <> '') and (TextWidth(trial, size, bold) > w) then
    begin
      Flush;
      ln := words[i];
    end
    else
      ln := trial;
  end;
  Flush;
end;

procedure TSheet.FillRect(x, y, w, h: double; colour: TARGBColor);
begin
  FPage.SetColor(colour, false);
  // fcl-pdf's rectangles are given by their bottom-left corner.
  FPage.DrawRect(x, y + h, w, h, 0, true, false);
end;

procedure TSheet.StrokeRect(x, y, w, h: double; colour: TARGBColor; width: double);
begin
  FPage.SetColor(colour, true);
  FPage.SetPenStyle(ppsSolid, width);
  FPage.DrawRect(x, y + h, w, h, width, false, true);
end;

procedure TSheet.RoundRect(x, y, w, h, r: double; colour: TARGBColor);
begin
  FPage.SetColor(colour, false);
  FPage.SetColor(colour, true);
  FPage.SetPenStyle(ppsSolid, 0.1);
  FPage.DrawRoundedRect(x, y + h, w, h, r, 0.1, true, false);
end;

procedure TSheet.Line(x1, y1, x2, y2: double; colour: TARGBColor;
  width: double; dashed: boolean);
begin
  FPage.SetColor(colour, true);
  if dashed then
    FPage.SetPenStyle(ppsDash, width)
  else
    FPage.SetPenStyle(ppsSolid, width);
  FPage.DrawLine(x1, y1, x2, y2, width);
  FPage.SetPenStyle(ppsSolid, 1);
end;

procedure TSheet.PolyLine(const pts: array of TPDFCoord; colour: TARGBColor;
  width: double);
begin
  if Length(pts) < 2 then
    exit;
  FPage.SetColor(colour, true);
  FPage.SetPenStyle(ppsSolid, width);
  FPage.SetLineJoinStyle(pljsRoundJoin);
  // DrawPolyLine only builds the path; without the stroke the next fill
  // would paint the whole of it.
  FPage.DrawPolyLine(pts, width);
  FPage.StrokePath;
end;

procedure TSheet.Dot(x, y, r: double; colour: TARGBColor);
begin
  FPage.SetColor(colour, false);
  FPage.SetColor(colour, true);
  FPage.DrawEllipse(x - r, y + r, 2 * r, 2 * r, 0.1, true, false);
end;

function TSheet.HasLogo: boolean;
begin
  Result := FLogo >= 0;
end;

procedure TSheet.Logo(x, y, size: double);
begin
  if FLogo < 0 then
    exit;
  FPage.DrawImage(x, y + size, size, size, FLogo);
end;

{------------------------------------------------------------------------------
  The chart
 ------------------------------------------------------------------------------}

// The day's readings: the in-range band and the personal target band
// shaded, the limits as dashed lines, a line through the readings broken
// where the data has a gap, and a dot per reading in its range colour.
// Time runs left to right across the whole window, so a sensor that was
// off for hours shows as empty space.
procedure Chart(sh: TSheet; const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime);
const
  W = CONTENT_W;
  HT = 164;
  PAD_L = 38;
  PAD_R = 8;
  PAD_T = 8;
  PAD_B = 20;
  FONT = 8;
var
  lo, hi, v: double;
  i, gapMin, n: integer;
  x0, y0: double;
  t, tick: TDateTime;
  topV, bottomV: integer;
  limits: TTrndiReportLimits;
  pts: array of TPDFCoord;

  function XOf(const at: TDateTime): double;
  begin
    Result := x0 + PAD_L + (at - fromT) / (toT - fromT) * (W - PAD_L - PAD_R);
  end;

  function YOf(val: double): double;
  begin
    Result := y0 + HT - PAD_B - (val - lo) / (hi - lo) * (HT - PAD_T - PAD_B);
  end;

  procedure HLine(val: double; colour: TARGBColor);
  begin
    sh.Line(x0 + PAD_L, YOf(val), x0 + W - PAD_R, YOf(val), colour, 0.8, true);
    sh.TextRight(x0 + PAD_L - 3, YOf(val) - sh.LineHeight(FONT) / 2,
      FmtV(val, u), FONT, false, colour);
  end;

  procedure FlushLine;
  begin
    if n >= 2 then
      sh.PolyLine(Copy(pts, 0, n), CHART_LINE, 1.2);
    n := 0;
  end;

begin
  sh.Need(HT + 10);
  sh.Cur := sh.Cur + 10;
  x0 := MARGIN;
  y0 := sh.Cur;

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

  sh.FillRect(x0 + PAD_L, y0 + PAD_T, W - PAD_L - PAD_R, HT - PAD_T - PAD_B, $FFFFFF);
  sh.FillRect(x0 + PAD_L, YOf(s.hi), W - PAD_L - PAD_R, YOf(s.lo) - YOf(s.hi), BAND_RANGE);
  if HasTarget(s) then
  begin
    topV := s.top;
    if topV = TrndiAPI.CGM_RANGE_HI_DISABLED then
      topV := s.hi;
    bottomV := s.bottom;
    if bottomV = TrndiAPI.CGM_RANGE_LO_DISABLED then
      bottomV := s.lo;
    sh.FillRect(x0 + PAD_L, YOf(topV), W - PAD_L - PAD_R, YOf(bottomV) - YOf(topV), BAND_TARGET);
  end;

  // Hour marks every three hours from the first whole hour in the window.
  tick := IncHour(RecodeTime(fromT, HourOf(fromT), 0, 0, 0), 1);
  while tick < toT do
  begin
    if HourOf(tick) mod 3 = 0 then
    begin
      sh.Line(XOf(tick), y0 + PAD_T, XOf(tick), y0 + HT - PAD_B, TICK_RULE, 0.8);
      sh.Text(XOf(tick) - sh.TextWidth(Clock(tick), FONT, false) / 2,
        y0 + HT - PAD_B + 3, Clock(tick), FONT, false, GREY);
    end;
    tick := IncHour(tick, 1);
  end;
  sh.StrokeRect(x0 + PAD_L, y0 + PAD_T, W - PAD_L - PAD_R, HT - PAD_T - PAD_B, CELL_RULE, 0.8);
  HLine(s.hi, CssToArgb(CSS_HIGH));
  HLine(s.lo, CssToArgb(CSS_LOW));

  // The line, broken at gaps of more than three intervals, then the dots
  // on top of it.
  limits := LimitsOf(s);
  gapMin := 3 * Max(1, s.interval);
  SetLength(pts, Length(s.history));
  n := 0;
  for i := 0 to High(s.history) do
  begin
    t := s.history[i].date;
    v := s.history[i].convert(mgdl);
    if (i > 0) and (MinutesBetween(t, s.history[i - 1].date) > gapMin) then
      FlushLine;
    pts[n].X := XOf(t);
    pts[n].Y := YOf(v);
    Inc(n);
  end;
  FlushLine;
  for i := 0 to High(s.history) do
  begin
    v := s.history[i].convert(mgdl);
    sh.Dot(XOf(s.history[i].date), YOf(v), 1.7, CssToArgb(LevelCss(BandLevel(v, limits))));
  end;
  if Length(s.history) = 0 then
    sh.Text(x0 + PAD_L + (W - PAD_L - PAD_R - sh.TextWidth('No readings in this period', 10, false)) / 2,
      y0 + HT / 2 - 6, 'No readings in this period', 10, false, LIGHT_GREY);
  sh.Cur := y0 + HT;
end;

{------------------------------------------------------------------------------
  The tables
 ------------------------------------------------------------------------------}

type
  TCell = record
    text: string;
    left: boolean;      //< Aligned left; numbers go right
    bold: boolean;
    colour: TARGBColor;
  end;
  TRow = array of TCell;

function Cell(const text: string; left: boolean = false; bold: boolean = false;
  colour: TARGBColor = INK): TCell;
begin
  Result.text := text;
  Result.left := left;
  Result.bold := bold;
  Result.colour := colour;
end;

// A ruled table in 9pt: the header row shaded, each row on one line, the
// header repeated when a page break falls inside. Columns are in points
// and add up to at most the content width; the last one takes the rest
// when @param(widths) is one short.
procedure Table(sh: TSheet; const widths: array of double; const head: TRow;
  const rows: array of TRow);
const
  SIZE = 9;
  PAD_X = 6;
  PAD_Y = 2;
var
  rowH, total: double;
  i: integer;
  cols: array of double;
  hasHead: boolean;

  procedure DrawRow(const r: TRow; shaded: boolean);
  var
    c: integer;
    cx: double;
  begin
    if shaded then
      sh.FillRect(MARGIN, sh.Cur, total, rowH, CELL_HEAD);
    cx := MARGIN;
    for c := 0 to High(cols) do
    begin
      sh.StrokeRect(cx, sh.Cur, cols[c], rowH, CELL_RULE, 0.6);
      if c <= High(r) then
      begin
        if r[c].left then
          sh.Text(cx + PAD_X, sh.Cur + PAD_Y, r[c].text, SIZE, r[c].bold or shaded, r[c].colour)
        else
          sh.TextRight(cx + cols[c] - PAD_X, sh.Cur + PAD_Y, r[c].text, SIZE,
            r[c].bold or shaded, r[c].colour);
      end;
      cx := cx + cols[c];
    end;
    sh.Cur := sh.Cur + rowH;
  end;

begin
  rowH := sh.LineHeight(SIZE) + 2 * PAD_Y;
  SetLength(cols, Max(Length(widths), Length(head)));
  total := 0;
  for i := 0 to High(widths) do
  begin
    cols[i] := widths[i];
    total := total + widths[i];
  end;
  if Length(widths) < Length(cols) then
  begin
    cols[High(cols)] := CONTENT_W - total;
    total := CONTENT_W;
  end;
  // A table whose header says nothing (the key-value one) has no header row.
  hasHead := false;
  for i := 0 to High(head) do
    hasHead := hasHead or (head[i].text <> '');
  sh.Cur := sh.Cur + 8;
  sh.Need(2 * rowH);
  if hasHead then
    DrawRow(head, true);
  for i := 0 to High(rows) do
  begin
    if sh.Cur + rowH > PAGE_H - MARGIN then
    begin
      sh.NewPage;
      if hasHead then
        DrawRow(head, true);
    end;
    DrawRow(rows[i], false);
  end;
end;

// The 24 one-hour buckets: how many readings, their mean and extremes, and
// how many were past the clinical limits, so a night's dip can be found by
// hour.
procedure HourlyTable(sh: TSheet; const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime);
var
  bucket, bucketEnd: TDateTime;
  i, n, nLow, nHigh: integer;
  v, sum, minV, maxV: double;
  limits: TTrndiReportLimits;
  rows: array of TRow;
  r: TRow;
begin
  limits := LimitsOf(s);
  rows := nil;
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
      case TrndiReportBandOf(v, limits) of
        rbHigh: Inc(nHigh);
        rbLow: Inc(nLow);
      end;
      Inc(i);
    end;
    SetLength(r, 7);
    r[0] := Cell(Clock(bucket) + '–' + Clock(bucketEnd), true);
    if n = 0 then
    begin
      r[1] := Cell('–');
      r[2] := Cell('–');
      r[3] := Cell('–');
      r[4] := Cell('–');
      r[5] := Cell('–');
      r[6] := Cell('–');
    end
    else
    begin
      r[1] := Cell(IntToStr(n));
      r[2] := Cell(FmtV(sum / n, u));
      r[3] := Cell(FmtV(minV, u));
      r[4] := Cell(FmtV(maxV, u));
      r[5] := Cell(IntToStr(nLow), false, nLow > 0, Pick(nLow > 0, CssToArgb(CSS_LOW), INK));
      r[6] := Cell(IntToStr(nHigh), false, nHigh > 0, Pick(nHigh > 0, CssToArgb(CSS_HIGH), INK));
    end;
    SetLength(rows, Length(rows) + 1);
    rows[High(rows)] := r;
    bucket := bucketEnd;
  end;
  Table(sh, [86, 60, 60, 60, 60, 44, 44],
    [Cell('Hour', true), Cell('Readings'), Cell('Mean'), Cell('Lowest'),
    Cell('Highest'), Cell('Low'), Cell('High')], rows);
end;

{------------------------------------------------------------------------------
  The sections
 ------------------------------------------------------------------------------}

// The change since the reading before, signed and with the unit. A backend
// that fetched one reading at a time leaves the delta empty (Dexcom Share
// does, and BG_NO_VAL formats as a nonsense figure); the report has the
// day's history, so the change is taken from there when its newest reading
// is the current one. With nothing to count from, the unit stands alone,
// as the tile and the detail view show it.
function DeltaText(const s: TReportSection; u: BGUnit): string;
var
  n: integer;
  r: BGReading;
begin
  if not s.acct.current.deltaEmpty then
    Exit(s.acct.current.format(u, BG_MSG_SIGNED, BGDelta));
  n := Length(s.history);
  if (n >= 2) and (MinutesBetween(s.history[n - 1].date, s.acct.current.date) < 1) then
  begin
    // Through a reading of its own, so the sign and the decimals come out
    // exactly as the tile formats them.
    r.Init(mgdl, 'report');
    r.update(s.history[n - 1].convert(mgdl),
      s.history[n - 1].convert(mgdl) - s.history[n - 2].convert(mgdl), mgdl);
    Exit(r.format(u, BG_MSG_SIGNED, BGDelta));
  end;
  Result := BG_UNIT_NAMES[u];
end;

procedure Section(sh: TSheet; const s: TReportSection; u: BGUnit;
  const fromT, toT: TDateTime);
const
  BODY = 10.5;
var
  st: TTrndiReportStats;
  cur: BGReading;
  v, x, w, barW: double;
  low, inRange, high: integer;
  meta, target, gap, val, note: string;
  kv: array of TRow;
begin
  st := Compute(s, toT);
  low := st.bands[rbLow];
  high := st.bands[rbHigh];
  inRange := st.count - low - high;

  // The rule, the name and the reading stay on one page with the day's
  // figures; a heading alone at the foot of a page says nothing.
  if st.valid then
    sh.Need(270)
  else
    sh.Need(90);
  sh.Cur := sh.Cur + 20;
  sh.Line(MARGIN, sh.Cur, MARGIN + CONTENT_W, sh.Cur, RULE, 1.5);
  sh.Cur := sh.Cur + 6;
  sh.Text(MARGIN, sh.Cur, AccountLabel(s.acct.info), 15, true);
  sh.Cur := sh.Cur + sh.LineHeight(15) + 2;
  // The thresholds are the backend's; an account that never connected
  // has none to show.
  if s.connected then
    meta := s.system + ' · limits ' + FmtV(s.lo, u) + '–' + FmtV(s.hi, u) +
      ' ' + BG_UNIT_NAMES[u]
  else
    meta := 'Not connected';
  if s.connected and HasTarget(s) then
  begin
    target := '';
    if s.bottom <> TrndiAPI.CGM_RANGE_LO_DISABLED then
      target := FmtV(s.bottom, u);
    target := target + '–';
    if s.top <> TrndiAPI.CGM_RANGE_HI_DISABLED then
      target := target + FmtV(s.top, u);
    meta := meta + ' · personal target ' + target;
  end;
  sh.Paragraph(meta, 9, false, GREY);
  sh.Cur := sh.Cur + 8;

  // The latest reading, as the tile shows it: the value on its range
  // colour, the change beside it, and when it was.
  x := MARGIN;
  if s.acct.haveCurrent then
  begin
    cur := s.acct.current;
    v := cur.convert(mgdl);
    val := FmtV(v, u) + ' ' + BG_TREND_ARROWS_UTF[cur.trend];
    w := sh.TextWidth(val, 22, true) + 16;
    sh.RoundRect(x, sh.Cur, w, sh.LineHeight(22) + 2, 4, CssToArgb(LevelCss(LevelOf(v, s))));
    sh.Text(x + 8, sh.Cur + 1, val, 22, true, $FFFFFF);
    x := x + w + 10;
    sh.Text(x, sh.Cur + 9, DeltaText(s, u), 13, false);
    x := x + sh.TextWidth(DeltaText(s, u), 13, false) + 10;
    sh.Text(x, sh.Cur + 11, 'at ' + Stamp(cur.date), BODY, false, GREY);
    x := x + sh.TextWidth('at ' + Stamp(cur.date), BODY, false) + 10;
    if s.acct.stale or (MinutesBetween(Now, cur.date) > 2 * Max(1, s.interval) + 5) then
    begin
      note := 'last known, ' + FormatAge(MinutesBetween(Now, cur.date)) + ' old';
      sh.Text(x, sh.Cur + 11, note, BODY, false, AMBER);
    end;
    sh.Cur := sh.Cur + sh.LineHeight(22) + 2;
  end
  else
  begin
    w := sh.TextWidth('–', 22, true) + 16;
    sh.RoundRect(x, sh.Cur, w, sh.LineHeight(22) + 2, 4, CssToArgb(CSS_NONE));
    sh.Text(x + 8, sh.Cur + 1, '–', 22, true, $FFFFFF);
    note := 'No reading';
    if s.acct.err <> '' then
      note := note + ': ' + s.acct.err;
    sh.Cur := sh.Cur + 11;
    sh.Paragraph(note, BODY, false, GREY, CONTENT_W - w - 10, x + w + 10);
    sh.Cur := sh.Cur + sh.LineHeight(22) + 2 - 11 - sh.LineHeight(BODY);
  end;
  sh.Cur := sh.Cur + 8;

  if s.fetchErr <> '' then
  begin
    sh.Paragraph('The day''s history could not be fetched: ' + s.fetchErr,
      BODY, false, CssToArgb(CSS_HIGH));
    sh.Cur := sh.Cur + 4;
  end;

  // The day in numbers: the time-in-range bar and its shares, then the
  // figures as a two-column table.
  if st.valid then
  begin
    sh.Need(60);
    sh.FillRect(MARGIN, sh.Cur, CONTENT_W, 10, BAR_BG);
    x := MARGIN;
    if low > 0 then
    begin
      barW := CONTENT_W * low / st.count;
      sh.FillRect(x, sh.Cur, barW, 10, CssToArgb(CSS_LOW));
      x := x + barW;
    end;
    if inRange > 0 then
    begin
      barW := CONTENT_W * inRange / st.count;
      sh.FillRect(x, sh.Cur, barW, 10, CssToArgb(CSS_RANGE));
      x := x + barW;
    end;
    if high > 0 then
    begin
      barW := CONTENT_W * high / st.count;
      sh.FillRect(x, sh.Cur, barW, 10, CssToArgb(CSS_HIGH));
    end;
    sh.Cur := sh.Cur + 14;
    x := MARGIN;
    sh.Text(x, sh.Cur, 'Low ' + Pct(low, st.count), BODY, true, CssToArgb(CSS_LOW));
    x := x + sh.TextWidth('Low ' + Pct(low, st.count), BODY, true) + 14;
    sh.Text(x, sh.Cur, 'In range ' + Pct(inRange, st.count), BODY, true, CssToArgb(CSS_RANGE));
    x := x + sh.TextWidth('In range ' + Pct(inRange, st.count), BODY, true) + 14;
    sh.Text(x, sh.Cur, 'High ' + Pct(high, st.count), BODY, true, CssToArgb(CSS_HIGH));
    x := x + sh.TextWidth('High ' + Pct(high, st.count), BODY, true) + 14;
    if st.limits.hasRange then
      sh.Text(x, sh.Cur, 'In personal target ' + Pct(st.bands[rbInRange], st.count),
        BODY, true, TARGET_INK);
    sh.Cur := sh.Cur + sh.LineHeight(BODY);

    // The longest gap only says something when it is wider than the
    // sensor's own spacing.
    if st.longestGap > 2 * Max(1, Round(st.cadenceMinutes)) then
      gap := FormatAge(st.longestGap) + ', from ' + Stamp(st.longestGapAt)
    else
      gap := 'none beyond the usual spacing';
    SetLength(kv, 7);
    kv[0] := [Cell('Readings', true), Cell(Format('%d, from %s to %s, about %.0f min apart, covering %.0f%%',
      [st.count, Stamp(st.first), Stamp(st.last), st.cadenceMinutes, st.coverage]), true)];
    kv[1] := [Cell('Mean', true), Cell(Format('%s %s (median %s, SD %s, CV %.0f%%)',
      [FmtV(st.mean, u), BG_UNIT_NAMES[u], FmtV(st.median, u), FmtV(st.sd, u), st.cv]), true)];
    kv[2] := [Cell('GMI', true), Cell(Format('%.1f%% (%.0f mmol/mol)', [st.gmiPercent, st.gmiMmolMol]), true)];
    kv[3] := [Cell('Lowest', true), Cell(FmtV(st.lowest, u) + ' at ' + Stamp(st.lowestAt), true)];
    kv[4] := [Cell('Highest', true), Cell(FmtV(st.highest, u) + ' at ' + Stamp(st.highestAt), true)];
    kv[5] := [Cell('Excursions', true), Cell(Format('%d low, %d high (runs of %d or more readings past the limit)',
      [st.lowExcursions, st.highExcursions, TRNDI_REPORT_EXCURSION_MIN]), true)];
    kv[6] := [Cell('Longest gap', true), Cell(gap, true)];
    Table(sh, [72], [Cell('', true), Cell('', true)], kv);
  end;

  // An account that never connected has no limits to plot against.
  if s.connected then
    Chart(sh, s, u, fromT, toT);
  if st.valid then
    HourlyTable(sh, s, u, fromT, toT);
end;

procedure WriteReportPdf(const sections: TReportSections; u: BGUnit;
  const fromT, toT: TDateTime; const fileName: string);
var
  sh: TSheet;
  i: integer;
  build: string;
  x: double;
begin
  {$PUSH}{$WARN 6018 OFF}
  if BUILD_NUMBER = 'dev' then
    build := 'development build'
  else
    build := 'build ' + BUILD_NUMBER;
  {$POP}
  sh := TSheet.Create('Trndi Multi report');
  try
    x := MARGIN;
    if sh.HasLogo then
    begin
      sh.Logo(MARGIN, sh.Cur, 34);
      x := MARGIN + 34 + 9;
    end;
    sh.Text(x, sh.Cur, 'Trndi Multi report', 20, true);
    sh.Cur := sh.Cur + sh.LineHeight(20) + 2;
    sh.Paragraph('The last ' + IntToStr(REPORT_HOURS) + ' hours, ' + Stamp(fromT) +
      ' to ' + Stamp(toT) + ', in ' + BG_UNIT_NAMES[u] + '. Generated ' + Stamp(toT) +
      ' by trndi-multi (' + build + ').', 9, false, GREY, CONTENT_W - (x - MARGIN), x);
    for i := 0 to High(sections) do
      Section(sh, sections[i], u, fromT, toT);
    sh.Need(60);
    sh.Cur := sh.Cur + 24;
    sh.Line(MARGIN, sh.Cur, MARGIN + CONTENT_W, sh.Cur, RULE, 0.8);
    sh.Cur := sh.Cur + 6;
    sh.Paragraph('Not a medical device. The readings come from each account''s ' +
      'CGM service as trndi-multi received them and may be delayed, incomplete ' +
      'or wrong; verify against the official device and records before acting ' +
      'on anything here. Time in range is the share of readings, not of time, ' +
      'so gaps in the data are not counted. GMI restates the period''s mean on ' +
      'the A1c scale; it is not a laboratory A1c.', 8.5, false, GREY);
    sh.SaveToFile(fileName);
  finally
    sh.Free;
  end;
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
      secs[i].connected := true;
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
    WriteReportPdf(secs, FUnit, fromT, toT, FFileName);
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

end.
