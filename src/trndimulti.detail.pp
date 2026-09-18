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
  One account up close: what the tile shows, plus everything it has no
  room for. Opened by a left click on the tile (not in kiosk mode: the
  pointer is hidden there and nobody would close it).

  A page rendered by the vendored Pixie engine, as the other dialogs are:
  the latest reading with its colour, the account's limits and personal
  target band, how it is polled and when, the backend's full error text
  rather than the tile's abbreviation, and the last hours' readings as a
  table, coloured by range. The page keeps up with the wall while it is
  open: it is rebuilt when a fetch lands and the age line is touched up
  each minute in place, so a scroll position survives.
}
unit trndimulti.detail;

{$mode objfpc}{$H+}

interface

uses
Classes, trndi.types, trndimulti.state;

{** Show @param(state) in a modal window over @param(owner), in the wall's
    display unit @param(u). The state stays owned by the caller, which
    must keep it alive while the window is open (the main window's states
    only go away through its Accounts window, which a modal blocks). }
procedure ShowDetail(owner: TComponent; state: TAccountState; u: BGUnit);

implementation

uses
SysUtils, DateUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics,
trndi.api, trndi.api.registry, trndimulti.accounts, trndimulti.tile,
trndimulti.markdown, Pixie.Document, Pixie.Element;

const
  // How often the page checks the state; the wall's own tick rate.
  TICK_MS = 10000;
  // Text colours for a stale reading's line on the window's background:
  // the report's amber, and the tile's red-orange once the link is likely
  // gone. Not the tile's own stale text colours, which are for white on
  // slate.
  CSS_STALE_LATE = '#9A6B00';
  CSS_STALE_LOST = CSS_HIGH;

type
  TfDetail = class(TForm)
  private
    FState: TAccountState;
    FUnit: BGUnit;
    FPane: TMarkdownPane;
    FTimer: TTimer;
    FSnapshot: TTimer;
    FSig: string;          // What the page was last built from
    FAge: integer;         // The age the page last showed
    function Signature: string;
    function PageHtml: string;
    procedure Rebuild;
    procedure Tick(Sender: TObject);
    procedure SnapshotTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; state: TAccountState;
      u: BGUnit); reintroduce;
  end;

{------------------------------------------------------------------------------
  Formatting
 ------------------------------------------------------------------------------}

