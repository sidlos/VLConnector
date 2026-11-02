# Starts the agent - VL Connector in the notification area of the scanner PC (network scenario) - and switches
# its start with Windows on or off (the shortcut "VL Connector" in the user's Startup folder; no administrator
# rights). Dot-source this file; it needs lib\Settings.ps1.

function Get-AgentShortcutPath([string]$StartupDir = [Environment]::GetFolderPath('Startup')) { return Join-Path $StartupDir 'VL Connector.lnk' }

# The name of the Startup shortcut up to the first builds of 1.0.0-rc11 ("agent" is no longer shown to users).
function Get-AgentOldShortcutPath([string]$StartupDir = [Environment]::GetFolderPath('Startup')) { return Join-Path $StartupDir 'VL Connector agent.lnk' }

function Test-AgentAutostart([string]$StartupDir = [Environment]::GetFolderPath('Startup')) {
    return (Test-Path -LiteralPath (Get-AgentShortcutPath $StartupDir)) -or (Test-Path -LiteralPath (Get-AgentOldShortcutPath $StartupDir))
}

function Test-AgentRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\VLConnector_Agent', [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

function Start-VlcAgent {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path (Get-VlcPaths).AppDir 'Agent.ps1')`"" -WindowStyle Hidden
}

function Set-AgentAutostart([bool]$On, [string]$Path = (Get-AgentShortcutPath)) {
    $old = Get-AgentOldShortcutPath (Split-Path $Path)
    if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
    if (-not $On) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }; return }
    $app = (Get-VlcPaths).AppDir
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$app\Agent.ps1`""
    $s.WorkingDirectory = $app
    $s.IconLocation = "$app\assets\VLC_icon.ico,0"
    $s.Description = 'VL Connector for PolyWorks in the notification area: exports the STL after AI Replay and opens the reports'
    $s.WindowStyle = 7
    $s.Save()
}

# Shortcuts of this user from an older installation (1.0.0-rc10 in C:\ProgramData\VLConnector, or another
# folder, or the Startup shortcut under its old name "VL Connector agent"): the start with Windows is pointed at
# this installation under the name "VL Connector", and the user's own Start menu folder is removed once the
# installer has created the entries for all users. A "VL Connector" Startup shortcut that does not start an
# Agent.ps1 is not ours and stays. Only an installed copy changes them (a development tree leaves the user's
# shortcuts alone). Returns what was changed.
function Repair-VlcUserShortcuts([string]$StartupDir = [Environment]::GetFolderPath('Startup'), [string]$ProgramsDir = [Environment]::GetFolderPath('Programs'),
    [string]$CommonProgramsDir = [Environment]::GetFolderPath('CommonPrograms')) {
    $changed = New-Object Collections.Generic.List[string]
    $paths = Get-VlcPaths
    if (-not $paths.Installed) { return $changed.ToArray() }
    $lnk = Get-AgentShortcutPath $StartupDir
    if (Test-Path -LiteralPath (Get-AgentOldShortcutPath $StartupDir)) { Set-AgentAutostart $true $lnk; $changed.Add($lnk) }
    elseif (Test-Path -LiteralPath $lnk) {
        $arguments = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments
        if ($arguments -match '\\Agent\.ps1"' -and $arguments.IndexOf("`"$($paths.AppDir)\Agent.ps1`"", [StringComparison]::OrdinalIgnoreCase) -lt 0) { Set-AgentAutostart $true $lnk; $changed.Add($lnk) }
    }
    $menu = Join-Path $ProgramsDir 'VL Connector'
    if ((Test-Path -LiteralPath $menu) -and (Test-Path -LiteralPath (Join-Path $CommonProgramsDir 'VL Connector'))) {
        Remove-Item -LiteralPath $menu -Recurse -Force
        $changed.Add($menu)
    }
    return $changed.ToArray()
}
