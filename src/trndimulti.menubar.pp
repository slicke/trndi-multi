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
  macOS: the readings in the menu bar, next to the clock. One pill per
  account, in its tile's colour, with the name, value, trend arrow and
  delta; @code(--) while an account has no current reading, as the Dock
  badge does in Trndi. Each pill's menu brings the window forward, hides
  the pills or quits.

  The pills are trndimulti.statusitem's keyed status items (one per
  account name).
  AppKit puts a new item to the left of those already there, so the pills
  are created together in reverse account order, and recreated together
  when the accounts change: they then read left to right in tile order.

  The setting is stored at the root of Trndi's settings store, next to the
  always-on-top setting, under its own key: Trndi's @code(menubar.reading)
  is about Trndi's own pill. Until the user chooses, it follows the Dock
  as Trndi's does: on when the Dock hides itself, off otherwise. Elsewhere
  there is no status item and @link(MenuBarSupported) is false.
}
unit trndimulti.menubar;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, Graphics, trndi.types, trndi.native.base,
trndimulti.accounts, trndimulti.state, trndimulti.tile,
trndimulti.statusitem;

type
  {** The pills. Hides them all when freed. }
  TMenuBarPills = class
  private
    FNative: TMultiStatusNative;
    FKeys: TStringList;      // Keys shown, in account order
    FOnShow, FOnHide, FOnQuit: TTrndiWakeCallback;
  public
    {** The callbacks are the pill menu's entries; they run on the main
        thread. }
    constructor Create(onShow, onHide, onQuit: TTrndiWakeCallback);
    destructor Destroy; override;
    {** Show or refresh one pill per state, values in @param(displayUnit). }
    procedure Update(const states: array of TAccountState;
      displayUnit: BGUnit);
    {** Take every pill away. }
    procedure Clear;
  end;

{** True where the platform has a menu bar to put the readings in. }
function MenuBarSupported: boolean;

{** The stored setting, or the Dock-based default when none is stored. }
function ReadMenuBar: boolean;
procedure WriteMenuBar(value: boolean);

implementation

const
  MENUBAR_KEY = 'trndi-multi.menubar';
  SHOW_CAPTION = 'Show Trndi Multi';
  HIDE_CAPTION = 'Hide from menu bar';
  QUIT_CAPTION = 'Quit Trndi Multi';

function MenuBarSupported: boolean;
begin
  Result := TMultiStatusNative.SupportsStatusItem;
end;

function ReadMenuBar: boolean;
var
  native: TMultiNative;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    Result := native.GetBoolSetting(MENUBAR_KEY,
      TMultiStatusNative.StatusItemDefault);
  finally
    native.Free;
  end;
end;

procedure WriteMenuBar(value: boolean);
var
  native: TMultiNative;
begin
  native := TMultiNative.Create;
  try
    native.configUser := '';
    native.SetSetting(MENUBAR_KEY, value);
  finally
    native.Free;
  end;
end;

// The account name is the identity; '' is the default account.
function PillKey(state: TAccountState): string;
begin
  Result := 'trndi-multi:' + state.info.name;
end;

constructor TMenuBarPills.Create(onShow, onHide, onQuit: TTrndiWakeCallback);
begin
  inherited Create;
  FNative := TMultiStatusNative.Create;
  FKeys := TStringList.Create;
  FOnShow := onShow;
  FOnHide := onHide;
  FOnQuit := onQuit;
end;

destructor TMenuBarPills.Destroy;
begin
  Clear;
  FKeys.Free;
  FNative.Free;
  inherited Destroy;
end;

procedure TMenuBarPills.Clear;
var
  i: integer;
begin
  for i := 0 to FKeys.Count - 1 do
    FNative.HideStatusItem(FKeys[i]);
  FKeys.Clear;
end;

procedure TMenuBarPills.Update(const states: array of TAccountState;
  displayUnit: BGUnit);
var
  i: integer;
  same: boolean;
  value, detail: string;
  st: TAccountState;
begin
  // Another set of accounts: start over, so the new pills are created
  // together and in order.
  same := FKeys.Count = Length(states);
  if same then
    for i := 0 to High(states) do
      if FKeys[i] <> PillKey(states[i]) then
      begin
        same := false;
        break;
      end;
  if not same then
  begin
    Clear;
    for i := 0 to High(states) do
      FKeys.Add(PillKey(states[i]));
  end;

  // Right to left: each new item lands to the left of the last one.
  for i := High(states) downto 0 do
  begin
    st := states[i];
    FNative.SetStatusItemMenu(FKeys[i], SHOW_CAPTION, HIDE_CAPTION,
      QUIT_CAPTION, FOnShow, FOnHide, FOnQuit);
    // A stale value is gone, not frozen: an old number next to the clock
    // reads as the current one far more easily than a faded tile does.
    detail := '';
    if (not st.haveCurrent) or (st.StaleStage <> ssFresh) then
      value := '--'
    else
    begin
      value := st.current.format(displayUnit, BG_MSG_SHORT);
      detail := BG_TREND_ARROWS_UTF[st.current.trend];
      if not st.current.deltaEmpty then
        detail := detail + ' ' +
          st.current.format(displayUnit, BG_MSG_SIG_SHORT, BGDelta);
    end;
    FNative.ShowStatusItem(FKeys[i], AccountLabel(st.info), value, detail,
      TileColor(st), clWhite);
  end;
end;

end.
