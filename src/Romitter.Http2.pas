unit Romitter.Http2;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  System.StrUtils,
  System.Generics.Collections,
  Winapi.Winsock2,
  Romitter.Logging,
  Romitter.OpenSsl;

type
  TRomitterHttp2Header = record
    Name: string;
    Value: string;
  end;

  TRomitterHttp2Headers = TArray<TRomitterHttp2Header>;

  TRomitterHttp2RequestHandler = function(
    const ClientSocket: TSocket;
    const StreamId: Cardinal;
    const Method, Path, Scheme, Authority: string;
    const Headers: TDictionary<string, string>;
    const Body: TBytes;
    const LocalPort: Word;
    const LocalAddress: string;
    out ResponseRaw: TBytes;
    out CloseConnection: Boolean): Boolean of object;

  TRomitterHttp2Connection = class
  private
    type
      TStreamState = (ssIdle, ssOpen, ssHalfClosedRemote, ssHalfClosedLocal, ssClosed);

      TStreamCtx = class
      public
        Id: Cardinal;
        State: TStreamState;
        HeadersBlock: TBytes;
        Headers: TRomitterHttp2Headers;
        Body: TBytes;
        Method: string;
        Path: string;
        Scheme: string;
        Authority: string;
        HeadersDecoded: Boolean;
        EndStreamReceived: Boolean;
        ResponseSent: Boolean;
        Queued: Boolean;
        ResetByPeer: Boolean;
        SendWindow: Int64;
        constructor Create(const AId: Cardinal; const InitialWindow: Integer);
      end;

      THuffmanNode = record
        HasChildren: Boolean;
        Children: array[0..255] of Integer;
        Sym: Byte;
        CodeLen: Byte;
      end;

      THpackDecoder = class
      private
        FDynamic: TList<TRomitterHttp2Header>;
        FDynamicSize: Cardinal;
        FMaxSize: Cardinal;
        FAllowedSize: Cardinal;
        class var GHuffmanBuilt: Boolean;
        class var GHuffmanNodes: TArray<THuffmanNode>;
        class procedure BuildHuffmanTree; static;
        class function DecodeHuffman(const Src: TBytes; out Dst: TBytes): Boolean; static;
        class function HeaderSize(const H: TRomitterHttp2Header): Cardinal; static;
        class function ReadVarInt(const PrefixBits: Byte; const Data: TBytes;
          var Pos: Integer; out Value: UInt64): Boolean; static;
        function DecodeStringLiteral(const Data: TBytes; var Pos: Integer;
          out Value: string): Boolean;
        function TryGetByIndex(const Index: UInt64; out H: TRomitterHttp2Header): Boolean;
        procedure AddDynamic(const H: TRomitterHttp2Header);
        procedure SetMaxSize(const ASize: Cardinal);
      public
        constructor Create(const MaxSize: Cardinal);
        destructor Destroy; override;
        function Decode(const Block: TBytes; out Headers: TRomitterHttp2Headers;
          out ErrorText: string): Boolean;
      end;

      THpackEncoder = class
      private
        class function FindStaticExact(const Name, Value: string): Integer; static;
        class function FindStaticName(const Name: string): Integer; static;
        class procedure AppendVarInt(var Dst: TBytes; const PrefixBits: Byte;
          const Value: UInt64); static;
        class procedure AppendString(var Dst: TBytes; const Value: string); static;
      public
        function Encode(const Headers: TRomitterHttp2Headers): TBytes;
      end;
  private
    FSocket: TSocket;
    FSsl: TRomitterSsl;
    FLogger: TRomitterLogger;
    FHandler: TRomitterHttp2RequestHandler;
    FLocalPort: Word;
    FLocalAddress: string;

    FDecoder: THpackDecoder;
    FEncoder: THpackEncoder;
    FStreams: TObjectDictionary<Cardinal, TStreamCtx>;
    FQueue: TQueue<Cardinal>;

    FStopping: Boolean;
    FGoAwaySent: Boolean;
    FLastClientStreamId: Cardinal;
    FExpectedContinuationStreamId: Cardinal;
    FPeerMaxFrameSize: Integer;
    FPeerInitialWindowSize: Integer;
    FConnSendWindow: Int64;
    FConnRecvWindow: Int64;
    FPeerMaxConcurrentStreams: Cardinal;

    function ReadTransport(const Buffer: Pointer; const Count: Integer): Integer;
    function WriteTransport(const Buffer: Pointer; const Count: Integer): Integer;
    function ReadExact(const Count: Integer; out Data: TBytes): Boolean;
    function WriteExact(const Data: Pointer; const Count: Integer): Boolean;

    function SendFrame(const FrameType, Flags: Byte; const StreamId: Cardinal;
      const Payload: TBytes): Boolean;
    function SendSettings: Boolean;
    function SendSettingsAck: Boolean;
    function SendWindowUpdate(const StreamId: Cardinal; const Increment: Cardinal): Boolean;
    function SendRst(const StreamId: Cardinal; const ErrorCode: Cardinal): Boolean;
    function SendGoAway(const ErrorCode: Cardinal; const LastStreamId: Cardinal;
      const DebugText: string = ''): Boolean;

    function ReadAndHandleFrame: Boolean;
    function HandleFrame(const FrameType, Flags: Byte; const StreamId: Cardinal;
      const Payload: TBytes): Boolean;
    function GetOrCreateClientStream(const StreamId: Cardinal; out S: TStreamCtx): Boolean;
    procedure QueueStream(const S: TStreamCtx);
    function DecodeStreamHeaders(const S: TStreamCtx; out ErrorText: string): Boolean;
    function ProcessQueue: Boolean;
    function ProcessStream(const S: TStreamCtx): Boolean;

    function ParseHttp1Response(const Raw: TBytes; out StatusCode: Integer;
      out Headers: TRomitterHttp2Headers; out Body: TBytes): Boolean;
    function DecodeChunkedBody(const ChunkedBody: TBytes; out Body: TBytes): Boolean;
    function SendHeaderBlock(const StreamId: Cardinal; const Block: TBytes;
      const EndStream: Boolean): Boolean;
    function WaitSendWindow(const S: TStreamCtx): Boolean;
    function SendBodyData(const S: TStreamCtx; const Body: TBytes): Boolean;
    function SendResponse(const S: TStreamCtx; const StatusCode: Integer;
      const Headers: TRomitterHttp2Headers; const Body: TBytes): Boolean;
  public
    constructor Create(const SocketHandle: TSocket; const ClientSsl: TRomitterSsl;
      const Logger: TRomitterLogger; const LocalPort: Word; const LocalAddress: string;
      const RequestHandler: TRomitterHttp2RequestHandler);
    destructor Destroy; override;
    function Run: Boolean;
  end;

implementation

{$I Romitter.Http2.HpackTables.inc}

