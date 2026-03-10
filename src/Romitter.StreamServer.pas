unit Romitter.StreamServer;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.Winsock2,
  Romitter.Config.Model,
  Romitter.Logging;

type
  TRomitterStreamAttemptKind = (sakOk, sakError, sakTimeout);

  TRomitterStreamListener = class
  public
    ListenHost: string;
    ListenPort: Word;
    IsUdp: Boolean;
    ListenSocket: TSocket;
    AcceptThread: TThread;
    constructor Create(const AListenHost: string; const AListenPort: Word;
      const AIsUdp: Boolean);
    destructor Destroy; override;
  end;

  TRomitterStreamServer = class
  private
    FConfig: TRomitterConfig;
    FLogger: TRomitterLogger;
    FListeners: TObjectList<TRomitterStreamListener>;
    FClientsLock: TObject;
    FClientSockets: TList<TSocket>;
    FConfigUsageLock: TObject;
    FConfigUsage: TDictionary<TRomitterConfig, Integer>;
    FConnectionSemaphore: THandle;
    FClientsDoneEvent: THandle;
    FActiveClients: Integer;
    FWorkerConnections: Integer;
    FStopping: Boolean;
    FWsaStarted: Boolean;
    function ActiveConfig: TRomitterConfig;
    function AcquireConfigSnapshot: TRomitterConfig;
    procedure LeaveConfigUsage(const Config: TRomitterConfig);
    function FindServerForListener(const Config: TRomitterConfig;
      const Listener: TRomitterStreamListener): TRomitterStreamServerConfig;
    class function NormalizeListenHost(const Host: string): string; static;
    procedure AcceptLoop(const Listener: TRomitterStreamListener);
    function TryAcquireClientSlot(const ClientSocket: TSocket): Boolean;
    procedure ClientConnected(const ClientSocket: TSocket);
    procedure ClientDisconnected(const ClientSocket: TSocket);
    procedure ForceCloseClients;
    procedure HandleClient(const Listener: TRomitterStreamListener;
      const ClientSocket: TSocket);
    function ParseProxyPassTarget(const ProxyPass: string; const IsUdp: Boolean;
      out Upstream: TRomitterUpstreamConfig; out Host: string;
      out Port: Word): Boolean;
    function RelayTraffic(const ClientSocket, UpstreamSocket: TSocket;
      const ReadTimeoutMs: Integer; out TimedOut: Boolean): Boolean;
    function ProxySessionSingle(const ClientSocket: TSocket; const Host: string;
      const Port: Word; const Server: TRomitterStreamServerConfig;
      out AttemptKind: TRomitterStreamAttemptKind): Boolean;
    function ProxySession(const ClientSocket: TSocket;
      const Server: TRomitterStreamServerConfig): Boolean;
    function ProxyDatagramSingle(const RequestData: TBytes; const Host: string;
      const Port: Word; const Server: TRomitterStreamServerConfig;
      out ResponsePackets: TArray<TBytes>;
      out AttemptKind: TRomitterStreamAttemptKind): Boolean;
    function ProxyDatagram(const RequestData: TBytes;
      const ClientAddr: TSockAddrIn; const Server: TRomitterStreamServerConfig;
      out ResponsePackets: TArray<TBytes>): Boolean;
    class function IsSocketTimeoutError(const ErrorCode: Integer): Boolean; static;
    class function IsRetriableAttempt(const AttemptKind: TRomitterStreamAttemptKind;
      const Conditions: TRomitterProxyNextUpstreamConditions): Boolean; static;
    class function GetClientIpHash(const ClientSocket: TSocket): Cardinal; static;
    class function GetClientIpHashFromAddr(const ClientAddr: TSockAddrIn): Cardinal; static;
  public
    constructor Create(const Config: TRomitterConfig; const Logger: TRomitterLogger);
    destructor Destroy; override;
    procedure Start;
    procedure Stop(const Force: Boolean = False);
    procedure ReloadConfig(const Config: TRomitterConfig);
    function IsConfigInUse(const Config: TRomitterConfig): Boolean;
  end;

implementation

uses
  System.StrUtils,
  Romitter.Utils;

const
  STREAM_DEFAULT_TIMEOUT_MS = 600000;
  // Windows kernel-level listener port sharing (SO_REUSEPORT analogue).
  SO_REUSE_UNICASTPORT = $3007;

threadvar
  GStreamRequestConfig: TRomitterConfig;

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

type
  TRomitterStreamAcceptThread = class(TThread)
  private
    FOwner: TRomitterStreamServer;
    FListener: TRomitterStreamListener;
  protected
    procedure Execute; override;
  public
    constructor Create(const Owner: TRomitterStreamServer;
      const Listener: TRomitterStreamListener);
  end;

  TRomitterStreamClientThread = class(TThread)
  private
    FOwner: TRomitterStreamServer;
    FListener: TRomitterStreamListener;
    FClientSocket: TSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(const Owner: TRomitterStreamServer;
      const Listener: TRomitterStreamListener; const ClientSocket: TSocket);
  end;

function SendBuffer(const SocketHandle: TSocket; const Data: Pointer;
  const DataLen: Integer): Boolean;
var
  Sent: Integer;
  Offset: Integer;
begin
  Offset := 0;
  while Offset < DataLen do
  begin
    Sent := send(SocketHandle, PByte(Data)[Offset], DataLen - Offset, 0);
    if Sent = SOCKET_ERROR then
      Exit(False);
    Inc(Offset, Sent);
  end;
  Result := True;
end;

function ResolveIpv4Address(const Host: string; out Address: u_long): Boolean;
var
  HostEnt: PHostEnt;
