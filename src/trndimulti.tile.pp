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
  One account's tile: colour by range, the value large, the trend arrow and
  delta, the reading's time and age, and a sparkline of the last hours.

  Everything scales with the tile's height so the same drawing works as a
  small window on a desk and a full-screen wall display.

  A value giving way to the next rolls over as Trndi's main reading does
  (its utabularlabel): the digits that differ slide up out of the line while
  the new ones rise in from below, and the digits shared at either end stand
  still, so 5.4 -> 5.6 turns one wheel and 9.9 -> 10.0 turns them all. Only a
  number changing into a number in the same unit rolls; the first value, a
  unit switch and HIGH/LOW appear in one step.

  The fill fades into a new colour as Trndi's window does, over the same
  700 ms with the same ease-in-out; the first colour, and the first after the
  tile is given another account, appear at once.
}
unit trndimulti.tile;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Controls, Graphics, ExtCtrls, Types, Math, DateUtils, LCLIntf,
LCLType, trndi.types, trndi.api, trndi.raster, trndimulti.accounts, trndimulti.state;

type
  {** A TCustomControl that paints a @link(TAccountState). The state is owned
      by the window, not the tile; a nil state paints an empty tile. }
  TAccountTile = class(TCustomControl)
  private
    FState: TAccountState;
    FUnit: BGUnit;
    FShown: string;         // Value the last paint drew; '' before the first
    FShownUnit: BGUnit;     // Unit FShown is in
    FRollFrom: string;      // Value being rolled away; '' when no roll is running
    FRollStart: QWord;      // GetTickCount64 when the roll began
    FBg: TColor;            // Fill the last paint used
    FBgFrom: TColor;        // Fill a running fade started from
    FBgTarget: TColor;      // Fill the tile is fading to, or showing
    FBgStart: QWord;        // GetTickCount64 when the fade began
    FBgSet: boolean;        // False until a first fill, so that one does not fade
    FBgFading: boolean;
    FAnimTimer: TTimer;     // Frame tick of the roll and the fade; nil until the first
    procedure SetState(AValue: TAccountState);
    procedure AnimTick({%H-}Sender: TObject);
    procedure StartAnim;
    procedure NoteShown(const AValue: string);
    function FillFor(ATarget: TColor): TColor;
    procedure DrawSpark(const r: TRect; bg: TColor);
    procedure DrawText(x, y: integer; const s: string; how: TAlignment;
      w: integer = 0);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property State: TAccountState read FState write SetState;
    property DisplayUnit: BGUnit read FUnit write FUnit;
    {** A left click, for the window to open the account's detail view on;
        the right button goes to PopupMenu as on every control. }
    property OnClick;
  end;

