unit Romitter.Config.Loader;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Romitter.Config.Ast,
  Romitter.Config.Model;

type
  ERomitterConfig = class(Exception);

  TRomitterConfigLoader = class
  private
    class procedure ExpandIncludes(const Directives: TObjectList<TRomitterDirective>;
      const BaseDir: string); static;
    class function ResolveIncludeFiles(const BaseDir, Pattern: string): TArray<string>; static;
    class function ParseMainFile(const FileName, Prefix: string): string; static;
    class procedure ApplyTopLevel(const Directives: TObjectList<TRomitterDirective>;
      const Config: TRomitterConfig); static;
    class procedure ApplyEvents(const Directive: TRomitterDirective;
      const Config: TRomitterConfig); static;
    class procedure ApplyHttp(const Directive: TRomitterDirective;
      const Config: TRomitterConfig); static;
    class procedure ApplyStream(const Directive: TRomitterDirective;
      const Config: TRomitterConfig); static;
    class procedure ApplyUpstreamInContext(const Directive: TRomitterDirective;
      const Upstreams: TObjectList<TRomitterUpstreamConfig>;
      const ContextName: string); static;
    class procedure ApplyServer(const Directive: TRomitterDirective;
      const Config: TRomitterConfig); static;
    class procedure ApplyStreamServer(const Directive: TRomitterDirective;
      const Config: TRomitterConfig); static;
    class procedure ApplyLocation(const Directive: TRomitterDirective;
      const Server: TRomitterServerConfig; const Config: TRomitterConfig); static;
    class function FindUpstreamInList(const Upstreams: TObjectList<TRomitterUpstreamConfig>;
      const Name: string): TRomitterUpstreamConfig; static;
    class function ParseInt(const Directive: TRomitterDirective; const Value: string;
      const Description: string): Integer; static;
    class function ParseSizeBytes(const Directive: TRomitterDirective;
      const Value: string; const Description: string): Int64; static;
    class function ParseDurationMs(const Directive: TRomitterDirective;
      const Value: string; const Description: string): Integer; static;
    class procedure ParseProxyRedirectDirective(
      const Directive: TRomitterDirective; out IsOff, IsDefault: Boolean;
      out FromValue, ToValue: string); static;
    class procedure ParseReturnDirective(
      const Directive: TRomitterDirective; out StatusCode: Integer;
      out BodyTemplate: string); static;
    class function ParseErrorPageDirective(
      const Directive: TRomitterDirective): TRomitterErrorPageConfig; static;
    class procedure EnsureDefaultServer(const Config: TRomitterConfig); static;
    class function ResolveRuntimePath(const Config: TRomitterConfig;
      const Value: string): string; static;
    class function IsPathRootedPattern(const Value: string): Boolean; static;
    class function IsWildcardPattern(const Pattern: string): Boolean; static;
    class function JoinArgs(const Args: TArray<string>; const StartIndex: Integer): string; static;
  public
    class function LoadExpandedAst(const FileName, Prefix: string): TRomitterConfigAst; static;
    class function LoadFromFile(const FileName, Prefix: string): TRomitterConfig; static;
    class procedure DumpAst(const Ast: TRomitterConfigAst; const Output: TStrings); static;
  end;

implementation

uses
  System.IOUtils,
  System.StrUtils,
  System.RegularExpressions,
  System.Generics.Defaults,
  Romitter.Config.Parser,
  Romitter.Utils;

class function TRomitterConfigLoader.IsWildcardPattern(
  const Pattern: string): Boolean;
begin
  Result := (Pos('*', Pattern) > 0) or (Pos('?', Pattern) > 0);
end;

class function TRomitterConfigLoader.IsPathRootedPattern(
  const Value: string): Boolean;
begin
  Result := False;
  if Value = '' then
    Exit(False);

  if (Length(Value) >= 2) and (Value[2] = ':') then
    Exit(True);

  if ((Length(Value) >= 2) and
      (((Value[1] = '\') and (Value[2] = '\')) or
       ((Value[1] = '/') and (Value[2] = '/')))) or
     ((Value[1] = '\') or (Value[1] = '/')) then
    Exit(True);
end;

class function TRomitterConfigLoader.JoinArgs(const Args: TArray<string>;
  const StartIndex: Integer): string;
var
  I: Integer;
begin
  Result := '';
  for I := StartIndex to High(Args) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + Args[I];
  end;
end;

class function TRomitterConfigLoader.FindUpstreamInList(
  const Upstreams: TObjectList<TRomitterUpstreamConfig>;
  const Name: string): TRomitterUpstreamConfig;
var
  Upstream: TRomitterUpstreamConfig;
begin
  for Upstream in Upstreams do
    if SameText(Upstream.Name, Name) then
      Exit(Upstream);
  Result := nil;
end;

class function TRomitterConfigLoader.LoadExpandedAst(const FileName,
  Prefix: string): TRomitterConfigAst;
var
  MainFile: string;
begin
  MainFile := ParseMainFile(FileName, Prefix);
  Result := TRomitterConfigParser.ParseFile(MainFile);
  ExpandIncludes(Result.Directives, TPath.GetDirectoryName(MainFile));
end;

class function TRomitterConfigLoader.LoadFromFile(const FileName,
  Prefix: string): TRomitterConfig;
var
  Ast: TRomitterConfigAst;
begin
  Ast := LoadExpandedAst(FileName, Prefix);
  try
    Result := TRomitterConfig.Create;
    try
      if Prefix <> '' then
        Result.Prefix := TPath.GetFullPath(Prefix)
      else
        Result.Prefix := TPath.GetDirectoryName(ParseMainFile(FileName, Prefix));
      ApplyTopLevel(Ast.Directives, Result);
      EnsureDefaultServer(Result);
    except
      Result.Free;
      raise;
    end;
  finally
    Ast.Free;
  end;
end;

class function TRomitterConfigLoader.ParseMainFile(const FileName,
  Prefix: string): string;
var
  BaseDir: string;
begin
  if Prefix <> '' then
    BaseDir := Prefix
  else
    BaseDir := GetCurrentDir;

  Result := ResolvePath(BaseDir, FileName);
  if not FileExists(Result) then
    raise ERomitterConfig.CreateFmt('Config file not found: %s', [Result]);
end;

class procedure TRomitterConfigLoader.ExpandIncludes(
  const Directives: TObjectList<TRomitterDirective>; const BaseDir: string);
var
  I: Integer;
  J: Integer;
  Files: TArray<string>;
  IncludeAst: TRomitterConfigAst;
  IncludedDirective: TRomitterDirective;
  Directive: TRomitterDirective;
begin
  I := 0;
  while I < Directives.Count do
  begin
    Directive := Directives[I];
    if SameText(Directive.Name, 'include') then
    begin
      if Length(Directive.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): include requires exactly one argument',
          [Directive.SourceFile, Directive.Line]);

      Files := ResolveIncludeFiles(BaseDir, Directive.Args[0]);
      Directives.Delete(I);

      for J := 0 to High(Files) do
      begin
        IncludeAst := TRomitterConfigParser.ParseFile(Files[J]);
        try
          ExpandIncludes(IncludeAst.Directives, TPath.GetDirectoryName(Files[J]));
          while IncludeAst.Directives.Count > 0 do
          begin
            IncludedDirective := IncludeAst.Directives.Extract(IncludeAst.Directives[0]);
            Directives.Insert(I, IncludedDirective);
            Inc(I);
          end;
        finally
          IncludeAst.Free;
        end;
      end;

      Continue;
    end;

    if Directive.Children.Count > 0 then
      ExpandIncludes(Directive.Children, BaseDir);
    Inc(I);
  end;
end;

class function TRomitterConfigLoader.ResolveIncludeFiles(const BaseDir,
  Pattern: string): TArray<string>;
var
  FullPattern: string;
  NormalizedPattern: string;
  SearchDir: string;
  Search: TSearchRec;
  List: TList<string>;
  Res: Integer;
  SearchStarted: Boolean;
begin
  NormalizedPattern := StringReplace(
    Pattern,
    '/',
    PathDelim,
    [rfReplaceAll]);
  if IsWildcardPattern(NormalizedPattern) then
  begin
    if IsPathRootedPattern(NormalizedPattern) then
      FullPattern := NormalizedPattern
    else
      FullPattern := IncludeTrailingPathDelimiter(BaseDir) + NormalizedPattern;
  end
  else
    FullPattern := ResolvePath(BaseDir, NormalizedPattern);
  List := TList<string>.Create;
  try
    if IsWildcardPattern(FullPattern) then
    begin
      SearchDir := ExtractFilePath(FullPattern);
      if SearchDir = '' then
        SearchDir := BaseDir;
      SearchDir := IncludeTrailingPathDelimiter(SearchDir);
      SearchStarted := False;
      Res := FindFirst(FullPattern, faAnyFile, Search);
      if Res = 0 then
      begin
        SearchStarted := True;
        try
          while Res = 0 do
          begin
            if (Search.Attr and faDirectory) = 0 then
              List.Add(SearchDir + Search.Name);
            Res := FindNext(Search);
          end;
        finally
          if SearchStarted then
            FindClose(Search);
        end;
      end;
    end
    else
    begin
      if not FileExists(FullPattern) then
        raise ERomitterConfig.CreateFmt('include file not found: %s', [FullPattern]);
      List.Add(FullPattern);
    end;

    List.Sort(TComparer<string>.Default);
    Result := List.ToArray;
  finally
    List.Free;
  end;
end;

class function TRomitterConfigLoader.ParseInt(const Directive: TRomitterDirective;
  const Value, Description: string): Integer;
begin
  if not TryStrToInt(Value, Result) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): invalid %s value "%s"',
      [Directive.SourceFile, Directive.Line, Description, Value]);
end;

class function TRomitterConfigLoader.ParseSizeBytes(
  const Directive: TRomitterDirective; const Value: string;
  const Description: string): Int64;
var
  NumberPart: string;
  Multiplier: Int64;
  LastChar: Char;
begin
  NumberPart := Trim(Value);
  if NumberPart = '' then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): invalid %s value "%s"',
      [Directive.SourceFile, Directive.Line, Description, Value]);

  Multiplier := 1;
  LastChar := NumberPart[Length(NumberPart)];
  case LastChar of
    'k', 'K':
      begin
        Multiplier := 1024;
        Delete(NumberPart, Length(NumberPart), 1);
      end;
    'm', 'M':
      begin
        Multiplier := 1024 * 1024;
        Delete(NumberPart, Length(NumberPart), 1);
      end;
    'g', 'G':
      begin
        Multiplier := Int64(1024) * 1024 * 1024;
        Delete(NumberPart, Length(NumberPart), 1);
      end;
  end;

  NumberPart := Trim(NumberPart);
  if NumberPart = '' then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): invalid %s value "%s"',
      [Directive.SourceFile, Directive.Line, Description, Value]);

  if not TryStrToInt64(NumberPart, Result) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): invalid %s value "%s"',
      [Directive.SourceFile, Directive.Line, Description, Value]);
  if Result < 0 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): %s must be >= 0',
      [Directive.SourceFile, Directive.Line, Description]);
  if (Multiplier <> 1) and (Result > (High(Int64) div Multiplier)) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): %s value "%s" is too large',
      [Directive.SourceFile, Directive.Line, Description, Value]);
  Result := Result * Multiplier;
end;

class function TRomitterConfigLoader.ParseDurationMs(
  const Directive: TRomitterDirective; const Value, Description: string): Integer;
var
  NumberPart: string;
  Multiplier: Int64;
  ParsedValue: Int64;
