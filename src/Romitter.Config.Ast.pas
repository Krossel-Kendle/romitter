unit Romitter.Config.Ast;

interface

uses
  System.Generics.Collections;

type
  TRomitterDirective = class
  private
    FName: string;
    FArgs: TArray<string>;
    FChildren: TObjectList<TRomitterDirective>;
    FSourceFile: string;
    FLine: Integer;
  public
    constructor Create(const Name: string; const Args: TArray<string>;
      const SourceFile: string; const Line: Integer);
    destructor Destroy; override;
    property Name: string read FName;
    property Args: TArray<string> read FArgs;
    property Children: TObjectList<TRomitterDirective> read FChildren;
    property SourceFile: string read FSourceFile;
    property Line: Integer read FLine;
  end;

  TRomitterConfigAst = class
  private
    FDirectives: TObjectList<TRomitterDirective>;
  public
    constructor Create;
    destructor Destroy; override;
    property Directives: TObjectList<TRomitterDirective> read FDirectives;
  end;

implementation

constructor TRomitterDirective.Create(const Name: string;
  const Args: TArray<string>; const SourceFile: string; const Line: Integer);
begin
  inherited Create;
  FName := Name;
  FArgs := Args;
  FSourceFile := SourceFile;
  FLine := Line;
  FChildren := TObjectList<TRomitterDirective>.Create(True);
end;

destructor TRomitterDirective.Destroy;
begin
  FChildren.Free;
  inherited;
end;

constructor TRomitterConfigAst.Create;
begin
  inherited Create;
  FDirectives := TObjectList<TRomitterDirective>.Create(True);
end;

destructor TRomitterConfigAst.Destroy;
begin
  FDirectives.Free;
  inherited;
end;

end.
