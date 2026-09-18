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
  The always-on-top setting and what it takes to honour it.

  The setting is stored at the root of Trndi's settings store, next to the
  terms acceptance: it is about this window, not any account. The window
  applies it through the LCL's form style, which every widgetset maps to
  its own floating window: HWND_TOPMOST, Qt's stays-on-top hint, Cocoa's
  floating window level.

  Wayland is the exception. The protocol has nothing for it, so Qt's Wayland
  backend drops the hint, on every compositor. XWayland does honour it: GNOME
  and KDE both keep an X11 window with the "above" state on top of their
  Wayland windows. So when the setting is on in a Wayland session, this
  unit's initialization puts the toolkit onto XWayland before Qt is created,
  which is why it is listed before Interfaces in the program. A toolkit
  choice already made in the environment is left alone, and a session
  without XWayland (no DISPLAY) is left to ignore the hint.
}
unit trndimulti.ontop;

{$mode objfpc}{$H+}

interface

{** The stored setting. }
function ReadOnTop: boolean;
procedure WriteOnTop(value: boolean);

{** True when the setting cannot take effect in the running window, only in
    a new one: the toolkit is on Wayland with XWayland available. Turning
    the setting off never needs a restart. }
function OnTopNeedsRestart: boolean;

{** Starts another copy of this program with the same arguments. The caller
    closes this one. }
procedure RestartProgram;

implementation

uses
SysUtils, Classes, Process, trndimulti.accounts;

const
  ONTOP_KEY = 'trndi-multi.ontop';

function ReadOnTop: boolean;
var
  native: TMultiNative;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    Result := native.GetBoolSetting(ONTOP_KEY, false);
  finally
    native.Free;
  end;
end;

procedure WriteOnTop(value: boolean);
var
  native: TMultiNative;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    native.SetSetting(ONTOP_KEY, value);
  finally
    native.Free;
  end;
end;

{$IF DEFINED(LINUX)}
// True in a Wayland session with the toolkit on the Wayland backend and an
// X server (XWayland) to move it to. IsWaylandSession answers false when
// QT_QPA_PLATFORM already names xcb.
function ToolkitOnWayland: boolean;
begin
  Result := TMultiNative.IsWaylandSession and
    (GetEnvironmentVariable('DISPLAY') <> '');
end;

function setenv(name, value: PChar; overwrite: longint): longint; cdecl;
  external 'c';
{$ENDIF}

function OnTopNeedsRestart: boolean;
begin
  {$IF DEFINED(LINUX)}
  Result := ToolkitOnWayland;
  {$ELSE}
  Result := false;
  {$ENDIF}
end;

procedure RestartProgram;
var
  p: TProcess;
  i: integer;
begin
  p := TProcess.Create(nil);
  try
    p.Executable := ParamStr(0);
    for i := 1 to ParamCount do
      p.Parameters.Add(ParamStr(i));
    p.CurrentDirectory := GetCurrentDir;
    // Its own process group and no inherited handles: it outlives this one.
    p.Options := [poNewProcessGroup];
    p.InheritHandles := false;
    p.Execute;
  finally
    p.Free;
  end;
end;

initialization
  // Before any config path is resolved: the settings file is Trndi's. The
  // program sets this too, but only after this unit has run.
  OnGetApplicationName := @TrndiAppName;
  {$IF DEFINED(LINUX)}
  if (GetEnvironmentVariable('QT_QPA_PLATFORM') = '') and ToolkitOnWayland
     and ReadOnTop then
    setenv('QT_QPA_PLATFORM', 'xcb', 1);
  {$ENDIF}
end.