begin
  Address := inet_addr(PAnsiChar(AnsiString(Host)));
  if Address <> INADDR_NONE then
    Exit(True);

  HostEnt := gethostbyname(PAnsiChar(AnsiString(Host)));
  if HostEnt = nil then
    Exit(False);

  Address := PInAddr(HostEnt^.h_addr_list^)^.S_addr;
  Result := True;
end;

function ConnectWithTimeout(const SocketHandle: TSocket; const Addr: TSockAddrIn;
  const TimeoutMs: Integer; out TimedOut: Boolean): Boolean;
var
  Mode: u_long;
  IoCtlCmd: Integer;
  SelectResult: Integer;
  WriteSet: TFDSet;
  TimeValue: timeval;
  OptError: Integer;
  OptLen: Integer;
  ConnectResult: Integer;
  WaitMs: Integer;
  LastErr: Integer;
  AddrCopy: TSockAddrIn;
  AddrSock: TSockAddr absolute AddrCopy;
begin
  TimedOut := False;
  WaitMs := TimeoutMs;
  if WaitMs <= 0 then
    WaitMs := 5000;

  IoCtlCmd := -2147195266; // FIONBIO as signed 32-bit integer
  Mode := 1;
  if ioctlsocket(SocketHandle, IoCtlCmd, Mode) <> 0 then
    Exit(False);

  try
    AddrCopy := Addr;
    ConnectResult := connect(SocketHandle, AddrSock, SizeOf(AddrCopy));
    if ConnectResult = 0 then
      Exit(True);

    LastErr := WSAGetLastError;
    if (LastErr <> WSAEWOULDBLOCK) and
       (LastErr <> WSAEINPROGRESS) and
       (LastErr <> WSAEINVAL) then
      Exit(False);

    WriteSet.fd_count := 1;
    WriteSet.fd_array[0] := SocketHandle;
    TimeValue.tv_sec := WaitMs div 1000;
    TimeValue.tv_usec := (WaitMs mod 1000) * 1000;

    SelectResult := select(0, nil, @WriteSet, nil, @TimeValue);
    if SelectResult <= 0 then
    begin
      TimedOut := SelectResult = 0;
      Exit(False);
    end;

    OptError := 0;
    OptLen := SizeOf(OptError);
    if getsockopt(SocketHandle, SOL_SOCKET, SO_ERROR, PAnsiChar(@OptError), OptLen) <> 0 then
      Exit(False);
    TimedOut := OptError = WSAETIMEDOUT;
    Result := OptError = 0;
  finally
    Mode := 0;
    ioctlsocket(SocketHandle, IoCtlCmd, Mode);
  end;
end;

procedure ApplySocketTimeouts(const SocketHandle: TSocket;
  const SendTimeoutMs, ReadTimeoutMs: Integer);
var
  SendMs: Integer;
  ReadMs: Integer;
begin
  SendMs := SendTimeoutMs;
  if SendMs <= 0 then
    SendMs := STREAM_DEFAULT_TIMEOUT_MS;
  ReadMs := ReadTimeoutMs;
  if ReadMs <= 0 then
    ReadMs := STREAM_DEFAULT_TIMEOUT_MS;

  setsockopt(SocketHandle, SOL_SOCKET, SO_SNDTIMEO, PAnsiChar(@SendMs), SizeOf(SendMs));
  setsockopt(SocketHandle, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@ReadMs), SizeOf(ReadMs));
end;

constructor TRomitterStreamAcceptThread.Create(const Owner: TRomitterStreamServer;
  const Listener: TRomitterStreamListener);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
  FListener := Listener;
  StartThreadCompat(Self);
end;

procedure TRomitterStreamAcceptThread.Execute;
begin
  FOwner.AcceptLoop(FListener);
end;

constructor TRomitterStreamClientThread.Create(const Owner: TRomitterStreamServer;
  const Listener: TRomitterStreamListener; const ClientSocket: TSocket);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := Owner;
  FListener := Listener;
  FClientSocket := ClientSocket;
  StartThreadCompat(Self);
end;

procedure TRomitterStreamClientThread.Execute;
begin
  try
    FOwner.HandleClient(FListener, FClientSocket);
  finally
    shutdown(FClientSocket, SD_BOTH);
    closesocket(FClientSocket);
    FOwner.ClientDisconnected(FClientSocket);
  end;
end;

constructor TRomitterStreamListener.Create(const AListenHost: string;
  const AListenPort: Word; const AIsUdp: Boolean);
begin
  inherited Create;
  ListenHost := AListenHost;
  ListenPort := AListenPort;
  IsUdp := AIsUdp;
  ListenSocket := INVALID_SOCKET;
  AcceptThread := nil;
end;

destructor TRomitterStreamListener.Destroy;
begin
  AcceptThread.Free;
  if ListenSocket <> INVALID_SOCKET then
    closesocket(ListenSocket);
  inherited;
end;

constructor TRomitterStreamServer.Create(const Config: TRomitterConfig;
  const Logger: TRomitterLogger);
begin
  inherited Create;
  FConfig := Config;
  FLogger := Logger;
  FListeners := TObjectList<TRomitterStreamListener>.Create(True);
  FClientsLock := TObject.Create;
  FClientSockets := TList<TSocket>.Create;
  FConfigUsageLock := TObject.Create;
  FConfigUsage := TDictionary<TRomitterConfig, Integer>.Create;
  FConnectionSemaphore := 0;
  FClientsDoneEvent := 0;
  FActiveClients := 0;
  FWorkerConnections := 1;
  FStopping := False;
  FWsaStarted := False;
end;