function H(const s: string): string;
begin
  Result := StringReplace(s, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

// Error text as the backend gives it: escaped, with its line breaks kept.
function Multiline(const s: string): string;
begin
  Result := StringReplace(H(Trim(s)), #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '<br>', [rfReplaceAll]);
end;

// A threshold, stored in mg/dL, in the display unit.
function FmtV(mgdlV: double; u: BGUnit): string;
begin
  if u = mmol then
    Result := Format('%.1f', [mgdlV / 18.0182])
  else
    Result := IntToStr(Round(mgdlV));
end;

// A difference between two readings in the display unit, signed.
function FmtDelta(d: double; u: BGUnit): string;
begin
  if u = mmol then
    Result := Format('%.1f', [Abs(d)])
  else
    Result := IntToStr(Round(Abs(d)));
  if d < 0 then
    Result := '−' + Result
  else if d > 0 then
    Result := '+' + Result;
end;

function Clock(const dt: TDateTime): string;
begin
  Result := FormatDateTime('hh:nn', dt);
end;

// The account's target as something safe to show: the host of a site
// URL, or the account name or e-mail as it is. Pixie never breaks a long
// unbroken token, so the path and query of a URL stay out of the page.
function TargetLabel(const target: string): string;
var
  p: integer;
begin
  Result := target;
  p := Pos('://', Result);
  if p > 0 then
  begin
    Delete(Result, 1, p + 2);
    p := Pos('/', Result);
    if p > 0 then
      SetLength(Result, p - 1);
  end;
end;

{------------------------------------------------------------------------------
  The page
 ------------------------------------------------------------------------------}

function TfDetail.Signature: string;
begin
  // Everything a rebuild depends on other than the reading's age: a fetch
  // landing (lastFetch), its outcome, and the stale stage, which changes
  // the colour of the age line and so needs more than a text touch-up.
  Result := FloatToStr(FState.lastFetch) + '|' + FState.err + '|' +
    BoolToStr(FState.haveCurrent) + '|' + BoolToStr(FState.Busy) + '|' +
    IntToStr(Ord(FState.StaleStage)) + '|' + IntToStr(Length(FState.history));
end;

// The age line's text, fresh or stale. Updated in place between rebuilds.
function AgeText(s: TAccountState): string;
var
  age: integer;
begin
  age := s.AgeMinutes;
  if s.StaleStage = ssFresh then
  begin
    if age < 1 then
      Result := 'just now'
    else
      Result := FormatAge(age) + ' ago';
  end
  else if age < 1 then
    Result := 'Last known, not current: no new data'
  else
    Result := 'Last known, not current: no data for ' + FormatAge(age);
end;

function TfDetail.PageHtml: string;
var
  api: TrndiAPI;
  cur, r: BGReading;
  i: integer;
  s, loginHint, band, ageClass: string;
  d: double;
begin
  api := FState.api;

  // Who, and where the readings come from.
  s := BackendDisplayName(FState.info.backend);
  if api <> nil then
    s := api.systemName;
  if s = '' then
    s := FState.info.backend;
  Result := '<h1>' + H(AccountLabel(FState.info)) + '</h1>' +
    '<p class="meta">' + H(s);
  if FState.info.target <> '' then
    Result := Result + ' · ' + H(TargetLabel(FState.info.target));
  Result := Result + '</p>';

  // The latest reading, as the tile shows it, and how old it is.
  if FState.haveCurrent then
  begin
    cur := FState.current;
    Result := Result + '<div class="now"><span class="val" style="background:' +
      LevelCss(cur.level) + '">' + H(cur.format(FUnit, BG_MSG_SHORT)) + ' ' +
      H(BG_TREND_ARROWS_UTF[cur.trend]) + '</span>';
    // The signed delta carries the unit; without one, the unit stands alone.
    if not cur.deltaEmpty then
      Result := Result + '<span class="delta">' +
        H(cur.format(FUnit, BG_MSG_SIGNED, BGDelta)) + '</span>'
    else
      Result := Result + '<span class="unit">' + BG_UNIT_NAMES[FUnit] +
        '</span>';
    Result := Result + '</div>';
    case FState.StaleStage of
      ssFresh: ageClass := 'when';
      ssDelayed: ageClass := 'when stale';
      ssLate: ageClass := 'stale late';
    else
      ageClass := 'stale lost';
    end;
    Result := Result + '<p class="' + ageClass + '">Reading from ' +
      Clock(cur.date) + ' · <span id="age">' + H(AgeText(FState)) +
      '</span></p>';
  end
  else
  begin
    Result := Result + '<div class="now"><span class="val" style="background:' +
      CSS_NONE + '">–</span><span class="unit">';
    if FState.Busy and (not FState.everFetched) then
      Result := Result + 'Connecting…'
    else
      Result := Result + 'No reading';
    Result := Result + '</span></div>';
  end;

  // The full error, and the one repair only Trndi can make, said first.
  if FState.err <> '' then
  begin
    loginHint := TrndiLoginHint(FState.info.backend, FState.err);
    Result := Result + '<div class="err">';
    if loginHint <> '' then
      Result := Result + '<p><b>' + H(loginHint) + '</b></p>';
    Result := Result + '<p>' + Multiline(FState.err) + '</p></div>';
  end;

  // How the account is set up and polled.
  Result := Result + '<table class="kv">';
  if api <> nil then
  begin
    band := 'none';
    if (api.cgmRangeLo <> TrndiAPI.CGM_RANGE_LO_DISABLED) or
      (api.cgmRangeHi <> TrndiAPI.CGM_RANGE_HI_DISABLED) then
    begin
      band := '';
      if api.cgmRangeLo <> TrndiAPI.CGM_RANGE_LO_DISABLED then
        band := FmtV(api.cgmRangeLo, FUnit);
      band := band + '–';
      if api.cgmRangeHi <> TrndiAPI.CGM_RANGE_HI_DISABLED then
        band := band + FmtV(api.cgmRangeHi, FUnit);
      band := band + ' ' + BG_UNIT_NAMES[FUnit];
    end;
    Result := Result +
      '<tr><th>Limits</th><td><span class="lo">' + FmtV(api.cgmLo, FUnit) +
      '</span> low · <span class="hi">' + FmtV(api.cgmHi, FUnit) + '</span> high, ' +
      BG_UNIT_NAMES[FUnit] + '</td></tr>' +
      '<tr><th>Personal target</th><td>' + band + '</td></tr>';
  end
  else
    Result := Result + '<tr><th>Connection</th><td>Not connected yet</td></tr>';
  s := 'every ' + IntToStr(FState.IntervalMinutes) + ' min';
  if FState.Busy then
    s := s + ' · fetching now'
  else
  begin
    if FState.lastFetch > 0 then
      s := s + ' · last at ' + Clock(FState.lastFetch);
    if FState.nextDue > Now then
      s := s + ' · next at ' + Clock(FState.nextDue);
  end;
  Result := Result + '<tr><th>Polling</th><td>' + s + '</td></tr></table>';

  // The last hours, newest first, each with its change from the reading
  // before it in time. The level is the backend's own classification, the
  // one the tile colours by.
  Result := Result + '<h2>Last ' + IntToStr(HISTORY_MINUTES div 60) +
    ' hours</h2>';
  if Length(FState.history) = 0 then
    Result := Result + '<p class="meta">No readings.</p>'
  else
  begin
    Result := Result + '<table class="hist"><tr><th class="l">Time</th>' +
      '<th>Value</th><th>Change</th><th>Trend</th></tr>';
    for i := High(FState.history) downto 0 do
    begin
      r := FState.history[i];
      Result := Result + '<tr><td class="l">' + Clock(r.date) + '</td>' +
        '<td class="v" style="color:' + LevelCss(r.level) + '">' +
        H(r.format(FUnit, BG_MSG_SHORT)) + '</td><td>';
      if i > 0 then
      begin
        d := r.convert(FUnit) - FState.history[i - 1].convert(FUnit);
        Result := Result + FmtDelta(d, FUnit);
      end
      else
        Result := Result + '–';
      Result := Result + '</td><td class="t">' +
        H(BG_TREND_ARROWS_UTF[r.trend]) + '</td></tr>';
    end;
    Result := Result + '</table>';
  end;
end;

procedure TfDetail.Rebuild;
begin
  FSig := Signature;
  FAge := FState.AgeMinutes;
  // One raw HTML block: a blank line inside it would end the block and
  // leave the rest as literal text, so the page has no line breaks at all.
  FPane.Load(PageHtml);
end;

procedure TfDetail.Tick(Sender: TObject);
var
  el: TPixieElement;
begin
  if Signature <> FSig then
    Rebuild
  else if (FState.AgeMinutes <> FAge) and (FPane.Document <> nil) then
  begin
    // Only the minutes moved: touch the age line up in place rather than
    // reload, which would throw away the reader's scroll position.
    FAge := FState.AgeMinutes;
    el := FPane.Document.GetElementById('age');
    if el <> nil then
      FPane.Document.SetElementText(el, AgeText(FState));
  end;
end;

{------------------------------------------------------------------------------
  The window
 ------------------------------------------------------------------------------}

constructor TfDetail.Create(AOwner: TComponent; state: TAccountState;
  u: BGUnit);
const
  MARGIN = 12;
var
  btnClose: TButton;
begin
  inherited CreateNew(AOwner, 0);
  FState := state;
  FUnit := u;
  Caption := AccountLabel(state.info);
  Width := 520;
  Height := 620;
  Constraints.MinWidth := 360;
  Constraints.MinHeight := 320;
  if AOwner is TCustomForm then
    Position := poOwnerFormCenter
  else
    Position := poScreenCenter;
  BorderStyle := bsSizeable;

  btnClose := TButton.Create(Self);
  btnClose.Parent := Self;
  btnClose.Caption := 'Close';
  btnClose.Cancel := true;
  btnClose.Default := true;
  btnClose.ModalResult := mrCancel;
  btnClose.AutoSize := true;
  btnClose.Anchors := [akRight, akBottom];
  btnClose.Left := ClientWidth - MARGIN - btnClose.Width;
  btnClose.Top := ClientHeight - MARGIN - btnClose.Height;

  // On the window's own background, as the About window: one surface, not
  // a document. The tables are ruled by faint lines rather than borders.
  FPane := TMarkdownPane.Create(Self);
  FPane.Parent := Self;
  FPane.SetTheme(clBtnFace, clBtnText, 13,
    'h1 { font-size: 1.6em; margin: 0; }' +
    'h2 { font-size: 1.15em; margin: 18px 0 6px; }' +
    '.meta { color: ' + CssColor(clGrayText) + '; margin: 0 0 12px; }' +
    '.now { display: flex; align-items: center; margin: 0 0 6px; }' +
    '.val { font-size: 2em; font-weight: bold; color: #FFFFFF; ' +
    'padding: 2px 12px; border-radius: 6px; margin-right: 12px; }' +
    '.delta { font-size: 1.3em; margin-right: 8px; }' +
    '.unit { color: ' + CssColor(clGrayText) + '; }' +
    '.when { margin: 0 0 12px; }' +
    '.stale { font-weight: bold; margin: 0 0 12px; }' +
    '.late { color: ' + CSS_STALE_LATE + '; }' +
    '.lost { color: ' + CSS_STALE_LOST + '; }' +
    '.err { margin: 0 0 12px; padding: 0 0 0 10px; ' +
    'border-left: 3px solid ' + CSS_HIGH + '; }' +
    '.err p { margin: 0 0 4px; }' +
    'table { border-collapse: collapse; }' +
    'table.kv th { text-align: left; padding: 2px 14px 2px 0; ' +
    'white-space: nowrap; vertical-align: top; }' +
    'table.kv td { padding: 2px 0; }' +
    '.lo { color: ' + CSS_LOW + '; font-weight: bold; }' +
    '.hi { color: ' + CSS_HIGH + '; font-weight: bold; }' +
    'table.hist th, table.hist td { padding: 2px 12px; text-align: right; ' +
    'border-bottom: 1px solid ' + CssColor(clGrayText) + '; }' +
    'table.hist th { font-weight: bold; }' +
    'table.hist th.l, table.hist td.l { text-align: left; padding-left: 0; }' +
    'table.hist td.v { font-weight: bold; }' +
    'table.hist td.t { text-align: center; }');
  FPane.Anchors := [akLeft, akTop, akRight, akBottom];
  FPane.Left := MARGIN;
  FPane.Top := MARGIN;
  FPane.Width := ClientWidth - 2 * MARGIN;
  FPane.Height := btnClose.Top - MARGIN - FPane.Top;
  Rebuild;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := TICK_MS;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := true;

  // Under the snapshot test hook (see umulti) there is nobody to click.
  if GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT') <> '' then
  begin
    FSnapshot := TTimer.Create(Self);
    FSnapshot.Interval := 2000;
    FSnapshot.OnTimer := @SnapshotTick;
    FSnapshot.Enabled := true;
  end;
end;

procedure TfDetail.SnapshotTick(Sender: TObject);
var
  img: TBitmap;
  png: TPortableNetworkGraphic;
begin
  FSnapshot.Enabled := false;
  img := GetFormImage;
  try
    png := TPortableNetworkGraphic.Create;
    try
      png.Assign(img);
      png.SaveToFile(ChangeFileExt(
        GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT'), '.detail.png'));
    finally
      png.Free;
    end;
  finally
    img.Free;
  end;
  ModalResult := mrCancel;
end;

procedure ShowDetail(owner: TComponent; state: TAccountState; u: BGUnit);
var
  f: TfDetail;
begin
  if state = nil then
    exit;
  f := TfDetail.Create(owner, state, u);
  try
    f.ShowModal;
  finally
    f.Free;
  end;
end;

end.
