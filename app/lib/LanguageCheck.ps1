<#
  Stops VL Connector with a clear message when Windows PowerShell does not run its scripts in FullLanguage
  mode (an application control policy such as AppLocker or WDAC runs scripts it does not trust in
  ConstrainedLanguage mode). Every entry script calls it as its first statement, before it loads anything:
      if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
          & (Join-Path $PSScriptRoot 'lib\LanguageCheck.ps1') -Caller <name> -Mode $ExecutionContext.SessionState.LanguageMode ...; exit 1 }
  The caller passes its own mode: Windows decides the mode per file, so this script may run in another one.
  Only cmdlets and plain text are used here, so it works in ConstrainedLanguage mode as well.
    -OutFile, -Keys   the result file a PolyWorks macro reads (KEY=value lines in the given order): STATE=ERROR,
                      MESSAGE=<the text>, every other key empty
    -Show             windows and the tray agent: also shows the text in Notepad
  The text also goes to the console and to the log %LOCALAPPDATA%\VLConnector\logs\<Caller>_<date>.log.
#>
param(
    [Parameter(Mandatory = $true)] [string]$Caller,
    [Parameter(Mandatory = $true)] [string]$Mode,
    [string]$OutFile = '',
    [string[]]$Keys = @(),
    [switch]$Show
)

$text = "VL Connector cannot run: Windows PowerShell runs its scripts in $Mode mode on this PC, and VL Connector needs FullLanguage mode. An application control policy (AppLocker or Windows Defender Application Control) gives that mode to scripts it trusts. Please ask your IT department; the Notes for IT (docs\IT-Review) describe how VL Connector is allowed: installed in C:\Program Files\VLConnector, or its scripts signed with the company certificate."
Write-Host $text -ForegroundColor Red

try {
    $logDir = Join-Path (Join-Path $env:LOCALAPPDATA 'VLConnector') 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $log = Join-Path $logDir ('{0}_{1}.log' -f $Caller, (Get-Date -Format 'yyyyMMdd'))
    Add-Content -LiteralPath $log -Value ('{0}  ERROR: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $text) -Encoding UTF8
}
catch { }

if ($OutFile -and $Keys.Count) {
    try {
        $lines = foreach ($key in $Keys) {
            if ($key -eq 'STATE') { 'STATE=ERROR' } elseif ($key -eq 'MESSAGE') { "MESSAGE=$text" } else { "$key=" }
        }
        # written under a temporary name and renamed, like every other result file (UTF-8 with BOM)
        Set-Content -LiteralPath "$OutFile.part" -Value $lines -Encoding UTF8
        Move-Item -LiteralPath "$OutFile.part" -Destination $OutFile -Force
    }
    catch { Write-Host "The result file $OutFile could not be written: $_" -ForegroundColor Red }
}

# VLCONNECTOR_NO_UI=1: the automatic tests run the windows in ConstrainedLanguage mode without Notepad
if ($Show -and $env:VLCONNECTOR_NO_UI -ne '1') {
    try {
        $note = Join-Path $env:TEMP 'VL Connector - PowerShell language mode.txt'
        Set-Content -LiteralPath $note -Value 'VL Connector for PolyWorks', '', $text -Encoding UTF8
        Invoke-Item -LiteralPath $note
    }
    catch { }
}
