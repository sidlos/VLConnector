<#
  Uninstall.ps1 - VL Connector for PolyWorks: removes VL Connector from this PC. Start it with Uninstall.cmd
  (also in the Start menu: Uninstall VL Connector). Windows asks for administrator rights.
    Uninstall.cmd                     removes the program folder, the Start menu entries, the agent's start with
                                      Windows of every user, the forwarders of an older version and the event
                                      source "VL Connector"
    Uninstall.cmd -RemoveUserData     also the settings and logs of the Windows user who runs it
    Uninstall.cmd -Quiet              no questions (run it as administrator or SYSTEM; exit codes as Install.cmd)
  Scans, reports, PolyWorks projects and the shared network folder are never touched. The VL Connector buttons
  have to be removed from the PolyWorks ribbon by hand (File > Visual Layout > Customize).
#>
param(
    [switch]$RemoveUserData,
    [switch]$Quiet,
    # used by the uninstaller itself: the installation to remove and the part that runs with administrator rights
    [string]$InstallDir = '',
    [switch]$MachinePart,
    [string]$ResultFile = ''
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything else runs
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'app\lib\LanguageCheck.ps1') -Caller Uninstall -Mode $ExecutionContext.SessionState.LanguageMode
    if (-not $Quiet -and -not $MachinePart) { $null = Read-Host 'Press Enter to close' }
    exit 1
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app\lib\Install.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not $InstallDir) { $InstallDir = $PSScriptRoot }
$InstallDir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
# nothing may have its current folder in the program folder, or it cannot be deleted
Set-Location -LiteralPath $env:SystemRoot
[Environment]::CurrentDirectory = $env:SystemRoot

function Say([string]$Text, [string]$Color = 'Gray') {
    if ($ResultFile) { [IO.File]::AppendAllText($ResultFile, "$Color|$Text`r`n", (New-Object Text.UTF8Encoding($false))) }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Wait-Key { if (-not $Quiet -and -not $MachinePart) { [void](Read-Host 'Press Enter to close') } }

# This script and what it needs, copied to a temporary folder: the program folder can only be deleted when
# nothing runs from it.
function Copy-Uninstaller {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('VLConnector-uninstall-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($rel in 'Uninstall.ps1', 'app\lib\Install.ps1', 'app\lib\LanguageCheck.ps1') {
        $to = Join-Path $temp $rel
        [void][IO.Directory]::CreateDirectory((Split-Path $to))
        [IO.File]::Copy((Join-Path $PSScriptRoot $rel), $to)
    }
    return $temp
}

# The part of the Windows user who runs it: the own Start menu folder of 1.0.0-rc10 and, if wanted, the own data.
function Remove-UserPart {
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'VL Connector'
    if (Test-Path -LiteralPath $menu) { Remove-Item -LiteralPath $menu -Recurse -Force; Say "Removed $menu" }
    if ($RemoveUserData) {
        foreach ($dir in (Join-Path $env:APPDATA 'VLConnector'), (Join-Path $env:LOCALAPPDATA 'VLConnector')) {
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Say "Removed $dir" }
        }
    }
}

# --- administrator part, from a temporary copy ------------------------------------------------------------------
if ($MachinePart) {
    $code = 1
    try { $code = Uninstall-VlcMachine -InstallDir $InstallDir -Say ${function:Say} }
    catch { Say "Removal failed: $($_.Exception.Message)" 'Red' }
    Say "$code" 'EXIT'
    exit $code
}

Say 'Uninstall VL Connector for PolyWorks' 'Cyan'
Say "Program folder: $InstallDir"
$kind = Get-VlcFolderKind $InstallDir
if (-not $kind -or $kind.Kind -ne 'VLConnector') { Say 'This folder does not look like a VL Connector installation. Nothing was removed.' 'Red'; Wait-Key; exit 1 }
if (-not $Quiet) {
    $answer = Read-Host 'Remove VL Connector from this PC? [y/N]'
    if ($answer -notmatch '^[YyAa]') { Say 'Cancelled.'; exit 2 }
}

$admin = Test-VlcAdministrator
if (-not $admin -and $Quiet) { Say 'Administrator rights are needed: run Uninstall.cmd -Quiet as administrator or as SYSTEM.' 'Red'; exit 740 }
$temp = Copy-Uninstaller
$result = Join-Path $temp 'result.txt'
$code = 1
try {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$temp\Uninstall.ps1`"", '-MachinePart', '-InstallDir', "`"$InstallDir`"", '-ResultFile', "`"$result`"")
    if ($admin) {
        $p = Start-Process -FilePath $ps -ArgumentList $argList -NoNewWindow -Wait -PassThru
        $code = $p.ExitCode
    }
    else {
        Say 'Windows asks for administrator rights now...'
        $p = $null
        try { $p = Start-Process -FilePath $ps -ArgumentList (@('-WindowStyle', 'Hidden') + $argList) -Verb RunAs -WindowStyle Hidden -PassThru }
        catch { Say 'Administrator rights were not given. Nothing was removed.' 'Yellow'; Wait-Key; exit 2 }
        [void]$p.Handle
        $p.WaitForExit()
        $code = $p.ExitCode
    }
    if (Test-Path -LiteralPath $result) {
        foreach ($line in [IO.File]::ReadAllLines($result)) {
            $parts = $line -split '\|', 2
            if ($parts[0] -eq 'EXIT') { if ($null -eq $code) { $code = [int]$parts[1] }; continue }
            Write-Host $parts[1] -ForegroundColor $parts[0]
        }
    }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
if ($code -eq 0) {
    Remove-UserPart
    Say ''
    Say 'VL Connector is removed. Remove its buttons from the PolyWorks ribbon by hand if you added them.' 'Green'
}
Wait-Key
exit $code
