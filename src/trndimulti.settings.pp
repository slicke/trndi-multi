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
  The accounts window: one tab per Trndi account with the few settings a
  tile needs (nickname, backend, its user and password, unit), a "+" tab
  that adds an account, and Remove. Writes go to Trndi's own store through
  @link(SaveAccounts), so an account set up here is a Trndi account too.

  Each tab also holds the account's limits: the high and low limits and the
  target range, as Trndi's settings window stores them (override.*, in
  mg/dL), shown in the tab's unit. Unticked, the backend's own apply; a
  backend that sends none (Dexcom Share) needs them set here or in Trndi.

  The account name is asked for once, when the tab is added, and cannot be
  changed afterwards: it is the prefix on every key the account owns, and
  Trndi has no rename either. The nickname is what changes, and what the
  tab and the tile show.
}
unit trndimulti.settings;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Math, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls,
Dialogs, trndi.api, trndi.api.registry, trndimulti.accounts, Graphics,
trndimulti.markdown;

{** Show the window modally. True when the user saved, in which case the
    store has changed and the caller should reload its accounts. }
function EditAccounts(owner: TComponent): boolean;

implementation

type
  {** The controls of one account tab and the account behind them. }
  TAccountPage = class
    sheet: TTabSheet;
    edNick, edUser, edPass: TEdit;
    cbSys: TComboBox;
    lbUser, lbPass: TLabel;
    lbNote: TMarkdownPane;
    rgUnit: TRadioGroup;
    gbLimits: TGroupBox;
    cbLimits, cbRange: TCheckBox;
    edLo, edHi, edRangeLo, edRangeHi: TEdit;
    lbLimitsNote: TLabel;
    limitsMmol: boolean;     // Unit the limit boxes are showing
    btnRemove: TButton;
    info: TAccountInfo;      // As loaded; name is the identity
    credsEdited: boolean;
    loginHidden: boolean;    // User and credential rows collapsed (web-login backend)
  end;

  TfAccounts = class(TForm)
  private
    FPages: TPageControl;
    FPlus: TTabSheet;        // The "+" tab, always last
    FLast: TTabSheet;        // Tab shown before "+" was clicked
    FList: TFPList;          // of TAccountPage, in tab order
    FErased: TStringList;    // Removed with "erase settings"
    FBackends: TStringList;  // Picker entries: '' then display names
    FSnapshot: TTimer;       // Test hook, see the constructor
    procedure SnapshotTick(Sender: TObject);
    procedure AddPage(const a: TAccountInfo; select: boolean);
    function PageOf(sheet: TTabSheet): TAccountPage;
    function HasName(const acct: string): boolean;
    procedure PagesChange(Sender: TObject);
    procedure NickChange(Sender: TObject);
    procedure SysChange(Sender: TObject);
    procedure PassChange(Sender: TObject);
    procedure PassEnter(Sender: TObject);
    procedure PassExit(Sender: TObject);
    procedure UnitClick(Sender: TObject);
    procedure LimitsClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    function Collect(out list: TAccountEditList): boolean;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

const
  NOT_SET_UP = '(not set up)';
  MARGIN = 12;
  ROW = 26;
  NOTE_H = 4 * (ROW - 8);  // Four lines under the credential box
  LIMITS_H = 2 * (ROW + 8) + 3 * (ROW - 8) + 32;  // Two rows, a three-line note, the frame
  // Trndi's factor (BG_CONVERTIONS).
  MGDL_PER_MMOL = 18.0182;
  // What a tick in an empty pair starts from: the usual 70-180 mg/dL.
  DEFAULT_LO = 70;
  DEFAULT_HI = 180;
  NOTE_LIMITS = 'Unticked, the backend''s own limits apply. Dexcom Share '
    + 'sends none: without limits set here or in Trndi, every value up to '
    + '400 mg/dL shows as in range.';
  // Shown under the credential of a backend that only Trndi can log in to.
  // Markdown, with a link to the guide that walks through that login.
  NOTE_TRNDI_LOGIN = 'The token is captured and renewed by [Trndi''s browser '
    + 'login](https://github.com/slicke/trndi/blob/main/guides/CareLink.md), '
    + 'so this account is set up, and logged in again when it expires, in '
    + 'Trndi. Let one program poll it at a time: every refresh revokes the '
    + 'previous token, so Trndi and trndi-multi on the same account log '
    + 'each other out.';

