unit Romitter.Config.Model;

interface

uses
  System.Generics.Collections;

type
  TRomitterLocationMatchKind = (
    lmkPrefix,
    lmkExact,
    lmkPrefixNoRegex,
    lmkRegexCaseSensitive,
    lmkRegexCaseInsensitive,
    lmkNamed
  );
  TRomitterUpstreamLbMethod = (ulbWeightedRoundRobin, ulbLeastConn, ulbIpHash);
  TRomitterProxyHttpVersion = (phv10, phv11);
  TRomitterProxyNextUpstreamCondition = (
    pnucError,
    pnucTimeout,
    pnucInvalidHeader,
    pnucHttp500,
    pnucHttp502,
    pnucHttp503,
    pnucHttp504
  );
  TRomitterProxyNextUpstreamConditions = set of TRomitterProxyNextUpstreamCondition;

  TRomitterAddHeaderConfig = class
  public
    Name: string;
    Value: string;
    Always: Boolean;
    constructor Create(const AName, AValue: string; const AAlways: Boolean);
  end;

  TRomitterErrorPageConfig = class
  public
    StatusCodes: TArray<Integer>;
    Uri: string;
    OverrideStatus: Integer;
    constructor Create(const AStatusCodes: TArray<Integer>; const AUri: string;
      const AOverrideStatus: Integer = 0);
  end;

  TRomitterAccessRuleConfig = class
  public
    IsAllow: Boolean;
    RuleText: string;
    constructor Create(const AIsAllow: Boolean; const ARuleText: string);
  end;

  TRomitterUpstreamPeer = class
  public
    Host: string;
    Port: Word;
    Weight: Integer;
    MaxFails: Integer;
    FailTimeoutMs: Integer;
    IsDown: Boolean;
    IsBackup: Boolean;
    ActiveConnections: Integer;
    FailureCount: Integer;
    DownUntilTick: UInt64;
    constructor Create(const AHost: string; const APort: Word; const AWeight: Integer = 1);
  end;

  TRomitterUpstreamConfig = class
  private
    FLock: TObject;
    FNextPeerIndex: Integer;
    FLbMethod: TRomitterUpstreamLbMethod;
    class function IsPeerExcluded(const Peer: TRomitterUpstreamPeer;
      const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): Boolean; static;
    function IsPeerAvailable(const Peer: TRomitterUpstreamPeer;
      const TickNow: UInt64): Boolean;
    function AcquirePeerRoundRobin(const IncludeBackup: Boolean;
      const TickNow: UInt64;
      const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
    function AcquirePeerLeastConn(const IncludeBackup: Boolean;
      const TickNow: UInt64;
      const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
    function AcquirePeerIpHash(const IncludeBackup: Boolean;
      const TickNow: UInt64; const HashKey: Cardinal;
      const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
  public
    Name: string;
    Peers: TObjectList<TRomitterUpstreamPeer>;
    constructor Create(const AName: string);
    destructor Destroy; override;
    function AcquirePeer(const HashKey: Cardinal = 0;
      const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean> = nil): TRomitterUpstreamPeer;
    procedure ReleasePeer(const Peer: TRomitterUpstreamPeer; const Succeeded: Boolean);
    property LbMethod: TRomitterUpstreamLbMethod read FLbMethod write FLbMethod;
  end;

  TRomitterLocationConfig = class
  public
    MatchKind: TRomitterLocationMatchKind;
    MatchPath: string;
    DefaultType: string;
    Root: string;
    AliasPath: string;
    IndexFiles: TArray<string>;
    TryFiles: TArray<string>;
    RewritePattern: string;
    RewriteReplacement: string;
    RewriteFlag: string;
    ProxyPass: string;
    FastCgiPass: string;
    FastCgiIndex: string;
    FastCgiSplitPathInfoPattern: string;
    FastCgiParams: TDictionary<string, string>;
    ProxySetHeaders: TDictionary<string, string>;
    ProxyRequestBuffering: Boolean;
    ProxyBuffering: Boolean;
    ProxyCacheValue: string;
    ProxyHttpVersion: TRomitterProxyHttpVersion;
    ProxySslServerName: Boolean;
    ProxySslName: string;
    ProxySslVerify: Boolean;
    ProxyConnectTimeoutMs: Integer;
    ProxyReadTimeoutMs: Integer;
    ProxySendTimeoutMs: Integer;
    ClientHeaderTimeoutMs: Integer;
    ClientBodyTimeoutMs: Integer;
    SendTimeoutMs: Integer;
    ProxyNextUpstream: TRomitterProxyNextUpstreamConditions;
    ProxyNextUpstreamTries: Integer;
    ProxyNextUpstreamTimeoutMs: Integer;
    ClientMaxBodySize: Int64;
    ReturnCode: Integer;
    ReturnBody: string;
    AddHeaders: TObjectList<TRomitterAddHeaderConfig>;
    ErrorPages: TObjectList<TRomitterErrorPageConfig>;
    ProxyRedirectOff: Boolean;
    ProxyRedirectDefault: Boolean;
    ProxyRedirectFrom: string;
    ProxyRedirectTo: string;
    SubFilterSearch: string;
    SubFilterReplacement: string;
    SubFilterTypes: TArray<string>;
    SubFilterOnce: Boolean;
    AccessRules: TObjectList<TRomitterAccessRuleConfig>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRomitterHttpListenConfig = class
  public
    Host: string;
    Port: Word;
    IsDefaultServer: Boolean;
    IsSsl: Boolean;
    IsHttp2: Boolean;
    UsesProxyProtocol: Boolean;
    constructor Create(const AHost: string; const APort: Word;
      const AIsDefaultServer: Boolean = False;
      const AIsSsl: Boolean = False;
      const AIsHttp2: Boolean = False;
      const AUsesProxyProtocol: Boolean = False);
  end;

  TRomitterServerConfig = class
  public
    ListenHost: string;
    ListenPort: Word;
    Listens: TObjectList<TRomitterHttpListenConfig>;
    DefaultType: string;
    ServerNames: TArray<string>;
    Root: string;
    IndexFiles: TArray<string>;
    Locations: TObjectList<TRomitterLocationConfig>;
    ClientHeaderTimeoutMs: Integer;
    ClientBodyTimeoutMs: Integer;
    SendTimeoutMs: Integer;
    KeepAliveTimeoutMs: Integer;
    ClientMaxBodySize: Int64;
    ProxySetHeaders: TDictionary<string, string>;
    ProxyRequestBuffering: Boolean;
    ProxyBuffering: Boolean;
    ProxyCacheValue: string;
    ProxyHttpVersion: TRomitterProxyHttpVersion;
    ProxySslServerName: Boolean;
    ProxySslName: string;
    ProxySslVerify: Boolean;
    ProxyConnectTimeoutMs: Integer;
    ProxyReadTimeoutMs: Integer;
    ProxySendTimeoutMs: Integer;
    ProxyNextUpstream: TRomitterProxyNextUpstreamConditions;
    ProxyNextUpstreamTries: Integer;
    ProxyNextUpstreamTimeoutMs: Integer;
    ReturnCode: Integer;
    ReturnBody: string;
    ServerTokens: Boolean;
    AddHeaders: TObjectList<TRomitterAddHeaderConfig>;
    ErrorPages: TObjectList<TRomitterErrorPageConfig>;
    AccessRules: TObjectList<TRomitterAccessRuleConfig>;
    ProxyRedirectOff: Boolean;
    ProxyRedirectDefault: Boolean;
    ProxyRedirectFrom: string;
    ProxyRedirectTo: string;
    SslCertificateFile: string;
    SslCertificateKeyFile: string;
    SslProtocols: TArray<string>;
    SslCiphers: string;
    SslPreferServerCiphers: Boolean;
    SslSessionCache: string;
    SslSessionTimeoutMs: Integer;
    SslSessionTickets: Boolean;
    constructor Create;
    destructor Destroy; override;
  end;

  TRomitterHttpConfig = class
  public
    Enabled: Boolean;
    Servers: TObjectList<TRomitterServerConfig>;
    Upstreams: TObjectList<TRomitterUpstreamConfig>;
    KeepAliveTimeoutMs: Integer;
    ClientHeaderTimeoutMs: Integer;
    ClientBodyTimeoutMs: Integer;
    SendTimeoutMs: Integer;
    ClientMaxBodySize: Int64;
    ProxySetHeaders: TDictionary<string, string>;
    ProxyRequestBuffering: Boolean;
    ProxyBuffering: Boolean;
    ProxyCacheValue: string;
    ProxyHttpVersion: TRomitterProxyHttpVersion;
    ProxySslServerName: Boolean;
    ProxySslName: string;
    ProxySslVerify: Boolean;
    ProxyConnectTimeoutMs: Integer;
    ProxyReadTimeoutMs: Integer;
    ProxySendTimeoutMs: Integer;
    ProxyNextUpstream: TRomitterProxyNextUpstreamConditions;
    ProxyNextUpstreamTries: Integer;
    ProxyNextUpstreamTimeoutMs: Integer;
    ServerNamesHashBucketSize: Integer;
    KeepAliveRequests: Integer;
    TcpNoDelay: Boolean;
    ResetTimedoutConnection: Boolean;
    IgnoreInvalidHeaders: Boolean;
    OpenFileCacheErrors: Boolean;
    ServerTokens: Boolean;
    SslCertificateFile: string;
    SslCertificateKeyFile: string;
    SslProtocols: TArray<string>;
    SslCiphers: string;
    SslPreferServerCiphers: Boolean;
    SslSessionCache: string;
    SslSessionTimeoutMs: Integer;
    SslSessionTickets: Boolean;
    DefaultType: string;
    SendFile: Boolean;
    TcpNoPush: Boolean;
    AddHeaders: TObjectList<TRomitterAddHeaderConfig>;
    constructor Create;
    destructor Destroy; override;
  end;

  TRomitterStreamServerConfig = class
  public
    ListenHost: string;
    ListenPort: Word;
    IsUdp: Boolean;
    UsesProxyProtocol: Boolean;
    ProxyPass: string;
    ProxyConnectTimeoutMs: Integer;
    ProxyReadTimeoutMs: Integer;
    ProxySendTimeoutMs: Integer;
    ProxyNextUpstream: TRomitterProxyNextUpstreamConditions;
    ProxyNextUpstreamTries: Integer;
    ProxyNextUpstreamTimeoutMs: Integer;
    ProxyResponses: Integer;
    constructor Create;
  end;

  TRomitterStreamConfig = class
  public
    Enabled: Boolean;
    Servers: TObjectList<TRomitterStreamServerConfig>;
    Upstreams: TObjectList<TRomitterUpstreamConfig>;
    ProxyConnectTimeoutMs: Integer;
    ProxyReadTimeoutMs: Integer;
    ProxySendTimeoutMs: Integer;
    ProxyNextUpstream: TRomitterProxyNextUpstreamConditions;
    ProxyNextUpstreamTries: Integer;
    ProxyNextUpstreamTimeoutMs: Integer;
    constructor Create;
    destructor Destroy; override;
  end;

  TRomitterEventsConfig = record
    WorkerConnections: Integer;
    MultiAccept: Boolean;
  end;

  TRomitterConfig = class
  public
    Prefix: string;
    User: string;
    Daemon: Boolean;
    MasterProcess: Boolean;
    WorkerProcesses: Integer;
    WorkerRlimitNofile: Integer;
    ErrorLogFile: string;
    ErrorLogLevel: string;
    PidFile: string;
    Events: TRomitterEventsConfig;
    Http: TRomitterHttpConfig;
    Stream: TRomitterStreamConfig;
    constructor Create;
    destructor Destroy; override;
    function EffectiveWorkerProcesses: Integer;
    function FindHttpUpstream(const Name: string): TRomitterUpstreamConfig;
    function FindStreamUpstream(const Name: string): TRomitterUpstreamConfig;
    function FindUpstream(const Name: string): TRomitterUpstreamConfig;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  Romitter.Constants;

constructor TRomitterAddHeaderConfig.Create(const AName, AValue: string;
  const AAlways: Boolean);
begin
  inherited Create;
  Name := AName;
  Value := AValue;
  Always := AAlways;
end;

constructor TRomitterErrorPageConfig.Create(const AStatusCodes: TArray<Integer>;
  const AUri: string; const AOverrideStatus: Integer);
begin
  inherited Create;
  StatusCodes := Copy(AStatusCodes);
  Uri := AUri;
  OverrideStatus := AOverrideStatus;
end;

constructor TRomitterAccessRuleConfig.Create(const AIsAllow: Boolean;
  const ARuleText: string);
begin
  inherited Create;
  IsAllow := AIsAllow;
  RuleText := ARuleText;
end;

constructor TRomitterUpstreamPeer.Create(const AHost: string; const APort: Word;
  const AWeight: Integer);
begin
  inherited Create;
  Host := AHost;
  Port := APort;
  if AWeight > 0 then
    Weight := AWeight
  else
    Weight := 1;
  MaxFails := 1;
  FailTimeoutMs := 10000;
  IsDown := False;
  IsBackup := False;
  ActiveConnections := 0;
  FailureCount := 0;
  DownUntilTick := 0;
end;

constructor TRomitterUpstreamConfig.Create(const AName: string);
begin
  inherited Create;
  Name := AName;
  Peers := TObjectList<TRomitterUpstreamPeer>.Create(True);
  FLock := TObject.Create;
  FNextPeerIndex := 0;
  FLbMethod := ulbWeightedRoundRobin;
end;

destructor TRomitterUpstreamConfig.Destroy;
begin
  FLock.Free;
  Peers.Free;
  inherited;
end;

class function TRomitterUpstreamConfig.IsPeerExcluded(
  const Peer: TRomitterUpstreamPeer;
  const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): Boolean;
begin
  Result := (ExcludedPeers <> nil) and ExcludedPeers.ContainsKey(Peer);
end;

function TRomitterUpstreamConfig.IsPeerAvailable(const Peer: TRomitterUpstreamPeer;
  const TickNow: UInt64): Boolean;
begin
  if Peer.IsDown then
    Exit(False);
  if (Peer.DownUntilTick <> 0) and (TickNow < Peer.DownUntilTick) then
    Exit(False);
  Result := True;
end;

function TRomitterUpstreamConfig.AcquirePeerRoundRobin(const IncludeBackup: Boolean;
  const TickNow: UInt64;
  const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
var
  I: Integer;
  Cursor: Integer;
  TotalWeight: Integer;
  Candidate: TRomitterUpstreamPeer;
begin
  Result := nil;
  TotalWeight := 0;
  for I := 0 to Peers.Count - 1 do
  begin
    Candidate := Peers[I];
    if Candidate.IsBackup <> IncludeBackup then
      Continue;
    if IsPeerExcluded(Candidate, ExcludedPeers) then
      Continue;
    if not IsPeerAvailable(Candidate, TickNow) then
      Continue;
    Inc(TotalWeight, Candidate.Weight);
  end;

  if TotalWeight < 1 then
    Exit(nil);

  if FNextPeerIndex < 0 then
    FNextPeerIndex := 0;
  if FNextPeerIndex >= TotalWeight then
    FNextPeerIndex := 0;
  Cursor := FNextPeerIndex;

  for I := 0 to Peers.Count - 1 do
  begin
    Candidate := Peers[I];
    if Candidate.IsBackup <> IncludeBackup then
      Continue;
    if IsPeerExcluded(Candidate, ExcludedPeers) then
      Continue;
    if not IsPeerAvailable(Candidate, TickNow) then
      Continue;
    if Cursor < Candidate.Weight then
    begin
      Result := Candidate;
      FNextPeerIndex := (FNextPeerIndex + 1) mod TotalWeight;
      Exit;
    end;
    Dec(Cursor, Candidate.Weight);
  end;
end;

function TRomitterUpstreamConfig.AcquirePeerLeastConn(const IncludeBackup: Boolean;
  const TickNow: UInt64;
  const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
var
  I: Integer;
  Candidate: TRomitterUpstreamPeer;
  BestScore: Double;
  Score: Double;
begin
  Result := nil;
  BestScore := 0.0;

  for I := 0 to Peers.Count - 1 do
  begin
    Candidate := Peers[I];
    if Candidate.IsBackup <> IncludeBackup then
      Continue;
    if IsPeerExcluded(Candidate, ExcludedPeers) then
      Continue;
    if not IsPeerAvailable(Candidate, TickNow) then
      Continue;

    Score := Candidate.ActiveConnections / Candidate.Weight;
    if (Result = nil) or (Score < BestScore) then
    begin
      Result := Candidate;
      BestScore := Score;
    end;
  end;
end;

function TRomitterUpstreamConfig.AcquirePeerIpHash(const IncludeBackup: Boolean;
  const TickNow: UInt64; const HashKey: Cardinal;
  const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
var
  I: Integer;
  CountAvailable: Integer;
  StartIndex: Integer;
  Candidate: TRomitterUpstreamPeer;
  Available: TArray<TRomitterUpstreamPeer>;
begin
  SetLength(Available, 0);
  CountAvailable := 0;

  for I := 0 to Peers.Count - 1 do
  begin
    Candidate := Peers[I];
    if Candidate.IsBackup <> IncludeBackup then
      Continue;
    if IsPeerExcluded(Candidate, ExcludedPeers) then
      Continue;
    if not IsPeerAvailable(Candidate, TickNow) then
      Continue;

    SetLength(Available, CountAvailable + 1);
    Available[CountAvailable] := Candidate;
    Inc(CountAvailable);
  end;

  if CountAvailable = 0 then
    Exit(nil);

  StartIndex := HashKey mod Cardinal(CountAvailable);
  Result := Available[StartIndex];
end;

function TRomitterUpstreamConfig.AcquirePeer(
  const HashKey: Cardinal;
  const ExcludedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>): TRomitterUpstreamPeer;
var
  TickNow: UInt64;
begin
  if Peers.Count = 0 then
    Exit(nil);

  TMonitor.Enter(FLock);
  try
    TickNow := GetTickCount64;
    case FLbMethod of
      ulbLeastConn:
        Result := AcquirePeerLeastConn(False, TickNow, ExcludedPeers);
      ulbIpHash:
        Result := AcquirePeerIpHash(False, TickNow, HashKey, ExcludedPeers);
    else
      Result := AcquirePeerRoundRobin(False, TickNow, ExcludedPeers);
    end;

    if Result = nil then
    begin
      case FLbMethod of
        ulbLeastConn:
          Result := AcquirePeerLeastConn(True, TickNow, ExcludedPeers);
        ulbIpHash:
          Result := AcquirePeerIpHash(True, TickNow, HashKey, ExcludedPeers);
      else
        Result := AcquirePeerRoundRobin(True, TickNow, ExcludedPeers);
      end;
    end;

    if Result <> nil then
      Inc(Result.ActiveConnections);
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TRomitterUpstreamConfig.ReleasePeer(const Peer: TRomitterUpstreamPeer;
  const Succeeded: Boolean);
var
  TickNow: UInt64;
begin
  if Peer = nil then
    Exit;

  TMonitor.Enter(FLock);
  try
    if Peer.ActiveConnections > 0 then
      Dec(Peer.ActiveConnections);

    if Succeeded then
    begin
      Peer.FailureCount := 0;
      Peer.DownUntilTick := 0;
      Exit;
    end;

    Inc(Peer.FailureCount);
    if (Peer.MaxFails > 0) and (Peer.FailureCount >= Peer.MaxFails) then
    begin
      TickNow := GetTickCount64;
      Peer.DownUntilTick := TickNow + UInt64(Peer.FailTimeoutMs);
      Peer.FailureCount := 0;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
end;

constructor TRomitterLocationConfig.Create;
begin
  inherited Create;
  MatchKind := lmkPrefix;
  MatchPath := '/';
  DefaultType := '';
  Root := '';
  AliasPath := '';
  IndexFiles := nil;
  TryFiles := nil;
  RewritePattern := '';
  RewriteReplacement := '';
  RewriteFlag := '';
  ProxyPass := '';
  FastCgiPass := '';
  FastCgiIndex := '';
  FastCgiSplitPathInfoPattern := '';
  FastCgiParams := TDictionary<string, string>.Create;
  ProxySetHeaders := TDictionary<string, string>.Create;
  ProxyRequestBuffering := True;
  ProxyBuffering := True;
  ProxyCacheValue := 'off';
  ProxyHttpVersion := phv10;
  ProxySslServerName := False;
  ProxySslName := '';
  ProxySslVerify := False;
  ProxyConnectTimeoutMs := 60000;
  ProxyReadTimeoutMs := 60000;
  ProxySendTimeoutMs := 60000;
  ClientHeaderTimeoutMs := -1;
  ClientBodyTimeoutMs := -1;
  SendTimeoutMs := -1;
  ProxyNextUpstream := [pnucError, pnucTimeout];
  ProxyNextUpstreamTries := 0;
  ProxyNextUpstreamTimeoutMs := 0;
  ClientMaxBodySize := -1;
  ReturnCode := 0;
  ReturnBody := '';
  AddHeaders := TObjectList<TRomitterAddHeaderConfig>.Create(True);
  ErrorPages := TObjectList<TRomitterErrorPageConfig>.Create(True);
  AccessRules := TObjectList<TRomitterAccessRuleConfig>.Create(True);
  ProxyRedirectOff := False;
  ProxyRedirectDefault := False;
  ProxyRedirectFrom := '';
  ProxyRedirectTo := '';
  SubFilterSearch := '';
  SubFilterReplacement := '';
  SubFilterTypes := nil;
  SubFilterOnce := True;
end;

destructor TRomitterLocationConfig.Destroy;
begin
  AccessRules.Free;
  ErrorPages.Free;
  AddHeaders.Free;
  FastCgiParams.Free;
  ProxySetHeaders.Free;
  inherited;
end;

constructor TRomitterHttpListenConfig.Create(const AHost: string;
  const APort: Word; const AIsDefaultServer, AIsSsl, AIsHttp2,
  AUsesProxyProtocol: Boolean);
begin
  inherited Create;
  Host := AHost;
  Port := APort;
  IsDefaultServer := AIsDefaultServer;
  IsSsl := AIsSsl;
  IsHttp2 := AIsHttp2;
  UsesProxyProtocol := AUsesProxyProtocol;
end;

constructor TRomitterServerConfig.Create;
begin
  inherited Create;
  ListenHost := '0.0.0.0';
  ListenPort := 80;
  Listens := TObjectList<TRomitterHttpListenConfig>.Create(True);
  DefaultType := '';
  Root := '';
  SetLength(IndexFiles, 1);
  IndexFiles[0] := 'index.html';
  Locations := TObjectList<TRomitterLocationConfig>.Create(True);
  ClientHeaderTimeoutMs := -1;
  ClientBodyTimeoutMs := -1;
  SendTimeoutMs := -1;
  KeepAliveTimeoutMs := -1;
  ClientMaxBodySize := -1;
  ProxySetHeaders := TDictionary<string, string>.Create;
  ProxyRequestBuffering := True;
  ProxyBuffering := True;
  ProxyCacheValue := 'off';
  ProxyHttpVersion := phv10;
  ProxySslServerName := False;
  ProxySslName := '';
  ProxySslVerify := False;
  ProxyConnectTimeoutMs := 60000;
  ProxyReadTimeoutMs := 60000;
  ProxySendTimeoutMs := 60000;
  ProxyNextUpstream := [pnucError, pnucTimeout];
  ProxyNextUpstreamTries := 0;
  ProxyNextUpstreamTimeoutMs := 0;
  ReturnCode := 0;
  ReturnBody := '';
  ServerTokens := True;
  AddHeaders := TObjectList<TRomitterAddHeaderConfig>.Create(True);
  ErrorPages := TObjectList<TRomitterErrorPageConfig>.Create(True);
  AccessRules := TObjectList<TRomitterAccessRuleConfig>.Create(True);
  ProxyRedirectOff := False;
  ProxyRedirectDefault := False;
  ProxyRedirectFrom := '';
  ProxyRedirectTo := '';
  SslCertificateFile := '';
  SslCertificateKeyFile := '';
  SslProtocols := nil;
  SslCiphers := '';
  SslPreferServerCiphers := False;
  SslSessionCache := '';
  SslSessionTimeoutMs := 0;
  SslSessionTickets := True;
end;

destructor TRomitterServerConfig.Destroy;
begin
  AccessRules.Free;
  ErrorPages.Free;
  AddHeaders.Free;
  ProxySetHeaders.Free;
  Listens.Free;
  Locations.Free;
  inherited;
end;

constructor TRomitterHttpConfig.Create;
begin
  inherited Create;
  Enabled := False;
  Servers := TObjectList<TRomitterServerConfig>.Create(True);
  Upstreams := TObjectList<TRomitterUpstreamConfig>.Create(True);
  KeepAliveTimeoutMs := 60000;
  ClientHeaderTimeoutMs := 60000;
  ClientBodyTimeoutMs := 60000;
  SendTimeoutMs := 60000;
  ClientMaxBodySize := 1024 * 1024;
  ProxySetHeaders := TDictionary<string, string>.Create;
  ProxyRequestBuffering := True;
  ProxyBuffering := True;
  ProxyCacheValue := 'off';
  ProxyHttpVersion := phv10;
  ProxySslServerName := False;
  ProxySslName := '';
  ProxySslVerify := False;
  ProxyConnectTimeoutMs := 60000;
  ProxyReadTimeoutMs := 60000;
  ProxySendTimeoutMs := 60000;
  ProxyNextUpstream := [pnucError, pnucTimeout];
  ProxyNextUpstreamTries := 0;
  ProxyNextUpstreamTimeoutMs := 0;
  ServerNamesHashBucketSize := 64;
  KeepAliveRequests := 1000;
  TcpNoDelay := False;
  ResetTimedoutConnection := False;
  IgnoreInvalidHeaders := True;
  OpenFileCacheErrors := False;
  ServerTokens := True;
  SslCertificateFile := '';
  SslCertificateKeyFile := '';
  SslProtocols := nil;
  SslCiphers := '';
  SslPreferServerCiphers := False;
  SslSessionCache := '';
  SslSessionTimeoutMs := 0;
  SslSessionTickets := True;
  DefaultType := 'application/octet-stream';
  SendFile := True;
  TcpNoPush := False;
  AddHeaders := TObjectList<TRomitterAddHeaderConfig>.Create(True);
end;

destructor TRomitterHttpConfig.Destroy;
begin
  AddHeaders.Free;
  ProxySetHeaders.Free;
  Upstreams.Free;
  Servers.Free;
  inherited;
end;

constructor TRomitterStreamServerConfig.Create;
begin
  inherited Create;
  ListenHost := '0.0.0.0';
  ListenPort := 0;
  IsUdp := False;
  UsesProxyProtocol := False;
  ProxyPass := '';
  ProxyConnectTimeoutMs := 5000;
  ProxyReadTimeoutMs := 600000;
  ProxySendTimeoutMs := 600000;
  ProxyNextUpstream := [pnucError, pnucTimeout];
  ProxyNextUpstreamTries := 0;
  ProxyNextUpstreamTimeoutMs := 0;
  ProxyResponses := 1;
end;

constructor TRomitterStreamConfig.Create;
begin
  inherited Create;
  Enabled := False;
  Servers := TObjectList<TRomitterStreamServerConfig>.Create(True);
  Upstreams := TObjectList<TRomitterUpstreamConfig>.Create(True);
  ProxyConnectTimeoutMs := 5000;
  ProxyReadTimeoutMs := 600000;
  ProxySendTimeoutMs := 600000;
  ProxyNextUpstream := [pnucError, pnucTimeout];
  ProxyNextUpstreamTries := 0;
  ProxyNextUpstreamTimeoutMs := 0;
end;

destructor TRomitterStreamConfig.Destroy;
begin
  Upstreams.Free;
  Servers.Free;
  inherited;
end;

constructor TRomitterConfig.Create;
begin
  inherited Create;
  Prefix := '';
  User := '';
  Daemon := True;
  MasterProcess := True;
  WorkerProcesses := 1;
  WorkerRlimitNofile := 0;
  ErrorLogFile := ROMITTER_DEFAULT_ERROR_LOG_FILE;
  ErrorLogLevel := 'error';
  PidFile := ROMITTER_DEFAULT_PID_FILE;
  Events.WorkerConnections := 1024;
  Events.MultiAccept := False;
  Http := TRomitterHttpConfig.Create;
  Stream := TRomitterStreamConfig.Create;
end;

destructor TRomitterConfig.Destroy;
begin
  Stream.Free;
  Http.Free;
  inherited;
end;

function TRomitterConfig.EffectiveWorkerProcesses: Integer;
begin
  if WorkerProcesses > 0 then
    Exit(WorkerProcesses);

  Result := TThread.ProcessorCount;
  if Result < 1 then
    Result := 1;
end;

function TRomitterConfig.FindHttpUpstream(const Name: string): TRomitterUpstreamConfig;
var
  Upstream: TRomitterUpstreamConfig;
begin
  for Upstream in Http.Upstreams do
    if SameText(Upstream.Name, Name) then
      Exit(Upstream);
  Result := nil;
end;

function TRomitterConfig.FindStreamUpstream(const Name: string): TRomitterUpstreamConfig;
var
  Upstream: TRomitterUpstreamConfig;
begin
  for Upstream in Stream.Upstreams do
    if SameText(Upstream.Name, Name) then
      Exit(Upstream);
  Result := nil;
end;

function TRomitterConfig.FindUpstream(const Name: string): TRomitterUpstreamConfig;
begin
  Result := FindHttpUpstream(Name);
end;

end.
