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
  The window: one tile per configured Trndi account, laid out as a grid that
  refills the window on resize, polled on each account's own schedule.

  Keys: F5 refetches every account, F11 toggles full screen, Escape leaves
  it, Q quits.
}
unit umulti;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, StdCtrls, LCLType,
Math, DateUtils, trndi.types, trndimulti.accounts, trndimulti.state,
trndimulti.tile, trndimulti.kiosk;

type
  {** The main (and only) window. Built in code: no form resource.

      Command line: @code(--fullscreen) starts full screen; @code(--kiosk)
      does that and also hides the pointer, keeps the machine and display
      awake and ignores Escape, for a dedicated wall display. }
  TfMulti = class(TForm)
  private
    FStates: array of TAccountState;
    FTiles: array of TAccountTile;
    FTimer: TTimer;
    FKioskTimer: TTimer;
    FUnit: BGUnit;
    FEmpty: TLabel;
    FKiosk: boolean;
    FStartFullscreen: boolean;
    FSnapshotTimer: TTimer;
    procedure LoadAccounts;
    procedure SnapshotTick(Sender: TObject);
    procedure LayoutTiles;
    procedure TimerTick(Sender: TObject);
    procedure FetchDone(state: TAccountState);
    procedure FetchDue(force: boolean);
    procedure ToggleFullscreen;
    procedure KioskApply(Sender: TObject);
  protected
    procedure Resize; override;
    procedure DoShow; override;
    procedure KeyDown(var Key: word; Shift: TShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  fMulti: TfMulti;

implementation

const
  TILE_GAP = 8;
  // How often the window checks whether an account is due and refreshes the
  // reading ages on the tiles.
  TICK_MS = 10000;

constructor TfMulti.Create(AOwner: TComponent);
var
  i: integer;
begin
  inherited CreateNew(AOwner, 0);
  // Parsed by hand, as Trndi does: two flags do not need a parser, and the
  // GUI has no console for a usage message anyway.
  for i := 1 to ParamCount do
    if ParamStr(i) = '--kiosk' then
      FKiosk := true
    else if ParamStr(i) = '--fullscreen' then
      FStartFullscreen := true;
  Caption := 'Trndi Multi';
  Color := BackgroundColor;
  Width := 960;
  Height := 600;
  Constraints.MinWidth := 320;
  Constraints.MinHeight := 240;
  Position := poScreenCenter;
  KeyPreview := true;
  DoubleBuffered := true;

  FTimer := TTimer.Create(Self);
  FTimer.Interval := TICK_MS;
  FTimer.OnTimer := @TimerTick;

  LoadAccounts;
  LayoutTiles;
  FetchDue(true);
  FTimer.Enabled := true;

  // Test hook: TRNDI_MULTI_SNAPSHOT=<file.png> renders the window to that
  // file a few seconds in and quits. With QT_QPA_PLATFORM=offscreen this
  // gives a screenshot with no display and no screen grab, for CI and for
  // checking a tile state without taking over the desktop.
  if GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT') <> '' then
  begin
    FSnapshotTimer := TTimer.Create(Self);
    FSnapshotTimer.Interval := 6000;
    FSnapshotTimer.OnTimer := @SnapshotTick;
    FSnapshotTimer.Enabled := true;
  end;
end;

procedure TfMulti.SnapshotTick(Sender: TObject);
var
  img: TBitmap;
  png: TPortableNetworkGraphic;
begin
  FSnapshotTimer.Enabled := false;
  img := GetFormImage;
  try
    png := TPortableNetworkGraphic.Create;
    try
      png.Assign(img);
      png.SaveToFile(GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT'));
    finally
      png.Free;
    end;
  finally
    img.Free;
  end;
  Close;
end;

destructor TfMulti.Destroy;
var
  i: integer;
begin
  FTimer.Enabled := false;
  if FKiosk then
    SetKeepAwake(false);
  // Tiles first, so nothing paints a state that is being freed; the states
  // then wait for any fetch still running.
  for i := 0 to High(FTiles) do
    FTiles[i].Free;
  FTiles := nil;
  for i := 0 to High(FStates) do
    FStates[i].Free;
  FStates := nil;
  inherited Destroy;
end;

// Every account with a backend gets a tile. The display unit is the first
// such account's: a household can have mmol/L and mg/dL accounts side by
// side, and one unit across the wall is easier to read than two.
procedure TfMulti.LoadAccounts;
var
  accounts: TAccountList;
  a: TAccountInfo;
  n: integer;
begin
  accounts := ListAccounts;
  n := 0;
  for a in accounts do
    if a.backend <> '' then
    begin
      if n = 0 then
        if a.mmol then
          FUnit := mmol
        else
          FUnit := mgdl;
      SetLength(FStates, n + 1);
      SetLength(FTiles, n + 1);
      FStates[n] := TAccountState.Create(a);
      FTiles[n] := TAccountTile.Create(Self);
      FTiles[n].Parent := Self;
      FTiles[n].State := FStates[n];
      FTiles[n].DisplayUnit := FUnit;
      Inc(n);
    end;

  if n = 0 then
  begin
    FEmpty := TLabel.Create(Self);
    FEmpty.Parent := Self;
    FEmpty.Align := alClient;
    FEmpty.Alignment := taCenter;
    FEmpty.Layout := tlCenter;
    FEmpty.WordWrap := true;
    FEmpty.Font.Color := clWhite;
    FEmpty.Font.Height := -16;
    FEmpty.Caption := 'No Trndi accounts found.' + LineEnding + LineEnding +
      'Set up Trndi first: accounts and their backends are managed in its ' +
      'settings window, and this program shows every account it finds there ('
      + SettingsLocation + ').';
  end;
end;

// Grid: the column count that gives the biggest tiles, judged by how large
// a 4:3 rectangle fits inside one tile. Two accounts get two columns in a
// wide window and two rows in a tall one, and so on up.
procedure TfMulti.LayoutTiles;
var
  n, cols, rows, best, c, r, i, tw, th: integer;
  score, bestScore: double;
begin
  n := Length(FTiles);
  if n = 0 then
    exit;
  best := 1;
  bestScore := -1;
  for c := 1 to n do
  begin
    r := (n + c - 1) div c;
    tw := (ClientWidth - TILE_GAP * (c + 1)) div c;
    th := (ClientHeight - TILE_GAP * (r + 1)) div r;
    score := Min(tw / 4, th / 3);
    if score > bestScore then
    begin
      bestScore := score;
      best := c;
    end;
  end;
  cols := best;
  rows := (n + cols - 1) div cols;
  tw := (ClientWidth - TILE_GAP * (cols + 1)) div cols;
  th := (ClientHeight - TILE_GAP * (rows + 1)) div rows;
  for i := 0 to n - 1 do
    FTiles[i].SetBounds(TILE_GAP + (i mod cols) * (tw + TILE_GAP),
      TILE_GAP + (i div cols) * (th + TILE_GAP), tw, th);
end;

procedure TfMulti.Resize;
begin
  inherited Resize;
  LayoutTiles;
end;

// Full screen is asked for once the window is mapped, on a short timer, so
// the window manager has a real window to resize; asking in the constructor
// is ignored by some of them.
procedure TfMulti.DoShow;
begin
  inherited DoShow;
  if (FKiosk or FStartFullscreen) and (FKioskTimer = nil) then
  begin
    FKioskTimer := TTimer.Create(Self);
    FKioskTimer.Interval := 300;
    FKioskTimer.OnTimer := @KioskApply;
    FKioskTimer.Enabled := true;
  end;
end;

procedure TfMulti.KioskApply(Sender: TObject);
begin
  FKioskTimer.Enabled := false;
  WindowState := wsFullScreen;
  if FKiosk then
  begin
    Screen.Cursor := crNone;
    SetKeepAwake(true);
  end;
end;

procedure TfMulti.TimerTick(Sender: TObject);
var
  i: integer;
begin
  FetchDue(false);
  // Ages on the footers move on even when nothing was fetched.
  for i := 0 to High(FTiles) do
    FTiles[i].Invalidate;
end;

procedure TfMulti.FetchDue(force: boolean);
var
  i: integer;
begin
  for i := 0 to High(FStates) do
    if (not FStates[i].Busy) and (force or (FStates[i].nextDue <= Now)) then
      StartFetch(FStates[i], @FetchDone);
end;

procedure TfMulti.FetchDone(state: TAccountState);
var
  i: integer;
begin
  for i := 0 to High(FTiles) do
    if FTiles[i].State = state then
      FTiles[i].Invalidate;
end;

procedure TfMulti.ToggleFullscreen;
begin
  if WindowState = wsFullScreen then
    WindowState := wsNormal
  else
    WindowState := wsFullScreen;
end;

procedure TfMulti.KeyDown(var Key: word; Shift: TShiftState);
begin
  case Key of
    VK_F5:
      FetchDue(true);
    VK_F11:
      ToggleFullscreen;
    VK_ESCAPE:
      // A kiosk stays full screen; Q still quits it.
      if (WindowState = wsFullScreen) and (not FKiosk) then
        WindowState := wsNormal;
    VK_Q:
      Close;
  else
    begin
      inherited KeyDown(Key, Shift);
      exit;
    end;
  end;
  Key := 0;
end;

end.