// A limit in mg/dL as the box shows it: one decimal in mmol/L, whole in
// mg/dL. 0 (not set) is an empty box.
function LimitText(mgdl: integer; mmol: boolean): string;
begin
  if mgdl <= 0 then
    Result := ''
  else if mmol then
    Result := FormatFloat('0.0', mgdl / MGDL_PER_MMOL)
  else
    Result := IntToStr(mgdl);
end;

// A box back to mg/dL; either decimal mark is taken. 0 when it is not a
// number.
function LimitValue(const text: string; mmol: boolean): integer;
var
  fs: TFormatSettings;
  v: double;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  if not TryStrToFloat(StringReplace(Trim(text), ',', '.', []), v, fs) then
    exit(0);
  if mmol then
    v := v * MGDL_PER_MMOL;
  Result := Max(0, Round(v));
end;

function EditAccounts(owner: TComponent): boolean;
var
  f: TfAccounts;
begin
  f := TfAccounts.Create(owner);
  try
    Result := f.ShowModal = mrOk;
  finally
    f.Free;
  end;
end;

constructor TfAccounts.Create(AOwner: TComponent);
var
  accounts: TAccountList;
  i: integer;
  btnSave, btnCancel: TButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'Trndi accounts';
  Width := 520;
  Height := 490 + LIMITS_H + 34;
  Constraints.MinWidth := 440;
  Constraints.MinHeight := 430 + LIMITS_H + 34;
  Position := poOwnerFormCenter;
  BorderStyle := bsSizeable;

  FList := TFPList.Create;
  FErased := TStringList.Create;
  FErased.CaseSensitive := false;
  // The picker: no backend first (the account gets no tile), then Trndi's
  // list; the debug build shows the synthetic backends as Trndi's does.
  FBackends := TStringList.Create;
  FBackends.Add(NOT_SET_UP);
  ListBackendNames(FBackends, {$IFDEF DEBUG}true{$ELSE}false{$ENDIF});

  btnCancel := TButton.Create(Self);
  btnCancel.Parent := Self;
  btnCancel.Caption := 'Cancel';
  btnCancel.Cancel := true;
  btnCancel.ModalResult := mrCancel;
  btnCancel.AutoSize := true;
  btnCancel.Anchors := [akRight, akBottom];
  btnCancel.Left := ClientWidth - MARGIN - btnCancel.Width;
  btnCancel.Top := ClientHeight - MARGIN - btnCancel.Height;

  btnSave := TButton.Create(Self);
  btnSave.Parent := Self;
  btnSave.Caption := 'Save';
  btnSave.Default := true;
  btnSave.OnClick := @SaveClick;
  btnSave.AutoSize := true;
  btnSave.Anchors := [akRight, akBottom];
  btnSave.Left := btnCancel.Left - 8 - btnSave.Width;
  btnSave.Top := btnCancel.Top;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.SetBounds(MARGIN, MARGIN, ClientWidth - 2 * MARGIN,
    btnSave.Top - 2 * MARGIN);
  FPages.Anchors := [akLeft, akTop, akRight, akBottom];
  FPages.OnChange := @PagesChange;

  // Every stored account, the default first, as ListAccounts orders them;
  // here the unconfigured ones show too, since this is where to configure
  // them.
  accounts := ListAccounts;
  for i := 0 to High(accounts) do
    AddPage(accounts[i], false);

  FPlus := FPages.AddTabSheet;
  FPlus.Caption := ' + ';
  FPages.ActivePageIndex := 0;
  FLast := FPages.ActivePage;

  // Under the snapshot test hook (see umulti) there is nobody to click:
  // render this window beside the wall's snapshot and cancel.
  if GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT') <> '' then
  begin
    FSnapshot := TTimer.Create(Self);
    FSnapshot.Interval := 2000;
    FSnapshot.OnTimer := @SnapshotTick;
    FSnapshot.Enabled := true;
  end;
end;