begin
  Multiplier := 1000;
  NumberPart := Value;

  if EndsText('ms', Value) then
  begin
    Multiplier := 1;
    NumberPart := Copy(Value, 1, Length(Value) - 2);
  end
  else if EndsText('s', Value) then
  begin
    Multiplier := 1000;
    NumberPart := Copy(Value, 1, Length(Value) - 1);
  end
  else if EndsText('m', Value) then
  begin
    Multiplier := 60 * 1000;
    NumberPart := Copy(Value, 1, Length(Value) - 1);
  end
  else if EndsText('h', Value) then
  begin
    Multiplier := 60 * 60 * 1000;
    NumberPart := Copy(Value, 1, Length(Value) - 1);
  end
  else if EndsText('d', Value) then
  begin
    Multiplier := 24 * 60 * 60 * 1000;
    NumberPart := Copy(Value, 1, Length(Value) - 1);
  end;

  ParsedValue := ParseInt(Directive, NumberPart, Description);
  if ParsedValue < 0 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): %s must be >= 0',
      [Directive.SourceFile, Directive.Line, Description]);
  if ParsedValue > (High(Int64) div Multiplier) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): %s value "%s" is too large',
      [Directive.SourceFile, Directive.Line, Description, Value]);
  ParsedValue := ParsedValue * Multiplier;
  if ParsedValue > High(Integer) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): %s value "%s" exceeds supported range',
      [Directive.SourceFile, Directive.Line, Description, Value]);
  Result := Integer(ParsedValue);
end;

class procedure TRomitterConfigLoader.ParseProxyRedirectDirective(
  const Directive: TRomitterDirective; out IsOff, IsDefault: Boolean;
  out FromValue, ToValue: string);
begin
  if Length(Directive.Args) < 1 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): proxy_redirect requires arguments',
      [Directive.SourceFile, Directive.Line]);

  IsOff := False;
  IsDefault := False;
  FromValue := '';
  ToValue := '';

  if SameText(Directive.Args[0], 'off') then
  begin
    if Length(Directive.Args) <> 1 then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): proxy_redirect off does not accept extra arguments',
        [Directive.SourceFile, Directive.Line]);
    IsOff := True;
    Exit;
  end;

  if Length(Directive.Args) = 1 then
  begin
    if SameText(Directive.Args[0], 'default') then
      IsDefault := True
    else
      raise ERomitterConfig.CreateFmt(
        '%s(%d): proxy_redirect with one argument supports only "default"',
        [Directive.SourceFile, Directive.Line]);
    Exit;
  end;

  if Length(Directive.Args) = 2 then
  begin
    FromValue := Directive.Args[0];
    ToValue := Directive.Args[1];
    Exit;
  end;

  raise ERomitterConfig.CreateFmt(
    '%s(%d): proxy_redirect supports one or two arguments',
    [Directive.SourceFile, Directive.Line]);
end;

class procedure TRomitterConfigLoader.ParseReturnDirective(
  const Directive: TRomitterDirective; out StatusCode: Integer;
  out BodyTemplate: string);
begin
  if Length(Directive.Args) < 1 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): return requires at least one argument',
      [Directive.SourceFile, Directive.Line]);

  if Length(Directive.Args) = 1 then
  begin
    if TryStrToInt(Directive.Args[0], StatusCode) then
      BodyTemplate := ''
    else
    begin
      // nginx syntax: `return URL;` implies 302 redirect.
      StatusCode := 302;
      BodyTemplate := Directive.Args[0];
    end;
  end
  else
  begin
    StatusCode := ParseInt(Directive, Directive.Args[0], 'return status');
    BodyTemplate := JoinArgs(Directive.Args, 1);
  end;

  if (StatusCode < 0) or (StatusCode > 999) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): return status must be within 0..999',
      [Directive.SourceFile, Directive.Line]);
end;

class function TRomitterConfigLoader.ParseErrorPageDirective(
  const Directive: TRomitterDirective): TRomitterErrorPageConfig;
var
  UriValue: string;
  OverrideToken: string;
  OverrideStatus: Integer;
  LastCodeIndex: Integer;
  I: Integer;
  StatusCode: Integer;
  StatusCodes: TList<Integer>;
begin
  if Length(Directive.Args) < 2 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): error_page requires at least one code and URI',
      [Directive.SourceFile, Directive.Line]);

  UriValue := Directive.Args[High(Directive.Args)];
  if UriValue = '' then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): error_page URI must not be empty',
      [Directive.SourceFile, Directive.Line]);

  OverrideStatus := 0;
  LastCodeIndex := High(Directive.Args) - 1;
  if (LastCodeIndex >= 0) and StartsStr('=', Directive.Args[LastCodeIndex]) then
  begin
    OverrideToken := Trim(Copy(Directive.Args[LastCodeIndex], 2, MaxInt));
    Dec(LastCodeIndex);
    if OverrideToken <> '' then
    begin
      OverrideStatus := ParseInt(Directive, OverrideToken, 'error_page overwrite code');
      if (OverrideStatus < 100) or (OverrideStatus > 999) then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): error_page overwrite code must be within 100..999',
          [Directive.SourceFile, Directive.Line]);
    end;
  end;

  if LastCodeIndex < 0 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): error_page requires at least one status code',
      [Directive.SourceFile, Directive.Line]);

  StatusCodes := TList<Integer>.Create;
  try
    for I := 0 to LastCodeIndex do
    begin
      StatusCode := ParseInt(Directive, Directive.Args[I], 'error_page status code');
      if (StatusCode < 300) or (StatusCode > 599) then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): error_page status code must be within 300..599',
          [Directive.SourceFile, Directive.Line]);
      StatusCodes.Add(StatusCode);
    end;
    Result := TRomitterErrorPageConfig.Create(StatusCodes.ToArray, UriValue, OverrideStatus);
  finally
    StatusCodes.Free;
  end;
end;

class function TRomitterConfigLoader.ResolveRuntimePath(const Config: TRomitterConfig;
  const Value: string): string;
begin
  if SameText(Value, 'stderr') then
    Exit('stderr');
  Result := ResolvePath(Config.Prefix, Value);
end;

class procedure TRomitterConfigLoader.ApplyTopLevel(
  const Directives: TObjectList<TRomitterDirective>; const Config: TRomitterConfig);
var
  Directive: TRomitterDirective;
  Parsed: Integer;
begin
  for Directive in Directives do
  begin
    if SameText(Directive.Name, 'user') then
    begin
      if Length(Directive.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): user requires at least one argument',
          [Directive.SourceFile, Directive.Line]);
      Config.User := Directive.Args[0];
      Continue;
    end;

    if SameText(Directive.Name, 'worker_processes') then
    begin
      if Length(Directive.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): worker_processes requires one argument',
          [Directive.SourceFile, Directive.Line]);

      if SameText(Directive.Args[0], 'auto') then
        Config.WorkerProcesses := 0
      else
      begin
        Parsed := ParseInt(Directive, Directive.Args[0], 'worker_processes');
        if Parsed < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): worker_processes must be >= 1',
            [Directive.SourceFile, Directive.Line]);
        Config.WorkerProcesses := Parsed;
      end;
      Continue;
    end;

    if SameText(Directive.Name, 'worker_rlimit_nofile') then
    begin
      if Length(Directive.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): worker_rlimit_nofile requires one argument',
          [Directive.SourceFile, Directive.Line]);
      Parsed := ParseInt(Directive, Directive.Args[0], 'worker_rlimit_nofile');
      if Parsed < 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): worker_rlimit_nofile must be >= 0',
          [Directive.SourceFile, Directive.Line]);
      Config.WorkerRlimitNofile := Parsed;
      Continue;
    end;

    if SameText(Directive.Name, 'error_log') then
    begin
      if Length(Directive.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): error_log requires at least one argument',
          [Directive.SourceFile, Directive.Line]);
      if Length(Directive.Args) > 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): error_log supports at most file and level',
          [Directive.SourceFile, Directive.Line]);
      Config.ErrorLogFile := ResolveRuntimePath(Config, Directive.Args[0]);
      if Length(Directive.Args) = 2 then
      begin
        if (not SameText(Directive.Args[1], 'debug')) and
           (not SameText(Directive.Args[1], 'info')) and
           (not SameText(Directive.Args[1], 'notice')) and
           (not SameText(Directive.Args[1], 'warn')) and
           (not SameText(Directive.Args[1], 'error')) and
           (not SameText(Directive.Args[1], 'crit')) and
           (not SameText(Directive.Args[1], 'alert')) and
           (not SameText(Directive.Args[1], 'emerg')) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported error_log level "%s"',
            [Directive.SourceFile, Directive.Line, Directive.Args[1]]);
        Config.ErrorLogLevel := LowerCase(Directive.Args[1]);
      end;
      Continue;
    end;

    if SameText(Directive.Name, 'pid') then
    begin
      if Length(Directive.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): pid requires one argument',
          [Directive.SourceFile, Directive.Line]);
      Config.PidFile := ResolveRuntimePath(Config, Directive.Args[0]);
      Continue;
    end;

    if SameText(Directive.Name, 'events') then
    begin
      ApplyEvents(Directive, Config);
      Continue;
    end;

    if SameText(Directive.Name, 'http') then
    begin
      ApplyHttp(Directive, Config);
      Continue;
    end;

    if SameText(Directive.Name, 'stream') then
    begin
      ApplyStream(Directive, Config);
      Continue;
    end;

    raise ERomitterConfig.CreateFmt(
      '%s(%d): unsupported top-level directive "%s"',
      [Directive.SourceFile, Directive.Line, Directive.Name]);
  end;
end;

class procedure TRomitterConfigLoader.ApplyEvents(
  const Directive: TRomitterDirective; const Config: TRomitterConfig);
var
  Child: TRomitterDirective;
  Value: Integer;
begin
  for Child in Directive.Children do
  begin
    if SameText(Child.Name, 'worker_connections') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): worker_connections requires one argument',
          [Child.SourceFile, Child.Line]);
      Value := ParseInt(Child, Child.Args[0], 'worker_connections');
      if Value < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): worker_connections must be >= 1',
          [Child.SourceFile, Child.Line]);
      Config.Events.WorkerConnections := Value;
      Continue;
    end;

    if SameText(Child.Name, 'multi_accept') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): multi_accept requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Events.MultiAccept := True
      else if SameText(Child.Args[0], 'off') then
        Config.Events.MultiAccept := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): multi_accept must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    raise ERomitterConfig.CreateFmt(
      '%s(%d): unsupported directive "%s" in events',
      [Child.SourceFile, Child.Line, Child.Name]);
  end;
end;

class procedure TRomitterConfigLoader.ApplyHttp(const Directive: TRomitterDirective;
  const Config: TRomitterConfig);
var
  Child: TRomitterDirective;
  ConditionSet: TRomitterProxyNextUpstreamConditions;
  Option: string;
  ParsedSize: Int64;
  AddHeaderValue: string;
  AddHeaderAlways: Boolean;
  ValueEndIndex: Integer;
  I: Integer;