const
  HTTP2_CLIENT_PREFACE = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  HTTP2_DEFAULT_WINDOW_SIZE = 65535;
  HTTP2_DEFAULT_MAX_FRAME_SIZE = 16384;
  HTTP2_MAX_FRAME_SIZE_LIMIT = 16777215;
  HTTP2_MAX_HEADER_BLOCK_SIZE = 1024 * 1024;
  HTTP2_MAX_REQUEST_BODY_SIZE = 64 * 1024 * 1024;

  H2_FRAME_DATA = 0;
  H2_FRAME_HEADERS = 1;
  H2_FRAME_PRIORITY = 2;
  H2_FRAME_RST_STREAM = 3;
  H2_FRAME_SETTINGS = 4;
  H2_FRAME_PUSH_PROMISE = 5;
  H2_FRAME_PING = 6;
  H2_FRAME_GOAWAY = 7;
  H2_FRAME_WINDOW_UPDATE = 8;
  H2_FRAME_CONTINUATION = 9;

  H2_FLAG_END_STREAM = $1;
  H2_FLAG_END_HEADERS = $4;
  H2_FLAG_PADDED = $8;
  H2_FLAG_PRIORITY = $20;
  H2_FLAG_ACK = $1;

  H2_SETTINGS_HEADER_TABLE_SIZE = 1;
  H2_SETTINGS_ENABLE_PUSH = 2;
  H2_SETTINGS_MAX_CONCURRENT_STREAMS = 3;
  H2_SETTINGS_INITIAL_WINDOW_SIZE = 4;
  H2_SETTINGS_MAX_FRAME_SIZE = 5;
  H2_SETTINGS_MAX_HEADER_LIST_SIZE = 6;

  H2_NO_ERROR = 0;
  H2_PROTOCOL_ERROR = 1;
  H2_INTERNAL_ERROR = 2;
  H2_FLOW_CONTROL_ERROR = 3;
  H2_STREAM_CLOSED = 5;
  H2_FRAME_SIZE_ERROR = 6;
  H2_CANCEL = 8;
  H2_COMPRESSION_ERROR = 9;

procedure AppendBytes(var Target: TBytes; const Data: Pointer; const Count: Integer);
var
  L: Integer;
begin
  if Count <= 0 then
    Exit;
  L := Length(Target);
  SetLength(Target, L + Count);
  Move(Data^, Target[L], Count);
end;

procedure AppendByte(var Target: TBytes; const Value: Byte);
var
  L: Integer;
begin
  L := Length(Target);
  SetLength(Target, L + 1);
  Target[L] := Value;
end;

function FindSequence(const Data, Pattern: TBytes): Integer;
var
  I: Integer;
  J: Integer;
  Matched: Boolean;
begin
  Result := -1;
  if (Length(Data) = 0) or (Length(Pattern) = 0) or
     (Length(Data) < Length(Pattern)) then
    Exit;
  for I := 0 to Length(Data) - Length(Pattern) do
  begin
    Matched := True;
    for J := 0 to Length(Pattern) - 1 do
      if Data[I + J] <> Pattern[J] then
      begin
        Matched := False;
        Break;
      end;
    if Matched then
      Exit(I);
  end;
end;

constructor TRomitterHttp2Connection.TStreamCtx.Create(const AId: Cardinal;
  const InitialWindow: Integer);
begin
  inherited Create;
  Id := AId;
  State := ssOpen;
  SendWindow := InitialWindow;
end;

constructor TRomitterHttp2Connection.THpackDecoder.Create(const MaxSize: Cardinal);
begin
  inherited Create;
  FDynamic := TList<TRomitterHttp2Header>.Create;
  FDynamicSize := 0;
  FMaxSize := MaxSize;
  FAllowedSize := MaxSize;
  BuildHuffmanTree;
end;

destructor TRomitterHttp2Connection.THpackDecoder.Destroy;
begin
  FDynamic.Free;
  inherited;
end;

class function TRomitterHttp2Connection.THpackDecoder.HeaderSize(
  const H: TRomitterHttp2Header): Cardinal;
begin
  Result := Cardinal(
    Length(TEncoding.UTF8.GetBytes(H.Name)) +
    Length(TEncoding.UTF8.GetBytes(H.Value)) + 32);
end;

procedure TRomitterHttp2Connection.THpackDecoder.SetMaxSize(const ASize: Cardinal);
var
  Last: Integer;
begin
  FMaxSize := ASize;
  while (FDynamicSize > FMaxSize) and (FDynamic.Count > 0) do
  begin
    Last := FDynamic.Count - 1;
    Dec(FDynamicSize, HeaderSize(FDynamic[Last]));
    FDynamic.Delete(Last);
  end;
end;

procedure TRomitterHttp2Connection.THpackDecoder.AddDynamic(
  const H: TRomitterHttp2Header);
var
  Sz: Cardinal;
  Last: Integer;
begin
  Sz := HeaderSize(H);
  if Sz > FMaxSize then
  begin
    FDynamic.Clear;
    FDynamicSize := 0;
    Exit;
  end;
  FDynamic.Insert(0, H);
  Inc(FDynamicSize, Sz);
  while (FDynamicSize > FMaxSize) and (FDynamic.Count > 0) do
  begin
    Last := FDynamic.Count - 1;
    Dec(FDynamicSize, HeaderSize(FDynamic[Last]));
    FDynamic.Delete(Last);
  end;
end;

function TRomitterHttp2Connection.THpackDecoder.TryGetByIndex(
  const Index: UInt64; out H: TRomitterHttp2Header): Boolean;
var
  DynamicIndex: Integer;
begin
  H.Name := '';
  H.Value := '';
  if Index = 0 then
    Exit(False);
  if Index <= HPACK_STATIC_TABLE_COUNT then
  begin
    H.Name := HPACK_STATIC_NAMES[Integer(Index)];
    H.Value := HPACK_STATIC_VALUES[Integer(Index)];
    Exit(True);
  end;
  DynamicIndex := Integer(Index - HPACK_STATIC_TABLE_COUNT);
  if (DynamicIndex < 1) or (DynamicIndex > FDynamic.Count) then
    Exit(False);
  H := FDynamic[DynamicIndex - 1];
  Result := True;
end;

class function TRomitterHttp2Connection.THpackDecoder.ReadVarInt(
  const PrefixBits: Byte; const Data: TBytes; var Pos: Integer;
  out Value: UInt64): Boolean;
var
  PrefixMask: UInt64;
  B: Byte;
  Shift: Integer;
begin
  Result := False;
  Value := 0;
  if (PrefixBits < 1) or (PrefixBits > 8) then
    Exit(False);
  if (Pos < 0) or (Pos >= Length(Data)) then
    Exit(False);

  PrefixMask := (UInt64(1) shl PrefixBits) - 1;
  Value := UInt64(Data[Pos]) and PrefixMask;
  Inc(Pos);
  if Value < PrefixMask then
    Exit(True);

  Shift := 0;
  while Pos < Length(Data) do
  begin
    B := Data[Pos];
    Inc(Pos);
    Value := Value + (UInt64(B and $7F) shl Shift);
    if (B and $80) = 0 then
      Exit(True);
    Inc(Shift, 7);
    if Shift >= 63 then
      Exit(False);
  end;
end;

class procedure TRomitterHttp2Connection.THpackDecoder.BuildHuffmanTree;
var
  I: Integer;
  Cur: Integer;
  Code: Cardinal;
  CodeLen: Integer;
  Shift: Integer;
  NextByte: Integer;
  Start: Integer;
  Count: Integer;
  LeafIdx: Integer;
  N: THuffmanNode;
