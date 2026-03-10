unit Romitter.Config.Parser;

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Romitter.Config.Lexer,
  Romitter.Config.Ast;

type
  ERomitterConfigParser = class(Exception);

  TRomitterConfigParser = class
  private
    FLexer: TRomitterConfigLexer;
    FCurrent: TRomitterToken;
    FSourceName: string;
    procedure Next;
    procedure Expect(const Kind: TRomitterTokenKind; const Description: string = '');
    procedure ParseDirectiveList(const Target: TObjectList<TRomitterDirective>;
      const StopAtRBrace: Boolean);
    function ParseDirective: TRomitterDirective;
    class procedure AppendArg(var Args: TArray<string>; const Value: string); static;
  public
    constructor Create(const Text, SourceName: string);
    destructor Destroy; override;
    function Parse: TRomitterConfigAst;
    class function ParseFile(const FileName: string): TRomitterConfigAst; static;
  end;

implementation

uses
  System.IOUtils;

class procedure TRomitterConfigParser.AppendArg(var Args: TArray<string>;
  const Value: string);
var
  N: Integer;
begin
  N := Length(Args);
  SetLength(Args, N + 1);
  Args[N] := Value;
end;

constructor TRomitterConfigParser.Create(const Text, SourceName: string);
begin
  inherited Create;
  FSourceName := SourceName;
  FLexer := TRomitterConfigLexer.Create(Text, SourceName);
  FCurrent := FLexer.NextToken;
end;

destructor TRomitterConfigParser.Destroy;
begin
  FLexer.Free;
  inherited;
end;

procedure TRomitterConfigParser.Expect(const Kind: TRomitterTokenKind;
  const Description: string);
var
  Expected: string;
begin
  if FCurrent.Kind = Kind then
    Exit;

  case Kind of
    tkWord: Expected := 'word';
    tkLBrace: Expected := '"{"';
    tkRBrace: Expected := '"}"';
    tkSemicolon: Expected := '";"';
    tkEOF: Expected := 'end of file';
  else
    Expected := 'token';
  end;

  if Description <> '' then
    Expected := Description;

  raise ERomitterConfigParser.CreateFmt(
    '%s(%d,%d): expected %s, got "%s"',
    [FSourceName, FCurrent.Line, FCurrent.Column, Expected, FCurrent.Value]);
end;

procedure TRomitterConfigParser.Next;
begin
  FCurrent := FLexer.NextToken;
end;

function TRomitterConfigParser.Parse: TRomitterConfigAst;
begin
  Result := TRomitterConfigAst.Create;
  ParseDirectiveList(Result.Directives, False);
  Expect(tkEOF);
end;

function TRomitterConfigParser.ParseDirective: TRomitterDirective;
var
  Name: string;
  LineNo: Integer;
  Args: TArray<string>;
begin
  Expect(tkWord);
  Name := FCurrent.Value;
  LineNo := FCurrent.Line;
  Next;

  while FCurrent.Kind = tkWord do
  begin
    AppendArg(Args, FCurrent.Value);
    Next;
  end;

  Result := TRomitterDirective.Create(Name, Args, FSourceName, LineNo);

  if FCurrent.Kind = tkSemicolon then
  begin
    Next;
    Exit;
  end;

  if FCurrent.Kind <> tkLBrace then
    raise ERomitterConfigParser.CreateFmt(
      '%s(%d,%d): expected ";" or "{", got "%s"',
      [FSourceName, FCurrent.Line, FCurrent.Column, FCurrent.Value]);

  Next;
  ParseDirectiveList(Result.Children, True);
  Expect(tkRBrace);
  Next;
end;

procedure TRomitterConfigParser.ParseDirectiveList(
  const Target: TObjectList<TRomitterDirective>; const StopAtRBrace: Boolean);
var
  Directive: TRomitterDirective;
begin
  while FCurrent.Kind <> tkEOF do
  begin
    if (FCurrent.Kind = tkRBrace) and StopAtRBrace then
      Exit;

    Directive := ParseDirective;
    Target.Add(Directive);
  end;

  if StopAtRBrace then
    raise ERomitterConfigParser.CreateFmt(
      '%s(%d,%d): missing closing "}"',
      [FSourceName, FCurrent.Line, FCurrent.Column]);
end;

class function TRomitterConfigParser.ParseFile(
  const FileName: string): TRomitterConfigAst;
var
  Parser: TRomitterConfigParser;
  Content: string;
begin
  Content := TFile.ReadAllText(FileName, TEncoding.UTF8);
  Parser := TRomitterConfigParser.Create(Content, FileName);
  try
    Result := Parser.Parse;
  finally
    Parser.Free;
  end;
end;

end.
