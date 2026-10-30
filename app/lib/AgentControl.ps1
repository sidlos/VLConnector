# Starts the VL Connector agent (scanner PC, network scenario) and switches its start with Windows on or
# off (a shortcut in the user's Startup folder; no administrator rights). Dot-source this file; it needs
# lib\Settings.ps1.

function Get-AgentShortcutPath([string]$StartupDir = [Environment]::GetFolderPath('Startup')) { return Join-Path $StartupDir 'VL Connector agent.lnk' }

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

function Set-AgentAutostart([bool]$On, [string]$Path = (Get-AgentShortcutPath)) {
    if (-not $On) { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }; return }
    $app = (Get-VlcPaths).AppDir
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$app\Agent.ps1`""
    $s.WorkingDirectory = $app
    $s.IconLocation = "$app\assets\VLC_icon.ico,0"
    $s.Description = 'VL Connector agent - exports the STL after AI Replay and opens the reports'
    $s.WindowStyle = 7
    $s.Save()
}

# Shortcuts of this user from an older installation (1.0.0-rc10 in C:\ProgramData\VLConnector, or another
# folder): the agent's start with Windows is pointed at this installation, and the user's own Start menu folder
# is removed once the installer has created the entries for all users. Only an installed copy changes them (a
# development tree leaves the user's shortcuts alone). Returns what was changed.
function Repair-VlcUserShortcuts([string]$StartupDir = [Environment]::GetFolderPath('Startup'), [string]$ProgramsDir = [Environment]::GetFolderPath('Programs'),
    [string]$CommonProgramsDir = [Environment]::GetFolderPath('CommonPrograms')) {
    $changed = New-Object Collections.Generic.List[string]
    $paths = Get-VlcPaths
    if (-not $paths.Installed) { return $changed.ToArray() }
    $lnk = Get-AgentShortcutPath $StartupDir
    if (Test-Path -LiteralPath $lnk) {
        $arguments = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).Arguments
        if ($arguments.IndexOf("`"$($paths.AppDir)\Agent.ps1`"", [StringComparison]::OrdinalIgnoreCase) -lt 0) { Set-AgentAutostart $true $lnk; $changed.Add($lnk) }
    }
    $menu = Join-Path $ProgramsDir 'VL Connector'
    if ((Test-Path -LiteralPath $menu) -and (Test-Path -LiteralPath (Join-Path $CommonProgramsDir 'VL Connector'))) {
        Remove-Item -LiteralPath $menu -Recurse -Force
        $changed.Add($menu)
    }
    return $changed.ToArray()
}