begin
  Config.Http.Enabled := True;
  for Child in Directive.Children do
  begin
    if SameText(Child.Name, 'types') then
    begin
      // types {} table is currently accepted for nginx config compatibility.
      Continue;
    end;

    if SameText(Child.Name, 'default_type') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): default_type requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.DefaultType := Child.Args[0];
      Continue;
    end;

    if SameText(Child.Name, 'server_names_hash_bucket_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): server_names_hash_bucket_size requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ServerNamesHashBucketSize := ParseInt(
        Child,
        Child.Args[0],
        'server_names_hash_bucket_size');
      if Config.Http.ServerNamesHashBucketSize < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): server_names_hash_bucket_size must be >= 1',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'sendfile') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): sendfile requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.SendFile := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.SendFile := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): sendfile must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'tcp_nopush') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): tcp_nopush requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.TcpNoPush := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.TcpNoPush := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): tcp_nopush must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'tcp_nodelay') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): tcp_nodelay requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.TcpNoDelay := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.TcpNoDelay := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): tcp_nodelay must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'keepalive_timeout') then
    begin
      if (Length(Child.Args) < 1) or (Length(Child.Args) > 2) then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): keepalive_timeout requires one or two arguments',
          [Child.SourceFile, Child.Line]);
      Config.Http.KeepAliveTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'keepalive_timeout');
      if Length(Child.Args) = 2 then
        ParseDurationMs(
          Child,
          Child.Args[1],
          'keepalive_timeout header_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'keepalive_requests') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): keepalive_requests requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.KeepAliveRequests := ParseInt(
        Child,
        Child.Args[0],
        'keepalive_requests');
      if Config.Http.KeepAliveRequests < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): keepalive_requests must be >= 1',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'client_max_body_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): client_max_body_size requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ClientMaxBodySize := ParseSizeBytes(
        Child,
        Child.Args[0],
        'client_max_body_size');
      Continue;
    end;

    if SameText(Child.Name, 'client_body_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): client_body_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ClientBodyTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'client_body_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'client_header_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): client_header_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ClientHeaderTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'client_header_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'send_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): send_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.SendTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
          'send_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'reset_timedout_connection') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): reset_timedout_connection requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ResetTimedoutConnection := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ResetTimedoutConnection := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): reset_timedout_connection must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'ignore_invalid_headers') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ignore_invalid_headers requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.IgnoreInvalidHeaders := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.IgnoreInvalidHeaders := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ignore_invalid_headers must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'server_tokens') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): server_tokens requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ServerTokens := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ServerTokens := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): server_tokens must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_certificate') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_certificate requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.SslCertificateFile := ResolveRuntimePath(Config, Child.Args[0]);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_certificate_key') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_certificate_key requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.SslCertificateKeyFile := ResolveRuntimePath(Config, Child.Args[0]);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_protocols') then
    begin
      if Length(Child.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_protocols requires arguments',
          [Child.SourceFile, Child.Line]);
      for I := 0 to High(Child.Args) do
        if (not SameText(Child.Args[I], 'TLSv1')) and
           (not SameText(Child.Args[I], 'TLSv1.1')) and
           (not SameText(Child.Args[I], 'TLSv1.2')) and
           (not SameText(Child.Args[I], 'TLSv1.3')) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported ssl_protocols value "%s"',
            [Child.SourceFile, Child.Line, Child.Args[I]]);
      SetLength(Config.Http.SslProtocols, Length(Child.Args));
      for I := 0 to High(Child.Args) do
        Config.Http.SslProtocols[I] := Child.Args[I];
      Continue;
    end;

    if SameText(Child.Name, 'ssl_ciphers') then
    begin
      if Length(Child.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_ciphers requires arguments',
          [Child.SourceFile, Child.Line]);
      Config.Http.SslCiphers := JoinArgs(Child.Args, 0);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_prefer_server_ciphers') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_prefer_server_ciphers requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.SslPreferServerCiphers := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.SslPreferServerCiphers := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_prefer_server_ciphers must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_session_cache') then
    begin
      if Length(Child.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_session_cache requires arguments',
          [Child.SourceFile, Child.Line]);
      Config.Http.SslSessionCache := JoinArgs(Child.Args, 0);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_session_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_session_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.SslSessionTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'ssl_session_timeout');
      if Config.Http.SslSessionTimeoutMs <= 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_session_timeout must be > 0',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'ssl_session_tickets') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_session_tickets requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.SslSessionTickets := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.SslSessionTickets := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl_session_tickets must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'open_file_cache_errors') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): open_file_cache_errors requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.OpenFileCacheErrors := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.OpenFileCacheErrors := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): open_file_cache_errors must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_set_header') then
    begin
      if Length(Child.Args) < 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_set_header requires header name and value',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxySetHeaders.AddOrSetValue(
        LowerCase(Child.Args[0]),
        JoinArgs(Child.Args, 1));
      Continue;
    end;

    if SameText(Child.Name, 'proxy_http_version') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_http_version requires one argument',
          [Child.SourceFile, Child.Line]);
      if Child.Args[0] = '1.0' then
        Config.Http.ProxyHttpVersion := phv10
      else if Child.Args[0] = '1.1' then
        Config.Http.ProxyHttpVersion := phv11
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_http_version must be 1.0 or 1.1',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_request_buffering') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_request_buffering requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ProxyRequestBuffering := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ProxyRequestBuffering := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_request_buffering must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_buffering') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_buffering requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ProxyBuffering := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ProxyBuffering := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_buffering must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_cache') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_cache requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxyCacheValue := Child.Args[0];
      Continue;
    end;

    if SameText(Child.Name, 'proxy_ssl_server_name') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_ssl_server_name requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ProxySslServerName := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ProxySslServerName := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_ssl_server_name must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_ssl_name') then
    begin
      if Length(Child.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_ssl_name requires arguments',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxySslName := JoinArgs(Child.Args, 0);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_ssl_verify') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_ssl_verify requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'on') then
        Config.Http.ProxySslVerify := True
      else if SameText(Child.Args[0], 'off') then
        Config.Http.ProxySslVerify := False
      else
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_ssl_verify must be on or off',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream_tries') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_tries requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxyNextUpstreamTries := ParseInt(
        Child,
        Child.Args[0],
        'proxy_next_upstream_tries');
      if Config.Http.ProxyNextUpstreamTries < 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_tries must be >= 0',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxyNextUpstreamTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_next_upstream_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream') then
    begin
      if Length(Child.Args) = 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream requires arguments',
          [Child.SourceFile, Child.Line]);

      if (Length(Child.Args) = 1) and SameText(Child.Args[0], 'off') then
      begin
        Config.Http.ProxyNextUpstream := [];
        Continue;
      end;

      ConditionSet := [];
      for Option in Child.Args do
      begin
        if SameText(Option, 'error') then
          Include(ConditionSet, pnucError)
        else if SameText(Option, 'timeout') then
          Include(ConditionSet, pnucTimeout)
        else if SameText(Option, 'invalid_header') then
          Include(ConditionSet, pnucInvalidHeader)
        else if SameText(Option, 'http_500') then
          Include(ConditionSet, pnucHttp500)
        else if SameText(Option, 'http_502') then
          Include(ConditionSet, pnucHttp502)
        else if SameText(Option, 'http_503') then
          Include(ConditionSet, pnucHttp503)
        else if SameText(Option, 'http_504') then
          Include(ConditionSet, pnucHttp504)
        else if SameText(Option, 'off') then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): "off" must be the only proxy_next_upstream argument',
            [Child.SourceFile, Child.Line])
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported proxy_next_upstream option "%s"',
            [Child.SourceFile, Child.Line, Option]);
      end;

      Config.Http.ProxyNextUpstream := ConditionSet;
      Continue;
    end;

    if SameText(Child.Name, 'proxy_connect_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_connect_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxyConnectTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_connect_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_read_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_read_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxyReadTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_read_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_send_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_send_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Http.ProxySendTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_send_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_buffer_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_buffer_size requires one argument',
          [Child.SourceFile, Child.Line]);
      ParsedSize := ParseSizeBytes(Child, Child.Args[0], 'proxy_buffer_size');
      if ParsedSize < 0 then
        ParsedSize := 0;
      Continue;
    end;

    if SameText(Child.Name, 'proxy_buffers') then
    begin
      if Length(Child.Args) <> 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_buffers requires two arguments',
          [Child.SourceFile, Child.Line]);
      ParseInt(Child, Child.Args[0], 'proxy_buffers number');
      ParseSizeBytes(Child, Child.Args[1], 'proxy_buffers size');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_busy_buffers_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_busy_buffers_size requires one argument',
          [Child.SourceFile, Child.Line]);
      ParseSizeBytes(Child, Child.Args[0], 'proxy_busy_buffers_size');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_temp_file_write_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_temp_file_write_size requires one argument',
          [Child.SourceFile, Child.Line]);
      ParseSizeBytes(Child, Child.Args[0], 'proxy_temp_file_write_size');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_max_temp_file_size') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_max_temp_file_size requires one argument',
          [Child.SourceFile, Child.Line]);
      if SameText(Child.Args[0], 'off') then
        Continue;
      ParseSizeBytes(Child, Child.Args[0], 'proxy_max_temp_file_size');
      Continue;
    end;

    if SameText(Child.Name, 'add_header') then
    begin
      if Length(Child.Args) < 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): add_header requires at least name and value',
          [Child.SourceFile, Child.Line]);
      AddHeaderAlways := False;
      ValueEndIndex := High(Child.Args);
      if (Length(Child.Args) >= 3) and SameText(Child.Args[ValueEndIndex], 'always') then
      begin
        AddHeaderAlways := True;
        Dec(ValueEndIndex);
      end;
      if ValueEndIndex < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): add_header value is missing',
          [Child.SourceFile, Child.Line]);
      AddHeaderValue := Child.Args[1];
      for I := 2 to ValueEndIndex do
        AddHeaderValue := AddHeaderValue + ' ' + Child.Args[I];
      Config.Http.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
        Child.Args[0],
        AddHeaderValue,
        AddHeaderAlways));
      Continue;
    end;

    if SameText(Child.Name, 'log_format') or
       SameText(Child.Name, 'access_log') or
       SameText(Child.Name, 'gzip') or
       SameText(Child.Name, 'charset') then
      Continue;

    if SameText(Child.Name, 'upstream') then
    begin
      ApplyUpstreamInContext(Child, Config.Http.Upstreams, 'http');
      Continue;
    end;

    if SameText(Child.Name, 'server') then
    begin
      ApplyServer(Child, Config);
      Continue;
    end;

    raise ERomitterConfig.CreateFmt(
      '%s(%d): unsupported directive "%s" in http',
      [Child.SourceFile, Child.Line, Child.Name]);
  end;
end;

class procedure TRomitterConfigLoader.ApplyStream(
  const Directive: TRomitterDirective; const Config: TRomitterConfig);
var
  Child: TRomitterDirective;
  ConditionSet: TRomitterProxyNextUpstreamConditions;
  Option: string;
begin
  Config.Stream.Enabled := True;
  for Child in Directive.Children do
  begin
    if SameText(Child.Name, 'access_log') then
    begin
      if Length(Child.Args) = 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): access_log requires arguments',
          [Child.SourceFile, Child.Line]);
      // stream access_log is accepted for nginx compatibility.
      Continue;
    end;

    if SameText(Child.Name, 'proxy_connect_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_connect_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxyConnectTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_connect_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxyReadTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_timeout');
      Config.Stream.ProxySendTimeoutMs := Config.Stream.ProxyReadTimeoutMs;
      Continue;
    end;

    if SameText(Child.Name, 'proxy_read_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_read_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxyReadTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_read_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_send_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_send_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxySendTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_send_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream_tries') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_tries requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxyNextUpstreamTries := ParseInt(
        Child,
        Child.Args[0],
        'proxy_next_upstream_tries');
      if Config.Stream.ProxyNextUpstreamTries < 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_tries must be >= 0',
          [Child.SourceFile, Child.Line]);
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream_timeout') then
    begin
      if Length(Child.Args) <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream_timeout requires one argument',
          [Child.SourceFile, Child.Line]);
      Config.Stream.ProxyNextUpstreamTimeoutMs := ParseDurationMs(
        Child,
        Child.Args[0],
        'proxy_next_upstream_timeout');
      Continue;
    end;

    if SameText(Child.Name, 'proxy_next_upstream') then
    begin
      if Length(Child.Args) = 0 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): proxy_next_upstream requires arguments',
          [Child.SourceFile, Child.Line]);

      if (Length(Child.Args) = 1) and SameText(Child.Args[0], 'off') then
      begin
        Config.Stream.ProxyNextUpstream := [];
        Continue;
      end;

      ConditionSet := [];
      for Option in Child.Args do
      begin
        if SameText(Option, 'error') then
          Include(ConditionSet, pnucError)
        else if SameText(Option, 'timeout') then
          Include(ConditionSet, pnucTimeout)
        else if SameText(Option, 'off') then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): "off" must be the only proxy_next_upstream argument',
            [Child.SourceFile, Child.Line])
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported stream proxy_next_upstream option "%s"',
            [Child.SourceFile, Child.Line, Option]);
      end;

      Config.Stream.ProxyNextUpstream := ConditionSet;
      Continue;
    end;

    if SameText(Child.Name, 'upstream') then
    begin
      ApplyUpstreamInContext(Child, Config.Stream.Upstreams, 'stream');
      Continue;
    end;

    if SameText(Child.Name, 'server') then
    begin
      ApplyStreamServer(Child, Config);
      Continue;
    end;

    raise ERomitterConfig.CreateFmt(
      '%s(%d): unsupported directive "%s" in stream',
      [Child.SourceFile, Child.Line, Child.Name]);
  end;
