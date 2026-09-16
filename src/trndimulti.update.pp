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
  The update check: is there a newer trndi-multi build on GitHub?

  Modelled on Trndi's TUpdateCheckThread. The HTTPS call to the releases
  API and the JSON comparison run on a worker thread, since the transport
  is synchronous and the first paint must not wait for the network; only
  the dialog runs on the main thread. The comparison follows Trndi's
  HasNewerRelease, against this program's own build metadata: a release is
  newer when its build-<N> is above ours, or, for a dev or PR build with no
  number, when it was published after this binary was built. (Trndi's
  helper itself is not used: it lives in trndi.funcs, which drags the whole
  Trndi dialog stack into a debug build.)

  Runs once shortly after start, unless the user chose "remind me later"
  less than two weeks ago; that choice is kept at the root of Trndi's
  store as trndi-multi.update.ignore, next to the terms acceptance, since a
  wall's update is not any one account's business. The menu's manual check
  ignores the snooze and always answers, including "up to date". A kiosk
  never checks: there is nobody at a wall display to click a dialog away.
}
unit trndimulti.update;

{$mode objfpc}{$H+}

interface

uses
Classes;

{** Start a check in the background. @param(manual True from the menu: report
    "up to date" and failures too, and ignore the snooze.) A check already in
    flight is left alone. }
procedure CheckForUpdates(manual: boolean);

{** Tell a check still in flight that the window is gone, so its result is
    dropped instead of shown. The thread then frees itself. }
procedure AbandonUpdateCheck;

{** The build for display: "build 123", "PR build PR-4" or "development build". }
function BuildLabel: string;

{** True when this binary came out of CI for a pull request. }
function IsPRBuild: boolean;

