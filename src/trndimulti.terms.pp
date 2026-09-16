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
  The medical disclaimer, accepted once per install before any reading is
  shown: the same gate Trndi puts up on its first run.

  Trndi stores its acceptance as license.<date> in the account scope, so
  each account's user accepts for themselves. That does not carry over:
  the person at a wall display is usually not the person whose account is
  on it, and an account added in this program's own Accounts window has
  never been through Trndi's gate at all. So this program keeps one key of
  its own at the root of the same store, trndi-multi.<date>, covering the
  wall as a whole. The date is bumped whenever the terms change materially,
  so everyone re-accepts what they are actually agreeing to.
}
unit trndimulti.terms;

{$mode objfpc}{$H+}

interface

{** True once the terms have been accepted, showing the dialog first if
    they have not. False means the user declined: the caller quits without
    showing a reading. }
function TermsAccepted: boolean;

implementation

uses
Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics, LCLIntf,
trndimulti.accounts;

const
  // Trndi's currentTerms, kept in step: 260804 added the warning that
  // alerts are not an alarm system (see Trndi's DISCLAIMER.md).
  CURRENT_TERMS = '260804';
  // Every date this program has ever shipped, newest last, so a returning
  // user is told the terms changed rather than shown a first-run gate.
  // Empty until the first bump.
  PRIOR_TERMS: array of string = nil;
  KEY_PREFIX = 'trndi-multi.';
  DISCLAIMER_URL = 'https://github.com/slicke/trndi/blob/main/DISCLAIMER.md';

  TERMS_TEXT =
    'This program is NOT a medical device.' + LineEnding +
    '• Do NOT make medical decisions based on this data' + LineEnding +
    '• Data may be WRONG, delayed, or unavailable' + LineEnding +
    '• A tile that stops updating may not be noticed — trndi-multi is NOT an alarm' + LineEnding +
    '• Always verify with the official CGM device' + LineEnding +
    '• For emergencies, contact medical professionals' + LineEnding + LineEnding +
    'By continuing, you acknowledge that:' + LineEnding +
    '• You use this program at your own risk' + LineEnding +
    '• The developers have NO LIABILITY' + LineEnding +
    '• You have read and agree to the full terms' + LineEnding + LineEnding +
    'trndi-multi and Trndi are free software under the GNU General Public ' +
    'License v3, with the medical disclaimer above as an additional term.';

type
  TfTerms = class(TForm)
  private
    FSnapshot: TTimer;
    procedure ReadClick(Sender: TObject);
    procedure SnapshotTick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent; termsChanged: boolean); reintroduce;
  end;

constructor TfTerms.Create(AOwner: TComponent; termsChanged: boolean);
const
  MARGIN = 12;
var
  lbTitle, lbQuestion: TLabel;
  memo: TMemo;
  btnAgree, btnRead, btnQuit: TButton;