procedure TfAccounts.SnapshotTick(Sender: TObject);
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
        GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT'), '.accounts.png'));
    finally
      png.Free;
    end;
  finally
    img.Free;
  end;
  ModalResult := mrCancel;
end;

destructor TfAccounts.Destroy;
var
  i: integer;
begin
  for i := 0 to FList.Count - 1 do
    TObject(FList[i]).Free;
  FList.Free;
  FErased.Free;
  FBackends.Free;
  inherited Destroy;
end;

function TfAccounts.PageOf(sheet: TTabSheet): TAccountPage;
var
  i: integer;
begin
  for i := 0 to FList.Count - 1 do
    if TAccountPage(FList[i]).sheet = sheet then
      exit(TAccountPage(FList[i]));
  Result := nil;
end;

function TfAccounts.HasName(const acct: string): boolean;
var
  i: integer;
begin
  for i := 0 to FList.Count - 1 do
    if SameText(TAccountPage(FList[i]).info.name, acct) then
      exit(true);
  Result := false;
end;

// A tab: labelled boxes stacked top to bottom, stretched to the tab's
// width. The "+" tab, when it exists, stays last.
procedure TfAccounts.AddPage(const a: TAccountInfo; select: boolean);
var
  pg: TAccountPage;
  y, w: integer;
  ix: integer;

  function AddLabel(const text: string): TLabel;
  begin
    Result := TLabel.Create(Self);
    Result.Parent := pg.sheet;
    Result.Caption := text;
    Result.SetBounds(MARGIN, y, w, ROW - 8);
    Inc(y, ROW - 6);
  end;

  // One row of the limits box: the tick, then "Low" and "High" boxes.
  function AddLimitRow(line: integer; const text: string;
    out edLo, edHi: TEdit): TCheckBox;
  var
    top, x: integer;

    function Box(const lab: string): TEdit;
    var
      lb: TLabel;
    begin
      lb := TLabel.Create(Self);
      lb.Parent := pg.gbLimits;
      lb.Caption := lab;
      lb.SetBounds(x, top + 4, 36, ROW - 8);
      Inc(x, 38);
      Result := TEdit.Create(Self);
      Result.Parent := pg.gbLimits;
      Result.SetBounds(x, top, 64, ROW);
      Inc(x, 64 + 14);
    end;

  begin
    top := 4 + line * (ROW + 8);
    Result := TCheckBox.Create(Self);
    Result.Parent := pg.gbLimits;
    Result.Caption := text;
    Result.SetBounds(8, top + 2, 170, ROW - 4);
    x := 186;
    edLo := Box('Low');
    edHi := Box('High');
  end;

  function AddEdit: TEdit;
  begin
    Result := TEdit.Create(Self);
    Result.Parent := pg.sheet;
    Result.SetBounds(MARGIN, y, w, ROW);
    Result.Anchors := [akLeft, akTop, akRight];
    Inc(y, ROW + 10);
  end;

