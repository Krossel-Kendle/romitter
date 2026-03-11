unit Romitter.Master;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Winapi.Windows,
  Romitter.Control,
  Romitter.Config.Model,
  Romitter.Logging,
  Romitter.HttpServer,
  Romitter.StreamServer;

type
  TRomitterMaster = class
  private
    FConfigPath: string;
    FPrefix: string;
    FPipeName: string;
    FInstanceMutexName: string;
    FInstanceMutex: THandle;
    FSignalEvent: THandle;
    FSignalLock: TObject;
    FPendingSignal: TRomitterSignal;
    FConfig: TRomitterConfig;
    FLogger: TRomitterLogger;
    FHttpServer: TRomitterHttpServer;
    FStreamServer: TRomitterStreamServer;
    FControl: TRomitterControlServer;
    FWorkerModeEnabled: Boolean;
    FWorkerProcessHandles: TList<THandle>;
    FWorkerProcessIds: TList<Cardinal>;
    FWorkerIds: TList<Integer>;
    FWorkerReadyEventNames: TList<string>;
    FWorkerReadyEvents: TList<THandle>;
    FWorkerQuitEventName: string;
    FWorkerStopEventName: string;
    FWorkerQuitEvent: THandle;
    FWorkerStopEvent: THandle;
    FWorkerGeneration: Integer;
    FNextWorkerId: Integer;
    FWorkerShutdownInProgress: Boolean;
    procedure SetPendingSignal(const Signal: TRomitterSignal);
    function PullPendingSignal: TRomitterSignal;
    procedure ControlSignalHandler(const Signal: TRomitterSignal);
    procedure WritePidFile;
    procedure RemovePidFile;
    function BuildWorkerEventName(const Suffix: string): string;
    procedure EnsureWorkerEvents;
    procedure CloseWorkerEvents;
    procedure RemoveWorkerAt(const Index: Integer);
    procedure ShutdownWorkerPoolSnapshot(
      const ProcessHandles: TList<THandle>;
      const ProcessIds: TList<Cardinal>;
      const WorkerIds: TList<Integer>;
      const WorkerReadyEventNames: TList<string>;
      const WorkerReadyEvents: TList<THandle>;
      const QuitEvent, StopEvent: THandle;
      const FastShutdown: Boolean);
    function SpawnWorkerProcess(const WorkerId: Integer): Boolean;
    function StartWorkerPool(const WorkerCount: Integer): Boolean;
    procedure StopWorkerPool(const FastShutdown: Boolean);
    procedure MonitorWorkerPool;
    procedure StartSingleRuntime;
    procedure StopSingleRuntime(const FastShutdown: Boolean);
    procedure StartCurrentRuntime;
    procedure StopCurrentRuntime(const FastShutdown: Boolean);
    procedure AcquireInstanceMutex;
    procedure ReleaseInstanceMutex;
    function ReloadRuntime: Boolean;
  public
    constructor Create(const ConfigPath, Prefix: string);
    destructor Destroy; override;
    function Run: Integer;
    procedure RequestSignal(const Signal: TRomitterSignal);
    property PipeName: string read FPipeName;
  end;

implementation

uses
  System.Classes,
  System.IOUtils,
  Romitter.Config.Loader,
  Romitter.Constants,
  Romitter.Utils;

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

