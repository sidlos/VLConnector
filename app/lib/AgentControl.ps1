# Starts the VL Connector agent (scanner PC, network scenario) and switches its start with Windows on or
# off (a shortcut in the user's Startup folder; no administrator rights). Dot-source this file; it needs
# lib\Settings.ps1.

function Get-AgentShortcutPath { return Join-Path ([Environment]::GetFolderPath('Startup')) 'VL Connector agent.lnk' }

function Test-AgentAutostart { return Test-Path -LiteralPath (Get-AgentShortcutPath) }

function Test-AgentRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\VLConnector_Agent', [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

function Start-VlcAgent {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path (Get-VlcPaths).AppDir 'Agent.ps1')`"" -WindowStyle Hidden
}

function Set-AgentAutostart([bool]$On) {
    $lnk = Get-AgentShortcutPath
    if (-not $On) { if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }; return }
    $app = (Get-VlcPaths).AppDir
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$app\Agent.ps1`""
    $s.WorkingDirectory = $app
    $s.IconLocation = "$app\assets\VLC_icon.ico,0"
    $s.Description = 'VL Connector agent - exports the STL after AI Replay and opens the reports'
    $s.WindowStyle = 7
    $s.Save()
}