begin
  inherited CreateNew(AOwner, 0);
  Caption := 'Trndi Multi';
  Width := 560;
  Height := 480;
  Constraints.MinWidth := 420;
  Constraints.MinHeight := 360;
  Position := poScreenCenter;
  BorderStyle := bsSizeable;

  lbTitle := TLabel.Create(Self);
  lbTitle.Parent := Self;
  lbTitle.Font.Style := [fsBold];
  lbTitle.Font.Height := -16;
  lbTitle.Font.Color := RGBToColor($C4, $3C, $1E);
  lbTitle.WordWrap := true;
  lbTitle.AutoSize := true;
  lbTitle.Anchors := [akLeft, akTop, akRight];
  lbTitle.Left := MARGIN;
  lbTitle.Top := MARGIN;
  lbTitle.Width := ClientWidth - 2 * MARGIN;
  if termsChanged then
    lbTitle.Caption := 'The medical disclaimer has been updated'
  else
    lbTitle.Caption := '⚠ Important medical warning';

  // Quit on its own at the left, the two ways of going on together at the
  // right, so a mis-click next to Agree never quits.
  btnQuit := TButton.Create(Self);
  btnQuit.Parent := Self;
  btnQuit.Caption := 'Quit';
  btnQuit.Cancel := true;
  btnQuit.ModalResult := mrCancel;
  btnQuit.AutoSize := true;
  btnQuit.Anchors := [akLeft, akBottom];
  btnQuit.Left := MARGIN;
  btnQuit.Top := ClientHeight - MARGIN - btnQuit.Height;

  btnAgree := TButton.Create(Self);
  btnAgree.Parent := Self;
  btnAgree.Caption := 'I agree';
  btnAgree.Default := true;
  btnAgree.ModalResult := mrYes;
  btnAgree.AutoSize := true;
  btnAgree.Anchors := [akRight, akBottom];
  btnAgree.Left := ClientWidth - MARGIN - btnAgree.Width;
  btnAgree.Top := btnQuit.Top;

  btnRead := TButton.Create(Self);
  btnRead.Parent := Self;
  btnRead.Caption := 'Read the full terms...';
  btnRead.OnClick := @ReadClick;
  btnRead.AutoSize := true;
  btnRead.Anchors := [akRight, akBottom];
  btnRead.Left := btnAgree.Left - 8 - btnRead.Width;
  btnRead.Top := btnQuit.Top;

  lbQuestion := TLabel.Create(Self);
  lbQuestion.Parent := Self;
  lbQuestion.WordWrap := true;
  lbQuestion.AutoSize := true;
  lbQuestion.Anchors := [akLeft, akRight, akBottom];
  lbQuestion.Left := MARGIN;
  lbQuestion.Width := ClientWidth - 2 * MARGIN;
  if termsChanged then
    lbQuestion.Caption := 'You accepted an earlier version. Do you agree ' +
      'to the updated terms?'
  else
    lbQuestion.Caption := 'Do you agree to the terms and the full license?';
  lbQuestion.Top := btnQuit.Top - MARGIN - lbQuestion.Height;

  memo := TMemo.Create(Self);
  memo.Parent := Self;
  memo.ReadOnly := true;
  memo.WordWrap := true;
  memo.ScrollBars := ssAutoVertical;
  memo.Color := clWhite;
  memo.Font.Color := RGBToColor($A9, $11, $34);
  memo.Font.Height := -14;
  memo.Text := TERMS_TEXT;
  memo.Anchors := [akLeft, akTop, akRight, akBottom];
  memo.Left := MARGIN;
  memo.Top := lbTitle.Top + lbTitle.Height + MARGIN;
  memo.Width := ClientWidth - 2 * MARGIN;
  memo.Height := lbQuestion.Top - MARGIN - memo.Top;

  // Under the snapshot test hook (see umulti) there is nobody to click:
  // render this dialog beside the window's snapshot and accept, so the
  // accept path runs too.
  if GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT') <> '' then
  begin
    FSnapshot := TTimer.Create(Self);
    FSnapshot.Interval := 2000;
    FSnapshot.OnTimer := @SnapshotTick;
    FSnapshot.Enabled := true;
  end;
end;

// "Read" on a medical-warning gate wants the disclaimer, which states its
// GPL section 7 relationship and links the license text itself.
procedure TfTerms.ReadClick(Sender: TObject);
begin
  OpenURL(DISCLAIMER_URL);
end;

procedure TfTerms.SnapshotTick(Sender: TObject);
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
        GetEnvironmentVariable('TRNDI_MULTI_SNAPSHOT'), '.terms.png'));
    finally
      png.Free;
    end;
  finally
    img.Free;
  end;
  ModalResult := mrYes;
end;

function TermsAccepted: boolean;
var
  native: TMultiNative;
  f: TfTerms;
  prior: string;
  updated: boolean;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    Result := native.GetBoolSetting(KEY_PREFIX + CURRENT_TERMS);
    if Result then
      exit;
    updated := false;
    for prior in PRIOR_TERMS do
      if native.GetBoolSetting(KEY_PREFIX + prior) then
        updated := true;
    f := TfTerms.Create(nil, updated);
    try
      Result := f.ShowModal = mrYes;
    finally
      f.Free;
    end;
    if Result then
      native.SetSetting(KEY_PREFIX + CURRENT_TERMS, true);
  finally
    native.Free;
  end;
end;

end.