end;

class procedure TRomitterConfigLoader.ApplyUpstreamInContext(
  const Directive: TRomitterDirective;
  const Upstreams: TObjectList<TRomitterUpstreamConfig>;
  const ContextName: string);
var
  Upstream: TRomitterUpstreamConfig;
  Peer: TRomitterUpstreamPeer;
  Child: TRomitterDirective;
  Host: string;
  Port: Word;
  Weight: Integer;
  MaxFails: Integer;
  FailTimeoutMs: Integer;
  IsDown: Boolean;
  IsBackup: Boolean;
  I: Integer;
  Arg: string;
begin
  if Length(Directive.Args) <> 1 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): upstream requires one argument (name)',
      [Directive.SourceFile, Directive.Line]);

  if Assigned(FindUpstreamInList(Upstreams, Directive.Args[0])) then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): duplicate upstream name "%s" in %s',
      [Directive.SourceFile, Directive.Line, Directive.Args[0], ContextName]);

  Upstream := TRomitterUpstreamConfig.Create(Directive.Args[0]);
  try
    for Child in Directive.Children do
    begin
      if SameText(Child.Name, 'least_conn') then
      begin
        if Length(Child.Args) <> 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): least_conn does not accept arguments',
            [Child.SourceFile, Child.Line]);
        Upstream.LbMethod := ulbLeastConn;
        Continue;
      end;

      if SameText(Child.Name, 'ip_hash') then
      begin
        if Length(Child.Args) <> 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): ip_hash does not accept arguments',
            [Child.SourceFile, Child.Line]);
        Upstream.LbMethod := ulbIpHash;
        Continue;
      end;

      if not SameText(Child.Name, 'server') then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): unsupported directive "%s" in upstream',
          [Child.SourceFile, Child.Line, Child.Name]);

      if Length(Child.Args) < 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): upstream server requires host:port',
          [Child.SourceFile, Child.Line]);

      if not ParseHostPort(Child.Args[0], Host, Port, 80) then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): invalid upstream server "%s"',
          [Child.SourceFile, Child.Line, Child.Args[0]]);

      Weight := 1;
      MaxFails := 1;
      FailTimeoutMs := 10000;
      IsDown := False;
      IsBackup := False;
      for I := 1 to High(Child.Args) do
      begin
        Arg := Child.Args[I];
        if StartsText('weight=', Arg) then
        begin
          Weight := ParseInt(Child, Copy(Arg, Length('weight=') + 1, MaxInt), 'upstream weight');
          if Weight < 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): upstream weight must be >= 1',
              [Child.SourceFile, Child.Line]);
          Continue;
        end;

        if StartsText('max_fails=', Arg) then
        begin
          MaxFails := ParseInt(Child, Copy(Arg, Length('max_fails=') + 1, MaxInt), 'max_fails');
          if MaxFails < 0 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): max_fails must be >= 0',
              [Child.SourceFile, Child.Line]);
          Continue;
        end;

        if StartsText('fail_timeout=', Arg) then
        begin
          FailTimeoutMs := ParseDurationMs(
            Child,
            Copy(Arg, Length('fail_timeout=') + 1, MaxInt),
            'fail_timeout');
          Continue;
        end;

        if SameText(Arg, 'down') then
        begin
          IsDown := True;
          Continue;
        end;

        if SameText(Arg, 'backup') then
        begin
          IsBackup := True;
          Continue;
        end;

        raise ERomitterConfig.CreateFmt(
          '%s(%d): unsupported upstream server option "%s"',
          [Child.SourceFile, Child.Line, Arg]);
      end;

      Peer := TRomitterUpstreamPeer.Create(Host, Port, Weight);
      Peer.MaxFails := MaxFails;
      Peer.FailTimeoutMs := FailTimeoutMs;
      Peer.IsDown := IsDown;
      Peer.IsBackup := IsBackup;
      Upstream.Peers.Add(Peer);
    end;

    if Upstream.Peers.Count = 0 then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): upstream "%s" has no servers',
        [Directive.SourceFile, Directive.Line, Directive.Args[0]]);

    Upstreams.Add(Upstream);
    Upstream := nil;
  finally
    Upstream.Free;
  end;
end;

class procedure TRomitterConfigLoader.ApplyServer(
  const Directive: TRomitterDirective; const Config: TRomitterConfig);
var
  Server: TRomitterServerConfig;
  Listen: TRomitterHttpListenConfig;
  Child: TRomitterDirective;
  Host: string;
  Port: Word;
  I: Integer;
  Arg: string;
  IsDefaultServer: Boolean;
  IsSsl: Boolean;
  IsHttp2: Boolean;
  UsesProxyProtocol: Boolean;
  ExistingCount: Integer;
  RegexPattern: string;
  RegexOptions: TRegExOptions;
  ConditionSet: TRomitterProxyNextUpstreamConditions;
  Option: string;
  Pair: TPair<string, string>;
  ServerProxySetHeadersDefined: Boolean;
  ParsedSize: Int64;
  AddHeaderValue: string;
  AddHeaderAlways: Boolean;
  ValueEndIndex: Integer;
  ServerAddHeadersDefined: Boolean;
  ServerErrorPagesDefined: Boolean;
  InheritedAddHeader: TRomitterAddHeaderConfig;
  ParsedProxyRedirectOff: Boolean;
  ParsedProxyRedirectDefault: Boolean;
  ParsedProxyRedirectFrom: string;
  ParsedProxyRedirectTo: string;
  ParsedErrorPage: TRomitterErrorPageConfig;