begin
  pg := TAccountPage.Create;
  pg.info := a;
  pg.sheet := FPages.AddTabSheet;
  if FPlus <> nil then
    pg.sheet.PageIndex := FPlus.PageIndex;
  FList.Add(pg);

  w := FPages.ClientWidth - 2 * MARGIN - 8;
  y := MARGIN;

  AddLabel('Nickname (shown on the tile)');
  pg.edNick := AddEdit;
  pg.edNick.Text := a.nick;
  pg.edNick.OnChange := @NickChange;

  AddLabel('System');
  pg.cbSys := TComboBox.Create(Self);
  pg.cbSys.Parent := pg.sheet;
  pg.cbSys.Style := csDropDownList;
  pg.cbSys.Items.Assign(FBackends);
  pg.cbSys.SetBounds(MARGIN, y, w, ROW);
  pg.cbSys.Anchors := [akLeft, akTop, akRight];
  Inc(y, ROW + 10);
  if a.backend = '' then
    ix := 0
  else if BackendExists(a.backend) then
    ix := pg.cbSys.Items.IndexOf(BackendDisplayName(a.backend))
  else
    // A code this build cannot resolve (a debug backend in a release
    // build, or one Trndi has since renamed) is kept as it is rather than
    // silently swapped for something else.
    ix := pg.cbSys.Items.Add(a.backend);
  pg.cbSys.ItemIndex := ix;
  pg.cbSys.OnChange := @SysChange;

  pg.lbUser := AddLabel('User');
  pg.edUser := AddEdit;
  pg.edUser.Text := a.target;

  pg.lbPass := AddLabel('Password');
  pg.edPass := AddEdit;
  pg.edPass.Text := a.creds;
  pg.edPass.PasswordChar := '*';
  pg.edPass.OnEnter := @PassEnter;
  pg.edPass.OnExit := @PassExit;
  pg.edPass.OnChange := @PassChange;
  pg.credsEdited := false;

  // Room for a note under the credential; SysChange fills it for a backend
  // that only Trndi can log in to (CareLink) and blanks it for the rest.
  pg.lbNote := TMarkdownPane.Create(Self);
  pg.lbNote.Parent := pg.sheet;
  pg.lbNote.SetTheme(clBtnFace, clGrayText, 12);
  pg.lbNote.SetBounds(MARGIN, y, w, NOTE_H);
  pg.lbNote.Anchors := [akLeft, akTop, akRight];
  Inc(y, NOTE_H + 6);

  pg.rgUnit := TRadioGroup.Create(Self);
  pg.rgUnit.Parent := pg.sheet;
  pg.rgUnit.Caption := 'Unit';
  pg.rgUnit.Columns := 2;
  pg.rgUnit.Items.Add('mmol/L');
  pg.rgUnit.Items.Add('mg/dL');
  pg.rgUnit.ItemIndex := Ord(not a.mmol);
  pg.rgUnit.SetBounds(MARGIN, y, w, 2 * ROW);
  pg.rgUnit.Anchors := [akLeft, akTop, akRight];
  pg.rgUnit.OnClick := @UnitClick;
  Inc(y, 2 * ROW + 10);

  // The limits: a tick and a low/high pair per row, in the tab's unit.
  pg.limitsMmol := a.mmol;
  pg.gbLimits := TGroupBox.Create(Self);
  pg.gbLimits.Parent := pg.sheet;
  pg.gbLimits.SetBounds(MARGIN, y, w, LIMITS_H);
  pg.gbLimits.Anchors := [akLeft, akTop, akRight];
  pg.gbLimits.Caption := 'Limits';
  pg.cbLimits := AddLimitRow(0, 'High and low limits', pg.edLo, pg.edHi);
  pg.cbLimits.Checked := a.ovrOn;
  pg.edLo.Text := LimitText(a.ovrLo, a.mmol);
  pg.edHi.Text := LimitText(a.ovrHi, a.mmol);
  pg.cbRange := AddLimitRow(1, 'Target range', pg.edRangeLo, pg.edRangeHi);
  pg.cbRange.Checked := a.ovrRangeOn;
  pg.edRangeLo.Text := LimitText(a.ovrRangeLo, a.mmol);
  pg.edRangeHi.Text := LimitText(a.ovrRangeHi, a.mmol);
  pg.lbLimitsNote := TLabel.Create(Self);
  pg.lbLimitsNote.Parent := pg.gbLimits;
  pg.lbLimitsNote.WordWrap := true;
  pg.lbLimitsNote.AutoSize := false;
  pg.lbLimitsNote.Font.Color := clGrayText;
  pg.lbLimitsNote.Caption := NOTE_LIMITS;
  pg.lbLimitsNote.SetBounds(8, 2 * (ROW + 8) + 4, pg.gbLimits.ClientWidth - 16,
    3 * (ROW - 8));
  pg.lbLimitsNote.Anchors := [akLeft, akTop, akRight];
  pg.cbLimits.OnClick := @LimitsClick;
  pg.cbRange.OnClick := @LimitsClick;
  Inc(y, LIMITS_H + 10);

  pg.btnRemove := TButton.Create(Self);
  pg.btnRemove.Parent := pg.sheet;
  pg.btnRemove.Caption := 'Remove account';
  pg.btnRemove.AutoSize := true;
  pg.btnRemove.Left := MARGIN;
  pg.btnRemove.Top := y;
  pg.btnRemove.OnClick := @RemoveClick;
  // The default account is the unprefixed keys; Trndi has no way to remove
  // it either.
  pg.btnRemove.Enabled := a.name <> '';

  SysChange(pg.cbSys);
  NickChange(pg.edNick);
  LimitsClick(pg.cbLimits);
  if select then
    FPages.ActivePage := pg.sheet;