function TRomitterStreamServer.ActiveConfig: TRomitterConfig;
begin
  if GStreamRequestConfig <> nil then
    Result := GStreamRequestConfig
  else
  begin
    TMonitor.Enter(FConfigUsageLock);
    try
      Result := FConfig;
    finally
      TMonitor.Exit(FConfigUsageLock);
    end;
  end;
end;

function TRomitterStreamServer.AcquireConfigSnapshot: TRomitterConfig;
var
  RefCount: Integer;
begin
  Result := nil;
  TMonitor.Enter(FConfigUsageLock);
  try
    Result := FConfig;
    if Result = nil then
      Exit;
    if FConfigUsage.TryGetValue(Result, RefCount) then
      FConfigUsage.AddOrSetValue(Result, RefCount + 1)
    else
      FConfigUsage.Add(Result, 1);
  finally
    TMonitor.Exit(FConfigUsageLock);
  end;
end;

procedure TRomitterStreamServer.LeaveConfigUsage(const Config: TRomitterConfig);
var
  RefCount: Integer;
begin
  if Config = nil then
    Exit;
  TMonitor.Enter(FConfigUsageLock);
  try
    if not FConfigUsage.TryGetValue(Config, RefCount) then
      Exit;
    Dec(RefCount);
    if RefCount <= 0 then
      FConfigUsage.Remove(Config)
    else
      FConfigUsage.AddOrSetValue(Config, RefCount);
  finally
    TMonitor.Exit(FConfigUsageLock);
  end;
end;

class function TRomitterStreamServer.NormalizeListenHost(
  const Host: string): string;
begin
  if SameText(Trim(Host), '*') or SameText(Trim(Host), '0.0.0.0') then
    Result := '0.0.0.0'
  else
    Result := LowerCase(Trim(Host));
end;

function TRomitterStreamServer.FindServerForListener(const Config: TRomitterConfig;
  const Listener: TRomitterStreamListener): TRomitterStreamServerConfig;
var
  Server: TRomitterStreamServerConfig;
  ListenerHost: string;
begin
  Result := nil;
  if (Config = nil) or (not Config.Stream.Enabled) or (Listener = nil) then
    Exit;

  ListenerHost := NormalizeListenHost(Listener.ListenHost);
  for Server in Config.Stream.Servers do
  begin
    if Server.IsUdp <> Listener.IsUdp then
      Continue;
    if Server.ListenPort <> Listener.ListenPort then
      Continue;
    if SameText(NormalizeListenHost(Server.ListenHost), ListenerHost) then
      Exit(Server);
  end;
end;

destructor TRomitterStreamServer.Destroy;
begin
  Stop;
  FConfigUsage.Free;
  FConfigUsageLock.Free;
  FClientSockets.Free;
  FClientsLock.Free;
  FListeners.Free;
  inherited;
end;

procedure TRomitterStreamServer.ClientConnected(const ClientSocket: TSocket);
begin
  TMonitor.Enter(FClientsLock);
  try
    FClientSockets.Add(ClientSocket);
  finally
    TMonitor.Exit(FClientsLock);
  end;

  if InterlockedIncrement(FActiveClients) = 1 then
    if FClientsDoneEvent <> 0 then
      ResetEvent(FClientsDoneEvent);
end;

procedure TRomitterStreamServer.ClientDisconnected(const ClientSocket: TSocket);
begin
  TMonitor.Enter(FClientsLock);
  try
    FClientSockets.Remove(ClientSocket);
  finally
    TMonitor.Exit(FClientsLock);
  end;

  if FConnectionSemaphore <> 0 then
    ReleaseSemaphore(FConnectionSemaphore, 1, nil);

  if InterlockedDecrement(FActiveClients) = 0 then
    if FClientsDoneEvent <> 0 then
      SetEvent(FClientsDoneEvent);
end;

function TRomitterStreamServer.TryAcquireClientSlot(
  const ClientSocket: TSocket): Boolean;
begin
  if FConnectionSemaphore = 0 then
  begin
    ClientConnected(ClientSocket);
    Exit(True);
  end;

  Result := WaitForSingleObject(FConnectionSemaphore, 0) = WAIT_OBJECT_0;
  if Result then
    ClientConnected(ClientSocket);
end;

procedure TRomitterStreamServer.Start;
var
  WsaData: TWSAData;
  Listener: TRomitterStreamListener;
  Server: TRomitterStreamServerConfig;
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  ReuseValue: Integer;
  ListenHost: string;