begin
  Server := TRomitterServerConfig.Create;
  try
    for Pair in Config.Http.ProxySetHeaders do
      Server.ProxySetHeaders.AddOrSetValue(Pair.Key, Pair.Value);
    for InheritedAddHeader in Config.Http.AddHeaders do
      Server.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
        InheritedAddHeader.Name,
        InheritedAddHeader.Value,
        InheritedAddHeader.Always));
    Server.ProxyRequestBuffering := Config.Http.ProxyRequestBuffering;
    Server.ProxyBuffering := Config.Http.ProxyBuffering;
    Server.ProxyCacheValue := Config.Http.ProxyCacheValue;
    Server.ProxyHttpVersion := Config.Http.ProxyHttpVersion;
    Server.ProxySslServerName := Config.Http.ProxySslServerName;
    Server.ProxySslName := Config.Http.ProxySslName;
    Server.ProxySslVerify := Config.Http.ProxySslVerify;
    Server.ProxyConnectTimeoutMs := Config.Http.ProxyConnectTimeoutMs;
    Server.ProxyReadTimeoutMs := Config.Http.ProxyReadTimeoutMs;
    Server.ProxySendTimeoutMs := Config.Http.ProxySendTimeoutMs;
    Server.ProxyNextUpstream := Config.Http.ProxyNextUpstream;
    Server.ProxyNextUpstreamTries := Config.Http.ProxyNextUpstreamTries;
    Server.ProxyNextUpstreamTimeoutMs := Config.Http.ProxyNextUpstreamTimeoutMs;
    Server.DefaultType := Config.Http.DefaultType;
    Server.ServerTokens := Config.Http.ServerTokens;
    Server.SslCertificateFile := Config.Http.SslCertificateFile;
    Server.SslCertificateKeyFile := Config.Http.SslCertificateKeyFile;
    Server.SslProtocols := Copy(
      Config.Http.SslProtocols,
      0,
      Length(Config.Http.SslProtocols));
    Server.SslCiphers := Config.Http.SslCiphers;
    Server.SslPreferServerCiphers := Config.Http.SslPreferServerCiphers;
    Server.SslSessionCache := Config.Http.SslSessionCache;
    Server.SslSessionTimeoutMs := Config.Http.SslSessionTimeoutMs;
    Server.SslSessionTickets := Config.Http.SslSessionTickets;
    Server.ProxyRedirectOff := False;
    Server.ProxyRedirectDefault := False;
    Server.ProxyRedirectFrom := '';
    Server.ProxyRedirectTo := '';
    ServerProxySetHeadersDefined := False;
    ServerAddHeadersDefined := False;
    ServerErrorPagesDefined := False;

    for Child in Directive.Children do
    begin
      if SameText(Child.Name, 'listen') then
      begin
        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): listen requires at least one argument',
            [Child.SourceFile, Child.Line]);

        if not ParseHostPort(Child.Args[0], Host, Port, 80) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): invalid listen value "%s"',
            [Child.SourceFile, Child.Line, Child.Args[0]]);

        IsDefaultServer := False;
        IsSsl := False;
        IsHttp2 := False;
        UsesProxyProtocol := False;
        for I := 1 to High(Child.Args) do
        begin
          Arg := Child.Args[I];
          if SameText(Arg, 'default_server') or SameText(Arg, 'default') then
          begin
            IsDefaultServer := True;
            Continue;
          end;

          if SameText(Arg, 'ssl') then
          begin
            IsSsl := True;
            Continue;
          end;
          if SameText(Arg, 'http2') then
          begin
            IsHttp2 := True;
            Continue;
          end;
          if SameText(Arg, 'proxy_protocol') then
          begin
            UsesProxyProtocol := True;
            Continue;
          end;

          if SameText(Arg, 'bind') or
             SameText(Arg, 'reuseport') or
             SameText(Arg, 'deferred') or
             StartsText('backlog=', Arg) or
             StartsText('fastopen=', Arg) or
             StartsText('sndbuf=', Arg) or
             StartsText('rcvbuf=', Arg) or
             StartsText('so_keepalive=', Arg) then
            Continue;

          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported listen option "%s"',
            [Child.SourceFile, Child.Line, Arg]);
        end;

        Listen := TRomitterHttpListenConfig.Create(
          Host,
          Port,
          IsDefaultServer,
          IsSsl,
          IsHttp2,
          UsesProxyProtocol);
        Server.Listens.Add(Listen);
        if Server.Listens.Count = 1 then
        begin
          Server.ListenHost := Host;
          Server.ListenPort := Port;
        end;
        Continue;
      end;

      if SameText(Child.Name, 'server_name') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): server_name requires at least one argument',
            [Child.SourceFile, Child.Line]);

        for I := 0 to High(Child.Args) do
        begin
          Arg := Child.Args[I];
          if StartsText('~*', Arg) then
          begin
            RegexPattern := Trim(Copy(Arg, 3, MaxInt));
            RegexOptions := [roIgnoreCase];
          end
          else if StartsText('~', Arg) then
          begin
            RegexPattern := Trim(Copy(Arg, 2, MaxInt));
            RegexOptions := [];
          end
          else
            Continue;

          if RegexPattern = '' then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): invalid server_name regex "%s"',
              [Child.SourceFile, Child.Line, Arg]);

          try
            TRegEx.Create(RegexPattern, RegexOptions);
          except
            on E: Exception do
              raise ERomitterConfig.CreateFmt(
                '%s(%d): invalid server_name regex "%s": %s',
                [Child.SourceFile, Child.Line, Arg, E.Message]);
          end;
        end;

        ExistingCount := Length(Server.ServerNames);
        SetLength(Server.ServerNames, ExistingCount + Length(Child.Args));
        for I := 0 to High(Child.Args) do
          Server.ServerNames[ExistingCount + I] := Child.Args[I];
        Continue;
      end;

      if SameText(Child.Name, 'root') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): root requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.Root := ResolveRuntimePath(Config, Child.Args[0]);
        Continue;
      end;

      if SameText(Child.Name, 'index') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): index requires at least one argument',
            [Child.SourceFile, Child.Line]);
        SetLength(Server.IndexFiles, Length(Child.Args));
        for I := 0 to High(Child.Args) do
          Server.IndexFiles[I] := Child.Args[I];
        Continue;
      end;

      if SameText(Child.Name, 'default_type') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): default_type requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.DefaultType := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'server_tokens') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): server_tokens requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Server.ServerTokens := True
        else if SameText(Child.Args[0], 'off') then
          Server.ServerTokens := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): server_tokens must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'allow') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): allow requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.AccessRules.Add(TRomitterAccessRuleConfig.Create(
          True,
          Trim(Child.Args[0])));
        Continue;
      end;

      if SameText(Child.Name, 'deny') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): deny requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.AccessRules.Add(TRomitterAccessRuleConfig.Create(
          False,
          Trim(Child.Args[0])));
        Continue;
      end;

      if SameText(Child.Name, 'return') then
      begin
        ParseReturnDirective(Child, Server.ReturnCode, Server.ReturnBody);
        Continue;
      end;

      if SameText(Child.Name, 'client_max_body_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_max_body_size requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ClientMaxBodySize := ParseSizeBytes(
          Child,
          Child.Args[0],
          'client_max_body_size');
        Continue;
      end;

      if SameText(Child.Name, 'client_body_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_body_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ClientBodyTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'client_body_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'client_header_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_header_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ClientHeaderTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'client_header_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'send_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): send_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.SendTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'send_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'keepalive_timeout') then
      begin
        if (Length(Child.Args) < 1) or (Length(Child.Args) > 2) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): keepalive_timeout requires one or two arguments',
            [Child.SourceFile, Child.Line]);
        Server.KeepAliveTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'keepalive_timeout');
        if Length(Child.Args) = 2 then
          ParseDurationMs(
            Child,
            Child.Args[1],
            'keepalive_timeout header_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_set_header') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_set_header requires header name and value',
            [Child.SourceFile, Child.Line]);
        if not ServerProxySetHeadersDefined then
        begin
          Server.ProxySetHeaders.Clear;
          ServerProxySetHeadersDefined := True;
        end;
        Server.ProxySetHeaders.AddOrSetValue(
          LowerCase(Child.Args[0]),
          JoinArgs(Child.Args, 1));
        Continue;
      end;

      if SameText(Child.Name, 'proxy_http_version') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_http_version requires one argument',
            [Child.SourceFile, Child.Line]);
        if Child.Args[0] = '1.0' then
          Server.ProxyHttpVersion := phv10
        else if Child.Args[0] = '1.1' then
          Server.ProxyHttpVersion := phv11
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_http_version must be 1.0 or 1.1',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_request_buffering') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_request_buffering requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Server.ProxyRequestBuffering := True
        else if SameText(Child.Args[0], 'off') then
          Server.ProxyRequestBuffering := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_request_buffering must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffering') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffering requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Server.ProxyBuffering := True
        else if SameText(Child.Args[0], 'off') then
          Server.ProxyBuffering := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffering must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_cache') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_cache requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyCacheValue := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_server_name') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_server_name requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Server.ProxySslServerName := True
        else if SameText(Child.Args[0], 'off') then
          Server.ProxySslServerName := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_server_name must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_name') then
      begin
        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_name requires arguments',
            [Child.SourceFile, Child.Line]);
        Server.ProxySslName := JoinArgs(Child.Args, 0);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_verify') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_verify requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Server.ProxySslVerify := True
        else if SameText(Child.Args[0], 'off') then
          Server.ProxySslVerify := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_verify must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_tries') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyNextUpstreamTries := ParseInt(
          Child,
          Child.Args[0],
          'proxy_next_upstream_tries');
        if Server.ProxyNextUpstreamTries < 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries must be >= 0',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyNextUpstreamTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_next_upstream_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream requires arguments',
            [Child.SourceFile, Child.Line]);

        if (Length(Child.Args) = 1) and SameText(Child.Args[0], 'off') then
        begin
          Server.ProxyNextUpstream := [];
          Continue;
        end;

        ConditionSet := [];
        for Option in Child.Args do
        begin
          if SameText(Option, 'error') then
            Include(ConditionSet, pnucError)
          else if SameText(Option, 'timeout') then
            Include(ConditionSet, pnucTimeout)
          else if SameText(Option, 'invalid_header') then
            Include(ConditionSet, pnucInvalidHeader)
          else if SameText(Option, 'http_500') then
            Include(ConditionSet, pnucHttp500)
          else if SameText(Option, 'http_502') then
            Include(ConditionSet, pnucHttp502)
          else if SameText(Option, 'http_503') then
            Include(ConditionSet, pnucHttp503)
          else if SameText(Option, 'http_504') then
            Include(ConditionSet, pnucHttp504)
          else if SameText(Option, 'off') then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): "off" must be the only proxy_next_upstream argument',
              [Child.SourceFile, Child.Line])
          else
            raise ERomitterConfig.CreateFmt(
              '%s(%d): unsupported proxy_next_upstream option "%s"',
              [Child.SourceFile, Child.Line, Option]);
        end;

        Server.ProxyNextUpstream := ConditionSet;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_connect_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_connect_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyConnectTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_connect_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_read_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_read_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyReadTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_read_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_send_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_send_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxySendTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_send_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffer_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffer_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParsedSize := ParseSizeBytes(Child, Child.Args[0], 'proxy_buffer_size');
        if ParsedSize < 0 then
          ParsedSize := 0;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffers') then
      begin
        if Length(Child.Args) <> 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffers requires two arguments',
            [Child.SourceFile, Child.Line]);
        ParseInt(Child, Child.Args[0], 'proxy_buffers number');
        ParseSizeBytes(Child, Child.Args[1], 'proxy_buffers size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_busy_buffers_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_busy_buffers_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParseSizeBytes(Child, Child.Args[0], 'proxy_busy_buffers_size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_temp_file_write_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_temp_file_write_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParseSizeBytes(Child, Child.Args[0], 'proxy_temp_file_write_size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_max_temp_file_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_max_temp_file_size requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'off') then
          Continue;
        ParseSizeBytes(Child, Child.Args[0], 'proxy_max_temp_file_size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_redirect') then
      begin
        ParseProxyRedirectDirective(
          Child,
          ParsedProxyRedirectOff,
          ParsedProxyRedirectDefault,
          ParsedProxyRedirectFrom,
          ParsedProxyRedirectTo);
        Server.ProxyRedirectOff := ParsedProxyRedirectOff;
        Server.ProxyRedirectDefault := ParsedProxyRedirectDefault;
        Server.ProxyRedirectFrom := ParsedProxyRedirectFrom;
        Server.ProxyRedirectTo := ParsedProxyRedirectTo;
        Continue;
      end;

      if SameText(Child.Name, 'add_header') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): add_header requires at least name and value',
            [Child.SourceFile, Child.Line]);
        if not ServerAddHeadersDefined then
        begin
          Server.AddHeaders.Clear;
          ServerAddHeadersDefined := True;
        end;
        AddHeaderAlways := False;
        ValueEndIndex := High(Child.Args);
        if (Length(Child.Args) >= 3) and SameText(Child.Args[ValueEndIndex], 'always') then
        begin
          AddHeaderAlways := True;
          Dec(ValueEndIndex);
        end;
        if ValueEndIndex < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): add_header value is missing',
            [Child.SourceFile, Child.Line]);
        AddHeaderValue := Child.Args[1];
        for I := 2 to ValueEndIndex do
          AddHeaderValue := AddHeaderValue + ' ' + Child.Args[I];
        Server.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
          Child.Args[0],
          AddHeaderValue,
          AddHeaderAlways));
        Continue;
      end;

      if SameText(Child.Name, 'error_page') then
      begin
        if not ServerErrorPagesDefined then
        begin
          Server.ErrorPages.Clear;
          ServerErrorPagesDefined := True;
        end;
        ParsedErrorPage := ParseErrorPageDirective(Child);
        try
          Server.ErrorPages.Add(ParsedErrorPage);
          ParsedErrorPage := nil;
        finally
          ParsedErrorPage.Free;
        end;
        Continue;
      end;

      if SameText(Child.Name, 'ssl_certificate') or
         SameText(Child.Name, 'ssl_certificate_key') or
         SameText(Child.Name, 'ssl_protocols') or
         SameText(Child.Name, 'ssl_ciphers') or
         SameText(Child.Name, 'ssl_prefer_server_ciphers') or
         SameText(Child.Name, 'ssl_session_cache') or
         SameText(Child.Name, 'ssl_session_timeout') or
         SameText(Child.Name, 'ssl_session_tickets') then
      begin
        if SameText(Child.Name, 'ssl_certificate') then
        begin
          if Length(Child.Args) <> 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_certificate requires one argument',
              [Child.SourceFile, Child.Line]);
          Server.SslCertificateFile := ResolveRuntimePath(Config, Child.Args[0]);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_certificate_key') then
        begin
          if Length(Child.Args) <> 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_certificate_key requires one argument',
              [Child.SourceFile, Child.Line]);
          Server.SslCertificateKeyFile := ResolveRuntimePath(Config, Child.Args[0]);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_protocols') then
        begin
          if Length(Child.Args) < 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_protocols requires arguments',
              [Child.SourceFile, Child.Line]);
          for I := 0 to High(Child.Args) do
            if (not SameText(Child.Args[I], 'TLSv1')) and
               (not SameText(Child.Args[I], 'TLSv1.1')) and
               (not SameText(Child.Args[I], 'TLSv1.2')) and
               (not SameText(Child.Args[I], 'TLSv1.3')) then
              raise ERomitterConfig.CreateFmt(
                '%s(%d): unsupported ssl_protocols value "%s"',
                [Child.SourceFile, Child.Line, Child.Args[I]]);
          SetLength(Server.SslProtocols, Length(Child.Args));
          for I := 0 to High(Child.Args) do
            Server.SslProtocols[I] := Child.Args[I];
          Continue;
        end;

        if SameText(Child.Name, 'ssl_ciphers') then
        begin
          if Length(Child.Args) < 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_ciphers requires arguments',
              [Child.SourceFile, Child.Line]);
          Server.SslCiphers := JoinArgs(Child.Args, 0);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_prefer_server_ciphers') then
        begin
          if Length(Child.Args) <> 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_prefer_server_ciphers requires one argument',
              [Child.SourceFile, Child.Line]);
          if SameText(Child.Args[0], 'on') then
            Server.SslPreferServerCiphers := True
          else if SameText(Child.Args[0], 'off') then
            Server.SslPreferServerCiphers := False
          else
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_prefer_server_ciphers must be on or off',
              [Child.SourceFile, Child.Line]);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_session_cache') then
        begin
          if Length(Child.Args) < 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_session_cache requires arguments',
              [Child.SourceFile, Child.Line]);
          Server.SslSessionCache := JoinArgs(Child.Args, 0);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_session_timeout') then
        begin
          if Length(Child.Args) <> 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_session_timeout requires one argument',
              [Child.SourceFile, Child.Line]);
          Server.SslSessionTimeoutMs := ParseDurationMs(
            Child,
            Child.Args[0],
            'ssl_session_timeout');
          if Server.SslSessionTimeoutMs <= 0 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_session_timeout must be > 0',
              [Child.SourceFile, Child.Line]);
          Continue;
        end;

        if SameText(Child.Name, 'ssl_session_tickets') then
        begin
          if Length(Child.Args) <> 1 then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_session_tickets requires one argument',
              [Child.SourceFile, Child.Line]);
          if SameText(Child.Args[0], 'on') then
            Server.SslSessionTickets := True
          else if SameText(Child.Args[0], 'off') then
            Server.SslSessionTickets := False
          else
            raise ERomitterConfig.CreateFmt(
              '%s(%d): ssl_session_tickets must be on or off',
              [Child.SourceFile, Child.Line]);
          Continue;
        end;

        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): %s requires arguments',
            [Child.SourceFile, Child.Line, Child.Name]);
        Continue;
      end;

      if SameText(Child.Name, 'location') then
      begin
        ApplyLocation(Child, Server, Config);
        Continue;
      end;

      raise ERomitterConfig.CreateFmt(
        '%s(%d): unsupported directive "%s" in server',
        [Child.SourceFile, Child.Line, Child.Name]);
    end;

    for Listen in Server.Listens do
      if Listen.IsSsl and
         ((Trim(Server.SslCertificateFile) = '') or
          (Trim(Server.SslCertificateKeyFile) = '')) then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): ssl listen requires ssl_certificate and ssl_certificate_key in server',
          [Directive.SourceFile, Directive.Line]);

    Config.Http.Servers.Add(Server);
    Server := nil;
  finally
    Server.Free;
  end;