begin
  if GHuffmanBuilt then
    Exit;

  SetLength(GHuffmanNodes, 1);
  GHuffmanNodes[0].HasChildren := True;
  for I := 0 to 255 do
    GHuffmanNodes[0].Children[I] := -1;

  for I := 0 to 255 do
  begin
    Cur := 0;
    Code := HPACK_HUFFMAN_CODES[I];
    CodeLen := HPACK_HUFFMAN_CODE_LEN[I];

    while CodeLen > 8 do
    begin
      Dec(CodeLen, 8);
      NextByte := Integer((Code shr CodeLen) and $FF);
      if GHuffmanNodes[Cur].Children[NextByte] < 0 then
      begin
        SetLength(GHuffmanNodes, Length(GHuffmanNodes) + 1);
        GHuffmanNodes[High(GHuffmanNodes)].HasChildren := True;
        for Shift := 0 to 255 do
          GHuffmanNodes[High(GHuffmanNodes)].Children[Shift] := -1;
        GHuffmanNodes[Cur].Children[NextByte] := High(GHuffmanNodes);
      end;
      Cur := GHuffmanNodes[Cur].Children[NextByte];
    end;

    Shift := 8 - CodeLen;
    Start := Integer((Code shl Shift) and $FF);
    Count := 1 shl Shift;

    FillChar(N, SizeOf(N), 0);
    N.HasChildren := False;
    N.Sym := Byte(I);
    N.CodeLen := Byte(CodeLen);
    for Shift := 0 to 255 do
      N.Children[Shift] := -1;
    SetLength(GHuffmanNodes, Length(GHuffmanNodes) + 1);
    LeafIdx := High(GHuffmanNodes);
    GHuffmanNodes[LeafIdx] := N;

    for NextByte := Start to Start + Count - 1 do
      GHuffmanNodes[Cur].Children[NextByte] := LeafIdx;
  end;

  GHuffmanBuilt := True;
end;

class function TRomitterHttp2Connection.THpackDecoder.DecodeHuffman(
  const Src: TBytes; out Dst: TBytes): Boolean;
var
  Root: Integer;
  Node: Integer;
  Cur: UInt64;
  CBits: Integer;
  SBits: Integer;
  I: Integer;
  Lookup: Integer;
  Mask: UInt64;
begin
  Dst := nil;
  Result := False;
  BuildHuffmanTree;
  Root := 0;
  Node := Root;
  Cur := 0;
  CBits := 0;
  SBits := 0;

  for I := 0 to High(Src) do
  begin
    Cur := (Cur shl 8) or UInt64(Src[I]);
    Inc(CBits, 8);
    Inc(SBits, 8);
    while CBits >= 8 do
    begin
      Lookup := Integer((Cur shr (CBits - 8)) and $FF);
      Node := GHuffmanNodes[Node].Children[Lookup];
      if Node < 0 then
        Exit(False);
      if GHuffmanNodes[Node].HasChildren then
        Dec(CBits, 8)
      else
      begin
        AppendByte(Dst, GHuffmanNodes[Node].Sym);
        Dec(CBits, GHuffmanNodes[Node].CodeLen);
        Node := Root;
        SBits := CBits;
      end;
    end;
  end;

  while CBits > 0 do
  begin
    Lookup := Integer((Cur shl (8 - CBits)) and $FF);
    Node := GHuffmanNodes[Node].Children[Lookup];
    if Node < 0 then
      Exit(False);
    if GHuffmanNodes[Node].HasChildren or
       (GHuffmanNodes[Node].CodeLen > CBits) then
      Break;
    AppendByte(Dst, GHuffmanNodes[Node].Sym);
    Dec(CBits, GHuffmanNodes[Node].CodeLen);
    Node := Root;
    SBits := CBits;
  end;

  if SBits > 7 then
    Exit(False);
  if CBits > 0 then
  begin
    Mask := (UInt64(1) shl CBits) - 1;
    if (Cur and Mask) <> Mask then
      Exit(False);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.THpackDecoder.DecodeStringLiteral(
  const Data: TBytes; var Pos: Integer; out Value: string): Boolean;
var
  IsHuffman: Boolean;
  StrLen: UInt64;
  Raw: TBytes;
  Decoded: TBytes;
begin
  Result := False;
  Value := '';
  if (Pos < 0) or (Pos >= Length(Data)) then
    Exit(False);

  IsHuffman := (Data[Pos] and $80) <> 0;
  if not ReadVarInt(7, Data, Pos, StrLen) then
    Exit(False);
  if StrLen > UInt64(Length(Data) - Pos) then
    Exit(False);
  if StrLen > UInt64(High(Integer)) then
    Exit(False);

  SetLength(Raw, Integer(StrLen));
  if StrLen > 0 then
    Move(Data[Pos], Raw[0], Integer(StrLen));
  Inc(Pos, Integer(StrLen));

  if not IsHuffman then
    Value := TEncoding.UTF8.GetString(Raw)
  else
  begin
    if not DecodeHuffman(Raw, Decoded) then
      Exit(False);
    Value := TEncoding.UTF8.GetString(Decoded);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.THpackDecoder.Decode(const Block: TBytes;
  out Headers: TRomitterHttp2Headers; out ErrorText: string): Boolean;
var
  Pos: Integer;
  First: Byte;
  Idx: UInt64;
  H: TRomitterHttp2Header;
  NameText: string;
  ValueText: string;
begin
  Result := False;
  ErrorText := '';
  Headers := nil;
  Pos := 0;

  while Pos < Length(Block) do
  begin
    First := Block[Pos];
    if (First and $80) <> 0 then
    begin
      if not ReadVarInt(7, Block, Pos, Idx) then
      begin
        ErrorText := 'HPACK indexed varint error';
        Exit(False);
      end;
      if not TryGetByIndex(Idx, H) then
      begin
        ErrorText := 'HPACK indexed entry out of range';
        Exit(False);
      end;
      SetLength(Headers, Length(Headers) + 1);
      Headers[High(Headers)] := H;
      Continue;
    end;

    if (First and $E0) = $20 then
    begin
      if not ReadVarInt(5, Block, Pos, Idx) then
      begin
        ErrorText := 'HPACK table size update error';
        Exit(False);
      end;
      if Idx > FAllowedSize then
      begin
        ErrorText := 'HPACK dynamic table size exceeds peer limit';
        Exit(False);
      end;
      SetMaxSize(Cardinal(Idx));
      Continue;
    end;

    if ((First and $C0) = $40) or ((First and $F0) = $10) or ((First and $F0) = 0) then
    begin
      if (First and $C0) = $40 then
      begin
        if not ReadVarInt(6, Block, Pos, Idx) then
        begin
          ErrorText := 'HPACK literal(indexed) varint error';
          Exit(False);
        end;
      end
      else
      begin
        if not ReadVarInt(4, Block, Pos, Idx) then
        begin
          ErrorText := 'HPACK literal varint error';
          Exit(False);
        end;
      end;

      if Idx = 0 then
      begin
        if not DecodeStringLiteral(Block, Pos, NameText) then
        begin
          ErrorText := 'HPACK literal name decode error';
          Exit(False);
        end;
      end
      else
      begin
        if not TryGetByIndex(Idx, H) then
        begin
          ErrorText := 'HPACK literal name index out of range';
          Exit(False);
        end;
        NameText := H.Name;
      end;

      if not DecodeStringLiteral(Block, Pos, ValueText) then
      begin
        ErrorText := 'HPACK literal value decode error';
        Exit(False);
      end;

      H.Name := NameText;
      H.Value := ValueText;
      if (First and $C0) = $40 then
        AddDynamic(H);

      SetLength(Headers, Length(Headers) + 1);
      Headers[High(Headers)] := H;
      Continue;
    end;

    ErrorText := 'HPACK unsupported representation';
    Exit(False);
  end;

  Result := True;
end;

