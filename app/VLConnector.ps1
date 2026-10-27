<#
  VLConnector.ps1 - VL Connector for PolyWorks: opens a window.
    VLConnector.cmd                   settings (scenario, scan options, PolyWorks, network, diagnostics)
  The network scenario runs in the background: app\Agent.ps1 on the scanner PC (tray, starts with Windows)
  and the PolyWorks station inside PolyWorks (VL Station button, VLC_Station.pwmacro).
  Only one window of each kind runs per user; a second start brings the open one to the front.
#>
param([ValidateSet('Settings')] [string]$Show = 'Settings')

$ErrorActionPreference = 'Stop'
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Ui', 'PolyWorksSetup', 'Share', 'Prerequisites', 'Diagnostics') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("PowerShell runs in $($ExecutionContext.SessionState.LanguageMode) mode. VL Connector needs FullLanguage mode; please ask IT (see docs\IT-Review).", 'VL Connector', 'OK', 'Error')
    exit 1
}

$mutex = New-Object System.Threading.Mutex($false, "Local\VLConnector_Window_$Show")
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    # already open: bring it to the front
    $title = 'VL Connector for PolyWorks'
    Add-Type -Namespace VlcEntry -Name Win -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
    $h = [VlcEntry.Win]::FindWindow($null, $title)
    if ($h -ne [IntPtr]::Zero) { [void][VlcEntry.Win]::ShowWindow($h, 9); [void][VlcEntry.Win]::SetForegroundWindow($h) }
    exit 0
}

[void](Initialize-VlcLog $Show)
try {
    switch ($Show) {
        'Settings' { . (Join-Path $PSScriptRoot 'ui\SettingsForm.ps1'); Show-SettingsWindow }
    }
}
catch {
    Write-VlcLog "ERROR: $($_.Exception.Message)"
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("VL Connector stopped with an error:`n`n$($_.Exception.Message)`n`nDetails are in the log: $((Get-VlcPaths).LogDir)", 'VL Connector', 'OK', 'Error')
    exit 1
}
finally { $mutex.ReleaseMutex() }