end;

// Clicking "+" asks for the name, then turns into a real tab in front of
// itself; cancelling goes back to the tab that was showing.
procedure TfAccounts.PagesChange(Sender: TObject);
var
  acct, why: string;
  i: integer;
begin
  if FPages.ActivePage <> FPlus then
  begin
    FLast := FPages.ActivePage;
    exit;
  end;
  FPages.ActivePage := FLast;
  acct := Trim(InputBox('New account',
    'Account name (this cannot be changed later; the nickname can):', ''));
  if acct = '' then
    exit;
  if not AccountNameValid(acct, why) then
  begin
    MessageDlg(why, mtError, [mbOK], 0);
    exit;
  end;
  if HasName(acct) then
  begin
    MessageDlg('There is already an account called ' + acct + '.',
      mtError, [mbOK], 0);
    exit;
  end;
  // Adding a name back cancels an erase from this session, and shows
  // whatever the store still holds for it.
  i := FErased.IndexOf(acct);
  if i >= 0 then
    FErased.Delete(i);
  AddPage(ReadStoredAccount(acct), true);
end;

procedure TfAccounts.NickChange(Sender: TObject);
var
  pg: TAccountPage;
begin
  pg := PageOf(TControl(Sender).Parent as TTabSheet);
  if pg = nil then
    exit;
  pg.info.nick := Trim(pg.edNick.Text);
  pg.sheet.Caption := AccountLabel(pg.info);
end;

// The user and password boxes mean different things per backend: a site
// and an API secret for Nightscout, an e-mail and password for Libre and
// Tandem, a captured token for CareLink. The backend class says which.
procedure TfAccounts.SysChange(Sender: TObject);
var
  pg: TAccountPage;
  cls: TrndiAPIClass;
  configured, webLogin: boolean;
  delta: integer;

  procedure Shift(c: TControl);
  begin
    c.Top := c.Top + delta;
  end;

begin
  pg := PageOf(TControl(Sender).Parent as TTabSheet);
  if pg = nil then
    exit;
  configured := pg.cbSys.ItemIndex > 0;
  cls := nil;
  if configured then
    cls := BackendClassOf(pg.cbSys.Text);
  if cls <> nil then
  begin
    pg.lbUser.Caption := cls.ParamLabel(APLUser);
    pg.lbPass.Caption := cls.ParamLabel(APLPass);
  end
  else
  begin
    pg.lbUser.Caption := 'User';
    pg.lbPass.Caption := 'Password';
  end;
  pg.edUser.Enabled := configured;
  pg.edPass.Enabled := configured;
  // A web-login backend's login is the token Trndi's browser flow captured
  // and the username it carries. Nothing typed here could replace either,
  // and an accidental edit would overwrite a working login on Save, so both
  // rows are hidden (Trndi's own settings window hides the username too)
  // and the note takes their place. The hidden boxes keep their values:
  // Save reads the target from one and, only if typed in, the credential
  // from the other, so a hidden pair is stored back as it was.
  webLogin := (cls <> nil) and cls.supportsWebLogin;
  if webLogin then
    pg.lbNote.Load(NOTE_TRNDI_LOGIN)
  else
    pg.lbNote.Load('');
  // Trndi stores a placeholder target so one is always present; keep the
  // store alike (the login flow overwrites it with the real name).
  if webLogin and (Trim(pg.edUser.Text) = '') then
    pg.edUser.Text := 'carelink';
  if webLogin <> pg.loginHidden then
  begin
    delta := pg.lbNote.Top - pg.lbUser.Top;
    if webLogin then
      delta := -delta;
    Shift(pg.lbNote);
    Shift(pg.rgUnit);
    Shift(pg.gbLimits);
    Shift(pg.btnRemove);
    pg.loginHidden := webLogin;
  end;
  pg.lbUser.Visible := not webLogin;
  pg.edUser.Visible := not webLogin;
  pg.lbPass.Visible := not webLogin;
  pg.edPass.Visible := not webLogin;