begin
  if FConfig.Stream.Servers.Count = 0 then
  begin
    if Assigned(FLogger) then
      FLogger.Log(rlInfo,
        'No stream server blocks configured; stream listener startup skipped');
    Exit;
  end;

  FWorkerConnections := FConfig.Events.WorkerConnections;
  if FWorkerConnections < 1 then
    FWorkerConnections := 1;

  FActiveClients := 0;
  if FClientsDoneEvent = 0 then
  begin
    FClientsDoneEvent := CreateEvent(nil, True, True, nil);
    if FClientsDoneEvent = 0 then
      raise Exception.CreateFmt('CreateEvent failed: %d', [GetLastError]);
  end;

  if FConnectionSemaphore = 0 then
  begin
    FConnectionSemaphore := CreateSemaphore(nil, FWorkerConnections, FWorkerConnections, nil);
    if FConnectionSemaphore = 0 then
      raise Exception.CreateFmt('CreateSemaphore failed: %d', [GetLastError]);
  end;

  if WSAStartup($202, WsaData) <> 0 then
    raise Exception.CreateFmt('WSAStartup failed: %d', [WSAGetLastError]);
  FWsaStarted := True;

  FStopping := False;
  FListeners.Clear;

  try
    for Server in FConfig.Stream.Servers do
    begin
      ListenHost := NormalizeListenHost(Server.ListenHost);
      Listener := TRomitterStreamListener.Create(
        ListenHost,
        Server.ListenPort,
        Server.IsUdp);
      try
        if Listener.IsUdp then
          Listener.ListenSocket := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        else
          Listener.ListenSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if Listener.ListenSocket = INVALID_SOCKET then
          raise Exception.CreateFmt('socket() failed: %d', [WSAGetLastError]);

        ReuseValue := 1;
        setsockopt(Listener.ListenSocket, SOL_SOCKET, SO_REUSEADDR, PAnsiChar(@ReuseValue), SizeOf(ReuseValue));
        // Best-effort: enable multi-process listener sharing on Windows 10+.
        setsockopt(Listener.ListenSocket, SOL_SOCKET, SO_REUSE_UNICASTPORT, PAnsiChar(@ReuseValue), SizeOf(ReuseValue));

        ZeroMemory(@Addr, SizeOf(Addr));
        Addr.sin_family := AF_INET;
        Addr.sin_port := htons(Listener.ListenPort);

        if SameText(Listener.ListenHost, '0.0.0.0') then
          Addr.sin_addr.S_addr := htonl(INADDR_ANY)
        else if not ResolveIpv4Address(Listener.ListenHost, Addr.sin_addr.S_addr) then
          raise Exception.CreateFmt('Unable to resolve stream listen host: %s', [Listener.ListenHost]);

        if bind(Listener.ListenSocket, AddrSock, SizeOf(Addr)) = SOCKET_ERROR then
          raise Exception.CreateFmt('stream bind() failed: %d', [WSAGetLastError]);

        if (not Listener.IsUdp) and
           (listen(Listener.ListenSocket, SOMAXCONN) = SOCKET_ERROR) then
          raise Exception.CreateFmt('stream listen() failed: %d', [WSAGetLastError]);

        Listener.AcceptThread := TRomitterStreamAcceptThread.Create(Self, Listener);
        FListeners.Add(Listener);
        if Listener.IsUdp then
          FLogger.Log(rlInfo, Format('Stream listening (udp) on %s:%d',
            [Listener.ListenHost, Listener.ListenPort]))
        else
          FLogger.Log(rlInfo, Format('Stream listening (tcp) on %s:%d',
            [Listener.ListenHost, Listener.ListenPort]));
        Listener := nil;
      finally
        Listener.Free;
      end;
    end;
  except
    Stop;
    raise;
  end;
end;

procedure TRomitterStreamServer.ForceCloseClients;
var
  Snapshot: TArray<TSocket>;
  ClientSocket: TSocket;
begin
  TMonitor.Enter(FClientsLock);
  try
    Snapshot := FClientSockets.ToArray;
  finally
    TMonitor.Exit(FClientsLock);
  end;

  for ClientSocket in Snapshot do
  begin
    shutdown(ClientSocket, SD_BOTH);
    closesocket(ClientSocket);
  end;
end;

procedure TRomitterStreamServer.Stop(const Force: Boolean);
var
  Listener: TRomitterStreamListener;
  WaitResult: DWORD;
  WaitCycles: Integer;
begin
  FStopping := True;

  for Listener in FListeners do
  begin
    if Listener.ListenSocket <> INVALID_SOCKET then
    begin
      if not Listener.IsUdp then
        shutdown(Listener.ListenSocket, SD_BOTH);
      closesocket(Listener.ListenSocket);
      Listener.ListenSocket := INVALID_SOCKET;
    end;
  end;

  for Listener in FListeners do
  begin
    if Assigned(Listener.AcceptThread) then
    begin
      Listener.AcceptThread.WaitFor;
      FreeAndNil(Listener.AcceptThread);
    end;
  end;

  if Force then
    ForceCloseClients;

  if FClientsDoneEvent <> 0 then
  begin
    if Force then
      WaitForSingleObject(FClientsDoneEvent, 30000)
    else
    begin
      WaitCycles := 0;
      repeat
        WaitResult := WaitForSingleObject(FClientsDoneEvent, 1000);
        if WaitResult <> WAIT_TIMEOUT then
          Break;
        Inc(WaitCycles);
        if Assigned(FLogger) and ((WaitCycles mod 30) = 0) then
          FLogger.Log(rlInfo, 'waiting for stream clients to drain');
      until False;
    end;
  end;

  FListeners.Clear;

  if FWsaStarted then
  begin
    WSACleanup;
    FWsaStarted := False;
  end;

  if FConnectionSemaphore <> 0 then
  begin
    CloseHandle(FConnectionSemaphore);
    FConnectionSemaphore := 0;
  end;

  if FClientsDoneEvent <> 0 then
  begin
    CloseHandle(FClientsDoneEvent);
    FClientsDoneEvent := 0;
  end;
end;

procedure TRomitterStreamServer.ReloadConfig(const Config: TRomitterConfig);
begin
  if Config = nil then
    Exit;
  TMonitor.Enter(FConfigUsageLock);
  try
    FConfig := Config;
  finally
    TMonitor.Exit(FConfigUsageLock);
  end;
end;

function TRomitterStreamServer.IsConfigInUse(
  const Config: TRomitterConfig): Boolean;
var
  RefCount: Integer;
begin
  if Config = nil then
    Exit(False);
  TMonitor.Enter(FConfigUsageLock);
  try
    Result := FConfigUsage.TryGetValue(Config, RefCount) and (RefCount > 0);
  finally
    TMonitor.Exit(FConfigUsageLock);
  end;
end;

