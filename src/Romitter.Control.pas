unit Romitter.Control;

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  Romitter.Logging;

type
  TRomitterSignal = (rsNone, rsStop, rsQuit, rsReload);

  TRomitterSignalEvent = procedure(const Signal: TRomitterSignal) of object;

  TRomitterControlServer = class
  private
    FPipeName: string;
    FOnSignal: TRomitterSignalEvent;
    FLogger: TRomitterLogger;
    FThread: TThread;
    FStopping: Boolean;
    procedure ExecuteLoop;
    procedure HandleSignalText(const Text: string);
  public
    constructor Create(const PipeName: string; const OnSignal: TRomitterSignalEvent;
      const Logger: TRomitterLogger);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

function SignalToText(const Signal: TRomitterSignal): string;
function TryParseSignal(const Value: string; out Signal: TRomitterSignal): Boolean;
function BuildControlPipeName(const Prefix, ConfigPath: string): string;
function SendSignalToMaster(const Prefix, ConfigPath: string;
  const Signal: TRomitterSignal; out ErrorMessage: string): Boolean;

implementation

uses
  System.IOUtils,
  Romitter.Utils;

const
  DEFAULT_PIPE_WAIT_MS = 2000;

procedure StartThreadCompat(const Thread: TThread);
begin
  if Thread = nil then
    Exit;

  {$WARN SYMBOL_DEPRECATED OFF}
  try
    Thread.Resume;
    Exit;
  except
    on Exception do
      if not Thread.Suspended then
        Exit;
  end;
  {$WARN SYMBOL_DEPRECATED ON}

  try
    Thread.Start;
    Exit;
  except
    on Exception do
      if not Thread.Suspended then
        Exit;
  end;

  if Thread.Suspended then
  begin
    {$WARN SYMBOL_DEPRECATED OFF}
    Thread.Resume;
    {$WARN SYMBOL_DEPRECATED ON}
  end;
end;

function SignalToText(const Signal: TRomitterSignal): string;
begin
  case Signal of
    rsStop: Result := 'stop';
    rsQuit: Result := 'quit';
    rsReload: Result := 'reload';
  else
    Result := '';
  end;
end;

function TryParseSignal(const Value: string; out Signal: TRomitterSignal): Boolean;
begin
  Signal := rsNone;
  if SameText(Value, 'stop') then
    Signal := rsStop
  else if SameText(Value, 'quit') then
    Signal := rsQuit
  else if SameText(Value, 'reload') then
    Signal := rsReload;

  Result := Signal <> rsNone;
end;

function Fnv1a32(const Text: string): Cardinal;
const
  FNV_OFFSET_BASIS: Cardinal = $811C9DC5;
  FNV_PRIME: Cardinal = $01000193;
var
  Bytes: TBytes;
  B: Byte;
begin
  Result := FNV_OFFSET_BASIS;
  Bytes := TEncoding.UTF8.GetBytes(Text);
  for B in Bytes do
  begin
    Result := Result xor B;
    Result := Result * FNV_PRIME;
  end;
end;

function BuildInstanceKey(const Prefix, ConfigPath: string): string;
var
  EffectivePrefix: string;
  EffectiveConfigPath: string;
  BasePath: string;
begin
  if Prefix <> '' then
    EffectivePrefix := TPath.GetFullPath(Prefix)
  else
    EffectivePrefix := TPath.GetFullPath(ExtractFilePath(ParamStr(0)));

  if EffectivePrefix = '' then
    EffectivePrefix := TPath.GetFullPath(GetCurrentDir);

  BasePath := EffectivePrefix;
  EffectiveConfigPath := ResolvePath(BasePath, ConfigPath);
  Result := LowerCase(EffectivePrefix) + '|' + LowerCase(EffectiveConfigPath);
end;

function BuildControlPipeName(const Prefix, ConfigPath: string): string;
begin
  Result := '\\.\pipe\romitter-' + IntToHex(Fnv1a32(BuildInstanceKey(Prefix, ConfigPath)), 8);
end;

function SendSignalToMaster(const Prefix, ConfigPath: string;
  const Signal: TRomitterSignal; out ErrorMessage: string): Boolean;
var
  PipeName: string;
  PipeHandle: THandle;
  Payload: AnsiString;
  BytesWritten: DWORD;
