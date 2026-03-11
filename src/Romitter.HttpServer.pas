unit Romitter.HttpServer;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.Winsock2,
  Romitter.Config.Model,
  Romitter.Logging,
  Romitter.OpenSsl;

type
  TRomitterProxyAttemptKind = (pakOk, pakError, pakTimeout, pakInvalidHeader);
  TRomitterRequestBodyKind = (rbkNone, rbkContentLength, rbkChunked);
  TRomitterTryFilesActionKind = (tfaNone, tfaServeFile, tfaRedirectUri, tfaStatusCode, tfaNamedLocation);

  TRomitterHttpListener = class
  public
    ListenHost: string;
    ListenPort: Word;
    IsSsl: Boolean;
    IsHttp2: Boolean;
    UsesProxyProtocol: Boolean;
    TlsEndpoint: TObject;
    ListenSocket: TSocket;
    AcceptThread: TThread;
    constructor Create(const AHost: string; const APort: Word;
      const AIsSsl: Boolean = False;
      const AIsHttp2: Boolean = False;
      const AUsesProxyProtocol: Boolean = False;
      const ATlsEndpoint: TObject = nil);
    destructor Destroy; override;
  end;

  TRomitterHttpServer = class
  private
    FConfig: TRomitterConfig;
    FLogger: TRomitterLogger;
    FListeners: TObjectList<TRomitterHttpListener>;
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
    procedure AcceptLoop(const Listener: TRomitterHttpListener);
    function TryAcquireClientSlot(const ClientSocket: TSocket): Boolean;
    procedure ClientConnected(const ClientSocket: TSocket);
    procedure ClientDisconnected(const ClientSocket: TSocket);
    procedure ForceCloseClients;
    function ReadProxyProtocolHeader(const ClientSocket: TSocket;
      out ClientAddress: string; out ClientPort: Word;
      out ErrorText: string): Boolean;
    function EstablishClientTls(const ClientSocket: TSocket;
      const TlsEndpoint: TObject; out ClientSsl: Pointer): Boolean;
    procedure HandleClientHttp2(const ClientSocket: TSocket;
      const ClientSsl: TRomitterSsl; const LocalPort: Word;
      const LocalAddress: string);
    procedure HandleClient(const ClientSocket: TSocket; const LocalPort: Word);
    function HandleHttp2Request(
      const ClientSocket: TSocket;
      const StreamId: Cardinal;
      const Method, Path, Scheme, Authority: string;
      const Headers: TDictionary<string, string>;
      const Body: TBytes;
      const LocalPort: Word;
      const LocalAddress: string;
      out ResponseRaw: TBytes;
      out CloseConnection: Boolean): Boolean;
    function ReceiveRequest(const ClientSocket: TSocket; out Method, Uri, Version: string;
      const Headers: TDictionary<string, string>; out Body: TBytes;
      out ErrorStatusCode: Integer; var PendingRaw: TBytes;
      out BodyDeferred: Boolean; out BodyKind: TRomitterRequestBodyKind;
      out BodyContentLength: Integer; out NeedClientContinue: Boolean;
      const LocalPort: Word; const LocalAddress: string): Boolean;
    procedure ProcessRequest(const ClientSocket: TSocket; const Method, Uri, Version: string;
      const Headers: TDictionary<string, string>; const Body: TBytes;
      const BodyDeferred: Boolean; const BodyKind: TRomitterRequestBodyKind;
      const BodyContentLength: Integer; const NeedClientContinue: Boolean;
      var PendingRaw: TBytes;
      const AllowKeepAlive: Boolean; out CloseConnection: Boolean;
      const LocalPort: Word; const LocalAddress: string);
    function SelectServer(const HostHeader: string;
      const LocalPort: Word; const LocalAddress: string): TRomitterServerConfig;
    function SelectLocation(const Server: TRomitterServerConfig; const UriPath: string): TRomitterLocationConfig;
    function FindNamedLocation(const Server: TRomitterServerConfig;
      const Name: string): TRomitterLocationConfig;
    function EvaluateTryFiles(const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig; const RequestUri, RequestUriPath: string;
      out ActionKind: TRomitterTryFilesActionKind; out TargetValue: string;
      out StatusCode: Integer): Boolean;
    function BuildFilesystemPath(const Root, UriPath: string): string;
    function ParseProxyPassTarget(const ProxyPass: string; out Upstream: TRomitterUpstreamConfig;
      out Host: string; out Port: Word; out BasePath: string;
      out HasUriPart: Boolean; out IsHttpsUpstream: Boolean): Boolean;
    class function ResolveClientHeaderTimeoutMs(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig): Integer; static;
    class function ResolveClientBodyTimeoutMs(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig): Integer; static;
    class function ResolveKeepAliveTimeoutMs(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig): Integer; static;
    class function ResolveSendTimeoutMs(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig): Integer; static;
    class function ResolveClientMaxBodySize(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig): Int64; static;
    class function ResolveDefaultType(const Config: TRomitterConfig;
      const Server: TRomitterServerConfig;
      const Location: TRomitterLocationConfig): string; static;
    function ProxyRequestSingle(const ClientSocket: TSocket; const Host: string;
      const Port: Word; const Method, ForwardUri: string;
      const Headers: TDictionary<string, string>;
      const ClientHeaders: TDictionary<string, string>;
      const Location: TRomitterLocationConfig;
      const Body: TBytes;
      const BodyDeferred: Boolean; const BodyKind: TRomitterRequestBodyKind;
      const BodyContentLength: Integer; const NeedClientContinue: Boolean;
      const ClientMaxBodySize: Int64; const ClientBodyTimeoutMs: Integer;
      var PendingRaw: TBytes;
      const ProxyHttpVersion: TRomitterProxyHttpVersion;
      const UpstreamTls: Boolean;
      const UpstreamTlsServerName: string;
      const UpstreamTlsVerify: Boolean;
      const StreamResponseToClient: Boolean;
      const ConnectTimeoutMs, SendTimeoutMs, ReadTimeoutMs: Integer;
      out ResponseData: TBytes; out StatusCode: Integer;
      out AttemptKind: TRomitterProxyAttemptKind;
      out ResponseRelayed: Boolean;
      out CloseAfterResponse: Boolean): Boolean;
    class function IsRetriableAttempt(
      const AttemptKind: TRomitterProxyAttemptKind;
      const Conditions: TRomitterProxyNextUpstreamConditions): Boolean; static;
    class function IsRetriableStatus(const StatusCode: Integer;
      const Conditions: TRomitterProxyNextUpstreamConditions): Boolean; static;
    class function ParseHttpStatusCode(const ResponseData: TBytes;
      out StatusCode: Integer): Boolean; static;
    class function ShouldCloseAfterProxyResponse(const Method: string;
      const ResponseData: TBytes): Boolean; static;
    class function IsSocketTimeoutError(const ErrorCode: Integer): Boolean; static;
    class function GetClientIpAddress(const ClientSocket: TSocket): string; static;
    class function GetClientIpHash(const ClientSocket: TSocket): Cardinal; static;
    class function TryParseIpv4Address(const Value: string;
      out AddressValue: Cardinal): Boolean; static;
    class function IsLocationAccessAllowed(const ClientAddress: string;
      const Location: TRomitterLocationConfig): Boolean; static;
    class function TryGetLocalEndpoint(const SocketHandle: TSocket;
      out LocalAddress: string; out LocalPort: Word): Boolean; static;
    class function ExpandProxyHeaderValue(const Template: string;
      const ClientHeaders: TDictionary<string, string>;
      const RequestHost, RequestHostRaw, ProxyHost, RemoteAddr, RequestUri: string;
      const IsHttpsRequest: Boolean = False;
      const RequestLocalPort: Word = 0): string; static;
    class function BuildProxyHeaders(const ClientSocket: TSocket;
      const ClientHeaders: TDictionary<string, string>;
      const Location: TRomitterLocationConfig; const UpstreamHost: string;
      const UpstreamPort: Word; const RequestUri: string;
      const PreserveBodyHeaders: Boolean = False;
      const IsUpstreamHttps: Boolean = False;
      const IsHttpsRequest: Boolean = False;
      const RequestLocalPort: Word = 0): TDictionary<string, string>; static;
    class function ShouldAddConfiguredHeader(const StatusCode: Integer;
      const Always: Boolean): Boolean; static;
    class function BuildServerHeaderValue(
      const Server: TRomitterServerConfig): string; static;
    class function ShouldApplySubFilterToContentType(const ContentType: string;
      const SubFilterTypes: TArray<string>): Boolean; static;
    class function LocationHasBufferedResponseFilters(
      const Location: TRomitterLocationConfig): Boolean; static;
    class function LocationHasStreamingHeaderFilters(
      const Location: TRomitterLocationConfig): Boolean; static;
    function ApplyBufferedProxyResponseFilters(const ClientSocket: TSocket;
      const ClientHeaders: TDictionary<string, string>;
      const Location: TRomitterLocationConfig;
      const UpstreamHost: string; const UpstreamPort: Word;
      const RequestUri, Method: string;
      const ResponseData: TBytes): TBytes;
    function FastCgiRequest(const ClientSocket: TSocket;
      const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
      const Method, Uri, Version: string;
      const Headers: TDictionary<string, string>; const Body: TBytes;
      const HostHeader, HostHeaderRaw: string; const LocalPort: Word;
      const LocalAddress: string; const CloseConnection: Boolean;
      out CloseAfterResponse: Boolean): Boolean;
    function ProxyRequest(const ClientSocket: TSocket;
      const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
      const Method, Uri: string; const Headers: TDictionary<string, string>;
      const Body: TBytes; const BodyDeferred: Boolean;
      const BodyKind: TRomitterRequestBodyKind;
      const BodyContentLength: Integer; const NeedClientContinue: Boolean;
      var PendingRaw: TBytes; out CloseConnection: Boolean;
      const IsHttpsRequest: Boolean = False;
      const RequestLocalPort: Word = 0): Boolean;
    function SendResponseHeaders(const ClientSocket: TSocket;
      const StatusCode: Integer; const Reason, ContentType: string;
      const ContentLength: Int64; const CloseConnection: Boolean;
      const Server: TRomitterServerConfig = nil;
      const Location: TRomitterLocationConfig = nil;
      const ClientHeaders: TDictionary<string, string> = nil;
      const RequestUri: string = '';
      const ExtraHeaders: TDictionary<string, string> = nil;
      const ExtraHeaderLines: TArray<string> = nil): Boolean;
    function SendFileResponse(const ClientSocket: TSocket; const StatusCode: Integer;
      const Reason, ContentType, FilePath: string; const SendBody: Boolean;
      const CloseConnection: Boolean;
      const Server: TRomitterServerConfig = nil;
      const Location: TRomitterLocationConfig = nil;
      const ClientHeaders: TDictionary<string, string> = nil;
      const RequestUri: string = ''): Boolean;
    procedure SendSimpleResponse(const ClientSocket: TSocket; const StatusCode: Integer;
      const Reason, ContentType: string; const Body: TBytes;
      const CloseConnection: Boolean = True;
      const Server: TRomitterServerConfig = nil;
      const Location: TRomitterLocationConfig = nil;
      const ClientHeaders: TDictionary<string, string> = nil;
      const RequestUri: string = '';
      const ExtraHeaders: TDictionary<string, string> = nil);
    procedure SendStatus(const ClientSocket: TSocket; const StatusCode: Integer;
      const BodyText: string; const CloseConnection: Boolean = True;
      const Server: TRomitterServerConfig = nil;
      const Location: TRomitterLocationConfig = nil;
      const ClientHeaders: TDictionary<string, string> = nil;
      const RequestUri: string = '';
      const ExtraHeaders: TDictionary<string, string> = nil);
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
  System.Math,
  System.IOUtils,
  System.RegularExpressions,
  Romitter.Constants,
  Romitter.Utils,
  Romitter.Http2;

const
  MAX_HEADER_SIZE = 65536;
  MAX_UPSTREAM_RESPONSE_SIZE = 16 * 1024 * 1024;
  CLIENT_KEEPALIVE_TIMEOUT_MS = 60000;
  // Windows kernel-level listener port sharing (SO_REUSEPORT analogue).
  SO_REUSE_UNICASTPORT = $3007;

threadvar
  GHttpRequestConfig: TRomitterConfig;
  GActiveTlsClientSocket: TSocket;
  GActiveTlsClientSession: TRomitterSsl;
  GProxyProtocolClientAddress: string;
  GProxyProtocolClientPort: Word;
  GProxyProtocolAddressValid: Boolean;
  GHttp2CaptureEnabled: Boolean;
  GHttp2CaptureSocket: TSocket;
  GHttp2CapturedResponse: TBytes;
  GHttp2CaptureCloseConnection: Boolean;

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
  TRomitterTlsServerEntry = class
  public
    ServerNames: TArray<string>;
    SslContext: TRomitterSslContext;
    IsDefaultServer: Boolean;
    constructor Create(const AServerNames: TArray<string>;
      const ASslContext: TRomitterSslContext;
      const AIsDefaultServer: Boolean);
  end;

  TRomitterTlsEndpoint = class
  private
    FListenHost: string;
    FListenPort: Word;
    FEnableHttp2: Boolean;
    FEntries: TObjectList<TRomitterTlsServerEntry>;
    FOwnedContexts: TList<TRomitterSslContext>;
    FDefaultContext: TRomitterSslContext;
    FLogger: TRomitterLogger;
    procedure Reset;
    class function IsWildcardHost(const Host: string): Boolean; static;
    function ListenMatchesEndpoint(const ListenCfg: TRomitterHttpListenConfig): Boolean;
    class function NormalizeHostForServerName(const RawHost: string): string; static;
    class function TryMatchExactServerName(const Pattern, Host: string): Boolean; static;
    class function TryMatchWildcardPrefixServerName(const Pattern, Host: string;
      out WildcardLen: Integer): Boolean; static;
    class function TryMatchWildcardSuffixServerName(const Pattern, Host: string;
      out WildcardLen: Integer): Boolean; static;
    function TryMatchRegexServerName(const Pattern, Host: string): Boolean;
    class function BuildContextCacheKey(const Server: TRomitterServerConfig): string; static;
    function ResolveServerContext(const ServerName: string): TRomitterSslContext;
  public
    constructor Create(const AListenHost: string; const AListenPort: Word;
      const AEnableHttp2: Boolean);
    destructor Destroy; override;
    function BuildFromConfig(const Config: TRomitterConfig;
      const Logger: TRomitterLogger; out ErrorText: string): Boolean;
    function DefaultContext: TRomitterSslContext;
    function ContextForServerName(const ServerName: string): TRomitterSslContext;
  end;

  TRomitterHttpAcceptThread = class(TThread)
  private
    FOwner: TRomitterHttpServer;
    FListener: TRomitterHttpListener;
  protected
    procedure Execute; override;
  public
    constructor Create(const Owner: TRomitterHttpServer;
      const Listener: TRomitterHttpListener);
  end;

  TRomitterClientThread = class(TThread)
  private
    FOwner: TRomitterHttpServer;
    FClientSocket: TSocket;
    FLocalPort: Word;
    FIsSsl: Boolean;
    FIsHttp2: Boolean;
    FUsesProxyProtocol: Boolean;
    FTlsEndpoint: TRomitterTlsEndpoint;
  protected
    procedure Execute; override;
  public
    constructor Create(const Owner: TRomitterHttpServer;
      const ClientSocket: TSocket; const LocalPort: Word;
      const IsSsl: Boolean; const IsHttp2: Boolean;
      const UsesProxyProtocol: Boolean;
      const TlsEndpoint: TRomitterTlsEndpoint);
  end;

function OpenSslServerNameCallback(ssl: TRomitterSsl; ad: PInteger;
  arg: Pointer): Integer; cdecl; forward;
function OpenSslAlpnSelectCallback(ssl: TRomitterSsl; out OutProto: PByte;
  out OutProtoLen: Byte; const InProto: PByte; InProtoLen: Cardinal;
  Arg: Pointer): Integer; cdecl; forward;

constructor TRomitterTlsServerEntry.Create(const AServerNames: TArray<string>;
  const ASslContext: TRomitterSslContext; const AIsDefaultServer: Boolean);
begin
  inherited Create;
  ServerNames := Copy(AServerNames, 0, Length(AServerNames));
  SslContext := ASslContext;
  IsDefaultServer := AIsDefaultServer;
end;

constructor TRomitterTlsEndpoint.Create(const AListenHost: string;
  const AListenPort: Word; const AEnableHttp2: Boolean);
begin
  inherited Create;
  FListenHost := AListenHost;
  FListenPort := AListenPort;
  FEnableHttp2 := AEnableHttp2;
  FEntries := TObjectList<TRomitterTlsServerEntry>.Create(True);
  FOwnedContexts := TList<TRomitterSslContext>.Create;
  FDefaultContext := nil;
  FLogger := nil;
end;

destructor TRomitterTlsEndpoint.Destroy;
begin
  Reset;
  FOwnedContexts.Free;
  FEntries.Free;
  inherited;
end;

procedure TRomitterTlsEndpoint.Reset;
var
  I: Integer;
  Ctx: TRomitterSslContext;
begin
  FEntries.Clear;
  for I := 0 to FOwnedContexts.Count - 1 do
  begin
    Ctx := FOwnedContexts[I];
    OpenSslFreeContext(Ctx);
  end;
  FOwnedContexts.Clear;
  FDefaultContext := nil;
end;

class function TRomitterTlsEndpoint.IsWildcardHost(const Host: string): Boolean;
begin
  Result := SameText(Host, '0.0.0.0') or SameText(Host, '*');
end;

function TRomitterTlsEndpoint.ListenMatchesEndpoint(
  const ListenCfg: TRomitterHttpListenConfig): Boolean;
begin
  if ListenCfg.Port <> FListenPort then
    Exit(False);
  if IsWildcardHost(ListenCfg.Host) or IsWildcardHost(FListenHost) then
    Exit(True);
  Result := SameText(ListenCfg.Host, FListenHost);
end;

class function TRomitterTlsEndpoint.NormalizeHostForServerName(
  const RawHost: string): string;
var
  HostValue: string;
  CloseBracketPos: Integer;
  ColonPos: Integer;
begin
  HostValue := Trim(RawHost);
  if HostValue = '' then
    Exit('');

  if HostValue[1] = '[' then
  begin
    CloseBracketPos := Pos(']', HostValue);
    if CloseBracketPos > 1 then
      HostValue := Copy(HostValue, 2, CloseBracketPos - 2);
  end
  else
  begin
    ColonPos := Pos(':', HostValue);
    if ColonPos > 0 then
      HostValue := Copy(HostValue, 1, ColonPos - 1);
  end;

  while (HostValue <> '') and (HostValue[Length(HostValue)] = '.') do
    Delete(HostValue, Length(HostValue), 1);

  Result := LowerCase(HostValue);
end;

class function TRomitterTlsEndpoint.TryMatchExactServerName(
  const Pattern, Host: string): Boolean;
begin
  if Pattern = '' then
    Exit(False);
  if Pattern[1] = '~' then
    Exit(False);
  if Pattern[1] = '.' then
    Exit(False);
  if Pos('*', Pattern) > 0 then
    Exit(False);
  Result := SameText(Pattern, Host);
end;

class function TRomitterTlsEndpoint.TryMatchWildcardPrefixServerName(
  const Pattern, Host: string; out WildcardLen: Integer): Boolean;
var
  Suffix: string;
  RootName: string;
begin
  WildcardLen := 0;
  if Pattern = '' then
    Exit(False);
  if Pattern[1] = '~' then
    Exit(False);

  if StartsText('*.', Pattern) then
  begin
    Suffix := Copy(Pattern, 2, MaxInt); // ".example.com"
    if (Length(Host) > Length(Suffix)) and EndsText(Suffix, Host) then
    begin
      WildcardLen := Length(Suffix);
      Exit(True);
    end;
    Exit(False);
  end;

  if Pattern[1] = '.' then
  begin
    RootName := Copy(Pattern, 2, MaxInt);
    if SameText(Host, RootName) then
    begin
      WildcardLen := Length(Pattern);
      Exit(True);
    end;
    if (Length(Host) > Length(Pattern)) and EndsText(Pattern, Host) then
    begin
      WildcardLen := Length(Pattern);
      Exit(True);
    end;
    Exit(False);
  end;

  Result := False;
end;

class function TRomitterTlsEndpoint.TryMatchWildcardSuffixServerName(
  const Pattern, Host: string; out WildcardLen: Integer): Boolean;
var
  Prefix: string;
begin
  WildcardLen := 0;
  if Pattern = '' then
    Exit(False);
  if Pattern[1] = '~' then
    Exit(False);
  if not EndsText('.*', Pattern) then
    Exit(False);

  Prefix := Copy(Pattern, 1, Length(Pattern) - 1); // "mail."
  if (Length(Host) > Length(Prefix)) and StartsText(Prefix, Host) then
  begin
    WildcardLen := Length(Prefix);
    Exit(True);
  end;
  Result := False;
end;

function TRomitterTlsEndpoint.TryMatchRegexServerName(
  const Pattern, Host: string): Boolean;
var
  RegexPattern: string;
  RegexOptions: TRegExOptions;
begin
  Result := False;
  if StartsText('~*', Pattern) then
  begin
    RegexPattern := Trim(Copy(Pattern, 3, MaxInt));
    RegexOptions := [roIgnoreCase];
  end
  else if StartsText('~', Pattern) then
  begin
    RegexPattern := Trim(Copy(Pattern, 2, MaxInt));
    RegexOptions := [];
  end
  else
    Exit(False);

  if RegexPattern = '' then
    Exit(False);

  try
    Result := TRegEx.IsMatch(Host, RegexPattern, RegexOptions);
  except
    on E: Exception do
      if FLogger <> nil then
        FLogger.Log(rlWarn, Format('server_name regex "%s" failed in TLS SNI match: %s',
          [Pattern, E.Message]));
  end;
end;

class function TRomitterTlsEndpoint.BuildContextCacheKey(
  const Server: TRomitterServerConfig): string;
var
  I: Integer;
  ProtocolPart: string;
begin
  ProtocolPart := '';
  for I := 0 to High(Server.SslProtocols) do
  begin
    if I > 0 then
      ProtocolPart := ProtocolPart + ',';
    ProtocolPart := ProtocolPart + LowerCase(Server.SslProtocols[I]);
  end;
  Result :=
    LowerCase(Server.SslCertificateFile) + '|' +
    LowerCase(Server.SslCertificateKeyFile) + '|' +
    LowerCase(Server.SslCiphers) + '|' +
    ProtocolPart + '|' +
    BoolToStr(Server.SslPreferServerCiphers, True) + '|' +
    LowerCase(Server.SslSessionCache) + '|' +
    IntToStr(Server.SslSessionTimeoutMs) + '|' +
    BoolToStr(Server.SslSessionTickets, True);
end;

function TRomitterTlsEndpoint.BuildFromConfig(const Config: TRomitterConfig;
  const Logger: TRomitterLogger; out ErrorText: string): Boolean;
var
  Server: TRomitterServerConfig;
  ListenCfg: TRomitterHttpListenConfig;
  HasMatchingListen: Boolean;
  IsDefaultForEndpoint: Boolean;
  Entry: TRomitterTlsServerEntry;
  ContextCache: TDictionary<string, TRomitterSslContext>;
  ContextKey: string;
  SslContext: TRomitterSslContext;
  ContextItem: TRomitterSslContext;
begin
  Result := False;
  ErrorText := '';
  FLogger := Logger;
  Reset;

  if (Config = nil) or (Config.Http = nil) then
  begin
    ErrorText := 'HTTP configuration is not available';
    Exit(False);
  end;

  if not OpenSslEnsureInitialized(ErrorText) then
    Exit(False);

  ContextCache := TDictionary<string, TRomitterSslContext>.Create;
  try
    for Server in Config.Http.Servers do
    begin
      HasMatchingListen := False;
      IsDefaultForEndpoint := False;
      for ListenCfg in Server.Listens do
      begin
        if (not ListenCfg.IsSsl) or (not ListenMatchesEndpoint(ListenCfg)) then
          Continue;
        HasMatchingListen := True;
        if ListenCfg.IsDefaultServer then
          IsDefaultForEndpoint := True;
      end;
      if not HasMatchingListen then
        Continue;

      ContextKey := BuildContextCacheKey(Server);
      if not ContextCache.TryGetValue(ContextKey, SslContext) then
      begin
        if not OpenSslCreateServerContext(
          Server.SslCertificateFile,
          Server.SslCertificateKeyFile,
          Server.SslCiphers,
          Server.SslProtocols,
          Server.SslPreferServerCiphers,
          Server.SslSessionCache,
          Server.SslSessionTimeoutMs,
          Server.SslSessionTickets,
          SslContext,
          ErrorText) then
        begin
          ErrorText := Format(
            'TLS context init failed for %s:%d (cert=%s): %s',
            [FListenHost, FListenPort, Server.SslCertificateFile, ErrorText]);
          Exit(False);
        end;
        ContextCache.Add(ContextKey, SslContext);
        FOwnedContexts.Add(SslContext);
      end;

      Entry := TRomitterTlsServerEntry.Create(
        Server.ServerNames,
        SslContext,
        IsDefaultForEndpoint);
      FEntries.Add(Entry);
      if (FDefaultContext = nil) and IsDefaultForEndpoint then
        FDefaultContext := SslContext;
      if FDefaultContext = nil then
        FDefaultContext := SslContext;
    end;
  finally
    ContextCache.Free;
  end;

  if FDefaultContext = nil then
  begin
    ErrorText := Format('No SSL servers resolved for %s:%d',
      [FListenHost, FListenPort]);
    Exit(False);
  end;

  for ContextItem in FOwnedContexts do
    if not OpenSslSetServerNameCallback(
      ContextItem,
      @OpenSslServerNameCallback,
      Self,
      ErrorText) then
    begin
      ErrorText := Format('TLS SNI setup failed for %s:%d: %s',
        [FListenHost, FListenPort, ErrorText]);
      Exit(False);
    end;

  if FEnableHttp2 then
    for ContextItem in FOwnedContexts do
      if not OpenSslSetAlpnSelectCallback(
        ContextItem,
        @OpenSslAlpnSelectCallback,
        Self,
        ErrorText) then
      begin
        ErrorText := Format('TLS ALPN setup failed for %s:%d: %s',
          [FListenHost, FListenPort, ErrorText]);
        Exit(False);
      end;

  Result := True;
end;

function TRomitterTlsEndpoint.ResolveServerContext(
  const ServerName: string): TRomitterSslContext;
var
  Entry: TRomitterTlsServerEntry;
  Pattern: string;
  MatchLen: Integer;
  NormalizedHost: string;
  Candidate: TRomitterTlsServerEntry;
  DefaultCandidate: TRomitterTlsServerEntry;
  BestWildcardPrefixEntry: TRomitterTlsServerEntry;
  BestWildcardPrefixLen: Integer;
  BestWildcardSuffixEntry: TRomitterTlsServerEntry;
  BestWildcardSuffixLen: Integer;
begin
  Result := nil;
  if FEntries.Count = 0 then
    Exit(nil);

  Candidate := FEntries[0];
  DefaultCandidate := nil;
  for Entry in FEntries do
    if Entry.IsDefaultServer then
    begin
      DefaultCandidate := Entry;
      Break;
    end;

  NormalizedHost := NormalizeHostForServerName(ServerName);

  if NormalizedHost <> '' then
  begin
    for Entry in FEntries do
      for Pattern in Entry.ServerNames do
        if TryMatchExactServerName(Pattern, NormalizedHost) then
          Exit(Entry.SslContext);

    BestWildcardPrefixEntry := nil;
    BestWildcardPrefixLen := -1;
    for Entry in FEntries do
      for Pattern in Entry.ServerNames do
      begin
        if not TryMatchWildcardPrefixServerName(Pattern, NormalizedHost, MatchLen) then
          Continue;
        if MatchLen > BestWildcardPrefixLen then
        begin
          BestWildcardPrefixLen := MatchLen;
          BestWildcardPrefixEntry := Entry;
        end;
      end;
    if BestWildcardPrefixEntry <> nil then
      Exit(BestWildcardPrefixEntry.SslContext);

    BestWildcardSuffixEntry := nil;
    BestWildcardSuffixLen := -1;
    for Entry in FEntries do
      for Pattern in Entry.ServerNames do
      begin
        if not TryMatchWildcardSuffixServerName(Pattern, NormalizedHost, MatchLen) then
          Continue;
        if MatchLen > BestWildcardSuffixLen then
        begin
          BestWildcardSuffixLen := MatchLen;
          BestWildcardSuffixEntry := Entry;
        end;
      end;
    if BestWildcardSuffixEntry <> nil then
      Exit(BestWildcardSuffixEntry.SslContext);

    for Entry in FEntries do
      for Pattern in Entry.ServerNames do
        if TryMatchRegexServerName(Pattern, NormalizedHost) then
          Exit(Entry.SslContext);
  end;

  if DefaultCandidate <> nil then
    Exit(DefaultCandidate.SslContext);
  Result := Candidate.SslContext;
end;

function TRomitterTlsEndpoint.DefaultContext: TRomitterSslContext;
begin
  Result := FDefaultContext;
end;

function TRomitterTlsEndpoint.ContextForServerName(
  const ServerName: string): TRomitterSslContext;