class function TRomitterHttp2Connection.THpackEncoder.FindStaticExact(
  const Name, Value: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to HPACK_STATIC_TABLE_COUNT do
    if SameText(HPACK_STATIC_NAMES[I], Name) and
       SameText(HPACK_STATIC_VALUES[I], Value) then
      Exit(I);
end;

class function TRomitterHttp2Connection.THpackEncoder.FindStaticName(
  const Name: string): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 1 to HPACK_STATIC_TABLE_COUNT do
    if SameText(HPACK_STATIC_NAMES[I], Name) then
      Exit(I);
end;

class procedure TRomitterHttp2Connection.THpackEncoder.AppendVarInt(
  var Dst: TBytes; const PrefixBits: Byte; const Value: UInt64);
var
  PrefixMask: UInt64;
  V: UInt64;
begin
  PrefixMask := (UInt64(1) shl PrefixBits) - 1;
  if Value < PrefixMask then
  begin
    AppendByte(Dst, Byte(Value));
    Exit;
  end;
  AppendByte(Dst, Byte(PrefixMask));
  V := Value - PrefixMask;
  while V >= 128 do
  begin
    AppendByte(Dst, Byte((V and $7F) or $80));
    V := V shr 7;
  end;
  AppendByte(Dst, Byte(V));
end;

class procedure TRomitterHttp2Connection.THpackEncoder.AppendString(
  var Dst: TBytes; const Value: string);
var
  B: TBytes;
begin
  B := TEncoding.UTF8.GetBytes(Value);
  AppendVarInt(Dst, 7, UInt64(Length(B)));
  if Length(B) > 0 then
    AppendBytes(Dst, @B[0], Length(B));
end;

function TRomitterHttp2Connection.THpackEncoder.Encode(
  const Headers: TRomitterHttp2Headers): TBytes;
var
  H: TRomitterHttp2Header;
  Exact: Integer;
  NameIdx: Integer;
  FirstPos: Integer;
begin
  Result := nil;
  for H in Headers do
  begin
    Exact := FindStaticExact(H.Name, H.Value);
    if Exact > 0 then
    begin
      FirstPos := Length(Result);
      AppendVarInt(Result, 7, Exact);
      Result[FirstPos] := Result[FirstPos] or $80;
      Continue;
    end;

    NameIdx := FindStaticName(H.Name);
    if NameIdx > 0 then
    begin
      FirstPos := Length(Result);
      AppendVarInt(Result, 4, NameIdx);
      Result[FirstPos] := Result[FirstPos] or $00; // without indexing
      AppendString(Result, H.Value);
    end
    else
    begin
      AppendByte(Result, $00);
      AppendString(Result, H.Name);
      AppendString(Result, H.Value);
    end;
  end;
end;

constructor TRomitterHttp2Connection.Create(const SocketHandle: TSocket;
  const ClientSsl: TRomitterSsl; const Logger: TRomitterLogger;
  const LocalPort: Word; const LocalAddress: string;
  const RequestHandler: TRomitterHttp2RequestHandler);
begin
  inherited Create;
  FSocket := SocketHandle;
  FSsl := ClientSsl;
  FLogger := Logger;
  FHandler := RequestHandler;
  FLocalPort := LocalPort;
  FLocalAddress := LocalAddress;
  FDecoder := THpackDecoder.Create(4096);
  FEncoder := THpackEncoder.Create;
  FStreams := TObjectDictionary<Cardinal, TStreamCtx>.Create([doOwnsValues]);
  FQueue := TQueue<Cardinal>.Create;
  FStopping := False;
  FGoAwaySent := False;
  FLastClientStreamId := 0;
  FExpectedContinuationStreamId := 0;
  FPeerMaxFrameSize := HTTP2_DEFAULT_MAX_FRAME_SIZE;
  FPeerInitialWindowSize := HTTP2_DEFAULT_WINDOW_SIZE;
  FConnSendWindow := HTTP2_DEFAULT_WINDOW_SIZE;
  FConnRecvWindow := HTTP2_DEFAULT_WINDOW_SIZE;
  FPeerMaxConcurrentStreams := 100;
end;

destructor TRomitterHttp2Connection.Destroy;
begin
  FQueue.Free;
  FStreams.Free;
  FEncoder.Free;
  FDecoder.Free;
  inherited;
end;

function TRomitterHttp2Connection.ReadTransport(const Buffer: Pointer;
  const Count: Integer): Integer;
begin
  if FSsl <> nil then
    Exit(OpenSslRead(FSsl, Buffer, Count));
  Result := recv(FSocket, Buffer^, Count, 0);
end;

function TRomitterHttp2Connection.WriteTransport(const Buffer: Pointer;
  const Count: Integer): Integer;
begin
  if FSsl <> nil then
    Exit(OpenSslWrite(FSsl, Buffer, Count));
  Result := send(FSocket, Buffer^, Count, 0);
end;

function TRomitterHttp2Connection.ReadExact(const Count: Integer;
  out Data: TBytes): Boolean;
var
  Offset: Integer;
  N: Integer;
begin
  Result := False;
  SetLength(Data, 0);
  if Count < 0 then
    Exit(False);
  if Count = 0 then
    Exit(True);
  SetLength(Data, Count);
  Offset := 0;
  while Offset < Count do
  begin
    N := ReadTransport(@Data[Offset], Count - Offset);
    if N <= 0 then
      Exit(False);
    Inc(Offset, N);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.WriteExact(const Data: Pointer;
  const Count: Integer): Boolean;
var
  Offset: Integer;
  N: Integer;
begin
  Result := False;
  if Count <= 0 then
    Exit(True);
  Offset := 0;
  while Offset < Count do
  begin
    N := WriteTransport(@PByte(Data)[Offset], Count - Offset);
    if N <= 0 then
      Exit(False);
    Inc(Offset, N);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.SendFrame(const FrameType, Flags: Byte;
  const StreamId: Cardinal; const Payload: TBytes): Boolean;
var
  Header: array[0..8] of Byte;
  L: Cardinal;
begin
  L := Length(Payload);
  Header[0] := Byte((L shr 16) and $FF);
  Header[1] := Byte((L shr 8) and $FF);
  Header[2] := Byte(L and $FF);
  Header[3] := FrameType;
  Header[4] := Flags;
  Header[5] := Byte((StreamId shr 24) and $7F);
  Header[6] := Byte((StreamId shr 16) and $FF);
  Header[7] := Byte((StreamId shr 8) and $FF);
  Header[8] := Byte(StreamId and $FF);
  if not WriteExact(@Header[0], SizeOf(Header)) then
    Exit(False);
  if L > 0 then
    if not WriteExact(@Payload[0], L) then
      Exit(False);
  Result := True;
end;

function TRomitterHttp2Connection.SendSettings: Boolean;
var
  Payload: TBytes;
  Pair: array[0..5] of Byte;
  procedure Add(const Id: Word; const Value: Cardinal);
  begin
    Pair[0] := Byte((Id shr 8) and $FF);
    Pair[1] := Byte(Id and $FF);
    Pair[2] := Byte((Value shr 24) and $FF);
    Pair[3] := Byte((Value shr 16) and $FF);
    Pair[4] := Byte((Value shr 8) and $FF);
    Pair[5] := Byte(Value and $FF);
    AppendBytes(Payload, @Pair[0], SizeOf(Pair));
  end;
begin
  Payload := nil;
  Add(H2_SETTINGS_ENABLE_PUSH, 0);
  Add(H2_SETTINGS_MAX_CONCURRENT_STREAMS, FPeerMaxConcurrentStreams);
  Result := SendFrame(H2_FRAME_SETTINGS, 0, 0, Payload);
end;

function TRomitterHttp2Connection.SendSettingsAck: Boolean;
var
  Empty: TBytes;
begin
  Empty := nil;
  Result := SendFrame(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, Empty);
end;

function TRomitterHttp2Connection.SendWindowUpdate(const StreamId: Cardinal;
  const Increment: Cardinal): Boolean;
var
  V: Cardinal;
  Payload: array[0..3] of Byte;
  Data: TBytes;
begin
  V := Increment and $7FFFFFFF;
  if V = 0 then
    Exit(False);
  Payload[0] := Byte((V shr 24) and $7F);
  Payload[1] := Byte((V shr 16) and $FF);
  Payload[2] := Byte((V shr 8) and $FF);
  Payload[3] := Byte(V and $FF);
  SetLength(Data, 4);
  Move(Payload[0], Data[0], 4);
  Result := SendFrame(H2_FRAME_WINDOW_UPDATE, 0, StreamId, Data);
end;

function TRomitterHttp2Connection.SendRst(const StreamId: Cardinal;
  const ErrorCode: Cardinal): Boolean;
var
  Payload: array[0..3] of Byte;
  Data: TBytes;
begin
  Payload[0] := Byte((ErrorCode shr 24) and $FF);
  Payload[1] := Byte((ErrorCode shr 16) and $FF);
  Payload[2] := Byte((ErrorCode shr 8) and $FF);
  Payload[3] := Byte(ErrorCode and $FF);
  SetLength(Data, 4);
  Move(Payload[0], Data[0], 4);
  Result := SendFrame(H2_FRAME_RST_STREAM, 0, StreamId, Data);
end;

function TRomitterHttp2Connection.SendGoAway(const ErrorCode: Cardinal;
  const LastStreamId: Cardinal; const DebugText: string): Boolean;
var
  Payload: TBytes;
  Header: array[0..7] of Byte;
  LastId: Cardinal;
  DebugBytes: TBytes;
begin
  if FGoAwaySent then
    Exit(True);
  LastId := LastStreamId and $7FFFFFFF;
  Header[0] := Byte((LastId shr 24) and $7F);
  Header[1] := Byte((LastId shr 16) and $FF);
  Header[2] := Byte((LastId shr 8) and $FF);
  Header[3] := Byte(LastId and $FF);
  Header[4] := Byte((ErrorCode shr 24) and $FF);
  Header[5] := Byte((ErrorCode shr 16) and $FF);
  Header[6] := Byte((ErrorCode shr 8) and $FF);
  Header[7] := Byte(ErrorCode and $FF);
  Payload := nil;
  AppendBytes(Payload, @Header[0], SizeOf(Header));
  if DebugText <> '' then
  begin
    DebugBytes := TEncoding.ASCII.GetBytes(DebugText);
    AppendBytes(Payload, @DebugBytes[0], Length(DebugBytes));
  end;
  Result := SendFrame(H2_FRAME_GOAWAY, 0, 0, Payload);
  FGoAwaySent := True;
end;

function TRomitterHttp2Connection.GetOrCreateClientStream(
  const StreamId: Cardinal; out S: TStreamCtx): Boolean;
begin
  if FStreams.TryGetValue(StreamId, S) then
    Exit(True);
  if (StreamId = 0) or ((StreamId and 1) = 0) or
     (StreamId <= FLastClientStreamId) then
    Exit(False);
  S := TStreamCtx.Create(StreamId, FPeerInitialWindowSize);
  FStreams.Add(StreamId, S);
  FLastClientStreamId := StreamId;
  Result := True;
end;

procedure TRomitterHttp2Connection.QueueStream(const S: TStreamCtx);
begin
  if (S = nil) or S.Queued or S.ResponseSent or S.ResetByPeer then
    Exit;
  S.Queued := True;
  FQueue.Enqueue(S.Id);
end;

function TRomitterHttp2Connection.DecodeStreamHeaders(const S: TStreamCtx;
  out ErrorText: string): Boolean;
var
  H: TRomitterHttp2Header;
  NameLower: string;
  SeenRegular: Boolean;
begin
  Result := False;
  ErrorText := '';
  if Length(S.HeadersBlock) > HTTP2_MAX_HEADER_BLOCK_SIZE then
  begin
    ErrorText := 'header block too large';
    Exit(False);
  end;
  if not FDecoder.Decode(S.HeadersBlock, S.Headers, ErrorText) then
    Exit(False);
  S.HeadersBlock := nil;
  S.Method := '';
  S.Path := '';
  S.Scheme := '';
  S.Authority := '';
  SeenRegular := False;
  for H in S.Headers do
  begin
    NameLower := LowerCase(H.Name);
    if NameLower = '' then
    begin
      ErrorText := 'empty header name';
      Exit(False);
    end;
    if NameLower <> H.Name then
    begin
      ErrorText := 'upper-case header name';
      Exit(False);
    end;
    if NameLower[1] = ':' then
    begin
      if SeenRegular then
      begin
        ErrorText := 'pseudo header after regular header';
        Exit(False);
      end;
      if SameText(NameLower, ':method') then
        S.Method := H.Value
      else if SameText(NameLower, ':path') then
        S.Path := H.Value
      else if SameText(NameLower, ':scheme') then
        S.Scheme := H.Value
      else if SameText(NameLower, ':authority') then
        S.Authority := H.Value;
    end
    else
      SeenRegular := True;
  end;
  if (S.Method = '') or (S.Path = '') then
  begin
    ErrorText := 'missing pseudo headers';
    Exit(False);
  end;
  S.HeadersDecoded := True;
  Result := True;
end;

function TRomitterHttp2Connection.HandleFrame(const FrameType, Flags: Byte;
  const StreamId: Cardinal; const Payload: TBytes): Boolean;
var
  S: TStreamCtx;
  I: Integer;
  PadLen: Integer;
  FragLen: Integer;
  SettingId: Word;
  SettingVal: Cardinal;
  IncVal: Cardinal;
  Delta: Int64;
  Pair: TPair<Cardinal, TStreamCtx>;
  TmpError: string;
begin
  Result := False;
  if (FExpectedContinuationStreamId <> 0) and
     (FrameType <> H2_FRAME_CONTINUATION) then
  begin
    SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'expected CONTINUATION');
    Exit(False);
  end;

  case FrameType of
    H2_FRAME_SETTINGS:
      begin
        if StreamId <> 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'SETTINGS stream id');
          Exit(False);
        end;
        if (Flags and H2_FLAG_ACK) <> 0 then
        begin
          if Length(Payload) <> 0 then
          begin
            SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'SETTINGS ack payload');
            Exit(False);
          end;
          Exit(True);
        end;
        if (Length(Payload) mod 6) <> 0 then
        begin
          SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'SETTINGS length');
          Exit(False);
        end;
        I := 0;
        while I < Length(Payload) do
        begin
          SettingId := (Word(Payload[I]) shl 8) or Word(Payload[I + 1]);
          SettingVal :=
            (Cardinal(Payload[I + 2]) shl 24) or
            (Cardinal(Payload[I + 3]) shl 16) or
            (Cardinal(Payload[I + 4]) shl 8) or
            Cardinal(Payload[I + 5]);
          Inc(I, 6);
          case SettingId of
            H2_SETTINGS_HEADER_TABLE_SIZE:
              ;
            H2_SETTINGS_ENABLE_PUSH:
              if SettingVal > 1 then
              begin
                SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'ENABLE_PUSH');
                Exit(False);
              end;
            H2_SETTINGS_MAX_CONCURRENT_STREAMS:
              FPeerMaxConcurrentStreams := SettingVal;
            H2_SETTINGS_INITIAL_WINDOW_SIZE:
              begin
                if SettingVal > $7FFFFFFF then
                begin
                  SendGoAway(H2_FLOW_CONTROL_ERROR, FLastClientStreamId, 'INITIAL_WINDOW_SIZE');
                  Exit(False);
                end;
                Delta := Int64(SettingVal) - Int64(FPeerInitialWindowSize);
                FPeerInitialWindowSize := Integer(SettingVal);
                for Pair in FStreams do
                  if Pair.Value.State <> ssClosed then
                    Inc(Pair.Value.SendWindow, Delta);
              end;
            H2_SETTINGS_MAX_FRAME_SIZE:
              begin
                if (SettingVal < HTTP2_DEFAULT_MAX_FRAME_SIZE) or
                   (SettingVal > HTTP2_MAX_FRAME_SIZE_LIMIT) then
                begin
                  SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'MAX_FRAME_SIZE');
                  Exit(False);
                end;
                FPeerMaxFrameSize := Integer(SettingVal);
              end;
            H2_SETTINGS_MAX_HEADER_LIST_SIZE:
              ;
          end;
        end;
        Exit(SendSettingsAck);
      end;

    H2_FRAME_PING:
      begin
        if (StreamId <> 0) or (Length(Payload) <> 8) then
        begin
          SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'PING');
          Exit(False);
        end;
        if (Flags and H2_FLAG_ACK) <> 0 then
          Exit(True);
        Exit(SendFrame(H2_FRAME_PING, H2_FLAG_ACK, 0, Payload));
      end;

    H2_FRAME_WINDOW_UPDATE:
      begin
        if Length(Payload) <> 4 then
        begin
          SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'WINDOW_UPDATE');
          Exit(False);
        end;
        IncVal :=
          ((Cardinal(Payload[0]) and $7F) shl 24) or
          (Cardinal(Payload[1]) shl 16) or
          (Cardinal(Payload[2]) shl 8) or
          Cardinal(Payload[3]);
        if IncVal = 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'WINDOW_UPDATE zero');
          Exit(False);
        end;
        if StreamId = 0 then
          Inc(FConnSendWindow, IncVal)
        else if FStreams.TryGetValue(StreamId, S) then
          Inc(S.SendWindow, IncVal);
        Exit(True);
      end;

    H2_FRAME_RST_STREAM:
      begin
        if (StreamId = 0) or (Length(Payload) <> 4) then
        begin
          SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'RST_STREAM');
          Exit(False);
        end;
        if FStreams.TryGetValue(StreamId, S) then
        begin
          S.ResetByPeer := True;
          S.State := ssClosed;
        end;
        Exit(True);
      end;

    H2_FRAME_GOAWAY:
      begin
        if StreamId <> 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'GOAWAY stream id');
          Exit(False);
        end;
        FStopping := True;
        Exit(True);
      end;

    H2_FRAME_HEADERS:
      begin
        if StreamId = 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'HEADERS stream id');
          Exit(False);
        end;
        if not GetOrCreateClientStream(StreamId, S) then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'invalid stream id sequence');
          Exit(False);
        end;
        if S.HeadersDecoded then
        begin
          SendRst(StreamId, H2_PROTOCOL_ERROR);
          S.State := ssClosed;
          Exit(True);
        end;
        if S.ResetByPeer or (S.State = ssClosed) then
          Exit(True);

        I := 0;
        PadLen := 0;
        if (Flags and H2_FLAG_PADDED) <> 0 then
        begin
          if Length(Payload) = 0 then
          begin
            SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'HEADERS padded empty');
            Exit(False);
          end;
          PadLen := Payload[0];
          Inc(I);
        end;
        if (Flags and H2_FLAG_PRIORITY) <> 0 then
        begin
          if (Length(Payload) - I) < 5 then
          begin
            SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'HEADERS priority');
            Exit(False);
          end;
          Inc(I, 5);
        end;

        FragLen := Length(Payload) - I - PadLen;
        if FragLen < 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'HEADERS padding');
          Exit(False);
        end;
        if FragLen > 0 then
          AppendBytes(S.HeadersBlock, @Payload[I], FragLen);

        if (Flags and H2_FLAG_END_HEADERS) <> 0 then
        begin
          FExpectedContinuationStreamId := 0;
          if not DecodeStreamHeaders(S, TmpError) then
          begin
            SendRst(StreamId, H2_COMPRESSION_ERROR);
            S.State := ssClosed;
            Exit(True);
          end;
        end
        else
          FExpectedContinuationStreamId := StreamId;

        if (Flags and H2_FLAG_END_STREAM) <> 0 then
        begin
          S.EndStreamReceived := True;
          if S.State = ssOpen then
            S.State := ssHalfClosedRemote
          else if S.State = ssHalfClosedLocal then
            S.State := ssClosed;
          if S.HeadersDecoded then
            QueueStream(S);
        end;
        Exit(True);
      end;

    H2_FRAME_CONTINUATION:
      begin
        if (StreamId = 0) or (StreamId <> FExpectedContinuationStreamId) then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'CONTINUATION stream');
          Exit(False);
        end;
        if not FStreams.TryGetValue(StreamId, S) then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'CONTINUATION unknown stream');
          Exit(False);
        end;
        if Length(Payload) > 0 then
          AppendBytes(S.HeadersBlock, @Payload[0], Length(Payload));
        if (Flags and H2_FLAG_END_HEADERS) <> 0 then
        begin
          FExpectedContinuationStreamId := 0;
          if not DecodeStreamHeaders(S, TmpError) then
          begin
            SendRst(StreamId, H2_COMPRESSION_ERROR);
            S.State := ssClosed;
            Exit(True);
          end;
          if S.EndStreamReceived then
            QueueStream(S);
        end;
        Exit(True);
      end;

    H2_FRAME_DATA:
      begin
        if StreamId = 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'DATA stream id');
          Exit(False);
        end;
        if not FStreams.TryGetValue(StreamId, S) then
        begin
          SendRst(StreamId, H2_STREAM_CLOSED);
          Exit(True);
        end;
        if S.ResetByPeer or (S.State = ssClosed) then
          Exit(True);

        I := 0;
        PadLen := 0;
        if (Flags and H2_FLAG_PADDED) <> 0 then
        begin
          if Length(Payload) = 0 then
          begin
            SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'DATA padded empty');
            Exit(False);
          end;
          PadLen := Payload[0];
          Inc(I);
        end;
        FragLen := Length(Payload) - I - PadLen;
        if FragLen < 0 then
        begin
          SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'DATA padding');
          Exit(False);
        end;
        if FragLen > 0 then
        begin
          if (Length(S.Body) + FragLen) > HTTP2_MAX_REQUEST_BODY_SIZE then
          begin
            SendRst(StreamId, H2_CANCEL);
            S.State := ssClosed;
            Exit(True);
          end;
          AppendBytes(S.Body, @Payload[I], FragLen);
          Dec(FConnRecvWindow, FragLen);
          if not SendWindowUpdate(0, FragLen) then
            Exit(False);
          if not SendWindowUpdate(StreamId, FragLen) then
            Exit(False);
        end;

        if (Flags and H2_FLAG_END_STREAM) <> 0 then
        begin
          S.EndStreamReceived := True;
          if S.State = ssOpen then
            S.State := ssHalfClosedRemote
          else if S.State = ssHalfClosedLocal then
            S.State := ssClosed;
          if S.HeadersDecoded then
            QueueStream(S);
        end;
        Exit(True);
      end;

    H2_FRAME_PRIORITY:
      begin
        if Length(Payload) <> 5 then
        begin
          SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'PRIORITY size');
          Exit(False);
        end;
        Exit(True);
      end;

    H2_FRAME_PUSH_PROMISE:
      begin
        SendGoAway(H2_PROTOCOL_ERROR, FLastClientStreamId, 'PUSH_PROMISE from client');
        Exit(False);
      end;
  end;

  Result := True;
