unit Romitter.App;

interface

uses
  System.SysUtils,
  Winapi.Windows,
  Romitter.Control,
  Romitter.Master;

type
  TRomitterCommand = (rcRun, rcHelp, rcVersion, rcTestConfig, rcDumpConfig, rcSignal, rcWorker);

  TRomitterApplication = class
  private
    class var GInstance: TRomitterApplication;
  private
    FCommand: TRomitterCommand;
    FConfigPath: string;
    FPrefix: string;
    FSignal: TRomitterSignal;
    FWorkerId: Integer;
    FWorkerQuitEventName: string;
    FWorkerStopEventName: string;
    FWorkerReadyEventName: string;
    FWorkerParentPid: Cardinal;
    FMaster: TRomitterMaster;
    procedure ParseCommandLine;
    procedure PrintUsage;
    procedure PrintVersion;
    function ValidateConfig(const DumpAst: Boolean): Integer;
    function RunServer: Integer;
    function SendSignalCommand: Integer;
    function RunWorker: Integer;
    class function ConsoleHandler(CtrlType: DWORD): BOOL; stdcall; static;
  public
    constructor Create;
    destructor Destroy; override;
    function Run: Integer;
  end;

implementation

uses
  System.Classes,
  Romitter.Constants,
  Romitter.Config.Ast,
  Romitter.Config.Model,
  Romitter.Config.Loader,
  Romitter.Worker;

constructor TRomitterApplication.Create;
begin
  inherited;
  FCommand := rcRun;
  FConfigPath := ROMITTER_DEFAULT_CONFIG_FILE;
  FPrefix := '';
  FSignal := rsNone;
  FWorkerId := 0;
  FWorkerQuitEventName := '';
  FWorkerStopEventName := '';
  FWorkerReadyEventName := '';
  FWorkerParentPid := 0;
  FMaster := nil;
  GInstance := Self;
end;

destructor TRomitterApplication.Destroy;
begin
  if GInstance = Self then
    GInstance := nil;
  inherited;
end;

class function TRomitterApplication.ConsoleHandler(CtrlType: DWORD): BOOL;
begin
  Result := False;
  if not Assigned(GInstance) then
    Exit(False);

  case CtrlType of
    CTRL_C_EVENT,
    CTRL_BREAK_EVENT,
    CTRL_CLOSE_EVENT,
    CTRL_SHUTDOWN_EVENT:
      begin
        if Assigned(GInstance.FMaster) then
          GInstance.FMaster.RequestSignal(rsQuit);
        Result := True;
      end;
  end;
end;

procedure TRomitterApplication.ParseCommandLine;
var
  I: Integer;
  Param: string;
  SignalName: string;
  ParsedWorkerId: Integer;
  ParsedParentPid: Int64;
begin
  I := 1;
  while I <= ParamCount do
  begin
    Param := ParamStr(I);
    if SameText(Param, '--worker') then
    begin
      FCommand := rcWorker;
      Inc(I);
      Continue;
    end;

    if SameText(Param, '--worker-id') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option --worker-id requires a value');
      Inc(I);
      if not TryStrToInt(ParamStr(I), ParsedWorkerId) then
        raise Exception.CreateFmt('Invalid --worker-id value: %s', [ParamStr(I)]);
      if ParsedWorkerId < 0 then
        raise Exception.CreateFmt('--worker-id must be >= 0: %s', [ParamStr(I)]);
      FWorkerId := ParsedWorkerId;
      Inc(I);
      Continue;
    end;

    if SameText(Param, '--worker-quit-event') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option --worker-quit-event requires a value');
      Inc(I);
      FWorkerQuitEventName := ParamStr(I);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '--worker-stop-event') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option --worker-stop-event requires a value');
      Inc(I);
      FWorkerStopEventName := ParamStr(I);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '--worker-ready-event') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option --worker-ready-event requires a value');
      Inc(I);
      FWorkerReadyEventName := ParamStr(I);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '--worker-parent-pid') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option --worker-parent-pid requires a value');
      Inc(I);
      if (not TryStrToInt64(ParamStr(I), ParsedParentPid)) or
         (ParsedParentPid < 0) or
         (ParsedParentPid > High(Cardinal)) then
        raise Exception.CreateFmt(
          'Invalid --worker-parent-pid value: %s',
          [ParamStr(I)]);
      FWorkerParentPid := Cardinal(ParsedParentPid);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '-h') or SameText(Param, '-?') then
    begin
      FCommand := rcHelp;
      Exit;
    end;

    if SameText(Param, '-v') or SameText(Param, '-V') then
    begin
      FCommand := rcVersion;
      Exit;
    end;

    if SameText(Param, '-t') then
    begin
      FCommand := rcTestConfig;
      Inc(I);
      Continue;
    end;

    if SameText(Param, '-T') then
    begin
      FCommand := rcDumpConfig;
      Inc(I);
      Continue;
    end;

    if SameText(Param, '-c') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option -c requires a value');
      Inc(I);
      FConfigPath := ParamStr(I);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '-p') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option -p requires a value');
      Inc(I);
      FPrefix := ParamStr(I);
      Inc(I);
      Continue;
    end;

    if SameText(Param, '-s') then
    begin
      if I = ParamCount then
        raise Exception.Create('Option -s requires a signal');
      Inc(I);
      SignalName := ParamStr(I);
      if not TryParseSignal(SignalName, FSignal) then
        raise Exception.CreateFmt(
          'Unsupported signal "%s". Expected: stop, quit, reload',
          [SignalName]);
      FCommand := rcSignal;
      Inc(I);
      Continue;
    end;

    raise Exception.CreateFmt('Unknown argument: %s', [Param]);
  end;
