unit Romitter.Worker;

interface

uses
  System.SysUtils,
  Winapi.Windows,
  Romitter.Config.Model,
  Romitter.Logging,
  Romitter.HttpServer,
  Romitter.StreamServer;

type
  TRomitterWorker = class
  private
    FConfigPath: string;
    FPrefix: string;
    FWorkerId: Integer;
    FQuitEventName: string;
    FStopEventName: string;
    FReadyEventName: string;
    FParentPid: Cardinal;
    FConfig: TRomitterConfig;
    FLogger: TRomitterLogger;
    FHttpServer: TRomitterHttpServer;
    FStreamServer: TRomitterStreamServer;
    function OpenSignalEvent(const Name: string;
      const DesiredAccess: DWORD = SYNCHRONIZE): THandle;
  public
    constructor Create(const ConfigPath, Prefix: string;
      const WorkerId: Integer;
      const QuitEventName, StopEventName: string;
      const ReadyEventName: string;
      const ParentPid: Cardinal);
    destructor Destroy; override;
    function Run: Integer;
  end;

implementation

uses
  System.IOUtils,
  Romitter.Config.Loader,
  Romitter.Constants;

function MapErrorLogLevelToMinLevel(const LevelText: string): TRomitterLogLevel;
begin
  if SameText(LevelText, 'debug') then
    Exit(rlDebug);
  if SameText(LevelText, 'info') or SameText(LevelText, 'notice') then
    Exit(rlInfo);
  if SameText(LevelText, 'warn') then
    Exit(rlWarn);
  Result := rlError;
end;

procedure AppendWorkerCrashLog(const WorkerId: Integer; const MessageText: string);
var
  CrashLogPath: string;
  LineText: string;
begin
  try
    CrashLogPath := TPath.Combine(ExtractFilePath(ParamStr(0)), 'romitter-worker-crash.log');
    LineText := Format(
      '%s [worker:%d pid:%d] %s%s',
      [
        FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now),
        WorkerId,
        GetCurrentProcessId,
        MessageText,
        sLineBreak
      ]);
    TFile.AppendAllText(CrashLogPath, LineText, TEncoding.UTF8);
  except
    // Best-effort only; never raise from crash logger.
  end;
end;

constructor TRomitterWorker.Create(const ConfigPath, Prefix: string;
  const WorkerId: Integer; const QuitEventName, StopEventName: string;
  const ReadyEventName: string;
  const ParentPid: Cardinal);
begin
  inherited Create;
  FConfigPath := ConfigPath;
  FPrefix := Prefix;
  FWorkerId := WorkerId;
  FQuitEventName := QuitEventName;
  FStopEventName := StopEventName;
  FReadyEventName := ReadyEventName;
  FParentPid := ParentPid;
  FConfig := nil;
  FLogger := nil;
  FHttpServer := nil;
  FStreamServer := nil;
end;

destructor TRomitterWorker.Destroy;
begin
  FStreamServer.Free;
  FHttpServer.Free;
  FLogger.Free;
  FConfig.Free;
  inherited;
end;

function TRomitterWorker.OpenSignalEvent(const Name: string;
  const DesiredAccess: DWORD): THandle;
begin
  Result := 0;
  if Trim(Name) = '' then
    Exit(0);
  Result := OpenEvent(DesiredAccess, False, PChar(Name));
end;

function TRomitterWorker.Run: Integer;
var
  StopEventHandle: THandle;
  QuitEventHandle: THandle;
  ReadyEventHandle: THandle;
  ParentHandle: THandle;
  WaitHandles: array[0..2] of THandle;
  HandleCount: DWORD;
  WaitResult: DWORD;
  ShutdownFast: Boolean;
