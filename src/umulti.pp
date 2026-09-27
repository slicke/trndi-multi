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
  it, Q quits. Right-click opens a menu with the accounts window, an update
  check and the same actions; a kiosk has no menu, its passwords are not
  one click away.

  Shortly after the window is shown it asks GitHub once whether a newer
  build exists (trndimulti.update), except in kiosk mode, where nobody is
  there to answer the dialog.

  Full screen adds a clock strip above the tiles: a wall display has no
  panel or taskbar to tell the time.

  On macOS the readings can also sit in the menu bar, one pill per account
  (trndimulti.menubar); not in kiosk mode, where nobody is at the menu bar
  and a full-screen window hides it anyway.
}
unit umulti;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Forms, Controls, Graphics, ExtCtrls, StdCtrls, Menus,
LCLType, LCLIntf, Dialogs, Math, DateUtils, trndi.types, trndimulti.accounts,
trndimulti.state, trndimulti.tile, trndimulti.kiosk, trndimulti.clock,
trndimulti.settings, trndimulti.update, trndimulti.markdown,
trndimulti.report, trndimulti.about, trndimulti.branding, trndimulti.ontop,
trndimulti.detail, trndimulti.menubar;

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
    FEmpty: TMarkdownPane;
    FKiosk: boolean;
    FStartFullscreen: boolean;
    FSnapshotTimer: TTimer;
    FReportTimer: TTimer;
    FUpdateTimer: TTimer;
    FClock: TClockBar;
    FMenu: TPopupMenu;
    FOnTop: boolean;
    FOnTopItem: TMenuItem;
    // The menu-bar pills; nil where unsupported, in kiosk mode, and while
    // the setting is off.
    FPills: TMenuBarPills;
    FMenuBarItem: TMenuItem;
    // Where the report goes once every fetch in flight has landed; ''
    // when none is wanted. Polling pauses while it is set.
    FReportFile: string;
    procedure BuildMenu;
    procedure LoadAccounts;
    procedure ClearAccounts;
    procedure MenuAccounts(Sender: TObject);
    procedure MenuRefresh(Sender: TObject);
    procedure MenuFullscreen(Sender: TObject);
    procedure MenuOnTop(Sender: TObject);
    procedure MenuMenuBar(Sender: TObject);
    procedure ApplyMenuBar(pillsOn: boolean);
    procedure UpdatePills;
    procedure PillShowClicked;
    procedure PillHideClicked;
    procedure PillQuitClicked;
    procedure MenuQuit(Sender: TObject);
    procedure MenuUpdate(Sender: TObject);
    procedure MenuAbout(Sender: TObject);
    procedure MenuReport(Sender: TObject);
    procedure TileClick(Sender: TObject);
    procedure TryStartReport;
    procedure ReportDone(const fileName, err: string);
    procedure SnapshotTick(Sender: TObject);
    procedure ReportTick(Sender: TObject);
    procedure UpdateTick(Sender: TObject);
    procedure LayoutTiles;
    procedure TimerTick(Sender: TObject);
    procedure FetchDone(state: TAccountState);
    procedure FetchDue(force: boolean);
    procedure SetFullscreen(full: boolean);
    procedure ApplyOnTop(fullscreen: boolean);
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
  TRNDI_URL = 'https://github.com/slicke/trndi';
  GUIDE_URL = 'https://github.com/slicke/trndi/blob/main/guides/Multiuser.md';
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
  FOnTop := ReadOnTop;
  ApplyOnTop(false);

  FTimer := TTimer.Create(Self);
  FTimer.Interval := TICK_MS;
  FTimer.OnTimer := @TimerTick;

  FClock := TClockBar.Create(Self);
  FClock.Parent := Self;
  FClock.Color := Color;
  FClock.Visible := false;

  if not FKiosk then
    BuildMenu;
  LoadAccounts;
  LayoutTiles;
  if (not FKiosk) and MenuBarSupported then
    ApplyMenuBar(ReadMenuBar);
  FetchDue(true);
  FTimer.Enabled := true;

  // Test hook: TRNDI_MULTI_REPORT=<file.pdf> saves the report there a few
  // seconds in, once the first fetches have landed, and quits; a failure
  // goes to stderr and the exit code. For CI, against a synthetic backend.
  if GetEnvironmentVariable('TRNDI_MULTI_REPORT') <> '' then
  begin
    FReportTimer := TTimer.Create(Self);
    FReportTimer.Interval := 6000;
    FReportTimer.OnTimer := @ReportTick;
    FReportTimer.Enabled := true;
  end;

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
  // The accounts, About and detail windows snapshot themselves
  // (<file>.accounts.png, <file>.about.png, <file>.detail.png) and close;
  // the detail window is the first account's.
  if not FKiosk then
  begin
    EditAccounts(Self);
    ShowAbout(Self);
    if Length(FStates) > 0 then
      ShowDetail(Self, FStates[0], FUnit);
  end;
  Close;
