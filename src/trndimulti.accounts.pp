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
  Accounts as the Trndi desktop app stores them, and the backend each one
  connects to.

  Trndi keeps every setting in one store (~/.config/Trndi.cfg on Linux and
  macOS, HKCU\SOFTWARE\Trndi on Windows). With multi-user mode on, the
  account names sit in the root key users.names and every other key of an
  account carries a "Name_" prefix (trndi.native.base's buildKey); the default
  account is the unprefixed keys. This unit only reads that store: accounts
  are created, renamed and removed in Trndi's own settings window, and this
  program shows whatever it finds there.
}
unit trndimulti.accounts;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, trndi.native.console, trndi.api, trndi.api.registry;

type
  {** One account as read from the store. }
  TAccountInfo = record
    name: string;          //< Stored spelling; '' is the default account
    nick: string;          //< user.nick, may be empty
    backend: string;       //< remote.type code, '' when unconfigured
    target: string;        //< Site URL, account name or e-mail
    creds: string;         //< Secret, token or password
    mmol: boolean;         //< Display unit the account uses in Trndi
    // Thresholds in mg/dL, 0 when not set. wizHi/wizLo back-fill backends
    // that report no limits of their own; the ovr* values apply on top of
    // whatever the backend reports, as the GUI applies them (umain_init.inc).
    wizHi, wizLo: integer;
    ovrHi, ovrLo: integer;
    ovrRangeHi, ovrRangeLo: integer;
  end;
  TAccountList = array of TAccountInfo;

  {** The console native resolves its INI to GetAppConfigDir + trndi.ini, but
      the GUI stores settings elsewhere: on Linux and BSD via
      GetAppConfigFile (~/.config/Trndi.cfg), on Windows in the registry,
      on macOS in the app's preferences domain (NSUserDefaults). Read the
      GUI's store on each, so a configured Trndi is all the setup this
      program needs. @link(TrndiAppName) makes ApplicationName = 'Trndi'
      regardless of this binary's file name. }
  TMultiNative = class(TTrndiNativeConsole)
  protected
    function ResolveIniPath: string; override;
  public
{$IF DEFINED(WINDOWS) OR DEFINED(DARWIN)}
    function GetSetting(const keyname: string; def: string = '';
      global: boolean = false): string; override;
    procedure SetSetting(const keyname: string; const val: string;
      global: boolean = false); override; overload;
{$ENDIF}
  end;

{** For OnGetApplicationName: the settings file is Trndi's, not ours. }
function TrndiAppName: string;

{** Where the settings live, for messages. }
function SettingsLocation: string;

{** Every account in the store, the default one first and the rest sorted
    case-insensitively as Trndi's own account picker sorts them. Accounts
    without a backend (remote.type) are included; callers decide whether an
    unconfigured account deserves a tile. }
function ListAccounts: TAccountList;

{** What to call the account on screen: the nickname, else the account name,
    else "Default". }
function AccountLabel(const a: TAccountInfo): string;

{** Write a rotated credential back to the account's remote.creds, so the
    next start (of this program or of Trndi, which reads the same key) logs
    in with the token the backend currently accepts. CareLink rotates its
    refresh token on every refresh and invalidates the old one, so a blob
    that is not written back is dead by the next restart. Safe to call from
    a fetch thread: writes are serialised. }
procedure StoreCredentials(const a: TAccountInfo; const creds: string);

{** Build and connect the account's backend, then lay the user's thresholds
    on top of what it reported, exactly as the GUI does. False leaves the
    reason in @param(err) and @param(api) nil. Synchronous: call it off the
    main thread. }
function OpenBackend(const a: TAccountInfo; out api: TrndiAPI;
  out err: string): boolean;

implementation

uses
{$IF DEFINED(WINDOWS)}
registry, Windows,
{$ELSEIF DEFINED(DARWIN)}
MacOSAll,
{$ENDIF}
SyncObjs, trndi.types;

var
  // Two accounts can rotate at the same moment on two fetch threads, and the
  // INI store rewrites the whole file on every write.
  storeLock: TCriticalSection;

const
  // initCGMCore's untouched default high limit: a backend that reports no
  // limits of its own leaves it there (the same constant trndi-cli keys on).
  CGM_HI_UNSET = 401;

function TrndiAppName: string;
begin
  Result := 'Trndi';
end;

function TMultiNative.ResolveIniPath: string;
begin
  Result := GetAppConfigFile(false);
end;

{$IFDEF WINDOWS}
// The Windows GUI keeps settings in the registry, not an INI — read the same
// values (HKCU\SOFTWARE\Trndi, value names like 'remote.type', or
// 'Name_remote.type' under a multi-user account: buildKey applies the same
// prefix the GUI's own registry native applies).
function TMultiNative.GetSetting(const keyname: string; def: string;
global: boolean): string;
var
  reg: TRegistry;
  key: string;
begin
  Result := def;
  key := buildKey(keyname, global);
  reg := TRegistry.Create;
  try
    reg.RootKey := HKEY_CURRENT_USER;
    if reg.OpenKeyReadOnly('\SOFTWARE\Trndi\') then
      if reg.ValueExists(key) then
        Result := reg.ReadString(key);
  finally
    reg.Free;
  end;
end;

procedure TMultiNative.SetSetting(const keyname: string; const val: string;
global: boolean);
var
  reg: TRegistry;
begin
  reg := TRegistry.Create;
  try
    reg.RootKey := HKEY_CURRENT_USER;
    if reg.OpenKey('\SOFTWARE\Trndi\', true) then
      reg.WriteString(buildKey(keyname, global), val);
  finally
    reg.Free;
  end;
end;
{$ENDIF}

{$IFDEF DARWIN}
// The macOS GUI keeps settings in NSUserDefaults under its bundle
// identifier, i.e. ~/Library/Preferences/com.slicke.Trndi.plist. Read and
// write that domain through CFPreferences: the same store, the same keys
// (buildKey applies the account prefix), no Cocoa runtime needed. Keys and
// values are UTF-8 strings, as Trndi's own native writes them.
const
  MAC_PREFS_DOMAIN = 'com.slicke.Trndi';

function CFStr(const s: string): CFStringRef;
begin
  Result := CFStringCreateWithCString(nil, PChar(s), kCFStringEncodingUTF8);
end;

function CFToStr(ref: CFStringRef): string;
var
  size: CFIndex;
  buf: array of char;
begin
  Result := '';
  if ref = nil then
    exit;
  size := CFStringGetMaximumSizeForEncoding(CFStringGetLength(ref),
    kCFStringEncodingUTF8) + 1;
  SetLength(buf, size);
  if CFStringGetCString(ref, @buf[0], size, kCFStringEncodingUTF8) then
    Result := PChar(@buf[0]);
end;

function TMultiNative.GetSetting(const keyname: string; def: string;
global: boolean): string;
var
  key, domain: CFStringRef;
  val: CFPropertyListRef;
begin
  Result := def;
  key := CFStr(buildKey(keyname, global));
  domain := CFStr(MAC_PREFS_DOMAIN);
  try
    val := CFPreferencesCopyAppValue(key, domain);
    if val <> nil then
      try
        if CFGetTypeID(val) = CFStringGetTypeID() then
          Result := CFToStr(CFStringRef(val));
      finally
        CFRelease(val);
      end;
  finally
    CFRelease(key);
    CFRelease(domain);
  end;
  // An empty stored value reads as the default, as Trndi's native does.
  if Result = '' then
    Result := def;
end;

procedure TMultiNative.SetSetting(const keyname: string; const val: string;
global: boolean);
var
  key, domain, value: CFStringRef;
begin
  key := CFStr(buildKey(keyname, global));
  domain := CFStr(MAC_PREFS_DOMAIN);
  value := CFStr(val);
  try
    CFPreferencesSetAppValue(key, CFPropertyListRef(value), domain);
    CFPreferencesAppSynchronize(domain);
  finally
    CFRelease(value);
    CFRelease(key);
    CFRelease(domain);
  end;
end;
{$ENDIF}

function SettingsLocation: string;
begin
{$IF DEFINED(WINDOWS)}
  Result := 'HKCU\SOFTWARE\Trndi';
{$ELSEIF DEFINED(DARWIN)}
  Result := '~/Library/Preferences/' + MAC_PREFS_DOMAIN + '.plist';
{$ELSE}
  Result := GetAppConfigFile(false);
{$ENDIF}
end;

// Read one account's keys. configUser selects the prefix; '' reads the
// default account's unprefixed keys.
function ReadAccount(native: TMultiNative; const name: string): TAccountInfo;
begin
  native.configUser := name;
  Result := Default(TAccountInfo);
  Result.name := name;
  Result.nick := Trim(native.GetSetting('user.nick', ''));
  Result.backend := Trim(native.GetSetting('remote.type'));
  Result.target := native.GetSetting('remote.target');
  Result.creds := native.GetSetting('remote.creds');
  // Anything but 'mmol' means mg/dL, as the GUI reads it.
  Result.mmol := native.GetSetting('unit', 'mmol') = 'mmol';
  // A missing or blank key parses to 0, the "not set" value.
  Result.wizHi := StrToIntDef(native.GetSetting('wizard.hi'), 0);
  Result.wizLo := StrToIntDef(native.GetSetting('wizard.lo'), 0);
  Result.ovrHi := StrToIntDef(native.GetSetting('override.hi'), 0);
  Result.ovrLo := StrToIntDef(native.GetSetting('override.lo'), 0);
  Result.ovrRangeHi := StrToIntDef(native.GetSetting('override.rangehi'), 0);
  Result.ovrRangeLo := StrToIntDef(native.GetSetting('override.rangelo'), 0);
end;

function ListAccounts: TAccountList;
var
  native: TMultiNative;
  names: TStringArray;
  sorter: TStringList;
  i, n: integer;
begin
  Result := nil;
  names := nil;
  native := TMultiNative.Create;
  try
    if not native.TryGetCSVSetting('users.names', names, true) then
      names := nil;
    // Trndi's picker sorts case-insensitively rather than in insertion
    // order; list the same way so the two enumerate alike. Blank entries
    // (a trailing comma in the CSV) name nothing.
    sorter := TStringList.Create;
    try
      sorter.CaseSensitive := false;
      for i := 0 to High(names) do
        if Trim(names[i]) <> '' then
          sorter.Add(Trim(names[i]));
      sorter.Sort;
      SetLength(Result, 1 + sorter.Count);
      Result[0] := ReadAccount(native, '');
      n := 1;
      for i := 0 to sorter.Count - 1 do
      begin
        Result[n] := ReadAccount(native, sorter[i]);
        Inc(n);
      end;
    finally
      sorter.Free;
    end;
  finally
    native.Free;
  end;
end;

function AccountLabel(const a: TAccountInfo): string;
begin
  if a.nick <> '' then
    Result := a.nick
  else if a.name <> '' then
    Result := a.name
  else
    Result := 'Default';
end;

procedure StoreCredentials(const a: TAccountInfo; const creds: string);
var
  native: TMultiNative;
begin
  storeLock.Acquire;
  try
    native := TMultiNative.Create;
    try
      native.configUser := a.name;
      native.SetSetting('remote.creds', creds);
    finally
      native.Free;
    end;
  finally
    storeLock.Release;
  end;
end;

function OpenBackend(const a: TAccountInfo; out api: TrndiAPI;
out err: string): boolean;
begin
  Result := false;
  err := '';
  api := CreateBackend(a.backend, a.target, a.creds);
  if api = nil then
  begin
    err := Format('Unknown backend "%s" in settings.', [a.backend]);
    exit;
  end;
  if not api.connect then
  begin
    err := api.errormsg;
    if err = '' then
      err := 'Could not connect.';
    FreeAndNil(api);
    exit;
  end;
  // User thresholds on top of what the backend reported, as the GUI lays
  // them on (umain_init.inc): the wizard pair only where the backend
  // supplied no high limit of its own, the override pair always.
  if api.cgmHi = CGM_HI_UNSET then
  begin
    if a.wizHi > 0 then
      api.cgmHi := a.wizHi;
    if a.wizLo > 0 then
      api.cgmLo := a.wizLo;
  end;
  if a.ovrLo > 0 then
    api.cgmLo := a.ovrLo;
  if a.ovrHi > 0 then
    api.cgmHi := a.ovrHi;
  if a.ovrRangeLo > 0 then
    api.cgmRangeLo := a.ovrRangeLo;
  if a.ovrRangeHi > 0 then
    api.cgmRangeHi := a.ovrRangeHi;
  Result := true;
end;

initialization
  storeLock := TCriticalSection.Create;

finalization
  storeLock.Free;

end.
