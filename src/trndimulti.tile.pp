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
}
unit trndimulti.tile;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Controls, Graphics, Types, Math, DateUtils,
trndi.types, trndi.api, trndimulti.accounts, trndimulti.state;

type
  {** A TCustomControl that paints a @link(TAccountState). The state is owned
      by the window, not the tile; a nil state paints an empty tile. }
  TAccountTile = class(TCustomControl)
  private
    FState: TAccountState;
    FUnit: BGUnit;
    procedure DrawSpark(const r: TRect; bg: TColor);
    procedure DrawText(x, y: integer; const s: string; how: TAlignment;
      w: integer = 0);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
    property State: TAccountState read FState write FState;
    property DisplayUnit: BGUnit read FUnit write FUnit;
  end;

{** Window background behind the tiles. }
function BackgroundColor: TColor;

implementation

const
  // The range palette: darker than the desktop app's so white text carries
  // across a room, but the same meaning — green in range, amber and blue for
  // the room between a personal target band and the hard limits, red-orange
  // above and red below them.
  COL_RANGE = $2E7D32;       // green (stored as RGB below via Swap)
  COL_RANGE_HI = $C99500;
  COL_RANGE_LO = $0A6FA8;
  COL_HIGH = $C43C1E;
  COL_LOW = $B4142C;
  COL_NONE = $45454B;
  COL_BACK = $141418;

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

constructor TAccountTile.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := true;
  FUnit := mmol;
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
// "off the chart", not "the highest we saw". The limits themselves are
// drawn as thin lines.
procedure TAccountTile.DrawSpark(const r: TRect; bg: TColor);
var
  api: TrndiAPI;
  lo, hi, v: double;
  i, n, x, y, w, h: integer;
  pts: array of TPoint;
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
  Canvas.Pen.Color := Mix(bg, clWhite, 0.9);
  Canvas.Pen.Width := Max(2, h div 25);
  Canvas.Polyline(pts);
  // The newest reading, marked.
  Canvas.Brush.Color := clWhite;
  Canvas.Pen.Color := clWhite;
  x := Max(3, h div 14);
  Canvas.Ellipse(pts[n - 1].x - x, pts[n - 1].y - x, pts[n - 1].x + x,
    pts[n - 1].y + x);
  Canvas.Brush.Style := bsClear;
end;

procedure TAccountTile.Paint;
var
  r: TRect;
  h, w, pad, x, y, vh, ah, valW, arrowW, age: integer;
  scale: double;
  bg: TColor;
  s, arrow, footer: string;
  style: TTextStyle;
begin
  r := ClientRect;
  h := r.Bottom - r.Top;
  w := r.Right - r.Left;
  pad := Max(6, h div 30);

  // Background by range; grey without a reading, dimmed when the reading is
  // old, so a tile that stopped updating reads as such from across the room.
  if (FState = nil) or (not FState.haveCurrent) then
    bg := RGB(COL_NONE)
  else if FState.IsStale then
    bg := Mix(LevelColor(FState.current.level), RGB(COL_NONE), 0.6)
  else
    bg := LevelColor(FState.current.level);
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
    y := r.Top + Round(h * 0.16) + (Max(24, Round(h * 0.40)) - vh) div 2;
    x := r.Left + (w - valW - arrowW - pad) div 2;
    Canvas.Font.Height := -vh;
    Canvas.TextOut(x, y, s);
    Canvas.Font.Height := -ah;
    Canvas.TextOut(x + valW + pad, y + Round((vh - ah) * 0.55), arrow);

    // Delta and unit.
    Canvas.Font.Style := [];
    Canvas.Font.Height := -Max(11, Round(h * 0.09));
    if FState.current.deltaEmpty then
      s := BG_UNIT_NAMES[FUnit]
    else
      s := FState.current.format(FUnit, BG_MSG_SIG_SHORT, BGDelta) + '  ' +
        BG_UNIT_NAMES[FUnit];
    DrawText(r.Left, r.Top + Round(h * 0.57), s, taCenter, w);

    DrawSpark(Rect(r.Left + pad, r.Top + Round(h * 0.68), r.Right - pad,
      r.Top + Round(h * 0.86)), bg);

    // Footer: when the reading is from and how old that makes it.
    age := FState.AgeMinutes;
    footer := FormatDateTime('hh:nn', FState.current.date);
    if age < 1 then
      footer := footer + '  ·  now'
    else
      footer := footer + Format('  ·  %d min', [age]);
    if FState.IsStale then
      footer := 'stale  ·  ' + footer;
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
    // long unbreakable tokens (a backend code, a URL), so shrink the font
    // until the widest word fits rather than let TextRect clip it.
    Canvas.Font.Style := [];
    if FState.Busy and (not FState.everFetched) then
      s := 'Connecting…'
    else if FState.err <> '' then
      s := 'No data' + LineEnding + FState.err
    else
      s := 'No reading';
    vh := Max(11, Round(h * 0.09));
    Canvas.Font.Height := -vh;
    while (vh > 10) and (WidestWord(Canvas, s) > w - 2 * pad) do
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
    Canvas.TextRect(Rect(r.Left + pad, r.Top + Round(h * 0.2), r.Right - pad,
      r.Bottom - pad), r.Left + pad, r.Top + Round(h * 0.2), s, style);
  end;
end;

end.