constructor TRomitterMaster.Create(const ConfigPath, Prefix: string);
begin
  inherited Create;
  FConfigPath := ConfigPath;
  FPrefix := Prefix;
  FPipeName := BuildControlPipeName(FPrefix, FConfigPath);
  FInstanceMutexName := StringReplace(
    StringReplace(FPipeName, '\\.\pipe\', 'Local\', [rfIgnoreCase]),
    '\',
    '-',
    [rfReplaceAll]);
  FInstanceMutex := 0;
  FSignalEvent := CreateEvent(nil, False, False, nil);
  if FSignalEvent = 0 then
    raise Exception.Create('Unable to create master signal event');
  FSignalLock := TObject.Create;
  FPendingSignal := rsNone;
  FConfig := nil;
  FLogger := nil;
  FHttpServer := nil;
  FStreamServer := nil;
  FControl := nil;
  FWorkerModeEnabled := False;
  FWorkerProcessHandles := TList<THandle>.Create;
  FWorkerProcessIds := TList<Cardinal>.Create;
  FWorkerIds := TList<Integer>.Create;
  FWorkerReadyEventNames := TList<string>.Create;
  FWorkerReadyEvents := TList<THandle>.Create;
  FWorkerQuitEventName := '';
  FWorkerStopEventName := '';
  FWorkerQuitEvent := 0;
  FWorkerStopEvent := 0;
  FWorkerGeneration := 1;
  FNextWorkerId := 1;
  FWorkerShutdownInProgress := False;
end;

destructor TRomitterMaster.Destroy;
begin
  StopCurrentRuntime(True);
  CloseWorkerEvents;
  RemovePidFile;
  ReleaseInstanceMutex;
  FControl.Free;
  FStreamServer.Free;
  FHttpServer.Free;
  FLogger.Free;
  FConfig.Free;
  FWorkerReadyEvents.Free;
  FWorkerReadyEventNames.Free;
  FWorkerIds.Free;
  FWorkerProcessIds.Free;
  FWorkerProcessHandles.Free;
  FSignalLock.Free;
  if FSignalEvent <> 0 then
    CloseHandle(FSignalEvent);
  inherited;
end;

procedure TRomitterMaster.SetPendingSignal(const Signal: TRomitterSignal);
begin
  TMonitor.Enter(FSignalLock);
  try
    case Signal of
      rsStop,
      rsQuit:
        FPendingSignal := Signal;
      rsReload:
        if FPendingSignal = rsNone then
          FPendingSignal := Signal;
    end;
    SetEvent(FSignalEvent);
  finally
    TMonitor.Exit(FSignalLock);
  end;
end;

function TRomitterMaster.PullPendingSignal: TRomitterSignal;
begin
  TMonitor.Enter(FSignalLock);
  try
    Result := FPendingSignal;
    FPendingSignal := rsNone;
  finally
    TMonitor.Exit(FSignalLock);
  end;
end;

procedure TRomitterMaster.ControlSignalHandler(const Signal: TRomitterSignal);
begin
  RequestSignal(Signal);
end;

procedure TRomitterMaster.RequestSignal(const Signal: TRomitterSignal);
begin
  if Signal = rsNone then
    Exit;
  SetPendingSignal(Signal);
end;

procedure TRomitterMaster.WritePidFile;
begin
  EnsureDirectoryForFile(FConfig.PidFile);
  TFile.WriteAllText(FConfig.PidFile, IntToStr(GetCurrentProcessId), TEncoding.ASCII);
end;

procedure TRomitterMaster.RemovePidFile;
begin
  if (FConfig <> nil) and TFile.Exists(FConfig.PidFile) then
    TFile.Delete(FConfig.PidFile);
end;

function TRomitterMaster.BuildWorkerEventName(const Suffix: string): string;
var
  BaseName: string;
  I: Integer;
begin
  BaseName := FPipeName;
  if Pos('\\.\pipe\', LowerCase(BaseName)) = 1 then
    Delete(BaseName, 1, Length('\\.\pipe\'));

  for I := 1 to Length(BaseName) do
    if CharInSet(BaseName[I], ['\', '/', ':', '*', '?', '"', '<', '>', '|']) then
      BaseName[I] := '-';

  Result := Format(
    'Local\%s-g%d-%s',
    [BaseName, FWorkerGeneration, Suffix]);
end;

procedure TRomitterMaster.EnsureWorkerEvents;
begin
  if FWorkerQuitEventName = '' then
    FWorkerQuitEventName := BuildWorkerEventName('worker-quit');
  if FWorkerStopEventName = '' then
    FWorkerStopEventName := BuildWorkerEventName('worker-stop');

  if FWorkerQuitEvent = 0 then
  begin
    FWorkerQuitEvent := CreateEvent(nil, True, False, PChar(FWorkerQuitEventName));
    if FWorkerQuitEvent = 0 then
      raise Exception.CreateFmt(
        'unable to create worker quit event "%s" (error %d)',
        [FWorkerQuitEventName, GetLastError]);
  end;

  if FWorkerStopEvent = 0 then
  begin
    FWorkerStopEvent := CreateEvent(nil, True, False, PChar(FWorkerStopEventName));
    if FWorkerStopEvent = 0 then
      raise Exception.CreateFmt(
        'unable to create worker stop event "%s" (error %d)',
        [FWorkerStopEventName, GetLastError]);
  end;
end;

procedure TRomitterMaster.CloseWorkerEvents;
begin
  if FWorkerQuitEvent <> 0 then
  begin
    CloseHandle(FWorkerQuitEvent);
    FWorkerQuitEvent := 0;
  end;
  if FWorkerStopEvent <> 0 then
  begin
    CloseHandle(FWorkerStopEvent);
    FWorkerStopEvent := 0;
  end;
end;

procedure TRomitterMaster.RemoveWorkerAt(const Index: Integer);
var
  ProcessHandle: THandle;
  ReadyEventHandle: THandle;
begin
  if (Index < 0) or (Index >= FWorkerProcessHandles.Count) then
    Exit;
  ProcessHandle := FWorkerProcessHandles[Index];
  if ProcessHandle <> 0 then
    CloseHandle(ProcessHandle);
  if (Index >= 0) and (Index < FWorkerReadyEvents.Count) then
  begin
    ReadyEventHandle := FWorkerReadyEvents[Index];
    if ReadyEventHandle <> 0 then
      CloseHandle(ReadyEventHandle);
    FWorkerReadyEvents.Delete(Index);
  end;
  if (Index >= 0) and (Index < FWorkerReadyEventNames.Count) then
    FWorkerReadyEventNames.Delete(Index);
  FWorkerProcessHandles.Delete(Index);
  FWorkerProcessIds.Delete(Index);
  FWorkerIds.Delete(Index);
end;

procedure TRomitterMaster.ShutdownWorkerPoolSnapshot(
  const ProcessHandles: TList<THandle>;
  const ProcessIds: TList<Cardinal>;
  const WorkerIds: TList<Integer>;
  const WorkerReadyEventNames: TList<string>;
  const WorkerReadyEvents: TList<THandle>;
  const QuitEvent, StopEvent: THandle;
  const FastShutdown: Boolean);
var
  I: Integer;
  WaitResult: DWORD;
  WaitTimeoutMs: DWORD;
  DeadlineTick: UInt64;
  AllExited: Boolean;
  WorkerId: Integer;
  WorkerPid: Cardinal;
begin
  if ProcessHandles <> nil then
  begin
    if ProcessHandles.Count > 0 then
    begin
      if FastShutdown then
      begin
        if StopEvent <> 0 then
          SetEvent(StopEvent);
      end
      else if QuitEvent <> 0 then
        SetEvent(QuitEvent);

      if FastShutdown then
        WaitTimeoutMs := 5000
      else
        WaitTimeoutMs := 30000;

      DeadlineTick := GetTickCount64 + WaitTimeoutMs;
      repeat
        AllExited := True;
        for I := 0 to ProcessHandles.Count - 1 do
        begin
          if ProcessHandles[I] = 0 then
            Continue;
          WaitResult := WaitForSingleObject(ProcessHandles[I], 0);
          if WaitResult <> WAIT_OBJECT_0 then
          begin
            AllExited := False;
            Break;
          end;
        end;
        if AllExited or (GetTickCount64 >= DeadlineTick) then
          Break;
        Sleep(25);
      until False;

      for I := 0 to ProcessHandles.Count - 1 do
      begin
        if ProcessHandles[I] = 0 then
          Continue;
        WaitResult := WaitForSingleObject(ProcessHandles[I], 0);
        if WaitResult <> WAIT_OBJECT_0 then
        begin
          if (WorkerIds <> nil) and (I < WorkerIds.Count) then
            WorkerId := WorkerIds[I]
          else
            WorkerId := -1;
          if (ProcessIds <> nil) and (I < ProcessIds.Count) then
            WorkerPid := ProcessIds[I]
          else
            WorkerPid := 0;
          if FastShutdown then
          begin
            FLogger.Log(rlWarn, Format(
              'worker[%d] pid=%d did not exit in time, terminating',
              [WorkerId, WorkerPid]));
            TerminateProcess(ProcessHandles[I], 1);
            WaitForSingleObject(ProcessHandles[I], 2000);
          end
          else
            FLogger.Log(rlInfo, Format(
              'worker[%d] pid=%d is still draining after reload; detached',
              [WorkerId, WorkerPid]));
        end;
      end;
    end;

    for I := 0 to ProcessHandles.Count - 1 do
      if ProcessHandles[I] <> 0 then
        CloseHandle(ProcessHandles[I]);
    ProcessHandles.Free;
  end;

  if ProcessIds <> nil then
    ProcessIds.Free;
  if WorkerIds <> nil then
    WorkerIds.Free;
  if WorkerReadyEventNames <> nil then
    WorkerReadyEventNames.Free;
  if WorkerReadyEvents <> nil then
  begin
    for I := 0 to WorkerReadyEvents.Count - 1 do
      if WorkerReadyEvents[I] <> 0 then
        CloseHandle(WorkerReadyEvents[I]);
    WorkerReadyEvents.Free;
  end;

  if QuitEvent <> 0 then
    CloseHandle(QuitEvent);
  if StopEvent <> 0 then
    CloseHandle(StopEvent);
end;

function TRomitterMaster.SpawnWorkerProcess(const WorkerId: Integer): Boolean;
var
  StartupInfo: TStartupInfo;
  ProcessInfo: TProcessInformation;
  CommandLine: string;
  ReadyEventName: string;
  ReadyEventHandle: THandle;
begin
  Result := False;
  ReadyEventHandle := 0;
  ReadyEventName := BuildWorkerEventName(Format('worker-%d-ready', [WorkerId]));
  ReadyEventHandle := CreateEvent(nil, True, False, PChar(ReadyEventName));
  if ReadyEventHandle = 0 then
  begin
    FLogger.Log(rlError, Format(
      'failed to create ready event for worker[%d] (error %d)',
      [WorkerId, GetLastError]));
    Exit(False);
  end;

  FillChar(StartupInfo, SizeOf(StartupInfo), 0);
  FillChar(ProcessInfo, SizeOf(ProcessInfo), 0);
  StartupInfo.cb := SizeOf(StartupInfo);

  CommandLine := Format(
    '"%s" --worker --worker-id %d --worker-quit-event "%s" --worker-stop-event "%s" --worker-ready-event "%s" --worker-parent-pid %d -c "%s"',
    [
      ParamStr(0),
      WorkerId,
      FWorkerQuitEventName,
      FWorkerStopEventName,
      ReadyEventName,
      GetCurrentProcessId,
      FConfigPath
    ]);
  if FPrefix <> '' then
    CommandLine := CommandLine + Format(' -p "%s"', [FPrefix]);

  if not CreateProcess(
    nil,
    PChar(CommandLine),
    nil,
    nil,
    False,
    CREATE_NO_WINDOW,
    nil,
    nil,
    StartupInfo,
    ProcessInfo) then
  begin
    CloseHandle(ReadyEventHandle);
    FLogger.Log(rlError, Format(
      'failed to spawn worker[%d] (error %d)',
      [WorkerId, GetLastError]));
    Exit(False);
  end;

  CloseHandle(ProcessInfo.hThread);
  FWorkerProcessHandles.Add(ProcessInfo.hProcess);
  FWorkerProcessIds.Add(ProcessInfo.dwProcessId);
  FWorkerIds.Add(WorkerId);
  FWorkerReadyEventNames.Add(ReadyEventName);
  FWorkerReadyEvents.Add(ReadyEventHandle);
  FLogger.Log(rlInfo, Format(
    'worker[%d] pid=%d spawned',
    [WorkerId, ProcessInfo.dwProcessId]));
  Result := True;
end;

function TRomitterMaster.StartWorkerPool(const WorkerCount: Integer): Boolean;
var
  I: Integer;
  WaitResult: DWORD;
  ReadyWaitResult: DWORD;
  ReadyTimeoutMs: DWORD;
  ExitCode: DWORD;
  function FallbackToSingleWorker(const ReasonText: string): Boolean;
  begin
    if WorkerCount <= 1 then
      Exit(False);
    FLogger.Log(rlWarn, Format(
      'multi-worker startup failed (%s); falling back to a single worker process',
      [ReasonText]));
    StopWorkerPool(True);
    Result := StartWorkerPool(1);
  end;
begin
  Result := False;
  if WorkerCount < 1 then
    Exit(True);

  EnsureWorkerEvents;
  ResetEvent(FWorkerQuitEvent);
  ResetEvent(FWorkerStopEvent);
  FWorkerShutdownInProgress := False;

  for I := 1 to WorkerCount do
  begin
    if not SpawnWorkerProcess(FNextWorkerId) then
    begin
      if FallbackToSingleWorker('spawn failed') then
        Exit(True);
      StopWorkerPool(True);
      Exit(False);
    end;
    Inc(FNextWorkerId);
  end;

  Sleep(100);
  for I := 0 to FWorkerProcessHandles.Count - 1 do
  begin
    WaitResult := WaitForSingleObject(FWorkerProcessHandles[I], 0);
    if WaitResult <> WAIT_OBJECT_0 then
      Continue;
    ExitCode := 0;
    GetExitCodeProcess(FWorkerProcessHandles[I], ExitCode);
    FLogger.Log(rlError, Format(
      'worker[%d] pid=%d exited immediately after start (code %d)',
      [FWorkerIds[I], FWorkerProcessIds[I], ExitCode]));
    if FallbackToSingleWorker('worker exited immediately') then
      Exit(True);
    StopWorkerPool(True);
    Exit(False);
  end;

  ReadyTimeoutMs := 15000;
  for I := 0 to FWorkerReadyEvents.Count - 1 do
  begin
    ReadyWaitResult := WaitForSingleObject(FWorkerReadyEvents[I], ReadyTimeoutMs);
    if ReadyWaitResult = WAIT_OBJECT_0 then
      Continue;

    if ReadyWaitResult = WAIT_TIMEOUT then
      FLogger.Log(rlError, Format(
        'worker[%d] pid=%d did not become ready in %d ms',
        [FWorkerIds[I], FWorkerProcessIds[I], ReadyTimeoutMs]))
    else
      FLogger.Log(rlError, Format(
        'worker[%d] pid=%d ready wait failed (result %d)',
        [FWorkerIds[I], FWorkerProcessIds[I], ReadyWaitResult]));
    if FallbackToSingleWorker('worker did not become ready') then
      Exit(True);
    StopWorkerPool(True);
    Exit(False);
  end;

  Result := True;
end;

procedure TRomitterMaster.StopWorkerPool(const FastShutdown: Boolean);
var
  I: Integer;
  WaitResult: DWORD;
  WaitTimeoutMs: DWORD;
  DeadlineTick: UInt64;
  AllExited: Boolean;
begin
  if FWorkerProcessHandles.Count = 0 then
    Exit;

  FWorkerShutdownInProgress := True;
  if FastShutdown then
  begin
    if FWorkerStopEvent <> 0 then
      SetEvent(FWorkerStopEvent);
  end
  else if FWorkerQuitEvent <> 0 then
    SetEvent(FWorkerQuitEvent);

  if FastShutdown then
    WaitTimeoutMs := 5000
  else
    WaitTimeoutMs := 30000;

  if FastShutdown then
  begin
    DeadlineTick := GetTickCount64 + WaitTimeoutMs;
    repeat
      AllExited := True;
      for I := 0 to FWorkerProcessHandles.Count - 1 do
      begin
        if FWorkerProcessHandles[I] = 0 then
          Continue;
        WaitResult := WaitForSingleObject(FWorkerProcessHandles[I], 0);
        if WaitResult <> WAIT_OBJECT_0 then
        begin
          AllExited := False;
          Break;
        end;
      end;
      if AllExited or (GetTickCount64 >= DeadlineTick) then
        Break;
      Sleep(25);
    until False;
  end
  else
  begin
    repeat
      AllExited := True;
      for I := 0 to FWorkerProcessHandles.Count - 1 do
      begin
        if FWorkerProcessHandles[I] = 0 then
          Continue;
        WaitResult := WaitForSingleObject(FWorkerProcessHandles[I], 0);
        if WaitResult <> WAIT_OBJECT_0 then
        begin
          AllExited := False;
          Break;
        end;
      end;
      if AllExited then
        Break;
      Sleep(25);
    until False;
  end;

  for I := 0 to FWorkerProcessHandles.Count - 1 do
  begin
    if FWorkerProcessHandles[I] = 0 then
      Continue;
    WaitResult := WaitForSingleObject(FWorkerProcessHandles[I], 0);
    if FastShutdown and (WaitResult <> WAIT_OBJECT_0) then
    begin
      FLogger.Log(rlWarn, Format(
        'worker[%d] pid=%d did not exit in time, terminating',
        [FWorkerIds[I], FWorkerProcessIds[I]]));
      TerminateProcess(FWorkerProcessHandles[I], 1);
      WaitForSingleObject(FWorkerProcessHandles[I], 2000);
    end;
  end;

  for I := FWorkerProcessHandles.Count - 1 downto 0 do
    RemoveWorkerAt(I);

  if FWorkerQuitEvent <> 0 then
    ResetEvent(FWorkerQuitEvent);
  if FWorkerStopEvent <> 0 then
    ResetEvent(FWorkerStopEvent);
  FWorkerShutdownInProgress := False;
end;

procedure TRomitterMaster.MonitorWorkerPool;
var
  I: Integer;
  WaitResult: DWORD;
  ExitCode: DWORD;
  ExpectedWorkers: Integer;
  ReadyWaitResult: DWORD;
begin
  if not FWorkerModeEnabled then
    Exit;

  for I := FWorkerProcessHandles.Count - 1 downto 0 do
  begin
    WaitResult := WaitForSingleObject(FWorkerProcessHandles[I], 0);
    if WaitResult <> WAIT_OBJECT_0 then
      Continue;

    ExitCode := 0;
    GetExitCodeProcess(FWorkerProcessHandles[I], ExitCode);
    FLogger.Log(rlWarn, Format(
      'worker[%d] pid=%d exited with code %d',
      [FWorkerIds[I], FWorkerProcessIds[I], ExitCode]));
    RemoveWorkerAt(I);
  end;

  if FWorkerShutdownInProgress then
    Exit;

  ExpectedWorkers := FConfig.EffectiveWorkerProcesses;
  while FWorkerProcessHandles.Count < ExpectedWorkers do
  begin
    if not SpawnWorkerProcess(FNextWorkerId) then
    begin
      FLogger.Log(rlError, 'worker respawn failed; initiating shutdown');
      RequestSignal(rsQuit);
      Break;
    end;
    ReadyWaitResult := WaitForSingleObject(
      FWorkerReadyEvents[FWorkerReadyEvents.Count - 1],
      15000);
    if ReadyWaitResult <> WAIT_OBJECT_0 then
    begin
      FLogger.Log(rlError, Format(
        'worker[%d] pid=%d did not become ready after respawn (wait=%d)',
        [
          FWorkerIds[FWorkerIds.Count - 1],
          FWorkerProcessIds[FWorkerProcessIds.Count - 1],
          ReadyWaitResult
        ]));
      RequestSignal(rsQuit);
      Break;
    end;
    Inc(FNextWorkerId);
  end;
end;

procedure TRomitterMaster.StartSingleRuntime;
begin
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
    FLogger.Log(rlWarn, 'No http{} or stream{} blocks enabled; runtime has no listeners');
end;

procedure TRomitterMaster.StopSingleRuntime(const FastShutdown: Boolean);
begin
  if Assigned(FStreamServer) then
  begin
    FStreamServer.Stop(FastShutdown);
    FreeAndNil(FStreamServer);
  end;
  if Assigned(FHttpServer) then
  begin
    FHttpServer.Stop(FastShutdown);
    FreeAndNil(FHttpServer);
  end;
end;

procedure TRomitterMaster.StartCurrentRuntime;
var
  WorkerCount: Integer;
begin
  if not FConfig.MasterProcess then
  begin
    FWorkerModeEnabled := False;
    StartSingleRuntime;
    FLogger.Log(rlInfo,
      'master_process off: running in single-process mode');
    Exit;
  end;

  WorkerCount := FConfig.EffectiveWorkerProcesses;
  if WorkerCount < 1 then
    WorkerCount := 1;

  FWorkerModeEnabled := True;
  if not StartWorkerPool(WorkerCount) then
    raise Exception.Create('unable to start worker pool');
  FLogger.Log(rlInfo, Format('worker pool started: %d processes', [WorkerCount]));
end;

procedure TRomitterMaster.StopCurrentRuntime(const FastShutdown: Boolean);
begin
  if FWorkerModeEnabled then
    StopWorkerPool(FastShutdown)
  else
    StopSingleRuntime(FastShutdown);
  FWorkerModeEnabled := False;
end;

procedure TRomitterMaster.AcquireInstanceMutex;
var
  LastErrorCode: DWORD;
begin
  if FInstanceMutex <> 0 then
    Exit;

  FInstanceMutex := CreateMutex(nil, True, PChar(FInstanceMutexName));
  if FInstanceMutex = 0 then
    raise Exception.CreateFmt(
      'unable to acquire instance lock "%s" (error %d)',
      [FInstanceMutexName, GetLastError]);

  LastErrorCode := GetLastError;
  if (LastErrorCode = ERROR_ALREADY_EXISTS) or
     (LastErrorCode = ERROR_ACCESS_DENIED) then
  begin
    CloseHandle(FInstanceMutex);
    FInstanceMutex := 0;
    raise Exception.CreateFmt(
      'another master instance is already running for this config (lock "%s")',
      [FInstanceMutexName]);
  end;
end;

procedure TRomitterMaster.ReleaseInstanceMutex;
begin
  if FInstanceMutex = 0 then
    Exit;
  ReleaseMutex(FInstanceMutex);
  CloseHandle(FInstanceMutex);
  FInstanceMutex := 0;
end;

function TRomitterMaster.ReloadRuntime: Boolean;
var
  NewConfig: TRomitterConfig;
  OldConfig: TRomitterConfig;
  OldProcessHandles: TList<THandle>;
  OldProcessIds: TList<Cardinal>;
  OldWorkerIds: TList<Integer>;
  OldWorkerReadyEventNames: TList<string>;
  OldWorkerReadyEvents: TList<THandle>;
  OldQuitEvent: THandle;
  OldStopEvent: THandle;
  OldQuitEventName: string;
  OldStopEventName: string;
  OldWorkerGeneration: Integer;
begin
  Result := False;
  NewConfig := nil;
  OldConfig := nil;
  OldProcessHandles := nil;
  OldProcessIds := nil;
  OldWorkerIds := nil;
  OldWorkerReadyEventNames := nil;
  OldWorkerReadyEvents := nil;
  OldQuitEvent := 0;
  OldStopEvent := 0;
  OldQuitEventName := '';
  OldStopEventName := '';
  OldWorkerGeneration := 0;

  if not FWorkerModeEnabled then
  begin
    FLogger.Log(rlError,
      'Reload requested while worker mode is disabled; forcing graceful stop/start');
    Exit(False);
  end;

  OldConfig := FConfig;

  try
    NewConfig := TRomitterConfigLoader.LoadFromFile(FConfigPath, FPrefix);
  except
    on E: Exception do
    begin
      FLogger.Log(rlError, 'Reload failed while parsing config: ' + E.Message);
      Exit(False);
    end;
  end;

  try
    OldProcessHandles := FWorkerProcessHandles;
    OldProcessIds := FWorkerProcessIds;
    OldWorkerIds := FWorkerIds;
    OldWorkerReadyEventNames := FWorkerReadyEventNames;
    OldWorkerReadyEvents := FWorkerReadyEvents;
    OldQuitEvent := FWorkerQuitEvent;
    OldStopEvent := FWorkerStopEvent;
    OldQuitEventName := FWorkerQuitEventName;
    OldStopEventName := FWorkerStopEventName;
    OldWorkerGeneration := FWorkerGeneration;

    FWorkerProcessHandles := TList<THandle>.Create;
    FWorkerProcessIds := TList<Cardinal>.Create;
    FWorkerIds := TList<Integer>.Create;
    FWorkerReadyEventNames := TList<string>.Create;
    FWorkerReadyEvents := TList<THandle>.Create;
    FWorkerQuitEvent := 0;
    FWorkerStopEvent := 0;
    FWorkerQuitEventName := '';
    FWorkerStopEventName := '';
    FWorkerShutdownInProgress := False;
    Inc(FWorkerGeneration);

    FConfig := NewConfig;
    NewConfig := nil;

    try
      StartCurrentRuntime;
    except
      on E: Exception do
      begin
        FLogger.Log(rlError, 'Reload failed while starting new runtime: ' + E.Message);
        StopCurrentRuntime(True);

        FWorkerProcessHandles.Free;
        FWorkerProcessIds.Free;
        FWorkerIds.Free;
        FWorkerReadyEventNames.Free;
        FWorkerReadyEvents.Free;
        FWorkerProcessHandles := OldProcessHandles;
        FWorkerProcessIds := OldProcessIds;
        FWorkerIds := OldWorkerIds;
        FWorkerReadyEventNames := OldWorkerReadyEventNames;
        FWorkerReadyEvents := OldWorkerReadyEvents;
        OldProcessHandles := nil;
        OldProcessIds := nil;
        OldWorkerIds := nil;
        OldWorkerReadyEventNames := nil;
        OldWorkerReadyEvents := nil;

        if FWorkerQuitEvent <> 0 then
          CloseHandle(FWorkerQuitEvent);
        if FWorkerStopEvent <> 0 then
          CloseHandle(FWorkerStopEvent);
        FWorkerQuitEvent := OldQuitEvent;
        FWorkerStopEvent := OldStopEvent;
        FWorkerQuitEventName := OldQuitEventName;
        FWorkerStopEventName := OldStopEventName;
        OldQuitEvent := 0;
        OldStopEvent := 0;
        OldQuitEventName := '';
        OldStopEventName := '';

        FWorkerGeneration := OldWorkerGeneration;
        FWorkerModeEnabled := True;
        FWorkerShutdownInProgress := False;

        if Assigned(FConfig) and (FConfig <> OldConfig) then
        begin
          FConfig.Free;
          FConfig := nil;
        end;
        FConfig := OldConfig;
        OldConfig := nil;

        FLogger.Log(rlWarn, 'Old runtime kept active after failed reload');
        Exit(False);
      end;
    end;

    ShutdownWorkerPoolSnapshot(
      OldProcessHandles,
      OldProcessIds,
      OldWorkerIds,
      OldWorkerReadyEventNames,
      OldWorkerReadyEvents,
      OldQuitEvent,
      OldStopEvent,
      False);
    OldProcessHandles := nil;
    OldProcessIds := nil;
    OldWorkerIds := nil;
    OldWorkerReadyEventNames := nil;
    OldWorkerReadyEvents := nil;
    OldQuitEvent := 0;
    OldStopEvent := 0;
    OldQuitEventName := '';
    OldStopEventName := '';

    OldConfig.Free;
    OldConfig := nil;
    WritePidFile;
    FLogger.Log(rlInfo, 'Reload successful');
    Result := True;
  finally
    NewConfig.Free;
    OldConfig.Free;
    if (OldProcessHandles <> nil) or (OldProcessIds <> nil) or
       (OldWorkerIds <> nil) or
       (OldWorkerReadyEventNames <> nil) or
       (OldWorkerReadyEvents <> nil) or
       (OldQuitEvent <> 0) or
       (OldStopEvent <> 0) then
      ShutdownWorkerPoolSnapshot(
        OldProcessHandles,
        OldProcessIds,
        OldWorkerIds,
        OldWorkerReadyEventNames,
        OldWorkerReadyEvents,
        OldQuitEvent,
        OldStopEvent,
        True);
  end;
end;

function TRomitterMaster.Run: Integer;
var
  Signal: TRomitterSignal;
  ShutdownSignal: TRomitterSignal;
  WaitResult: DWORD;
begin
  Result := 1;
  ShutdownSignal := rsQuit;
  try
    AcquireInstanceMutex;
    FConfig := TRomitterConfigLoader.LoadFromFile(FConfigPath, FPrefix);
    if SameText(FConfig.ErrorLogFile, 'stderr') then
      FLogger := TRomitterLogger.Create('', True)
    else
      FLogger := TRomitterLogger.Create(FConfig.ErrorLogFile, True);
    FLogger.MinLevel := MapErrorLogLevelToMinLevel(FConfig.ErrorLogLevel);

    FControl := TRomitterControlServer.Create(FPipeName, ControlSignalHandler, FLogger);
    FControl.Start;

    WritePidFile;
    StartCurrentRuntime;

    FLogger.Log(rlInfo, Format('%s/%s master started', [ROMITTER_NAME, ROMITTER_VERSION]));
    FLogger.Log(rlInfo, Format('control pipe: %s', [FPipeName]));
    FLogger.Log(rlInfo, Format('worker_processes=%d worker_connections=%d',
      [FConfig.EffectiveWorkerProcesses, FConfig.Events.WorkerConnections]));

    Result := 0;
    while True do
    begin
      WaitResult := WaitForSingleObject(FSignalEvent, 1000);
      if WaitResult = WAIT_TIMEOUT then
      begin
        MonitorWorkerPool;
        Continue;
      end;

      if WaitResult <> WAIT_OBJECT_0 then
      begin
        FLogger.Log(rlWarn, 'Master wait returned unexpected result');
        Continue;
      end;

      Signal := PullPendingSignal;
      case Signal of
        rsReload:
          ReloadRuntime;
        rsStop:
          begin
            FLogger.Log(rlInfo, 'Stop signal received (fast shutdown)');
            ShutdownSignal := rsStop;
            Break;
          end;
        rsQuit:
          begin
            FLogger.Log(rlInfo, 'Quit signal received (graceful shutdown)');
            ShutdownSignal := rsQuit;
            Break;
          end;
      end;
    end;
  finally
    if Assigned(FControl) then
      FControl.Stop;
    StopCurrentRuntime(ShutdownSignal = rsStop);
    CloseWorkerEvents;
    RemovePidFile;
    ReleaseInstanceMutex;
    if Assigned(FLogger) then
      FLogger.Log(rlInfo, 'Master stopped');
  end;
end;

end.
