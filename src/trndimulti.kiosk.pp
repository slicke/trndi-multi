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

  A thin wrapper around the platform native's SetKeepAwake: on Windows
  SetThreadExecutionState, on macOS a caffeinate child, on Linux and BSD a
  logind lock, the desktop session's own idle inhibition over D-Bus and
  xset. The native keeps the inhibition in instance state, so one instance
  lives from enable to disable and is freed on disable; the natives also
  release whatever they hold in their destructors, so nothing outlives the
  process.

  Windows' request is per thread: enable and disable from the same (main)
  thread, as umulti does.
}
unit trndimulti.kiosk;

{$mode objfpc}{$H+}

interface

{** Hold (true) or release (false) every inhibition the platform offers. }
procedure SetKeepAwake(Enable: boolean);

implementation

uses
  SysUtils, trndi.native;

var
  keeper: TrndiNative = nil;

procedure SetKeepAwake(Enable: boolean);
begin
  if Enable then
  begin
    if not Assigned(keeper) then
    begin
      keeper := TrndiNative.Create;
      // The Linux native's destructor otherwise deletes Trndi's panel
      // indicator cache (~/.cache/trndi/current.txt) as if Trndi itself
      // were shutting down; Trndi may well be running beside us.
      keeper.noFree := true;
    end;
    keeper.SetKeepAwake(true);
  end
  else if Assigned(keeper) then
  begin
    keeper.SetKeepAwake(false);
    FreeAndNil(keeper);
  end;
end;

finalization
  // A process that exits with kiosk mode still on releases its inhibition
  // through the native's destructor.
  FreeAndNil(keeper);
end.