begin
  Result := ResolveServerContext(ServerName);
  if Result = nil then
    Result := FDefaultContext;
end;

function ReadFromSocketCompat(const SocketHandle: TSocket; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
begin
  if (GActiveTlsClientSession = nil) or
     (GActiveTlsClientSocket <> SocketHandle) then
    Exit(recv(SocketHandle, Buffer^, BufferLen, 0));
  Result := OpenSslRead(GActiveTlsClientSession, Buffer, BufferLen);
end;

function WriteToSocketCompat(const SocketHandle: TSocket; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
begin
  if GHttp2CaptureEnabled and (GHttp2CaptureSocket = SocketHandle) then
  begin
    if BufferLen > 0 then
    begin
      SetLength(GHttp2CapturedResponse, Length(GHttp2CapturedResponse) + BufferLen);
      Move(
        Buffer^,
        GHttp2CapturedResponse[Length(GHttp2CapturedResponse) - BufferLen],
        BufferLen);
    end;
    Exit(BufferLen);
  end;

  if (GActiveTlsClientSession = nil) or
     (GActiveTlsClientSocket <> SocketHandle) then
    Exit(send(SocketHandle, Buffer^, BufferLen, 0));
  Result := OpenSslWrite(GActiveTlsClientSession, Buffer, BufferLen);
end;

function OpenSslServerNameCallback(ssl: TRomitterSsl; ad: PInteger;
  arg: Pointer): Integer; cdecl;
const
  SSL_TLSEXT_ERR_OK = 0;
  SSL_TLSEXT_ERR_NOACK = 3;
var
  Endpoint: TRomitterTlsEndpoint;
  SniServerName: string;
  SelectedContext: TRomitterSslContext;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
  try
    if arg = nil then
      Exit;
    Endpoint := TRomitterTlsEndpoint(arg);
    SniServerName := OpenSslGetSessionServerName(ssl);
    SelectedContext := Endpoint.ContextForServerName(SniServerName);
    if (SelectedContext = nil) or
       (not OpenSslSwitchSessionContext(ssl, SelectedContext)) then
      Exit;
    Result := SSL_TLSEXT_ERR_OK;
  except
    Result := SSL_TLSEXT_ERR_NOACK;
  end;
end;

function OpenSslAlpnSelectCallback(ssl: TRomitterSsl; out OutProto: PByte;
  out OutProtoLen: Byte; const InProto: PByte; InProtoLen: Cardinal;
  Arg: Pointer): Integer; cdecl;
const
  SSL_TLSEXT_ERR_OK = 0;
  SSL_TLSEXT_ERR_NOACK = 3;
  ALPN_H2: array[0..1] of Byte = (Ord('h'), Ord('2'));
  ALPN_HTTP11: array[0..7] of Byte =
    (Ord('h'), Ord('t'), Ord('t'), Ord('p'), Ord('/'), Ord('1'), Ord('.'), Ord('1'));
var
  Endpoint: TRomitterTlsEndpoint;
  Cursor: PByte;
  Remaining: Integer;
  ProtoLen: Integer;
  HasHttp11: Boolean;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
  OutProto := nil;
  OutProtoLen := 0;
  if (Arg = nil) or (InProto = nil) then
    Exit;

  Endpoint := TRomitterTlsEndpoint(Arg);
  Cursor := InProto;
  Remaining := Integer(InProtoLen);
  HasHttp11 := False;

  while Remaining > 0 do
  begin
    ProtoLen := Cursor^;
    Inc(Cursor);
    Dec(Remaining);
    if ProtoLen > Remaining then
      Exit(SSL_TLSEXT_ERR_NOACK);

    if Endpoint.FEnableHttp2 and (ProtoLen = 2) and
       (PByte(NativeUInt(Cursor) + 0)^ = ALPN_H2[0]) and
       (PByte(NativeUInt(Cursor) + 1)^ = ALPN_H2[1]) then
    begin
      OutProto := @ALPN_H2[0];
      OutProtoLen := 2;
      Exit(SSL_TLSEXT_ERR_OK);
    end;

    if (ProtoLen = 8) and
       (PByte(NativeUInt(Cursor) + 0)^ = ALPN_HTTP11[0]) and
       (PByte(NativeUInt(Cursor) + 1)^ = ALPN_HTTP11[1]) and
       (PByte(NativeUInt(Cursor) + 2)^ = ALPN_HTTP11[2]) and
       (PByte(NativeUInt(Cursor) + 3)^ = ALPN_HTTP11[3]) and
       (PByte(NativeUInt(Cursor) + 4)^ = ALPN_HTTP11[4]) and
       (PByte(NativeUInt(Cursor) + 5)^ = ALPN_HTTP11[5]) and
       (PByte(NativeUInt(Cursor) + 6)^ = ALPN_HTTP11[6]) and
       (PByte(NativeUInt(Cursor) + 7)^ = ALPN_HTTP11[7]) then
      HasHttp11 := True;

    Inc(Cursor, ProtoLen);
    Dec(Remaining, ProtoLen);
  end;

  if HasHttp11 then
  begin
    OutProto := @ALPN_HTTP11[0];
    OutProtoLen := 8;
    Result := SSL_TLSEXT_ERR_OK;
  end;
end;

function GuessContentType(const FileName: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(TPath.GetExtension(FileName));
  if Ext = '.html' then Exit('text/html; charset=utf-8');
  if Ext = '.htm' then Exit('text/html; charset=utf-8');
  if Ext = '.txt' then Exit('text/plain; charset=utf-8');
  if Ext = '.json' then Exit('application/json; charset=utf-8');
  if Ext = '.css' then Exit('text/css; charset=utf-8');
  if Ext = '.js' then Exit('application/javascript; charset=utf-8');
  if Ext = '.xml' then Exit('application/xml; charset=utf-8');
  if Ext = '.svg' then Exit('image/svg+xml');
  if Ext = '.png' then Exit('image/png');
  if Ext = '.jpg' then Exit('image/jpeg');
  if Ext = '.jpeg' then Exit('image/jpeg');
  if Ext = '.gif' then Exit('image/gif');
  if Ext = '.ico' then Exit('image/x-icon');
  Result := 'application/octet-stream';
end;

function ReasonPhrase(const StatusCode: Integer): string;
begin
  case StatusCode of
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    304: Result := 'Not Modified';
    400: Result := 'Bad Request';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    413: Result := 'Payload Too Large';
    417: Result := 'Expectation Failed';
    431: Result := 'Request Header Fields Too Large';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
  else
    Result := 'OK';
  end;
end;

procedure AppendBytes(var Target: TBytes; const Buffer: Pointer; const Count: Integer);
var
  CurrentLen: Integer;
begin
  if Count <= 0 then
    Exit;

  CurrentLen := Length(Target);
  SetLength(Target, CurrentLen + Count);
  Move(Buffer^, Target[CurrentLen], Count);
end;

function FindByteSequence(const Data, Pattern: TBytes): Integer;
var
  I: Integer;
  J: Integer;
  Matched: Boolean;
begin
  Result := -1;
  if (Length(Data) = 0) or (Length(Pattern) = 0) then
    Exit;
  if Length(Data) < Length(Pattern) then
    Exit;

  for I := 0 to Length(Data) - Length(Pattern) do
  begin
    Matched := True;
    for J := 0 to Length(Pattern) - 1 do
    begin
      if Data[I + J] <> Pattern[J] then
      begin
        Matched := False;
        Break;
      end;
    end;
    if Matched then
      Exit(I);
  end;
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
    Sent := WriteToSocketCompat(SocketHandle, @PByte(Data)[Offset], DataLen - Offset);
    if Sent = SOCKET_ERROR then
      Exit(False);
    if Sent = 0 then
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
    SendMs := 30000;
  ReadMs := ReadTimeoutMs;
  if ReadMs <= 0 then
    ReadMs := 30000;

  setsockopt(SocketHandle, SOL_SOCKET, SO_SNDTIMEO, PAnsiChar(@SendMs), SizeOf(SendMs));
  setsockopt(SocketHandle, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@ReadMs), SizeOf(ReadMs));
end;

function HeaderValue(const Headers: TDictionary<string, string>;
  const Name: string): string;
begin
  if (Headers = nil) or
     (not Headers.TryGetValue(LowerCase(Name), Result)) then
    Result := '';
end;

function TrimHostName(const HostHeader: string): string;
var
  P: Integer;
begin
  Result := HostHeader.Trim;
  P := Pos(':', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
end;

function ProxyJoinUri(const BasePath, Uri: string): string;
var
  LeftPart: string;
  RightPart: string;
begin
  if BasePath = '/' then
    Exit(Uri);

  LeftPart := BasePath;
  RightPart := Uri;

  if LeftPart = '' then
    LeftPart := '/';
  if LeftPart[1] <> '/' then
    LeftPart := '/' + LeftPart;

  if RightPart = '' then
    RightPart := '/';

  if LeftPart.EndsWith('/') and RightPart.StartsWith('/') then
    Result := LeftPart.Substring(0, LeftPart.Length - 1) + RightPart
  else if (not LeftPart.EndsWith('/')) and (not RightPart.StartsWith('/')) then
    Result := LeftPart + '/' + RightPart
  else
    Result := LeftPart + RightPart;
end;

function BuildProxyForwardUri(const RequestUri: string;
  const Location: TRomitterLocationConfig; const ProxyBasePath: string;
  const ProxyHasUriPart: Boolean): string;
var
  RequestPath: string;
  RequestQuery: string;
  QueryPos: Integer;
  Remainder: string;
begin
  if not ProxyHasUriPart then
    Exit(RequestUri);

  QueryPos := Pos('?', RequestUri);
  if QueryPos > 0 then
  begin
    RequestPath := Copy(RequestUri, 1, QueryPos - 1);
    RequestQuery := Copy(RequestUri, QueryPos, MaxInt);
  end
  else
  begin
    RequestPath := RequestUri;
    RequestQuery := '';
  end;
  if RequestPath = '' then
    RequestPath := '/';

  case Location.MatchKind of
    lmkExact:
      Result := ProxyBasePath;

    lmkPrefix,
    lmkPrefixNoRegex:
      begin
        Remainder := RequestPath;
        if (Location.MatchPath <> '') and StartsStr(Location.MatchPath, RequestPath) then
          Remainder := Copy(RequestPath, Length(Location.MatchPath) + 1, MaxInt);
        if Remainder = '' then
          Result := ProxyBasePath
        else
          Result := ProxyJoinUri(ProxyBasePath, Remainder);
      end;
  else
    // For regex locations the replacement prefix is undefined; keep existing behavior.
    Result := ProxyJoinUri(ProxyBasePath, RequestPath);
  end;

  Result := Result + RequestQuery;
end;

constructor TRomitterHttpListener.Create(const AHost: string; const APort: Word;
  const AIsSsl: Boolean; const AIsHttp2: Boolean;
  const AUsesProxyProtocol: Boolean; const ATlsEndpoint: TObject);
begin
  inherited Create;
  ListenHost := AHost;
  ListenPort := APort;
  IsSsl := AIsSsl;
  IsHttp2 := AIsHttp2;
  UsesProxyProtocol := AUsesProxyProtocol;
  TlsEndpoint := ATlsEndpoint;
  ListenSocket := INVALID_SOCKET;
  AcceptThread := nil;
end;

destructor TRomitterHttpListener.Destroy;
begin
  AcceptThread.Free;
  TlsEndpoint.Free;
  if ListenSocket <> INVALID_SOCKET then
    closesocket(ListenSocket);
  inherited;
end;

constructor TRomitterHttpAcceptThread.Create(const Owner: TRomitterHttpServer;
  const Listener: TRomitterHttpListener);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
  FListener := Listener;
  StartThreadCompat(Self);
end;

procedure TRomitterHttpAcceptThread.Execute;
begin
  FOwner.AcceptLoop(FListener);
end;

constructor TRomitterClientThread.Create(const Owner: TRomitterHttpServer;
  const ClientSocket: TSocket; const LocalPort: Word;
  const IsSsl: Boolean; const IsHttp2: Boolean;
  const UsesProxyProtocol: Boolean;
  const TlsEndpoint: TRomitterTlsEndpoint);
begin
  inherited Create(True);
  FreeOnTerminate := True;
  FOwner := Owner;
  FClientSocket := ClientSocket;
  FLocalPort := LocalPort;
  FIsSsl := IsSsl;
  FIsHttp2 := IsHttp2;
  FUsesProxyProtocol := UsesProxyProtocol;
  FTlsEndpoint := TlsEndpoint;
  StartThreadCompat(Self);
end;

procedure TRomitterClientThread.Execute;
var
  ClientSslRaw: Pointer;
  ClientSsl: TRomitterSsl;
  NegotiatedAlpn: string;
  UseHttp2: Boolean;
  ProxyClientAddress: string;
  ProxyErrorText: string;
  ProxyClientPort: Word;
  ProxyHeaderTimeoutMs: Integer;
  LocalAddress: string;
  LocalPortResolved: Word;
begin
  ClientSslRaw := nil;
  ClientSsl := nil;
  GActiveTlsClientSession := nil;
  GActiveTlsClientSocket := INVALID_SOCKET;
  GProxyProtocolClientAddress := '';
  GProxyProtocolClientPort := 0;
  GProxyProtocolAddressValid := False;
  GHttp2CaptureEnabled := False;
  GHttp2CaptureSocket := INVALID_SOCKET;
  GHttp2CapturedResponse := nil;
  GHttp2CaptureCloseConnection := False;
  try
    if FUsesProxyProtocol then
    begin
      ProxyHeaderTimeoutMs := 10000;
      setsockopt(
        FClientSocket,
        SOL_SOCKET,
        SO_RCVTIMEO,
        PAnsiChar(@ProxyHeaderTimeoutMs),
        SizeOf(ProxyHeaderTimeoutMs));
      if not FOwner.ReadProxyProtocolHeader(
        FClientSocket,
        ProxyClientAddress,
        ProxyClientPort,
        ProxyErrorText) then
      begin
        FOwner.FLogger.Log(rlWarn, 'PROXY protocol header rejected: ' + ProxyErrorText);
        Exit;
      end;
      if ProxyClientAddress <> '' then
      begin
        GProxyProtocolClientAddress := ProxyClientAddress;
        GProxyProtocolClientPort := ProxyClientPort;
        GProxyProtocolAddressValid := True;
      end;
    end;

    if FIsSsl and
       (not FOwner.EstablishClientTls(FClientSocket, FTlsEndpoint, ClientSslRaw)) then
      Exit;
    ClientSsl := TRomitterSsl(ClientSslRaw);
    if ClientSsl <> nil then
    begin
      GActiveTlsClientSocket := FClientSocket;
      GActiveTlsClientSession := ClientSsl;
    end;

    LocalAddress := '0.0.0.0';
    LocalPortResolved := FLocalPort;
    TRomitterHttpServer.TryGetLocalEndpoint(
      FClientSocket,
      LocalAddress,
      LocalPortResolved);

    UseHttp2 := False;
    if FIsHttp2 then
    begin
      if ClientSsl <> nil then
      begin
        NegotiatedAlpn := LowerCase(OpenSslGetSelectedAlpnProtocol(ClientSsl));
        UseHttp2 := SameText(NegotiatedAlpn, 'h2');
      end
      else
        UseHttp2 := False;
    end;

    if UseHttp2 then
      FOwner.HandleClientHttp2(
        FClientSocket,
        ClientSsl,
        LocalPortResolved,
        LocalAddress)
    else
      FOwner.HandleClient(FClientSocket, LocalPortResolved);
  finally
    if ClientSsl <> nil then
    begin
      OpenSslFreeSession(ClientSsl);
      GActiveTlsClientSession := nil;
      GActiveTlsClientSocket := INVALID_SOCKET;
    end;
    GProxyProtocolClientAddress := '';
    GProxyProtocolClientPort := 0;
    GProxyProtocolAddressValid := False;
    GHttp2CaptureEnabled := False;
    GHttp2CaptureSocket := INVALID_SOCKET;
    GHttp2CapturedResponse := nil;
    GHttp2CaptureCloseConnection := False;
    shutdown(FClientSocket, SD_BOTH);
    closesocket(FClientSocket);
    FOwner.ClientDisconnected(FClientSocket);
  end;
end;

constructor TRomitterHttpServer.Create(const Config: TRomitterConfig;
  const Logger: TRomitterLogger);
begin
  inherited Create;
  FConfig := Config;
  FLogger := Logger;
  FListeners := TObjectList<TRomitterHttpListener>.Create(True);
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

function TRomitterHttpServer.ActiveConfig: TRomitterConfig;
begin
  if GHttpRequestConfig <> nil then
    Result := GHttpRequestConfig
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

function TRomitterHttpServer.AcquireConfigSnapshot: TRomitterConfig;
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

procedure TRomitterHttpServer.LeaveConfigUsage(const Config: TRomitterConfig);
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

destructor TRomitterHttpServer.Destroy;
begin
  Stop;
  FConfigUsage.Free;
  FConfigUsageLock.Free;
  FClientSockets.Free;
  FClientsLock.Free;
  FListeners.Free;
  inherited;
end;

procedure TRomitterHttpServer.ClientConnected(const ClientSocket: TSocket);
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

procedure TRomitterHttpServer.ClientDisconnected(const ClientSocket: TSocket);
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

function TRomitterHttpServer.TryAcquireClientSlot(
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

procedure TRomitterHttpServer.Start;
var
  WsaData: TWSAData;
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  ReuseValue: Integer;
  Server: TRomitterServerConfig;
  ListenCfg: TRomitterHttpListenConfig;
  Listener: TRomitterHttpListener;
  Existing: TRomitterHttpListener;
  SkipListen: Boolean;
  NormalizedHost: string;
  ListenSslModeConflict: Boolean;
  ListenProxyProtocolConflict: Boolean;
  TlsEndpoint: TRomitterTlsEndpoint;
  TlsErrorText: string;
  SharedListenLogged: TDictionary<string, Boolean>;
  SharedListenKey: string;
  StartupCompleted: Boolean;

  function IsWildcardHost(const Host: string): Boolean;
  begin
    Result := SameText(Host, '0.0.0.0') or SameText(Host, '*');
  end;
begin
  if FConfig.Http.Servers.Count = 0 then
    raise Exception.Create('No HTTP server blocks configured');

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
  SharedListenLogged := TDictionary<string, Boolean>.Create;
  StartupCompleted := False;

  try
    for Server in FConfig.Http.Servers do
      for ListenCfg in Server.Listens do
    begin
      if IsWildcardHost(ListenCfg.Host) then
        NormalizedHost := '0.0.0.0'
      else
        NormalizedHost := ListenCfg.Host;

      SkipListen := False;
      ListenSslModeConflict := False;
      ListenProxyProtocolConflict := False;
      for Existing in FListeners do
      begin
        if Existing.ListenPort <> ListenCfg.Port then
          Continue;
        if IsWildcardHost(Existing.ListenHost) or
           IsWildcardHost(NormalizedHost) or
           SameText(Existing.ListenHost, NormalizedHost) then
        begin
          if Existing.IsSsl <> ListenCfg.IsSsl then
            ListenSslModeConflict := True
          else if Existing.UsesProxyProtocol <> ListenCfg.UsesProxyProtocol then
            ListenProxyProtocolConflict := True
          else
            SkipListen := True;
          Break;
        end;
      end;
      if ListenSslModeConflict then
        raise Exception.CreateFmt(
          'Conflicting listen options for %s:%d: ssl and non-ssl listeners cannot share endpoint',
          [NormalizedHost, ListenCfg.Port]);
      if ListenProxyProtocolConflict then
        raise Exception.CreateFmt(
          'Conflicting listen options for %s:%d: proxy_protocol and non-proxy_protocol listeners cannot share endpoint',
          [NormalizedHost, ListenCfg.Port]);
      if SkipListen then
      begin
        SharedListenKey := LowerCase(NormalizedHost) + ':' + IntToStr(ListenCfg.Port);
        if ListenCfg.IsSsl then
          SharedListenKey := SharedListenKey + ':ssl'
        else
          SharedListenKey := SharedListenKey + ':plain';
        if not SharedListenLogged.ContainsKey(SharedListenKey) then
        begin
          FLogger.Log(rlDebug, Format(
            'HTTP listen %s:%d is shared across server blocks; reusing existing listener',
            [NormalizedHost, ListenCfg.Port]));
          SharedListenLogged.Add(SharedListenKey, True);
        end;
        Continue;
      end;

      TlsEndpoint := nil;
      if ListenCfg.IsSsl then
      begin
        TlsEndpoint := TRomitterTlsEndpoint.Create(
          NormalizedHost,
          ListenCfg.Port,
          ListenCfg.IsHttp2);
        try
          if not TlsEndpoint.BuildFromConfig(FConfig, FLogger, TlsErrorText) then
            raise Exception.CreateFmt(
              'TLS init failed for listen %s:%d: %s',
              [NormalizedHost, ListenCfg.Port, TlsErrorText]);
        except
          TlsEndpoint.Free;
          TlsEndpoint := nil;
          raise;
        end;
      end;

      Listener := TRomitterHttpListener.Create(
        NormalizedHost,
        ListenCfg.Port,
        ListenCfg.IsSsl,
        ListenCfg.IsHttp2,
        ListenCfg.UsesProxyProtocol,
        TlsEndpoint);
      try
        TlsEndpoint := nil;
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

        if IsWildcardHost(Listener.ListenHost) then
          Addr.sin_addr.S_addr := htonl(INADDR_ANY)
        else if not ResolveIpv4Address(Listener.ListenHost, Addr.sin_addr.S_addr) then
          raise Exception.CreateFmt('Unable to resolve listen host: %s', [Listener.ListenHost]);

        if bind(Listener.ListenSocket, AddrSock, SizeOf(Addr)) = SOCKET_ERROR then
          raise Exception.CreateFmt('bind() failed: %d', [WSAGetLastError]);

        if listen(Listener.ListenSocket, SOMAXCONN) = SOCKET_ERROR then
          raise Exception.CreateFmt('listen() failed: %d', [WSAGetLastError]);

        Listener.AcceptThread := TRomitterHttpAcceptThread.Create(Self, Listener);
        FListeners.Add(Listener);
        Listener := nil;
      finally
        TlsEndpoint.Free;
        Listener.Free;
      end;
    end;

    if FListeners.Count = 0 then
      raise Exception.Create('No HTTP listen sockets resolved from configuration');

    for Listener in FListeners do
      if Listener.IsSsl then
        FLogger.Log(rlDebug, Format('HTTPS listening on %s:%d', [Listener.ListenHost, Listener.ListenPort]))
      else
        FLogger.Log(rlDebug, Format('HTTP listening on %s:%d', [Listener.ListenHost, Listener.ListenPort]));
    StartupCompleted := True;
  finally
    if not StartupCompleted then
      Stop;
    SharedListenLogged.Free;
  end;
end;

procedure TRomitterHttpServer.ForceCloseClients;
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

function TRomitterHttpServer.ReadProxyProtocolHeader(
  const ClientSocket: TSocket; out ClientAddress: string; out ClientPort: Word;
  out ErrorText: string): Boolean;
const
  MAX_PROXY_V1_HEADER = 512;
  PROXY_V2_SIGNATURE: array[0..11] of Byte =
    ($0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
var
  FirstByte: Byte;
  PrefixBytes: TBytes;
  HeaderBytes: TBytes;
  Payload: TBytes;
  LineBytes: TBytes;
  ByteValue: Byte;
  ReadLen: Integer;
  I: Integer;
  LineText: string;
  Parts: TStringList;
  ProxyTransport: string;
  SrcPortValue: Integer;
  IpValue: Cardinal;
  VersionNibble: Byte;
  CommandNibble: Byte;
  FamilyNibble: Byte;
  ProtocolNibble: Byte;
  PayloadLength: Word;
  PartValue: Word;
  function ReadExact(const ByteCount: Integer; out Data: TBytes): Boolean;
  var
    Offset: Integer;
    ChunkLen: Integer;
  begin
    SetLength(Data, 0);
    if ByteCount < 0 then
      Exit(False);
    if ByteCount = 0 then
      Exit(True);
    SetLength(Data, ByteCount);
    Offset := 0;
    while Offset < ByteCount do
    begin
      ChunkLen := recv(
        ClientSocket,
        Data[Offset],
        ByteCount - Offset,
        0);
      if ChunkLen <= 0 then
        Exit(False);
      Inc(Offset, ChunkLen);
    end;
    Result := True;
  end;
begin
  Result := False;
  ErrorText := '';
  ClientAddress := '';
  ClientPort := 0;

  ReadLen := recv(ClientSocket, FirstByte, 1, 0);
  if ReadLen <> 1 then
  begin
    ErrorText := 'unable to read PROXY protocol header';
    Exit(False);
  end;

  if FirstByte = Ord('P') then
  begin
    SetLength(LineBytes, 1);
    LineBytes[0] := FirstByte;
    while True do
    begin
      if Length(LineBytes) > MAX_PROXY_V1_HEADER then
      begin
        ErrorText := 'PROXY protocol v1 header is too large';
        Exit(False);
      end;
      ReadLen := recv(ClientSocket, ByteValue, 1, 0);
      if ReadLen <> 1 then
      begin
        ErrorText := 'unexpected EOF while reading PROXY protocol v1 header';
        Exit(False);
      end;
      SetLength(LineBytes, Length(LineBytes) + 1);
      LineBytes[High(LineBytes)] := ByteValue;
      if (Length(LineBytes) >= 2) and
         (LineBytes[High(LineBytes) - 1] = Ord(#13)) and
         (LineBytes[High(LineBytes)] = Ord(#10)) then
        Break;
    end;

    LineText := TEncoding.ASCII.GetString(LineBytes);
    LineText := Trim(LineText);
    if not StartsText('PROXY ', LineText) then
    begin
      ErrorText := 'invalid PROXY protocol v1 preface';
      Exit(False);
    end;

    Parts := TStringList.Create;
    try
      ExtractStrings([' '], [], PChar(LineText), Parts);
      if Parts.Count < 2 then
      begin
        ErrorText := 'invalid PROXY protocol v1 header';
        Exit(False);
      end;

      ProxyTransport := UpperCase(Trim(Parts[1]));
      if ProxyTransport = 'UNKNOWN' then
      begin
        Result := True;
        Exit;
      end;

      if (ProxyTransport <> 'TCP4') and (ProxyTransport <> 'TCP6') then
      begin
        ErrorText := Format('unsupported PROXY protocol v1 transport "%s"', [ProxyTransport]);
        Exit(False);
      end;

      if Parts.Count < 6 then
      begin
        ErrorText := 'invalid PROXY protocol v1 address tuple';
        Exit(False);
      end;

      ClientAddress := Trim(Parts[2]);
      if (ProxyTransport = 'TCP4') and
         ((ClientAddress = '') or (not TryParseIpv4Address(ClientAddress, IpValue))) then
      begin
        ErrorText := 'invalid PROXY protocol v1 source IPv4 address';
        Exit(False);
      end;

      if (not TryStrToInt(Trim(Parts[4]), SrcPortValue)) or
         (SrcPortValue < 0) or (SrcPortValue > 65535) then
      begin
        ErrorText := 'invalid PROXY protocol v1 source port';
        Exit(False);
      end;
      ClientPort := Word(SrcPortValue);
      Result := True;
      Exit;
    finally
      Parts.Free;
    end;
  end;

  if FirstByte <> PROXY_V2_SIGNATURE[0] then
  begin
    ErrorText := 'invalid PROXY protocol preface';
    Exit(False);
  end;

  if not ReadExact(11, PrefixBytes) then
  begin
    ErrorText := 'unable to read PROXY protocol v2 signature';
    Exit(False);
  end;
  for I := 0 to High(PrefixBytes) do
    if PrefixBytes[I] <> PROXY_V2_SIGNATURE[I + 1] then
    begin
      ErrorText := 'invalid PROXY protocol v2 signature';
      Exit(False);
    end;

  if not ReadExact(4, HeaderBytes) then
  begin
    ErrorText := 'unable to read PROXY protocol v2 header';
    Exit(False);
  end;

  VersionNibble := HeaderBytes[0] shr 4;
  CommandNibble := HeaderBytes[0] and $0F;
  FamilyNibble := HeaderBytes[1] shr 4;
  ProtocolNibble := HeaderBytes[1] and $0F;
  PayloadLength := (Word(HeaderBytes[2]) shl 8) or Word(HeaderBytes[3]);

  if VersionNibble <> $2 then
  begin
    ErrorText := 'unsupported PROXY protocol version';
    Exit(False);
  end;

  if not ReadExact(PayloadLength, Payload) then
  begin
    ErrorText := 'unable to read PROXY protocol v2 payload';
    Exit(False);
  end;

  if CommandNibble = $0 then
  begin
    // LOCAL command: receiver should ignore address info.
    Result := True;
    Exit;
  end;
  if CommandNibble <> $1 then
  begin
    ErrorText := 'unsupported PROXY protocol v2 command';
    Exit(False);
  end;

  if (ProtocolNibble <> $1) and (ProtocolNibble <> $2) then
  begin
    ErrorText := 'unsupported PROXY protocol v2 transport';
    Exit(False);
  end;

  if (FamilyNibble = $1) and (PayloadLength >= 12) then
  begin
    ClientAddress := Format(
      '%d.%d.%d.%d',
      [Payload[0], Payload[1], Payload[2], Payload[3]]);
    ClientPort := (Word(Payload[8]) shl 8) or Word(Payload[9]);
    Result := True;
    Exit;
  end;

  if (FamilyNibble = $2) and (PayloadLength >= 36) then
  begin
    ClientAddress := '';
    for I := 0 to 7 do
    begin
      PartValue := (Word(Payload[I * 2]) shl 8) or Word(Payload[I * 2 + 1]);
      if I > 0 then
        ClientAddress := ClientAddress + ':';
      ClientAddress := ClientAddress + LowerCase(IntToHex(PartValue, 1));
    end;
    ClientPort := (Word(Payload[32]) shl 8) or Word(Payload[33]);
    Result := True;
    Exit;
  end;

  if FamilyNibble = $0 then
  begin
    // UNSPEC family; address is intentionally omitted.
    Result := True;
    Exit;
  end;

  ErrorText := 'unsupported PROXY protocol v2 address family';
end;

function TRomitterHttpServer.EstablishClientTls(const ClientSocket: TSocket;
  const TlsEndpoint: TObject; out ClientSsl: Pointer): Boolean;
var
  Endpoint: TRomitterTlsEndpoint;
  Ssl: TRomitterSsl;
  ErrorText: string;
  HandshakeTimeoutMs: Integer;
begin
  ClientSsl := nil;
  Result := False;
  if TlsEndpoint = nil then
    Exit(False);
  Endpoint := TlsEndpoint as TRomitterTlsEndpoint;
  if Endpoint.DefaultContext = nil then
    Exit(False);

  HandshakeTimeoutMs := 30000;
  setsockopt(
    ClientSocket,
    SOL_SOCKET,
    SO_RCVTIMEO,
    PAnsiChar(@HandshakeTimeoutMs),
    SizeOf(HandshakeTimeoutMs));
  setsockopt(
    ClientSocket,
    SOL_SOCKET,
    SO_SNDTIMEO,
    PAnsiChar(@HandshakeTimeoutMs),
    SizeOf(HandshakeTimeoutMs));

  Ssl := nil;
  if not OpenSslCreateSession(
    Endpoint.DefaultContext,
    ClientSocket,
    Ssl,
    ErrorText) then
  begin
    FLogger.Log(rlWarn, 'TLS session creation failed: ' + ErrorText);
    Exit(False);
  end;
  try
    if not OpenSslAcceptSession(Ssl, ErrorText) then
    begin
      if ContainsText(ErrorText, 'alert bad certificate') or
         ContainsText(ErrorText, 'unknown ca') then
        FLogger.Log(rlDebug, 'TLS handshake failed: ' + ErrorText)
      else
        FLogger.Log(rlWarn, 'TLS handshake failed: ' + ErrorText);
      Exit(False);
    end;
    ClientSsl := Ssl;
    Ssl := nil;
    Result := True;
  finally
    if Ssl <> nil then
      OpenSslFreeSession(Ssl);
  end;
end;

procedure TRomitterHttpServer.HandleClientHttp2(const ClientSocket: TSocket;
  const ClientSsl: TRomitterSsl; const LocalPort: Word;
  const LocalAddress: string);
var
  Connection: TRomitterHttp2Connection;
begin
  Connection := TRomitterHttp2Connection.Create(
    ClientSocket,
    ClientSsl,
    FLogger,
    LocalPort,
    LocalAddress,
    HandleHttp2Request);
  try
    if not Connection.Run then
      FLogger.Log(rlDebug, 'HTTP/2 connection closed');
  finally
    Connection.Free;
  end;
end;

function TRomitterHttpServer.HandleHttp2Request(
  const ClientSocket: TSocket;
  const StreamId: Cardinal;
  const Method, Path, Scheme, Authority: string;
  const Headers: TDictionary<string, string>;
  const Body: TBytes;
  const LocalPort: Word;
  const LocalAddress: string;
  out ResponseRaw: TBytes;
  out CloseConnection: Boolean): Boolean;
var
  HeadersCopy: TDictionary<string, string>;
  Pair: TPair<string, string>;
  PendingRaw: TBytes;
  CloseAfterRequest: Boolean;
  BodyKind: TRomitterRequestBodyKind;
  BodyContentLength: Integer;
  RequestUri: string;
begin
  ResponseRaw := nil;
  CloseConnection := False;

  HeadersCopy := TDictionary<string, string>.Create;
  try
    for Pair in Headers do
      HeadersCopy.AddOrSetValue(Pair.Key, Pair.Value);

    if (Authority <> '') and (not HeadersCopy.ContainsKey('host')) then
      HeadersCopy.Add('host', Authority);

    if Length(Body) > 0 then
      BodyKind := rbkContentLength
    else
      BodyKind := rbkNone;
    BodyContentLength := Length(Body);

    PendingRaw := nil;
    CloseAfterRequest := False;
    RequestUri := Path;
    if RequestUri = '' then
      RequestUri := '/';
    GHttp2CaptureEnabled := True;
    GHttp2CaptureSocket := ClientSocket;
    GHttp2CapturedResponse := nil;
    GHttp2CaptureCloseConnection := False;
    try
      ProcessRequest(
        ClientSocket,
        Method,
        RequestUri,
        'HTTP/2',
        HeadersCopy,
        Body,
        False,
        BodyKind,
        BodyContentLength,
        False,
        PendingRaw,
        True,
        CloseAfterRequest,
        LocalPort,
        LocalAddress);
      ResponseRaw := Copy(GHttp2CapturedResponse, 0, Length(GHttp2CapturedResponse));
      CloseConnection := CloseAfterRequest or GHttp2CaptureCloseConnection;
      Result := True;
    finally
      GHttp2CaptureEnabled := False;
      GHttp2CaptureSocket := INVALID_SOCKET;
      GHttp2CapturedResponse := nil;
      GHttp2CaptureCloseConnection := False;
    end;
  finally
    HeadersCopy.Free;
  end;
end;

procedure TRomitterHttpServer.Stop(const Force: Boolean);
var
  Listener: TRomitterHttpListener;
  WaitResult: DWORD;
  WaitCycles: Integer;
begin
  FStopping := True;

  for Listener in FListeners do
  begin
    if Listener.ListenSocket <> INVALID_SOCKET then
    begin
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
          FLogger.Log(rlInfo, 'waiting for HTTP clients to drain');
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

procedure TRomitterHttpServer.ReloadConfig(const Config: TRomitterConfig);
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

function TRomitterHttpServer.IsConfigInUse(
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

procedure TRomitterHttpServer.AcceptLoop(const Listener: TRomitterHttpListener);
var
  ClientSocket: TSocket;
  DefaultServer: TRomitterServerConfig;
begin
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
      if not Listener.IsSsl then
      begin
        DefaultServer := SelectServer('', Listener.ListenPort, Listener.ListenHost);
        SendStatus(ClientSocket, 503, 'Service Unavailable', True, DefaultServer, nil, nil, '', nil);
      end;
      shutdown(ClientSocket, SD_BOTH);
      closesocket(ClientSocket);
      Continue;
    end;

    try
      TRomitterClientThread.Create(
        Self,
        ClientSocket,
        Listener.ListenPort,
        Listener.IsSsl,
        Listener.IsHttp2,
        Listener.UsesProxyProtocol,
        Listener.TlsEndpoint as TRomitterTlsEndpoint);
    except
      on E: Exception do
      begin
        FLogger.Log(rlError, 'Unable to spawn client thread: ' + E.Message);
        ClientDisconnected(ClientSocket);
        shutdown(ClientSocket, SD_BOTH);
        closesocket(ClientSocket);
      end;
    end;
  end;
end;

procedure TRomitterHttpServer.HandleClient(const ClientSocket: TSocket;
  const LocalPort: Word);
var
  Method: string;
  Uri: string;
  Version: string;
  Headers: TDictionary<string, string>;
  Body: TBytes;
  ErrorStatusCode: Integer;
  KeepAliveRequested: Boolean;
  CloseConnection: Boolean;
  KeepAliveTimeoutMs: Integer;
  SendTimeoutMs: Integer;
  PendingRaw: TBytes;
  ConnectionHeaderValue: string;
  BodyDeferred: Boolean;
  BodyKind: TRomitterRequestBodyKind;
  BodyContentLength: Integer;
  NeedClientContinue: Boolean;
  KeepAliveRequests: Integer;
  RequestCount: Integer;
  TcpNoDelayValue: Integer;
  LocalAddress: string;
  LocalPortResolved: Word;
  ConfigSnapshot: TRomitterConfig;
  DefaultServer: TRomitterServerConfig;
begin
  LocalAddress := '';
  DefaultServer := nil;
  LocalPortResolved := LocalPort;
  if not TryGetLocalEndpoint(ClientSocket, LocalAddress, LocalPortResolved) then
    LocalAddress := '0.0.0.0';

  ConfigSnapshot := AcquireConfigSnapshot;
  if ConfigSnapshot <> nil then
  begin
    try
      KeepAliveTimeoutMs := ConfigSnapshot.Http.KeepAliveTimeoutMs;
    finally
      LeaveConfigUsage(ConfigSnapshot);
    end;
  end
  else
    KeepAliveTimeoutMs := CLIENT_KEEPALIVE_TIMEOUT_MS;
  if KeepAliveTimeoutMs <= 0 then
    KeepAliveTimeoutMs := CLIENT_KEEPALIVE_TIMEOUT_MS;
  KeepAliveRequests := 1000;
  RequestCount := 0;
  setsockopt(ClientSocket, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@KeepAliveTimeoutMs), SizeOf(KeepAliveTimeoutMs));
  setsockopt(ClientSocket, SOL_SOCKET, SO_SNDTIMEO, PAnsiChar(@KeepAliveTimeoutMs), SizeOf(KeepAliveTimeoutMs));

  Headers := TDictionary<string, string>.Create;
  try
    try
      PendingRaw := nil;
      while not FStopping do
      begin
        ConfigSnapshot := AcquireConfigSnapshot;
        if ConfigSnapshot = nil then
          Break;
        GHttpRequestConfig := ConfigSnapshot;
        try
          Headers.Clear;
          Body := nil;
          ErrorStatusCode := 0;
          BodyDeferred := False;
          BodyKind := rbkNone;
          BodyContentLength := 0;
          NeedClientContinue := False;
          KeepAliveRequests := ConfigSnapshot.Http.KeepAliveRequests;
          if KeepAliveRequests <= 0 then
            KeepAliveRequests := 1000;
          DefaultServer := SelectServer('', LocalPortResolved, LocalAddress);
          KeepAliveTimeoutMs := ResolveKeepAliveTimeoutMs(
            ConfigSnapshot,
            DefaultServer);
          setsockopt(
            ClientSocket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            PAnsiChar(@KeepAliveTimeoutMs),
            SizeOf(KeepAliveTimeoutMs));
          if ConfigSnapshot.Http.TcpNoDelay then
            TcpNoDelayValue := 1
          else
            TcpNoDelayValue := 0;
          setsockopt(
            ClientSocket,
            IPPROTO_TCP,
            TCP_NODELAY,
            PAnsiChar(@TcpNoDelayValue),
            SizeOf(TcpNoDelayValue));

          SendTimeoutMs := ResolveSendTimeoutMs(
            ConfigSnapshot,
            DefaultServer,
            nil);
          // Header receive timeout starts in ReceiveRequest after first byte;
          // keepalive timeout remains active while connection is idle.
          setsockopt(ClientSocket, SOL_SOCKET, SO_SNDTIMEO, PAnsiChar(@SendTimeoutMs), SizeOf(SendTimeoutMs));

          if not ReceiveRequest(
            ClientSocket,
            Method,
            Uri,
            Version,
            Headers,
            Body,
            ErrorStatusCode,
            PendingRaw,
            BodyDeferred,
            BodyKind,
            BodyContentLength,
            NeedClientContinue,
            LocalPortResolved,
            LocalAddress) then
          begin
            if ErrorStatusCode > 0 then
              SendStatus(
                ClientSocket,
                ErrorStatusCode,
                ReasonPhrase(ErrorStatusCode),
                True,
                DefaultServer,
                nil,
                Headers,
                '',
                nil);
            Break;
          end;

          ConnectionHeaderValue := LowerCase(HeaderValue(Headers, 'connection'));
          KeepAliveRequested :=
            (SameText(Version, 'HTTP/1.1') and (Pos('close', ConnectionHeaderValue) = 0)) or
            (SameText(Version, 'HTTP/1.0') and (Pos('keep-alive', ConnectionHeaderValue) > 0));
          CloseConnection := not KeepAliveRequested;

          ProcessRequest(
            ClientSocket,
            Method,
            Uri,
            Version,
            Headers,
            Body,
            BodyDeferred,
            BodyKind,
            BodyContentLength,
            NeedClientContinue,
            PendingRaw,
            KeepAliveRequested,
            CloseConnection,
            LocalPortResolved,
            LocalAddress);
          Inc(RequestCount);
          if (not CloseConnection) and KeepAliveRequested and
             (KeepAliveRequests > 0) and
             (RequestCount >= KeepAliveRequests) then
            CloseConnection := True;

          if CloseConnection then
            Break;
        finally
          GHttpRequestConfig := nil;
          LeaveConfigUsage(ConfigSnapshot);
        end;
      end;
    except
      on E: Exception do
      begin
        FLogger.Log(rlError, 'Client handling error: ' + E.Message);
        SendStatus(
          ClientSocket,
          500,
          'Internal Server Error',
          True,
          DefaultServer,
          nil,
          Headers,
          '',
          nil);
      end;
    end;
  finally
    Headers.Free;
  end;
end;

function TRomitterHttpServer.ReceiveRequest(const ClientSocket: TSocket;
  out Method, Uri, Version: string; const Headers: TDictionary<string, string>;
  out Body: TBytes; out ErrorStatusCode: Integer; var PendingRaw: TBytes;
  out BodyDeferred: Boolean; out BodyKind: TRomitterRequestBodyKind;
  out BodyContentLength: Integer; out NeedClientContinue: Boolean;
  const LocalPort: Word; const LocalAddress: string): Boolean;
var
  Buffer: array[0..8191] of Byte;
  ReadLen: Integer;
  Raw: TBytes;
  RawPos: Integer;
  Delimiter: TBytes;
  HeaderEndPos: Integer;
  HeaderText: string;
  HeaderLines: TStringList;
  I: Integer;
  Line: string;
  ColonPos: Integer;
  HeaderName: string;
  HeaderValueText: string;
  ContentLength: Integer;
  BodyOffset: Integer;
  ExistingBodyLen: Integer;
  NeedToRead: Integer;
  TransferEncoding: string;
  IsChunked: Boolean;
  ExpectHeader: string;
  ContinueBytes: TBytes;
  NeedsContinue: Boolean;
  ChunkSizeText: string;
  ChunkSize64: Int64;
  ChunkData: TBytes;
  TrailerLine: string;
  ExtensionPos: Integer;
  TotalBodyLen: Integer;
  ChunkCrlf: TBytes;
  HostHeader: string;
  HostHeaderRaw: string;
  UriPath: string;
  QueryPos: Integer;
  Config: TRomitterConfig;
  PreRouteServer: TRomitterServerConfig;
  RouteServer: TRomitterServerConfig;
  RouteLocation: TRomitterLocationConfig;
  EffectiveClientHeaderTimeoutMs: Integer;
  EffectiveClientMaxBodySize: Int64;
  EffectiveClientBodyTimeoutMs: Integer;
  EffectiveSendTimeoutMs: Integer;
  BufferBodyLimit: Int64;
  P1: Integer;
  P2: Integer;
  HeaderTimeoutApplied: Boolean;
  ExistingHeaderValue: string;
  HostHeaderCount: Integer;
  function ReceiveMore: Boolean;
  var
    LastErr: Integer;
  begin
    ReadLen := ReadFromSocketCompat(ClientSocket, @Buffer[0], SizeOf(Buffer));
    if ReadLen <= 0 then
    begin
      if ReadLen = 0 then
        ErrorStatusCode := 0
      else
      begin
        LastErr := WSAGetLastError;
        if IsSocketTimeoutError(LastErr) then
        begin
          if Length(Raw) = 0 then
            ErrorStatusCode := 0
          else
            ErrorStatusCode := 400;
        end
        else
          ErrorStatusCode := 400;
      end;
      Exit(False);
    end;
    if not HeaderTimeoutApplied then
    begin
      setsockopt(
        ClientSocket,
        SOL_SOCKET,
        SO_RCVTIMEO,
        PAnsiChar(@EffectiveClientHeaderTimeoutMs),
        SizeOf(EffectiveClientHeaderTimeoutMs));
      HeaderTimeoutApplied := True;
    end;
    AppendBytes(Raw, @Buffer[0], ReadLen);
    Result := True;
  end;

  function EnsureAvailable(const ByteCount: Integer): Boolean;
  begin
    if ByteCount < 0 then
      Exit(False);
    while (Length(Raw) - RawPos) < ByteCount do
      if not ReceiveMore then
        Exit(False);
    Result := True;
  end;

  function ReadLine(out OutLine: string): Boolean;
  var
    SearchPos: Integer;
    StartPos: Integer;
  begin
    OutLine := '';
    while True do
    begin
      StartPos := RawPos;
      for SearchPos := StartPos to Length(Raw) - 2 do
      begin
        if (Raw[SearchPos] = Ord(#13)) and (Raw[SearchPos + 1] = Ord(#10)) then
        begin
          OutLine := TEncoding.ASCII.GetString(
            Raw,
            StartPos,
            SearchPos - StartPos);
          RawPos := SearchPos + 2;
          Exit(True);
        end;
      end;

      if (Length(Raw) - StartPos) > MAX_HEADER_SIZE then
        Exit(False);
      if not ReceiveMore then
        Exit(False);
    end;
  end;

  function ReadExactBytes(const ByteCount: Integer; out Data: TBytes): Boolean;
  begin
    SetLength(Data, 0);
    if ByteCount < 0 then
      Exit(False);
    if ByteCount = 0 then
      Exit(True);

    if not EnsureAvailable(ByteCount) then
      Exit(False);

    SetLength(Data, ByteCount);
    Move(Raw[RawPos], Data[0], ByteCount);
    Inc(RawPos, ByteCount);
    Result := True;
  end;
begin
  ErrorStatusCode := 400;
  BodyDeferred := False;
  BodyKind := rbkNone;
  BodyContentLength := 0;
  NeedClientContinue := False;
  Method := '';
  Uri := '';
  Version := '';
  Body := nil;
  Raw := PendingRaw;
  RawPos := 0;
  HeaderTimeoutApplied := False;
  HostHeaderCount := 0;
  Delimiter := TEncoding.ASCII.GetBytes(#13#10#13#10);
  HeaderEndPos := FindByteSequence(Raw, Delimiter);

  Config := ActiveConfig;
  PreRouteServer := SelectServer('', LocalPort, LocalAddress);
  EffectiveClientHeaderTimeoutMs := ResolveClientHeaderTimeoutMs(
    Config,
    PreRouteServer,
    nil);
  if Length(Raw) > 0 then
  begin
    setsockopt(
      ClientSocket,
      SOL_SOCKET,
      SO_RCVTIMEO,
      PAnsiChar(@EffectiveClientHeaderTimeoutMs),
      SizeOf(EffectiveClientHeaderTimeoutMs));
    HeaderTimeoutApplied := True;
  end;

  while HeaderEndPos < 0 do
  begin
    if Length(Raw) > MAX_HEADER_SIZE then
    begin
      ErrorStatusCode := 431;
      Exit(False);
    end;

    if not ReceiveMore then
      Exit(False);

    HeaderEndPos := FindByteSequence(Raw, Delimiter);
  end;

  HeaderText := TEncoding.ASCII.GetString(Raw, 0, HeaderEndPos);
  HeaderLines := TStringList.Create;
  try
    HeaderLines.Text := StringReplace(HeaderText, #13#10, sLineBreak, [rfReplaceAll]);
    if HeaderLines.Count = 0 then
      Exit(False);

    Line := Trim(HeaderLines[0]);
    P1 := Pos(' ', Line);
    if P1 = 0 then
      Exit(False);
    P2 := PosEx(' ', Line, P1 + 1);
    if P2 = 0 then
      Exit(False);

    Method := Copy(Line, 1, P1 - 1);
    Uri := Copy(Line, P1 + 1, P2 - P1 - 1);
    Version := Copy(Line, P2 + 1, MaxInt);

    // Accept absolute-form request targets and normalize to origin-form path.
    // Some proxies/clients may send: "GET https://host/path HTTP/1.1".
    if StartsText('http://', Uri) or StartsText('https://', Uri) then
    begin
      P1 := Pos('://', Uri);
      if P1 > 0 then
      begin
        Line := Copy(Uri, P1 + 3, MaxInt);
        P2 := Pos('/', Line);
        if P2 > 0 then
          Uri := Copy(Line, P2, MaxInt)
        else
          Uri := '/';
      end;
    end;

    for I := 1 to HeaderLines.Count - 1 do
    begin
      Line := Trim(HeaderLines[I]);
      if Line = '' then
        Continue;
      ColonPos := Pos(':', Line);
      if ColonPos < 2 then
        Continue;
      HeaderName := LowerCase(Trim(Copy(Line, 1, ColonPos - 1)));
      HeaderValueText := Trim(Copy(Line, ColonPos + 1, MaxInt));

      if SameText(HeaderName, 'host') then
      begin
        Inc(HostHeaderCount);
        if HostHeaderCount > 1 then
        begin
          ErrorStatusCode := 400;
          Exit(False);
        end;
      end;

      if SameText(HeaderName, 'content-length') and
         Headers.TryGetValue(HeaderName, ExistingHeaderValue) and
         (Trim(ExistingHeaderValue) <> HeaderValueText) then
      begin
        ErrorStatusCode := 400;
        Exit(False);
      end;

      if SameText(HeaderName, 'transfer-encoding') and
         Headers.TryGetValue(HeaderName, ExistingHeaderValue) then
        HeaderValueText := ExistingHeaderValue + ',' + HeaderValueText;

      Headers.AddOrSetValue(HeaderName, HeaderValueText);
    end;
  finally
    HeaderLines.Free;
  end;

  ContentLength := 0;
  if HeaderValue(Headers, 'content-length') <> '' then
    if (not TryStrToInt(HeaderValue(Headers, 'content-length'), ContentLength)) or
       (ContentLength < 0) then
      Exit(False);

  BodyOffset := HeaderEndPos + Length(Delimiter);
  RawPos := BodyOffset;
  ExistingBodyLen := Length(Raw) - RawPos;

  if SameText(Version, 'HTTP/1.1') and (HeaderValue(Headers, 'host') = '') then
  begin
    ErrorStatusCode := 400;
    Exit(False);
  end;

  TransferEncoding := LowerCase(Trim(HeaderValue(Headers, 'transfer-encoding')));
  TransferEncoding := StringReplace(TransferEncoding, #9, '', [rfReplaceAll]);
  TransferEncoding := StringReplace(TransferEncoding, ' ', '', [rfReplaceAll]);
  if TransferEncoding <> '' then
  begin
    IsChunked := SameText(TransferEncoding, 'chunked');
    if not IsChunked then
    begin
      ErrorStatusCode := 501;
      Exit(False);
    end;
    if HeaderValue(Headers, 'content-length') <> '' then
    begin
      ErrorStatusCode := 400;
      Exit(False);
    end;
  end
  else
    IsChunked := False;
  if IsChunked then
    BodyKind := rbkChunked
  else if ContentLength > 0 then
    BodyKind := rbkContentLength
  else
    BodyKind := rbkNone;
  BodyContentLength := ContentLength;

  HostHeaderRaw := Trim(HeaderValue(Headers, 'host'));
  HostHeader := TrimHostName(HostHeaderRaw);
  RouteServer := SelectServer(HostHeader, LocalPort, LocalAddress);
  UriPath := Uri;
  QueryPos := Pos('?', UriPath);
  if QueryPos > 0 then
    UriPath := Copy(UriPath, 1, QueryPos - 1);
  if UriPath = '' then
    UriPath := '/';

  RouteLocation := nil;
  if Assigned(RouteServer) then
    RouteLocation := SelectLocation(RouteServer, UriPath);

  Config := ActiveConfig;
  EffectiveClientMaxBodySize := ResolveClientMaxBodySize(
    Config,
    RouteServer,
    RouteLocation);
  EffectiveSendTimeoutMs := ResolveSendTimeoutMs(
    Config,
    RouteServer,
    RouteLocation);
  EffectiveClientBodyTimeoutMs := ResolveClientBodyTimeoutMs(
    Config,
    RouteServer,
    RouteLocation);
  if EffectiveClientMaxBodySize > 0 then
    BufferBodyLimit := EffectiveClientMaxBodySize
  else
    BufferBodyLimit := High(Integer);
  if BufferBodyLimit > High(Integer) then
    BufferBodyLimit := High(Integer);
  if BodyKind <> rbkNone then
    setsockopt(
      ClientSocket,
      SOL_SOCKET,
      SO_RCVTIMEO,
      PAnsiChar(@EffectiveClientBodyTimeoutMs),
      SizeOf(EffectiveClientBodyTimeoutMs));
  setsockopt(
    ClientSocket,
    SOL_SOCKET,
    SO_SNDTIMEO,
    PAnsiChar(@EffectiveSendTimeoutMs),
    SizeOf(EffectiveSendTimeoutMs));

  BodyDeferred :=
    Assigned(RouteLocation) and
    (RouteLocation.ReturnCode = 0) and
    (RouteLocation.ProxyPass <> '') and
    (not RouteLocation.ProxyRequestBuffering) and
    (BodyKind <> rbkNone) and
    (not ((BodyKind = rbkChunked) and (RouteLocation.ProxyHttpVersion = phv10)));

  if Assigned(RouteLocation) and
     (RouteLocation.ProxyPass <> '') and
     (not RouteLocation.ProxyRequestBuffering) and
     (BodyKind = rbkChunked) and
     (RouteLocation.ProxyHttpVersion = phv10) then
    FLogger.Log(rlWarn, Format(
      'proxy_request_buffering=off with proxy_http_version 1.0 requires buffering for chunked request "%s"',
      [Uri]));

  if (EffectiveClientMaxBodySize > 0) and
     (Int64(ContentLength) > EffectiveClientMaxBodySize) then
  begin
    ErrorStatusCode := 413;
    Exit(False);
  end;

  ExpectHeader := LowerCase(Trim(HeaderValue(Headers, 'expect')));
  if ExpectHeader <> '' then
  begin
    if not SameText(ExpectHeader, '100-continue') then
    begin
      ErrorStatusCode := 417;
      Exit(False);
    end;

    NeedsContinue := IsChunked or (ContentLength > ExistingBodyLen);
    if NeedsContinue then
    begin
      if BodyDeferred then
        NeedClientContinue := True
      else
      begin
        ContinueBytes := TEncoding.ASCII.GetBytes('HTTP/1.1 100 Continue'#13#10#13#10);
        if not SendBuffer(ClientSocket, @ContinueBytes[0], Length(ContinueBytes)) then
          Exit(False);
      end;
    end;
  end;

  if BodyDeferred then
  begin
    // Body streaming is handled in ProxyRequestSingle.
  end
  else if IsChunked then
  begin
    Body := nil;
    TotalBodyLen := 0;

    while True do
    begin
      if not ReadLine(ChunkSizeText) then
        Exit(False);
      ChunkSizeText := Trim(ChunkSizeText);
      ExtensionPos := Pos(';', ChunkSizeText);
      if ExtensionPos > 0 then
        ChunkSizeText := Trim(Copy(ChunkSizeText, 1, ExtensionPos - 1));
      if ChunkSizeText = '' then
        Exit(False);

      if not TryStrToInt64('$' + ChunkSizeText, ChunkSize64) then
        Exit(False);
      if ChunkSize64 < 0 then
        Exit(False);

      if ChunkSize64 = 0 then
      begin
        repeat
          if not ReadLine(TrailerLine) then
            Exit(False);
        until TrailerLine = '';
        Break;
      end;

      if (ChunkSize64 > BufferBodyLimit) or
         ((Int64(TotalBodyLen) + ChunkSize64) > BufferBodyLimit) then
      begin
        ErrorStatusCode := 413;
        Exit(False);
      end;

      if not ReadExactBytes(Integer(ChunkSize64), ChunkData) then
        Exit(False);
      if Length(ChunkData) > 0 then
        AppendBytes(Body, @ChunkData[0], Length(ChunkData));
      Inc(TotalBodyLen, Integer(ChunkSize64));

      if not ReadExactBytes(2, ChunkCrlf) then
        Exit(False);
      if (Length(ChunkCrlf) <> 2) or
         (ChunkCrlf[0] <> Ord(#13)) or
         (ChunkCrlf[1] <> Ord(#10)) then
        Exit(False);
    end;
  end
  else if ContentLength > 0 then
  begin
    SetLength(Body, ContentLength);
    if ExistingBodyLen > ContentLength then
      ExistingBodyLen := ContentLength;

    if ExistingBodyLen > 0 then
    begin
      Move(Raw[RawPos], Body[0], ExistingBodyLen);
      Inc(RawPos, ExistingBodyLen);
    end;

    NeedToRead := ContentLength - ExistingBodyLen;
    while NeedToRead > 0 do
    begin
      ReadLen := ReadFromSocketCompat(
        ClientSocket,
        @Buffer[0],
        Min(SizeOf(Buffer), NeedToRead));
      if ReadLen <= 0 then
        Exit(False);
      Move(Buffer[0], Body[ContentLength - NeedToRead], ReadLen);
      Dec(NeedToRead, ReadLen);
    end;
  end;

  if RawPos < 0 then
    RawPos := 0;
  if RawPos < Length(Raw) then
  begin
    SetLength(PendingRaw, Length(Raw) - RawPos);
    Move(Raw[RawPos], PendingRaw[0], Length(PendingRaw));
  end
  else
    PendingRaw := nil;

  Result := True;
end;

function TRomitterHttpServer.EvaluateTryFiles(
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const RequestUri, RequestUriPath: string;
  out ActionKind: TRomitterTryFilesActionKind; out TargetValue: string;
  out StatusCode: Integer): Boolean;
var
  RootPath: string;
  RequestQuery: string;
  QueryPos: Integer;
  I: Integer;
  LastIndex: Integer;
  ExpandedValue: string;
  CandidateUriPath: string;
  CandidateFilePath: string;
  IsDirectoryCheck: Boolean;
  CodeValue: Integer;
  function ExpandToken(const Token: string): string;
  var
    ArgsOnly: string;
  begin
    ArgsOnly := RequestQuery;
    if StartsStr('?', ArgsOnly) then
      Delete(ArgsOnly, 1, 1);

    Result := Token;
    Result := StringReplace(Result, '$request_uri', RequestUri, [rfReplaceAll]);
    Result := StringReplace(Result, '$uri', RequestUriPath, [rfReplaceAll]);
    Result := StringReplace(Result, '$query_string', ArgsOnly, [rfReplaceAll]);
    Result := StringReplace(Result, '$args', ArgsOnly, [rfReplaceAll]);
  end;

  function NormalizeUriPath(const Value: string): string;
  var
    P: Integer;
  begin
    Result := Value;
    P := Pos('?', Result);
    if P > 0 then
      Result := Copy(Result, 1, P - 1);
    if Result = '' then
      Result := '/';
    if Result[1] <> '/' then
      Result := '/' + Result;
  end;

  function TryParseStatusCodeValue(const Value: string;
    out ParsedCode: Integer): Boolean;
  var
    CodeText: string;
  begin
    Result := False;
    ParsedCode := 0;
    if (Length(Value) < 2) or (Value[1] <> '=') then
      Exit(False);

    CodeText := Trim(Copy(Value, 2, MaxInt));
    if not TryStrToInt(CodeText, ParsedCode) then
      Exit(False);
    Result := (ParsedCode >= 100) and (ParsedCode <= 999);
  end;
begin
  ActionKind := tfaNone;
  TargetValue := '';
  StatusCode := 0;

  if (not Assigned(Location)) or (Length(Location.TryFiles) < 2) then
    Exit(False);
  Result := True;

  if Location.Root <> '' then
    RootPath := Location.Root
  else
    RootPath := Server.Root;

  QueryPos := Pos('?', RequestUri);
  if QueryPos > 0 then
    RequestQuery := Copy(RequestUri, QueryPos, MaxInt)
  else
    RequestQuery := '';

  LastIndex := High(Location.TryFiles);
  for I := 0 to LastIndex - 1 do
  begin
    ExpandedValue := ExpandToken(Location.TryFiles[I]);
    if ExpandedValue = '' then
      Continue;
    if (ExpandedValue[1] = '=') or (ExpandedValue[1] = '@') then
      Continue;

    IsDirectoryCheck := ExpandedValue[Length(ExpandedValue)] = '/';
    CandidateUriPath := NormalizeUriPath(ExpandedValue);
    if IsDirectoryCheck and (CandidateUriPath = '/') then
      CandidateFilePath := TPath.GetFullPath(RootPath)
    else
      CandidateFilePath := BuildFilesystemPath(RootPath, CandidateUriPath);
    if CandidateFilePath = '' then
      Continue;

    if IsDirectoryCheck then
    begin
      if TDirectory.Exists(CandidateFilePath) then
      begin
        ActionKind := tfaServeFile;
        TargetValue := CandidateFilePath;
        Exit(True);
      end;
    end
    else if TFile.Exists(CandidateFilePath) then
    begin
      ActionKind := tfaServeFile;
      TargetValue := CandidateFilePath;
      Exit(True);
    end;
  end;

  ExpandedValue := ExpandToken(Location.TryFiles[LastIndex]);
  if ExpandedValue = '' then
    ExpandedValue := '/';

  if TryParseStatusCodeValue(ExpandedValue, CodeValue) then
  begin
    ActionKind := tfaStatusCode;
    StatusCode := CodeValue;
    Exit(True);
  end;

  if ExpandedValue[1] = '@' then
  begin
    ActionKind := tfaNamedLocation;
    TargetValue := ExpandedValue;
    Exit(True);
  end;

  ActionKind := tfaRedirectUri;
  if ExpandedValue[1] <> '/' then
    ExpandedValue := '/' + ExpandedValue;
  if Pos('?', ExpandedValue) = 0 then
    ExpandedValue := ExpandedValue + RequestQuery;
  TargetValue := ExpandedValue;
end;

procedure TRomitterHttpServer.ProcessRequest(const ClientSocket: TSocket;
  const Method, Uri, Version: string; const Headers: TDictionary<string, string>;
  const Body: TBytes; const BodyDeferred: Boolean;
  const BodyKind: TRomitterRequestBodyKind;
  const BodyContentLength: Integer; const NeedClientContinue: Boolean;
  var PendingRaw: TBytes; const AllowKeepAlive: Boolean;
  out CloseConnection: Boolean; const LocalPort: Word;
  const LocalAddress: string);
const
  MAX_INTERNAL_REDIRECTS = 10;
var
  Server: TRomitterServerConfig;
  Location: TRomitterLocationConfig;
  HostHeader: string;
  HostHeaderRaw: string;
  ClientAddress: string;
  CurrentUri: string;
  CurrentUriPath: string;
  RootPath: string;
  FilePath: string;
  RelativeAliasPath: string;
  ContentType: string;
  RedirectCount: Integer;
  CurrentNamedLocation: string;
  HasForcedFilePath: Boolean;
  TryActionKind: TRomitterTryFilesActionKind;
  TryTargetValue: string;
  TryStatusCode: Integer;
  RewrittenUri: string;
  RewriteQueryPos: Integer;
  RequestBody: TBytes;
  EffectiveBodyDeferred: Boolean;
  EffectiveNeedClientContinue: Boolean;
  ProxyBodyDeferred: Boolean;
  ProxyCanStreamRequestBody: Boolean;
  FastCgiCloseAfterResponse: Boolean;
  SocketBuffer: array[0..8191] of Byte;
  ReadLen: Integer;
  Config: TRomitterConfig;
  EffectiveClientMaxBodySize: Int64;
  EffectiveClientBodyTimeoutMs: Integer;
  EffectiveSendTimeoutMs: Integer;
  BufferedBodyMaxSize: Int64;
  ConsumedDeferredBodyBytes: Int64;
  RequestIsHttps: Boolean;
  procedure SplitUri(const Value: string; out Path: string);
  var
    P: Integer;
  begin
    Path := Value;
    P := Pos('?', Path);
    if P > 0 then
      Path := Copy(Path, 1, P - 1);
    if Path = '' then
      Path := '/';
  end;
  procedure RefreshClientBodyLimit;
  begin
    Config := ActiveConfig;
    EffectiveClientBodyTimeoutMs := ResolveClientBodyTimeoutMs(Config, Server, Location);
    EffectiveSendTimeoutMs := ResolveSendTimeoutMs(Config, Server, Location);
    EffectiveClientMaxBodySize := ResolveClientMaxBodySize(Config, Server, Location);
    if EffectiveClientMaxBodySize > 0 then
      BufferedBodyMaxSize := EffectiveClientMaxBodySize
    else
      BufferedBodyMaxSize := High(Integer);
    if BufferedBodyMaxSize > High(Integer) then
      BufferedBodyMaxSize := High(Integer);
    setsockopt(
      ClientSocket,
      SOL_SOCKET,
      SO_RCVTIMEO,
      PAnsiChar(@EffectiveClientBodyTimeoutMs),
      SizeOf(EffectiveClientBodyTimeoutMs));
    setsockopt(
      ClientSocket,
      SOL_SOCKET,
      SO_SNDTIMEO,
      PAnsiChar(@EffectiveSendTimeoutMs),
      SizeOf(EffectiveSendTimeoutMs));
  end;
  function IsHttpsOnEndpoint(const CurrentServer: TRomitterServerConfig;
    const EndpointPort: Word): Boolean;
  var
    ListenCfg: TRomitterHttpListenConfig;
  begin
    Result := False;
    if (CurrentServer = nil) or (EndpointPort = 0) then
      Exit(False);
    for ListenCfg in CurrentServer.Listens do
      if (ListenCfg.Port = EndpointPort) and ListenCfg.IsSsl then
        Exit(True);
  end;
  function ResolveDirectoryIndex(const DirectoryPath: string;
    const ActiveLocation: TRomitterLocationConfig): string;
  var
    CandidateName: string;
    CandidatePath: string;
    IndexList: TArray<string>;
    RootForAbsoluteIndex: string;
  begin
    Result := '';
    if Assigned(ActiveLocation) and (Length(ActiveLocation.IndexFiles) > 0) then
      IndexList := ActiveLocation.IndexFiles
    else
      IndexList := Server.IndexFiles;

    if Assigned(ActiveLocation) and (ActiveLocation.AliasPath <> '') then
      RootForAbsoluteIndex := ActiveLocation.AliasPath
    else if Assigned(ActiveLocation) and (ActiveLocation.Root <> '') then
      RootForAbsoluteIndex := ActiveLocation.Root
    else
      RootForAbsoluteIndex := Server.Root;

    for CandidateName in IndexList do
    begin
      if CandidateName = '' then
        Continue;
      if CandidateName[1] = '/' then
        CandidatePath := BuildFilesystemPath(RootForAbsoluteIndex, CandidateName)
      else
        CandidatePath := TPath.Combine(DirectoryPath, CandidateName);
      if (CandidatePath <> '') and TFile.Exists(CandidatePath) then
        Exit(CandidatePath);
    end;
  end;
  function IsMethodTokenChar(const C: Char): Boolean;
  begin
    case C of
      '0'..'9', 'A'..'Z', 'a'..'z',
      '!', '#', '$', '%', '&', '''', '*', '+', '-', '.', '^', '_', '`', '|', '~':
        Result := True;
    else
      Result := False;
    end;
  end;
  function IsValidHttpMethod(const Value: string): Boolean;
  var
    I: Integer;
  begin
    if Value = '' then
      Exit(False);
    for I := 1 to Length(Value) do
      if not IsMethodTokenChar(Value[I]) then
        Exit(False);
    Result := True;
  end;
  procedure ConsumePending(const Count: Integer);
  var
    NewLen: Integer;
  begin
    if Count <= 0 then
      Exit;
    if Count >= Length(PendingRaw) then
    begin
      PendingRaw := nil;
      Exit;
    end;
    NewLen := Length(PendingRaw) - Count;
    Move(PendingRaw[Count], PendingRaw[0], NewLen);
    SetLength(PendingRaw, NewLen);
  end;
  function ReceiveMoreClientData: Boolean;
  begin
    ReadLen := ReadFromSocketCompat(
      ClientSocket,
      @SocketBuffer[0],
      SizeOf(SocketBuffer));
    if ReadLen <= 0 then
      Exit(False);
    AppendBytes(PendingRaw, @SocketBuffer[0], ReadLen);
    Result := True;
  end;
  function FindPendingCrlf: Integer;
  var
    I: Integer;
  begin
    Result := -1;
    for I := 0 to Length(PendingRaw) - 2 do
      if (PendingRaw[I] = Ord(#13)) and (PendingRaw[I + 1] = Ord(#10)) then
        Exit(I);
  end;
  function SendDeferredContinueIfNeeded: Boolean;
  var
    ContinueBytes: TBytes;
  begin
    if not EffectiveNeedClientContinue then
      Exit(True);
    ContinueBytes := TEncoding.ASCII.GetBytes('HTTP/1.1 100 Continue'#13#10#13#10);
    Result := (Length(ContinueBytes) = 0) or
      SendBuffer(ClientSocket, @ContinueBytes[0], Length(ContinueBytes));
    if Result then
      EffectiveNeedClientContinue := False;
  end;
  function ConsumeDeferredBody(const CaptureBody: Boolean; out Captured: TBytes;
    out PayloadTooLarge: Boolean): Boolean;
  var
    Remaining: Int64;
    ToCopy: Integer;
    CrLfPos: Integer;
    LineText: string;
    SizeText: string;
    ChunkSize: Int64;
    SizeExtPos: Integer;
  begin
    Captured := nil;
    PayloadTooLarge := False;
    if not EffectiveBodyDeferred then
      Exit(True);

    if BodyKind = rbkNone then
    begin
      EffectiveBodyDeferred := False;
      Exit(True);
    end;

    if not SendDeferredContinueIfNeeded then
      Exit(False);

    case BodyKind of
      rbkContentLength:
        begin
          Remaining := BodyContentLength;
          while Remaining > 0 do
          begin
            if Length(PendingRaw) = 0 then
              if not ReceiveMoreClientData then
                Exit(False);

            if Remaining > High(Integer) then
              ToCopy := Length(PendingRaw)
            else
              ToCopy := Min(Integer(Remaining), Length(PendingRaw));
            if ToCopy <= 0 then
              Exit(False);

            if (BufferedBodyMaxSize > 0) and
               ((ConsumedDeferredBodyBytes + Int64(ToCopy)) > BufferedBodyMaxSize) then
            begin
              PayloadTooLarge := True;
              Exit(False);
            end;

            if CaptureBody then
              AppendBytes(Captured, @PendingRaw[0], ToCopy);
            Inc(ConsumedDeferredBodyBytes, ToCopy);
 
            ConsumePending(ToCopy);
            Dec(Remaining, ToCopy);
          end;
        end;

      rbkChunked:
        begin
          while True do
          begin
            CrLfPos := FindPendingCrlf;
            while CrLfPos < 0 do
            begin
              if Length(PendingRaw) > MAX_HEADER_SIZE then
                Exit(False);
              if not ReceiveMoreClientData then
                Exit(False);
              CrLfPos := FindPendingCrlf;
            end;

            LineText := TEncoding.ASCII.GetString(PendingRaw, 0, CrLfPos);
            ConsumePending(CrLfPos + 2);

            SizeText := Trim(LineText);
            SizeExtPos := Pos(';', SizeText);
            if SizeExtPos > 0 then
              SizeText := Trim(Copy(SizeText, 1, SizeExtPos - 1));
            if (SizeText = '') or (not TryStrToInt64('$' + SizeText, ChunkSize)) or
               (ChunkSize < 0) then
              Exit(False);

            if ChunkSize = 0 then
            begin
              repeat
                CrLfPos := FindPendingCrlf;
                while CrLfPos < 0 do
                begin
                  if Length(PendingRaw) > MAX_HEADER_SIZE then
                    Exit(False);
                  if not ReceiveMoreClientData then
                    Exit(False);
                  CrLfPos := FindPendingCrlf;
                end;

                LineText := TEncoding.ASCII.GetString(PendingRaw, 0, CrLfPos);
                ConsumePending(CrLfPos + 2);
              until LineText = '';
              Break;
            end;

            Remaining := ChunkSize;
            while Remaining > 0 do
            begin
              if Length(PendingRaw) = 0 then
                if not ReceiveMoreClientData then
                  Exit(False);

              if Remaining > High(Integer) then
                ToCopy := Length(PendingRaw)
              else
                ToCopy := Min(Integer(Remaining), Length(PendingRaw));
              if ToCopy <= 0 then
                Exit(False);

              if (BufferedBodyMaxSize > 0) and
                 ((ConsumedDeferredBodyBytes + Int64(ToCopy)) > BufferedBodyMaxSize) then
              begin
                PayloadTooLarge := True;
                Exit(False);
              end;

              if CaptureBody then
                AppendBytes(Captured, @PendingRaw[0], ToCopy);
              Inc(ConsumedDeferredBodyBytes, ToCopy);

              ConsumePending(ToCopy);
              Dec(Remaining, ToCopy);
            end;

            while Length(PendingRaw) < 2 do
              if not ReceiveMoreClientData then
                Exit(False);
            if (PendingRaw[0] <> Ord(#13)) or (PendingRaw[1] <> Ord(#10)) then
              Exit(False);
            ConsumePending(2);
          end;
        end;
    end;

    EffectiveBodyDeferred := False;
    Result := True;
  end;
  function BufferDeferredBody(out BufferedBody: TBytes): Boolean;
  var
    PayloadTooLarge: Boolean;
  begin
    Result := ConsumeDeferredBody(True, BufferedBody, PayloadTooLarge);
    if Result then
      Exit(True);

    if PayloadTooLarge then
      SendStatus(ClientSocket, 413, 'Payload Too Large', True, Server, Location, Headers, CurrentUri, nil)
    else
      SendStatus(ClientSocket, 400, 'Bad Request', True, Server, Location, Headers, CurrentUri, nil);
    CloseConnection := True;
  end;
  function DrainDeferredBody: Boolean;
  var
    Sink: TBytes;
    PayloadTooLarge: Boolean;
  begin
    Sink := nil;
    Result := ConsumeDeferredBody(False, Sink, PayloadTooLarge);
  end;
  procedure PrepareLocalResponse;
  begin
    if not EffectiveBodyDeferred then
      Exit;

    if EffectiveNeedClientContinue then
    begin
      // For local responses, mirror nginx behavior and finalize with connection close.
      EffectiveNeedClientContinue := False;
      EffectiveBodyDeferred := False;
      CloseConnection := True;
      Exit;
    end;

    if not DrainDeferredBody then
      CloseConnection := True;
  end;
  procedure SendConfiguredReturn(const StatusCode: Integer;
    const ValueTemplate: string);
  var
    ExpandedValue: string;
    RequestHost: string;
    RequestHostRaw: string;
    RemoteAddr: string;
    BodyBytes: TBytes;
    RedirectHeaders: TDictionary<string, string>;
  begin
    if StatusCode = 444 then
    begin
      // nginx-compatible special code: close connection without response.
      CloseConnection := True;
      Exit;
    end;

    RequestHostRaw := HostHeaderRaw;
    if RequestHostRaw = '' then
      RequestHostRaw := Trim(HeaderValue(Headers, 'host'));
    RequestHost := TrimHostName(RequestHostRaw);
    if RequestHost = '' then
      RequestHost := HostHeader;
    if RequestHostRaw = '' then
      RequestHostRaw := RequestHost;
    RemoteAddr := GetClientIpAddress(ClientSocket);

    ExpandedValue := ExpandProxyHeaderValue(
      ValueTemplate,
      Headers,
      RequestHost,
      RequestHostRaw,
      RequestHost,
      RemoteAddr,
      CurrentUri);

    if (StatusCode >= 300) and (StatusCode < 400) and (ExpandedValue <> '') then
    begin
      RedirectHeaders := TDictionary<string, string>.Create;
      try
        RedirectHeaders.AddOrSetValue('Location', ExpandedValue);
        SendResponseHeaders(
          ClientSocket,
          StatusCode,
          ReasonPhrase(StatusCode),
          'text/plain; charset=utf-8',
          0,
          CloseConnection,
          Server,
          Location,
          Headers,
          CurrentUri,
          RedirectHeaders);
      finally
        RedirectHeaders.Free;
      end;
      Exit;
    end;

    BodyBytes := TEncoding.UTF8.GetBytes(ExpandedValue);
    SendSimpleResponse(
      ClientSocket,
      StatusCode,
      ReasonPhrase(StatusCode),
      'text/plain; charset=utf-8',
      BodyBytes,
      CloseConnection,
      Server,
      Location,
      Headers,
      CurrentUri,
      nil);
  end;
begin
  CloseConnection := not AllowKeepAlive;
  Server := nil;
  Location := nil;
  RequestBody := Body;
  EffectiveBodyDeferred := BodyDeferred;
  EffectiveNeedClientContinue := NeedClientContinue;
  CurrentUri := Uri;
  Config := nil;
  EffectiveClientMaxBodySize := 1024 * 1024;
  EffectiveClientBodyTimeoutMs := 60000;
  BufferedBodyMaxSize := 1024 * 1024;
  ConsumedDeferredBodyBytes := 0;

  if not SameText(Copy(Version, 1, 5), 'HTTP/') then
  begin
    SendStatus(ClientSocket, 400, 'Bad Request', True, Server, Location, Headers, CurrentUri, nil);
    CloseConnection := True;
    Exit;
  end;

  if not IsValidHttpMethod(Method) then
  begin
    SendStatus(ClientSocket, 400, 'Bad Request', True, Server, Location, Headers, CurrentUri, nil);
    CloseConnection := True;
    Exit;
  end;

  HostHeaderRaw := Trim(HeaderValue(Headers, 'host'));
  HostHeader := TrimHostName(HostHeaderRaw);
  ClientAddress := GetClientIpAddress(ClientSocket);
  Server := SelectServer(HostHeader, LocalPort, LocalAddress);
  if not Assigned(Server) then
  begin
    SendStatus(ClientSocket, 500, 'No server configured', True, Server, Location, Headers, CurrentUri, nil);
    CloseConnection := True;
    Exit;
  end;

  RedirectCount := 0;
  CurrentNamedLocation := '';

  while True do
  begin
    SplitUri(CurrentUri, CurrentUriPath);

    if Server.ReturnCode > 0 then
    begin
      Location := nil;
      RefreshClientBodyLimit;
      PrepareLocalResponse;
      SendConfiguredReturn(Server.ReturnCode, Server.ReturnBody);
      Exit;
    end;

    if CurrentNamedLocation <> '' then
    begin
      Location := FindNamedLocation(Server, CurrentNamedLocation);
      if not Assigned(Location) then
      begin
        SendStatus(ClientSocket, 500, 'Named location not found', True, Server, Location, Headers, CurrentUri, nil);
        CloseConnection := True;
        Exit;
      end;
      CurrentNamedLocation := '';
    end
    else
      Location := SelectLocation(Server, CurrentUriPath);
    RequestIsHttps := (GActiveTlsClientSession <> nil) or
      IsHttpsOnEndpoint(Server, LocalPort);
    RefreshClientBodyLimit;
    if not IsLocationAccessAllowed(ClientAddress, Location) then
    begin
      PrepareLocalResponse;
      SendStatus(
        ClientSocket,
        403,
        'Forbidden',
        CloseConnection,
        Server,
        Location,
        Headers,
        CurrentUri,
        nil);
      Exit;
    end;

    if Assigned(Location) and (Location.RewritePattern <> '') then
    begin
      try
        if TRegEx.IsMatch(CurrentUriPath, Location.RewritePattern) then
        begin
          RewrittenUri := TRegEx.Replace(
            CurrentUriPath,
            Location.RewritePattern,
            Location.RewriteReplacement);
          if RewrittenUri = '' then
            RewrittenUri := '/';
          if RewrittenUri[1] <> '/' then
            RewrittenUri := '/' + RewrittenUri;

          if Pos('?', RewrittenUri) = 0 then
          begin
            RewriteQueryPos := Pos('?', CurrentUri);
            if RewriteQueryPos > 0 then
              RewrittenUri := RewrittenUri + Copy(CurrentUri, RewriteQueryPos, MaxInt);
          end;

          if SameText(Location.RewriteFlag, 'redirect') then
          begin
            PrepareLocalResponse;
            SendConfiguredReturn(302, RewrittenUri);
            Exit;
          end;

          if SameText(Location.RewriteFlag, 'permanent') then
          begin
            PrepareLocalResponse;
            SendConfiguredReturn(301, RewrittenUri);
            Exit;
          end;

          Inc(RedirectCount);
          if RedirectCount > MAX_INTERNAL_REDIRECTS then
          begin
            SendStatus(ClientSocket, 500, 'Internal Redirect Loop', True, Server, Location, Headers, CurrentUri, nil);
            CloseConnection := True;
            Exit;
          end;

          CurrentUri := RewrittenUri;
          CurrentNamedLocation := '';
          Continue;
        end;
      except
        on E: Exception do
          FLogger.Log(rlWarn, Format(
            'rewrite regex "%s" failed: %s',
            [Location.RewritePattern, E.Message]));
      end;
    end;

    if Assigned(Location) and (Location.ReturnCode > 0) then
    begin
      PrepareLocalResponse;
      SendConfiguredReturn(Location.ReturnCode, Location.ReturnBody);
      Exit;
    end;

    HasForcedFilePath := False;
    TryTargetValue := '';
    TryStatusCode := 0;
    if Assigned(Location) and EvaluateTryFiles(
      Server,
      Location,
      CurrentUri,
      CurrentUriPath,
      TryActionKind,
      TryTargetValue,
      TryStatusCode) then
    begin
      case TryActionKind of
        tfaServeFile:
          begin
            HasForcedFilePath := True;
            FilePath := TryTargetValue;
          end;

        tfaRedirectUri:
          begin
            Inc(RedirectCount);
            if RedirectCount > MAX_INTERNAL_REDIRECTS then
            begin
              SendStatus(ClientSocket, 500, 'Internal Redirect Loop', True, Server, Location, Headers, CurrentUri, nil);
              CloseConnection := True;
              Exit;
            end;

            CurrentUri := TryTargetValue;
            CurrentNamedLocation := '';
            Continue;
          end;

        tfaStatusCode:
          begin
            PrepareLocalResponse;
            SendStatus(
              ClientSocket,
              TryStatusCode,
              ReasonPhrase(TryStatusCode),
              CloseConnection,
              Server,
              Location,
              Headers,
              CurrentUri,
              nil);
            Exit;
          end;

        tfaNamedLocation:
          begin
            Inc(RedirectCount);
            if RedirectCount > MAX_INTERNAL_REDIRECTS then
            begin
              SendStatus(ClientSocket, 500, 'Internal Redirect Loop', True, Server, Location, Headers, CurrentUri, nil);
              CloseConnection := True;
              Exit;
            end;

            CurrentNamedLocation := TryTargetValue;
            Continue;
          end;
      end;
    end;

    if (not HasForcedFilePath) and Assigned(Location) and (Location.ProxyPass <> '') then
    begin
      ProxyCanStreamRequestBody :=
        EffectiveBodyDeferred and
        (BodyKind <> rbkNone) and
        (not Location.ProxyRequestBuffering) and
        (not ((BodyKind = rbkChunked) and (Location.ProxyHttpVersion = phv10)));

      if EffectiveBodyDeferred and (not ProxyCanStreamRequestBody) then
      begin
        if not BufferDeferredBody(RequestBody) then
          Exit;
      end;
      ProxyBodyDeferred := ProxyCanStreamRequestBody;

      if not ProxyRequest(
        ClientSocket,
        Server,
        Location,
        Method,
        CurrentUri,
        Headers,
        RequestBody,
        ProxyBodyDeferred,
        BodyKind,
        BodyContentLength,
        EffectiveNeedClientContinue,
        PendingRaw,
        CloseConnection,
        RequestIsHttps,
        LocalPort) then
      begin
        if not AllowKeepAlive then
          CloseConnection := True;
        SendStatus(ClientSocket, 502, 'Bad Gateway', CloseConnection, Server, Location, Headers, CurrentUri, nil);
      end;
      if not AllowKeepAlive then
        CloseConnection := True;
      Exit;
    end;

    if Assigned(Location) and (Location.FastCgiPass <> '') then
    begin
      if EffectiveBodyDeferred then
      begin
        if not BufferDeferredBody(RequestBody) then
          Exit;
      end;

      FastCgiCloseAfterResponse := CloseConnection;
      if not FastCgiRequest(
        ClientSocket,
        Server,
        Location,
        Method,
        CurrentUri,
        Version,
        Headers,
        RequestBody,
        HostHeader,
        HostHeaderRaw,
        LocalPort,
        LocalAddress,
        CloseConnection,
        FastCgiCloseAfterResponse) then
      begin
        FLogger.Log(rlWarn, Format(
          'fastcgi request failed for "%s" via %s',
          [CurrentUri, Location.FastCgiPass]));
        if not AllowKeepAlive then
          CloseConnection := True;
        SendStatus(
          ClientSocket,
          502,
          'Bad Gateway',
          CloseConnection,
          Server,
          Location,
          Headers,
          CurrentUri,
          nil);
      end
      else
      begin
        CloseConnection := FastCgiCloseAfterResponse;
        if not AllowKeepAlive then
          CloseConnection := True;
      end;
      Exit;
    end;

    if not HasForcedFilePath then
    begin
      if Assigned(Location) and (Location.AliasPath <> '') then
      begin
        RelativeAliasPath := CurrentUriPath;
        if ((Location.MatchKind = lmkPrefix) or
            (Location.MatchKind = lmkPrefixNoRegex)) and
           StartsStr(Location.MatchPath, CurrentUriPath) then
          RelativeAliasPath := Copy(CurrentUriPath, Length(Location.MatchPath) + 1, MaxInt)
        else if Location.MatchKind = lmkExact then
          RelativeAliasPath := '';
        if RelativeAliasPath = '' then
          RelativeAliasPath := '/';
        if RelativeAliasPath[1] <> '/' then
          RelativeAliasPath := '/' + RelativeAliasPath;
        RootPath := Location.AliasPath;
        FilePath := BuildFilesystemPath(RootPath, RelativeAliasPath);
      end
      else
      begin
        if Assigned(Location) and (Location.Root <> '') then
          RootPath := Location.Root
        else
          RootPath := Server.Root;

        FilePath := BuildFilesystemPath(RootPath, CurrentUriPath);
      end;
      if FilePath = '' then
      begin
        PrepareLocalResponse;
        SendStatus(ClientSocket, 403, 'Forbidden', CloseConnection, Server, Location, Headers, CurrentUri, nil);
        Exit;
      end;
    end;

    if TDirectory.Exists(FilePath) then
    begin
      FilePath := ResolveDirectoryIndex(FilePath, Location);
      if FilePath = '' then
      begin
        PrepareLocalResponse;
        SendStatus(ClientSocket, 403, 'Forbidden', CloseConnection, Server, Location, Headers, CurrentUri, nil);
        Exit;
      end;
    end;

    if not TFile.Exists(FilePath) then
    begin
      FLogger.Log(rlWarn, Format(
        'local 404 for uri "%s" in location "%s" (root="%s", file="%s")',
        [CurrentUri, IfThen(Assigned(Location), Location.MatchPath, '(none)'), RootPath, FilePath]));
      PrepareLocalResponse;
      SendStatus(ClientSocket, 404, 'Not Found', CloseConnection, Server, Location, Headers, CurrentUri, nil);
      Exit;
    end;

    PrepareLocalResponse;
    ContentType := GuessContentType(FilePath);
    if (ContentType = 'application/octet-stream') and
       Assigned(Config) then
      ContentType := ResolveDefaultType(Config, Server, Location);
    if not SendFileResponse(
      ClientSocket,
      200,
      'OK',
      ContentType,
      FilePath,
      not SameText(Method, 'HEAD'),
      CloseConnection,
      Server,
      Location,
      Headers,
      CurrentUri) then
      CloseConnection := True;
    Exit;
  end;
end;

class function TRomitterHttpServer.IsSocketTimeoutError(
  const ErrorCode: Integer): Boolean;
begin
  Result := (ErrorCode = WSAETIMEDOUT) or
            (ErrorCode = WSAEWOULDBLOCK) or
            (ErrorCode = WSAEINPROGRESS);
end;

class function TRomitterHttpServer.ParseHttpStatusCode(
  const ResponseData: TBytes; out StatusCode: Integer): Boolean;
var
  I: Integer;
  LineEnd: Integer;
  Line: string;
  P1: Integer;
  P2: Integer;
  CodeText: string;
begin
  StatusCode := 0;

  if Length(ResponseData) < 12 then
    Exit(False);

  LineEnd := -1;
  for I := 0 to Length(ResponseData) - 2 do
  begin
    if (ResponseData[I] = Ord(#13)) and (ResponseData[I + 1] = Ord(#10)) then
    begin
      LineEnd := I;
      Break;
    end;
    if I > 4096 then
      Break;
  end;

  if LineEnd <= 0 then
    Exit(False);

  Line := TEncoding.ASCII.GetString(ResponseData, 0, LineEnd);
  if not StartsText('HTTP/', Line) then
    Exit(False);

  P1 := Pos(' ', Line);
  if P1 <= 0 then
    Exit(False);
  P2 := PosEx(' ', Line, P1 + 1);
  if P2 <= P1 then
    P2 := Length(Line) + 1;

  CodeText := Copy(Line, P1 + 1, P2 - P1 - 1);
  Result := TryStrToInt(CodeText, StatusCode);
end;

class function TRomitterHttpServer.ShouldCloseAfterProxyResponse(
  const Method: string; const ResponseData: TBytes): Boolean;
var
  HeaderEndPos: Integer;
  HeaderText: string;
  HeaderLines: TStringList;
  I: Integer;
  Line: string;
  ColonPos: Integer;
  HeaderName: string;
  HeaderValueText: string;
  LowerValue: string;
  IsHttp10: Boolean;
  HasContentLength: Boolean;
  HasChunked: Boolean;
  ConnectionClose: Boolean;
  ConnectionKeepAlive: Boolean;
  StatusCode: Integer;
begin
  HeaderEndPos := FindByteSequence(ResponseData, TEncoding.ASCII.GetBytes(#13#10#13#10));
  if HeaderEndPos < 0 then
    Exit(True);

  HeaderText := TEncoding.ASCII.GetString(ResponseData, 0, HeaderEndPos);
  HeaderLines := TStringList.Create;
  try
    HeaderLines.Text := StringReplace(HeaderText, #13#10, sLineBreak, [rfReplaceAll]);
    if HeaderLines.Count = 0 then
      Exit(True);

    Line := Trim(HeaderLines[0]);
    IsHttp10 := StartsText('HTTP/1.0', Line);
    if not ParseHttpStatusCode(ResponseData, StatusCode) then
      StatusCode := 0;

    HasContentLength := False;
    HasChunked := False;
    ConnectionClose := False;
    ConnectionKeepAlive := False;

    for I := 1 to HeaderLines.Count - 1 do
    begin
      Line := Trim(HeaderLines[I]);
      if Line = '' then
        Continue;
      ColonPos := Pos(':', Line);
      if ColonPos < 2 then
        Continue;

      HeaderName := LowerCase(Trim(Copy(Line, 1, ColonPos - 1)));
      HeaderValueText := Trim(Copy(Line, ColonPos + 1, MaxInt));
      LowerValue := LowerCase(HeaderValueText);

      if HeaderName = 'content-length' then
        HasContentLength := True
      else if HeaderName = 'transfer-encoding' then
      begin
        if Pos('chunked', LowerValue) > 0 then
          HasChunked := True;
      end
      else if HeaderName = 'connection' then
      begin
        if Pos('close', LowerValue) > 0 then
          ConnectionClose := True;
        if Pos('keep-alive', LowerValue) > 0 then
          ConnectionKeepAlive := True;
      end;
    end;

    if ConnectionClose then
      Exit(True);

    if IsHttp10 and (not ConnectionKeepAlive) then
      Exit(True);

    if SameText(Method, 'HEAD') then
      Exit(False);

    if (StatusCode = 101) or ((StatusCode >= 100) and (StatusCode < 200)) then
      Exit(True);

    if (StatusCode = 204) or (StatusCode = 304) then
      Exit(False);

    if HasChunked or HasContentLength then
      Exit(False);

    Result := True;
  finally
    HeaderLines.Free;
  end;
end;

class function TRomitterHttpServer.IsRetriableStatus(const StatusCode: Integer;
  const Conditions: TRomitterProxyNextUpstreamConditions): Boolean;
begin
  case StatusCode of
    500: Result := pnucHttp500 in Conditions;
    502: Result := pnucHttp502 in Conditions;
    503: Result := pnucHttp503 in Conditions;
    504: Result := pnucHttp504 in Conditions;
  else
    Result := False;
  end;
end;

class function TRomitterHttpServer.IsRetriableAttempt(
  const AttemptKind: TRomitterProxyAttemptKind;
  const Conditions: TRomitterProxyNextUpstreamConditions): Boolean;
begin
  case AttemptKind of
    pakTimeout:
      Result := pnucTimeout in Conditions;
    pakInvalidHeader:
      Result := pnucInvalidHeader in Conditions;
    pakError:
      Result := pnucError in Conditions;
  else
    Result := False;
  end;
end;

class function TRomitterHttpServer.GetClientIpAddress(
  const ClientSocket: TSocket): string;
var
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  AddrLen: Integer;
  AddrText: PAnsiChar;
begin
  if GProxyProtocolAddressValid and (Trim(GProxyProtocolClientAddress) <> '') then
    Exit(GProxyProtocolClientAddress);

  Result := '';
  ZeroMemory(@Addr, SizeOf(Addr));
  AddrLen := SizeOf(Addr);
  if getpeername(ClientSocket, AddrSock, AddrLen) <> 0 then
    Exit('');

  AddrText := inet_ntoa(Addr.sin_addr);
  if AddrText <> nil then
    Result := string(AnsiString(AddrText));
end;

class function TRomitterHttpServer.GetClientIpHash(
  const ClientSocket: TSocket): Cardinal;
var
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  AddrLen: Integer;
  ParsedAddress: Cardinal;
begin
  if GProxyProtocolAddressValid and
     TryParseIpv4Address(GProxyProtocolClientAddress, ParsedAddress) then
    Exit(ParsedAddress);

  Result := 0;
  ZeroMemory(@Addr, SizeOf(Addr));
  AddrLen := SizeOf(Addr);
  if getpeername(ClientSocket, AddrSock, AddrLen) = 0 then
    Result := ntohl(Addr.sin_addr.S_addr);
end;

class function TRomitterHttpServer.TryParseIpv4Address(const Value: string;
  out AddressValue: Cardinal): Boolean;
var
  Parts: TStringList;
  I: Integer;
  Octet: Integer;
begin
  AddressValue := 0;
  Result := False;
  Parts := TStringList.Create;
  try
    ExtractStrings(['.'], [], PChar(Trim(Value)), Parts);
    if Parts.Count <> 4 then
      Exit(False);

    for I := 0 to 3 do
    begin
      if (Parts[I] = '') or (not TryStrToInt(Parts[I], Octet)) then
        Exit(False);
      if (Octet < 0) or (Octet > 255) then
        Exit(False);
      AddressValue := (AddressValue shl 8) or Cardinal(Octet);
    end;

    Result := True;
  finally
    Parts.Free;
  end;
end;

class function TRomitterHttpServer.IsLocationAccessAllowed(
  const ClientAddress: string; const Location: TRomitterLocationConfig): Boolean;
var
  Rule: TRomitterAccessRuleConfig;
  RuleText: string;
  SlashPos: Integer;
  AddressText: string;
  PrefixText: string;
  PrefixLength: Integer;
  ClientIpValue: Cardinal;
  RuleIpValue: Cardinal;
  MaskValue: Cardinal;
  NetworkValue: Cardinal;
  RuleMatched: Boolean;
begin
  if (Location = nil) or (Location.AccessRules.Count = 0) then
    Exit(True);

  if not TryParseIpv4Address(ClientAddress, ClientIpValue) then
    Exit(False);

  for Rule in Location.AccessRules do
  begin
    RuleText := Trim(Rule.RuleText);
    RuleMatched := False;

    if SameText(RuleText, 'all') then
      RuleMatched := True
    else
    begin
      SlashPos := Pos('/', RuleText);
      if SlashPos > 0 then
      begin
        AddressText := Trim(Copy(RuleText, 1, SlashPos - 1));
        PrefixText := Trim(Copy(RuleText, SlashPos + 1, MaxInt));
        if TryParseIpv4Address(AddressText, RuleIpValue) and
           TryStrToInt(PrefixText, PrefixLength) and
           (PrefixLength >= 0) and (PrefixLength <= 32) then
        begin
          if PrefixLength = 0 then
            MaskValue := 0
          else
            MaskValue := Cardinal($FFFFFFFF) shl (32 - PrefixLength);
          NetworkValue := RuleIpValue and MaskValue;
          RuleMatched := (ClientIpValue and MaskValue) = NetworkValue;
        end;
      end
      else if TryParseIpv4Address(RuleText, RuleIpValue) then
        RuleMatched := ClientIpValue = RuleIpValue;
    end;

    if RuleMatched then
      Exit(Rule.IsAllow);
  end;

  Result := True;
end;

class function TRomitterHttpServer.TryGetLocalEndpoint(
  const SocketHandle: TSocket; out LocalAddress: string;
  out LocalPort: Word): Boolean;
var
  Addr: TSockAddrIn;
  AddrSock: TSockAddr absolute Addr;
  AddrLen: Integer;
  AddrText: PAnsiChar;
begin
  Result := False;
  LocalAddress := '';
  LocalPort := 0;
  ZeroMemory(@Addr, SizeOf(Addr));
  AddrLen := SizeOf(Addr);
  if getsockname(SocketHandle, AddrSock, AddrLen) <> 0 then
    Exit(False);

  LocalPort := ntohs(Addr.sin_port);
  AddrText := inet_ntoa(Addr.sin_addr);
  if AddrText <> nil then
    LocalAddress := string(AnsiString(AddrText))
  else
    LocalAddress := '';
  Result := True;
end;

class function TRomitterHttpServer.ExpandProxyHeaderValue(
  const Template: string; const ClientHeaders: TDictionary<string, string>;
  const RequestHost, RequestHostRaw, ProxyHost, RemoteAddr,
  RequestUri: string; const IsHttpsRequest: Boolean;
  const RequestLocalPort: Word): string;
var
  I: Integer;
  J: Integer;
  VarName: string;
  HeaderKey: string;
  VarValue: string;
  ExistingXff: string;
  HostPortPos: Integer;
  HostPortText: string;
  IsHttps: Boolean;
begin
  Result := '';
  IsHttps := IsHttpsRequest;
  if (not IsHttps) and
     (((RequestLocalPort <> 0) and (RequestLocalPort = 443)) or
      (GActiveTlsClientSession <> nil)) then
    IsHttps := True;
  HostPortText := '';
  HostPortPos := LastDelimiter(':', RequestHostRaw);
  if (HostPortPos > 0) and (HostPortPos < Length(RequestHostRaw)) and
     (Pos(']', RequestHostRaw) = 0) then
    HostPortText := Trim(Copy(RequestHostRaw, HostPortPos + 1, MaxInt));

  I := 1;
  while I <= Length(Template) do
  begin
    if Template[I] <> '$' then
    begin
      Result := Result + Template[I];
      Inc(I);
      Continue;
    end;

    Inc(I);
    if I > Length(Template) then
      Break;

    J := I;
    while (J <= Length(Template)) and
          CharInSet(Template[J], ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
      Inc(J);

    if J = I then
    begin
      Result := Result + '$';
      Continue;
    end;

    VarName := Copy(Template, I, J - I);
    VarValue := '';
    if SameText(VarName, 'host') then
      VarValue := RequestHost
    else if SameText(VarName, 'http_host') then
      VarValue := RequestHostRaw
    else if SameText(VarName, 'proxy_host') then
      VarValue := ProxyHost
    else if SameText(VarName, 'remote_addr') then
      VarValue := RemoteAddr
    else if SameText(VarName, 'request_uri') then
      VarValue := RequestUri
    else if SameText(VarName, 'scheme') then
    begin
      if IsHttps then
        VarValue := 'https'
      else
        VarValue := 'http';
    end
    else if SameText(VarName, 'server_port') then
    begin
      if HostPortText <> '' then
        VarValue := HostPortText
      else if RequestLocalPort <> 0 then
        VarValue := RequestLocalPort.ToString
      else if IsHttps then
        VarValue := '443'
      else
        VarValue := '80';
    end
    else if SameText(VarName, 'proxy_add_x_forwarded_for') then
    begin
      ExistingXff := HeaderValue(ClientHeaders, 'x-forwarded-for');
      if ExistingXff <> '' then
      begin
        if RemoteAddr <> '' then
          VarValue := ExistingXff + ', ' + RemoteAddr
        else
          VarValue := ExistingXff;
      end
      else
        VarValue := RemoteAddr;
    end
    else if StartsText('http_', VarName) then
    begin
      HeaderKey := LowerCase(StringReplace(
        Copy(VarName, Length('http_') + 1, MaxInt),
        '_',
        '-',
        [rfReplaceAll]));
      VarValue := HeaderValue(ClientHeaders, HeaderKey);
    end;

    Result := Result + VarValue;
    I := J;
  end;
end;

class function TRomitterHttpServer.BuildProxyHeaders(
  const ClientSocket: TSocket; const ClientHeaders: TDictionary<string, string>;
  const Location: TRomitterLocationConfig; const UpstreamHost: string;
  const UpstreamPort: Word; const RequestUri: string;
  const PreserveBodyHeaders: Boolean; const IsUpstreamHttps: Boolean;
  const IsHttpsRequest: Boolean;
  const RequestLocalPort: Word): TDictionary<string, string>;
var
  Pair: TPair<string, string>;
  HeaderName: string;
  HeaderValueText: string;
  RequestHost: string;
  RequestHostRaw: string;
  ProxyHost: string;
  RemoteAddr: string;
begin
  Result := TDictionary<string, string>.Create;

  for Pair in ClientHeaders do
  begin
    HeaderName := LowerCase(Pair.Key);
    if SameText(HeaderName, 'connection') then
      Continue;
    if SameText(HeaderName, 'proxy-connection') then
      Continue;
    if SameText(HeaderName, 'keep-alive') then
      Continue;
    if SameText(HeaderName, 'te') then
      Continue;
    if SameText(HeaderName, 'trailer') then
      Continue;
    if SameText(HeaderName, 'upgrade') then
      Continue;
    if SameText(HeaderName, 'expect') then
      Continue;
    if (not PreserveBodyHeaders) and SameText(HeaderName, 'transfer-encoding') then
      Continue;
    if (not PreserveBodyHeaders) and SameText(HeaderName, 'content-length') then
      Continue;
    Result.AddOrSetValue(HeaderName, Pair.Value);
  end;

  RequestHostRaw := HeaderValue(ClientHeaders, 'host');
  RequestHost := TrimHostName(RequestHostRaw);
  if RequestHost = '' then
    RequestHost := UpstreamHost;

  if (IsUpstreamHttps and (UpstreamPort = 443)) or
     ((not IsUpstreamHttps) and (UpstreamPort = 80)) then
    ProxyHost := UpstreamHost
  else
    ProxyHost := UpstreamHost + ':' + UpstreamPort.ToString;

  RemoteAddr := GetClientIpAddress(ClientSocket);

  for Pair in Location.ProxySetHeaders do
  begin
    HeaderName := LowerCase(Pair.Key);
    HeaderValueText := ExpandProxyHeaderValue(
      Pair.Value,
      ClientHeaders,
      RequestHost,
      RequestHostRaw,
      ProxyHost,
      RemoteAddr,
      RequestUri,
      IsHttpsRequest,
      RequestLocalPort);
    if HeaderValueText = '' then
      Result.Remove(HeaderName)
    else
      Result.AddOrSetValue(HeaderName, HeaderValueText);
  end;

  if not Result.ContainsKey('host') then
    Result.AddOrSetValue('host', ProxyHost);
  if not Result.ContainsKey('connection') then
    Result.AddOrSetValue('connection', 'close');
end;

class function TRomitterHttpServer.ShouldAddConfiguredHeader(
  const StatusCode: Integer; const Always: Boolean): Boolean;
begin
  if Always then
    Exit(True);
  case StatusCode of
    200, 201, 204, 206, 301, 302, 303, 304, 307, 308:
      Result := True;
  else
    Result := False;
  end;
end;

class function TRomitterHttpServer.BuildServerHeaderValue(
  const Server: TRomitterServerConfig): string;
begin
  if (Server = nil) or Server.ServerTokens then
    Result := ROMITTER_NAME + '/' + ROMITTER_VERSION
  else
    Result := ROMITTER_NAME;
end;

class function TRomitterHttpServer.ShouldApplySubFilterToContentType(
  const ContentType: string; const SubFilterTypes: TArray<string>): Boolean;
var
  BaseType: string;
  FilterType: string;
  FilterTypeNorm: string;
  SlashPos: Integer;
  BaseSlashPos: Integer;
begin
  BaseType := LowerCase(Trim(ContentType));
  SlashPos := Pos(';', BaseType);
  if SlashPos > 0 then
    BaseType := Trim(Copy(BaseType, 1, SlashPos - 1));

  if Length(SubFilterTypes) = 0 then
    Exit(BaseType = 'text/html');

  for FilterType in SubFilterTypes do
  begin
    FilterTypeNorm := LowerCase(Trim(FilterType));
    if (FilterTypeNorm = '') then
      Continue;
    if (FilterTypeNorm = '*') or (FilterTypeNorm = '*/*') then
      Exit(True);
    if FilterTypeNorm = BaseType then
      Exit(True);
    if EndsText('/*', FilterTypeNorm) then
    begin
      BaseSlashPos := Pos('/', BaseType);
      if BaseSlashPos > 0 then
        if SameText(
          Copy(FilterTypeNorm, 1, Length(FilterTypeNorm) - 2),
          Copy(BaseType, 1, BaseSlashPos - 1)) then
          Exit(True);
    end;
  end;

  Result := False;
end;

class function TRomitterHttpServer.LocationHasBufferedResponseFilters(
  const Location: TRomitterLocationConfig): Boolean;
begin
  if Location = nil then
    Exit(False);
  // Body rewriting (sub_filter) requires full buffering.
  // Header-only filters are applied in streaming mode.
  Result := (Location.SubFilterSearch <> '');
end;

class function TRomitterHttpServer.LocationHasStreamingHeaderFilters(
  const Location: TRomitterLocationConfig): Boolean;
begin
  if Location = nil then
    Exit(False);
  Result :=
    (Location.AddHeaders.Count > 0) or
    ((not Location.ProxyRedirectOff) and
     (Location.ProxyRedirectDefault or
      ((Location.ProxyRedirectFrom <> '') and (Location.ProxyRedirectTo <> ''))));
end;

function TRomitterHttpServer.ApplyBufferedProxyResponseFilters(
  const ClientSocket: TSocket;
  const ClientHeaders: TDictionary<string, string>;
  const Location: TRomitterLocationConfig;
  const UpstreamHost: string; const UpstreamPort: Word;
  const RequestUri, Method: string;
  const ResponseData: TBytes): TBytes;
var
  HeaderDelimiter: TBytes;
  HeaderEndPos: Integer;
  HeaderText: string;
  HeaderLines: TStringList;
  StatusCode: Integer;
  BodyOffset: Integer;
  I: Integer;
  ColonPos: Integer;
  Line: string;
  HeaderNameOriginal: string;
  HeaderName: string;
  HeaderValueText: string;
  ContentType: string;
  TransferEncodingLower: string;
  ContentLengthIndex: Integer;
  BodyBytes: TBytes;
  NewBodyBytes: TBytes;
  BodyText: string;
  NewBodyText: string;
  ReplacedBody: Boolean;
  HasBodyByStatus: Boolean;
  RequestHostRaw: string;
  RequestHost: string;
  ProxyHost: string;
  RemoteAddr: string;
  RedirectFrom: string;
  RedirectTo: string;
  AddHeaderItem: TRomitterAddHeaderConfig;
  NewHeaderText: string;
  HeaderBytes: TBytes;
begin
  Result := ResponseData;
  if (Location = nil) or (Length(ResponseData) = 0) then
    Exit;
  if not LocationHasBufferedResponseFilters(Location) then
    Exit;

  HeaderDelimiter := TEncoding.ASCII.GetBytes(#13#10#13#10);
  HeaderEndPos := FindByteSequence(ResponseData, HeaderDelimiter);
  if HeaderEndPos < 0 then
    Exit;

  StatusCode := 0;
  if not ParseHttpStatusCode(ResponseData, StatusCode) then
    StatusCode := 0;

  RequestHostRaw := HeaderValue(ClientHeaders, 'host');
  RequestHost := TrimHostName(RequestHostRaw);
  if RequestHost = '' then
    RequestHost := UpstreamHost;
  if RequestHostRaw = '' then
    RequestHostRaw := RequestHost;
  if UpstreamPort = 80 then
    ProxyHost := UpstreamHost
  else
    ProxyHost := UpstreamHost + ':' + UpstreamPort.ToString;
  RemoteAddr := GetClientIpAddress(ClientSocket);

  RedirectFrom := '';
  RedirectTo := '';
  if not Location.ProxyRedirectOff then
  begin
    if Location.ProxyRedirectDefault then
    begin
      RedirectFrom := 'http://' + ProxyHost;
      RedirectTo := ExpandProxyHeaderValue(
        '$scheme://$http_host',
        ClientHeaders,
        RequestHost,
        RequestHostRaw,
        ProxyHost,
        RemoteAddr,
        RequestUri);
    end
    else if (Location.ProxyRedirectFrom <> '') and
            (Location.ProxyRedirectTo <> '') then
    begin
      RedirectFrom := ExpandProxyHeaderValue(
        Location.ProxyRedirectFrom,
        ClientHeaders,
        RequestHost,
        RequestHostRaw,
        ProxyHost,
        RemoteAddr,
        RequestUri);
      RedirectTo := ExpandProxyHeaderValue(
        Location.ProxyRedirectTo,
        ClientHeaders,
        RequestHost,
        RequestHostRaw,
        ProxyHost,
        RemoteAddr,
        RequestUri);
    end;
  end;

  HeaderText := TEncoding.ASCII.GetString(ResponseData, 0, HeaderEndPos);
  HeaderLines := TStringList.Create;
  try
    HeaderLines.Text := StringReplace(HeaderText, #13#10, sLineBreak, [rfReplaceAll]);
    if HeaderLines.Count = 0 then
      Exit;

    ContentType := '';
    TransferEncodingLower := '';
    ContentLengthIndex := -1;

    for I := 1 to HeaderLines.Count - 1 do
    begin
      Line := HeaderLines[I];
      if Trim(Line) = '' then
        Continue;

      ColonPos := Pos(':', Line);
      if ColonPos < 2 then
        Continue;

      HeaderNameOriginal := Trim(Copy(Line, 1, ColonPos - 1));
      HeaderName := LowerCase(HeaderNameOriginal);
      HeaderValueText := Trim(Copy(Line, ColonPos + 1, MaxInt));

      if HeaderName = 'content-type' then
        ContentType := HeaderValueText
      else if HeaderName = 'transfer-encoding' then
        TransferEncodingLower := LowerCase(HeaderValueText)
      else if HeaderName = 'content-length' then
        ContentLengthIndex := I;

      if (HeaderName = 'location') and (RedirectFrom <> '') and
         StartsText(RedirectFrom, HeaderValueText) then
      begin
        HeaderValueText := RedirectTo + Copy(
          HeaderValueText,
          Length(RedirectFrom) + 1,
          MaxInt);
        HeaderLines[I] := HeaderNameOriginal + ': ' + HeaderValueText;
      end;
    end;

    BodyOffset := HeaderEndPos + Length(HeaderDelimiter);
    if BodyOffset < Length(ResponseData) then
    begin
      SetLength(BodyBytes, Length(ResponseData) - BodyOffset);
      Move(ResponseData[BodyOffset], BodyBytes[0], Length(BodyBytes));
    end
    else
      BodyBytes := nil;

    HasBodyByStatus := not SameText(Method, 'HEAD') and
      (not ((StatusCode >= 100) and (StatusCode < 200))) and
      (StatusCode <> 204) and
      (StatusCode <> 304);

    ReplacedBody := False;
    if HasBodyByStatus and
       (Location.SubFilterSearch <> '') and
       (Pos('chunked', TransferEncodingLower) = 0) and
       ShouldApplySubFilterToContentType(ContentType, Location.SubFilterTypes) and
       (Length(BodyBytes) > 0) then
    begin
      BodyText := TEncoding.UTF8.GetString(BodyBytes);
      if Location.SubFilterOnce then
        NewBodyText := StringReplace(
          BodyText,
          Location.SubFilterSearch,
          Location.SubFilterReplacement,
          [])
      else
        NewBodyText := StringReplace(
          BodyText,
          Location.SubFilterSearch,
          Location.SubFilterReplacement,
          [rfReplaceAll]);
      if NewBodyText <> BodyText then
      begin
        NewBodyBytes := TEncoding.UTF8.GetBytes(NewBodyText);
        BodyBytes := NewBodyBytes;
        ReplacedBody := True;
      end;
    end;

    if ReplacedBody then
    begin
      if ContentLengthIndex >= 0 then
        HeaderLines[ContentLengthIndex] := 'Content-Length: ' + Length(BodyBytes).ToString
      else
        HeaderLines.Add('Content-Length: ' + Length(BodyBytes).ToString);
    end;

    for AddHeaderItem in Location.AddHeaders do
    begin
      if not ShouldAddConfiguredHeader(StatusCode, AddHeaderItem.Always) then
        Continue;
      HeaderValueText := ExpandProxyHeaderValue(
        AddHeaderItem.Value,
        ClientHeaders,
        RequestHost,
        RequestHostRaw,
        ProxyHost,
        RemoteAddr,
        RequestUri);
      if HeaderValueText = '' then
        Continue;
      HeaderLines.Add(AddHeaderItem.Name + ': ' + HeaderValueText);
    end;

    NewHeaderText := '';
    for I := 0 to HeaderLines.Count - 1 do
    begin
      if HeaderLines[I] = '' then
        Continue;
      NewHeaderText := NewHeaderText + HeaderLines[I] + #13#10;
    end;
    NewHeaderText := NewHeaderText + #13#10;
    HeaderBytes := TEncoding.ASCII.GetBytes(NewHeaderText);

    Result := nil;
    if Length(HeaderBytes) > 0 then
      AppendBytes(Result, @HeaderBytes[0], Length(HeaderBytes));
    if Length(BodyBytes) > 0 then
      AppendBytes(Result, @BodyBytes[0], Length(BodyBytes));
  finally
    HeaderLines.Free;
  end;
end;

function TRomitterHttpServer.ParseProxyPassTarget(const ProxyPass: string;
  out Upstream: TRomitterUpstreamConfig; out Host: string; out Port: Word;
  out BasePath: string; out HasUriPart: Boolean;
  out IsHttpsUpstream: Boolean): Boolean;
var
  Work: string;
  SchemePrefixLen: Integer;
  Config: TRomitterConfig;
begin
  HasUriPart := False;
  IsHttpsUpstream := StartsText('https://', ProxyPass);
  Result := ParseHttpUrl(ProxyPass, Host, Port, BasePath);
  if not Result then
    Exit(False);

  if IsHttpsUpstream then
    SchemePrefixLen := Length('https://')
  else
    SchemePrefixLen := Length('http://');
  Work := Copy(ProxyPass, SchemePrefixLen + 1, MaxInt);
  HasUriPart := Pos('/', Work) > 0;

  Config := ActiveConfig;
  if Config <> nil then
    Upstream := Config.FindUpstream(Host)
  else
    Upstream := nil;
end;

function TRomitterHttpServer.FastCgiRequest(const ClientSocket: TSocket;
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const Method, Uri, Version: string;
  const Headers: TDictionary<string, string>; const Body: TBytes;
  const HostHeader, HostHeaderRaw: string; const LocalPort: Word;
  const LocalAddress: string; const CloseConnection: Boolean;
  out CloseAfterResponse: Boolean): Boolean;
const
  FCGI_VERSION_1 = 1;
  FCGI_BEGIN_REQUEST = 1;
  FCGI_END_REQUEST = 3;
  FCGI_PARAMS = 4;
  FCGI_STDIN = 5;
  FCGI_STDOUT = 6;
  FCGI_STDERR = 7;
  FCGI_RESPONDER = 1;
  FCGI_REQUEST_ID = 1;
var
  UpstreamSocket: TSocket;
  Addr: TSockAddrIn;
  AddressValue: u_long;
  ConnectTimedOut: Boolean;
  LastError: Integer;
  TargetHost: string;
  TargetPort: Word;
  Config: TRomitterConfig;
  Upstream: TRomitterUpstreamConfig;
  Peer: TRomitterUpstreamPeer;
  Params: TDictionary<string, string>;
  ParamsData: TBytes;
  PendingData: TBytes;
  StdoutData: TBytes;
  StderrData: TBytes;
  Pair: TPair<string, string>;
  Offset: Integer;
  ToSend: Integer;
  BeginBody: array[0..7] of Byte;
  RecvBuffer: array[0..8191] of Byte;
  ReadLen: Integer;
  RecType: Byte;
  RecContentLen: Integer;
  RecPaddingLen: Integer;
  RecTotalLen: Integer;
  EndRequestSeen: Boolean;
  UriPath: string;
  QueryString: string;
  QueryPos: Integer;
  RequestHost: string;
  RequestHostRawValue: string;
  RemoteAddr: string;
  RemotePortText: string;
  Scheme: string;
  HttpsValue: string;
  DocumentRoot: string;
  ScriptName: string;
  FastCgiPathInfo: string;
  ScriptFileName: string;
  FastCgiIndexName: string;
  ContentTypeValue: string;
  ContentLengthValue: string;
  HeaderEndPos: Integer;
  HeaderDelimiterLen: Integer;
  HeaderText: string;
  SplitPathMatch: TMatch;
  HeaderLines: TStringList;
  Line: string;
  ColonPos: Integer;
  HeaderNameOriginal: string;
  HeaderName: string;
  HeaderValueText: string;
  HeaderLineText: string;
  StatusValue: string;
  StatusCode: Integer;
  StatusSpacePos: Integer;
  StatusReason: string;
  ResponseContentType: string;
  ResponseHeaderLines: TList<string>;
  ResponseBody: TBytes;
  BodyOffset: Integer;
  ShouldSendBody: Boolean;
  BackendConnectionClose: Boolean;
  HasLocationHeader: Boolean;
  StderrText: string;
  TempBytes: TBytes;
  FastCgiParamTemplate: string;
  FastCgiParamExpanded: string;
  FastCgiParamIfNotEmpty: Boolean;
  ExtraHeaderLines: TArray<string>;

  procedure ConsumePending(const Count: Integer);
  var
    NewLen: Integer;
  begin
    if Count <= 0 then
      Exit;
    if Count >= Length(PendingData) then
    begin
      PendingData := nil;
      Exit;
    end;
    NewLen := Length(PendingData) - Count;
    Move(PendingData[Count], PendingData[0], NewLen);
    SetLength(PendingData, NewLen);
  end;

  function ResolveRemotePortText: string;
  var
    AddrRemote: TSockAddrIn;
    AddrRemoteSock: TSockAddr absolute AddrRemote;
    AddrRemoteLen: Integer;
  begin
    Result := '';
    ZeroMemory(@AddrRemote, SizeOf(AddrRemote));
    AddrRemoteLen := SizeOf(AddrRemote);
    if getpeername(ClientSocket, AddrRemoteSock, AddrRemoteLen) = 0 then
      Result := ntohs(AddrRemote.sin_port).ToString;
  end;

  function SendFastCgiRecord(const RecordType: Byte;
    const Content: Pointer; const ContentLen: Integer): Boolean;
  var
    Header: array[0..7] of Byte;
    Padding: array[0..7] of Byte;
    PaddingLen: Byte;
  begin
    Result := False;
    if (ContentLen < 0) or (ContentLen > 65535) then
      Exit(False);
    if (ContentLen > 0) and (Content = nil) then
      Exit(False);

    PaddingLen := Byte((8 - (ContentLen mod 8)) mod 8);
    FillChar(Header, SizeOf(Header), 0);
    Header[0] := FCGI_VERSION_1;
    Header[1] := RecordType;
    Header[2] := Byte((FCGI_REQUEST_ID shr 8) and $FF);
    Header[3] := Byte(FCGI_REQUEST_ID and $FF);
    Header[4] := Byte((ContentLen shr 8) and $FF);
    Header[5] := Byte(ContentLen and $FF);
    Header[6] := PaddingLen;

    if not SendBuffer(UpstreamSocket, @Header[0], SizeOf(Header)) then
      Exit(False);
    if (ContentLen > 0) and (not SendBuffer(UpstreamSocket, Content, ContentLen)) then
      Exit(False);
    if PaddingLen > 0 then
    begin
      FillChar(Padding, SizeOf(Padding), 0);
      if not SendBuffer(UpstreamSocket, @Padding[0], PaddingLen) then
        Exit(False);
    end;

    Result := True;
  end;

  procedure AppendFastCgiLength(var Data: TBytes; const Value: Integer);
  var
    LenBytes: array[0..3] of Byte;
  begin
    if Value < 128 then
    begin
      LenBytes[0] := Byte(Value);
      AppendBytes(Data, @LenBytes[0], 1);
      Exit;
    end;

    LenBytes[0] := Byte(((Value shr 24) and $7F) or $80);
    LenBytes[1] := Byte((Value shr 16) and $FF);
    LenBytes[2] := Byte((Value shr 8) and $FF);
    LenBytes[3] := Byte(Value and $FF);
    AppendBytes(Data, @LenBytes[0], 4);
  end;

  procedure AppendFastCgiNameValue(var Data: TBytes;
    const Name, Value: string);
  var
    NameBytes: TBytes;
    ValueBytes: TBytes;
  begin
    NameBytes := TEncoding.UTF8.GetBytes(Name);
    ValueBytes := TEncoding.UTF8.GetBytes(Value);

    AppendFastCgiLength(Data, Length(NameBytes));
    AppendFastCgiLength(Data, Length(ValueBytes));
    if Length(NameBytes) > 0 then
      AppendBytes(Data, @NameBytes[0], Length(NameBytes));
    if Length(ValueBytes) > 0 then
      AppendBytes(Data, @ValueBytes[0], Length(ValueBytes));
  end;

  function ExpandFastCgiValue(const Template: string): string;
  var
    I: Integer;
    J: Integer;
    VarName: string;
    HeaderKey: string;
  begin
    Result := '';
    I := 1;
    while I <= Length(Template) do
    begin
      if Template[I] <> '$' then
      begin
        Result := Result + Template[I];
        Inc(I);
        Continue;
      end;

      Inc(I);
      if I > Length(Template) then
        Break;

      J := I;
      while (J <= Length(Template)) and
            CharInSet(Template[J], ['a'..'z', 'A'..'Z', '0'..'9', '_']) do
        Inc(J);

      if J = I then
      begin
        Result := Result + '$';
        Continue;
      end;

      VarName := Copy(Template, I, J - I);
      if SameText(VarName, 'request_method') then
        Result := Result + Method
      else if SameText(VarName, 'query_string') or SameText(VarName, 'args') then
        Result := Result + QueryString
      else if SameText(VarName, 'content_type') then
        Result := Result + ContentTypeValue
      else if SameText(VarName, 'content_length') then
        Result := Result + ContentLengthValue
      else if SameText(VarName, 'request_uri') then
        Result := Result + Uri
      else if SameText(VarName, 'document_uri') or SameText(VarName, 'uri') then
        Result := Result + UriPath
      else if SameText(VarName, 'document_root') then
        Result := Result + DocumentRoot
      else if SameText(VarName, 'server_protocol') then
        Result := Result + Version
      else if SameText(VarName, 'request_scheme') or SameText(VarName, 'scheme') then
        Result := Result + Scheme
      else if SameText(VarName, 'https') then
        Result := Result + HttpsValue
      else if SameText(VarName, 'remote_addr') then
        Result := Result + RemoteAddr
      else if SameText(VarName, 'remote_port') then
        Result := Result + RemotePortText
      else if SameText(VarName, 'server_addr') then
        Result := Result + LocalAddress
      else if SameText(VarName, 'server_port') then
        Result := Result + LocalPort.ToString
      else if SameText(VarName, 'server_name') then
        Result := Result + RequestHost
      else if SameText(VarName, 'host') then
        Result := Result + RequestHost
      else if SameText(VarName, 'http_host') then
        Result := Result + RequestHostRawValue
      else if SameText(VarName, 'fastcgi_script_name') then
        Result := Result + ScriptName
      else if SameText(VarName, 'fastcgi_path_info') or
              SameText(VarName, 'path_info') then
        Result := Result + FastCgiPathInfo
      else if SameText(VarName, 'request_filename') then
        Result := Result + ScriptFileName
      else if SameText(VarName, 'nginx_version') then
        Result := Result + ROMITTER_VERSION
      else if StartsText('http_', VarName) then
      begin
        HeaderKey := LowerCase(StringReplace(
          Copy(VarName, Length('http_') + 1, MaxInt),
          '_',
          '-',
          [rfReplaceAll]));
        Result := Result + HeaderValue(Headers, HeaderKey);
      end;

      I := J;
    end;
  end;

  procedure AddParam(const Name, Value: string);
  begin
    if Trim(Name) = '' then
      Exit;
    Params.AddOrSetValue(Name, Value);
  end;
begin
  Result := False;
  CloseAfterResponse := True;
  TargetHost := '';
  TargetPort := 9000;
  UpstreamSocket := INVALID_SOCKET;
  Config := nil;
  Upstream := nil;
  Peer := nil;
  Params := nil;
  HeaderLines := nil;
  ResponseHeaderLines := nil;

  Config := ActiveConfig;
  if Config <> nil then
    Upstream := Config.FindHttpUpstream(Location.FastCgiPass);
  if Upstream <> nil then
  begin
    Peer := Upstream.AcquirePeer(GetClientIpHash(ClientSocket));
    if Peer = nil then
      Exit(False);
    TargetHost := Peer.Host;
    TargetPort := Peer.Port;
  end
  else
  begin
    if not ParseHostPort(Location.FastCgiPass, TargetHost, TargetPort, 9000) then
      Exit(False);
    if (TargetHost = '') or (TargetPort = 0) then
      Exit(False);
  end;

  UpstreamSocket := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if UpstreamSocket = INVALID_SOCKET then
    Exit(False);

  try
    ZeroMemory(@Addr, SizeOf(Addr));
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(TargetPort);
    if not ResolveIpv4Address(TargetHost, AddressValue) then
      Exit(False);
    Addr.sin_addr.S_addr := AddressValue;

    if not ConnectWithTimeout(
      UpstreamSocket,
      Addr,
      Location.ProxyConnectTimeoutMs,
      ConnectTimedOut) then
    begin
      LastError := WSAGetLastError;
      if ConnectTimedOut or IsSocketTimeoutError(LastError) then
        FLogger.Log(rlWarn, Format(
          'fastcgi connect timeout to %s:%d',
          [TargetHost, TargetPort]))
      else
        FLogger.Log(rlWarn, Format(
          'fastcgi connect failed to %s:%d err=%d',
          [TargetHost, TargetPort, LastError]));
      Exit(False);
    end;

    ApplySocketTimeouts(
      UpstreamSocket,
      Location.ProxySendTimeoutMs,
      Location.ProxyReadTimeoutMs);

    UriPath := Uri;
    QueryString := '';
    QueryPos := Pos('?', UriPath);
    if QueryPos > 0 then
    begin
      QueryString := Copy(UriPath, QueryPos + 1, MaxInt);
      UriPath := Copy(UriPath, 1, QueryPos - 1);
    end;
    if UriPath = '' then
      UriPath := '/';

    ScriptName := UriPath;
    FastCgiPathInfo := '';
    if Location.FastCgiSplitPathInfoPattern <> '' then
    begin
      try
        SplitPathMatch := TRegEx.Match(UriPath, Location.FastCgiSplitPathInfoPattern);
        if SplitPathMatch.Success and (SplitPathMatch.Groups.Count >= 3) then
        begin
          if SplitPathMatch.Groups[1].Success and
             (SplitPathMatch.Groups[1].Value <> '') then
            ScriptName := SplitPathMatch.Groups[1].Value
          else
            ScriptName := UriPath;
          if SplitPathMatch.Groups[2].Success then
            FastCgiPathInfo := SplitPathMatch.Groups[2].Value;
        end;
      except
        on E: Exception do
          FLogger.Log(rlWarn, Format(
            'fastcgi_split_path_info regex "%s" failed for "%s": %s',
            [Location.FastCgiSplitPathInfoPattern, UriPath, E.Message]));
      end;
    end;
    if ScriptName = '' then
      ScriptName := '/';
    if ScriptName[1] <> '/' then
      ScriptName := '/' + ScriptName;
    if (FastCgiPathInfo <> '') and (FastCgiPathInfo[1] <> '/') then
      FastCgiPathInfo := '/' + FastCgiPathInfo;
    if EndsText('/', ScriptName) then
    begin
      FastCgiIndexName := Location.FastCgiIndex;
      if FastCgiIndexName = '' then
        FastCgiIndexName := 'index.php';
      if StartsStr('/', FastCgiIndexName) then
        Delete(FastCgiIndexName, 1, 1);
      ScriptName := ScriptName + FastCgiIndexName;
    end;

    if Location.Root <> '' then
      DocumentRoot := Location.Root
    else if Location.AliasPath <> '' then
      DocumentRoot := Location.AliasPath
    else
      DocumentRoot := Server.Root;

    ScriptFileName := BuildFilesystemPath(DocumentRoot, ScriptName);
    if ScriptFileName = '' then
      ScriptFileName := TPath.Combine(
        DocumentRoot,
        StringReplace(
          Copy(ScriptName, 2, MaxInt),
          '/',
          PathDelim,
          [rfReplaceAll]));

    RequestHostRawValue := HostHeaderRaw;
    if RequestHostRawValue = '' then
      RequestHostRawValue := HeaderValue(Headers, 'host');
    RequestHost := TrimHostName(RequestHostRawValue);
    if RequestHost = '' then
      RequestHost := HostHeader;
    if RequestHost = '' then
      RequestHost := 'localhost';
    if RequestHostRawValue = '' then
      RequestHostRawValue := RequestHost;

    RemoteAddr := GetClientIpAddress(ClientSocket);
    RemotePortText := ResolveRemotePortText;

    if LocalPort = 443 then
    begin
      Scheme := 'https';
      HttpsValue := 'on';
    end
    else
    begin
      Scheme := 'http';
      HttpsValue := '';
    end;

    ContentTypeValue := HeaderValue(Headers, 'content-type');
    if Length(Body) > 0 then
      ContentLengthValue := Length(Body).ToString
    else
      ContentLengthValue := HeaderValue(Headers, 'content-length');

    Params := TDictionary<string, string>.Create;
    AddParam('GATEWAY_INTERFACE', 'CGI/1.1');
    AddParam('SERVER_SOFTWARE', ROMITTER_NAME + '/' + ROMITTER_VERSION);
    AddParam('REQUEST_METHOD', Method);
    AddParam('REQUEST_URI', Uri);
    AddParam('DOCUMENT_URI', UriPath);
    AddParam('QUERY_STRING', QueryString);
    AddParam('SERVER_PROTOCOL', Version);
    AddParam('REMOTE_ADDR', RemoteAddr);
    AddParam('REMOTE_PORT', RemotePortText);
    AddParam('SERVER_ADDR', LocalAddress);
    AddParam('SERVER_PORT', LocalPort.ToString);
    AddParam('SERVER_NAME', RequestHost);
    AddParam('REQUEST_SCHEME', Scheme);
    AddParam('SCHEME', Scheme);
    AddParam('HTTPS', HttpsValue);
    AddParam('DOCUMENT_ROOT', DocumentRoot);
    AddParam('SCRIPT_NAME', ScriptName);
    AddParam('SCRIPT_FILENAME', ScriptFileName);
    AddParam('CONTENT_TYPE', ContentTypeValue);
    AddParam('CONTENT_LENGTH', ContentLengthValue);

    for Pair in Headers do
    begin
      if SameText(Pair.Key, 'content-type') or SameText(Pair.Key, 'content-length') then
        Continue;
      AddParam(
        'HTTP_' + UpperCase(StringReplace(Pair.Key, '-', '_', [rfReplaceAll])),
        Pair.Value);
    end;

    for Pair in Location.FastCgiParams do
    begin
      FastCgiParamTemplate := Pair.Value;
      FastCgiParamIfNotEmpty := False;
      if StartsText('@@if_not_empty@@', FastCgiParamTemplate) then
      begin
        FastCgiParamIfNotEmpty := True;
        Delete(FastCgiParamTemplate, 1, Length('@@if_not_empty@@'));
      end;

      FastCgiParamExpanded := ExpandFastCgiValue(FastCgiParamTemplate);
      if FastCgiParamIfNotEmpty and (FastCgiParamExpanded = '') then
      begin
        Params.Remove(Pair.Key);
        Continue;
      end;
      AddParam(Pair.Key, FastCgiParamExpanded);
    end;

    FillChar(BeginBody, SizeOf(BeginBody), 0);
    BeginBody[0] := 0;
    BeginBody[1] := FCGI_RESPONDER;
    if not SendFastCgiRecord(FCGI_BEGIN_REQUEST, @BeginBody[0], SizeOf(BeginBody)) then
      Exit(False);

    ParamsData := nil;
    for Pair in Params do
      AppendFastCgiNameValue(ParamsData, Pair.Key, Pair.Value);

    Offset := 0;
    while Offset < Length(ParamsData) do
    begin
      ToSend := Min(65535, Length(ParamsData) - Offset);
      if not SendFastCgiRecord(FCGI_PARAMS, @ParamsData[Offset], ToSend) then
        Exit(False);
      Inc(Offset, ToSend);
    end;
    if not SendFastCgiRecord(FCGI_PARAMS, nil, 0) then
      Exit(False);

    Offset := 0;
    while Offset < Length(Body) do
    begin
      ToSend := Min(65535, Length(Body) - Offset);
      if not SendFastCgiRecord(FCGI_STDIN, @Body[Offset], ToSend) then
        Exit(False);
      Inc(Offset, ToSend);
    end;
    if not SendFastCgiRecord(FCGI_STDIN, nil, 0) then
      Exit(False);

    PendingData := nil;
    StdoutData := nil;
    StderrData := nil;
    EndRequestSeen := False;
    while not EndRequestSeen do
    begin
      ReadLen := recv(UpstreamSocket, RecvBuffer[0], SizeOf(RecvBuffer), 0);
      if ReadLen = 0 then
        Break;
      if ReadLen < 0 then
        Exit(False);
      AppendBytes(PendingData, @RecvBuffer[0], ReadLen);

      while Length(PendingData) >= 8 do
      begin
        RecType := PendingData[1];
        RecContentLen := (Integer(PendingData[4]) shl 8) or Integer(PendingData[5]);
        RecPaddingLen := Integer(PendingData[6]);
        RecTotalLen := 8 + RecContentLen + RecPaddingLen;
        if Length(PendingData) < RecTotalLen then
          Break;

        case RecType of
          FCGI_STDOUT:
            begin
              if RecContentLen > 0 then
              begin
                if (Length(StdoutData) + RecContentLen) > MAX_UPSTREAM_RESPONSE_SIZE then
                  Exit(False);
                AppendBytes(StdoutData, @PendingData[8], RecContentLen);
              end;
            end;
          FCGI_STDERR:
            begin
              if RecContentLen > 0 then
              begin
                if (Length(StderrData) + RecContentLen) <= MAX_HEADER_SIZE then
                  AppendBytes(StderrData, @PendingData[8], RecContentLen);
              end;
            end;
          FCGI_END_REQUEST:
            EndRequestSeen := True;
        end;

        ConsumePending(RecTotalLen);
      end;
    end;

    if Length(StderrData) > 0 then
    begin
      TempBytes := StderrData;
      if Length(TempBytes) > 1024 then
        SetLength(TempBytes, 1024);
      StderrText := Trim(TEncoding.UTF8.GetString(TempBytes));
      if StderrText <> '' then
        FLogger.Log(rlWarn, 'fastcgi stderr: ' + StderrText);
    end;

    if Length(StdoutData) = 0 then
      Exit(False);

    HeaderEndPos := FindByteSequence(StdoutData, TEncoding.ASCII.GetBytes(#13#10#13#10));
    HeaderDelimiterLen := 4;
    if HeaderEndPos < 0 then
    begin
      HeaderEndPos := FindByteSequence(StdoutData, TEncoding.ASCII.GetBytes(#10#10));
      HeaderDelimiterLen := 2;
    end;
    if HeaderEndPos < 0 then
      Exit(False);

    HeaderText := TEncoding.ASCII.GetString(StdoutData, 0, HeaderEndPos);
    HeaderText := StringReplace(HeaderText, #13#10, #10, [rfReplaceAll]);
    HeaderLines := TStringList.Create;
    HeaderLines.Text := StringReplace(HeaderText, #10, sLineBreak, [rfReplaceAll]);

    StatusCode := 200;
    StatusReason := '';
    ResponseContentType := 'text/html; charset=utf-8';
    ResponseHeaderLines := TList<string>.Create;
    BackendConnectionClose := False;
    HasLocationHeader := False;

    for Line in HeaderLines do
    begin
      HeaderLineText := Trim(Line);
      if HeaderLineText = '' then
        Continue;

      ColonPos := Pos(':', HeaderLineText);
      if ColonPos < 2 then
        Continue;

      HeaderNameOriginal := Trim(Copy(HeaderLineText, 1, ColonPos - 1));
      HeaderName := LowerCase(HeaderNameOriginal);
      HeaderValueText := Trim(Copy(HeaderLineText, ColonPos + 1, MaxInt));

      if HeaderName = 'status' then
      begin
        StatusValue := HeaderValueText;
        StatusSpacePos := Pos(' ', StatusValue);
        if StatusSpacePos > 0 then
        begin
          if TryStrToInt(Trim(Copy(StatusValue, 1, StatusSpacePos - 1)), StatusCode) then
            StatusReason := Trim(Copy(StatusValue, StatusSpacePos + 1, MaxInt));
        end
        else
          TryStrToInt(StatusValue, StatusCode);
        Continue;
      end;

      if HeaderName = 'content-type' then
      begin
        ResponseContentType := HeaderValueText;
        Continue;
      end;

      if HeaderName = 'connection' then
      begin
        if ContainsText(HeaderValueText, 'close') then
          BackendConnectionClose := True;
        Continue;
      end;

      if (HeaderName = 'content-length') or
         (HeaderName = 'transfer-encoding') then
        Continue;

      if HeaderName = 'location' then
        HasLocationHeader := True;

      ResponseHeaderLines.Add(HeaderNameOriginal + ': ' + HeaderValueText);
    end;

    BodyOffset := HeaderEndPos + HeaderDelimiterLen;
    if BodyOffset < Length(StdoutData) then
    begin
      SetLength(ResponseBody, Length(StdoutData) - BodyOffset);
      Move(StdoutData[BodyOffset], ResponseBody[0], Length(ResponseBody));
    end
    else
      ResponseBody := nil;

    if (StatusCode = 200) and (StatusReason = '') and HasLocationHeader then
      StatusCode := 302;

    if StatusReason = '' then
      StatusReason := ReasonPhrase(StatusCode);
    CloseAfterResponse := CloseConnection or BackendConnectionClose;
    ShouldSendBody := not SameText(Method, 'HEAD');
    ExtraHeaderLines := ResponseHeaderLines.ToArray;

    if not SendResponseHeaders(
      ClientSocket,
      StatusCode,
      StatusReason,
      ResponseContentType,
      Length(ResponseBody),
      CloseAfterResponse,
      Server,
      Location,
      Headers,
      Uri,
      nil,
      ExtraHeaderLines) then
      Exit(False);

    if ShouldSendBody and (Length(ResponseBody) > 0) then
      if not SendBuffer(ClientSocket, @ResponseBody[0], Length(ResponseBody)) then
        Exit(False);

    Result := True;
  finally
    ResponseHeaderLines.Free;
    HeaderLines.Free;
    Params.Free;
    if (Upstream <> nil) and (Peer <> nil) then
      Upstream.ReleasePeer(Peer, Result);
    if UpstreamSocket <> INVALID_SOCKET then
    begin
      shutdown(UpstreamSocket, SD_BOTH);
      closesocket(UpstreamSocket);
    end;
  end;
end;

class function TRomitterHttpServer.ResolveClientMaxBodySize(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig): Int64;
begin
  Result := 1024 * 1024;
  if Config <> nil then
    Result := Config.Http.ClientMaxBodySize;
  if (Server <> nil) and (Server.ClientMaxBodySize >= 0) then
    Result := Server.ClientMaxBodySize;
  if (Location <> nil) and (Location.ClientMaxBodySize >= 0) then
    Result := Location.ClientMaxBodySize;
  if Result < 0 then
    Result := 1024 * 1024;
end;

class function TRomitterHttpServer.ResolveDefaultType(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig): string;
begin
  Result := 'application/octet-stream';
  if (Config <> nil) and (Trim(Config.Http.DefaultType) <> '') then
    Result := Trim(Config.Http.DefaultType);
  if (Server <> nil) and (Trim(Server.DefaultType) <> '') then
    Result := Trim(Server.DefaultType);
  if (Location <> nil) and (Trim(Location.DefaultType) <> '') then
    Result := Trim(Location.DefaultType);
end;

class function TRomitterHttpServer.ResolveClientHeaderTimeoutMs(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig): Integer;
begin
  Result := 60000;
  if Config <> nil then
    Result := Config.Http.ClientHeaderTimeoutMs;
  if (Server <> nil) and (Server.ClientHeaderTimeoutMs >= 0) then
    Result := Server.ClientHeaderTimeoutMs;
  if (Location <> nil) and (Location.ClientHeaderTimeoutMs >= 0) then
    Result := Location.ClientHeaderTimeoutMs;
  if Result < 0 then
    Result := 60000;
end;

class function TRomitterHttpServer.ResolveClientBodyTimeoutMs(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig): Integer;
begin
  Result := 60000;
  if Config <> nil then
    Result := Config.Http.ClientBodyTimeoutMs;
  if (Server <> nil) and (Server.ClientBodyTimeoutMs >= 0) then
    Result := Server.ClientBodyTimeoutMs;
  if (Location <> nil) and (Location.ClientBodyTimeoutMs >= 0) then
    Result := Location.ClientBodyTimeoutMs;
  if Result < 0 then
    Result := 60000;
end;

class function TRomitterHttpServer.ResolveKeepAliveTimeoutMs(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig): Integer;
begin
  Result := CLIENT_KEEPALIVE_TIMEOUT_MS;
  if Config <> nil then
    Result := Config.Http.KeepAliveTimeoutMs;
  if (Server <> nil) and (Server.KeepAliveTimeoutMs >= 0) then
    Result := Server.KeepAliveTimeoutMs;
  if Result <= 0 then
    Result := CLIENT_KEEPALIVE_TIMEOUT_MS;
end;

class function TRomitterHttpServer.ResolveSendTimeoutMs(
  const Config: TRomitterConfig; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig): Integer;
begin
  Result := 60000;
  if Config <> nil then
    Result := Config.Http.SendTimeoutMs;
  if (Server <> nil) and (Server.SendTimeoutMs >= 0) then
    Result := Server.SendTimeoutMs;
  if (Location <> nil) and (Location.SendTimeoutMs >= 0) then
    Result := Location.SendTimeoutMs;
  if Result < 0 then
    Result := 60000;
end;

function TRomitterHttpServer.ProxyRequestSingle(const ClientSocket: TSocket;
  const Host: string; const Port: Word; const Method, ForwardUri: string;
  const Headers: TDictionary<string, string>;
  const ClientHeaders: TDictionary<string, string>;
  const Location: TRomitterLocationConfig;
  const Body: TBytes;
  const BodyDeferred: Boolean; const BodyKind: TRomitterRequestBodyKind;
  const BodyContentLength: Integer; const NeedClientContinue: Boolean;
  const ClientMaxBodySize: Int64; const ClientBodyTimeoutMs: Integer;
  var PendingRaw: TBytes;
  const ProxyHttpVersion: TRomitterProxyHttpVersion;
  const UpstreamTls: Boolean;
  const UpstreamTlsServerName: string;
  const UpstreamTlsVerify: Boolean;
  const StreamResponseToClient: Boolean;
  const ConnectTimeoutMs, SendTimeoutMs, ReadTimeoutMs: Integer;
  out ResponseData: TBytes; out StatusCode: Integer;
  out AttemptKind: TRomitterProxyAttemptKind;
  out ResponseRelayed: Boolean;
  out CloseAfterResponse: Boolean): Boolean;
var
  UpstreamSocket: TSocket;
  Addr: TSockAddrIn;
  AddressValue: u_long;
  RequestBuilder: TStringBuilder;
  Pair: TPair<string, string>;
  RequestText: string;
  RequestBytes: TBytes;
  Buffer: array[0..8191] of Byte;
  ReadLen: Integer;
  ConnectTimedOut: Boolean;
  LastError: Integer;
  RequestHttpVersion: string;
  Remaining: Int64;
  ToSend: Integer;
  CrLfPos: Integer;
  LineText: string;
  SizeText: string;
  ChunkSize: Int64;
  LineRawLen: Integer;
  SizeExtPos: Integer;
  ResponseHeaderBuffer: TBytes;
  ResponseHeaderParsed: Boolean;
  ResponseHeaderEndPos: Integer;
  HeaderDelimiter: TBytes;
  TotalBodyForwarded: Int64;
  BodyLimitEnabled: Boolean;
  BodyLimitBytes: Int64;
  EffectiveClientReadTimeoutMs: Integer;
  UpstreamTlsContext: TRomitterSslContext;
  UpstreamTlsSession: TRomitterSsl;
  UpstreamTlsError: string;
  function MarkSendError: Boolean;
  begin
    LastError := WSAGetLastError;
    if IsSocketTimeoutError(LastError) then
      AttemptKind := pakTimeout
    else
      AttemptKind := pakError;
    Result := False;
  end;

  function MarkRecvError(const AReadLen: Integer): Boolean;
  begin
    if AReadLen < 0 then
      LastError := WSAGetLastError
    else
      LastError := 0;
    if (AReadLen < 0) and IsSocketTimeoutError(LastError) then
      AttemptKind := pakTimeout
    else
      AttemptKind := pakError;
    Result := False;
  end;

  function UpstreamWrite(const BufferPtr: Pointer; const BufferLen: Integer): Integer;
  begin
    if UpstreamTlsSession <> nil then
      Exit(OpenSslWrite(UpstreamTlsSession, BufferPtr, BufferLen));
    Result := send(UpstreamSocket, BufferPtr^, BufferLen, 0);
  end;

  function UpstreamRead(var BufferRef; const BufferLen: Integer): Integer;
  begin
    if UpstreamTlsSession <> nil then
      Exit(OpenSslRead(UpstreamTlsSession, @BufferRef, BufferLen));
    Result := recv(UpstreamSocket, BufferRef, BufferLen, 0);
  end;

  function UpstreamSendBuffer(const Data: Pointer; const DataLen: Integer): Boolean;
  var
    Sent: Integer;
    Offset: Integer;
  begin
    Offset := 0;
    while Offset < DataLen do
    begin
      Sent := UpstreamWrite(@PByte(Data)[Offset], DataLen - Offset);
      if Sent = SOCKET_ERROR then
        Exit(False);
      if Sent = 0 then
        Exit(False);
      Inc(Offset, Sent);
    end;
    Result := True;
  end;

  function TrackForwardedBody(const ChunkLen: Int64): Boolean;
  begin
    if ChunkLen <= 0 then
      Exit(True);
    if not BodyLimitEnabled then
      Exit(True);
    if (BodyLimitBytes - TotalBodyForwarded) < ChunkLen then
    begin
      StatusCode := 413;
      AttemptKind := pakError;
      Exit(False);
    end;
    Inc(TotalBodyForwarded, ChunkLen);
    Result := True;
  end;

  procedure ConsumePending(const Count: Integer);
  var
    NewLen: Integer;
  begin
    if Count <= 0 then
      Exit;
    if Count >= Length(PendingRaw) then
    begin
      PendingRaw := nil;
      Exit;
    end;
    NewLen := Length(PendingRaw) - Count;
    Move(PendingRaw[Count], PendingRaw[0], NewLen);
    SetLength(PendingRaw, NewLen);
  end;

  function ReceiveMoreClientData: Boolean;
  begin
    ReadLen := ReadFromSocketCompat(ClientSocket, @Buffer[0], SizeOf(Buffer));
    if ReadLen <= 0 then
      Exit(MarkRecvError(ReadLen));
    AppendBytes(PendingRaw, @Buffer[0], ReadLen);
    Result := True;
  end;

  function StreamContentLengthBody: Boolean;
  begin
    Remaining := BodyContentLength;
    while Remaining > 0 do
    begin
      if Length(PendingRaw) = 0 then
        if not ReceiveMoreClientData then
          Exit(False);

      if Remaining > High(Integer) then
        ToSend := Length(PendingRaw)
      else
        ToSend := Min(Integer(Remaining), Length(PendingRaw));
      if ToSend <= 0 then
        Exit(False);

      if not TrackForwardedBody(ToSend) then
        Exit(False);

      if not UpstreamSendBuffer(@PendingRaw[0], ToSend) then
        Exit(MarkSendError);
      ConsumePending(ToSend);
      Dec(Remaining, ToSend);
    end;
    Result := True;
  end;

  function FindPendingCrlf: Integer;
  var
    I: Integer;
  begin
    Result := -1;
    for I := 0 to Length(PendingRaw) - 2 do
      if (PendingRaw[I] = Ord(#13)) and (PendingRaw[I + 1] = Ord(#10)) then
        Exit(I);
  end;

  function StreamChunkedBody: Boolean;
  begin
    while True do
    begin
      CrLfPos := FindPendingCrlf;
      while CrLfPos < 0 do
      begin
        if Length(PendingRaw) > MAX_HEADER_SIZE then
        begin
          AttemptKind := pakInvalidHeader;
          Exit(False);
        end;
        if not ReceiveMoreClientData then
          Exit(False);
        CrLfPos := FindPendingCrlf;
      end;

      LineText := TEncoding.ASCII.GetString(PendingRaw, 0, CrLfPos);
      LineRawLen := CrLfPos + 2;

      SizeText := Trim(LineText);
      SizeExtPos := Pos(';', SizeText);
      if SizeExtPos > 0 then
        SizeText := Trim(Copy(SizeText, 1, SizeExtPos - 1));
      if (SizeText = '') or (not TryStrToInt64('$' + SizeText, ChunkSize)) or
         (ChunkSize < 0) then
      begin
        AttemptKind := pakInvalidHeader;
        Exit(False);
      end;

      if (ChunkSize > 0) and (not TrackForwardedBody(ChunkSize)) then
        Exit(False);

      if not UpstreamSendBuffer(@PendingRaw[0], LineRawLen) then
        Exit(MarkSendError);
      ConsumePending(LineRawLen);

      if ChunkSize = 0 then
      begin
        repeat
          CrLfPos := FindPendingCrlf;
          while CrLfPos < 0 do
          begin
            if Length(PendingRaw) > MAX_HEADER_SIZE then
            begin
              AttemptKind := pakInvalidHeader;
              Exit(False);
            end;
            if not ReceiveMoreClientData then
              Exit(False);
            CrLfPos := FindPendingCrlf;
          end;

          LineText := TEncoding.ASCII.GetString(PendingRaw, 0, CrLfPos);
          LineRawLen := CrLfPos + 2;
          if not UpstreamSendBuffer(@PendingRaw[0], LineRawLen) then
            Exit(MarkSendError);
          ConsumePending(LineRawLen);
        until LineText = '';
        Exit(True);
      end;

      Remaining := ChunkSize;
      while Remaining > 0 do
      begin
        if Length(PendingRaw) = 0 then
          if not ReceiveMoreClientData then
            Exit(False);

        if Remaining > High(Integer) then
          ToSend := Length(PendingRaw)
        else
          ToSend := Min(Integer(Remaining), Length(PendingRaw));
        if ToSend <= 0 then
          Exit(False);

        if not UpstreamSendBuffer(@PendingRaw[0], ToSend) then
          Exit(MarkSendError);
        ConsumePending(ToSend);
        Dec(Remaining, ToSend);
      end;

      while Length(PendingRaw) < 2 do
        if not ReceiveMoreClientData then
          Exit(False);

      if (PendingRaw[0] <> Ord(#13)) or (PendingRaw[1] <> Ord(#10)) then
      begin
        AttemptKind := pakInvalidHeader;
        Exit(False);
      end;
      if not UpstreamSendBuffer(@PendingRaw[0], 2) then
        Exit(MarkSendError);
      ConsumePending(2);
    end;
  end;
begin
  StatusCode := 0;
  AttemptKind := pakError;
  ResponseData := nil;
  ResponseRelayed := False;
  CloseAfterResponse := True;
  ResponseHeaderBuffer := nil;
  ResponseHeaderParsed := False;
  ResponseHeaderEndPos := -1;
  HeaderDelimiter := TEncoding.ASCII.GetBytes(#13#10#13#10);
  TotalBodyForwarded := 0;
  BodyLimitBytes := ClientMaxBodySize;
  BodyLimitEnabled := ClientMaxBodySize > 0;
  EffectiveClientReadTimeoutMs := ClientBodyTimeoutMs;
  UpstreamTlsContext := nil;
  UpstreamTlsSession := nil;
  UpstreamTlsError := '';
  if EffectiveClientReadTimeoutMs < 0 then
    EffectiveClientReadTimeoutMs := 60000;

  if BodyDeferred then
    setsockopt(
      ClientSocket,
      SOL_SOCKET,
      SO_RCVTIMEO,
      PAnsiChar(@EffectiveClientReadTimeoutMs),
      SizeOf(EffectiveClientReadTimeoutMs));

  if BodyLimitEnabled and (BodyKind = rbkContentLength) and
     (Int64(BodyContentLength) > BodyLimitBytes) then
  begin
    StatusCode := 413;
    Exit(False);
  end;
  if BodyLimitEnabled and (not BodyDeferred) and
     (Int64(Length(Body)) > BodyLimitBytes) then
  begin
    StatusCode := 413;
    Exit(False);
  end;

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

    if not ConnectWithTimeout(UpstreamSocket, Addr, ConnectTimeoutMs, ConnectTimedOut) then
    begin
      if ConnectTimedOut then
        AttemptKind := pakTimeout
      else
        AttemptKind := pakError;
      Exit(False);
    end;

    ApplySocketTimeouts(UpstreamSocket, SendTimeoutMs, ReadTimeoutMs);
    if UpstreamTls then
    begin
      if not OpenSslCreateClientContext('', nil, UpstreamTlsContext, UpstreamTlsError) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS context init failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;

      if not OpenSslCreateSession(
        UpstreamTlsContext,
        UpstreamSocket,
        UpstreamTlsSession,
        UpstreamTlsError) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS session init failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;

      if (UpstreamTlsServerName <> '') and
         (not OpenSslSetSessionServerName(
           UpstreamTlsSession,
           UpstreamTlsServerName,
           UpstreamTlsError)) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS SNI setup failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;

      if not OpenSslSetSessionVerify(
        UpstreamTlsSession,
        UpstreamTlsVerify,
        UpstreamTlsServerName,
        UpstreamTlsError) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS verify setup failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;

      if not OpenSslConnectSession(UpstreamTlsSession, UpstreamTlsError) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS handshake failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;

      if UpstreamTlsVerify and
         (not OpenSslVerifySessionResult(UpstreamTlsSession, UpstreamTlsError)) then
      begin
        FLogger.Log(rlWarn, Format(
          'upstream TLS peer verification failed for %s:%d: %s',
          [Host, Port, UpstreamTlsError]));
        AttemptKind := pakError;
        Exit(False);
      end;
    end;

    RequestBuilder := TStringBuilder.Create;
    try
      if ProxyHttpVersion = phv10 then
        RequestHttpVersion := 'HTTP/1.0'
      else
        RequestHttpVersion := 'HTTP/1.1';

      RequestBuilder.Append(Method + ' ' + ForwardUri + ' ' + RequestHttpVersion + #13#10);
      for Pair in Headers do
      begin
        if SameText(Pair.Key, 'proxy-connection') then
          Continue;
        if SameText(Pair.Key, 'content-length') then
          Continue;
        if SameText(Pair.Key, 'transfer-encoding') then
          Continue;
        if Pair.Value = '' then
          Continue;
        RequestBuilder.Append(Pair.Key + ': ' + Pair.Value + #13#10);
      end;

      if BodyDeferred then
      begin
        case BodyKind of
          rbkContentLength:
            RequestBuilder.Append('Content-Length: ' + BodyContentLength.ToString + #13#10);
          rbkChunked:
            RequestBuilder.Append('Transfer-Encoding: chunked' + #13#10);
        end;
      end
      else if Length(Body) > 0 then
        RequestBuilder.Append('Content-Length: ' + Length(Body).ToString + #13#10);
      RequestBuilder.Append(#13#10);

      RequestText := RequestBuilder.ToString;
      RequestBytes := TEncoding.ASCII.GetBytes(RequestText);
      if not UpstreamSendBuffer(@RequestBytes[0], Length(RequestBytes)) then
      begin
        LastError := WSAGetLastError;
        if IsSocketTimeoutError(LastError) then
          AttemptKind := pakTimeout
        else
          AttemptKind := pakError;
        Exit(False);
      end;
      if BodyDeferred then
      begin
        if NeedClientContinue then
        begin
          RequestBytes := TEncoding.ASCII.GetBytes('HTTP/1.1 100 Continue'#13#10#13#10);
          if not SendBuffer(ClientSocket, @RequestBytes[0], Length(RequestBytes)) then
          begin
            LastError := WSAGetLastError;
            if IsSocketTimeoutError(LastError) then
              AttemptKind := pakTimeout
            else
              AttemptKind := pakError;
            Exit(False);
          end;
        end;

        case BodyKind of
          rbkContentLength:
            if not StreamContentLengthBody then
              Exit(False);
          rbkChunked:
            if not StreamChunkedBody then
              Exit(False);
        end;
      end
      else if Length(Body) > 0 then
      begin
        if not TrackForwardedBody(Length(Body)) then
          Exit(False);
        if not UpstreamSendBuffer(@Body[0], Length(Body)) then
          Exit(MarkSendError);
      end;
    finally
      RequestBuilder.Free;
    end;

    while True do
    begin
      ReadLen := UpstreamRead(Buffer[0], SizeOf(Buffer));
      if ReadLen = 0 then
        Break;
      if ReadLen < 0 then
      begin
        LastError := WSAGetLastError;
        if StreamResponseToClient and ResponseRelayed then
        begin
          // Response was already started; avoid appending synthetic 502 to a partial stream.
          CloseAfterResponse := True;
          AttemptKind := pakOk;
          Result := True;
          Exit;
        end;
        if IsSocketTimeoutError(LastError) then
          AttemptKind := pakTimeout
        else
          AttemptKind := pakError;
        Exit(False);
      end;

      if StreamResponseToClient then
      begin
        if not ResponseHeaderParsed then
        begin
          AppendBytes(ResponseHeaderBuffer, @Buffer[0], ReadLen);
          if Length(ResponseHeaderBuffer) > MAX_HEADER_SIZE then
          begin
            AttemptKind := pakInvalidHeader;
            Exit(False);
          end;

          ResponseHeaderEndPos := FindByteSequence(ResponseHeaderBuffer, HeaderDelimiter);
          if ResponseHeaderEndPos >= 0 then
          begin
            if LocationHasStreamingHeaderFilters(Location) then
              ResponseHeaderBuffer := ApplyBufferedProxyResponseFilters(
                ClientSocket,
                ClientHeaders,
                Location,
                Host,
                Port,
                ForwardUri,
                Method,
                ResponseHeaderBuffer);
            if not ParseHttpStatusCode(ResponseHeaderBuffer, StatusCode) then
            begin
              AttemptKind := pakInvalidHeader;
              Exit(False);
            end;
            CloseAfterResponse := ShouldCloseAfterProxyResponse(Method, ResponseHeaderBuffer);
            if not SendBuffer(ClientSocket, @ResponseHeaderBuffer[0], Length(ResponseHeaderBuffer)) then
              Exit(MarkSendError);
            ResponseRelayed := True;
            ResponseHeaderParsed := True;
            ResponseHeaderBuffer := nil;
          end;
        end
        else if not SendBuffer(ClientSocket, @Buffer[0], ReadLen) then
          Exit(MarkSendError);
        Continue;
      end;

      if Length(ResponseData) + ReadLen > MAX_UPSTREAM_RESPONSE_SIZE then
      begin
        AttemptKind := pakError;
        Exit(False);
      end;
      AppendBytes(ResponseData, @Buffer[0], ReadLen);
    end;

    if StreamResponseToClient then
    begin
      if not ResponseHeaderParsed then
      begin
        AttemptKind := pakInvalidHeader;
        Exit(False);
      end;
      AttemptKind := pakOk;
      Result := True;
      Exit;
    end;

    if Length(ResponseData) = 0 then
    begin
      AttemptKind := pakInvalidHeader;
      Exit(False);
    end;

    if not ParseHttpStatusCode(ResponseData, StatusCode) then
    begin
      AttemptKind := pakInvalidHeader;
      Exit(False);
    end;

    AttemptKind := pakOk;
    Result := True;
  finally
    OpenSslFreeSession(UpstreamTlsSession);
    OpenSslFreeContext(UpstreamTlsContext);
    shutdown(UpstreamSocket, SD_BOTH);
    closesocket(UpstreamSocket);
  end;
end;

function TRomitterHttpServer.ProxyRequest(const ClientSocket: TSocket;
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const Method, Uri: string;
  const Headers: TDictionary<string, string>; const Body: TBytes;
  const BodyDeferred: Boolean; const BodyKind: TRomitterRequestBodyKind;
  const BodyContentLength: Integer; const NeedClientContinue: Boolean;
  var PendingRaw: TBytes; out CloseConnection: Boolean;
  const IsHttpsRequest: Boolean; const RequestLocalPort: Word): Boolean;
var
  Upstream: TRomitterUpstreamConfig;
  Peer: TRomitterUpstreamPeer;
  Host: string;
  BasePath: string;
  ForwardUri: string;
  ProxyHasUriPart: Boolean;
  IsHttpsUpstream: Boolean;
  Port: Word;
  Attempts: Integer;
  MaxAttempts: Integer;
  ResponseData: TBytes;
  ResponseStatus: Integer;
  AttemptKind: TRomitterProxyAttemptKind;
  Succeeded: Boolean;
  ShouldRetry: Boolean;
  ResponseRelayed: Boolean;
  ResponseCloseConnection: Boolean;
  StreamProxyResponse: Boolean;
  ClientHash: Cardinal;
  ForwardHeaders: TDictionary<string, string>;
  TriedPeers: TDictionary<TRomitterUpstreamPeer, Boolean>;
  Config: TRomitterConfig;
  ClientMaxBodySize: Int64;
  ClientBodyTimeoutMs: Integer;
  RetryDeadlineTick: UInt64;
  FiltersRequireBuffering: Boolean;

  function ResolveUpstreamTlsServerName(const TargetHost: string;
    const TargetPort: Word): string;
  var
    RequestHost: string;
    RequestHostRaw: string;
    ProxyHost: string;
    RemoteAddr: string;
  begin
    Result := '';
    if not IsHttpsUpstream then
      Exit('');

    RequestHostRaw := HeaderValue(Headers, 'host');
    RequestHost := TrimHostName(RequestHostRaw);
    if RequestHost = '' then
      RequestHost := TargetHost;

    if (TargetPort = 443) then
      ProxyHost := TargetHost
    else
      ProxyHost := TargetHost + ':' + TargetPort.ToString;

    RemoteAddr := GetClientIpAddress(ClientSocket);
    if Trim(Location.ProxySslName) <> '' then
      Result := ExpandProxyHeaderValue(
        Location.ProxySslName,
        Headers,
        RequestHost,
        RequestHostRaw,
        ProxyHost,
        RemoteAddr,
        Uri,
        IsHttpsRequest,
        RequestLocalPort)
    else if Location.ProxySslServerName then
      Result := TargetHost;

    Result := TrimHostName(Trim(Result));
  end;
begin
  Result := False;
  CloseConnection := True;
  Upstream := nil;
  Host := '';
  BasePath := '/';
  ProxyHasUriPart := False;
  IsHttpsUpstream := False;
  Port := 80;
  TriedPeers := nil;
  StreamProxyResponse := not Location.ProxyBuffering;
  FiltersRequireBuffering := LocationHasBufferedResponseFilters(Location);
  if StreamProxyResponse and FiltersRequireBuffering then
  begin
    StreamProxyResponse := False;
    FLogger.Log(rlDebug, Format(
      'proxy_buffering=off overridden due to response filters for "%s"',
      [Location.ProxyPass]));
  end;
  Config := ActiveConfig;
  ClientMaxBodySize := ResolveClientMaxBodySize(Config, Server, Location);
  ClientBodyTimeoutMs := ResolveClientBodyTimeoutMs(Config, Server, Location);

  if not ParseProxyPassTarget(
    Location.ProxyPass,
    Upstream,
    Host,
    Port,
    BasePath,
    ProxyHasUriPart,
    IsHttpsUpstream) then
    Exit(False);

  ForwardUri := BuildProxyForwardUri(Uri, Location, BasePath, ProxyHasUriPart);

  if Upstream = nil then
  begin
    ForwardHeaders := BuildProxyHeaders(
      ClientSocket,
      Headers,
      Location,
      Host,
      Port,
      Uri,
      False,
      IsHttpsUpstream,
      IsHttpsRequest,
      RequestLocalPort);
    try
      if not ProxyRequestSingle(
        ClientSocket,
        Host,
        Port,
        Method,
        ForwardUri,
        ForwardHeaders,
        Headers,
        Location,
        Body,
        BodyDeferred,
        BodyKind,
        BodyContentLength,
        NeedClientContinue,
        ClientMaxBodySize,
        ClientBodyTimeoutMs,
        PendingRaw,
        Location.ProxyHttpVersion,
        IsHttpsUpstream,
        ResolveUpstreamTlsServerName(Host, Port),
        Location.ProxySslVerify,
        StreamProxyResponse,
        Location.ProxyConnectTimeoutMs,
        Location.ProxySendTimeoutMs,
        Location.ProxyReadTimeoutMs,
        ResponseData,
        ResponseStatus,
        AttemptKind,
        ResponseRelayed,
        ResponseCloseConnection) then
      begin
        if ResponseStatus = 413 then
        begin
          SendStatus(ClientSocket, 413, 'Payload Too Large', True, Server, Location, Headers, Uri, nil);
          CloseConnection := True;
          Exit(True);
        end;
        Exit(False);
      end;
    finally
      ForwardHeaders.Free;
    end;
    if ResponseRelayed then
    begin
      CloseConnection := ResponseCloseConnection;
      Exit(True);
    end;
    if Length(ResponseData) = 0 then
      Exit(False);
    ResponseData := ApplyBufferedProxyResponseFilters(
      ClientSocket,
      Headers,
      Location,
      Host,
      Port,
      Uri,
      Method,
      ResponseData);
    CloseConnection := ShouldCloseAfterProxyResponse(Method, ResponseData);
    Exit(SendBuffer(ClientSocket, @ResponseData[0], Length(ResponseData)));
  end;

  if BodyDeferred or StreamProxyResponse then
  begin
    MaxAttempts := 1;
    if BodyDeferred and ((Location.ProxyNextUpstreamTries > 1) or (Upstream.Peers.Count > 1)) then
      FLogger.Log(rlWarn, Format(
        'proxy_request_buffering=off forces single upstream attempt for "%s"',
        [Location.ProxyPass]));
    if StreamProxyResponse and ((Location.ProxyNextUpstreamTries > 1) or (Upstream.Peers.Count > 1)) then
      FLogger.Log(rlWarn, Format(
        'proxy_buffering=off forces single upstream attempt for "%s"',
        [Location.ProxyPass]));
  end
  else if Location.ProxyNextUpstreamTries > 0 then
    MaxAttempts := Location.ProxyNextUpstreamTries
  else if Location.ProxyNextUpstreamTimeoutMs > 0 then
    MaxAttempts := High(Integer)
  else
    MaxAttempts := Upstream.Peers.Count;
  if MaxAttempts < 1 then
    MaxAttempts := 1;
  ClientHash := GetClientIpHash(ClientSocket);
  if (not BodyDeferred) and (not StreamProxyResponse) and
     (Location.ProxyNextUpstreamTimeoutMs > 0) then
    RetryDeadlineTick := GetTickCount64 + UInt64(Location.ProxyNextUpstreamTimeoutMs)
  else
    RetryDeadlineTick := 0;

  TriedPeers := TDictionary<TRomitterUpstreamPeer, Boolean>.Create;
  try
    for Attempts := 1 to MaxAttempts do
    begin
      if (Attempts > 1) and (RetryDeadlineTick <> 0) and
         (GetTickCount64 >= RetryDeadlineTick) then
        Break;

      // nginx-compatible retry behavior: avoid reusing the same peer
      // within one upstream request sequence.
      Peer := Upstream.AcquirePeer(
        ClientHash + Cardinal(Attempts - 1),
        TriedPeers);
      if not Assigned(Peer) then
        Exit(False);
      TriedPeers.AddOrSetValue(Peer, True);

      ForwardHeaders := BuildProxyHeaders(
        ClientSocket,
        Headers,
        Location,
        Peer.Host,
        Peer.Port,
        Uri,
        False,
        IsHttpsUpstream,
        IsHttpsRequest,
        RequestLocalPort);
      try
        Succeeded := ProxyRequestSingle(
          ClientSocket,
          Peer.Host,
          Peer.Port,
          Method,
          ForwardUri,
          ForwardHeaders,
          Headers,
          Location,
          Body,
          BodyDeferred,
          BodyKind,
          BodyContentLength,
          NeedClientContinue,
          ClientMaxBodySize,
          ClientBodyTimeoutMs,
          PendingRaw,
          Location.ProxyHttpVersion,
          IsHttpsUpstream,
          ResolveUpstreamTlsServerName(Peer.Host, Peer.Port),
          Location.ProxySslVerify,
          StreamProxyResponse,
          Location.ProxyConnectTimeoutMs,
          Location.ProxySendTimeoutMs,
          Location.ProxyReadTimeoutMs,
          ResponseData,
          ResponseStatus,
          AttemptKind,
          ResponseRelayed,
          ResponseCloseConnection);
      finally
        ForwardHeaders.Free;
      end;

      if Succeeded then
      begin
        if BodyDeferred or StreamProxyResponse then
          ShouldRetry := False
        else
          ShouldRetry := IsRetriableStatus(ResponseStatus, Location.ProxyNextUpstream);
        if ShouldRetry and (RetryDeadlineTick <> 0) and (GetTickCount64 >= RetryDeadlineTick) then
          ShouldRetry := False;
        Upstream.ReleasePeer(Peer, not ShouldRetry);
        if (not ShouldRetry) or (Attempts = MaxAttempts) then
        begin
          if ResponseStatus >= 400 then
            FLogger.Log(rlWarn, Format(
              'upstream response status=%d for uri "%s" forwarded as "%s" via %s:%d',
              [ResponseStatus, Uri, ForwardUri, Peer.Host, Peer.Port]));
          if ResponseRelayed then
          begin
            CloseConnection := ResponseCloseConnection;
            Exit(True);
          end;
          if Length(ResponseData) = 0 then
            Exit(False);
          ResponseData := ApplyBufferedProxyResponseFilters(
            ClientSocket,
            Headers,
            Location,
            Peer.Host,
            Peer.Port,
            Uri,
            Method,
            ResponseData);
          CloseConnection := ShouldCloseAfterProxyResponse(Method, ResponseData);
          Exit(SendBuffer(ClientSocket, @ResponseData[0], Length(ResponseData)));
        end;

        FLogger.Log(rlWarn, Format(
          'upstream response retry %d/%d for "%s" -> %s:%d status=%d',
          [Attempts, MaxAttempts, Upstream.Name, Peer.Host, Peer.Port, ResponseStatus]));
        Continue;
      end;

      if ResponseStatus = 413 then
      begin
        Upstream.ReleasePeer(Peer, False);
        SendStatus(ClientSocket, 413, 'Payload Too Large', True, Server, Location, Headers, Uri, nil);
        CloseConnection := True;
        Exit(True);
      end;

      ShouldRetry := IsRetriableAttempt(AttemptKind, Location.ProxyNextUpstream);
      if BodyDeferred or StreamProxyResponse then
        ShouldRetry := False;
      if ShouldRetry and (RetryDeadlineTick <> 0) and (GetTickCount64 >= RetryDeadlineTick) then
        ShouldRetry := False;
      Upstream.ReleasePeer(Peer, False);

      if (not ShouldRetry) or (Attempts = MaxAttempts) then
        Exit(False);

      FLogger.Log(rlWarn, Format(
        'upstream transport retry %d/%d for "%s" -> %s:%d kind=%d',
        [Attempts, MaxAttempts, Upstream.Name, Peer.Host, Peer.Port, Ord(AttemptKind)]));
    end;
  finally
    TriedPeers.Free;
  end;
end;

function TRomitterHttpServer.SelectServer(const HostHeader: string;
  const LocalPort: Word; const LocalAddress: string): TRomitterServerConfig;
var
  Config: TRomitterConfig;
  Server: TRomitterServerConfig;
  ServerName: string;
  Candidate: TRomitterServerConfig;
  DefaultCandidate: TRomitterServerConfig;
  BestWildcardPrefixServer: TRomitterServerConfig;
  BestWildcardPrefixLen: Integer;
  BestWildcardSuffixServer: TRomitterServerConfig;
  BestWildcardSuffixLen: Integer;
  MatchLen: Integer;
  NormalizedHost: string;
  HasEndpointScope: Boolean;

  function ServerHasListenPort(const AServer: TRomitterServerConfig;
    const APort: Word): Boolean;
  var
    L: TRomitterHttpListenConfig;
  begin
    if APort = 0 then
      Exit(True);
    for L in AServer.Listens do
      if L.Port = APort then
        Exit(True);
    Result := False;
  end;

  function ServerHasDefaultOnPort(const AServer: TRomitterServerConfig;
    const APort: Word): Boolean;
  var
    L: TRomitterHttpListenConfig;
  begin
    if APort = 0 then
      Exit(False);
    for L in AServer.Listens do
      if (L.Port = APort) and L.IsDefaultServer then
        Exit(True);
    Result := False;
  end;

  function ListenMatchesAddress(const ListenHost: string;
    const ListenPort: Word; const AAddress: string; const APort: Word): Boolean;
  begin
    if (APort <> 0) and (ListenPort <> APort) then
      Exit(False);
    if AAddress = '' then
      Exit(True);
    if SameText(ListenHost, '0.0.0.0') or SameText(ListenHost, '*') then
      Exit(True);
    Result := SameText(ListenHost, AAddress);
  end;

  function ServerMatchesEndpoint(const AServer: TRomitterServerConfig;
    const APort: Word; const AAddress: string): Boolean;
  var
    L: TRomitterHttpListenConfig;
  begin
    if APort = 0 then
      Exit(True);
    for L in AServer.Listens do
      if ListenMatchesAddress(L.Host, L.Port, AAddress, APort) then
        Exit(True);
    Result := False;
  end;

  function ServerHasDefaultOnEndpoint(const AServer: TRomitterServerConfig;
    const APort: Word; const AAddress: string): Boolean;
  var
    L: TRomitterHttpListenConfig;
  begin
    if APort = 0 then
      Exit(False);
    for L in AServer.Listens do
      if L.IsDefaultServer and ListenMatchesAddress(L.Host, L.Port, AAddress, APort) then
        Exit(True);
    Result := False;
  end;

  function NormalizeHostForServerName(const RawHost: string): string;
  var
    HostValue: string;
    CloseBracketPos: Integer;
    ColonPos: Integer;
  begin
    HostValue := Trim(RawHost);
    if HostValue = '' then
      Exit('');

    if HostValue[1] = '[' then
    begin
      CloseBracketPos := Pos(']', HostValue);
      if CloseBracketPos > 1 then
        HostValue := Copy(HostValue, 2, CloseBracketPos - 2);
    end
    else
    begin
      ColonPos := Pos(':', HostValue);
      if ColonPos > 0 then
        HostValue := Copy(HostValue, 1, ColonPos - 1);
    end;

    while (HostValue <> '') and (HostValue[Length(HostValue)] = '.') do
      Delete(HostValue, Length(HostValue), 1);

    Result := LowerCase(HostValue);
  end;

  function ServerInScope(const AServer: TRomitterServerConfig): Boolean;
  begin
    if HasEndpointScope then
      Exit(ServerMatchesEndpoint(AServer, LocalPort, LocalAddress));

    if LocalPort <> 0 then
      Exit(ServerHasListenPort(AServer, LocalPort));

    Result := True;
  end;

  function TryMatchExactServerName(const Pattern, Host: string): Boolean;
  begin
    if Pattern = '' then
      Exit(False);
    if Pattern[1] = '~' then
      Exit(False);
    if Pattern[1] = '.' then
      Exit(False);
    if Pos('*', Pattern) > 0 then
      Exit(False);
    Result := SameText(Pattern, Host);
  end;

  function TryMatchWildcardPrefixServerName(const Pattern, Host: string;
    out WildcardLen: Integer): Boolean;
  var
    Suffix: string;
    RootName: string;
  begin
    WildcardLen := 0;
    if Pattern = '' then
      Exit(False);
    if Pattern[1] = '~' then
      Exit(False);

    if StartsText('*.', Pattern) then
    begin
      Suffix := Copy(Pattern, 2, MaxInt); // ".example.com"
      if (Length(Host) > Length(Suffix)) and EndsText(Suffix, Host) then
      begin
        WildcardLen := Length(Suffix);
        Exit(True);
      end;
      Exit(False);
    end;

    if Pattern[1] = '.' then
    begin
      RootName := Copy(Pattern, 2, MaxInt);
      if SameText(Host, RootName) then
      begin
        WildcardLen := Length(Pattern);
        Exit(True);
      end;
      if (Length(Host) > Length(Pattern)) and EndsText(Pattern, Host) then
      begin
        WildcardLen := Length(Pattern);
        Exit(True);
      end;
      Exit(False);
    end;

    Result := False;
  end;

  function TryMatchWildcardSuffixServerName(const Pattern, Host: string;
    out WildcardLen: Integer): Boolean;
  var
    Prefix: string;
  begin
    WildcardLen := 0;
    if Pattern = '' then
      Exit(False);
    if Pattern[1] = '~' then
      Exit(False);
    if not EndsText('.*', Pattern) then
      Exit(False);

    Prefix := Copy(Pattern, 1, Length(Pattern) - 1); // "mail."
    if (Length(Host) > Length(Prefix)) and StartsText(Prefix, Host) then
    begin
      WildcardLen := Length(Prefix);
      Exit(True);
    end;
    Result := False;
  end;

  function TryMatchRegexServerName(const Pattern, Host: string): Boolean;
  var
    RegexPattern: string;
    RegexOptions: TRegExOptions;
  begin
    Result := False;
    if StartsText('~*', Pattern) then
    begin
      RegexPattern := Trim(Copy(Pattern, 3, MaxInt));
      RegexOptions := [roIgnoreCase];
    end
    else if StartsText('~', Pattern) then
    begin
      RegexPattern := Trim(Copy(Pattern, 2, MaxInt));
      RegexOptions := [];
    end
    else
      Exit(False);

    if RegexPattern = '' then
      Exit(False);

    try
      Result := TRegEx.IsMatch(Host, RegexPattern, RegexOptions);
    except
      on E: Exception do
        FLogger.Log(rlWarn, Format('server_name regex "%s" failed: %s',
          [Pattern, E.Message]));
    end;
  end;
begin
  Config := ActiveConfig;
  if (Config = nil) or (Config.Http.Servers.Count = 0) then
    Exit(nil);

  NormalizedHost := NormalizeHostForServerName(HostHeader);

  Candidate := nil;
  DefaultCandidate := nil;
  HasEndpointScope := False;
  for Server in Config.Http.Servers do
  begin
    if not ServerMatchesEndpoint(Server, LocalPort, LocalAddress) then
      Continue;
    HasEndpointScope := True;
    if Candidate = nil then
      Candidate := Server;
    if (DefaultCandidate = nil) and
       ServerHasDefaultOnEndpoint(Server, LocalPort, LocalAddress) then
      DefaultCandidate := Server;
  end;

  if not HasEndpointScope then
  begin
    for Server in Config.Http.Servers do
    begin
      if (LocalPort <> 0) and (not ServerHasListenPort(Server, LocalPort)) then
        Continue;
      if Candidate = nil then
        Candidate := Server;
      if (DefaultCandidate = nil) and (LocalPort <> 0) and
         ServerHasDefaultOnPort(Server, LocalPort) then
        DefaultCandidate := Server;
    end;
  end;

  if Candidate = nil then
    Candidate := Config.Http.Servers[0];

  if NormalizedHost <> '' then
  begin
    // 1. exact names
    for Server in Config.Http.Servers do
    begin
      if not ServerInScope(Server) then
        Continue;
      for ServerName in Server.ServerNames do
        if TryMatchExactServerName(ServerName, NormalizedHost) then
          Exit(Server);
    end;

    // 2. longest wildcard name starting with "*." (and ".example.com")
    BestWildcardPrefixServer := nil;
    BestWildcardPrefixLen := -1;
    for Server in Config.Http.Servers do
    begin
      if not ServerInScope(Server) then
        Continue;
      for ServerName in Server.ServerNames do
      begin
        if not TryMatchWildcardPrefixServerName(ServerName, NormalizedHost, MatchLen) then
          Continue;
        if MatchLen > BestWildcardPrefixLen then
        begin
          BestWildcardPrefixLen := MatchLen;
          BestWildcardPrefixServer := Server;
        end;
      end;
    end;
    if BestWildcardPrefixServer <> nil then
      Exit(BestWildcardPrefixServer);

    // 3. longest wildcard name ending with ".*"
    BestWildcardSuffixServer := nil;
    BestWildcardSuffixLen := -1;
    for Server in Config.Http.Servers do
    begin
      if not ServerInScope(Server) then
        Continue;
      for ServerName in Server.ServerNames do
      begin
        if not TryMatchWildcardSuffixServerName(ServerName, NormalizedHost, MatchLen) then
          Continue;
        if MatchLen > BestWildcardSuffixLen then
        begin
          BestWildcardSuffixLen := MatchLen;
          BestWildcardSuffixServer := Server;
        end;
      end;
    end;
    if BestWildcardSuffixServer <> nil then
      Exit(BestWildcardSuffixServer);

    // 4. first regex in config order
    for Server in Config.Http.Servers do
    begin
      if not ServerInScope(Server) then
        Continue;
      for ServerName in Server.ServerNames do
        if TryMatchRegexServerName(ServerName, NormalizedHost) then
          Exit(Server);
    end;
  end;

  if DefaultCandidate <> nil then
    Exit(DefaultCandidate);

  Result := Candidate;
end;

function TRomitterHttpServer.SelectLocation(const Server: TRomitterServerConfig;
  const UriPath: string): TRomitterLocationConfig;
var
  Location: TRomitterLocationConfig;
  BestPrefix: TRomitterLocationConfig;
  BestLen: Integer;
  RegexOptions: TRegExOptions;
begin
  Result := nil;

  // 1) exact location match
  for Location in Server.Locations do
  begin
    if (Location.MatchKind = lmkExact) and (Location.MatchPath = UriPath) then
      Exit(Location);
  end;

  // 2) longest prefix match (including ^~ prefixes)
  BestPrefix := nil;
  BestLen := -1;
  for Location in Server.Locations do
  begin
    if (Location.MatchKind <> lmkPrefix) and
       (Location.MatchKind <> lmkPrefixNoRegex) then
      Continue;
    if (Location.MatchPath = '/') or StartsStr(Location.MatchPath, UriPath) then
    begin
      if Length(Location.MatchPath) > BestLen then
      begin
        BestLen := Length(Location.MatchPath);
        BestPrefix := Location;
      end;
    end;
  end;

  // ^~ selected prefix blocks regex phase.
  if Assigned(BestPrefix) and (BestPrefix.MatchKind = lmkPrefixNoRegex) then
    Exit(BestPrefix);

  // 3) regex locations in declaration order
  for Location in Server.Locations do
  begin
    if (Location.MatchKind <> lmkRegexCaseSensitive) and
       (Location.MatchKind <> lmkRegexCaseInsensitive) then
      Continue;

    if Location.MatchKind = lmkRegexCaseInsensitive then
      RegexOptions := [roIgnoreCase]
    else
      RegexOptions := [];
    try
      if TRegEx.IsMatch(UriPath, Location.MatchPath, RegexOptions) then
        Exit(Location);
    except
      on E: Exception do
        FLogger.Log(rlWarn, Format(
          'location regex "%s" failed: %s',
          [Location.MatchPath, E.Message]));
    end;
  end;

  // 4) fallback to longest plain prefix
  Result := BestPrefix;
end;

function TRomitterHttpServer.FindNamedLocation(
  const Server: TRomitterServerConfig; const Name: string): TRomitterLocationConfig;
var
  Location: TRomitterLocationConfig;
  LookupName: string;
begin
  LookupName := Trim(Name);
  if LookupName = '' then
    Exit(nil);
  if LookupName[1] <> '@' then
    LookupName := '@' + LookupName;

  for Location in Server.Locations do
    if (Location.MatchKind = lmkNamed) and SameText(Location.MatchPath, LookupName) then
      Exit(Location);

  Result := nil;
end;

function TRomitterHttpServer.BuildFilesystemPath(const Root,
  UriPath: string): string;
var
  RelativePath: string;
  FullRoot: string;
  FullPath: string;
  PrefixPath: string;
begin
  RelativePath := UrlDecode(UriPath);
  if RelativePath = '' then
    RelativePath := '/';

  if RelativePath.StartsWith('/') then
    Delete(RelativePath, 1, 1);

  RelativePath := StringReplace(RelativePath, '/', PathDelim, [rfReplaceAll]);

  FullRoot := TPath.GetFullPath(Root);
  if RelativePath = '' then
    FullPath := FullRoot
  else
    FullPath := TPath.GetFullPath(TPath.Combine(FullRoot, RelativePath));
  PrefixPath := EnsureTrailingPathDelimiter(FullRoot);

  if (not SameText(Copy(FullPath, 1, Length(PrefixPath)), PrefixPath)) and
     (not SameText(FullPath, FullRoot)) then
    Exit('');

  Result := FullPath;
end;

function TRomitterHttpServer.SendResponseHeaders(const ClientSocket: TSocket;
  const StatusCode: Integer; const Reason, ContentType: string;
  const ContentLength: Int64; const CloseConnection: Boolean;
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const ClientHeaders: TDictionary<string, string>; const RequestUri: string;
  const ExtraHeaders: TDictionary<string, string>;
  const ExtraHeaderLines: TArray<string>): Boolean;
var
  HeaderText: string;
  HeaderBytes: TBytes;
  ConnectionValue: string;
  EffectiveAddHeaders: TObjectList<TRomitterAddHeaderConfig>;
  AddHeaderItem: TRomitterAddHeaderConfig;
  Pair: TPair<string, string>;
  HeaderValueText: string;
  RequestHostRaw: string;
  RequestHost: string;
  ProxyHost: string;
  RemoteAddr: string;
  SafeClientHeaders: TDictionary<string, string>;
  TempClientHeaders: TDictionary<string, string>;
  ExtraHeaderLine: string;
begin
  if CloseConnection then
    ConnectionValue := 'close'
  else
    ConnectionValue := 'keep-alive';

  HeaderText :=
    'HTTP/1.1 ' + StatusCode.ToString + ' ' + Reason + #13#10 +
    'Server: ' + BuildServerHeaderValue(Server) + #13#10 +
    'Connection: ' + ConnectionValue + #13#10 +
    'Content-Type: ' + ContentType + #13#10 +
    'Content-Length: ' + ContentLength.ToString + #13#10;

  if ExtraHeaders <> nil then
    for Pair in ExtraHeaders do
      if Trim(Pair.Value) <> '' then
        HeaderText := HeaderText + Pair.Key + ': ' + Pair.Value + #13#10;

  if Length(ExtraHeaderLines) > 0 then
    for ExtraHeaderLine in ExtraHeaderLines do
      if Trim(ExtraHeaderLine) <> '' then
        HeaderText := HeaderText + ExtraHeaderLine + #13#10;

  if Location <> nil then
    EffectiveAddHeaders := Location.AddHeaders
  else if Server <> nil then
    EffectiveAddHeaders := Server.AddHeaders
  else
    EffectiveAddHeaders := nil;

  if (EffectiveAddHeaders <> nil) and (EffectiveAddHeaders.Count > 0) then
  begin
    SafeClientHeaders := ClientHeaders;
    TempClientHeaders := nil;
    if SafeClientHeaders = nil then
    begin
      TempClientHeaders := TDictionary<string, string>.Create;
      SafeClientHeaders := TempClientHeaders;
    end;
    try
      RequestHostRaw := HeaderValue(SafeClientHeaders, 'host');
      RequestHost := TrimHostName(RequestHostRaw);
      if RequestHostRaw = '' then
        RequestHostRaw := RequestHost;
      ProxyHost := RequestHost;
      RemoteAddr := GetClientIpAddress(ClientSocket);

      for AddHeaderItem in EffectiveAddHeaders do
      begin
        if not ShouldAddConfiguredHeader(StatusCode, AddHeaderItem.Always) then
          Continue;
        HeaderValueText := ExpandProxyHeaderValue(
          AddHeaderItem.Value,
          SafeClientHeaders,
          RequestHost,
          RequestHostRaw,
          ProxyHost,
          RemoteAddr,
          RequestUri);
        if HeaderValueText = '' then
          Continue;
        HeaderText := HeaderText + AddHeaderItem.Name + ': ' + HeaderValueText + #13#10;
      end;
    finally
      TempClientHeaders.Free;
    end;
  end;

  HeaderText := HeaderText + #13#10;
  HeaderBytes := TEncoding.ASCII.GetBytes(HeaderText);
  Result := (Length(HeaderBytes) = 0) or
    SendBuffer(ClientSocket, @HeaderBytes[0], Length(HeaderBytes));
end;

function TRomitterHttpServer.SendFileResponse(const ClientSocket: TSocket;
  const StatusCode: Integer; const Reason, ContentType, FilePath: string;
  const SendBody: Boolean; const CloseConnection: Boolean;
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const ClientHeaders: TDictionary<string, string>;
  const RequestUri: string): Boolean;
var
  FileStream: TFileStream;
  Buffer: array[0..65535] of Byte;
  ReadLen: Integer;
begin
  Result := False;
  FileStream := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    if not SendResponseHeaders(
      ClientSocket,
      StatusCode,
      Reason,
      ContentType,
      FileStream.Size,
      CloseConnection,
      Server,
      Location,
      ClientHeaders,
      RequestUri,
      nil) then
      Exit(False);

    if not SendBody then
      Exit(True);

    while True do
    begin
      ReadLen := FileStream.Read(Buffer[0], SizeOf(Buffer));
      if ReadLen = 0 then
        Break;
      if not SendBuffer(ClientSocket, @Buffer[0], ReadLen) then
        Exit(False);
    end;
    Result := True;
  finally
    FileStream.Free;
  end;
end;

procedure TRomitterHttpServer.SendSimpleResponse(const ClientSocket: TSocket;
  const StatusCode: Integer; const Reason, ContentType: string;
  const Body: TBytes; const CloseConnection: Boolean;
  const Server: TRomitterServerConfig; const Location: TRomitterLocationConfig;
  const ClientHeaders: TDictionary<string, string>; const RequestUri: string;
  const ExtraHeaders: TDictionary<string, string>);
var
  BodyLength: Integer;
begin
  BodyLength := Length(Body);
  if not SendResponseHeaders(
    ClientSocket,
    StatusCode,
    Reason,
    ContentType,
    BodyLength,
    CloseConnection,
    Server,
    Location,
    ClientHeaders,
    RequestUri,
    ExtraHeaders) then
    Exit;

  if BodyLength > 0 then
    SendBuffer(ClientSocket, @Body[0], BodyLength);
end;

procedure TRomitterHttpServer.SendStatus(const ClientSocket: TSocket;
  const StatusCode: Integer; const BodyText: string;
  const CloseConnection: Boolean; const Server: TRomitterServerConfig;
  const Location: TRomitterLocationConfig;
  const ClientHeaders: TDictionary<string, string>; const RequestUri: string;
  const ExtraHeaders: TDictionary<string, string>);
var
  EffectiveStatus: Integer;
  ErrorPage: TRomitterErrorPageConfig;
  ErrorUri: string;
  ErrorUriPath: string;
  ErrorLocation: TRomitterLocationConfig;
  RelativeAliasPath: string;
  RootPath: string;
  FilePath: string;
  DirectoryPath: string;
  CandidateName: string;
  CandidatePath: string;
  RootForAbsoluteIndex: string;
  IndexList: TArray<string>;
  QueryPos: Integer;
  RedirectStatus: Integer;
  RedirectHeaders: TDictionary<string, string>;
  Pair: TPair<string, string>;
  Config: TRomitterConfig;
  ContentType: string;
  BodyBytes: TBytes;
  RequestHostRaw: string;
  RequestHost: string;
  ProxyHost: string;
  RemoteAddr: string;
  ExpandedValue: string;
  SafeClientHeaders: TDictionary<string, string>;
  TempClientHeaders: TDictionary<string, string>;
  function FindErrorPageInList(
    const ErrorPages: TObjectList<TRomitterErrorPageConfig>;
    const Code: Integer): TRomitterErrorPageConfig;
  var
    Item: TRomitterErrorPageConfig;
    Idx: Integer;
    J: Integer;
  begin
    Result := nil;
    if ErrorPages = nil then
      Exit;
    for Idx := ErrorPages.Count - 1 downto 0 do
    begin
      Item := ErrorPages[Idx];
      for J := 0 to High(Item.StatusCodes) do
        if Item.StatusCodes[J] = Code then
          Exit(Item);
    end;
  end;
begin
  if StatusCode = 444 then
  begin
    if GHttp2CaptureEnabled and (GHttp2CaptureSocket = ClientSocket) then
    begin
      GHttp2CaptureCloseConnection := True;
      Exit;
    end;
    shutdown(ClientSocket, SD_BOTH);
    Exit;
  end;

  EffectiveStatus := StatusCode;
  ErrorPage := nil;
  if Server <> nil then
  begin
    if Location <> nil then
      ErrorPage := FindErrorPageInList(Location.ErrorPages, StatusCode);
    if ErrorPage = nil then
      ErrorPage := FindErrorPageInList(Server.ErrorPages, StatusCode);
  end;

  if ErrorPage <> nil then
  begin
    if ErrorPage.OverrideStatus > 0 then
      EffectiveStatus := ErrorPage.OverrideStatus;

    ErrorUri := Trim(ErrorPage.Uri);
    if (ErrorUri <> '') and (ErrorUri[1] = '@') then
    begin
      ErrorLocation := FindNamedLocation(Server, ErrorUri);
      if Assigned(ErrorLocation) and (ErrorLocation.ReturnCode > 0) then
      begin
        if ErrorLocation.ReturnCode = 444 then
        begin
          if GHttp2CaptureEnabled and (GHttp2CaptureSocket = ClientSocket) then
          begin
            GHttp2CaptureCloseConnection := True;
            Exit;
          end;
          shutdown(ClientSocket, SD_BOTH);
          Exit;
        end;

        SafeClientHeaders := ClientHeaders;
        TempClientHeaders := nil;
        if SafeClientHeaders = nil then
        begin
          TempClientHeaders := TDictionary<string, string>.Create;
          SafeClientHeaders := TempClientHeaders;
        end;
        try
          RequestHostRaw := HeaderValue(SafeClientHeaders, 'host');
          RequestHost := TrimHostName(RequestHostRaw);
          if RequestHostRaw = '' then
            RequestHostRaw := RequestHost;
          ProxyHost := RequestHost;
          RemoteAddr := GetClientIpAddress(ClientSocket);
          ExpandedValue := ExpandProxyHeaderValue(
            ErrorLocation.ReturnBody,
            SafeClientHeaders,
            RequestHost,
            RequestHostRaw,
            ProxyHost,
            RemoteAddr,
            RequestUri);
        finally
          TempClientHeaders.Free;
        end;

        if (ErrorLocation.ReturnCode >= 300) and
           (ErrorLocation.ReturnCode < 400) and
           (ExpandedValue <> '') then
        begin
          RedirectHeaders := TDictionary<string, string>.Create;
          try
            if ExtraHeaders <> nil then
              for Pair in ExtraHeaders do
                RedirectHeaders.AddOrSetValue(Pair.Key, Pair.Value);
            RedirectHeaders.AddOrSetValue('Location', ExpandedValue);
            SendResponseHeaders(
              ClientSocket,
              ErrorLocation.ReturnCode,
              ReasonPhrase(ErrorLocation.ReturnCode),
              'text/plain; charset=utf-8',
              0,
              CloseConnection,
              Server,
              ErrorLocation,
              ClientHeaders,
              RequestUri,
              RedirectHeaders);
          finally
            RedirectHeaders.Free;
          end;
          Exit;
        end;

        BodyBytes := TEncoding.UTF8.GetBytes(ExpandedValue);
        SendSimpleResponse(
          ClientSocket,
          ErrorLocation.ReturnCode,
          ReasonPhrase(ErrorLocation.ReturnCode),
          'text/plain; charset=utf-8',
          BodyBytes,
          CloseConnection,
          Server,
          ErrorLocation,
          ClientHeaders,
          RequestUri,
          ExtraHeaders);
        Exit;
      end;
    end
    else if (ErrorUri <> '') and (ErrorUri[1] = '/') then
    begin
      ErrorUriPath := ErrorUri;
      QueryPos := Pos('?', ErrorUriPath);
      if QueryPos > 0 then
        ErrorUriPath := Copy(ErrorUriPath, 1, QueryPos - 1);
      if ErrorUriPath = '' then
        ErrorUriPath := '/';

      ErrorLocation := SelectLocation(Server, ErrorUriPath);
      if Assigned(ErrorLocation) and (ErrorLocation.AliasPath <> '') then
      begin
        RelativeAliasPath := ErrorUriPath;
        if ((ErrorLocation.MatchKind = lmkPrefix) or
            (ErrorLocation.MatchKind = lmkPrefixNoRegex)) and
           StartsStr(ErrorLocation.MatchPath, ErrorUriPath) then
          RelativeAliasPath := Copy(ErrorUriPath, Length(ErrorLocation.MatchPath) + 1, MaxInt)
        else if ErrorLocation.MatchKind = lmkExact then
          RelativeAliasPath := '';
        if RelativeAliasPath = '' then
          RelativeAliasPath := '/';
        if RelativeAliasPath[1] <> '/' then
          RelativeAliasPath := '/' + RelativeAliasPath;
        RootPath := ErrorLocation.AliasPath;
        FilePath := BuildFilesystemPath(RootPath, RelativeAliasPath);
      end
      else
      begin
        if Assigned(ErrorLocation) and (ErrorLocation.Root <> '') then
          RootPath := ErrorLocation.Root
        else
          RootPath := Server.Root;
        FilePath := BuildFilesystemPath(RootPath, ErrorUriPath);
      end;

      if FilePath <> '' then
      begin
        if TDirectory.Exists(FilePath) then
        begin
          DirectoryPath := FilePath;
          if Assigned(ErrorLocation) and (Length(ErrorLocation.IndexFiles) > 0) then
            IndexList := ErrorLocation.IndexFiles
          else
            IndexList := Server.IndexFiles;

          if Assigned(ErrorLocation) and (ErrorLocation.AliasPath <> '') then
            RootForAbsoluteIndex := ErrorLocation.AliasPath
          else if Assigned(ErrorLocation) and (ErrorLocation.Root <> '') then
            RootForAbsoluteIndex := ErrorLocation.Root
          else
            RootForAbsoluteIndex := Server.Root;

          FilePath := '';
          for CandidateName in IndexList do
          begin
            if CandidateName = '' then
              Continue;
            if CandidateName[1] = '/' then
              CandidatePath := BuildFilesystemPath(RootForAbsoluteIndex, CandidateName)
            else
              CandidatePath := TPath.Combine(DirectoryPath, CandidateName);
            if (CandidatePath <> '') and TFile.Exists(CandidatePath) then
            begin
              FilePath := CandidatePath;
              Break;
            end;
          end;
        end;

        if (FilePath <> '') and TFile.Exists(FilePath) then
        begin
          ContentType := GuessContentType(FilePath);
          if ContentType = 'application/octet-stream' then
            ContentType := ResolveDefaultType(ActiveConfig, Server, ErrorLocation);
          if SendFileResponse(
            ClientSocket,
            EffectiveStatus,
            ReasonPhrase(EffectiveStatus),
            ContentType,
            FilePath,
            True,
            CloseConnection,
            Server,
            ErrorLocation,
            ClientHeaders,
            ErrorUriPath) then
            Exit;
        end;
      end;
    end
    else if StartsText('http://', ErrorUri) or StartsText('https://', ErrorUri) then
    begin
      RedirectHeaders := TDictionary<string, string>.Create;
      try
        if ExtraHeaders <> nil then
          for Pair in ExtraHeaders do
            RedirectHeaders.AddOrSetValue(Pair.Key, Pair.Value);
        RedirectHeaders.AddOrSetValue('Location', ErrorUri);
        if ErrorPage.OverrideStatus > 0 then
          RedirectStatus := ErrorPage.OverrideStatus
        else
          RedirectStatus := 302;
        SendResponseHeaders(
          ClientSocket,
          RedirectStatus,
          ReasonPhrase(RedirectStatus),
          'text/plain; charset=utf-8',
          0,
          CloseConnection,
          Server,
          Location,
          ClientHeaders,
          RequestUri,
          RedirectHeaders);
      finally
        RedirectHeaders.Free;
      end;
      Exit;
    end;
  end;

  BodyBytes := TEncoding.UTF8.GetBytes(BodyText);
  SendSimpleResponse(
    ClientSocket,
    EffectiveStatus,
    ReasonPhrase(EffectiveStatus),
    'text/plain; charset=utf-8',
    BodyBytes,
    CloseConnection,
    Server,
    Location,
    ClientHeaders,
    RequestUri,
    ExtraHeaders);
end;

end.