{** Judge a GitHub release (the /releases/latest object, or an array of
    releases, newest first) against this build. Pure; exposed for testing.
    @param(name The winning release's display name)
    @param(url Its page, or empty when none is newer) }
function NewerRelease(const json: string; out name, url: string): boolean; overload;
{** As above, with the release's notes (its body, Markdown) too. }
function NewerRelease(const json: string; out name, url, notes: string): boolean; overload;

{** When this binary was built, in local time: CI's BUILD_DATE, or the
    compile stamp of a local build (see @link(LocalBuildStamp)). }
function BuildDateTime: TDateTime;

var
  {** A local build's compile date and time, 'yyyy/mm/dd hh:mm:ss', set by
      the program file: that is the one unit recompiled on every build, so
      its stamp is the binary's. A stamp taken in this unit would stand
      still until this unit changed, and a release published the same day
      would look newer than a dev build made after it. }
  LocalBuildStamp: string = '';

implementation

uses
SysUtils, DateUtils, Forms, Controls, StdCtrls, Graphics, Dialogs, LCLIntf,
fpjson, jsonparser, trndimulti.buildinfo, trndi.native, trndimulti.accounts,
trndimulti.markdown;

const
  RELEASES_API = 'https://api.github.com/repos/slicke/trndi-multi/releases/latest';
  RELEASES_PAGE = 'https://github.com/slicke/trndi-multi/releases/latest';
  SNOOZE_KEY = 'trndi-multi.update.ignore';
  SNOOZE_DAYS = 14;

type
  TUpdateCheckThread = class(TThread)
  private
    FManual: boolean;
    FFetchOK: boolean;
    FResponse: string;
    FHasNewer: boolean;
    FReleaseName: string;
    FNotes: string;
    FLatestName: string;
    FDownloadURL: string;
    procedure ApplyResult;
  protected
    procedure Execute; override;
  public
    constructor Create(manual: boolean);
  end;

var
  // The one check in flight, or nil. Main thread only.
  Current: TUpdateCheckThread = nil;
  // Set by AbandonUpdateCheck: the result has nowhere to go.
  Abandoned: boolean = false;

{------------------------------------------------------------------------------
  Build identity
 ------------------------------------------------------------------------------}

function IsPRBuild: boolean;
begin
  Result := CI and (Copy(BUILD_NUMBER, 1, 3) = 'PR-');
end;

// BUILD_NUMBER is a compile-time constant, so one branch is always dead in
// any given build; both are needed.
{$PUSH}{$WARN 6018 OFF}
function BuildLabel: string;
begin
  if IsPRBuild then
    Result := 'PR build ' + BUILD_NUMBER
  else if BUILD_NUMBER = 'dev' then
    Result := 'development build'
  else
    Result := 'build ' + BUILD_NUMBER;
end;
{$POP}

// 'yyyy-mm-ddThh:nn:ss' (UTC, as GitHub and CI write it) to local time.
function ParseISO(const s: string; out dt: TDateTime): boolean;
var
  y, mo, d, h, mi, se: integer;
begin
  Result := false;
  if Length(s) < 19 then
    exit;
  y := StrToIntDef(Copy(s, 1, 4), -1);
  mo := StrToIntDef(Copy(s, 6, 2), -1);
  d := StrToIntDef(Copy(s, 9, 2), -1);
  h := StrToIntDef(Copy(s, 12, 2), -1);
  mi := StrToIntDef(Copy(s, 15, 2), -1);
  se := StrToIntDef(Copy(s, 18, 2), -1);
  if (y < 0) or (mo < 0) or (d < 0) or (h < 0) or (mi < 0) or (se < 0) then
    exit;
  try
    dt := UniversalTimeToLocal(EncodeDateTime(y, mo, d, h, mi, se, 0));
    Result := true;
  except
    Result := false;
  end;
end;

function BuildDateTime: TDateTime;
var
  s: string;
begin
  if ParseISO(BUILD_DATE, Result) then
    exit;
  // 'yyyy/mm/dd hh:mm:ss' from the program file; the time may be missing
  // if only the date was given, and then the day starts at midnight.
  s := LocalBuildStamp;
  try
    Result := EncodeDate(StrToInt(Copy(s, 1, 4)), StrToInt(Copy(s, 6, 2)),
      StrToInt(Copy(s, 9, 2)));
    if Length(s) >= 19 then
      Result := Result + EncodeTime(StrToInt(Copy(s, 12, 2)),
        StrToInt(Copy(s, 15, 2)), StrToInt(Copy(s, 18, 2)), 0);
  except
    Result := 0;
  end;
end;

{------------------------------------------------------------------------------
  Release comparison
 ------------------------------------------------------------------------------}

// The digits of 'build-123' (or anything else with digits in it).
function DigitsOf(const s: string; out n: int64): boolean;
var
  c: char;
  digits: string;
begin
  digits := '';
  for c in s do
    if c in ['0'..'9'] then
      digits := digits + c;
  Result := (digits <> '') and TryStrToInt64(digits, n);
end;

function NewerRelease(const json: string; out name, url: string): boolean;
var
  notes: string;
begin
  Result := NewerRelease(json, name, url, notes);
end;

function NewerRelease(const json: string; out name, url, notes: string): boolean;
var
  data: TJSONData;
  arr: TJSONArray;
  i: integer;

  function Newer(const rel: TJSONObject): boolean;
  var
    tag: string;
    ours, theirs: int64;
    published: TDateTime;
  begin
    Result := false;
    if rel.Get('prerelease', false) then
      exit;
    tag := rel.Get('tag_name', '');
    if (tag <> '') and (BUILD_TAG <> 'dev') and SameText(tag, BUILD_TAG) then
      exit;
    if TryStrToInt64(BUILD_NUMBER, ours) then
    begin
      // A numbered build against a numbered release: compare the numbers,
      // and let a release without one fall through to the dates.
      if DigitsOf(tag, theirs) or DigitsOf(rel.Get('name', ''), theirs) then
        Exit(theirs > ours);
    end;
    Result := ParseISO(rel.Get('published_at', ''), published) and
      (published > BuildDateTime);
  end;

  procedure Take(const rel: TJSONObject);
  begin
    name := rel.Get('name', rel.Get('tag_name', ''));
    notes := rel.Get('body', '');
    url := rel.Get('html_url', '');
    if url = '' then
      url := RELEASES_PAGE;
  end;

begin
  Result := false;
  name := '';
  url := '';
  notes := '';
  data := nil;
  try
    try
      data := GetJSON(json);
      if data is TJSONObject then
      begin
        Result := Newer(TJSONObject(data));
        if Result then
          Take(TJSONObject(data));
      end
      else if data is TJSONArray then
      begin
        arr := TJSONArray(data);
        for i := 0 to arr.Count - 1 do
          if (arr[i] is TJSONObject) and Newer(TJSONObject(arr[i])) then
          begin
            Take(TJSONObject(arr[i]));
            Exit(true);
          end;
      end;
    except
      Result := false;
    end;
  finally
    data.Free;
  end;
end;

{------------------------------------------------------------------------------
  Snooze
 ------------------------------------------------------------------------------}

// When the user last chose to be reminded later, or 0 if never (or the
// stored value is unreadable, which counts as never rather than forever).
function SnoozedAt: TDateTime;
var
  native: TMultiNative;
  s: string;
begin
  Result := 0;
  native := TMultiNative.Create;
  try
    native.configUser := '';
    s := Trim(native.GetSetting(SNOOZE_KEY, ''));
  finally
    native.Free;
  end;
  if Length(s) < 19 then
    exit;
  try
    Result := ScanDateTime('yyyy-mm-dd"T"hh:nn:ss', Copy(s, 1, 19));
  except
    Result := 0;
  end;
end;

procedure Snooze;
var
  native: TMultiNative;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    native.SetSetting(SNOOZE_KEY, FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
  finally
    native.Free;
  end;
end;

{------------------------------------------------------------------------------
  Entry points
 ------------------------------------------------------------------------------}

procedure CheckForUpdates(manual: boolean);
var
  at: TDateTime;
begin
  if Current <> nil then
    exit;
  if not manual then
  begin
    at := SnoozedAt;
    if (at <> 0) and (DaysBetween(Now, at) < SNOOZE_DAYS) then
      exit;
  end;
  Abandoned := false;
  Current := TUpdateCheckThread.Create(manual);
end;

procedure AbandonUpdateCheck;
begin
  Abandoned := true;
  Current := nil;
end;

{------------------------------------------------------------------------------
  TUpdateCheckThread
 ------------------------------------------------------------------------------}

constructor TUpdateCheckThread.Create(manual: boolean);
begin
  inherited Create(true);
  // Nobody joins this thread: the result is handed over in ApplyResult and
  // the window may be long gone by the time a stalled request returns.
  FreeOnTerminate := true;
  FManual := manual;
  FLatestName := 'unknown';
  Start;
end;

procedure TUpdateCheckThread.Execute;
var
  data: TJSONData;
begin
  try
    FFetchOK := TrndiNative.getURL(RELEASES_API, FResponse);
    if FFetchOK then
    begin
      data := nil;
      try
        data := GetJSON(FResponse);
        if data is TJSONObject then
          FLatestName := TJSONObject(data).Get('name',
            TJSONObject(data).Get('tag_name', 'unknown'));
      except
        FLatestName := 'unknown';
      end;
      data.Free;
      FHasNewer := NewerRelease(FResponse, FReleaseName, FDownloadURL, FNotes);
    end;
  except
    FFetchOK := false;
  end;
  if not (Terminated or Abandoned) then
    Synchronize(@ApplyResult);
end;

{------------------------------------------------------------------------------
  The dialog
 ------------------------------------------------------------------------------}

// The release notes are Markdown (CI writes them as the commit subjects
// since the previous build), so the dialog is a pane rather than a
// message box. The buttons follow Trndi's: download now, not now, or not
// for another fortnight.
function ShowUpdateDialog(const title, md: string): TModalResult;
const
  MARGIN = 12;
var
  f: TForm;
  lbTitle: TLabel;
  pane: TMarkdownPane;
  btnDownload, btnLater, btnSnooze: TButton;
begin
  f := TForm.CreateNew(nil, 0);
  try
    f.Caption := 'Trndi Multi';
    f.Width := 540;
    f.Height := 420;
    f.Constraints.MinWidth := 400;
    f.Constraints.MinHeight := 260;
    f.Position := poScreenCenter;
    f.BorderStyle := bsSizeable;

    lbTitle := TLabel.Create(f);
    lbTitle.Parent := f;
    lbTitle.Font.Style := [fsBold];
    lbTitle.Font.Height := -15;
    lbTitle.WordWrap := true;
    lbTitle.AutoSize := true;
    lbTitle.Anchors := [akLeft, akTop, akRight];
    lbTitle.Left := MARGIN;
    lbTitle.Top := MARGIN;
    lbTitle.Width := f.ClientWidth - 2 * MARGIN;
    lbTitle.Caption := title;

    // Snooze on its own at the left; the two answers together at the right.
    btnSnooze := TButton.Create(f);
    btnSnooze.Parent := f;
    btnSnooze.Caption := 'Remind me in ' + IntToStr(SNOOZE_DAYS) + ' days';
    btnSnooze.ModalResult := mrIgnore;
    btnSnooze.AutoSize := true;
    btnSnooze.Anchors := [akLeft, akBottom];
    btnSnooze.Left := MARGIN;
    btnSnooze.Top := f.ClientHeight - MARGIN - btnSnooze.Height;

    btnDownload := TButton.Create(f);
    btnDownload.Parent := f;
    btnDownload.Caption := 'Download';
    btnDownload.Default := true;
    btnDownload.ModalResult := mrYes;
    btnDownload.AutoSize := true;
    btnDownload.Anchors := [akRight, akBottom];
    btnDownload.Left := f.ClientWidth - MARGIN - btnDownload.Width;
    btnDownload.Top := btnSnooze.Top;

    btnLater := TButton.Create(f);
    btnLater.Parent := f;
    btnLater.Caption := 'Not now';
    btnLater.Cancel := true;
    btnLater.ModalResult := mrNo;
    btnLater.AutoSize := true;
    btnLater.Anchors := [akRight, akBottom];
    btnLater.Left := btnDownload.Left - 8 - btnLater.Width;
    btnLater.Top := btnSnooze.Top;

    pane := TMarkdownPane.Create(f);
    pane.Parent := f;
    pane.SetTheme(clWindow, clWindowText, 14, 'body { padding: 8px 10px; }');
    pane.Load(md);
    pane.Anchors := [akLeft, akTop, akRight, akBottom];
    pane.Left := MARGIN;
    pane.Top := lbTitle.Top + lbTitle.Height + MARGIN;
    pane.Width := f.ClientWidth - 2 * MARGIN;
    pane.Height := btnSnooze.Top - MARGIN - pane.Top;

    Result := f.ShowModal;
  finally
    f.Free;
  end;
end;

// Main thread.
procedure TUpdateCheckThread.ApplyResult;
var
  msg: string;
begin
  if Current = Self then
    Current := nil;
  if Abandoned or Application.Terminated then
    exit;

  if not FFetchOK then
  begin
    if FManual then
      MessageDlg('Trndi Multi', 'Could not check for updates.' + LineEnding +
        'This is a ' + BuildLabel + '.', mtWarning, [mbOK], 0);
    exit;
  end;

  if FHasNewer then
  begin
    msg := 'This is ' + BuildLabel + '.' + LineEnding + LineEnding;
    if IsPRBuild then
      msg := msg + '_This is a pull-request build; the release may be what ' +
        'it was made from._' + LineEnding + LineEnding;
    if Trim(FNotes) <> '' then
      msg := msg + '---' + LineEnding + LineEnding + FNotes;
    case ShowUpdateDialog('A newer build of trndi-multi is available: ' +
      FReleaseName, msg) of
    mrYes:
      OpenURL(FDownloadURL);
    mrIgnore:
      Snooze;
    end;
  end
  else if FManual then
  begin
    msg := 'trndi-multi is up to date.' + LineEnding +
      'This is ' + BuildLabel + '; the latest release is ' + FLatestName + '.';
    // A dev build has no number, so it is judged by its compile date; say
    // so, since "up to date" then only means "built after the release".
    {$PUSH}{$WARN 6018 OFF}
    if (not IsPRBuild) and (BUILD_NUMBER = 'dev') then
      msg := msg + LineEnding + LineEnding +
        'A development build is compared by build date, not build number.';
    {$POP}
    MessageDlg('Trndi Multi', msg, mtInformation, [mbOK], 0);
  end;
end;

end.