end;

class procedure TRomitterConfigLoader.ApplyStreamServer(
  const Directive: TRomitterDirective; const Config: TRomitterConfig);
var
  Server: TRomitterStreamServerConfig;
  Child: TRomitterDirective;
  Host: string;
  Port: Word;
  I: Integer;
  Arg: string;
  Option: string;
  ConditionSet: TRomitterProxyNextUpstreamConditions;
begin
  Server := TRomitterStreamServerConfig.Create;
  try
    Server.ProxyConnectTimeoutMs := Config.Stream.ProxyConnectTimeoutMs;
    Server.ProxyReadTimeoutMs := Config.Stream.ProxyReadTimeoutMs;
    Server.ProxySendTimeoutMs := Config.Stream.ProxySendTimeoutMs;
    Server.ProxyNextUpstream := Config.Stream.ProxyNextUpstream;
    Server.ProxyNextUpstreamTries := Config.Stream.ProxyNextUpstreamTries;
    Server.ProxyNextUpstreamTimeoutMs := Config.Stream.ProxyNextUpstreamTimeoutMs;

    for Child in Directive.Children do
    begin
      if SameText(Child.Name, 'listen') then
      begin
        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): listen requires at least one argument',
            [Child.SourceFile, Child.Line]);

        if (not ParseHostPort(Child.Args[0], Host, Port, 0)) or (Port = 0) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): invalid listen value "%s"',
            [Child.SourceFile, Child.Line, Child.Args[0]]);
        for I := 1 to High(Child.Args) do
        begin
          Arg := Child.Args[I];
          if SameText(Arg, 'udp') then
          begin
            Server.IsUdp := True;
            Continue;
          end;
          raise ERomitterConfig.CreateFmt(
            '%s(%d): unsupported stream listen option "%s"',
            [Child.SourceFile, Child.Line, Arg]);
        end;
        Server.ListenHost := Host;
        Server.ListenPort := Port;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_pass') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_pass requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyPass := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'proxy_connect_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_connect_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyConnectTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_connect_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyReadTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_timeout');
        Server.ProxySendTimeoutMs := Server.ProxyReadTimeoutMs;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_read_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_read_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyReadTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_read_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_send_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_send_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxySendTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_send_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_responses') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_responses requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyResponses := ParseInt(Child, Child.Args[0], 'proxy_responses');
        if Server.ProxyResponses < 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_responses must be >= 0',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_tries') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyNextUpstreamTries := ParseInt(
          Child,
          Child.Args[0],
          'proxy_next_upstream_tries');
        if Server.ProxyNextUpstreamTries < 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries must be >= 0',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Server.ProxyNextUpstreamTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_next_upstream_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream requires arguments',
            [Child.SourceFile, Child.Line]);

        if (Length(Child.Args) = 1) and SameText(Child.Args[0], 'off') then
        begin
          Server.ProxyNextUpstream := [];
          Continue;
        end;

        ConditionSet := [];
        for Option in Child.Args do
        begin
          if SameText(Option, 'error') then
            Include(ConditionSet, pnucError)
          else if SameText(Option, 'timeout') then
            Include(ConditionSet, pnucTimeout)
          else if SameText(Option, 'off') then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): "off" must be the only proxy_next_upstream argument',
              [Child.SourceFile, Child.Line])
          else
            raise ERomitterConfig.CreateFmt(
              '%s(%d): unsupported stream proxy_next_upstream option "%s"',
              [Child.SourceFile, Child.Line, Option]);
        end;

        Server.ProxyNextUpstream := ConditionSet;
        Continue;
      end;

      raise ERomitterConfig.CreateFmt(
        '%s(%d): unsupported directive "%s" in stream server',
        [Child.SourceFile, Child.Line, Child.Name]);
    end;

    if Server.ListenPort = 0 then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): stream server requires listen',
        [Directive.SourceFile, Directive.Line]);

    if Server.ProxyPass = '' then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): stream server requires proxy_pass',
        [Directive.SourceFile, Directive.Line]);
    if Server.IsUdp and StartsText('tcp://', Server.ProxyPass) then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): udp stream server cannot use tcp:// proxy_pass',
        [Directive.SourceFile, Directive.Line]);
    if (not Server.IsUdp) and StartsText('udp://', Server.ProxyPass) then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): tcp stream server cannot use udp:// proxy_pass',
        [Directive.SourceFile, Directive.Line]);

    Config.Stream.Servers.Add(Server);
    Server := nil;
  finally
    Server.Free;
  end;
end;

class procedure TRomitterConfigLoader.ApplyLocation(
  const Directive: TRomitterDirective; const Server: TRomitterServerConfig;
  const Config: TRomitterConfig);
var
  Location: TRomitterLocationConfig;
  Child: TRomitterDirective;
  ConditionSet: TRomitterProxyNextUpstreamConditions;
  Option: string;
  ArgCount: Integer;
  I: Integer;
  RegexOptions: TRegExOptions;
  ProxyPassWork: string;
  ProxyPassHasUriPart: Boolean;
  Pair: TPair<string, string>;
  LocationProxySetHeadersDefined: Boolean;
  ParsedSize: Int64;
  AddHeaderValue: string;
  AddHeaderAlways: Boolean;
  ValueEndIndex: Integer;
  LocationAddHeadersDefined: Boolean;
  LocationErrorPagesDefined: Boolean;
  InheritedAddHeader: TRomitterAddHeaderConfig;
  InheritedErrorPage: TRomitterErrorPageConfig;
  ParsedProxyRedirectOff: Boolean;
  ParsedProxyRedirectDefault: Boolean;
  ParsedProxyRedirectFrom: string;
  ParsedProxyRedirectTo: string;
  ParsedErrorPage: TRomitterErrorPageConfig;
  FastCgiParamValue: string;
  InheritedAccessRule: TRomitterAccessRuleConfig;
  LocationAccessRulesDefined: Boolean;