begin
  ErrorMessage := '';

  if Signal = rsNone then
  begin
    ErrorMessage := 'signal is empty';
    Exit(False);
  end;

  PipeName := BuildControlPipeName(Prefix, ConfigPath);
  if not WaitNamedPipe(PChar(PipeName), DEFAULT_PIPE_WAIT_MS) then
  begin
    ErrorMessage := Format('master control pipe is unavailable: %s (error %d)',
      [PipeName, GetLastError]);
    Exit(False);
  end;

  PipeHandle := CreateFile(
    PChar(PipeName),
    GENERIC_WRITE,
    0,
    nil,
    OPEN_EXISTING,
    0,
    0);

  if PipeHandle = INVALID_HANDLE_VALUE then
  begin
    ErrorMessage := Format('unable to connect to control pipe: %s (error %d)',
      [PipeName, GetLastError]);
    Exit(False);
  end;

  try
    Payload := AnsiString(SignalToText(Signal));
    if Length(Payload) = 0 then
    begin
      ErrorMessage := 'empty payload';
      Exit(False);
    end;

    if not WriteFile(PipeHandle, Payload[1], Length(Payload), BytesWritten, nil) then
    begin
      ErrorMessage := Format('unable to send signal to master (error %d)', [GetLastError]);
      Exit(False);
    end;

    if BytesWritten <> DWORD(Length(Payload)) then
    begin
      ErrorMessage := 'short write to control pipe';
      Exit(False);
    end;

    Result := True;
  finally
    CloseHandle(PipeHandle);
  end;
end;

constructor TRomitterControlServer.Create(const PipeName: string;
  const OnSignal: TRomitterSignalEvent; const Logger: TRomitterLogger);
begin
  inherited Create;
  FPipeName := PipeName;
  FOnSignal := OnSignal;
  FLogger := Logger;
  FThread := nil;
  FStopping := False;
end;

destructor TRomitterControlServer.Destroy;
begin
  Stop;
  inherited;
end;

procedure TRomitterControlServer.Start;
begin
  if Assigned(FThread) then
    Exit;

  FStopping := False;
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      ExecuteLoop;
    end);
  FThread.FreeOnTerminate := False;
  StartThreadCompat(FThread);
end;

procedure TRomitterControlServer.Stop;
var
  PipeHandle: THandle;
  BytesWritten: DWORD;
  WakePayload: AnsiString;
begin
  FStopping := True;

  if not Assigned(FThread) then
    Exit;

  PipeHandle := CreateFile(
    PChar(FPipeName),
    GENERIC_WRITE,
    0,
    nil,
    OPEN_EXISTING,
    0,
    0);
  if PipeHandle <> INVALID_HANDLE_VALUE then
  begin
    try
      WakePayload := AnsiString('quit');
      WriteFile(PipeHandle, WakePayload[1], Length(WakePayload), BytesWritten, nil);
    finally
      CloseHandle(PipeHandle);
    end;
  end;

  FThread.WaitFor;
  FreeAndNil(FThread);
end;

procedure TRomitterControlServer.HandleSignalText(const Text: string);
var
  Signal: TRomitterSignal;
begin
  if not TryParseSignal(Text, Signal) then
  begin
    if Assigned(FLogger) then
      FLogger.Log(rlWarn, 'Unknown control command ignored: ' + Text);
    Exit;
  end;

  if Assigned(FOnSignal) then
    FOnSignal(Signal);
end;

procedure TRomitterControlServer.ExecuteLoop;
var
  PipeHandle: THandle;
  Connected: BOOL;
  ErrorCode: DWORD;
  Buffer: array[0..127] of AnsiChar;
  BytesRead: DWORD;
  SignalText: string;
begin
  while not FStopping do
  begin
    PipeHandle := CreateNamedPipe(
      PChar(FPipeName),
      PIPE_ACCESS_INBOUND,
      PIPE_TYPE_MESSAGE or PIPE_READMODE_MESSAGE or PIPE_WAIT,
      1,
      0,
      128,
      0,
      nil);

    if PipeHandle = INVALID_HANDLE_VALUE then
    begin
      if Assigned(FLogger) then
        FLogger.Log(rlError, Format('CreateNamedPipe failed (%d)', [GetLastError]));
      Sleep(200);
      Continue;
    end;

    try
      Connected := ConnectNamedPipe(PipeHandle, nil);
      if not Connected then
      begin
        ErrorCode := GetLastError;
        if ErrorCode <> ERROR_PIPE_CONNECTED then
        begin
          if (ErrorCode <> ERROR_NO_DATA) and Assigned(FLogger) then
            FLogger.Log(rlWarn, Format('ConnectNamedPipe failed (%d)', [ErrorCode]));
          Continue;
        end;
      end;

      while not FStopping do
      begin
        BytesRead := 0;
        if not ReadFile(PipeHandle, Buffer[0], SizeOf(Buffer), BytesRead, nil) then
          Break;
        if BytesRead = 0 then
          Break;

        SetString(SignalText, PAnsiChar(@Buffer[0]), BytesRead);
        HandleSignalText(Trim(SignalText));
      end;
    finally
      DisconnectNamedPipe(PipeHandle);
      CloseHandle(PipeHandle);
    end;
  end;
end;

end.
