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
  Kiosk support: keep the machine and display awake while the wall display
  runs.

  A port of the keep-awake parts of Trndi's platform natives, which this
  program cannot use directly since it builds on the LCL-free console
  native. Everything is best-effort: a platform or session that cannot be
  inhibited just follows its own power settings, and every inhibition is
  released on disable and again at process exit so nothing outlives us.

  Linux and BSD: a logind idle/sleep lock held by a systemd-inhibit or
  elogind-inhibit child, the desktop session's own idle inhibition over
  D-Bus (portal, org.freedesktop.ScreenSaver, gnome-session) with the
  gnome-session-inhibit/kde-inhibit helpers as fallback, and X11 blanking
  and DPMS turned off with xset. macOS: a caffeinate child. Windows:
  SetThreadExecutionState.
}
unit trndimulti.kiosk;

{$mode objfpc}{$H+}

interface

{** Hold (true) or release (false) every inhibition the platform offers. }
procedure SetKeepAwake(Enable: boolean);

implementation

uses
  SysUtils, Classes
{$IF DEFINED(WINDOWS)}
  , Windows
{$ELSEIF DEFINED(DARWIN)}
  , Process
{$ELSE}
  , Process, linutils.dbus
{$ENDIF};

{$IF DEFINED(WINDOWS)}

const
  ES_SYSTEM_REQUIRED = $00000001;
  ES_DISPLAY_REQUIRED = $00000002;
  ES_CONTINUOUS = $80000000;

function SetThreadExecutionState(esFlags: DWORD): DWORD; stdcall;
  external 'kernel32' Name 'SetThreadExecutionState';

// ES_CONTINUOUS makes the request stick for this thread until it is
// replaced, so releasing is a plain ES_CONTINUOUS call.
procedure SetKeepAwake(Enable: boolean);
begin
  if Enable then
    SetThreadExecutionState(ES_CONTINUOUS or ES_SYSTEM_REQUIRED or
      ES_DISPLAY_REQUIRED)
  else
    SetThreadExecutionState(ES_CONTINUOUS);
end;

{$ELSEIF DEFINED(DARWIN)}

var
  caffeinate: TProcess = nil;

// caffeinate -d -i: -d asserts the display awake, -i the system. The
// assertion lives as long as the child, so a crash here still releases it.
procedure SetKeepAwake(Enable: boolean);
begin
  if Enable then
  begin
    if Assigned(caffeinate) then
      exit;
    caffeinate := TProcess.Create(nil);
    caffeinate.Executable := '/usr/bin/caffeinate';
    caffeinate.Parameters.Add('-d');
    caffeinate.Parameters.Add('-i');
    try
      caffeinate.Execute;
    except
      FreeAndNil(caffeinate);
    end;
  end
  else if Assigned(caffeinate) then
  begin
    caffeinate.Terminate(0);
    caffeinate.WaitOnExit;
    FreeAndNil(caffeinate);
  end;
end;

{$ELSE}

var
  logindProc: TProcess = nil;    // systemd-inhibit / elogind-inhibit child
  desktopProc: TProcess = nil;   // gnome-session-inhibit / kde-inhibit child
  dbusConn: TDBusConn = nil;     // the desktop lock held over D-Bus
  xsetApplied: boolean = false;

function FindInPath(const name: string): string;
begin
  Result := ExeSearch(name, GetEnvironmentVariable('PATH'));
end;

function RunXset(const argv: array of string): boolean;
var
  p: TProcess;
  exe, arg: string;
begin
  Result := false;
  exe := FindInPath('xset');
  if (exe = '') or (GetEnvironmentVariable('DISPLAY') = '') then
    exit;
  p := TProcess.Create(nil);
  try
    p.Executable := exe;
    for arg in argv do
      p.Parameters.Add(arg);
    p.Options := [poWaitOnExit];
    try
      p.Execute;
      Result := p.ExitStatus = 0;
    except
      // best-effort: a failing xset leaves blanking to the OS
    end;
  finally
    p.Free;
  end;
end;

// An inhibitor helper holds its lock for as long as the command it wraps
// runs. That command is `cat` on a pipe: closing our end of its stdin makes
// it exit on EOF and the helper follows, and the same happens by itself if
// this process dies. nil when the tool could not be started.
function StartInhibitor(const exe: string; const argv: array of string): TProcess;
var
  arg: string;
begin
  Result := TProcess.Create(nil);
  Result.Executable := exe;
  for arg in argv do
    Result.Parameters.Add(arg);
  Result.Parameters.Add('cat');
  Result.Options := [poUsePipes];
  try
    Result.Execute;
  except
    FreeAndNil(Result);
  end;
end;

