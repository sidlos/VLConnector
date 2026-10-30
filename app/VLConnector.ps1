<#
  VLConnector.ps1 - VL Connector for PolyWorks: opens a window.
    VLConnector.cmd                   settings (scenario, scan options, PolyWorks, network, diagnostics)
    VLConnector.cmd -Show Wizard      setup wizard (scenario, options, PolyWorks tab, network)
  The network scenario runs in the background: app\Agent.ps1 on the scanner PC (tray, starts with Windows)
  and the PolyWorks station inside PolyWorks (VL Station button, VLC_Station.pwmacro).
  Only one window of each kind runs per user; a second start brings the open one to the front.
#>
param([ValidateSet('Settings', 'Wizard')] [string]$Show = 'Settings')

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'lib\LanguageCheck.ps1') -Caller $Show -Mode $ExecutionContext.SessionState.LanguageMode -Show
    exit 1
}

$ErrorActionPreference = 'Stop'
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Interop', 'Ui', 'PolyWorksSetup', 'PolyWorksLayout', 'Share', 'AgentControl', 'Prerequisites', 'Diagnostics') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

$mutex = New-Object System.Threading.Mutex($false, "Local\VLConnector_Window_$Show")
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    # already open: bring it to the front
    $title = @{ Settings = 'VL Connector for PolyWorks'; Wizard = 'VL Connector - Setup' }[$Show]
    try { Import-VlcInterop; [void][VLConnector.Interop.VlcWindow]::Activate($title) } catch { }
    exit 0
}

[void](Initialize-VlcLog $Show)
try {
    Import-VlcInterop
    # user files of 1.0.0-rc10 and earlier hold every value, also keys only the administrator may set
    $removed = @(Repair-VlcUserSettings)
    if ($removed.Count) { Write-VlcLog "Settings cleaned up: $($removed -join ', ')" }
    try { foreach ($c in @(Repair-VlcUserShortcuts)) { Write-VlcLog "Shortcut brought up to date: $c" } } catch { Write-VlcLog "Shortcuts: $($_.Exception.Message)" }
    switch ($Show) {
        'Settings' { . (Join-Path $PSScriptRoot 'ui\SettingsForm.ps1'); Show-SettingsWindow }
        'Wizard' { . (Join-Path $PSScriptRoot 'ui\WizardForm.ps1'); Show-SetupWizard }
    }
}
catch {
    Write-VlcLog "ERROR: $($_.Exception.Message)"
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("VL Connector stopped with an error:`n`n$($_.Exception.Message)`n`nDetails are in the log: $((Get-VlcPaths).LogDir)", 'VL Connector', 'OK', 'Error')
    exit 1
}
finally { $mutex.ReleaseMutex() }
