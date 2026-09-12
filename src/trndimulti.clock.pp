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
  A clock strip for the wall: the time, large, and the date, for a display
  that runs full screen with no panel or taskbar to show them.

  Painted in the window's own colours so it reads as part of the wall, not a
  widget on top of it. Its own one-second timer repaints it when the minute
  turns, so the shown time is never more than a second behind.
}
unit trndimulti.clock;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Controls, Graphics, ExtCtrls, Math;

type
  {** Date on the left, time on the right, both vertically centred. Scales
      with its own height; the window decides how tall the strip is. }
  TClockBar = class(TCustomControl)
  private
    FTimer: TTimer;
    FShown: string;           // Time text last painted
    procedure Tick(Sender: TObject);
  protected
    procedure Paint; override;
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

constructor TClockBar.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  DoubleBuffered := true;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 1000;
  FTimer.OnTimer := @Tick;
  FTimer.Enabled := true;
end;

// Repaint only when the displayed minute changes: a wall display should not
// redraw itself every second for no visible reason.
procedure TClockBar.Tick(Sender: TObject);
begin
  if Visible and (FormatDateTime('hh:nn', Now) <> FShown) then
    Invalidate;
end;

procedure TClockBar.Paint;
var
  r: TRect;
  h, pad: integer;
  now_: TDateTime;
  s: string;
begin
  r := ClientRect;
  h := r.Bottom - r.Top;
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Color;
  Canvas.FillRect(r);
  if h < 10 then
    exit;
  pad := Max(4, h div 6);
  now_ := Now;
  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := clWhite;
  Canvas.Font.Quality := fqCleartype;

  // The time, bold, at the right edge.
  FShown := FormatDateTime('hh:nn', now_);
  Canvas.Font.Style := [fsBold];
  Canvas.Font.Height := -Max(12, Round(h * 0.8));
  Canvas.TextOut(r.Right - pad - Canvas.TextWidth(FShown),
    r.Top + (h - Canvas.TextHeight(FShown)) div 2, FShown);

  // The date, lighter and smaller, at the left. Dropped when the strip is
  // too narrow to hold both without overlapping.
  s := FormatDateTime('dddd d mmmm', now_);
  Canvas.Font.Style := [];
  Canvas.Font.Height := -Max(11, Round(h * 0.5));
  Canvas.Font.Color := $C8C8C8;
  if Canvas.TextWidth(s) + Canvas.TextWidth(FShown) + 3 * pad <= r.Right - r.Left
  then
    Canvas.TextOut(r.Left + pad, r.Top + (h - Canvas.TextHeight(s)) div 2, s);
end;

end.
