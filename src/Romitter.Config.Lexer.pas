unit Romitter.Config.Lexer;

interface

uses
  System.SysUtils;

type
  TRomitterTokenKind = (tkWord, tkLBrace, tkRBrace, tkSemicolon, tkEOF);

  TRomitterToken = record
    Kind: TRomitterTokenKind;
    Value: string;
    Line: Integer;
    Column: Integer;
  end;

  ERomitterConfigLexer = class(Exception);

  TRomitterConfigLexer = class
  private
    FSource: string;
    FSourceName: string;
    FIndex: Integer;
    FLine: Integer;
    FColumn: Integer;
    function CurrentChar: Char;
    function IsEOF: Boolean;
    procedure Advance;
    procedure SkipSpacesAndComments;
    function ParseWord: string;
    function ParseQuoted(const QuoteChar: Char): string;
    function MakeToken(const Kind: TRomitterTokenKind; const Value: string): TRomitterToken;
  public
    constructor Create(const Source, SourceName: string);
    function NextToken: TRomitterToken;
  end;

implementation

constructor TRomitterConfigLexer.Create(const Source, SourceName: string);
begin
  inherited Create;
  FSource := Source;
  FSourceName := SourceName;
  FIndex := 1;
  FLine := 1;
  FColumn := 1;
end;

procedure TRomitterConfigLexer.Advance;
begin
  if IsEOF then
    Exit;

  if FSource[FIndex] = #10 then
  begin
    Inc(FLine);
    FColumn := 1;
  end
  else
    Inc(FColumn);

  Inc(FIndex);
end;

function TRomitterConfigLexer.CurrentChar: Char;
begin
  if IsEOF then
    Exit(#0);
  Result := FSource[FIndex];
end;

function TRomitterConfigLexer.IsEOF: Boolean;
begin
  Result := FIndex > Length(FSource);
end;

function TRomitterConfigLexer.MakeToken(const Kind: TRomitterTokenKind;
  const Value: string): TRomitterToken;
begin
  Result.Kind := Kind;
  Result.Value := Value;
  Result.Line := FLine;
  Result.Column := FColumn;
end;

function TRomitterConfigLexer.ParseQuoted(const QuoteChar: Char): string;
var
  C: Char;
begin
  Result := '';
  Advance;
  while not IsEOF do
  begin
    C := CurrentChar;
    if C = QuoteChar then
    begin
      Advance;
      Exit;
    end;

    if C = '\' then
    begin
      Advance;
      if IsEOF then
        raise ERomitterConfigLexer.CreateFmt(
          '%s(%d,%d): unterminated escape sequence',
          [FSourceName, FLine, FColumn]);
      C := CurrentChar;
      case C of
        'n': Result := Result + #10;
        'r': Result := Result + #13;
        't': Result := Result + #9;
        '\', '''', '"': Result := Result + C;
      else
        // Keep unknown escapes intact (\x -> \x) to preserve Windows paths.
        Result := Result + '\' + C;
      end;
      Advance;
      Continue;
    end;

    Result := Result + C;
    Advance;
  end;

  raise ERomitterConfigLexer.CreateFmt(
    '%s(%d,%d): unterminated quoted string',
    [FSourceName, FLine, FColumn]);
end;

function TRomitterConfigLexer.ParseWord: string;
var
  C: Char;
  Escaped: Char;
begin
  Result := '';
  while not IsEOF do
  begin
    C := CurrentChar;
    if CharInSet(C, [#9, #10, #13, ' ', '{', '}', ';', '#']) then
      Break;

    if C = '\' then
    begin
      Advance;
      if IsEOF then
        raise ERomitterConfigLexer.CreateFmt(
          '%s(%d,%d): invalid escape at end of file',
          [FSourceName, FLine, FColumn]);
      Escaped := CurrentChar;
      if CharInSet(Escaped, [#9, #10, #13, ' ', '{', '}', ';', '#', '\', '''', '"']) then
        Result := Result + Escaped
      else
        // Preserve backslash for non-special sequences (e.g. C:\path\file).
        Result := Result + '\' + Escaped;
      Advance;
      Continue;
    end;

    if (C = '''') or (C = '"') then
    begin
      Result := Result + ParseQuoted(C);
      Continue;
    end;

    Result := Result + C;
    Advance;
  end;
end;

procedure TRomitterConfigLexer.SkipSpacesAndComments;
begin
  while not IsEOF do
  begin
    if CharInSet(CurrentChar, [#9, #10, #13, ' ']) then
    begin
      Advance;
      Continue;
    end;

    if CurrentChar = '#' then
    begin
      while (not IsEOF) and (CurrentChar <> #10) do
        Advance;
      Continue;
    end;

    Break;
  end;
end;

function TRomitterConfigLexer.NextToken: TRomitterToken;
var
  C: Char;
  LineAtStart: Integer;
  ColumnAtStart: Integer;
begin
  SkipSpacesAndComments;

  if IsEOF then
  begin
    Result := MakeToken(tkEOF, '');
    Exit;
  end;

  LineAtStart := FLine;
  ColumnAtStart := FColumn;
  C := CurrentChar;

  case C of
    '{':
      begin
        Advance;
        Result.Kind := tkLBrace;
        Result.Value := '{';
      end;
    '}':
      begin
        Advance;
        Result.Kind := tkRBrace;
        Result.Value := '}';
      end;
    ';':
      begin
        Advance;
        Result.Kind := tkSemicolon;
        Result.Value := ';';
      end;
  else
    begin
      Result.Kind := tkWord;
      Result.Value := ParseWord;
      if (Result.Value = '') and (C <> '''') and (C <> '"') then
        raise ERomitterConfigLexer.CreateFmt(
          '%s(%d,%d): unexpected token',
          [FSourceName, FLine, FColumn]);
    end;
  end;

  Result.Line := LineAtStart;
  Result.Column := ColumnAtStart;
end;

end.