begin
  Result := 1;
  StopEventHandle := 0;
  QuitEventHandle := 0;
  ReadyEventHandle := 0;
  ParentHandle := 0;
  ShutdownFast := False;

  try
    try
      FConfig := TRomitterConfigLoader.LoadFromFile(FConfigPath, FPrefix);
      if SameText(FConfig.ErrorLogFile, 'stderr') then
        FLogger := TRomitterLogger.Create('', False)
      else
        FLogger := TRomitterLogger.Create(FConfig.ErrorLogFile, False);
      FLogger.MinLevel := MapErrorLogLevelToMinLevel(FConfig.ErrorLogLevel);

      if FConfig.Http.Enabled then
      begin
        FHttpServer := TRomitterHttpServer.Create(FConfig, FLogger);
        FHttpServer.Start;
      end;
      if FConfig.Stream.Enabled then
      begin
        FStreamServer := TRomitterStreamServer.Create(FConfig, FLogger);
        FStreamServer.Start;
      end;
      if (not FConfig.Http.Enabled) and (not FConfig.Stream.Enabled) then
        FLogger.Log(rlWarn, Format('worker[%d] started without listeners', [FWorkerId]));

      StopEventHandle := OpenSignalEvent(FStopEventName);
      if StopEventHandle = 0 then
        raise Exception.CreateFmt('worker[%d] unable to open stop event "%s" (error %d)',
          [FWorkerId, FStopEventName, GetLastError]);
      QuitEventHandle := OpenSignalEvent(FQuitEventName);
      if QuitEventHandle = 0 then
        raise Exception.CreateFmt('worker[%d] unable to open quit event "%s" (error %d)',
          [FWorkerId, FQuitEventName, GetLastError]);
      ReadyEventHandle := OpenSignalEvent(FReadyEventName, EVENT_MODIFY_STATE);
      if ReadyEventHandle = 0 then
        raise Exception.CreateFmt('worker[%d] unable to open ready event "%s" (error %d)',
          [FWorkerId, FReadyEventName, GetLastError]);

      if FParentPid <> 0 then
        ParentHandle := OpenProcess(SYNCHRONIZE, False, FParentPid);

      HandleCount := 0;
      WaitHandles[HandleCount] := StopEventHandle;
      Inc(HandleCount);
      WaitHandles[HandleCount] := QuitEventHandle;
      Inc(HandleCount);
      if ParentHandle <> 0 then
      begin
        WaitHandles[HandleCount] := ParentHandle;
        Inc(HandleCount);
      end;

      FLogger.Log(rlInfo, Format(
        'worker[%d] pid=%d started',
        [FWorkerId, GetCurrentProcessId]));
      if not SetEvent(ReadyEventHandle) then
        raise Exception.CreateFmt(
          'worker[%d] unable to signal ready event "%s" (error %d)',
          [FWorkerId, FReadyEventName, GetLastError]);

      WaitResult := WaitForMultipleObjects(HandleCount, @WaitHandles[0], False, INFINITE);
      case WaitResult of
        WAIT_OBJECT_0:
          begin
            ShutdownFast := True;
            FLogger.Log(rlInfo, Format('worker[%d] stop event received', [FWorkerId]));
          end;
        WAIT_OBJECT_0 + 1:
          begin
            ShutdownFast := False;
            FLogger.Log(rlInfo, Format('worker[%d] quit event received', [FWorkerId]));
          end;
        WAIT_OBJECT_0 + 2:
          begin
            ShutdownFast := False;
            FLogger.Log(rlWarn, Format('worker[%d] parent process exited', [FWorkerId]));
          end;
      else
        begin
          ShutdownFast := True;
          FLogger.Log(rlWarn, Format(
            'worker[%d] wait returned unexpected result %d',
            [FWorkerId, WaitResult]));
        end;
      end;

      if Assigned(FStreamServer) then
        FStreamServer.Stop(ShutdownFast);
      if Assigned(FHttpServer) then
        FHttpServer.Stop(ShutdownFast);

      Result := 0;
    except
      on E: Exception do
      begin
        if Assigned(FLogger) then
          FLogger.Log(rlError, Format(
            'worker[%d] fatal startup/runtime error: %s',
            [FWorkerId, E.Message]))
        else
          Writeln(Format('worker[%d] fatal startup/runtime error: %s', [FWorkerId, E.Message]));
        AppendWorkerCrashLog(
          FWorkerId,
          Format(
            'fatal startup/runtime error: %s: %s (config="%s", prefix="%s")',
            [E.ClassName, E.Message, FConfigPath, FPrefix]));
        Result := 1;
      end;
    end;
  finally
    if ParentHandle <> 0 then
      CloseHandle(ParentHandle);
    if ReadyEventHandle <> 0 then
      CloseHandle(ReadyEventHandle);
    if QuitEventHandle <> 0 then
      CloseHandle(QuitEventHandle);
    if StopEventHandle <> 0 then
      CloseHandle(StopEventHandle);
  end;
end;

end.