begin
  ArgCount := Length(Directive.Args);
  if ArgCount = 0 then
    raise ERomitterConfig.CreateFmt(
      '%s(%d): location requires arguments',
      [Directive.SourceFile, Directive.Line]);

  Location := TRomitterLocationConfig.Create;
  try
    for Pair in Server.ProxySetHeaders do
      Location.ProxySetHeaders.AddOrSetValue(Pair.Key, Pair.Value);
    for InheritedAddHeader in Server.AddHeaders do
      Location.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
        InheritedAddHeader.Name,
        InheritedAddHeader.Value,
        InheritedAddHeader.Always));
    for InheritedErrorPage in Server.ErrorPages do
      Location.ErrorPages.Add(TRomitterErrorPageConfig.Create(
        InheritedErrorPage.StatusCodes,
        InheritedErrorPage.Uri,
        InheritedErrorPage.OverrideStatus));
    for InheritedAccessRule in Server.AccessRules do
      Location.AccessRules.Add(TRomitterAccessRuleConfig.Create(
        InheritedAccessRule.IsAllow,
        InheritedAccessRule.RuleText));
    Location.ProxyRequestBuffering := Server.ProxyRequestBuffering;
    Location.ProxyBuffering := Server.ProxyBuffering;
    Location.ProxyCacheValue := Server.ProxyCacheValue;
    Location.ProxyHttpVersion := Server.ProxyHttpVersion;
    Location.ProxySslServerName := Server.ProxySslServerName;
    Location.ProxySslName := Server.ProxySslName;
    Location.ProxySslVerify := Server.ProxySslVerify;
    Location.ProxyConnectTimeoutMs := Server.ProxyConnectTimeoutMs;
    Location.ProxyReadTimeoutMs := Server.ProxyReadTimeoutMs;
    Location.ProxySendTimeoutMs := Server.ProxySendTimeoutMs;
    Location.ProxyNextUpstream := Server.ProxyNextUpstream;
    Location.ProxyNextUpstreamTries := Server.ProxyNextUpstreamTries;
    Location.ProxyNextUpstreamTimeoutMs := Server.ProxyNextUpstreamTimeoutMs;
    Location.DefaultType := Server.DefaultType;
    Location.ProxyRedirectOff := Server.ProxyRedirectOff;
    Location.ProxyRedirectDefault := Server.ProxyRedirectDefault;
    Location.ProxyRedirectFrom := Server.ProxyRedirectFrom;
    Location.ProxyRedirectTo := Server.ProxyRedirectTo;
    LocationProxySetHeadersDefined := False;
    LocationAddHeadersDefined := False;
    LocationErrorPagesDefined := False;
    LocationAccessRulesDefined := False;

    if Directive.Args[0] = '=' then
    begin
      if ArgCount <> 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location = requires exactly one URI argument',
          [Directive.SourceFile, Directive.Line]);
      Location.MatchKind := lmkExact;
      Location.MatchPath := Directive.Args[1];
    end
    else if Directive.Args[0] = '^~' then
    begin
      if ArgCount <> 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location ^~ requires exactly one URI argument',
          [Directive.SourceFile, Directive.Line]);
      Location.MatchKind := lmkPrefixNoRegex;
      Location.MatchPath := Directive.Args[1];
    end
    else if Directive.Args[0] = '~' then
    begin
      if ArgCount <> 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location ~ requires exactly one regex argument',
          [Directive.SourceFile, Directive.Line]);
      Location.MatchKind := lmkRegexCaseSensitive;
      Location.MatchPath := Directive.Args[1];
    end
    else if Directive.Args[0] = '~*' then
    begin
      if ArgCount <> 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location ~* requires exactly one regex argument',
          [Directive.SourceFile, Directive.Line]);
      Location.MatchKind := lmkRegexCaseInsensitive;
      Location.MatchPath := Directive.Args[1];
    end
    else if StartsStr('@', Directive.Args[0]) then
    begin
      if ArgCount <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): named location expects exactly one argument',
          [Directive.SourceFile, Directive.Line]);
      if Length(Directive.Args[0]) < 2 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): invalid named location "%s"',
          [Directive.SourceFile, Directive.Line, Directive.Args[0]]);
      Location.MatchKind := lmkNamed;
      Location.MatchPath := Directive.Args[0];
    end
    else
    begin
      if ArgCount <> 1 then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location prefix syntax expects one URI argument',
          [Directive.SourceFile, Directive.Line]);
      Location.MatchKind := lmkPrefix;
      Location.MatchPath := Directive.Args[0];
    end;

    if (Location.MatchKind = lmkRegexCaseSensitive) or
       (Location.MatchKind = lmkRegexCaseInsensitive) then
    begin
      if Trim(Location.MatchPath) = '' then
        raise ERomitterConfig.CreateFmt(
          '%s(%d): location regex pattern must not be empty',
          [Directive.SourceFile, Directive.Line]);

      if Location.MatchKind = lmkRegexCaseInsensitive then
        RegexOptions := [roIgnoreCase]
      else
        RegexOptions := [];
      try
        TRegEx.Create(Location.MatchPath, RegexOptions);
      except
        on E: Exception do
          raise ERomitterConfig.CreateFmt(
            '%s(%d): invalid location regex "%s": %s',
            [Directive.SourceFile, Directive.Line, Location.MatchPath, E.Message]);
      end;
    end;

    for Child in Directive.Children do
    begin
      if SameText(Child.Name, 'root') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): root requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.Root := ResolveRuntimePath(Config, Child.Args[0]);
        Continue;
      end;

      if SameText(Child.Name, 'alias') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): alias requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.AliasPath := ResolveRuntimePath(Config, Child.Args[0]);
        Continue;
      end;

      if SameText(Child.Name, 'index') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): index requires at least one argument',
            [Child.SourceFile, Child.Line]);
        SetLength(Location.IndexFiles, Length(Child.Args));
        for I := 0 to High(Child.Args) do
          Location.IndexFiles[I] := Child.Args[I];
        Continue;
      end;

      if SameText(Child.Name, 'default_type') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): default_type requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.DefaultType := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'allow') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): allow requires one argument',
            [Child.SourceFile, Child.Line]);
        if not LocationAccessRulesDefined then
        begin
          Location.AccessRules.Clear;
          LocationAccessRulesDefined := True;
        end;
        Location.AccessRules.Add(TRomitterAccessRuleConfig.Create(
          True,
          Trim(Child.Args[0])));
        Continue;
      end;

      if SameText(Child.Name, 'deny') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): deny requires one argument',
            [Child.SourceFile, Child.Line]);
        if not LocationAccessRulesDefined then
        begin
          Location.AccessRules.Clear;
          LocationAccessRulesDefined := True;
        end;
        Location.AccessRules.Add(TRomitterAccessRuleConfig.Create(
          False,
          Trim(Child.Args[0])));
        Continue;
      end;

      if SameText(Child.Name, 'proxy_pass') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_pass requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyPass := Child.Args[0];

        ProxyPassWork := '';
        if StartsText('http://', Location.ProxyPass) then
          ProxyPassWork := Copy(Location.ProxyPass, Length('http://') + 1, MaxInt)
        else if StartsText('https://', Location.ProxyPass) then
          ProxyPassWork := Copy(Location.ProxyPass, Length('https://') + 1, MaxInt);

        if ProxyPassWork <> '' then
        begin
          ProxyPassHasUriPart := Pos('/', ProxyPassWork) > 0;
          if ProxyPassHasUriPart and
             ((Location.MatchKind = lmkRegexCaseSensitive) or
              (Location.MatchKind = lmkRegexCaseInsensitive) or
              (Location.MatchKind = lmkNamed)) then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): proxy_pass with URI part is not allowed in regex or named locations',
              [Child.SourceFile, Child.Line]);
        end;

        Continue;
      end;

      if SameText(Child.Name, 'try_files') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): try_files requires at least two arguments',
            [Child.SourceFile, Child.Line]);
        SetLength(Location.TryFiles, Length(Child.Args));
        for I := 0 to High(Child.Args) do
          Location.TryFiles[I] := Child.Args[I];
        Continue;
      end;

      if SameText(Child.Name, 'rewrite') then
      begin
        if (Length(Child.Args) < 2) or (Length(Child.Args) > 3) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): rewrite requires pattern, replacement and optional flag',
            [Child.SourceFile, Child.Line]);
        Location.RewritePattern := Child.Args[0];
        Location.RewriteReplacement := Child.Args[1];
        if Length(Child.Args) = 3 then
        begin
          Option := LowerCase(Child.Args[2]);
          if (Option <> 'last') and
             (Option <> 'break') and
             (Option <> 'redirect') and
             (Option <> 'permanent') then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): unsupported rewrite flag "%s"',
              [Child.SourceFile, Child.Line, Child.Args[2]]);
          Location.RewriteFlag := Option;
        end
        else
          Location.RewriteFlag := '';
        Continue;
      end;

      if SameText(Child.Name, 'proxy_set_header') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_set_header requires header name and value',
            [Child.SourceFile, Child.Line]);
        if not LocationProxySetHeadersDefined then
        begin
          Location.ProxySetHeaders.Clear;
          LocationProxySetHeadersDefined := True;
        end;
        Location.ProxySetHeaders.AddOrSetValue(
          LowerCase(Child.Args[0]),
          JoinArgs(Child.Args, 1));
        Continue;
      end;

      if SameText(Child.Name, 'proxy_http_version') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_http_version requires one argument',
            [Child.SourceFile, Child.Line]);
        if Child.Args[0] = '1.0' then
          Location.ProxyHttpVersion := phv10
        else if Child.Args[0] = '1.1' then
          Location.ProxyHttpVersion := phv11
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_http_version must be 1.0 or 1.1',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_request_buffering') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_request_buffering requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Location.ProxyRequestBuffering := True
        else if SameText(Child.Args[0], 'off') then
          Location.ProxyRequestBuffering := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_request_buffering must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffering') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffering requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Location.ProxyBuffering := True
        else if SameText(Child.Args[0], 'off') then
          Location.ProxyBuffering := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffering must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_cache') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_cache requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyCacheValue := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_server_name') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_server_name requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Location.ProxySslServerName := True
        else if SameText(Child.Args[0], 'off') then
          Location.ProxySslServerName := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_server_name must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_name') then
      begin
        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_name requires arguments',
            [Child.SourceFile, Child.Line]);
        Location.ProxySslName := JoinArgs(Child.Args, 0);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_ssl_verify') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_verify requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'on') then
          Location.ProxySslVerify := True
        else if SameText(Child.Args[0], 'off') then
          Location.ProxySslVerify := False
        else
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_ssl_verify must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_tries') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyNextUpstreamTries := ParseInt(
          Child,
          Child.Args[0],
          'proxy_next_upstream_tries');
        if Location.ProxyNextUpstreamTries < 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_tries must be >= 0',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyNextUpstreamTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_next_upstream_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_next_upstream') then
      begin
        if Length(Child.Args) = 0 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_next_upstream requires arguments',
            [Child.SourceFile, Child.Line]);

        if (Length(Child.Args) = 1) and SameText(Child.Args[0], 'off') then
        begin
          Location.ProxyNextUpstream := [];
          Continue;
        end;

        ConditionSet := [];
        for Option in Child.Args do
        begin
          if SameText(Option, 'error') then
            Include(ConditionSet, pnucError)
          else if SameText(Option, 'timeout') then
            Include(ConditionSet, pnucTimeout)
          else if SameText(Option, 'invalid_header') then
            Include(ConditionSet, pnucInvalidHeader)
          else if SameText(Option, 'http_500') then
            Include(ConditionSet, pnucHttp500)
          else if SameText(Option, 'http_502') then
            Include(ConditionSet, pnucHttp502)
          else if SameText(Option, 'http_503') then
            Include(ConditionSet, pnucHttp503)
          else if SameText(Option, 'http_504') then
            Include(ConditionSet, pnucHttp504)
          else if SameText(Option, 'off') then
            raise ERomitterConfig.CreateFmt(
              '%s(%d): "off" must be the only proxy_next_upstream argument',
              [Child.SourceFile, Child.Line])
          else
            raise ERomitterConfig.CreateFmt(
              '%s(%d): unsupported proxy_next_upstream option "%s"',
              [Child.SourceFile, Child.Line, Option]);
        end;

        Location.ProxyNextUpstream := ConditionSet;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_connect_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_connect_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyConnectTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_connect_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_read_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_read_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxyReadTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_read_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_send_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_send_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ProxySendTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'proxy_send_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffer_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffer_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParsedSize := ParseSizeBytes(Child, Child.Args[0], 'proxy_buffer_size');
        if ParsedSize < 0 then
          ParsedSize := 0;
        Continue;
      end;

      if SameText(Child.Name, 'proxy_buffers') then
      begin
        if Length(Child.Args) <> 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_buffers requires two arguments',
            [Child.SourceFile, Child.Line]);
        ParseInt(Child, Child.Args[0], 'proxy_buffers number');
        ParseSizeBytes(Child, Child.Args[1], 'proxy_buffers size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_busy_buffers_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_busy_buffers_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParseSizeBytes(Child, Child.Args[0], 'proxy_busy_buffers_size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_temp_file_write_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_temp_file_write_size requires one argument',
            [Child.SourceFile, Child.Line]);
        ParseSizeBytes(Child, Child.Args[0], 'proxy_temp_file_write_size');
        Continue;
      end;

      if SameText(Child.Name, 'proxy_max_temp_file_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): proxy_max_temp_file_size requires one argument',
            [Child.SourceFile, Child.Line]);
        if SameText(Child.Args[0], 'off') then
          Continue;
        ParseSizeBytes(Child, Child.Args[0], 'proxy_max_temp_file_size');
        Continue;
      end;

      if SameText(Child.Name, 'client_max_body_size') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_max_body_size requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ClientMaxBodySize := ParseSizeBytes(
          Child,
          Child.Args[0],
          'client_max_body_size');
        Continue;
      end;

      if SameText(Child.Name, 'client_body_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_body_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ClientBodyTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'client_body_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'client_header_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): client_header_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.ClientHeaderTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'client_header_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'send_timeout') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): send_timeout requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.SendTimeoutMs := ParseDurationMs(
          Child,
          Child.Args[0],
          'send_timeout');
        Continue;
      end;

      if SameText(Child.Name, 'return') then
      begin
        ParseReturnDirective(Child, Location.ReturnCode, Location.ReturnBody);
        Continue;
      end;

      if SameText(Child.Name, 'proxy_redirect') then
      begin
        ParseProxyRedirectDirective(
          Child,
          ParsedProxyRedirectOff,
          ParsedProxyRedirectDefault,
          ParsedProxyRedirectFrom,
          ParsedProxyRedirectTo);
        Location.ProxyRedirectOff := ParsedProxyRedirectOff;
        Location.ProxyRedirectDefault := ParsedProxyRedirectDefault;
        Location.ProxyRedirectFrom := ParsedProxyRedirectFrom;
        Location.ProxyRedirectTo := ParsedProxyRedirectTo;
        Continue;
      end;

      if SameText(Child.Name, 'sub_filter_types') then
      begin
        if Length(Child.Args) < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sub_filter_types requires arguments',
            [Child.SourceFile, Child.Line]);
        SetLength(Location.SubFilterTypes, Length(Child.Args));
        for I := 0 to High(Child.Args) do
          Location.SubFilterTypes[I] := LowerCase(Child.Args[I]);
        Continue;
      end;

      if SameText(Child.Name, 'sub_filter') then
      begin
        if Length(Child.Args) <> 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sub_filter requires search and replacement values',
            [Child.SourceFile, Child.Line]);
        Location.SubFilterSearch := Child.Args[0];
        Location.SubFilterReplacement := Child.Args[1];
        Continue;
      end;

      if SameText(Child.Name, 'sub_filter_once') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sub_filter_once requires one argument',
            [Child.SourceFile, Child.Line]);
        if (not SameText(Child.Args[0], 'on')) and
           (not SameText(Child.Args[0], 'off')) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sub_filter_once must be on or off',
            [Child.SourceFile, Child.Line]);
        Location.SubFilterOnce := SameText(Child.Args[0], 'on');
        Continue;
      end;

      if SameText(Child.Name, 'add_header') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): add_header requires at least name and value',
            [Child.SourceFile, Child.Line]);
        if not LocationAddHeadersDefined then
        begin
          Location.AddHeaders.Clear;
          LocationAddHeadersDefined := True;
        end;
        AddHeaderAlways := False;
        ValueEndIndex := High(Child.Args);
        if (Length(Child.Args) >= 3) and SameText(Child.Args[ValueEndIndex], 'always') then
        begin
          AddHeaderAlways := True;
          Dec(ValueEndIndex);
        end;
        if ValueEndIndex < 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): add_header value is missing',
            [Child.SourceFile, Child.Line]);
        AddHeaderValue := Child.Args[1];
        for I := 2 to ValueEndIndex do
          AddHeaderValue := AddHeaderValue + ' ' + Child.Args[I];
        Location.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
          Child.Args[0],
          AddHeaderValue,
          AddHeaderAlways));
        Continue;
      end;

      if SameText(Child.Name, 'error_page') then
      begin
        if not LocationErrorPagesDefined then
        begin
          Location.ErrorPages.Clear;
          LocationErrorPagesDefined := True;
        end;
        ParsedErrorPage := ParseErrorPageDirective(Child);
        try
          Location.ErrorPages.Add(ParsedErrorPage);
          ParsedErrorPage := nil;
        finally
          ParsedErrorPage.Free;
        end;
        Continue;
      end;

      if SameText(Child.Name, 'sendfile') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sendfile requires one argument',
            [Child.SourceFile, Child.Line]);
        if (not SameText(Child.Args[0], 'on')) and
           (not SameText(Child.Args[0], 'off')) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): sendfile must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'tcp_nopush') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): tcp_nopush requires one argument',
            [Child.SourceFile, Child.Line]);
        if (not SameText(Child.Args[0], 'on')) and
           (not SameText(Child.Args[0], 'off')) then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): tcp_nopush must be on or off',
            [Child.SourceFile, Child.Line]);
        Continue;
      end;

      if SameText(Child.Name, 'fastcgi_pass') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): fastcgi_pass requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.FastCgiPass := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'fastcgi_index') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): fastcgi_index requires one argument',
            [Child.SourceFile, Child.Line]);
        Location.FastCgiIndex := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'fastcgi_split_path_info') then
      begin
        if Length(Child.Args) <> 1 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): fastcgi_split_path_info requires one argument',
            [Child.SourceFile, Child.Line]);
        try
          TRegEx.Create(Child.Args[0]);
        except
          on E: Exception do
            raise ERomitterConfig.CreateFmt(
              '%s(%d): invalid fastcgi_split_path_info regex "%s": %s',
              [Child.SourceFile, Child.Line, Child.Args[0], E.Message]);
        end;
        Location.FastCgiSplitPathInfoPattern := Child.Args[0];
        Continue;
      end;

      if SameText(Child.Name, 'fastcgi_param') then
      begin
        if Length(Child.Args) < 2 then
          raise ERomitterConfig.CreateFmt(
            '%s(%d): fastcgi_param requires name and value',
            [Child.SourceFile, Child.Line]);
        FastCgiParamValue := JoinArgs(Child.Args, 1);
        if (Length(Child.Args) >= 3) and
           SameText(Child.Args[High(Child.Args)], 'if_not_empty') then
        begin
          FastCgiParamValue := Child.Args[1];
          for I := 2 to High(Child.Args) - 1 do
            FastCgiParamValue := FastCgiParamValue + ' ' + Child.Args[I];
          FastCgiParamValue := '@@if_not_empty@@' + FastCgiParamValue;
        end;
        Location.FastCgiParams.AddOrSetValue(
          Child.Args[0],
          FastCgiParamValue);
        Continue;
      end;

      raise ERomitterConfig.CreateFmt(
        '%s(%d): unsupported directive "%s" in location',
        [Child.SourceFile, Child.Line, Child.Name]);
    end;

    if (Location.ProxyPass <> '') and (Location.FastCgiPass <> '') then
      raise ERomitterConfig.CreateFmt(
        '%s(%d): proxy_pass and fastcgi_pass cannot be used together in one location',
        [Directive.SourceFile, Directive.Line]);

    Server.Locations.Add(Location);
    Location := nil;
  finally
    Location.Free;
  end;