procedure TRomitterStreamServer.AcceptLoop(const Listener: TRomitterStreamListener);
var
  ClientSocket: TSocket;
  ClientAddr: TSockAddrIn;
  ClientAddrSock: TSockAddr absolute ClientAddr;
  ClientAddrLen: Integer;
  ReadLen: Integer;
  SentLen: Integer;
  Buffer: array[0..65535] of Byte;
  RequestData: TBytes;
  ResponsePackets: TArray<TBytes>;
  ResponsePacket: TBytes;
  ConfigSnapshot: TRomitterConfig;
  ServerSnapshot: TRomitterStreamServerConfig;
begin
  if Listener.IsUdp then
  begin
    while not FStopping do
    begin
      ZeroMemory(@ClientAddr, SizeOf(ClientAddr));
      ClientAddrLen := SizeOf(ClientAddr);
      ReadLen := recvfrom(
        Listener.ListenSocket,
        Buffer[0],
        SizeOf(Buffer),
        0,
        ClientAddrSock,
        ClientAddrLen);
      if ReadLen = SOCKET_ERROR then
      begin
        if FStopping then
          Break;
        Sleep(1);
        Continue;
      end;
      if ReadLen <= 0 then
        Continue;

      SetLength(RequestData, ReadLen);
      Move(Buffer[0], RequestData[0], ReadLen);

      ConfigSnapshot := AcquireConfigSnapshot;
      if ConfigSnapshot = nil then
        Continue;
      GStreamRequestConfig := ConfigSnapshot;
      try
        ServerSnapshot := FindServerForListener(ConfigSnapshot, Listener);
        if ServerSnapshot = nil then
          Continue;
        if not ProxyDatagram(RequestData, ClientAddr, ServerSnapshot, ResponsePackets) then
          Continue;
      finally
        GStreamRequestConfig := nil;
        LeaveConfigUsage(ConfigSnapshot);
      end;

      for ResponsePacket in ResponsePackets do
      begin
        if Length(ResponsePacket) = 0 then
          Continue;
        SentLen := sendto(
          Listener.ListenSocket,
          ResponsePacket[0],
          Length(ResponsePacket),
          0,
          PSockAddr(@ClientAddr),
          ClientAddrLen);
        if (SentLen = SOCKET_ERROR) and FStopping then
          Break;
      end;
    end;
    Exit;
  end;

  while not FStopping do
  begin
    ClientSocket := accept(Listener.ListenSocket, nil, nil);
    if ClientSocket = INVALID_SOCKET then
    begin
      if FStopping then
        Break;
      Sleep(5);
      Continue;
    end;

    if not TryAcquireClientSlot(ClientSocket) then
    begin
      shutdown(ClientSocket, SD_BOTH);
      closesocket(ClientSocket);
      Continue;
    end;

    try
      TRomitterStreamClientThread.Create(Self, Listener, ClientSocket);
    except
      on E: Exception do
      begin
        FLogger.Log(rlError, 'Unable to spawn stream client thread: ' + E.Message);
        ClientDisconnected(ClientSocket);
        shutdown(ClientSocket, SD_BOTH);
        closesocket(ClientSocket);
      end;
    end;
  end;
end;

class function TRomitterStreamServer.IsSocketTimeoutError(
  const ErrorCode: Integer): Boolean;
begin
  Result := (ErrorCode = WSAETIMEDOUT) or
            (ErrorCode = WSAEWOULDBLOCK) or
            (ErrorCode = WSAEINPROGRESS);
end;

class function TRomitterStreamServer.IsRetriableAttempt(
  const AttemptKind: TRomitterStreamAttemptKind;
  const Conditions: TRomitterProxyNextUpstreamConditions): Boolean;
begin
  case AttemptKind of
    sakTimeout:
      Result := pnucTimeout in Conditions;
    sakError:
      Result := pnucError in Conditions;
  else
    Result := False;
  end;
end;

class function TRomitterStreamServer.GetClientIpHash(
  const ClientSocket: TSocket): Cardinal;
var
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  AddrLen: Integer;
begin
  Result := 0;
  ZeroMemory(@Addr, SizeOf(Addr));
  AddrLen := SizeOf(Addr);
  if getpeername(ClientSocket, AddrSock, AddrLen) = 0 then
    Result := ntohl(Addr.sin_addr.S_addr);
end;

class function TRomitterStreamServer.GetClientIpHashFromAddr(
  const ClientAddr: TSockAddrIn): Cardinal;
begin
  Result := ntohl(ClientAddr.sin_addr.S_addr);
end;

function TRomitterStreamServer.ParseProxyPassTarget(const ProxyPass: string;
  const IsUdp: Boolean; out Upstream: TRomitterUpstreamConfig;
  out Host: string; out Port: Word): Boolean;
var
  Target: string;
  HasScheme: Boolean;
  SchemeIsUdp: Boolean;
  Config: TRomitterConfig;
begin
  Result := False;
  Upstream := nil;
  Host := '';
  Port := 0;
  Target := Trim(ProxyPass);
  HasScheme := False;
  SchemeIsUdp := False;

  if StartsText('tcp://', Target) then
  begin
    HasScheme := True;
    SchemeIsUdp := False;
    Target := Copy(Target, Length('tcp://') + 1, MaxInt);
  end
  else if StartsText('udp://', Target) then
  begin
    HasScheme := True;
    SchemeIsUdp := True;
    Target := Copy(Target, Length('udp://') + 1, MaxInt);
  end;

  if HasScheme and (SchemeIsUdp <> IsUdp) then
    Exit(False);

  if ParseHostPort(Target, Host, Port, 0) and (Port <> 0) then
    Exit(True);

  Config := ActiveConfig;
  if Config <> nil then
    Upstream := Config.FindStreamUpstream(Target)
  else
    Upstream := nil;
  Result := Upstream <> nil;
