<#
  Uninstall.ps1 - VL Connector for PolyWorks: removes VL Connector from this PC. Start it with Uninstall.cmd
  (also in the Start menu: Uninstall VL Connector).
    Uninstall.cmd                     removes the program folder and the Start menu entries
    Uninstall.cmd -RemoveUserData     also removes the settings and logs of the current user
    Uninstall.cmd -Quiet              no questions
  Scans, reports, PolyWorks projects and the shared network folder are never touched. The Measure button
  has to be removed from the PolyWorks ribbon by hand (File > Visual Layout > Customize).
#>
param([switch]$RemoveUserData, [switch]$Quiet)

# FullLanguage mode is needed (docs\IT-Review); checked before anything else runs
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'app\lib\LanguageCheck.ps1') -Caller Uninstall -Mode $ExecutionContext.SessionState.LanguageMode
    if (-not $Quiet) { $null = Read-Host 'Press Enter to close' }
    exit 1
}

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot

Write-Host 'Uninstall VL Connector for PolyWorks' -ForegroundColor Cyan
Write-Host "Program folder: $installDir"
if (-not (Test-Path -LiteralPath (Join-Path $installDir 'app\VLReplay.ps1'))) {
    Write-Host 'This folder does not look like a VL Connector installation. Nothing was removed.' -ForegroundColor Red
    exit 1
}
if (-not $Quiet) {
    $answer = Read-Host 'Remove VL Connector from this PC? [y/N]'
    if ($answer -notmatch '^[YyAa]') { Write-Host 'Cancelled.'; exit 2 }
}

# stop a running agent of this user first (it runs from the program folder)
$stopAgent = $null
if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\VLConnector_AgentStop', [ref]$stopAgent)) { [void]$stopAgent.Set(); $stopAgent.Dispose(); Start-Sleep -Seconds 3; Write-Host 'Agent stopped.' }
foreach ($root in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')) {
    $menu = Join-Path $root 'VL Connector'
    if (Test-Path -LiteralPath $menu) {
        try { Remove-Item -LiteralPath $menu -Recurse -Force; Write-Host "Removed $menu" }
        catch { Write-Host "Not removed (needs administrator rights): $menu" -ForegroundColor Yellow }
    }
}
$startup = [Environment]::GetFolderPath('Startup')
Get-ChildItem -LiteralPath $startup -Filter 'VL Connector*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force; Write-Host "Removed $($_.FullName)"
}
if ($RemoveUserData) {
    foreach ($dir in (Join-Path $env:APPDATA 'VLConnector'), (Join-Path $env:LOCALAPPDATA 'VLConnector')) {
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Host "Removed $dir" }
    }
}

# The program folder is removed after this script has ended (it runs from that folder).
$cmd = "ping -n 3 127.0.0.1 >nul & rd /s /q `"$installDir`""
Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/c', $cmd -WindowStyle Hidden
Write-Host ''
Write-Host 'VL Connector is removed. Remove the Measure button from the PolyWorks ribbon by hand if you added it.' -ForegroundColor Green
if (-not $Quiet) { [void](Read-Host 'Press Enter to close') }
exit 0
