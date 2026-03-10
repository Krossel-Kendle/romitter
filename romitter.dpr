program romitter;

{$APPTYPE CONSOLE}

{$R *.res}

uses
  System.SysUtils,
  Romitter.App in 'src\Romitter.App.pas',
  Romitter.Config.Ast in 'src\Romitter.Config.Ast.pas',
  Romitter.Config.Lexer in 'src\Romitter.Config.Lexer.pas',
  Romitter.Config.Loader in 'src\Romitter.Config.Loader.pas',
  Romitter.Config.Model in 'src\Romitter.Config.Model.pas',
  Romitter.Config.Parser in 'src\Romitter.Config.Parser.pas',
  Romitter.Control in 'src\Romitter.Control.pas',
  Romitter.Constants in 'src\Romitter.Constants.pas',
  Romitter.HttpServer in 'src\Romitter.HttpServer.pas',
  Romitter.Logging in 'src\Romitter.Logging.pas',
  Romitter.Master in 'src\Romitter.Master.pas',
  Romitter.OpenSsl in 'src\Romitter.OpenSsl.pas',
  Romitter.StreamServer in 'src\Romitter.StreamServer.pas',
  Romitter.Worker in 'src\Romitter.Worker.pas',
  Romitter.Utils in 'src\Romitter.Utils.pas';

var
  App: TRomitterApplication;
  ExitCodeValue: Integer;
begin
  App := nil;
  try
    App := TRomitterApplication.Create;
    try
      ExitCodeValue := App.Run;
    finally
      App.Free;
    end;

    Halt(ExitCodeValue);
  except
    on E: Exception do
    begin
      Writeln(E.ClassName, ': ', E.Message);
      Halt(1);
    end;
  end;
end.
