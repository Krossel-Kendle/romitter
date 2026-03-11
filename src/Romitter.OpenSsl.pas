unit Romitter.OpenSsl;

interface

uses
  System.SysUtils,
  System.StrUtils,
  Winapi.Windows,
  Winapi.Winsock2;

type
  TRomitterSslContext = Pointer;
  TRomitterSsl = Pointer;

function OpenSslEnsureInitialized(out ErrorText: string): Boolean;
function OpenSslCreateServerContext(const CertFile, KeyFile: string;
  const Ciphers: string; const Protocols: TArray<string>;
  const PreferServerCiphers: Boolean;
  const SessionCache: string; const SessionTimeoutMs: Integer;
  const SessionTickets: Boolean;
  out SslContext: TRomitterSslContext; out ErrorText: string): Boolean;
function OpenSslCreateClientContext(const Ciphers: string;
  const Protocols: TArray<string>;
  out SslContext: TRomitterSslContext; out ErrorText: string): Boolean;
function OpenSslSetServerNameCallback(const SslContext: TRomitterSslContext;
  const Callback: Pointer; const CallbackArg: Pointer;
  out ErrorText: string): Boolean;
function OpenSslCreateSession(const SslContext: TRomitterSslContext;
  const SocketHandle: TSocket; out Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
function OpenSslAcceptSession(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
function OpenSslConnectSession(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
function OpenSslSetSessionServerName(const Ssl: TRomitterSsl;
  const ServerName: string; out ErrorText: string): Boolean;
function OpenSslSetSessionVerify(const Ssl: TRomitterSsl;
  const VerifyPeer: Boolean; const HostName: string;
  out ErrorText: string): Boolean;
function OpenSslVerifySessionResult(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
function OpenSslRead(const Ssl: TRomitterSsl; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
function OpenSslWrite(const Ssl: TRomitterSsl; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
function OpenSslSwitchSessionContext(const Ssl: TRomitterSsl;
  const SslContext: TRomitterSslContext): Boolean;
function OpenSslGetSessionServerName(const Ssl: TRomitterSsl): string;
procedure OpenSslFreeSession(var Ssl: TRomitterSsl);
procedure OpenSslFreeContext(var SslContext: TRomitterSslContext);
function OpenSslDescribeLastError: string;

implementation

const
  SSL_FILETYPE_PEM = 1;
  SSL_ERROR_WANT_READ = 2;
  SSL_ERROR_WANT_WRITE = 3;
  SSL_ERROR_SYSCALL = 5;
  SSL_ERROR_ZERO_RETURN = 6;

  SSL_OP_NO_TLSv1 = UInt64($04000000);
  SSL_OP_NO_TLSv1_1 = UInt64($10000000);
  SSL_OP_NO_TLSv1_2 = UInt64($08000000);
  SSL_OP_NO_TLSv1_3 = UInt64($20000000);
  SSL_OP_CIPHER_SERVER_PREFERENCE = UInt64($00400000);
  SSL_OP_NO_TICKET = UInt64($00004000);

  SSL_SESS_CACHE_OFF = 0;
  SSL_SESS_CACHE_SERVER = 2;

  SSL_CTRL_SET_TLSEXT_SERVERNAME_CB = 53;
  SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG = 54;
  SSL_CTRL_SET_TLSEXT_HOSTNAME = 55;
  SSL_CTRL_GET_TLSEXT_HOSTNAME = 56;
  TLSEXT_NAMETYPE_host_name = 0;

  SSL_VERIFY_NONE = 0;
  SSL_VERIFY_PEER = 1;
  X509_V_OK = 0;

type
  TOPENSSL_init_ssl = function(const opts: UInt64; const settings: Pointer): Integer; cdecl;
  TSSL_library_init = function: Integer; cdecl;
  TSSL_load_error_strings = procedure; cdecl;
  TOPENSSL_add_ssl_algorithms = procedure; cdecl;
  TTLS_server_method = function: Pointer; cdecl;
  TTLS_client_method = function: Pointer; cdecl;
  TSSLv23_client_method = function: Pointer; cdecl;
  TSSL_CTX_new = function(const meth: Pointer): Pointer; cdecl;
  TSSL_CTX_free = procedure(const ctx: Pointer); cdecl;
  TSSL_CTX_use_certificate_chain_file = function(const ctx: Pointer;
    const filename: PAnsiChar): Integer; cdecl;
  TSSL_CTX_use_PrivateKey_file = function(const ctx: Pointer;
    const filename: PAnsiChar; const AType: Integer): Integer; cdecl;
  TSSL_CTX_check_private_key = function(const ctx: Pointer): Integer; cdecl;
  TSSL_CTX_set_cipher_list = function(const ctx: Pointer;
    const CipherList: PAnsiChar): Integer; cdecl;
  TSSL_CTX_set_ciphersuites = function(const ctx: Pointer;
    const CipherList: PAnsiChar): Integer; cdecl;
  TSSL_CTX_set_options = function(const ctx: Pointer;
    const options: UInt64): UInt64; cdecl;
  TSSL_CTX_set_timeout = function(const ctx: Pointer;
    const TimeoutSeconds: Cardinal): Cardinal; cdecl;
  TSSL_CTX_set_session_cache_mode = function(const ctx: Pointer;
    const mode: NativeInt): NativeInt; cdecl;
  TSSL_CTX_ctrl = function(const ctx: Pointer; const cmd: Integer;
    const larg: NativeInt; const parg: Pointer): NativeInt; cdecl;
  TSSL_CTX_callback_ctrl = function(const ctx: Pointer; const cmd: Integer;
    const Callback: Pointer): NativeInt; cdecl;
  TSSL_new = function(const ctx: Pointer): Pointer; cdecl;
  TSSL_free = procedure(const ssl: Pointer); cdecl;
  TSSL_set_fd = function(const ssl: Pointer; const fd: Integer): Integer; cdecl;
  TSSL_accept = function(const ssl: Pointer): Integer; cdecl;
  TSSL_connect = function(const ssl: Pointer): Integer; cdecl;
  TSSL_set_verify = procedure(const ssl: Pointer; const mode: Integer;
    const callback: Pointer); cdecl;
  TSSL_get_verify_result = function(const ssl: Pointer): NativeInt; cdecl;
  TSSL_set1_host = function(const ssl: Pointer; const Name: PAnsiChar): Integer; cdecl;
  TSSL_CTX_set_default_verify_paths = function(const ctx: Pointer): Integer; cdecl;
  TSSL_read = function(const ssl: Pointer; const buf: Pointer; const num: Integer): Integer; cdecl;
  TSSL_write = function(const ssl: Pointer; const buf: Pointer; const num: Integer): Integer; cdecl;
  TSSL_shutdown = function(const ssl: Pointer): Integer; cdecl;
  TSSL_get_error = function(const ssl: Pointer; const ret_code: Integer): Integer; cdecl;
  TSSL_set_SSL_CTX = function(const ssl: Pointer; const ctx: Pointer): Pointer; cdecl;
  TSSL_get_servername = function(const ssl: Pointer;
    const name_type: Integer): PAnsiChar; cdecl;
  TSSL_ctrl = function(const ssl: Pointer; const cmd: Integer;
    const larg: NativeInt; const parg: Pointer): NativeInt; cdecl;
  TERR_get_error = function: Cardinal; cdecl;
  TERR_error_string_n = procedure(const e: Cardinal; const buf: PAnsiChar;
    const len: Cardinal); cdecl;

var
  GOpenSslInitialized: Boolean = False;
  GOpenSslFailed: Boolean = False;
  GOpenSslErrorText: string = '';
  GLibSsl: HMODULE = 0;
  GLibCrypto: HMODULE = 0;

  FOPENSSL_init_ssl: TOPENSSL_init_ssl = nil;
  FSSL_library_init: TSSL_library_init = nil;
  FSSL_load_error_strings: TSSL_load_error_strings = nil;
  FOPENSSL_add_ssl_algorithms: TOPENSSL_add_ssl_algorithms = nil;
  FTLS_server_method: TTLS_server_method = nil;
  FTLS_client_method: TTLS_client_method = nil;
  FSSLv23_client_method: TSSLv23_client_method = nil;
  FSSL_CTX_new: TSSL_CTX_new = nil;
  FSSL_CTX_free: TSSL_CTX_free = nil;
  FSSL_CTX_use_certificate_chain_file: TSSL_CTX_use_certificate_chain_file = nil;
  FSSL_CTX_use_PrivateKey_file: TSSL_CTX_use_PrivateKey_file = nil;
  FSSL_CTX_check_private_key: TSSL_CTX_check_private_key = nil;
  FSSL_CTX_set_cipher_list: TSSL_CTX_set_cipher_list = nil;
  FSSL_CTX_set_ciphersuites: TSSL_CTX_set_ciphersuites = nil;
  FSSL_CTX_set_options: TSSL_CTX_set_options = nil;
  FSSL_CTX_set_timeout: TSSL_CTX_set_timeout = nil;
  FSSL_CTX_set_session_cache_mode: TSSL_CTX_set_session_cache_mode = nil;
  FSSL_CTX_ctrl: TSSL_CTX_ctrl = nil;
  FSSL_CTX_callback_ctrl: TSSL_CTX_callback_ctrl = nil;
  FSSL_new: TSSL_new = nil;
  FSSL_free: TSSL_free = nil;
  FSSL_set_fd: TSSL_set_fd = nil;
  FSSL_accept: TSSL_accept = nil;
  FSSL_connect: TSSL_connect = nil;
  FSSL_set_verify: TSSL_set_verify = nil;
  FSSL_get_verify_result: TSSL_get_verify_result = nil;
  FSSL_set1_host: TSSL_set1_host = nil;
  FSSL_CTX_set_default_verify_paths: TSSL_CTX_set_default_verify_paths = nil;
  FSSL_read: TSSL_read = nil;
  FSSL_write: TSSL_write = nil;
  FSSL_shutdown: TSSL_shutdown = nil;
  FSSL_get_error: TSSL_get_error = nil;
  FSSL_set_SSL_CTX: TSSL_set_SSL_CTX = nil;
  FSSL_get_servername: TSSL_get_servername = nil;
  FSSL_ctrl: TSSL_ctrl = nil;
  FERR_get_error: TERR_get_error = nil;
  FERR_error_string_n: TERR_error_string_n = nil;

function LoadProc(const LibHandle: HMODULE; const Name: AnsiString): Pointer;
begin
  Result := nil;
  if LibHandle <> 0 then
    Result := GetProcAddress(LibHandle, PAnsiChar(Name));
end;

procedure FreeOpenSslLibraries;
begin
  if GLibSsl <> 0 then
  begin
    FreeLibrary(GLibSsl);
    GLibSsl := 0;
  end;
  if GLibCrypto <> 0 then
  begin
    FreeLibrary(GLibCrypto);
    GLibCrypto := 0;
  end;
end;

function AssignProcedures: Boolean;
  procedure ResolveProc(var Target; const LibHandle: HMODULE; const ProcName: AnsiString);
  var
    ProcPtr: Pointer;
  begin
    ProcPtr := LoadProc(LibHandle, ProcName);
    Move(ProcPtr, Target, SizeOf(Pointer));
  end;
begin
  ResolveProc(FOPENSSL_init_ssl, GLibSsl, 'OPENSSL_init_ssl');
  ResolveProc(FSSL_library_init, GLibSsl, 'SSL_library_init');
  ResolveProc(FSSL_load_error_strings, GLibSsl, 'SSL_load_error_strings');
  ResolveProc(FOPENSSL_add_ssl_algorithms, GLibCrypto, 'OPENSSL_add_ssl_algorithms');
  if not Assigned(FOPENSSL_add_ssl_algorithms) then
    ResolveProc(FOPENSSL_add_ssl_algorithms, GLibCrypto, 'OpenSSL_add_ssl_algorithms');

  ResolveProc(FTLS_server_method, GLibSsl, 'TLS_server_method');
  ResolveProc(FTLS_client_method, GLibSsl, 'TLS_client_method');
  ResolveProc(FSSLv23_client_method, GLibSsl, 'SSLv23_client_method');
  ResolveProc(FSSL_CTX_new, GLibSsl, 'SSL_CTX_new');
  ResolveProc(FSSL_CTX_free, GLibSsl, 'SSL_CTX_free');
  ResolveProc(FSSL_CTX_use_certificate_chain_file, GLibSsl, 'SSL_CTX_use_certificate_chain_file');
  ResolveProc(FSSL_CTX_use_PrivateKey_file, GLibSsl, 'SSL_CTX_use_PrivateKey_file');
  ResolveProc(FSSL_CTX_check_private_key, GLibSsl, 'SSL_CTX_check_private_key');
  ResolveProc(FSSL_CTX_set_cipher_list, GLibSsl, 'SSL_CTX_set_cipher_list');
  ResolveProc(FSSL_CTX_set_ciphersuites, GLibSsl, 'SSL_CTX_set_ciphersuites');
  ResolveProc(FSSL_CTX_set_options, GLibSsl, 'SSL_CTX_set_options');
  ResolveProc(FSSL_CTX_set_timeout, GLibSsl, 'SSL_CTX_set_timeout');
  ResolveProc(FSSL_CTX_set_session_cache_mode, GLibSsl, 'SSL_CTX_set_session_cache_mode');
  ResolveProc(FSSL_CTX_ctrl, GLibSsl, 'SSL_CTX_ctrl');
  ResolveProc(FSSL_CTX_callback_ctrl, GLibSsl, 'SSL_CTX_callback_ctrl');
  ResolveProc(FSSL_new, GLibSsl, 'SSL_new');
  ResolveProc(FSSL_free, GLibSsl, 'SSL_free');
  ResolveProc(FSSL_set_fd, GLibSsl, 'SSL_set_fd');
  ResolveProc(FSSL_accept, GLibSsl, 'SSL_accept');
  ResolveProc(FSSL_connect, GLibSsl, 'SSL_connect');
  ResolveProc(FSSL_set_verify, GLibSsl, 'SSL_set_verify');
  ResolveProc(FSSL_get_verify_result, GLibSsl, 'SSL_get_verify_result');
  ResolveProc(FSSL_set1_host, GLibSsl, 'SSL_set1_host');
  ResolveProc(FSSL_CTX_set_default_verify_paths, GLibSsl, 'SSL_CTX_set_default_verify_paths');
  ResolveProc(FSSL_read, GLibSsl, 'SSL_read');
  ResolveProc(FSSL_write, GLibSsl, 'SSL_write');
  ResolveProc(FSSL_shutdown, GLibSsl, 'SSL_shutdown');
  ResolveProc(FSSL_get_error, GLibSsl, 'SSL_get_error');
  ResolveProc(FSSL_set_SSL_CTX, GLibSsl, 'SSL_set_SSL_CTX');
  ResolveProc(FSSL_get_servername, GLibSsl, 'SSL_get_servername');
  ResolveProc(FSSL_ctrl, GLibSsl, 'SSL_ctrl');
  ResolveProc(FERR_get_error, GLibCrypto, 'ERR_get_error');
  ResolveProc(FERR_error_string_n, GLibCrypto, 'ERR_error_string_n');

  Result :=
    Assigned(FTLS_server_method) and
    Assigned(FSSL_CTX_new) and
    Assigned(FSSL_CTX_free) and
    Assigned(FSSL_CTX_use_certificate_chain_file) and
    Assigned(FSSL_CTX_use_PrivateKey_file) and
    Assigned(FSSL_CTX_check_private_key) and
    Assigned(FSSL_new) and
    Assigned(FSSL_free) and
    Assigned(FSSL_set_fd) and
    Assigned(FSSL_accept) and
    Assigned(FSSL_connect) and
    Assigned(FSSL_read) and
    Assigned(FSSL_write) and
    Assigned(FSSL_shutdown) and
    Assigned(FSSL_get_error) and
    Assigned(FSSL_ctrl) and
    Assigned(FSSL_set_SSL_CTX);
end;

function TryLoadOpenSslLibraries(out ErrorText: string): Boolean;
type
  TOpenSslLibPair = record
    CryptoName: string;
    SslName: string;
  end;
const
  LIB_PAIRS: array[0..4] of TOpenSslLibPair = (
    (CryptoName: 'libcrypto-3-x64.dll'; SslName: 'libssl-3-x64.dll'),
    (CryptoName: 'libcrypto-3.dll'; SslName: 'libssl-3.dll'),
    (CryptoName: 'libcrypto-1_1-x64.dll'; SslName: 'libssl-1_1-x64.dll'),
    (CryptoName: 'libcrypto-1_1.dll'; SslName: 'libssl-1_1.dll'),
    (CryptoName: 'libeay32.dll'; SslName: 'ssleay32.dll')
  );
var
  Pair: TOpenSslLibPair;
  SslHandle: HMODULE;
  CryptoHandle: HMODULE;
begin
  Result := False;
  ErrorText := '';

  for Pair in LIB_PAIRS do
  begin
    CryptoHandle := LoadLibrary(PChar(Pair.CryptoName));
    if CryptoHandle = 0 then
      Continue;
    SslHandle := LoadLibrary(PChar(Pair.SslName));
    if SslHandle = 0 then
    begin
      FreeLibrary(CryptoHandle);
      Continue;
    end;

    GLibCrypto := CryptoHandle;
    GLibSsl := SslHandle;
    if AssignProcedures then
    begin
      Result := True;
      Exit;
    end;

    GLibCrypto := 0;
    GLibSsl := 0;
    FreeLibrary(SslHandle);
    FreeLibrary(CryptoHandle);
  end;

  ErrorText :=
    'Unable to load matching OpenSSL library pairs (tried 3.x, 1.1 and legacy names)';
end;

function OpenSslDescribeLastError: string;
var
  ErrCode: Cardinal;
  Buffer: array[0..255] of AnsiChar;
begin
  Result := '';
  if not Assigned(FERR_get_error) then
    Exit;
  ErrCode := FERR_get_error;
  if ErrCode = 0 then
    Exit;
  if Assigned(FERR_error_string_n) then
  begin
    FillChar(Buffer, SizeOf(Buffer), 0);
    FERR_error_string_n(ErrCode, @Buffer[0], Length(Buffer));
    Result := string(AnsiString(PAnsiChar(@Buffer[0])));
  end
  else
    Result := Format('OpenSSL error 0x%x', [ErrCode]);
end;

function OpenSslEnsureInitialized(out ErrorText: string): Boolean;
var
  InitResult: Integer;
begin
  if GOpenSslInitialized then
  begin
    ErrorText := '';
    Exit(True);
  end;

  if GOpenSslFailed then
  begin
    ErrorText := GOpenSslErrorText;
    Exit(False);
  end;

  if not TryLoadOpenSslLibraries(ErrorText) then
  begin
    GOpenSslFailed := True;
    GOpenSslErrorText := ErrorText;
    Exit(False);
  end;

  if Assigned(FOPENSSL_init_ssl) then
  begin
    InitResult := FOPENSSL_init_ssl(0, nil);
    if InitResult <> 1 then
    begin
      ErrorText := 'OpenSSL initialization failed';
      FreeOpenSslLibraries;
      GOpenSslFailed := True;
      GOpenSslErrorText := ErrorText;
      Exit(False);
    end;
  end
  else
  begin
    if Assigned(FSSL_library_init) then
      FSSL_library_init;
    if Assigned(FSSL_load_error_strings) then
      FSSL_load_error_strings;
    if Assigned(FOPENSSL_add_ssl_algorithms) then
      FOPENSSL_add_ssl_algorithms;
  end;

  GOpenSslInitialized := True;
  ErrorText := '';
  Result := True;
end;

function BuildProtocolDisableOptions(const Protocols: TArray<string>;
  out Options: UInt64; out ErrorText: string): Boolean;
type
  TProtocolFlag = (pfTls10, pfTls11, pfTls12, pfTls13);
  TProtocolFlags = set of TProtocolFlag;
var
  Allowed: TProtocolFlags;
  ProtocolValue: string;
begin
  Options := 0;
  ErrorText := '';
  Result := True;

  if Length(Protocols) = 0 then
    Exit(True);

  Allowed := [];
  for ProtocolValue in Protocols do
  begin
    if SameText(ProtocolValue, 'TLSv1') then
      Include(Allowed, pfTls10)
    else if SameText(ProtocolValue, 'TLSv1.1') then
      Include(Allowed, pfTls11)
    else if SameText(ProtocolValue, 'TLSv1.2') then
      Include(Allowed, pfTls12)
    else if SameText(ProtocolValue, 'TLSv1.3') then
      Include(Allowed, pfTls13)
    else
    begin
      ErrorText := Format('unsupported SSL protocol "%s"', [ProtocolValue]);
      Exit(False);
    end;
  end;

  if Allowed = [] then
  begin
    ErrorText := 'ssl_protocols resolved to empty set';
    Exit(False);
  end;

  if not (pfTls10 in Allowed) then
    Options := Options or SSL_OP_NO_TLSv1;
  if not (pfTls11 in Allowed) then
    Options := Options or SSL_OP_NO_TLSv1_1;
  if not (pfTls12 in Allowed) then
    Options := Options or SSL_OP_NO_TLSv1_2;
  if not (pfTls13 in Allowed) then
    Options := Options or SSL_OP_NO_TLSv1_3;
end;

function ExtractTls13CipherSuites(const Ciphers: string): string;
var
  I: Integer;
  Token: string;
  Ch: Char;
begin
  Result := '';
  Token := '';
  for I := 1 to Length(Ciphers) + 1 do
  begin
    if I <= Length(Ciphers) then
      Ch := Ciphers[I]
    else
      Ch := ':';

    if (Ch = ':') or (Ch = ',') then
    begin
      Token := Trim(Token);
      if StartsText('TLS_', Token) then
      begin
        if Result <> '' then
          Result := Result + ':';
        Result := Result + Token;
      end;
      Token := '';
      Continue;
    end;

    Token := Token + Ch;
  end;
end;

function OpenSslCreateServerContext(const CertFile, KeyFile: string;
  const Ciphers: string; const Protocols: TArray<string>;
  const PreferServerCiphers: Boolean;
  const SessionCache: string; const SessionTimeoutMs: Integer;
  const SessionTickets: Boolean;
  out SslContext: TRomitterSslContext; out ErrorText: string): Boolean;
var
  Ctx: Pointer;
  Method: Pointer;
  CertFileAnsi: AnsiString;
  KeyFileAnsi: AnsiString;
  CipherListAnsi: AnsiString;
  Tls13CipherListAnsi: AnsiString;
  Tls13CipherList: string;
  DisableOptions: UInt64;
  CacheMode: NativeInt;
begin
  Result := False;
  ErrorText := '';
  SslContext := nil;

  if not OpenSslEnsureInitialized(ErrorText) then
    Exit(False);

  if not Assigned(FTLS_server_method) then
  begin
    ErrorText := 'OpenSSL TLS_server_method is unavailable';
    Exit(False);
  end;
  Method := FTLS_server_method();

  Ctx := FSSL_CTX_new(Method);
  if Ctx = nil then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'SSL_CTX_new failed';
    Exit(False);
  end;

  try
    CertFileAnsi := AnsiString(CertFile);
    KeyFileAnsi := AnsiString(KeyFile);

    if FSSL_CTX_use_certificate_chain_file(Ctx, PAnsiChar(CertFileAnsi)) <> 1 then
    begin
      ErrorText := OpenSslDescribeLastError;
      if ErrorText = '' then
        ErrorText := Format('Unable to load certificate "%s"', [CertFile]);
      Exit(False);
    end;

    if FSSL_CTX_use_PrivateKey_file(Ctx, PAnsiChar(KeyFileAnsi), SSL_FILETYPE_PEM) <> 1 then
    begin
      ErrorText := OpenSslDescribeLastError;
      if ErrorText = '' then
        ErrorText := Format('Unable to load private key "%s"', [KeyFile]);
      Exit(False);
    end;

    if FSSL_CTX_check_private_key(Ctx) <> 1 then
    begin
      ErrorText := OpenSslDescribeLastError;
      if ErrorText = '' then
        ErrorText := 'Certificate and private key mismatch';
      Exit(False);
    end;

    if Trim(Ciphers) <> '' then
    begin
      if not Assigned(FSSL_CTX_set_cipher_list) then
      begin
        ErrorText := 'OpenSSL SSL_CTX_set_cipher_list is unavailable';
        Exit(False);
      end;
      CipherListAnsi := AnsiString(Ciphers);
      if FSSL_CTX_set_cipher_list(Ctx, PAnsiChar(CipherListAnsi)) <> 1 then
      begin
        ErrorText := OpenSslDescribeLastError;
        if ErrorText = '' then
          ErrorText := Format('Unable to apply ssl_ciphers "%s"', [Ciphers]);
        Exit(False);
      end;

      if Assigned(FSSL_CTX_set_ciphersuites) then
      begin
        Tls13CipherList := ExtractTls13CipherSuites(Ciphers);
        if Tls13CipherList <> '' then
        begin
          Tls13CipherListAnsi := AnsiString(Tls13CipherList);
          if FSSL_CTX_set_ciphersuites(Ctx, PAnsiChar(Tls13CipherListAnsi)) <> 1 then
          begin
            ErrorText := OpenSslDescribeLastError;
            if ErrorText = '' then
              ErrorText := Format('Unable to apply TLSv1.3 ciphersuites "%s"',
                [Tls13CipherList]);
            Exit(False);
          end;
        end;
      end;
    end;

    if not BuildProtocolDisableOptions(Protocols, DisableOptions, ErrorText) then
      Exit(False);
    if (DisableOptions <> 0) and Assigned(FSSL_CTX_set_options) then
      FSSL_CTX_set_options(Ctx, DisableOptions);
    if PreferServerCiphers and Assigned(FSSL_CTX_set_options) then
      FSSL_CTX_set_options(Ctx, SSL_OP_CIPHER_SERVER_PREFERENCE);
    if (not SessionTickets) and Assigned(FSSL_CTX_set_options) then
      FSSL_CTX_set_options(Ctx, SSL_OP_NO_TICKET);

    if Assigned(FSSL_CTX_set_session_cache_mode) then
    begin
      if StartsText('off', Trim(SessionCache)) or
         StartsText('none', Trim(SessionCache)) then
        CacheMode := SSL_SESS_CACHE_OFF
      else
        CacheMode := SSL_SESS_CACHE_SERVER;
      FSSL_CTX_set_session_cache_mode(Ctx, CacheMode);
    end;

    if (SessionTimeoutMs > 0) and Assigned(FSSL_CTX_set_timeout) then
      FSSL_CTX_set_timeout(Ctx, Cardinal((SessionTimeoutMs + 999) div 1000));

    SslContext := Ctx;
    Ctx := nil;
    Result := True;
  finally
    if Ctx <> nil then
      FSSL_CTX_free(Ctx);
  end;
end;

function OpenSslCreateClientContext(const Ciphers: string;
  const Protocols: TArray<string>;
  out SslContext: TRomitterSslContext; out ErrorText: string): Boolean;
var
  Ctx: Pointer;
  Method: Pointer;
  DisableOptions: UInt64;
  CipherListAnsi: AnsiString;
  Tls13CipherListAnsi: AnsiString;
  Tls13CipherList: string;
begin
  Result := False;
  ErrorText := '';
  SslContext := nil;

  if not OpenSslEnsureInitialized(ErrorText) then
    Exit(False);

  Method := nil;
  if Assigned(FTLS_client_method) then
    Method := FTLS_client_method()
  else if Assigned(FSSLv23_client_method) then
    Method := FSSLv23_client_method();

  if Method = nil then
  begin
    ErrorText := 'OpenSSL TLS client method is unavailable';
    Exit(False);
  end;

  Ctx := FSSL_CTX_new(Method);
  if Ctx = nil then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'SSL_CTX_new failed';
    Exit(False);
  end;

  try
    if Trim(Ciphers) <> '' then
    begin
      if not Assigned(FSSL_CTX_set_cipher_list) then
      begin
        ErrorText := 'OpenSSL SSL_CTX_set_cipher_list is unavailable';
        Exit(False);
      end;
      CipherListAnsi := AnsiString(Ciphers);
      if FSSL_CTX_set_cipher_list(Ctx, PAnsiChar(CipherListAnsi)) <> 1 then
      begin
        ErrorText := OpenSslDescribeLastError;
        if ErrorText = '' then
          ErrorText := Format('Unable to apply ssl_ciphers "%s"', [Ciphers]);
        Exit(False);
      end;

      if Assigned(FSSL_CTX_set_ciphersuites) then
      begin
        Tls13CipherList := ExtractTls13CipherSuites(Ciphers);
        if Tls13CipherList <> '' then
        begin
          Tls13CipherListAnsi := AnsiString(Tls13CipherList);
          if FSSL_CTX_set_ciphersuites(Ctx, PAnsiChar(Tls13CipherListAnsi)) <> 1 then
          begin
            ErrorText := OpenSslDescribeLastError;
            if ErrorText = '' then
              ErrorText := Format('Unable to apply TLSv1.3 ciphersuites "%s"',
                [Tls13CipherList]);
            Exit(False);
          end;
        end;
      end;
    end;

    if not BuildProtocolDisableOptions(Protocols, DisableOptions, ErrorText) then
      Exit(False);
    if (DisableOptions <> 0) and Assigned(FSSL_CTX_set_options) then
      FSSL_CTX_set_options(Ctx, DisableOptions);

    if Assigned(FSSL_CTX_set_default_verify_paths) then
      FSSL_CTX_set_default_verify_paths(Ctx);

    SslContext := Ctx;
    Ctx := nil;
    Result := True;
  finally
    if Ctx <> nil then
      FSSL_CTX_free(Ctx);
  end;
end;

function OpenSslSetServerNameCallback(const SslContext: TRomitterSslContext;
  const Callback: Pointer; const CallbackArg: Pointer;
  out ErrorText: string): Boolean;
begin
  Result := False;
  ErrorText := '';
  if (SslContext = nil) or (not Assigned(FSSL_CTX_callback_ctrl)) or
     (not Assigned(FSSL_CTX_ctrl)) then
  begin
    ErrorText := 'OpenSSL SNI callback API is unavailable';
    Exit(False);
  end;

  if FSSL_CTX_callback_ctrl(SslContext, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, Callback) <= 0 then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'Failed to set OpenSSL SNI callback';
    Exit(False);
  end;

  if FSSL_CTX_ctrl(SslContext, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, CallbackArg) <= 0 then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'Failed to set OpenSSL SNI callback argument';
    Exit(False);
  end;

  Result := True;
end;

function OpenSslCreateSession(const SslContext: TRomitterSslContext;
  const SocketHandle: TSocket; out Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
var
  Session: Pointer;
  SocketFd: NativeUInt;
begin
  Result := False;
  ErrorText := '';
  Ssl := nil;

  if SslContext = nil then
  begin
    ErrorText := 'SSL context is not initialized';
    Exit(False);
  end;

  Session := FSSL_new(SslContext);
  if Session = nil then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'SSL_new failed';
    Exit(False);
  end;

  SocketFd := NativeUInt(SocketHandle);
  if SocketFd > NativeUInt(High(Integer)) then
  begin
    ErrorText := 'Socket handle value is out of range for SSL_set_fd';
    FSSL_free(Session);
    Exit(False);
  end;

  if FSSL_set_fd(Session, Integer(SocketFd)) <> 1 then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := 'SSL_set_fd failed';
    FSSL_free(Session);
    Exit(False);
  end;

  Ssl := Session;
  Result := True;
end;

function OpenSslAcceptSession(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
var
  AcceptResult: Integer;
  SslError: Integer;
  Retry: Integer;
begin
  Result := False;
  ErrorText := '';
  if Ssl = nil then
  begin
    ErrorText := 'SSL session is not initialized';
    Exit(False);
  end;

  for Retry := 1 to 32 do
  begin
    AcceptResult := FSSL_accept(Ssl);
    if AcceptResult = 1 then
      Exit(True);

    SslError := FSSL_get_error(Ssl, AcceptResult);
    if (SslError = SSL_ERROR_WANT_READ) or (SslError = SSL_ERROR_WANT_WRITE) then
    begin
      Sleep(1);
      Continue;
    end;

    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := Format('SSL_accept failed (error=%d)', [SslError]);
    Exit(False);
  end;

  ErrorText := 'SSL_accept did not complete';
end;

function OpenSslConnectSession(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
var
  ConnectResult: Integer;
  SslError: Integer;
  Retry: Integer;
begin
  Result := False;
  ErrorText := '';
  if Ssl = nil then
  begin
    ErrorText := 'SSL session is not initialized';
    Exit(False);
  end;

  for Retry := 1 to 32 do
  begin
    ConnectResult := FSSL_connect(Ssl);
    if ConnectResult = 1 then
      Exit(True);

    SslError := FSSL_get_error(Ssl, ConnectResult);
    if (SslError = SSL_ERROR_WANT_READ) or (SslError = SSL_ERROR_WANT_WRITE) then
    begin
      Sleep(1);
      Continue;
    end;

    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := Format('SSL_connect failed (error=%d)', [SslError]);
    Exit(False);
  end;

  ErrorText := 'SSL_connect did not complete';
end;

function OpenSslSetSessionServerName(const Ssl: TRomitterSsl;
  const ServerName: string; out ErrorText: string): Boolean;
var
  ServerNameAnsi: AnsiString;
begin
  Result := False;
  ErrorText := '';
  if Ssl = nil then
  begin
    ErrorText := 'SSL session is not initialized';
    Exit(False);
  end;
  if Trim(ServerName) = '' then
    Exit(True);
  if not Assigned(FSSL_ctrl) then
  begin
    ErrorText := 'OpenSSL SSL_ctrl API is unavailable';
    Exit(False);
  end;

  ServerNameAnsi := AnsiString(Trim(ServerName));
  if FSSL_ctrl(
      Ssl,
      SSL_CTRL_SET_TLSEXT_HOSTNAME,
      TLSEXT_NAMETYPE_host_name,
      PAnsiChar(ServerNameAnsi)) <= 0 then
  begin
    ErrorText := OpenSslDescribeLastError;
    if ErrorText = '' then
      ErrorText := Format('Unable to set TLS SNI name "%s"', [ServerName]);
    Exit(False);
  end;

  Result := True;
end;

function OpenSslSetSessionVerify(const Ssl: TRomitterSsl;
  const VerifyPeer: Boolean; const HostName: string;
  out ErrorText: string): Boolean;
var
  HostNameAnsi: AnsiString;
begin
  Result := False;
  ErrorText := '';
  if Ssl = nil then
  begin
    ErrorText := 'SSL session is not initialized';
    Exit(False);
  end;
  if not Assigned(FSSL_set_verify) then
  begin
    if VerifyPeer then
    begin
      ErrorText := 'OpenSSL SSL_set_verify is unavailable';
      Exit(False);
    end;
    Exit(True);
  end;

  if VerifyPeer then
    FSSL_set_verify(Ssl, SSL_VERIFY_PEER, nil)
  else
    FSSL_set_verify(Ssl, SSL_VERIFY_NONE, nil);

  if VerifyPeer and Assigned(FSSL_set1_host) and (Trim(HostName) <> '') then
  begin
    HostNameAnsi := AnsiString(Trim(HostName));
    if FSSL_set1_host(Ssl, PAnsiChar(HostNameAnsi)) <> 1 then
    begin
      ErrorText := OpenSslDescribeLastError;
      if ErrorText = '' then
        ErrorText := Format('Unable to set TLS verify host "%s"', [HostName]);
      Exit(False);
    end;
  end;

  Result := True;
end;

function OpenSslVerifySessionResult(const Ssl: TRomitterSsl;
  out ErrorText: string): Boolean;
var
  VerifyResult: NativeInt;
begin
  Result := False;
  ErrorText := '';
  if Ssl = nil then
  begin
    ErrorText := 'SSL session is not initialized';
    Exit(False);
  end;
  if not Assigned(FSSL_get_verify_result) then
  begin
    ErrorText := 'OpenSSL SSL_get_verify_result is unavailable';
    Exit(False);
  end;

  VerifyResult := FSSL_get_verify_result(Ssl);
  if VerifyResult <> X509_V_OK then
  begin
    ErrorText := Format('TLS peer verify failed (code=%d)', [VerifyResult]);
    Exit(False);
  end;

  Result := True;
end;

function OpenSslRead(const Ssl: TRomitterSsl; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
var
  ReadResult: Integer;
  SslError: Integer;
begin
  ReadResult := FSSL_read(Ssl, Buffer, BufferLen);
  if ReadResult > 0 then
    Exit(ReadResult);

  SslError := FSSL_get_error(Ssl, ReadResult);
  case SslError of
    SSL_ERROR_ZERO_RETURN:
      Result := 0;
    SSL_ERROR_WANT_READ,
    SSL_ERROR_WANT_WRITE:
      begin
        WSASetLastError(WSAEWOULDBLOCK);
        Result := SOCKET_ERROR;
      end;
    SSL_ERROR_SYSCALL:
      begin
        WSASetLastError(WSAECONNRESET);
        Result := SOCKET_ERROR;
      end;
  else
    begin
      WSASetLastError(WSAECONNRESET);
      Result := SOCKET_ERROR;
    end;
  end;
end;

function OpenSslWrite(const Ssl: TRomitterSsl; const Buffer: Pointer;
  const BufferLen: Integer): Integer;
var
  WriteResult: Integer;
  SslError: Integer;
begin
  WriteResult := FSSL_write(Ssl, Buffer, BufferLen);
  if WriteResult > 0 then
    Exit(WriteResult);

  SslError := FSSL_get_error(Ssl, WriteResult);
  case SslError of
    SSL_ERROR_WANT_READ,
    SSL_ERROR_WANT_WRITE:
      begin
        WSASetLastError(WSAEWOULDBLOCK);
        Result := SOCKET_ERROR;
      end;
    SSL_ERROR_ZERO_RETURN:
      Result := 0;
    SSL_ERROR_SYSCALL:
      begin
        WSASetLastError(WSAECONNRESET);
        Result := SOCKET_ERROR;
      end;
  else
    begin
      WSASetLastError(WSAECONNRESET);
      Result := SOCKET_ERROR;
    end;
  end;
end;

function OpenSslSwitchSessionContext(const Ssl: TRomitterSsl;
  const SslContext: TRomitterSslContext): Boolean;
begin
  Result := (Ssl <> nil) and (SslContext <> nil) and
    Assigned(FSSL_set_SSL_CTX) and
    (FSSL_set_SSL_CTX(Ssl, SslContext) <> nil);
end;

function OpenSslGetSessionServerName(const Ssl: TRomitterSsl): string;
var
  ServerNamePtr: Pointer;
begin
  Result := '';
  if Ssl = nil then
    Exit;
  ServerNamePtr := nil;
  if Assigned(FSSL_get_servername) then
    ServerNamePtr := FSSL_get_servername(
      Ssl,
      TLSEXT_NAMETYPE_host_name);
  if (ServerNamePtr = nil) and Assigned(FSSL_ctrl) then
    ServerNamePtr := Pointer(FSSL_ctrl(
      Ssl,
      SSL_CTRL_GET_TLSEXT_HOSTNAME,
      TLSEXT_NAMETYPE_host_name,
      nil));
  if ServerNamePtr <> nil then
    Result := string(AnsiString(PAnsiChar(ServerNamePtr)));
end;

procedure OpenSslFreeSession(var Ssl: TRomitterSsl);
var
  Session: Pointer;
begin
  Session := Ssl;
  Ssl := nil;
  if Session = nil then
    Exit;
  if Assigned(FSSL_shutdown) then
    FSSL_shutdown(Session);
  if Assigned(FSSL_free) then
    FSSL_free(Session);
end;

procedure OpenSslFreeContext(var SslContext: TRomitterSslContext);
var
  Ctx: Pointer;
begin
  Ctx := SslContext;
  SslContext := nil;
  if (Ctx <> nil) and Assigned(FSSL_CTX_free) then
    FSSL_CTX_free(Ctx);
end;

initialization

finalization
  FreeOpenSslLibraries;

end.