end;

function TRomitterStreamServer.RelayTraffic(const ClientSocket,
  UpstreamSocket: TSocket; const ReadTimeoutMs: Integer;
  out TimedOut: Boolean): Boolean;
var
  ReadSet: TFDSet;
  TimeValue: timeval;
  SelectResult: Integer;
  ReadLen: Integer;
  LastErr: Integer;
  Buffer: array[0..16383] of Byte;
  ClientOpen: Boolean;
  UpstreamOpen: Boolean;
  WaitMs: Integer;

  function SocketReady(const SocketHandle: TSocket): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := 0 to ReadSet.fd_count - 1 do
      if ReadSet.fd_array[I] = SocketHandle then
        Exit(True);
  end;
begin
  TimedOut := False;
  ClientOpen := True;
  UpstreamOpen := True;
  WaitMs := ReadTimeoutMs;
  if WaitMs <= 0 then
    WaitMs := STREAM_DEFAULT_TIMEOUT_MS;

  while ClientOpen or UpstreamOpen do
  begin
    ReadSet.fd_count := 0;
    if ClientOpen then
    begin
      ReadSet.fd_array[ReadSet.fd_count] := ClientSocket;
      Inc(ReadSet.fd_count);
    end;
    if UpstreamOpen then
    begin
      ReadSet.fd_array[ReadSet.fd_count] := UpstreamSocket;
      Inc(ReadSet.fd_count);
    end;

    TimeValue.tv_sec := WaitMs div 1000;
    TimeValue.tv_usec := (WaitMs mod 1000) * 1000;

    SelectResult := select(0, @ReadSet, nil, nil, @TimeValue);
    if SelectResult = 0 then
    begin
      TimedOut := True;
      Exit(False);
    end;
    if SelectResult = SOCKET_ERROR then
    begin
      LastErr := WSAGetLastError;
      TimedOut := IsSocketTimeoutError(LastErr);
      Exit(False);
    end;

    if ClientOpen and SocketReady(ClientSocket) then
    begin
      ReadLen := recv(ClientSocket, Buffer[0], SizeOf(Buffer), 0);
      if ReadLen = 0 then
      begin
        shutdown(UpstreamSocket, SD_SEND);
        ClientOpen := False;
      end
      else if ReadLen < 0 then
      begin
        LastErr := WSAGetLastError;
        TimedOut := IsSocketTimeoutError(LastErr);
        Exit(False);
      end
      else if not SendBuffer(UpstreamSocket, @Buffer[0], ReadLen) then
      begin
        LastErr := WSAGetLastError;
        TimedOut := IsSocketTimeoutError(LastErr);
        Exit(False);
      end;
    end;

    if UpstreamOpen and SocketReady(UpstreamSocket) then
    begin
      ReadLen := recv(UpstreamSocket, Buffer[0], SizeOf(Buffer), 0);
      if ReadLen = 0 then
      begin
        shutdown(ClientSocket, SD_SEND);
        UpstreamOpen := False;
      end
      else if ReadLen < 0 then
      begin
        LastErr := WSAGetLastError;
        TimedOut := IsSocketTimeoutError(LastErr);
        Exit(False);
      end
      else if not SendBuffer(ClientSocket, @Buffer[0], ReadLen) then
      begin
        LastErr := WSAGetLastError;
        TimedOut := IsSocketTimeoutError(LastErr);
        Exit(False);
      end;
    end;
  end;

  Result := True;
end;

function TRomitterStreamServer.ProxySessionSingle(const ClientSocket: TSocket;
  const Host: string; const Port: Word; const Server: TRomitterStreamServerConfig;
  out AttemptKind: TRomitterStreamAttemptKind): Boolean;
var
  UpstreamSocket: TSocket;
  Addr: TSockAddrIn;
  AddressValue: u_long;
  ConnectTimedOut: Boolean;
  RelayTimedOut: Boolean;
  TimeoutMs: Integer;
begin
  Result := False;
  AttemptKind := sakError;
  UpstreamSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if UpstreamSocket = INVALID_SOCKET then
    Exit(False);

  try
    ZeroMemory(@Addr, SizeOf(Addr));
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(Port);
    if not ResolveIpv4Address(Host, AddressValue) then
      Exit(False);
    Addr.sin_addr.S_addr := AddressValue;

    if not ConnectWithTimeout(UpstreamSocket, Addr, Server.ProxyConnectTimeoutMs, ConnectTimedOut) then
    begin
      if ConnectTimedOut then
        AttemptKind := sakTimeout
      else
        AttemptKind := sakError;
      Exit(False);
    end;

    ApplySocketTimeouts(ClientSocket, Server.ProxySendTimeoutMs, Server.ProxyReadTimeoutMs);
    ApplySocketTimeouts(UpstreamSocket, Server.ProxySendTimeoutMs, Server.ProxyReadTimeoutMs);

    TimeoutMs := Server.ProxyReadTimeoutMs;
    if TimeoutMs <= 0 then
      TimeoutMs := Server.ProxySendTimeoutMs;
    if not RelayTraffic(ClientSocket, UpstreamSocket, TimeoutMs, RelayTimedOut) then
    begin
      if RelayTimedOut then
        AttemptKind := sakTimeout
      else
        AttemptKind := sakError;
      Exit(False);
    end;

    AttemptKind := sakOk;
    Result := True;
  finally
    shutdown(UpstreamSocket, SD_BOTH);
    closesocket(UpstreamSocket);
  end;
end;

function TRomitterStreamServer.ProxySession(const ClientSocket: TSocket;
  const Server: TRomitterStreamServerConfig): Boolean;