const
  {** The range palette as CSS, for the HTML-rendered detail view and
      report: the same colours the tiles are painted in, so a value reads
      the same on paper as on the wall. }
  CSS_RANGE = '#2E7D32';
  CSS_RANGE_HI = '#C99500';
  CSS_RANGE_LO = '#0A6FA8';
  CSS_HIGH = '#C43C1E';
  CSS_LOW = '#B4142C';
  CSS_NONE = '#45454B';
  {** A stale reading's fill, as the tile turns. }
  CSS_STALE = '#404A5C';

{** Window background behind the tiles. }
function BackgroundColor: TColor;

{** A tile's fill for @param(state): the range colour, slate for a stale
    reading, or grey without a reading. The menu-bar pills
    use it too, so a pill matches its tile. }
function TileColor(state: TAccountState): TColor;

{** The CSS colour for a reading's range level. }
function LevelCss(lvl: BGValLevel): string;

implementation

const
  // The range palette: darker than the desktop app's so white text carries
  // across a room, but the same meaning — green in range, amber and blue for
  // the room between a personal target band and the hard limits, red-orange
  // above and red below them.
  // Kept in step with the CSS_* constants in the interface.
  COL_RANGE = $2E7D32;       // green (stored as RGB below via Swap)
  COL_RANGE_HI = $C99500;
  COL_RANGE_LO = $0A6FA8;
  COL_HIGH = $C43C1E;
  COL_LOW = $B4142C;
  COL_NONE = $45454B;
  COL_BACK = $141418;
  // A stale tile turns this slate: Trndi's neutral for an outage, bluer than
  // COL_NONE so "lost the sensor" and "never had one" stay apart, and well
  // clear of COL_BACK so the tile does not melt into the window. The stage colours are
  // for text on that slate — warm, but never a range colour, so a tile that
  // has gone quiet is not read as a low from across the room.
  COL_STALE = $404A5C;
  COL_STALE_LATE = $F2C94C;
  COL_STALE_LOST = $FF9E8A;
  // Trndi's pace for its rolling reading (utabularlabel), so the two read
  // the same.
  ROLL_MS = 320;
  ROLL_TICK_MS = 16;
  // Trndi's background fade (umain BG_FADE_MS).
  BG_FADE_MS = 700;

// The constants above read as RGB hex; TColor is BGR.
function RGB(hex: longint): TColor;
begin
  Result := RGBToColor((hex shr 16) and $FF, (hex shr 8) and $FF, hex and $FF);
end;

function Mix(a, b: TColor; t: double): TColor;
var
  ra, ga, ba, rb, gb, bb: byte;
begin
  RedGreenBlue(ColorToRGB(a), ra, ga, ba);
  RedGreenBlue(ColorToRGB(b), rb, gb, bb);
  Result := RGBToColor(Round(ra + (rb - ra) * t), Round(ga + (gb - ga) * t),
    Round(ba + (bb - ba) * t));
end;

function LevelColor(lvl: BGValLevel): TColor;
begin
  case lvl of
    BGHigh: Result := RGB(COL_HIGH);
    BGLOW: Result := RGB(COL_LOW);
    BGRangeHI: Result := RGB(COL_RANGE_HI);
    BGRangeLO: Result := RGB(COL_RANGE_LO);
  else
    Result := RGB(COL_RANGE);
  end;
end;

function BackgroundColor: TColor;
begin
  Result := RGB(COL_BACK);
end;

// A stale reading drops its range colour altogether: the value is struck
// out as not to be acted on, and a red left behind would still read as "low
// right now" from across the room. How long it has been quiet is the text's
// job, which escalates through Trndi's stages.
function TileColor(state: TAccountState): TColor;
begin
  if (state = nil) or (not state.haveCurrent) then
    exit(RGB(COL_NONE));
  if state.StaleStage <> ssFresh then
    exit(RGB(COL_STALE));
  Result := LevelColor(state.current.level);
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

// The widest single word of a text in the canvas's current font: what
// word-wrapped TextRect cannot make narrower.
function WidestWord(cv: TCanvas; const text: string): integer;
var
  words: TStringArray;
  word: string;
begin
  Result := 0;
  words := text.Split([' ', #10, #13]);
  for word in words do
    Result := Max(Result, cv.TextWidth(word));
end;

// Height of text word-wrapped to width in the canvas's current font.
function WrappedHeight(cv: TCanvas; const text: string; width: integer): integer;
var
  rc: TRect;
begin
  rc := Rect(0, 0, width, 0);
  LCLIntf.DrawText(cv.Handle, PChar(text), Length(text), rc,
    DT_CALCRECT or DT_WORDBREAK or DT_NOPREFIX);
  Result := rc.Bottom - rc.Top;
end;

function HasDigit(const s: string): boolean;
var
  i: integer;
begin
  for i := 1 to Length(s) do
    if s[i] in ['0'..'9'] then
      exit(true);
  Result := false;
end;

// Splits an old and a new value into the bytes they share at either end and
// the differing middle, so only "4" rolls in "5.4" -> "5.6" and everything in
// "9.9" -> "10.0". The cuts are backed off to UTF-8 code point starts so a
// glyph that differs in its tail bytes rolls whole. A copy of Trndi's
// SplitRoll (utabularlabel), which that unit keeps to itself.
procedure SplitRoll(const AOld, ANew: string; out APrefix, AOldMid, ANewMid,
  ASuffix: string);
var
  p, sfx, oldLen, newLen: integer;
begin
  oldLen := Length(AOld);
  newLen := Length(ANew);
  p := 0;
  while (p < oldLen) and (p < newLen) and (AOld[p + 1] = ANew[p + 1]) do
    Inc(p);
  while (p > 0) and (p < oldLen) and (Ord(AOld[p + 1]) and $C0 = $80) do
    Dec(p);
  sfx := 0;
  while (sfx < oldLen - p) and (sfx < newLen - p) and
    (AOld[oldLen - sfx] = ANew[newLen - sfx]) do
    Inc(sfx);
  while (sfx > 0) and (Ord(AOld[oldLen - sfx + 1]) and $C0 = $80) do
    Dec(sfx);
  APrefix := Copy(AOld, 1, p);
  AOldMid := Copy(AOld, p + 1, oldLen - p - sfx);
  ANewMid := Copy(ANew, p + 1, newLen - p - sfx);
  ASuffix := Copy(AOld, oldLen - sfx + 1, sfx);
end;

constructor TAccountTile.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := true;
  FUnit := mmol;
end;

destructor TAccountTile.Destroy;
begin
  if Assigned(FAnimTimer) then
    FAnimTimer.Enabled := false;
  inherited Destroy;
end;

// Another account's state is not the next value of this one's: drop what
// was shown, so its first value appears rather than rolls.
procedure TAccountTile.SetState(AValue: TAccountState);
begin
  if FState = AValue then
    exit;
  FState := AValue;
  FShown := '';
  FRollFrom := '';
  FBgSet := false;
  FBgFading := false;
  if Assigned(FAnimTimer) then
    FAnimTimer.Enabled := false;
end;

procedure TAccountTile.StartAnim;
begin
  if FAnimTimer = nil then
  begin
    FAnimTimer := TTimer.Create(Self);
    FAnimTimer.Enabled := false;
    FAnimTimer.Interval := ROLL_TICK_MS;
    FAnimTimer.OnTimer := @AnimTick;
  end;
  FAnimTimer.Enabled := true;
end;

// One frame of whatever is running. The roll ends here; the fade ends in
// FillFor, on the paint that reaches its target, and the tick after that
// finds nothing left to run.
procedure TAccountTile.AnimTick(Sender: TObject);
begin
  if (FRollFrom <> '') and (GetTickCount64 - FRollStart >= ROLL_MS) then
    FRollFrom := '';
  if (FRollFrom = '') and (not FBgFading) then
    FAnimTimer.Enabled := false;
  if not (csDestroying in ComponentState) then
    Invalidate;
end;

// The fill to paint now, on the way to ATarget. Called by Paint, like
// NoteShown: a new colour is seen when the tile is repainted with it. A new
// target mid-fade starts from the tone already reached.
function TAccountTile.FillFor(ATarget: TColor): TColor;
var
  t: double;
begin
  if not FBgSet then
  begin
    FBgSet := true;
    FBgFading := false;
    FBgTarget := ATarget;
    FBg := ATarget;
  end
  else if ATarget <> FBgTarget then
  begin
    FBgFrom := FBg;
    FBgTarget := ATarget;
    FBgStart := GetTickCount64;
    FBgFading := not (csDestroying in ComponentState);
    if FBgFading then
      StartAnim
    else
      FBg := ATarget;
  end;
  if FBgFading then
  begin
    t := Min(1.0, (GetTickCount64 - FBgStart) / BG_FADE_MS);
    // Ease-in-out, as Trndi's: colour has nothing to land, and the soft
    // start keeps the change from reading as a jolt that then trails off.
    if t < 0.5 then
      t := 4 * t * t * t
    else
      t := 1 - 4 * (1 - t) * (1 - t) * (1 - t);
    if t >= 1.0 then
    begin
      FBgFading := false;
      FBg := FBgTarget;
    end
    else
      FBg := Mix(FBgFrom, FBgTarget, t);
  end;
  Result := FBg;
end;

// Called by Paint with the value it is about to draw. The tile only learns
// of a new reading by being repainted, so this is where a change is seen.
// Only the timer is touched here, never the canvas. A roll already under
// way restarts from the value it was heading for.
procedure TAccountTile.NoteShown(const AValue: string);
begin
  if (AValue <> FShown) and (FShown <> '') and (FShownUnit = FUnit) and
    HasDigit(FShown) and HasDigit(AValue) and
    not (csDestroying in ComponentState) then
  begin
    FRollFrom := FShown;
    FRollStart := GetTickCount64;
    StartAnim;
  end
  else if FShownUnit <> FUnit then
    FRollFrom := '';
  FShown := AValue;
  FShownUnit := FUnit;
end;

procedure TAccountTile.DrawText(x, y: integer; const s: string;
how: TAlignment; w: integer);
var
  tw: integer;
begin
  tw := Canvas.TextWidth(s);
  case how of
    taCenter: x := x + (w - tw) div 2;
    taRightJustify: x := x + w - tw;
  end;
  Canvas.TextOut(x, y, s);
end;

// The last hours as a line on a fixed axis — the window ends at now on every
// tile, so a line that stops short of the right edge is a sensor that has
// gone quiet, and two tiles can be compared by eye. Scaled so the hard
// limits always fit: a reading pinned to the top or bottom edge then means
// "off the chart", not "the highest we saw". The room between the limits is
// washed a shade lighter, and the personal target band inside it lighter
// still, the way Trndi tints its own graphs; the limits themselves are
// drawn as thin lines on top. The trace and its end dot go through Trndi's
// rasterizer, so they are antialiased and land in device pixels on a
// scaled desktop — a wall display shows this line at a size where an
// aliased polyline reads as a staircase.
procedure TAccountTile.DrawSpark(const r: TRect; bg: TColor);
const
  // Alpha of the white wash between the hard limits, and of the second wash
  // stacked on it for the personal band. Faint: the tile's own colour is
  // the message, the band only says where "in range" sits on the line.
  BAND_ALPHA = 22;
  TARGET_ALPHA = 26;
  BAND_EDGE_PX = 2;
var
  api: TrndiAPI;
  lo, hi, v: double;
  i, n, x, y, w, h: integer;
  pts: array of TPoint;
  cols: array of TColor;
  bands: array of TRangeBand;
  line: TColor;
  t0, t1: TDateTime;

  function YOf(val: double): integer;
  begin
    Result := r.Bottom - Round((val - lo) / (hi - lo) * h);
  end;

begin
  if (FState = nil) or (FState.api = nil) then
    exit;
  n := Length(FState.history);
  if n < 2 then
    exit;
  api := FState.api;
  w := r.Right - r.Left;
  h := r.Bottom - r.Top;
  if (w < 10) or (h < 6) then
    exit;

  // Scale: the account's limits, widened by whatever the readings need.
  lo := api.cgmLo;
  hi := api.cgmHi;
  for i := 0 to n - 1 do
  begin
    v := FState.history[i].convert(mgdl);
    lo := Min(lo, v);
    hi := Max(hi, v);
  end;
  lo := lo - 10;
  hi := hi + 10;
  if hi - lo < 1 then
    hi := lo + 1;

  // Band rows are relative to the raster's top; DrawRangeBands clips what
  // falls outside, so a personal band that reaches past the limits (a
  // misconfiguration Trndi tolerates too) fades into the edge rather than
  // being drawn wrong.
  bands := nil;
  SetLength(bands, 1);
  bands[0].Top := YOf(api.cgmHi) - r.Top;
  bands[0].Bottom := YOf(api.cgmLo) - r.Top;
  bands[0].Color := clWhite;
  bands[0].Alpha := BAND_ALPHA;
  if (api.cgmRangeHi <> TrndiAPI.CGM_RANGE_HI_DISABLED) and
    (api.cgmRangeLo <> TrndiAPI.CGM_RANGE_LO_DISABLED) and
    (api.cgmRangeHi > api.cgmRangeLo) then
  begin
    SetLength(bands, 2);
    bands[1].Top := YOf(api.cgmRangeHi) - r.Top;
    bands[1].Bottom := YOf(api.cgmRangeLo) - r.Top;
    bands[1].Color := clWhite;
    bands[1].Alpha := TARGET_ALPHA;
  end;
  DrawRangeBands(Canvas, w, h, bands, BAND_EDGE_PX, r.Left, r.Top);

  line := Mix(bg, clWhite, 0.55);
  Canvas.Pen.Style := psSolid;
  Canvas.Pen.Width := 1;
  Canvas.Pen.Color := line;
  y := YOf(api.cgmHi);
  Canvas.Line(r.Left, y, r.Right, y);
  y := YOf(api.cgmLo);
  Canvas.Line(r.Left, y, r.Right, y);

  // Time on the x axis rather than reading index, so a gap in the data
  // shows as a gap in the line's slope rather than being closed up.
  t1 := Now;
  t0 := IncMinute(t1, -HISTORY_MINUTES);
  pts := nil;
  SetLength(pts, n);
  for i := 0 to n - 1 do
  begin
    x := r.Left + Round((FState.history[i].date - t0) / (t1 - t0) * w);
    pts[i] := Point(EnsureRange(x, r.Left, r.Right),
      YOf(FState.history[i].convert(mgdl)));
  end;
  // One colour along the whole trace: the tile's background already says
  // which range the account is in. Uncached — every tile has its own trace,
  // and the rasterizer keeps a single slot, so six tiles would only evict
  // one another.
  line := Mix(bg, clWhite, 0.9);
  cols := nil;
  SetLength(cols, n);
  for i := 0 to n - 1 do
    cols[i] := line;
  DrawSmoothPolyline(Canvas, pts, cols, Max(2, h div 25), false);
  // The newest reading, marked.
  x := Max(3, h div 14);
  DrawSmoothCircle(Canvas, 2 * x, clWhite, clNone, 0, pts[n - 1].x - x,
    pts[n - 1].y - x);
  Canvas.Brush.Style := bsClear;
end;

procedure TAccountTile.Paint;
var
  r: TRect;
  h, w, pad, x, y, vh, ah, valW, arrowW, age, th, dy, oldMidW, newMidW: integer;
  scale, t: double;
  bg, ink: TColor;
  s, arrow, footer, prefix, oldMid, newMid, suffix: string;
  style: TTextStyle;
  box: TRect;
  stage: TStaleStage;
begin
  r := ClientRect;
  h := r.Bottom - r.Top;
  w := r.Right - r.Left;
  pad := Max(6, h div 30);

  // Background by range; grey without a reading, slate when stale (see
  // TileColor).
  stage := ssFresh;
  age := -1;
  if (FState <> nil) and FState.haveCurrent then
  begin
    stage := FState.StaleStage;
    age := FState.AgeMinutes;
  end;
  bg := FillFor(TileColor(FState));
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := bg;
  Canvas.FillRect(r);
  if FState = nil then
    exit;

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWhite;
  Canvas.Font.Quality := fqCleartype;

  // Header: who this is.
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Height := -Max(11, h div 11);
  y := r.Top + pad;
  DrawText(r.Left + pad, y, AccountLabel(FState.info), taLeftJustify);

  if FState.haveCurrent then
  begin
    // The value, big, with the arrow at half its size beside it. Sized from
    // the height, then shrunk if the pair would not fit the width: a 22.2
    // in a narrow tile must still be a 22.2, not a 22.
    s := FState.current.format(FUnit, BG_MSG_SHORT);
    NoteShown(s);
    arrow := BG_TREND_ARROWS_UTF[FState.current.trend];
    Canvas.Font.Style := [fsBold];
    vh := Max(24, Round(h * 0.40));
    ah := Max(14, Round(h * 0.20));
    Canvas.Font.Height := -vh;
    valW := Canvas.TextWidth(s);
    Canvas.Font.Height := -ah;
    arrowW := Canvas.TextWidth(arrow);
    if valW + arrowW + pad > w - 2 * pad then
    begin
      scale := (w - 2 * pad) / (valW + arrowW + pad);
      vh := Max(16, Round(vh * scale));
      ah := Max(10, Round(ah * scale));
      Canvas.Font.Height := -vh;
      valW := Canvas.TextWidth(s);
      Canvas.Font.Height := -ah;
      arrowW := Canvas.TextWidth(arrow);
    end;
    // Mid-roll the value's width glides from the old one's to the new one's
    // ("9.9" -> "10.0"), so the centred pair and the arrow slide over rather
    // than jump. Ease-out, so the new value lands rather than stops.
    t := 1;
    if FRollFrom <> '' then
    begin
      t := Min(1.0, (GetTickCount64 - FRollStart) / ROLL_MS);
      t := 1 - (1 - t) * (1 - t) * (1 - t);
      Canvas.Font.Height := -vh;
      valW := Round(Canvas.TextWidth(FRollFrom) +
        (valW - Canvas.TextWidth(FRollFrom)) * t);
    end;
    y := r.Top + Round(h * 0.16) + (Max(24, Round(h * 0.40)) - vh) div 2;
    x := r.Left + (w - valW - arrowW - pad) div 2;
    // A stale value and its arrow are the last known, not the current:
    // drawn faded so the eye does not take them for a reading, and the value
    // struck out as well, as Trndi strikes its own: faded alone reads as
    // "de-emphasised", which is not the same claim as "do not act on this
    // number". A stale value does not roll either: the OS draws the strike
    // per TextOut, so a split value would have its line broken.
    if stage <> ssFresh then
    begin
      Canvas.Font.Color := Mix(clWhite, bg, 0.3);
      Canvas.Font.Style := [fsBold, fsStrikeOut];
    end;
    Canvas.Font.Height := -vh;
    if (FRollFrom = '') or (stage <> ssFresh) then
      Canvas.TextOut(x, y, s)
    else
    begin
      // The shared head and tail stand still while the differing middle
      // turns over, old sliding up out of the line as new rises into it
      // from below, clipped to the line so nothing shows above or below.
      SplitRoll(FRollFrom, s, prefix, oldMid, newMid, suffix);
      th := Canvas.TextHeight(s);
      oldMidW := Canvas.TextWidth(oldMid);
      newMidW := Canvas.TextWidth(newMid);
      dy := Round(t * th);
      Canvas.ClipRect := Rect(r.Left, y, r.Right, y + th);
      Canvas.Clipping := true;
      Canvas.TextOut(x, y, prefix);
      Inc(x, Canvas.TextWidth(prefix));
      Canvas.TextOut(x, y - dy, oldMid);
      Canvas.TextOut(x, y + th - dy, newMid);
      if suffix <> '' then
        Canvas.TextOut(x + Round(oldMidW + (newMidW - oldMidW) * t), y, suffix);
      Canvas.Clipping := false;
      Canvas.ClipRect := r;
      x := r.Left + (w - valW - arrowW - pad) div 2;
    end;
    Canvas.Font.Style := [fsBold];
    Canvas.Font.Height := -ah;
    Canvas.TextOut(x + valW + pad, y + Round((vh - ah) * 0.55), arrow);
    Canvas.Font.Color := clWhite;

    // Delta and unit — or, for a stale reading, how long it has been since
    // anything came in, in the same place and size: the delta of a reading
    // from an hour ago is not news, the silence is. The line warms with
    // Trndi's stages, amber when late and red-tinted once the link is
    // likely lost, so an outage that needs a hand escalates on its own.
    Canvas.Font.Style := [];
    Canvas.Font.Height := -Max(11, Round(h * 0.09));
    if stage = ssFresh then
    begin
      if FState.current.deltaEmpty then
        s := BG_UNIT_NAMES[FUnit]
      else
        s := FState.current.format(FUnit, BG_MSG_SIG_SHORT, BGDelta) + '  ' +
          BG_UNIT_NAMES[FUnit];
    end
    else
    begin
      if age < 1 then
        s := 'No new data'
      else
        s := 'No data for ' + FormatAge(age);
      case stage of
        ssLate: ink := RGB(COL_STALE_LATE);
        ssLost: ink := RGB(COL_STALE_LOST);
      else
        ink := clWhite;
      end;
      Canvas.Font.Color := ink;
      if stage <> ssDelayed then
        Canvas.Font.Style := [fsBold];
    end;
    DrawText(r.Left, r.Top + Round(h * 0.57), s, taCenter, w);
    Canvas.Font.Color := clWhite;
    Canvas.Font.Style := [];

    DrawSpark(Rect(r.Left + pad, r.Top + Round(h * 0.68), r.Right - pad,
      r.Top + Round(h * 0.86)), bg);

    // Footer: when the reading is from and how old that makes it.
    footer := FormatDateTime('hh:nn', FState.current.date);
    if age < 1 then
      footer := footer + '  ·  now'
    else
      footer := footer + '  ·  ' + FormatAge(age);
    Canvas.Font.Height := -Max(10, Round(h * 0.075));
    DrawText(r.Left + pad, r.Bottom - pad - Canvas.TextHeight(footer), footer,
      taLeftJustify);
    if FState.err <> '' then
      DrawText(r.Left, r.Bottom - pad - Canvas.TextHeight(footer), '!',
        taRightJustify, w - pad);
  end
  else
  begin
    // No reading: say why, in the middle of the tile. Backend errors carry
    // long unbreakable tokens (a backend code, a URL) and can run to several
    // sentences, so shrink the font until the widest word fits the width
    // and the wrapped text fits the height, rather than let TextRect clip
    // it at both ends. A value after this one appears rather than rolls:
    // nothing on the tile is giving way to it.
    FShown := '';
    FRollFrom := '';
    Canvas.Font.Style := [];
    if FState.Busy and (not FState.everFetched) then
      s := 'Connecting…'
    else if FState.err <> '' then
    begin
      // The one repair this program cannot make itself, said briefly.
      s := TrndiLoginHint(FState.info.backend, FState.err);
      if s = '' then
        s := FState.err;
      s := 'No data' + LineEnding + s;
    end
    else
      s := 'No reading';
    box := Rect(r.Left + pad, r.Top + Round(h * 0.2), r.Right - pad,
      r.Bottom - pad);
    vh := Max(11, Round(h * 0.09));
    Canvas.Font.Height := -vh;
    while (vh > 10) and ((WidestWord(Canvas, s) > box.Width) or
        (WrappedHeight(Canvas, s, box.Width) > box.Height)) do
    begin
      vh := vh - 2;
      Canvas.Font.Height := -vh;
    end;
    style := Canvas.TextStyle;
    style.Alignment := taCenter;
    style.Layout := tlCenter;
    style.Wordbreak := true;
    style.SingleLine := false;
    style.Opaque := false;
    Canvas.TextRect(box, box.Left, box.Top, s, style);
  end;
end;

end.