end;

procedure TfMulti.ReportTick(Sender: TObject);
begin
  FReportTimer.Enabled := false;
  FReportFile := GetEnvironmentVariable('TRNDI_MULTI_REPORT');
  TryStartReport;
end;

destructor TfMulti.Destroy;
begin
  FTimer.Enabled := false;
  AbandonUpdateCheck;
  // Before the states: the report reads through their backends.
  AbandonReport;
  if FKiosk then
    SetKeepAwake(false);
  FreeAndNil(FPills);
  ClearAccounts;
  inherited Destroy;
end;

procedure TfMulti.BuildMenu;

  function Item(const caption: string; handler: TNotifyEvent): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := caption;
    Result.OnClick := handler;
    FMenu.Items.Add(Result);
  end;

begin
  FMenu := TPopupMenu.Create(Self);
  Item('Accounts...', @MenuAccounts);
  Item('-', nil);
  Item('Refresh now' + #9 + 'F5', @MenuRefresh);
  Item('Full screen' + #9 + 'F11', @MenuFullscreen);
  FOnTopItem := Item('Always on top', @MenuOnTop);
  FOnTopItem.Checked := FOnTop;
  if MenuBarSupported then
    FMenuBarItem := Item('Readings in the menu bar', @MenuMenuBar);
  Item('-', nil);
  Item('Save report...', @MenuReport);
  Item('-', nil);
  Item('Check for updates...', @MenuUpdate);
  Item('About Trndi Multi...', @MenuAbout);
  Item('Quit' + #9 + 'Q', @MenuQuit);
  PopupMenu := FMenu;
end;

// Tiles first, so nothing paints a state that is being freed; the states
// then wait for any fetch still running. The arrays are taken away before
// anything is freed: removing a tile from the form makes the LCL re-run
// the layout, and a state's destructor services Synchronize while it
// waits for its fetch, so LayoutTiles and FetchDone can both run in the
// middle of this and must not find half-freed tiles.
procedure TfMulti.ClearAccounts;
var
  tiles: array of TAccountTile;
  states: array of TAccountState;
  i: integer;
begin
  // The pills are keyed by account; the next UpdatePills recreates them.
  if FPills <> nil then
    FPills.Clear;
  tiles := FTiles;
  states := FStates;
  FTiles := nil;
  FStates := nil;
  DisableAutoSizing;
  try
    for i := 0 to High(tiles) do
      tiles[i].Free;
    for i := 0 to High(states) do
      states[i].Free;
    FreeAndNil(FEmpty);
  finally
    EnableAutoSizing;
  end;
end;

// Saved in the accounts window: start over from the store, as a restart
// would, without the restart.
procedure TfMulti.MenuAccounts(Sender: TObject);
begin
  // Saving reloads the accounts, which frees the backends a report reads.
  if FReportFile <> '' then
  begin
    MessageDlg('Trndi Multi', 'A report is being prepared; try again when ' +
      'it has been saved.', mtInformation, [mbOK], 0);
    exit;
  end;
  if not EditAccounts(Self) then
    exit;
  ClearAccounts;
  LoadAccounts;
  LayoutTiles;
  UpdatePills;
  FetchDue(true);
end;

procedure TfMulti.MenuRefresh(Sender: TObject);
begin
  FetchDue(true);
end;

procedure TfMulti.MenuFullscreen(Sender: TObject);
begin
  SetFullscreen(WindowState <> wsFullScreen);
end;

procedure TfMulti.MenuOnTop(Sender: TObject);
begin
  FOnTop := not FOnTop;
  FOnTopItem.Checked := FOnTop;
  WriteOnTop(FOnTop);
  // Wayland: the hint only works through XWayland, which the program can
  // only switch to at start (see trndimulti.ontop). Offer that.
  if FOnTop and OnTopNeedsRestart then
  begin
    if MessageDlg('Trndi Multi',
      'On this desktop the window can only stay on top when it runs ' +
      'through XWayland, which takes a restart. Restart Trndi Multi now?',
      mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      RestartProgram;
      Close;
    end;
    exit;
  end;
  ApplyOnTop(WindowState = wsFullScreen);
end;

procedure TfMulti.MenuMenuBar(Sender: TObject);
begin
  WriteMenuBar(FPills = nil);
  ApplyMenuBar(FPills = nil);
end;

// Stored or not, the setting takes effect here: pills on or off, and the
// menu item's check mark to match.
procedure TfMulti.ApplyMenuBar(pillsOn: boolean);
begin
  if FMenuBarItem <> nil then
    FMenuBarItem.Checked := pillsOn;
  if not pillsOn then
  begin
    FreeAndNil(FPills);
    exit;
  end;
  if FPills = nil then
    FPills := TMenuBarPills.Create(@PillShowClicked, @PillHideClicked,
      @PillQuitClicked);
  UpdatePills;
end;

procedure TfMulti.UpdatePills;
begin
  if FPills <> nil then
    FPills.Update(FStates, FUnit);
end;

procedure TfMulti.PillShowClicked;
begin
  if WindowState = wsMinimized then
    WindowState := wsNormal;
  Show;
  Application.BringToFront;
  BringToFront;
end;

procedure TfMulti.PillHideClicked;
begin
  WriteMenuBar(false);
  ApplyMenuBar(false);
  MessageDlg('Trndi Multi', 'The readings are no longer shown in the menu ' +
    'bar.' + LineEnding + LineEnding + 'You can turn them back on by ' +
    'right-clicking the window and choosing "Readings in the menu bar".',
    mtInformation, [mbOK], 0);
end;

procedure TfMulti.PillQuitClicked;
begin
  Close;
end;

procedure TfMulti.MenuQuit(Sender: TObject);
begin
  Close;
end;

procedure TfMulti.MenuUpdate(Sender: TObject);
begin
  CheckForUpdates(true);
end;

// The About window runs the check for us rather than opening a dialog of
// its own on top of itself.
procedure TfMulti.MenuAbout(Sender: TObject);
begin
  if ShowAbout(Self) then
    CheckForUpdates(true);
end;

procedure TfMulti.TileClick(Sender: TObject);
begin
  if Sender is TAccountTile then
    ShowDetail(Self, TAccountTile(Sender).State, FUnit);
end;

// Every account with a backend gets a tile. The display unit is the first
// such account's: a household can have mmol/L and mg/dL accounts side by
// side, and one unit across the wall is easier to read than two.
procedure TfMulti.LoadAccounts;
var
  accounts: TAccountList;
  a: TAccountInfo;
  n: integer;
  head: string;
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
      FTiles[n].PopupMenu := FMenu;
      FTiles[n].State := FStates[n];
      FTiles[n].DisplayUnit := FUnit;
      // A click opens the account's detail window. Not on a kiosk: the
      // pointer is hidden there and a modal that nobody closes would
      // sit over the wall.
      if not FKiosk then
      begin
        FTiles[n].OnClick := @TileClick;
        FTiles[n].Cursor := crHandPoint;
      end;
      Inc(n);
    end;

  if n = 0 then
  begin
    FEmpty := TMarkdownPane.Create(Self);
    FEmpty.Parent := Self;
    FEmpty.Align := alClient;
    FEmpty.PopupMenu := FMenu;
    FEmpty.SetTheme(BackgroundColor, $C8C8C8, 16,
      'body { text-align: center; padding: 10% 12% 0; }' +
      '.logo { width: 112px; height: 112px; margin-bottom: 14px; }' +
      'h2 { color: #FFFFFF; font-weight: normal; font-size: 1.6em; }' +
      'p { margin-bottom: 1em; }');
    // A blank wall is what a display shows for as long as nobody has set an
    // account up, so it says whose program is standing there: the logo out
    // of this binary's icon (see trndimulti.branding), over the heading.
    head := LogoDataUri;
    if head <> '' then
      head := '<img class="logo" src="' + head + '">' + LineEnding + LineEnding;
    head := head + '## No Trndi accounts set up';
    if FKiosk then
      FEmpty.Load(
        head + LineEnding + LineEnding +
        'Accounts and their backends are managed in [Trndi](' + TRNDI_URL +
        ')''s settings window, or in this program''s Accounts window ' +
        'outside kiosk mode.' + LineEnding + LineEnding +
        'Settings: `' + SettingsLocation + '`')
    else
      FEmpty.Load(
        head + LineEnding + LineEnding +
        'Right-click here and choose **Accounts** to add them, or set them ' +
        'up in [Trndi](' + TRNDI_URL + '): both use the same settings. ' +
        'The walkthrough is in [Trndi''s multi-user guide](' + GUIDE_URL + ').' +
        LineEnding + LineEnding + 'Settings: `' + SettingsLocation + '`');
  end;
end;

// Grid: the column count that gives the biggest tiles, judged by how large
// a 4:3 rectangle fits inside one tile. Two accounts get two columns in a
// wide window and two rows in a tall one, and so on up.
procedure TfMulti.LayoutTiles;
var
  n, cols, rows, best, c, r, i, tw, th, gridTop, avail: integer;
  score, bestScore: double;
begin
  // The clock, when shown, takes a strip across the top; the tiles share
  // what is left. Resize runs once during construction, before the clock
  // exists; nothing to lay out then either.
  gridTop := TILE_GAP;
  if (FClock <> nil) and FClock.Visible then
  begin
    FClock.SetBounds(TILE_GAP, TILE_GAP, ClientWidth - 2 * TILE_GAP,
      Max(24, ClientHeight div 14));
    gridTop := FClock.Top + FClock.Height + TILE_GAP;
  end;
  avail := ClientHeight - gridTop + TILE_GAP;

  n := Length(FTiles);
  if n = 0 then
    exit;
  best := 1;
  bestScore := -1;
  for c := 1 to n do
  begin
    r := (n + c - 1) div c;
    tw := (ClientWidth - TILE_GAP * (c + 1)) div c;
    th := (avail - TILE_GAP * (r + 1)) div r;
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
  th := (avail - TILE_GAP * (rows + 1)) div rows;
  for i := 0 to n - 1 do
    FTiles[i].SetBounds(TILE_GAP + (i mod cols) * (tw + TILE_GAP),
      gridTop + (i div cols) * (th + TILE_GAP), tw, th);
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
  // The update check is deferred the same way, and a little longer, so the
  // first paint and the first fetches are not behind it. One-shot.
  if (not FKiosk) and (FUpdateTimer = nil) then
  begin
    FUpdateTimer := TTimer.Create(Self);
    FUpdateTimer.Interval := 1500;
    FUpdateTimer.OnTimer := @UpdateTick;
    FUpdateTimer.Enabled := true;
  end;
end;

procedure TfMulti.UpdateTick(Sender: TObject);
begin
  FUpdateTimer.Enabled := false;
  CheckForUpdates(false);
end;

procedure TfMulti.KioskApply(Sender: TObject);
begin
  FKioskTimer.Enabled := false;
  SetFullscreen(true);
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
  // Ages on the footers move on even when nothing was fetched, and a pill
  // turns to '--' once its reading goes stale.
  for i := 0 to High(FTiles) do
    FTiles[i].Invalidate;
  UpdatePills;
end;

procedure TfMulti.FetchDue(force: boolean);
var
  i: integer;
begin
  // A report wanted or running: no new fetch, so it gets the backends to
  // itself. Polling picks up again from ReportDone.
  if FReportFile <> '' then
    exit;
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
  UpdatePills;
  TryStartReport;
end;

{------------------------------------------------------------------------------
  The report
 ------------------------------------------------------------------------------}

procedure TfMulti.MenuReport(Sender: TObject);
var
  dlg: TSaveDialog;
begin
  if FReportFile <> '' then
  begin
    MessageDlg('Trndi Multi', 'A report is already being prepared.',
      mtInformation, [mbOK], 0);
    exit;
  end;
  if Length(FStates) = 0 then
  begin
    MessageDlg('Trndi Multi', 'There are no accounts to report on.',
      mtInformation, [mbOK], 0);
    exit;
  end;
  dlg := TSaveDialog.Create(nil);
  try
    dlg.Title := 'Save report';
    dlg.DefaultExt := 'pdf';
    dlg.Filter := 'PDF document|*.pdf';
    dlg.Options := [ofOverwritePrompt, ofPathMustExist, ofEnableSizing];
    dlg.InitialDir := GetUserDir;
    dlg.FileName := 'trndi-multi-report-' +
      FormatDateTime('yyyy-mm-dd', Now) + '.pdf';
    if not dlg.Execute then
      exit;
    FReportFile := dlg.FileName;
  finally
    dlg.Free;
  end;
  Screen.Cursor := crHourGlass;
  TryStartReport;
end;

// Start the report once no fetch is in flight: from the menu, and from
// FetchDone for each fetch that was running when the menu was used.
procedure TfMulti.TryStartReport;
var
  i: integer;
  accts: TReportAccounts;
begin
  if (FReportFile = '') or ReportRunning then
    exit;
  for i := 0 to High(FStates) do
    if FStates[i].Busy then
      exit;
  accts := nil;
  SetLength(accts, Length(FStates));
  for i := 0 to High(FStates) do
  begin
    accts[i].info := FStates[i].info;
    accts[i].api := FStates[i].api;
    accts[i].err := FStates[i].err;
    accts[i].current := FStates[i].current;
    accts[i].haveCurrent := FStates[i].haveCurrent;
    accts[i].stale := FStates[i].IsStale;
  end;
  StartReport(accts, FUnit, FReportFile, @ReportDone);
end;

procedure TfMulti.ReportDone(const fileName, err: string);
var
  i: integer;
begin
  FReportFile := '';
  Screen.Cursor := crDefault;
  // The report fetched through the backends too, and CareLink may have
  // rotated a token on its thread.
  for i := 0 to High(FStates) do
    FStates[i].SyncCredentials;
  if FReportTimer <> nil then
  begin
    if err <> '' then
    begin
      WriteLn(StdErr, 'Report failed: ', err);
      ExitCode := 1;
    end;
    Close;
    exit;
  end;
  if err <> '' then
    MessageDlg('Trndi Multi', 'The report could not be saved.' + LineEnding +
      err, mtError, [mbOK], 0)
  else if QuestionDlg('Trndi Multi', 'The report was saved as' + LineEnding +
      fileName, mtInformation, [mrYes, 'Open', 'IsDefault', mrOK, 'Close'],
      0) = mrYes then
    OpenDocument(fileName);
  // The accounts have been waiting for the report.
  FetchDue(false);
end;

// The LCL does not track a full-screen change made by the window manager,
// so every change goes through here and the clock follows it. The layout is
// redone at once as well: the resize that follows may arrive with the old
// client size on some widgetsets, or not at all if the size did not change.
procedure TfMulti.SetFullscreen(full: boolean);
begin
  // The floating level is dropped before the window goes full screen and
  // put back once it is a normal window again, so a widgetset that
  // recreates the window for a style change never does so mid-transition.
  if full then
  begin
    ApplyOnTop(true);
    WindowState := wsFullScreen;
  end
  else
  begin
    WindowState := wsNormal;
    ApplyOnTop(false);
  end;
  FClock.Visible := full;
  LayoutTiles;
end;

// The always-on-top setting, through the form style the LCL maps to each
// platform's own notion of a floating window (HWND_TOPMOST, the Qt hint,
// Cocoa's floating window level). Only outside full screen: a full-screen
// window is above everything already, and macOS puts a native full-screen
// window in a space of its own where a floating level makes no sense.
// Some widgetsets recreate the window to change its style, so this is
// done only when the style would actually change.
procedure TfMulti.ApplyOnTop(fullscreen: boolean);
var
  want: TFormStyle;
begin
  if FOnTop and (not fullscreen) then
    want := fsStayOnTop
  else
    want := fsNormal;
  if FormStyle <> want then
    FormStyle := want;
end;

procedure TfMulti.KeyDown(var Key: word; Shift: TShiftState);
begin
  case Key of
    VK_F5:
      FetchDue(true);
    VK_F11:
      SetFullscreen(WindowState <> wsFullScreen);
    VK_ESCAPE:
      // A kiosk stays full screen; Q still quits it.
      if (WindowState = wsFullScreen) and (not FKiosk) then
        SetFullscreen(false);
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