end;

// The limit boxes follow the unit: what is typed is converted, not cleared.
procedure TfAccounts.UnitClick(Sender: TObject);
var
  pg: TAccountPage;
  mmol: boolean;

  procedure Convert(ed: TEdit);
  begin
    ed.Text := LimitText(LimitValue(ed.Text, pg.limitsMmol), mmol);
  end;

begin
  pg := PageOf(TControl(Sender).Parent as TTabSheet);
  if pg = nil then
    exit;
  mmol := pg.rgUnit.ItemIndex = 0;
  if mmol = pg.limitsMmol then
    exit;
  Convert(pg.edLo);
  Convert(pg.edHi);
  Convert(pg.edRangeLo);
  Convert(pg.edRangeHi);
  pg.limitsMmol := mmol;
end;

// A ticked pair can be edited; ticking an empty one fills it from the
// setup wizard's suggestion, or 70-180 mg/dL, and an empty target range
// from the limits, as Trndi's settings window starts it.
procedure TfAccounts.LimitsClick(Sender: TObject);
var
  pg: TAccountPage;
  lo, hi: integer;
begin
  pg := PageOf((TControl(Sender).Parent as TGroupBox).Parent as TTabSheet);
  if pg = nil then
    exit;
  if pg.cbLimits.Checked and (Trim(pg.edLo.Text) = '') and
    (Trim(pg.edHi.Text) = '') then
  begin
    lo := DEFAULT_LO;
    hi := DEFAULT_HI;
    if (pg.info.wizLo > 0) and (pg.info.wizHi > pg.info.wizLo) then
    begin
      lo := pg.info.wizLo;
      hi := pg.info.wizHi;
    end;
    pg.edLo.Text := LimitText(lo, pg.limitsMmol);
    pg.edHi.Text := LimitText(hi, pg.limitsMmol);
  end;
  if pg.cbRange.Checked and (Trim(pg.edRangeLo.Text) = '') and
    (Trim(pg.edRangeHi.Text) = '') then
  begin
    lo := LimitValue(pg.edLo.Text, pg.limitsMmol);
    hi := LimitValue(pg.edHi.Text, pg.limitsMmol);
    if (lo <= 0) or (hi <= lo) then
    begin
      lo := DEFAULT_LO;
      hi := DEFAULT_HI;
    end;
    pg.edRangeLo.Text := LimitText(lo, pg.limitsMmol);
    pg.edRangeHi.Text := LimitText(hi, pg.limitsMmol);
  end;
  pg.edLo.Enabled := pg.cbLimits.Checked;
  pg.edHi.Enabled := pg.cbLimits.Checked;
  pg.edRangeLo.Enabled := pg.cbRange.Checked;
  pg.edRangeHi.Enabled := pg.cbRange.Checked;
end;

procedure TfAccounts.PassChange(Sender: TObject);
var
  pg: TAccountPage;
begin
  pg := PageOf(TControl(Sender).Parent as TTabSheet);
  if pg <> nil then
    pg.credsEdited := true;
end;

// Masked except while being typed in, as Trndi's own box is.
procedure TfAccounts.PassEnter(Sender: TObject);
begin
  TEdit(Sender).PasswordChar := #0;
end;

procedure TfAccounts.PassExit(Sender: TObject);
begin
  TEdit(Sender).PasswordChar := '*';
end;

// Two questions, as Trndi asks them: remove, and then also erase the
// stored settings. Neither touches the store until Save.
procedure TfAccounts.RemoveClick(Sender: TObject);
var
  pg: TAccountPage;
  acct: string;
  i: integer;