end;

function TRomitterHttp2Connection.ReadAndHandleFrame: Boolean;
var
  Header: TBytes;
  Payload: TBytes;
  PayloadLen: Integer;
  FrameType: Byte;
  Flags: Byte;
  StreamId: Cardinal;
begin
  Result := False;
  if not ReadExact(9, Header) then
    Exit(False);
  PayloadLen := (Integer(Header[0]) shl 16) or (Integer(Header[1]) shl 8) or Integer(Header[2]);
  FrameType := Header[3];
  Flags := Header[4];
  StreamId :=
    ((Cardinal(Header[5]) and $7F) shl 24) or
    (Cardinal(Header[6]) shl 16) or
    (Cardinal(Header[7]) shl 8) or
    Cardinal(Header[8]);

  if PayloadLen > HTTP2_MAX_FRAME_SIZE_LIMIT then
  begin
    SendGoAway(H2_FRAME_SIZE_ERROR, FLastClientStreamId, 'frame payload too large');
    Exit(False);
  end;
  if not ReadExact(PayloadLen, Payload) then
    Exit(False);
  Result := HandleFrame(FrameType, Flags, StreamId, Payload);
end;

function TRomitterHttp2Connection.DecodeChunkedBody(const ChunkedBody: TBytes;
  out Body: TBytes): Boolean;