end;

class procedure TRomitterConfigLoader.EnsureDefaultServer(
  const Config: TRomitterConfig);
var
  Server: TRomitterServerConfig;
  Location: TRomitterLocationConfig;
  Pair: TPair<string, string>;
  InheritedAddHeader: TRomitterAddHeaderConfig;
  InheritedErrorPage: TRomitterErrorPageConfig;
  InheritedAccessRule: TRomitterAccessRuleConfig;
begin
  if not Config.Http.Enabled then
    Exit;

  if Config.Http.Servers.Count = 0 then
  begin
    Server := TRomitterServerConfig.Create;
    for Pair in Config.Http.ProxySetHeaders do
      Server.ProxySetHeaders.AddOrSetValue(Pair.Key, Pair.Value);
    for InheritedAddHeader in Config.Http.AddHeaders do
      Server.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
        InheritedAddHeader.Name,
        InheritedAddHeader.Value,
        InheritedAddHeader.Always));
    Server.ProxyRequestBuffering := Config.Http.ProxyRequestBuffering;
    Server.ProxyBuffering := Config.Http.ProxyBuffering;
    Server.ProxyCacheValue := Config.Http.ProxyCacheValue;
    Server.ProxyHttpVersion := Config.Http.ProxyHttpVersion;
    Server.ProxySslServerName := Config.Http.ProxySslServerName;
    Server.ProxySslName := Config.Http.ProxySslName;
    Server.ProxySslVerify := Config.Http.ProxySslVerify;
    Server.ProxyConnectTimeoutMs := Config.Http.ProxyConnectTimeoutMs;
    Server.ProxyReadTimeoutMs := Config.Http.ProxyReadTimeoutMs;
    Server.ProxySendTimeoutMs := Config.Http.ProxySendTimeoutMs;
    Server.ProxyNextUpstream := Config.Http.ProxyNextUpstream;
    Server.ProxyNextUpstreamTries := Config.Http.ProxyNextUpstreamTries;
    Server.ProxyNextUpstreamTimeoutMs := Config.Http.ProxyNextUpstreamTimeoutMs;
    Server.DefaultType := Config.Http.DefaultType;
    Server.ProxyRedirectOff := False;
    Server.ProxyRedirectDefault := False;
    Server.ProxyRedirectFrom := '';
    Server.ProxyRedirectTo := '';
    Server.Root := ResolvePath(Config.Prefix, 'html');
    Server.Listens.Add(TRomitterHttpListenConfig.Create(Server.ListenHost, Server.ListenPort));
    Location := TRomitterLocationConfig.Create;
    for Pair in Server.ProxySetHeaders do
      Location.ProxySetHeaders.AddOrSetValue(Pair.Key, Pair.Value);
    for InheritedAddHeader in Server.AddHeaders do
      Location.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
        InheritedAddHeader.Name,
        InheritedAddHeader.Value,
        InheritedAddHeader.Always));
    for InheritedErrorPage in Server.ErrorPages do
      Location.ErrorPages.Add(TRomitterErrorPageConfig.Create(
        InheritedErrorPage.StatusCodes,
        InheritedErrorPage.Uri,
        InheritedErrorPage.OverrideStatus));
    for InheritedAccessRule in Server.AccessRules do
      Location.AccessRules.Add(TRomitterAccessRuleConfig.Create(
        InheritedAccessRule.IsAllow,
        InheritedAccessRule.RuleText));
    Location.ProxyRequestBuffering := Server.ProxyRequestBuffering;
    Location.ProxyBuffering := Server.ProxyBuffering;
    Location.ProxyCacheValue := Server.ProxyCacheValue;
    Location.ProxyHttpVersion := Server.ProxyHttpVersion;
    Location.ProxySslServerName := Server.ProxySslServerName;
    Location.ProxySslName := Server.ProxySslName;
    Location.ProxySslVerify := Server.ProxySslVerify;
    Location.ProxyConnectTimeoutMs := Server.ProxyConnectTimeoutMs;
    Location.ProxyReadTimeoutMs := Server.ProxyReadTimeoutMs;
    Location.ProxySendTimeoutMs := Server.ProxySendTimeoutMs;
    Location.ProxyNextUpstream := Server.ProxyNextUpstream;
    Location.ProxyNextUpstreamTries := Server.ProxyNextUpstreamTries;
    Location.ProxyNextUpstreamTimeoutMs := Server.ProxyNextUpstreamTimeoutMs;
    Location.DefaultType := Server.DefaultType;
    Location.ProxyRedirectOff := Server.ProxyRedirectOff;
    Location.ProxyRedirectDefault := Server.ProxyRedirectDefault;
    Location.ProxyRedirectFrom := Server.ProxyRedirectFrom;
    Location.ProxyRedirectTo := Server.ProxyRedirectTo;
    Location.MatchPath := '/';
    Server.Locations.Add(Location);
    Config.Http.Servers.Add(Server);
  end
  else
  begin
    for Server in Config.Http.Servers do
    begin
      if Server.Listens.Count = 0 then
        Server.Listens.Add(TRomitterHttpListenConfig.Create(Server.ListenHost, Server.ListenPort));
      if Server.Root = '' then
        Server.Root := ResolvePath(Config.Prefix, 'html');
      if Server.Locations.Count = 0 then
      begin
        Location := TRomitterLocationConfig.Create;
        for Pair in Server.ProxySetHeaders do
          Location.ProxySetHeaders.AddOrSetValue(Pair.Key, Pair.Value);
        for InheritedAddHeader in Server.AddHeaders do
          Location.AddHeaders.Add(TRomitterAddHeaderConfig.Create(
            InheritedAddHeader.Name,
            InheritedAddHeader.Value,
            InheritedAddHeader.Always));
        for InheritedErrorPage in Server.ErrorPages do
          Location.ErrorPages.Add(TRomitterErrorPageConfig.Create(
            InheritedErrorPage.StatusCodes,
            InheritedErrorPage.Uri,
            InheritedErrorPage.OverrideStatus));
        for InheritedAccessRule in Server.AccessRules do
          Location.AccessRules.Add(TRomitterAccessRuleConfig.Create(
            InheritedAccessRule.IsAllow,
            InheritedAccessRule.RuleText));
        Location.ProxyRequestBuffering := Server.ProxyRequestBuffering;
        Location.ProxyBuffering := Server.ProxyBuffering;
        Location.ProxyCacheValue := Server.ProxyCacheValue;
        Location.ProxyHttpVersion := Server.ProxyHttpVersion;
        Location.ProxySslServerName := Server.ProxySslServerName;
        Location.ProxySslName := Server.ProxySslName;
        Location.ProxySslVerify := Server.ProxySslVerify;
        Location.ProxyConnectTimeoutMs := Server.ProxyConnectTimeoutMs;
        Location.ProxyReadTimeoutMs := Server.ProxyReadTimeoutMs;
        Location.ProxySendTimeoutMs := Server.ProxySendTimeoutMs;
        Location.ProxyNextUpstream := Server.ProxyNextUpstream;
        Location.ProxyNextUpstreamTries := Server.ProxyNextUpstreamTries;
        Location.ProxyNextUpstreamTimeoutMs := Server.ProxyNextUpstreamTimeoutMs;
        Location.DefaultType := Server.DefaultType;
        Location.ProxyRedirectOff := Server.ProxyRedirectOff;
        Location.ProxyRedirectDefault := Server.ProxyRedirectDefault;
        Location.ProxyRedirectFrom := Server.ProxyRedirectFrom;
        Location.ProxyRedirectTo := Server.ProxyRedirectTo;
        Location.MatchPath := '/';
        Server.Locations.Add(Location);
      end;
    end;
  end;
end;

class procedure TRomitterConfigLoader.DumpAst(const Ast: TRomitterConfigAst;
  const Output: TStrings);
  procedure DumpDirectives(const Prefix: string;
    const Directives: TObjectList<TRomitterDirective>);
  var
    Directive: TRomitterDirective;
    ArgLine: string;
  begin
    for Directive in Directives do
    begin
      ArgLine := JoinArgs(Directive.Args, 0);
      if Directive.Children.Count = 0 then
      begin
        if ArgLine = '' then
          Output.Add(Prefix + Directive.Name + ';')
        else
          Output.Add(Prefix + Directive.Name + ' ' + ArgLine + ';');
      end
      else
      begin
        if ArgLine = '' then
          Output.Add(Prefix + Directive.Name + ' {')
        else
          Output.Add(Prefix + Directive.Name + ' ' + ArgLine + ' {');
        DumpDirectives(Prefix + '  ', Directive.Children);
        Output.Add(Prefix + '}');
      end;
    end;
  end;
begin
  DumpDirectives('', Ast.Directives);
end;

end.