begin
  pg := PageOf(TControl(Sender).Parent as TTabSheet);
  if (pg = nil) or (pg.info.name = '') then
    exit;
  acct := pg.info.name;
  if MessageDlg('Remove the account ' + acct + '?', mtConfirmation,
    [mbYes, mbNo], 0) <> mrYes then
    exit;
  if MessageDlg('Also erase its stored settings (backend, login, nickname)?'
    + LineEnding + LineEnding +
    'If you keep them, adding an account with the same name brings them back.',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    if FErased.IndexOf(acct) < 0 then
      FErased.Add(acct);
  FList.Remove(pg);
  // The default tab is index 0 and cannot be removed, so there is always
  // a tab before this one to fall back to.
  i := pg.sheet.PageIndex;
  pg.sheet.Free;
  pg.Free;
  FPages.ActivePageIndex := Max(0, i - 1);
  FLast := FPages.ActivePage;
end;

const
  // A sensor reads 40-400 mg/dL; a limit outside 20-600 is a typo.
  PAIR_MIN = 20;
  PAIR_MAX = 600;
  PAIR_RULE = 'need a low below the high, both between 1.1 and 33.3 mmol/L '
    + '(20 and 600 mg/dL).';

function PairValid(lo, hi: integer): boolean;
begin
  Result := (lo >= PAIR_MIN) and (hi <= PAIR_MAX) and (lo < hi);
end;

// Everything on the tabs as a list, checked the way Trndi checks a
// backend's fields before saving. False leaves the offending tab showing.
function TfAccounts.Collect(out list: TAccountEditList): boolean;
var
  i: integer;
  pg: TAccountPage;
  code: string;
  problem: string;
begin
  Result := false;
  list := nil;
  SetLength(list, FList.Count);
  for i := 0 to FList.Count - 1 do
  begin
    pg := TAccountPage(FList[i]);
    list[i].info := pg.info;
    list[i].info.nick := Trim(pg.edNick.Text);
    if pg.cbSys.ItemIndex <= 0 then
      code := ''
    else if BackendExists(pg.cbSys.Text) then
      code := BackendCode(pg.cbSys.Text)
    else
      code := pg.cbSys.Text;   // The unresolvable code, kept as loaded
    list[i].info.backend := code;
    list[i].info.target := Trim(pg.edUser.Text);
    list[i].info.creds := pg.edPass.Text;
    list[i].info.mmol := pg.rgUnit.ItemIndex = 0;
    list[i].credsEdited := pg.credsEdited;
    list[i].info.ovrOn := pg.cbLimits.Checked;
    list[i].info.ovrLo := LimitValue(pg.edLo.Text, pg.limitsMmol);
    list[i].info.ovrHi := LimitValue(pg.edHi.Text, pg.limitsMmol);
    list[i].info.ovrRangeOn := pg.cbRange.Checked;
    list[i].info.ovrRangeLo := LimitValue(pg.edRangeLo.Text, pg.limitsMmol);
    list[i].info.ovrRangeHi := LimitValue(pg.edRangeHi.Text, pg.limitsMmol);

    problem := '';
    if list[i].info.ovrOn and not PairValid(list[i].info.ovrLo,
        list[i].info.ovrHi) then
      problem := 'Its high and low limits ' + PAIR_RULE
    else if list[i].info.ovrRangeOn and not PairValid(list[i].info.ovrRangeLo,
        list[i].info.ovrRangeHi) then
      problem := 'Its target range ' + PAIR_RULE;
    if problem <> '' then
    begin
      FPages.ActivePage := pg.sheet;
      MessageDlg(AccountLabel(list[i].info) + ': ' + problem, mtError,
        [mbOK], 0);
      exit;
    end;
    if code <> '' then
      case CheckBackendCredentials(code, list[i].info.target,
          list[i].info.creds) of
        bceAddress:
          problem := 'needs a site address starting with http:// or https://.';
        bceEmail:
          problem := 'needs an e-mail address as the user.';
        bcePassword:
          problem := 'needs a password of at least five characters.';
        bceToken:
          problem := 'has no login token. Set the account up in Trndi, '
            + 'whose browser login captures it; it then appears here.';
      end;
    if problem <> '' then
    begin
      FPages.ActivePage := pg.sheet;
      MessageDlg(AccountLabel(list[i].info) + ': ' + pg.cbSys.Text + ' ' +
        problem, mtError, [mbOK], 0);
      exit;
    end;
  end;
  Result := true;
end;

procedure TfAccounts.SaveClick(Sender: TObject);
var
  list: TAccountEditList;
begin
  if not Collect(list) then
    exit;
  SaveAccounts(list, FErased.ToStringArray);
  ModalResult := mrOk;
end;

end.