var
  Offset: Integer;
  LineEnd: Integer;
  SizeText: string;
  ChunkSize: Int64;
  SemicolonPos: Integer;
  function FindCrlf(const StartPos: Integer): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    for K := StartPos to Length(ChunkedBody) - 2 do
      if (ChunkedBody[K] = Ord(#13)) and (ChunkedBody[K + 1] = Ord(#10)) then
        Exit(K);
  end;
begin
  Result := False;
  Body := nil;
  Offset := 0;
  while True do
  begin
    LineEnd := FindCrlf(Offset);
    if LineEnd < 0 then
      Exit(False);
    SizeText := TEncoding.ASCII.GetString(ChunkedBody, Offset, LineEnd - Offset);
    SizeText := Trim(SizeText);
    SemicolonPos := Pos(';', SizeText);
    if SemicolonPos > 0 then
      SizeText := Trim(Copy(SizeText, 1, SemicolonPos - 1));
    if (SizeText = '') or
       (not TryStrToInt64('$' + SizeText, ChunkSize)) or
       (ChunkSize < 0) then
      Exit(False);
    Offset := LineEnd + 2;
    if ChunkSize = 0 then
    begin
      while True do
      begin
        LineEnd := FindCrlf(Offset);
        if LineEnd < 0 then
          Exit(False);
        if LineEnd = Offset then
        begin
          Offset := LineEnd + 2;
          Break;
        end;
        Offset := LineEnd + 2;
      end;
      Break;
    end;
    if ChunkSize > (Length(ChunkedBody) - Offset) then
      Exit(False);
    AppendBytes(Body, @ChunkedBody[Offset], Integer(ChunkSize));
    Inc(Offset, Integer(ChunkSize));
    if (Offset + 1 >= Length(ChunkedBody)) or
       (ChunkedBody[Offset] <> Ord(#13)) or
       (ChunkedBody[Offset + 1] <> Ord(#10)) then
      Exit(False);
    Inc(Offset, 2);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.ParseHttp1Response(const Raw: TBytes;
  out StatusCode: Integer; out Headers: TRomitterHttp2Headers;
  out Body: TBytes): Boolean;
var
  Delim: TBytes;
  HeaderEnd: Integer;
  HeaderText: string;
  Lines: TStringList;
  Line: string;
  P: Integer;
  H: TRomitterHttp2Header;
  I: Integer;
  RawBody: TBytes;
  IsChunked: Boolean;
begin
  Result := False;
  StatusCode := 0;
  Headers := nil;
  Body := nil;
  Delim := TEncoding.ASCII.GetBytes(#13#10#13#10);
  HeaderEnd := FindSequence(Raw, Delim);
  if HeaderEnd < 0 then
    Exit(False);
  HeaderText := TEncoding.ASCII.GetString(Raw, 0, HeaderEnd);
  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(HeaderText, #13#10, sLineBreak, [rfReplaceAll]);
    if Lines.Count = 0 then
      Exit(False);
    Line := Trim(Lines[0]);
    P := Pos(' ', Line);
    if P <= 0 then
      Exit(False);
    Line := Trim(Copy(Line, P + 1, MaxInt));
    P := Pos(' ', Line);
    if P > 0 then
      Line := Copy(Line, 1, P - 1);
    if not TryStrToInt(Line, StatusCode) then
      Exit(False);

    SetLength(RawBody, Length(Raw) - (HeaderEnd + Length(Delim)));
    if Length(RawBody) > 0 then
      Move(Raw[HeaderEnd + Length(Delim)], RawBody[0], Length(RawBody));

    IsChunked := False;
    for I := 1 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if Line = '' then
        Continue;
      P := Pos(':', Line);
      if P < 2 then
        Continue;
      H.Name := LowerCase(Trim(Copy(Line, 1, P - 1)));
      H.Value := Trim(Copy(Line, P + 1, MaxInt));
      if SameText(H.Name, 'transfer-encoding') and
         ContainsText(LowerCase(H.Value), 'chunked') then
      begin
        IsChunked := True;
        Continue;
      end;
      if SameText(H.Name, 'connection') or
         SameText(H.Name, 'proxy-connection') or
         SameText(H.Name, 'keep-alive') or
         SameText(H.Name, 'upgrade') then
        Continue;
      if SameText(H.Name, 'content-length') then
        Continue;
      SetLength(Headers, Length(Headers) + 1);
      Headers[High(Headers)] := H;
    end;

    if IsChunked then
    begin
      if not DecodeChunkedBody(RawBody, Body) then
        Exit(False);
    end
    else
      Body := RawBody;

    if not ((StatusCode >= 100) and (StatusCode < 200)) and
       (StatusCode <> 204) and
       (StatusCode <> 304) then
    begin
      H.Name := 'content-length';
      H.Value := IntToStr(Length(Body));
      SetLength(Headers, Length(Headers) + 1);
      Headers[High(Headers)] := H;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

function TRomitterHttp2Connection.SendHeaderBlock(const StreamId: Cardinal;
  const Block: TBytes; const EndStream: Boolean): Boolean;
var
  Offset: Integer;
  ChunkLen: Integer;
  Payload: TBytes;
  Flags: Byte;
  First: Boolean;
  FrameType: Byte;
begin
  Result := False;
  if Length(Block) = 0 then
  begin
    Payload := nil;
    Flags := H2_FLAG_END_HEADERS;
    if EndStream then
      Flags := Flags or H2_FLAG_END_STREAM;
    Exit(SendFrame(H2_FRAME_HEADERS, Flags, StreamId, Payload));
  end;

  Offset := 0;
  First := True;
  while Offset < Length(Block) do
  begin
    ChunkLen := Min(FPeerMaxFrameSize, Length(Block) - Offset);
    SetLength(Payload, ChunkLen);
    Move(Block[Offset], Payload[0], ChunkLen);
    Inc(Offset, ChunkLen);
    Flags := 0;
    if Offset >= Length(Block) then
      Flags := Flags or H2_FLAG_END_HEADERS;
    if EndStream and (Offset >= Length(Block)) then
      Flags := Flags or H2_FLAG_END_STREAM;
    if First then
      FrameType := H2_FRAME_HEADERS
    else
      FrameType := H2_FRAME_CONTINUATION;
    if not SendFrame(FrameType, Flags, StreamId, Payload) then
      Exit(False);
    First := False;
  end;
  Result := True;
end;

function TRomitterHttp2Connection.WaitSendWindow(const S: TStreamCtx): Boolean;
begin
  Result := False;
  while not FStopping do
  begin
    if S.ResetByPeer or (S.State = ssClosed) then
      Exit(False);
    if (FConnSendWindow > 0) and (S.SendWindow > 0) then
      Exit(True);
    if not ReadAndHandleFrame then
      Exit(False);
  end;
end;

function TRomitterHttp2Connection.SendBodyData(const S: TStreamCtx;
  const Body: TBytes): Boolean;
var
  Offset: Integer;
  ChunkLen: Integer;
  Allowed: Int64;
  Payload: TBytes;
  Flags: Byte;
begin
  Result := False;
  if Length(Body) = 0 then
    Exit(True);
  Offset := 0;
  while Offset < Length(Body) do
  begin
    if not WaitSendWindow(S) then
      Exit(False);
    Allowed := Min(FConnSendWindow, S.SendWindow);
    if Allowed <= 0 then
      Exit(False);
    ChunkLen := Min(FPeerMaxFrameSize, Length(Body) - Offset);
    if ChunkLen > Allowed then
      ChunkLen := Integer(Allowed);
    if ChunkLen <= 0 then
      Exit(False);
    SetLength(Payload, ChunkLen);
    Move(Body[Offset], Payload[0], ChunkLen);
    Inc(Offset, ChunkLen);
    Flags := 0;
    if Offset >= Length(Body) then
      Flags := H2_FLAG_END_STREAM;
    if not SendFrame(H2_FRAME_DATA, Flags, S.Id, Payload) then
      Exit(False);
    Dec(FConnSendWindow, ChunkLen);
    Dec(S.SendWindow, ChunkLen);
  end;
  Result := True;
end;

function TRomitterHttp2Connection.SendResponse(const S: TStreamCtx;
  const StatusCode: Integer; const Headers: TRomitterHttp2Headers;
  const Body: TBytes): Boolean;
var
  OutHeaders: TRomitterHttp2Headers;
  H: TRomitterHttp2Header;
  Block: TBytes;
begin
  Result := False;
  SetLength(OutHeaders, 1);
  OutHeaders[0].Name := ':status';
  OutHeaders[0].Value := IntToStr(StatusCode);
  for H in Headers do
  begin
    if (H.Name = '') or (H.Name[1] = ':') then
      Continue;
    SetLength(OutHeaders, Length(OutHeaders) + 1);
    OutHeaders[High(OutHeaders)] := H;
  end;
  Block := FEncoder.Encode(OutHeaders);
  if not SendHeaderBlock(S.Id, Block, Length(Body) = 0) then
    Exit(False);
  if Length(Body) > 0 then
    if not SendBodyData(S, Body) then
      Exit(False);
  Result := True;
end;

function TRomitterHttp2Connection.ProcessStream(const S: TStreamCtx): Boolean;
var
  Map: TDictionary<string, string>;
  H: TRomitterHttp2Header;
  Existing: string;
  RawResp: TBytes;
  CloseConn: Boolean;
  StatusCode: Integer;
  RespHeaders: TRomitterHttp2Headers;
  RespBody: TBytes;
  Fallback: AnsiString;
begin
  Result := False;
  if (S = nil) or S.ResponseSent or S.ResetByPeer or (S.State = ssClosed) then
    Exit(True);

  Map := TDictionary<string, string>.Create;
  try
    for H in S.Headers do
    begin
      if (H.Name = '') or (H.Name[1] = ':') then
        Continue;
      if Map.TryGetValue(H.Name, Existing) then
      begin
        if SameText(H.Name, 'cookie') then
          Map.AddOrSetValue(H.Name, Existing + '; ' + H.Value)
        else
          Map.AddOrSetValue(H.Name, Existing + ',' + H.Value);
      end
      else
        Map.Add(H.Name, H.Value);
    end;
    if (S.Authority <> '') and (not Map.ContainsKey('host')) then
      Map.Add('host', S.Authority);

    RawResp := nil;
    CloseConn := False;
    if Assigned(FHandler) then
      Result := FHandler(
        FSocket,
        S.Id,
        S.Method,
        S.Path,
        S.Scheme,
        S.Authority,
        Map,
        S.Body,
        FLocalPort,
        FLocalAddress,
        RawResp,
        CloseConn)
    else
      Result := False;

    if Result and (Length(RawResp) = 0) and CloseConn then
    begin
      S.ResponseSent := True;
      S.State := ssClosed;
      SendGoAway(H2_NO_ERROR, S.Id);
      FStopping := True;
      Exit(True);
    end;

    if (not Result) or (Length(RawResp) = 0) then
    begin
      Fallback := AnsiString(
        'HTTP/1.1 500 Internal Server Error'#13#10 +
        'content-type: text/plain; charset=utf-8'#13#10 +
        'content-length: 21'#13#10#13#10 +
        'Internal Server Error');
      SetLength(RawResp, Length(Fallback));
      Move(PAnsiChar(Fallback)^, RawResp[0], Length(Fallback));
      CloseConn := True;
    end;

    if not ParseHttp1Response(RawResp, StatusCode, RespHeaders, RespBody) then
    begin
      StatusCode := 502;
      SetLength(RespHeaders, 1);
      RespHeaders[0].Name := 'content-type';
      RespHeaders[0].Value := 'text/plain; charset=utf-8';
      RespBody := TEncoding.UTF8.GetBytes('Bad Gateway');
      CloseConn := True;
    end;

    if not SendResponse(S, StatusCode, RespHeaders, RespBody) then
      Exit(False);

    S.ResponseSent := True;
    if S.State = ssHalfClosedRemote then
      S.State := ssClosed
    else
      S.State := ssHalfClosedLocal;
    Result := True;

    if CloseConn then
    begin
      SendGoAway(H2_NO_ERROR, S.Id);
      FStopping := True;
    end;
  finally
    Map.Free;
  end;
end;

function TRomitterHttp2Connection.ProcessQueue: Boolean;
var
  Id: Cardinal;
  S: TStreamCtx;
begin
  Result := True;
  while (FQueue.Count > 0) and (not FStopping) do
  begin
    Id := FQueue.Dequeue;
    if not FStreams.TryGetValue(Id, S) then
      Continue;
    S.Queued := False;
    if not ProcessStream(S) then
      Exit(False);
  end;
end;

function TRomitterHttp2Connection.Run: Boolean;
var
  Preface: TBytes;
  Expected: TBytes;
begin
  Result := False;
  Expected := TEncoding.ASCII.GetBytes(HTTP2_CLIENT_PREFACE);
  if not ReadExact(Length(Expected), Preface) then
    Exit(False);
  if (Length(Preface) <> Length(Expected)) or
     (not CompareMem(@Preface[0], @Expected[0], Length(Expected))) then
    Exit(False);

  if not SendSettings then
    Exit(False);

  while not FStopping do
  begin
    if not ProcessQueue then
      Break;
    if FStopping then
      Break;
    if not ReadAndHandleFrame then
      Break;
  end;

  if not FGoAwaySent then
    SendGoAway(H2_NO_ERROR, FLastClientStreamId);
  Result := True;
end;

end.
