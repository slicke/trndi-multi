{ Lays out the PDF report for made-up accounts and writes it to the file
  named on the command line, so the layout can be looked at without a
  backend: a full day with a gap and excursions, a day that could not be
  fetched, an account that never connected, and a second full day so the
  page breaks show. }
program reporttest;
{$mode objfpc}{$H+}
{$R *.res}
uses
  Interfaces, Forms, Graphics, SysUtils, DateUtils, Math, trndi.types, trndi.api,
  trndimulti.accounts, trndimulti.branding, trndimulti.report;

function TrendOf(delta: double): BGTrend;
begin
  if delta > 3 then
    Result := TdSingleUp
  else if delta > 1 then
    Result := TdFortyFiveUp
  else if delta < -3 then
    Result := TdSingleDown
  else if delta < -1 then
    Result := TdFortyFiveDown
  else
    Result := TdFlat;
end;

function Reading(const at: TDateTime; mgdlV, delta: double): BGReading;
begin
  Result.Init(mgdl, 'test');
  Result.update(mgdlV, delta, mgdl);
  Result.date := at;
  Result.trend := TrendOf(delta);
end;

function Day(const fromT, toT: TDateTime; cadence: integer; seed: integer): BGResults;
var
  t: TDateTime;
  v, prev, phase: double;
  n: integer;
begin
  Result := nil;
  t := fromT;
  prev := 120;
  phase := seed;
  n := 0;
  while t < toT do
  begin
    // A day's shape: a slow wave, a sharp lunch rise and a night dip.
    v := 125 + 35 * Sin((t - fromT) * 2 * Pi + phase) + 8 * Sin((t - fromT) * 29 * Pi + seed);
    if (HourOf(t) in [12..13]) then
      v := v + 70;
    if (HourOf(t) in [3..4]) then
      v := v - 60;
    // A sensor off for an hour and a half in the afternoon.
    if not ((HourOf(t) = 15) or ((HourOf(t) = 16) and (MinuteOf(t) < 30))) then
    begin
      SetLength(Result, n + 1);
      Result[n] := Reading(t, v, v - prev);
      Inc(n);
    end;
    prev := v;
    t := IncMinute(t, cadence);
  end;
end;

var
  secs: TReportSections;
  fromT, toT: TDateTime;
  s: TReportSection;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: reporttest <out.pdf> [icon.ico]');
    Halt(1);
  end;
  // The logo the real report carries, out of the project's icon.
  if ParamCount >= 2 then
  begin
    Application.Icon.LoadFromFile(ParamStr(2));
    PrepareLogo;
    WriteLn('logo: ', Length(LogoDataUri), ' chars');
  end;
  toT := EncodeDateTime(2026, 10, 13, 22, 44, 0, 0);
  fromT := IncHour(toT, -REPORT_HOURS);
  secs := nil;

  // A full day, with a personal target band.
  s := Default(TReportSection);
  s.acct.info.name := 'Anna';
  s.acct.info.nick := 'Anna';
  s.connected := true;
  s.system := 'Dexcom (Outside USA)';
  s.interval := 5;
  s.lo := 70; s.hi := 180; s.bottom := 80; s.top := 160;
  s.history := Day(fromT, toT, 5, 1);
  s.acct.current := s.history[High(s.history)];
  s.acct.haveCurrent := true;
  SetLength(secs, 1); secs[0] := s;

  // The day could not be fetched, the reading is old, the name is long.
  s := Default(TReportSection);
  s.acct.info.name := 'Grandfather Johansson at the summer house';
  s.connected := true;
  s.system := 'NightScout';
  s.interval := 5;
  s.lo := 72; s.hi := 200;
  s.top := TrndiAPI.CGM_RANGE_HI_DISABLED; s.bottom := TrndiAPI.CGM_RANGE_LO_DISABLED;
  s.fetchErr := 'HTTP 503 from https://ns.example.org/api/v1/entries.json: Service Unavailable';
  s.acct.current := Reading(IncHour(toT, -3), 95, -4);
  s.acct.haveCurrent := true;
  s.acct.stale := true;
  SetLength(secs, 2); secs[1] := s;

  // Never connected.
  s := Default(TReportSection);
  s.acct.info.name := 'Mia';
  s.connected := false;
  s.acct.err := 'CareLink login failed: the token has expired. Log in again in Trndi.';
  s.fetchErr := s.acct.err;
  SetLength(secs, 3); secs[2] := s;

  // A second full day at a coarser cadence, so the report runs to more pages.
  s := Default(TReportSection);
  s.acct.info.name := 'Erik';
  s.connected := true;
  s.system := 'xDrip';
  s.interval := 10;
  s.lo := 65; s.hi := 190;
  s.top := TrndiAPI.CGM_RANGE_HI_DISABLED; s.bottom := TrndiAPI.CGM_RANGE_LO_DISABLED;
  s.history := Day(fromT, toT, 10, 4);
  s.acct.current := s.history[High(s.history)];
  s.acct.haveCurrent := true;
  SetLength(secs, 4); secs[3] := s;

  WriteReportPdf(secs, mmol, fromT, toT, ParamStr(1));
  WriteLn('wrote ', ParamStr(1));
end.
