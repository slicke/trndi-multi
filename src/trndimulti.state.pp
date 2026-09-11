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
  Per-account runtime state and the worker thread that fills it.

  Each account keeps its own backend, its latest reading, a few hours of
  history for the sparkline and a "next poll due" time. Fetching is
  synchronous inside the API layer, so it happens on a @link(TFetchThread);
  the thread hands its results to the main thread through Synchronize, which
  is the only place the state is written after construction. A slow CareLink
  login on one account therefore never holds up the others, and the tiles
  only ever read state that is not being changed underneath them.
}
unit trndimulti.state;

{$mode objfpc}{$H+}

interface

uses
Classes, SysUtils, DateUtils, Math, trndi.api, trndi.types, trndimulti.accounts;

const
  {** Sparkline window: the last three hours. }
  HISTORY_MINUTES = 180;
  {** Polling never runs faster than one request a minute nor slower than
      one a quarter hour, whatever the backend reports as its interval. }
  POLL_MIN_MINUTES = 1;
  POLL_MAX_MINUTES = 15;

type
  TAccountState = class;

  {** Called on the main thread when a fetch for @param(state) has finished,
      whatever its outcome. }
  TStateEvent = procedure(state: TAccountState) of object;

  {** Everything one tile shows. Written only from the main thread. }
  TAccountState = class
  public
    info: TAccountInfo;
    api: TrndiAPI;            //< nil until the first successful connect
    current: BGReading;       //< Latest reading, valid when haveCurrent
    haveCurrent: boolean;
    stale: boolean;           //< current came from getLast: older than the backend's window
    history: BGResults;       //< Ascending by time, empties dropped
    err: string;              //< Last failure; '' after a successful fetch
    everFetched: boolean;     //< False until the first fetch has come back
    lastFetch: TDateTime;
    nextDue: TDateTime;       //< 0 = as soon as possible
    thread: TThread;          //< Running fetch, nil when idle
    doneThread: TThread;      //< Finished fetch awaiting Free
    constructor Create(const a: TAccountInfo);
    destructor Destroy; override;
    {** True while a fetch is running. }
    function Busy: boolean;
    {** Minutes between polls, from the backend's reporting interval. }
    function IntervalMinutes: integer;
    {** Age of the current reading in whole minutes; -1 without one. }
    function AgeMinutes: integer;
    {** True when the reading should be shown as old: the backend served it
        as a fallback (@link(stale)), or it has aged past two reporting
        intervals with some slack — the point at which a CGM app would
        stop treating it as current. Recomputed on every call, since a
        reading ages between fetches. }
    function IsStale: boolean;
  end;

  {** One fetch: connect if not yet connected, then the current reading and
      the sparkline history. Results land in the state via Synchronize. }
  TFetchThread = class(TThread)
  private
    FState: TAccountState;
    FOnDone: TStateEvent;
    FApi: TrndiAPI;           // opened by this run, handed over in Apply
    FCurrent: BGReading;
    FHave, FStale: boolean;
    FHistory: BGResults;
    FErr: string;
    procedure Apply;
  protected
    procedure Execute; override;
  public
    constructor Create(state: TAccountState; onDone: TStateEvent);
    destructor Destroy; override;
  end;

{** Start a fetch for @param(state) unless one is already running. }
procedure StartFetch(state: TAccountState; onDone: TStateEvent);

implementation

{------------------------------------------------------------------------------
  TAccountState
 ------------------------------------------------------------------------------}

constructor TAccountState.Create(const a: TAccountInfo);
begin
  inherited Create;
  info := a;
  current.Clear;
end;

destructor TAccountState.Destroy;
begin
  // A fetch still on the wire: tell it not to report back and wait for the
  // request to time out or finish. WaitFor on the main thread keeps
  // servicing Synchronize, and Execute checks Terminated before calling it.
  if thread <> nil then
  begin
    thread.Terminate;
    thread.WaitFor;
    FreeAndNil(thread);
  end;
  FreeAndNil(doneThread);
  FreeAndNil(api);
  inherited Destroy;
end;

function TAccountState.Busy: boolean;
begin
  Result := thread <> nil;
end;

function TAccountState.IntervalMinutes: integer;
begin
  Result := 5;
  if api <> nil then
    Result := api.getReportingInterval;
  Result := EnsureRange(Result, POLL_MIN_MINUTES, POLL_MAX_MINUTES);
end;

function TAccountState.AgeMinutes: integer;
begin
  if haveCurrent then
    Result := Max(0, MinutesBetween(Now, current.date))
  else
    Result := -1;
end;

function TAccountState.IsStale: boolean;
begin
  Result := haveCurrent and (stale or
    (AgeMinutes > Max(10, 2 * IntervalMinutes + 2)));
end;

{------------------------------------------------------------------------------
  TFetchThread
 ------------------------------------------------------------------------------}

constructor TFetchThread.Create(state: TAccountState; onDone: TStateEvent);
begin
  inherited Create(true);
  FreeOnTerminate := false;
  FState := state;
  FOnDone := onDone;
  FCurrent.Clear;
end;

destructor TFetchThread.Destroy;
begin
  // Opened but never handed over (the owner went away first).
  FreeAndNil(FApi);
  inherited Destroy;
end;

// Placeholder readings (BG_NO_VAL) and anything older than the window out
// of the history, and what is left sorted ascending by time so the
// sparkline can walk it left to right. The window is cut here rather than
// trusted from the request: Nightscout honours only the count, Dexcom Share
// only the minutes, so what comes back spans different times per backend.
procedure TidyHistory(var res: BGResults; const cutoff: TDateTime);
var
  i, j, w: integer;
  tmp: BGReading;
begin
  w := 0;
  for i := 0 to High(res) do
    if (not res[i].empty) and (res[i].date >= cutoff) then
    begin
      if w <> i then
        res[w] := res[i];
      Inc(w);
    end;
  SetLength(res, w);
  // Insertion sort: a few dozen readings, already nearly ordered.
  for i := 1 to High(res) do
  begin
    tmp := res[i];
    j := i - 1;
    while (j >= 0) and (res[j].date > tmp.date) do
    begin
      res[j + 1] := res[j];
      Dec(j);
    end;
    res[j + 1] := tmp;
  end;
end;

procedure TFetchThread.Execute;
var
  api: TrndiAPI;
  err: string;
begin
  FErr := '';
  FHave := false;
  FStale := false;
  FHistory := nil;
  // No early exit anywhere below: the hand-back at the end must run
  // whatever happened, or the account would show "connecting" forever.
  try
    api := FState.api;
    if (api = nil) and (not OpenBackend(FState.info, FApi, err)) then
      FErr := err
    else
    begin
      if api = nil then
        api := FApi;
      // A backend that answers with a placeholder has not answered: `empty`
      // is BG_NO_VAL. Treat it as no reading and fall back to the last one
      // the backend has, flagged stale, the way trndi-cli does.
      FHave := api.getCurrent(FCurrent) and (not FCurrent.empty);
      if not FHave then
      begin
        FHave := api.getLast(FCurrent) and (not FCurrent.empty);
        FStale := FHave;
      end;
      // Count from the backend's own cadence, with slack for uploads that
      // bunch up, so a count-only backend returns about the window too.
      FHistory := api.getReadings(HISTORY_MINUTES,
        HISTORY_MINUTES div Max(1, api.getReportingInterval) + 16);
      TidyHistory(FHistory, IncMinute(Now, -HISTORY_MINUTES));
      if (not FHave) and (Length(FHistory) = 0) then
        FErr := api.errormsg;
    end;
  except
    on E: Exception do
      FErr := E.Message;
  end;
  if not Terminated then
    Synchronize(@Apply);
end;

// Main thread: move this run's results into the state and decide when the
// account is next due.
procedure TFetchThread.Apply;
var
  due: TDateTime;
begin
  if FApi <> nil then
  begin
    FState.api := FApi;
    FApi := nil;
  end;
  FState.current := FCurrent;
  FState.haveCurrent := FHave;
  FState.stale := FStale;
  FState.history := FHistory;
  FState.err := FErr;
  FState.everFetched := true;
  FState.lastFetch := Now;

  // A fresh reading: poll again one interval after it, plus a little slack
  // for the upload path. That moment already passed (the reading arrived
  // late, or the interval is shorter than the sensor's cadence) or nothing
  // fresh came: try again in a minute. A failure: a little longer, so a
  // site that is down is not hammered.
  if FHave and (not FStale) then
  begin
    due := IncSecond(FState.current.date, FState.IntervalMinutes * 60 + 30);
    if due < IncSecond(Now, 30) then
      due := IncMinute(Now, 1);
  end
  else if FErr <> '' then
    due := IncMinute(Now, 2)
  else
    due := IncMinute(Now, 1);
  FState.nextDue := due;

  FState.thread := nil;
  FState.doneThread := Self;
  if Assigned(FOnDone) then
    FOnDone(FState);
end;

procedure StartFetch(state: TAccountState; onDone: TStateEvent);
begin
  if state.Busy then
    exit;
  // The previous run has finished (it cleared `thread` from inside
  // Synchronize); free it now rather than from inside its own callback.
  FreeAndNil(state.doneThread);
  state.thread := TFetchThread.Create(state, onDone);
  state.thread.Start;
end;

end.