var
  Upstream: TRomitterUpstreamConfig;
  Host: string;
  Port: Word;
  Peer: TRomitterUpstreamPeer;
  Attempts: Integer;
  MaxAttempts: Integer;
  AttemptKind: TRomitterStreamAttemptKind;
  ShouldRetry: Boolean;
  ClientHash: Cardinal;
  RetryDeadlineTick: UInt64;
  TriedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>;
begin
  Result := False;
  Upstream := nil;
  Host := '';
  Port := 0;
  TriedPeers := nil;

  if not ParseProxyPassTarget(Server.ProxyPass, False, Upstream, Host, Port) then
  begin
    FLogger.Log(rlError, 'invalid stream proxy_pass target: ' + Server.ProxyPass);
    Exit(False);
  end;

  if Upstream = nil then
    Exit(ProxySessionSingle(ClientSocket, Host, Port, Server, AttemptKind));

  if Upstream.Peers.Count = 0 then
    Exit(False);

  if Server.ProxyNextUpstreamTries > 0 then
    MaxAttempts := Server.ProxyNextUpstreamTries
  else if Server.ProxyNextUpstreamTimeoutMs > 0 then
    MaxAttempts := High(Integer)
  else
    MaxAttempts := Upstream.Peers.Count;
  if MaxAttempts < 1 then
    MaxAttempts := 1;
  if Server.ProxyNextUpstreamTimeoutMs > 0 then
    RetryDeadlineTick := GetTickCount64 + UInt64(Server.ProxyNextUpstreamTimeoutMs)
  else
    RetryDeadlineTick := 0;

  ClientHash := GetClientIpHash(ClientSocket);
  TriedPeers := TDictionary<TRomitterUpstreamPeer, Boolean>.Create;
  try
    Attempts := 0;
    while Attempts < MaxAttempts do
    begin
      if (Attempts > 0) and (RetryDeadlineTick <> 0) and
         (GetTickCount64 >= RetryDeadlineTick) then
        Break;

      Inc(Attempts);
      Peer := Upstream.AcquirePeer(ClientHash + Cardinal(Attempts - 1), TriedPeers);
      if Peer = nil then
        Exit(False);
      TriedPeers.AddOrSetValue(Peer, True);

      if ProxySessionSingle(ClientSocket, Peer.Host, Peer.Port, Server, AttemptKind) then
      begin
        Upstream.ReleasePeer(Peer, True);
        Exit(True);
      end;

      ShouldRetry :=
        (Attempts < MaxAttempts) and
        IsRetriableAttempt(AttemptKind, Server.ProxyNextUpstream);
      if ShouldRetry and (RetryDeadlineTick <> 0) and (GetTickCount64 >= RetryDeadlineTick) then
        ShouldRetry := False;
      Upstream.ReleasePeer(Peer, not ShouldRetry);
      if not ShouldRetry then
        Exit(False);

      FLogger.Log(rlWarn, Format(
        'stream upstream retry %d/%d for "%s" -> %s:%d kind=%d',
        [Attempts, MaxAttempts, Upstream.Name, Peer.Host, Peer.Port, Ord(AttemptKind)]));
    end;
  finally
    TriedPeers.Free;
  end;
end;

function TRomitterStreamServer.ProxyDatagramSingle(
  const RequestData: TBytes; const Host: string; const Port: Word;
  const Server: TRomitterStreamServerConfig; out ResponsePackets: TArray<TBytes>;
  out AttemptKind: TRomitterStreamAttemptKind): Boolean;
var
  UpstreamSocket: TSocket;
  UpstreamAddr: TSockAddrIn;
  UpstreamAddrSock: TSockAddr absolute UpstreamAddr;
  UpstreamAddrLen: Integer;
  AddressValue: u_long;
  SentLen: Integer;
  ReadLen: Integer;
  LastErr: Integer;
  Buffer: array[0..65535] of Byte;
  ExpectedResponses: Integer;
  ResponseIndex: Integer;
  Packet: TBytes;
begin
  Result := False;
  AttemptKind := sakError;
  ResponsePackets := nil;
  if Length(RequestData) = 0 then
    Exit(False);

  UpstreamSocket := socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if UpstreamSocket = INVALID_SOCKET then
    Exit(False);

  try
    ApplySocketTimeouts(UpstreamSocket, Server.ProxySendTimeoutMs, Server.ProxyReadTimeoutMs);

    ZeroMemory(@UpstreamAddr, SizeOf(UpstreamAddr));
    UpstreamAddr.sin_family := AF_INET;
    UpstreamAddr.sin_port := htons(Port);
    if not ResolveIpv4Address(Host, AddressValue) then
      Exit(False);
    UpstreamAddr.sin_addr.S_addr := AddressValue;

    SentLen := sendto(
      UpstreamSocket,
      RequestData[0],
      Length(RequestData),
      0,
      PSockAddr(@UpstreamAddr),
      SizeOf(UpstreamAddr));
    if SentLen = SOCKET_ERROR then
    begin
      LastErr := WSAGetLastError;
      if IsSocketTimeoutError(LastErr) then
        AttemptKind := sakTimeout
      else
        AttemptKind := sakError;
      Exit(False);
    end;
    if SentLen <> Length(RequestData) then
      Exit(False);

    ExpectedResponses := Server.ProxyResponses;
    if ExpectedResponses < 0 then
      ExpectedResponses := 0;
    if ExpectedResponses = 0 then
    begin
      AttemptKind := sakOk;
      Exit(True);
    end;

    SetLength(ResponsePackets, 0);
    for ResponseIndex := 1 to ExpectedResponses do
    begin
      UpstreamAddrLen := SizeOf(UpstreamAddr);
      ReadLen := recvfrom(
        UpstreamSocket,
        Buffer[0],
        SizeOf(Buffer),
        0,
        UpstreamAddrSock,
        UpstreamAddrLen);
      if ReadLen = SOCKET_ERROR then
      begin
        LastErr := WSAGetLastError;
        if IsSocketTimeoutError(LastErr) then
          AttemptKind := sakTimeout
        else
          AttemptKind := sakError;
        Exit(False);
      end;
      if ReadLen < 0 then
        Exit(False);

      SetLength(Packet, ReadLen);
      if ReadLen > 0 then
        Move(Buffer[0], Packet[0], ReadLen);
      SetLength(ResponsePackets, Length(ResponsePackets) + 1);
      ResponsePackets[High(ResponsePackets)] := Packet;
    end;

    AttemptKind := sakOk;
    Result := True;
  finally
    closesocket(UpstreamSocket);
  end;
