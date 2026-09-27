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
  The logo, taken back out of the binary's own icon.

  trndi-multi.png is the one piece of artwork: `make icon` turns it into
  TrndiMulti.ico, lazbuild embeds that as the MAINICON resource and the
  LCL loads it into Application.Icon at startup, which is what a desktop
  shows in the window frame, the taskbar and the Dock. The About window,
  the wall with no accounts on it yet and the PDF report want the same
  mark inside the document, so this unit exports the icon's largest image
  as a PNG data: URI for their <img> tags rather than carrying a second
  copy of the picture in the binary.
}
unit trndimulti.branding;

{$mode objfpc}{$H+}
{$IFDEF DARWIN}
{$modeswitch objectivec1}
{$ENDIF}

interface

{** Read the logo out of MAINICON and keep it. Call once from the main
    thread after Application.Initialize, which is what loads the resource:
    the report builds its HTML on a worker thread, so it must not be the
    first thing to touch the icon. }
procedure PrepareLogo;

{** The logo as an inline PNG for the src of an <img> in any of the
    Pixie-rendered documents, or an empty string when this binary carries
    no icon — callers then lay out without it rather than showing a
    broken image. }
function LogoDataUri: string;

{** macOS: when this runs as an .app, show the bundle's own icon in the Dock
    instead of MAINICON, as Trndi does. The LCL pushes MAINICON to the Dock
    in Application.Initialize, over the bundle's CFBundleIconFile, so the
    development bundle (make run) would otherwise wear the release artwork
    while running. A bare binary has no bundle icon and keeps MAINICON.
    Call once after Application.Initialize. A no-op elsewhere. }
procedure ShowBundleIcon;

implementation

uses
SysUtils, Classes, Graphics, Forms, base64{$IFDEF DARWIN}, CocoaAll{$ENDIF};

var
  LogoUri: string = '';
  Prepared: boolean = false;

// The largest image in the icon, 256x256 in TrndiMulti.ico. One export
// serves every use, scaled down by whoever draws it: the About window,
// the report's header and the PDF all ask for a different size, and the
// PDF for one that is not in pixels at all.
function LargestImage(ico: TIcon): integer;
var
  i: integer;
  fmt: TPixelFormat;
  w, h, best: word;
begin
  Result := -1;
  best := 0;
  for i := 0 to ico.Count-1 do
  begin
    ico.GetDescription(i, fmt, h, w);
    if w > best then
    begin
      best := w;
      Result := i;
    end;
  end;
end;

procedure PrepareLogo;
var
  ico: TIcon;
  idx: integer;
  png: TFPImageBitmap;
  buf: TMemoryStream;
  raw: ansistring;
begin
  if Prepared then
    Exit;
  Prepared := true;
  ico := Application.Icon;
  if (ico = nil) or (ico.Count = 0) then
    Exit;
  idx := LargestImage(ico);
  if idx < 0 then
    Exit;
  // Decoration: a binary whose icon cannot be read still runs, with the
  // documents laid out without it.
  try
    png := ico.ExportImage(idx, TPortableNetworkGraphic);
    try
      buf := TMemoryStream.Create;
      try
        png.SaveToStream(buf);
        // An encoder that wrote nothing raises nothing either, and an
        // empty data: URI is a broken image rather than no image.
        raw := '';
        if buf.Size > 0 then
          SetString(raw, PAnsiChar(buf.Memory), buf.Size);
      finally
        buf.Free;
      end;
    finally
      png.Free;
    end;
    if raw <> '' then
      LogoUri := 'data:image/png;base64,' + EncodeStringBase64(raw);
  except
    LogoUri := '';
  end;
end;

function LogoDataUri: string;
begin
  Result := LogoUri;
end;

procedure ShowBundleIcon;
begin
  {$IFDEF DARWIN}
  // nil hands the Dock back to CFBundleIconFile. Only Application.Icon
  // changing pushes MAINICON again, and nothing here changes it.
  if NSBundle.mainBundle.bundleIdentifier <> nil then
    NSApp.setApplicationIconImage(nil);
  {$ENDIF}
end;

end.
