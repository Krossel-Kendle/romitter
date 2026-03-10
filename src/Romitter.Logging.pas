unit Romitter.Logging;

interface

uses
  System.SysUtils,
  Winapi.Windows;

type
  TRomitterLogLevel = (rlDebug, rlInfo, rlWarn, rlError);

  TRomitterLogger = class
  private
    FLogFile: string;
    FWriteToConsole: Boolean;
    FLock: TObject;
    FMinLevel: TRomitterLogLevel;
    procedure WriteLine(const Value: string);
    class function LevelToText(const Level: TRomitterLogLevel): string; static;
  public
    constructor Create(const LogFile: string; const WriteToConsole: Boolean = True);
    destructor Destroy; override;
    procedure Log(const Level: TRomitterLogLevel; const Message: string);
    property MinLevel: TRomitterLogLevel read FMinLevel write FMinLevel;
  end;

implementation

uses
  Romitter.Utils;

constructor TRomitterLogger.Create(const LogFile: string;
  const WriteToConsole: Boolean);
begin
  inherited Create;
  FLogFile := LogFile;
  FWriteToConsole := WriteToConsole;
  FLock := TObject.Create;
  FMinLevel := rlDebug;

  if FLogFile <> '' then
    EnsureDirectoryForFile(FLogFile);
end;

destructor TRomitterLogger.Destroy;
begin
  FLock.Free;
  inherited;
end;

class function TRomitterLogger.LevelToText(const Level: TRomitterLogLevel): string;
begin
  case Level of
    rlDebug: Result := 'DEBUG';
    rlInfo: Result := 'INFO';
    rlWarn: Result := 'WARN';
    rlError: Result := 'ERROR';
  else
    Result := 'INFO';
  end;
end;

procedure TRomitterLogger.Log(const Level: TRomitterLogLevel;
  const Message: string);
var
  Line: string;
begin
  if Level < FMinLevel then
    Exit;

  Line := Format('%s [%s] %s',
    [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), LevelToText(Level), Message]);
  WriteLine(Line);
end;

procedure TRomitterLogger.WriteLine(const Value: string);
var
  LineText: string;
  LineBytes: TBytes;
  FileHandle: THandle;
  BytesWritten: DWORD;
begin
  TMonitor.Enter(FLock);
  try
    if FWriteToConsole then
      Writeln(Value);

    if FLogFile <> '' then
    begin
      EnsureDirectoryForFile(FLogFile);
      LineText := Value + sLineBreak;
      LineBytes := TEncoding.UTF8.GetBytes(LineText);
      FileHandle := CreateFile(
        PChar(FLogFile),
        FILE_APPEND_DATA,
        FILE_SHARE_READ or FILE_SHARE_WRITE or FILE_SHARE_DELETE,
        nil,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        0);
      try
        if FileHandle <> INVALID_HANDLE_VALUE then
        begin
          if Length(LineBytes) > 0 then
            WriteFile(FileHandle, LineBytes[0], Length(LineBytes), BytesWritten, nil);
        end;
      finally
        if FileHandle <> INVALID_HANDLE_VALUE then
          CloseHandle(FileHandle);
      end;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
end;

end.