end;

function TRomitterStreamServer.ProxyDatagram(const RequestData: TBytes;
  const ClientAddr: TSockAddrIn; const Server: TRomitterStreamServerConfig;
  out ResponsePackets: TArray<TBytes>): Boolean;
var
  Upstream: TRomitterUpstreamConfig;
  Host: string;
  Port: Word;
  Peer: TRomitterUpstreamPeer;
  Attempts: Integer;
  MaxAttempts: Integer;
  AttemptKind: TRomitterStreamAttemptKind;
  ShouldRetry: Boolean;
  ClientHash: Cardinal;
  RetryDeadlineTick: UInt64;
  TriedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>;
begin
  Result := False;
  ResponsePackets := nil;
  Upstream := nil;
  Host := '';
  Port := 0;
  TriedPeers := nil;

  if not ParseProxyPassTarget(Server.ProxyPass, True, Upstream, Host, Port) then
  begin
    FLogger.Log(rlError, 'invalid stream udp proxy_pass target: ' + Server.ProxyPass);
    Exit(False);
  end;

  if Upstream = nil then
    Exit(ProxyDatagramSingle(RequestData, Host, Port, Server, ResponsePackets, AttemptKind));

  if Upstream.Peers.Count = 0 then
    Exit(False);

  if Server.ProxyNextUpstreamTries > 0 then
    MaxAttempts := Server.ProxyNextUpstreamTries
  else if Server.ProxyNextUpstreamTimeoutMs > 0 then
    MaxAttempts := High(Integer)
  else
    MaxAttempts := Upstream.Peers.Count;
  if MaxAttempts < 1 then
    MaxAttempts := 1;
  if Server.ProxyNextUpstreamTimeoutMs > 0 then
    RetryDeadlineTick := GetTickCount64 + UInt64(Server.ProxyNextUpstreamTimeoutMs)
  else
    RetryDeadlineTick := 0;

  ClientHash := GetClientIpHashFromAddr(ClientAddr);
  TriedPeers := TDictionary<TRomitterUpstreamPeer, Boolean>.Create;
  try
    Attempts := 0;
    while Attempts < MaxAttempts do
    begin
      if (Attempts > 0) and (RetryDeadlineTick <> 0) and
         (GetTickCount64 >= RetryDeadlineTick) then
        Break;

      Inc(Attempts);
      Peer := Upstream.AcquirePeer(ClientHash + Cardinal(Attempts - 1), TriedPeers);
      if Peer = nil then
        Exit(False);
      TriedPeers.AddOrSetValue(Peer, True);

      if ProxyDatagramSingle(RequestData, Peer.Host, Peer.Port, Server, ResponsePackets, AttemptKind) then
      begin
        Upstream.ReleasePeer(Peer, True);
        Exit(True);
      end;

      ShouldRetry :=
        (Attempts < MaxAttempts) and
        IsRetriableAttempt(AttemptKind, Server.ProxyNextUpstream);
      if ShouldRetry and (RetryDeadlineTick <> 0) and (GetTickCount64 >= RetryDeadlineTick) then
        ShouldRetry := False;
      Upstream.ReleasePeer(Peer, not ShouldRetry);
      if not ShouldRetry then
        Exit(False);

      FLogger.Log(rlWarn, Format(
        'stream udp upstream retry %d/%d for "%s" -> %s:%d kind=%d',
        [Attempts, MaxAttempts, Upstream.Name, Peer.Host, Peer.Port, Ord(AttemptKind)]));
    end;
  finally
    TriedPeers.Free;
  end;
end;

procedure TRomitterStreamServer.HandleClient(
  const Listener: TRomitterStreamListener; const ClientSocket: TSocket);
var
  ConfigSnapshot: TRomitterConfig;
  ServerSnapshot: TRomitterStreamServerConfig;
begin
  try
    ConfigSnapshot := AcquireConfigSnapshot;
    if ConfigSnapshot = nil then
      Exit;
    GStreamRequestConfig := ConfigSnapshot;
    try
      ServerSnapshot := FindServerForListener(ConfigSnapshot, Listener);
      if ServerSnapshot = nil then
      begin
        FLogger.Log(rlWarn, Format(
          'stream listener %s:%d is not present in active config',
          [Listener.ListenHost, Listener.ListenPort]));
        Exit;
      end;

      if not ProxySession(ClientSocket, ServerSnapshot) then
        FLogger.Log(rlWarn, Format('stream proxy session failed for listen %s:%d',
          [ServerSnapshot.ListenHost, ServerSnapshot.ListenPort]));
    finally
      GStreamRequestConfig := nil;
      LeaveConfigUsage(ConfigSnapshot);
    end;
  except
    on E: Exception do
      FLogger.Log(rlError, 'stream client handling error: ' + E.Message);
  end;
end;

end.