procedure StopInhibitor(var p: TProcess);
begin
  if not Assigned(p) then
    exit;
  p.CloseInput;
  if (not p.WaitOnExit(2000)) and p.Running then
  begin
    p.Terminate(0);
    p.WaitOnExit;
  end;
  FreeAndNil(p);
end;

// The desktop session's own idle inhibition over D-Bus: the portal, then
// org.freedesktop.ScreenSaver (KDE, XFCE, MATE, Cinnamon), then gnome-session.
// Each releases when the calling connection closes, so the private
// connection is kept and freeing it is the release.
function TryDBusIdleInhibit: boolean;
const
  INHIBIT_IDLE = 8;
var
  conn: TDBusConn;
  call, reply: TDBusMessage;
  handle: string;
  cookie: cardinal;
  held: boolean;
begin
  Result := false;
  if not DBusAvailable then
    exit;
  conn := TDBusConn.Create(dbSession, true);
  try
    if not conn.Connected then
      exit;
    held := false;
    call := conn.NewCall('org.freedesktop.portal.Desktop',
      '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.Inhibit',
      'Inhibit');
    if call <> nil then
    begin
      call.AddString('');
      call.AddUInt32(INHIBIT_IDLE);
      call.OpenDict;
      call.DictAddString('reason', 'Kiosk mode');
      call.CloseDict;
      reply := conn.CallBlocking(call, 3000);
      if reply <> nil then
        try
          held := reply.ReadObjectPath(handle) and (handle <> '');
        finally
          reply.Free;
        end;
    end;
    if not held then
    begin
      call := conn.NewCall('org.freedesktop.ScreenSaver',
        '/org/freedesktop/ScreenSaver', 'org.freedesktop.ScreenSaver',
        'Inhibit');
      if call <> nil then
      begin
        call.AddString('trndi-multi');
        call.AddString('Kiosk mode');
        reply := conn.CallBlocking(call, 3000);
        if reply <> nil then
          try
            held := reply.ReadUInt32(cookie);
          finally
            reply.Free;
          end;
      end;
    end;
    if not held then
    begin
      call := conn.NewCall('org.gnome.SessionManager',
        '/org/gnome/SessionManager', 'org.gnome.SessionManager', 'Inhibit');
      if call <> nil then
      begin
        call.AddString('trndi-multi');
        call.AddUInt32(0);
        call.AddString('Kiosk mode');
        call.AddUInt32(INHIBIT_IDLE);
        reply := conn.CallBlocking(call, 3000);
        if reply <> nil then
          try
            held := reply.ReadUInt32(cookie);
          finally
            reply.Free;
          end;
      end;
    end;
    if held then
    begin
      dbusConn := conn;
      conn := nil;
      Result := true;
    end;
  finally
    conn.Free;
  end;
end;

procedure SetKeepAwake(Enable: boolean);
var
  exe, desktop: string;
begin
  if Enable then
  begin
    if not Assigned(logindProc) then
    begin
      exe := FindInPath('systemd-inhibit');
      if exe = '' then
        exe := FindInPath('elogind-inhibit');
      if exe <> '' then
        logindProc := StartInhibitor(exe, ['--what=idle:sleep',
          '--who=trndi-multi', '--why=Kiosk mode', '--mode=block']);
    end;
    if (not Assigned(dbusConn)) and (not Assigned(desktopProc)) then
      TryDBusIdleInhibit;
    if (not Assigned(dbusConn)) and (not Assigned(desktopProc)) then
    begin
      // The helper matching the running desktop first, then the other one.
      desktop := UpperCase(GetEnvironmentVariable('XDG_CURRENT_DESKTOP'));
      if (Pos('KDE', desktop) > 0) or (Pos('PLASMA', desktop) > 0) then
      begin
        exe := FindInPath('kde-inhibit');
        if exe = '' then
          exe := FindInPath('gnome-session-inhibit');
      end
      else
      begin
        exe := FindInPath('gnome-session-inhibit');
        if exe = '' then
          exe := FindInPath('kde-inhibit');
      end;
      if ExtractFileName(exe) = 'kde-inhibit' then
        desktopProc := StartInhibitor(exe, ['--screenSaver', '--power'])
      else if exe <> '' then
        desktopProc := StartInhibitor(exe, ['--app-id', 'trndi-multi',
          '--reason', 'Kiosk mode', '--inhibit', 'idle']);
    end;
    if RunXset(['s', 'off', '-dpms']) then
      xsetApplied := true;
  end
  else
  begin
    FreeAndNil(dbusConn);
    StopInhibitor(logindProc);
    StopInhibitor(desktopProc);
    if xsetApplied then
    begin
      RunXset(['s', 'on', '+dpms']);
      xsetApplied := false;
    end;
  end;
end;

{$ENDIF}

finalization
  SetKeepAwake(false);

end.