end;

function TRomitterApplication.RunWorker: Integer;
var
  Worker: TRomitterWorker;
begin
  Worker := TRomitterWorker.Create(
    FConfigPath,
    FPrefix,
    FWorkerId,
    FWorkerQuitEventName,
    FWorkerStopEventName,
    FWorkerReadyEventName,
    FWorkerParentPid);
  try
    Result := Worker.Run;
  finally
    Worker.Free;
  end;
end;

procedure TRomitterApplication.PrintUsage;
begin
  Writeln('romitter - Windows-native nginx-inspired server (Delphi)');
  Writeln;
  Writeln('Usage:');
  Writeln('  romitter [-c file] [-p prefix]');
  Writeln('  romitter -t [-c file] [-p prefix]');
  Writeln('  romitter -T [-c file] [-p prefix]');
  Writeln('  romitter -s signal [-c file] [-p prefix]');
  Writeln('  romitter -v');
  Writeln;
  Writeln('Options:');
  Writeln('  -c file   set configuration file');
  Writeln('  -p path   set prefix path');
  Writeln('  -t        test configuration and exit');
  Writeln('  -T        test configuration and dump expanded config');
  Writeln('  -s signal send signal to master (stop|quit|reload)');
  Writeln('  -v        print version and exit');
  Writeln('  -h        show help');
end;

procedure TRomitterApplication.PrintVersion;
begin
  Writeln(Format('%s/%s', [ROMITTER_NAME, ROMITTER_VERSION]));
end;

function TRomitterApplication.SendSignalCommand: Integer;
var
  ErrorText: string;
begin
  if not SendSignalToMaster(FPrefix, FConfigPath, FSignal, ErrorText) then
  begin
    Writeln('failed to send signal: ' + ErrorText);
    Exit(1);
  end;

  Writeln(Format('signal "%s" sent successfully',
    [SignalToText(FSignal)]));
  Result := 0;
end;

function TRomitterApplication.ValidateConfig(const DumpAst: Boolean): Integer;
var
  Ast: TRomitterConfigAst;
  Model: TRomitterConfig;
  Lines: TStringList;
  Line: string;
begin
  Result := 1;
  Ast := nil;
  Model := nil;
  try
    Ast := TRomitterConfigLoader.LoadExpandedAst(FConfigPath, FPrefix);
    Model := TRomitterConfigLoader.LoadFromFile(FConfigPath, FPrefix);

    if DumpAst then
    begin
      Lines := TStringList.Create;
      try
        TRomitterConfigLoader.DumpAst(Ast, Lines);
        for Line in Lines do
          Writeln(Line);
      finally
        Lines.Free;
      end;
    end;

    Writeln('configuration test is successful');
    Result := 0;
  except
    on E: Exception do
    begin
      Writeln('configuration test failed: ' + E.Message);
      Result := 1;
    end;
  end;
  Ast.Free;
  Model.Free;
end;

function TRomitterApplication.RunServer: Integer;
begin
  FMaster := TRomitterMaster.Create(FConfigPath, FPrefix);
  try
    if not SetConsoleCtrlHandler(@ConsoleHandler, True) then
      raise Exception.Create('Failed to register console handler');
    Result := FMaster.Run;
  finally
    SetConsoleCtrlHandler(@ConsoleHandler, False);
    FreeAndNil(FMaster);
  end;
end;

function TRomitterApplication.Run: Integer;
begin
  ParseCommandLine;
  case FCommand of
    rcHelp:
      begin
        PrintUsage;
        Exit(0);
      end;
    rcVersion:
      begin
        PrintVersion;
        Exit(0);
      end;
    rcTestConfig:
      Exit(ValidateConfig(False));
    rcDumpConfig:
      Exit(ValidateConfig(True));
    rcSignal:
      Exit(SendSignalCommand);
    rcWorker:
      Exit(RunWorker);
  else
    Exit(RunServer);
  end;
end;

end.
