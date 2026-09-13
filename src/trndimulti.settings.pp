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
Dialogs, trndi.api, trndi.api.registry, trndimulti.accounts, Graphics;

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
    lbUser, lbPass, lbNote: TLabel;
    rgUnit: TRadioGroup;
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
    procedure AddPage(const a: TAccountInfo; select: boolean);
    function PageOf(sheet: TTabSheet): TAccountPage;
    function HasName(const acct: string): boolean;
    procedure PagesChange(Sender: TObject);
    procedure NickChange(Sender: TObject);
    procedure SysChange(Sender: TObject);
    procedure PassChange(Sender: TObject);
    procedure PassEnter(Sender: TObject);
    procedure PassExit(Sender: TObject);
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
  // Shown under the credential of a backend that only Trndi can log in to.
  NOTE_TRNDI_LOGIN = 'The token is captured and renewed by Trndi''s browser '
    + 'login, so this account is set up, and logged in again when it '
    + 'expires, in Trndi. Let one program poll it at a time: every refresh '
    + 'revokes the previous token, so Trndi and trndi-multi on the same '
    + 'account log each other out.';

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
  Height := 490;
  Constraints.MinWidth := 400;
  Constraints.MinHeight := 430;
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
  pg.lbNote := TLabel.Create(Self);
  pg.lbNote.Parent := pg.sheet;
  pg.lbNote.AutoSize := false;
  pg.lbNote.WordWrap := true;
  pg.lbNote.Font.Color := clGrayText;
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
  Inc(y, 2 * ROW + 10);

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
    pg.lbNote.Caption := NOTE_TRNDI_LOGIN
  else
    pg.lbNote.Caption := '';
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
    Shift(pg.btnRemove);
    pg.loginHidden := webLogin;
  end;
  pg.lbUser.Visible := not webLogin;
  pg.edUser.Visible := not webLogin;
  pg.lbPass.Visible := not webLogin;
  pg.edPass.Visible := not webLogin;
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

    problem := '';
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
