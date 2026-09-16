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
  The About window: what this binary is, what it is not, and where it
  came from.

  A wall display is often run by someone who did not build it and will be
  asked "which version is that?" when something looks wrong, so the build,
  the toolchain it was made with and the settings file it reads are all
  here in one place, next to the medical disclaimer and the license.
  Rendered as Markdown by the vendored Pixie engine, as the other dialogs
  are.
}
unit trndimulti.about;

{$mode objfpc}{$H+}

interface

uses
Classes;

{** Show the About window modally. @returns(True when the user asked for
    an update check from it: the caller runs the check once this window is
    gone, rather than putting a dialog on top of a dialog.) }
function ShowAbout(owner: TComponent): boolean;

implementation

uses
SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics, InterfaceBase,
LCLPlatformDef, LCLVersion, trndimulti.markdown, trndimulti.accounts,
trndimulti.buildinfo, trndimulti.update;

const
  PROJECT_URL = 'https://github.com/slicke/trndi-multi';
  RELEASES_URL = 'https://github.com/slicke/trndi-multi/releases';
  TRNDI_URL = 'https://github.com/slicke/trndi';
  DISCLAIMER_URL = 'https://github.com/slicke/trndi/blob/main/DISCLAIMER.md';
  GPL_URL = 'https://www.gnu.org/licenses/gpl-3.0.html';
  PIXIE_URL = 'https://gitlab.com/retrofoxed/pixie';

type
  TfAbout = class(TForm)
  private
    FSnapshot: TTimer;
    procedure SnapshotTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); reintroduce;
  end;

// "build 123 · built 2026-09-16 18:01 · a1b2c3d on main", or for a local
// build what little it knows: the label and the compile stamp.
function BuildLine: string;
begin
  Result := BuildLabel;
  if BuildDateTime > 0 then
    Result := Result + ' · built ' +
      FormatDateTime('yyyy-mm-dd hh:nn', BuildDateTime);
  // CI is a compile-time constant, so one branch is always dead.
  {$PUSH}{$WARN 6018 OFF}
  if CI then
    Result := Result + ' · ' + GIT_SHA + ' on ' + GIT_BRANCH;
  {$POP}
end;

// What it was built with and runs on: the first thing to ask about when a
// window misbehaves on one machine and not another.
function ToolchainLine: string;
begin
  Result := 'FPC ' + {$I %FPCVERSION%} + ' · LCL ' + lcl_version;
  if WidgetSet <> nil then
    Result := Result + ' · ' + LCLPlatformDisplayNames[WidgetSet.LCLPlatform];
  Result := Result + ' · ' + {$I %FPCTARGETOS%} + ' ' + {$I %FPCTARGETCPU%};
end;

function AboutText: string;
begin
  // The heading block is one raw HTML line: a blank line inside it would
  // end the block and leave the rest as literal text.
  Result :=
    '<div class="head"><h1>Trndi Multi</h1>' +
    '<p class="sub">Every Trndi account in one window.</p>' +
    '<p class="env">' + BuildLine + '<br>' + ToolchainLine + '</p></div>' +
    LineEnding + LineEnding +
    '> **Not a medical device.** A reading may be delayed, wrong or ' +
    'missing, and a tile that stops updating may not be noticed: this is ' +
    'not an alarm. Verify with the official CGM device before acting on ' +
    'anything here. [Full disclaimer](' + DISCLAIMER_URL + ')' +
    LineEnding + LineEnding +
    'Free software under the [GNU General Public License v3](' + GPL_URL +
    '), with that disclaimer as an additional term. ' +
    '[Source](' + PROJECT_URL + ') · [Releases](' + RELEASES_URL + ')' +
    LineEnding + LineEnding +
    'A companion to [Trndi](' + TRNDI_URL + '), whose API and settings ' +
    'layer it is built on and whose accounts it shows. This window and ' +
    'the reports are rendered with [Pixie](' + PIXIE_URL + '), an ' +
    'HTML engine for Free Pascal (MIT, SoftPerfect).' +
    LineEnding + LineEnding +
    'Settings: `' + SettingsLocation + '`';
end;

constructor TfAbout.Create(AOwner: TComponent);
const
  MARGIN = 12;
var
  pane: TMarkdownPane;
  btnClose, btnUpdate: TButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'About Trndi Multi';
  Width := 540;
  Height := 460;
  Constraints.MinWidth := 400;
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

  // The check itself runs after this window has closed (see ShowAbout).
  btnUpdate := TButton.Create(Self);
  btnUpdate.Parent := Self;
  btnUpdate.Caption := 'Check for updates';
  btnUpdate.ModalResult := mrYes;
  btnUpdate.AutoSize := true;
  btnUpdate.Anchors := [akRight, akBottom];
  btnUpdate.Left := btnClose.Left - 8 - btnUpdate.Width;
  btnUpdate.Top := btnClose.Top;

  // On the window's own background rather than a document's white, so it
  // reads as one surface; the disclaimer is set off by a rule down its
  // side rather than a tint, which would have to know about dark themes.
  pane := TMarkdownPane.Create(Self);
  pane.Parent := Self;
  pane.SetTheme(clBtnFace, clBtnText, 13,
    'h1 { font-size: 1.7em; margin: 0 0 1px; }' +
    '.sub { margin: 0 0 10px; }' +
    '.env { color: ' + CssColor(clGrayText) + '; font-size: 0.85em; ' +
    'line-height: 1.5; margin: 0 0 14px; }' +
    'blockquote { margin: 0 0 12px; padding: 0 0 0 10px; ' +
    'border-left: 3px solid #C43C1E; }' +
    'blockquote p { margin: 0; }');
  pane.Load(AboutText);
  pane.Anchors := [akLeft, akTop, akRight, akBottom];
  pane.Left := MARGIN;
  pane.Top := MARGIN;
  pane.Width := ClientWidth - 2 * MARGIN;
  pane.Height := btnClose.Top - MARGIN - pane.Top;

  // Under the snapshot test hook (see umulti) there is nobody to click.
  if GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT') <> '' then
  begin
    FSnapshot := TTimer.Create(Self);
    FSnapshot.Interval := 2000;
    FSnapshot.OnTimer := @SnapshotTick;
    FSnapshot.Enabled := true;
  end;
end;

procedure TfAbout.SnapshotTick(Sender: TObject);
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
        GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT'), '.about.png'));
    finally
      png.Free;
    end;
  finally
    img.Free;
  end;
  ModalResult := mrCancel;
end;

function ShowAbout(owner: TComponent): boolean;
var
  f: TfAbout;
begin
  f := TfAbout.Create(owner);
  try
    Result := f.ShowModal = mrYes;
  finally
    f.Free;
  end;
end;

end.
