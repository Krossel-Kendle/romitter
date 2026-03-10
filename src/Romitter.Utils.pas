unit Romitter.Utils;

interface

uses
  System.SysUtils,
  System.Classes;

function EnsureTrailingPathDelimiter(const Value: string): string;
function ResolvePath(const BasePath, Value: string): string;
function ParseHostPort(const Value: string; out Host: string; out Port: Word;
  const DefaultPort: Word = 80): Boolean;
function ParseHttpUrl(const Value: string; out Host: string; out Port: Word;
  out Path: string): Boolean;
function UrlDecode(const Value: string): string;
procedure EnsureDirectoryForFile(const FileName: string);

implementation

uses
  System.IOUtils,
  System.StrUtils;

function EnsureTrailingPathDelimiter(const Value: string): string;
begin
  Result := Value;
  if Result = '' then
    Exit;

  if not (Result.EndsWith('\') or Result.EndsWith('/')) then
    Result := Result + PathDelim;
end;

function ResolvePath(const BasePath, Value: string): string;
begin
  if Value = '' then
    Exit('');

  if TPath.IsPathRooted(Value) then
    Result := TPath.GetFullPath(Value)
  else
    Result := TPath.GetFullPath(TPath.Combine(BasePath, Value));
end;

function ParseHostPort(const Value: string; out Host: string; out Port: Word;
  const DefaultPort: Word): Boolean;
var
  ColonPos: Integer;
  PortText: string;
  PortNumber: Integer;
begin
  Result := False;
  Host := '';
  Port := DefaultPort;

  if Value = '' then
    Exit;

  if Value = '*' then
  begin
    Host := '0.0.0.0';
    Result := True;
    Exit;
  end;

  ColonPos := LastDelimiter(':', Value);
  if ColonPos = 0 then
  begin
    if TryStrToInt(Value, PortNumber) then
    begin
      if (PortNumber < 1) or (PortNumber > 65535) then
        Exit;
      Host := '0.0.0.0';
      Port := PortNumber;
      Result := True;
      Exit;
    end;

    Host := Value;
    Result := True;
    Exit;
  end;

  Host := Copy(Value, 1, ColonPos - 1);
  PortText := Copy(Value, ColonPos + 1, MaxInt);
  if Host = '' then
    Host := '0.0.0.0';

  if not TryStrToInt(PortText, PortNumber) then
    Exit;

  if (PortNumber < 1) or (PortNumber > 65535) then
    Exit;

  Port := PortNumber;
  Result := True;
end;

function ParseHttpUrl(const Value: string; out Host: string; out Port: Word;
  out Path: string): Boolean;
var
  Work: string;
  SlashPos: Integer;
  HostPort: string;
  DefaultPort: Word;
begin
  Result := False;
  Host := '';
  Port := 80;
  Path := '/';

  if StartsText('http://', Value) then
  begin
    DefaultPort := 80;
    Work := Copy(Value, Length('http://') + 1, MaxInt);
  end
  else if StartsText('https://', Value) then
  begin
    DefaultPort := 443;
    Work := Copy(Value, Length('https://') + 1, MaxInt);
  end
  else
    Exit;

  SlashPos := Pos('/', Work);
  if SlashPos > 0 then
  begin
    HostPort := Copy(Work, 1, SlashPos - 1);
    Path := Copy(Work, SlashPos, MaxInt);
  end
  else
  begin
    HostPort := Work;
    Path := '/';
  end;

  if Path = '' then
    Path := '/';

  Result := ParseHostPort(HostPort, Host, Port, DefaultPort);
end;

function UrlDecode(const Value: string): string;
var
  I: Integer;
  Hex: string;
  Code: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(Value) do
  begin
    if (Value[I] = '%') and (I + 2 <= Length(Value)) then
    begin
      Hex := '$' + Copy(Value, I + 1, 2);
      if TryStrToInt(Hex, Code) then
      begin
        Result := Result + Chr(Code);
        Inc(I, 3);
        Continue;
      end;
    end;

    if Value[I] = '+' then
      Result := Result + ' '
    else
      Result := Result + Value[I];
    Inc(I);
  end;
end;

procedure EnsureDirectoryForFile(const FileName: string);
var
  DirName: string;
begin
  DirName := TPath.GetDirectoryName(FileName);
  if DirName = '' then
    Exit;

  if not TDirectory.Exists(DirName) then
    TDirectory.CreateDirectory(DirName);
end;

end.
