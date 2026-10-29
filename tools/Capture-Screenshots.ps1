<#
  Development tool: renders the windows offscreen with sample values and saves PNG screenshots for
  the documentation (docs\images). Nothing is shown on screen. Run with powershell.exe -STA.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'docs\images'))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'app\lib\Ui.ps1')
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ui = Import-Window 'SettingsWindow.xaml'
$c = $ui.Controls
$c.AppIcon.Source = Get-AppImage 'VLC_icon_256.png'
$c.AboutIcon.Source = Get-AppImage 'VLC_icon_256.png'
$c.ScenarioLocal.IsChecked = $true
$c.ModeHighSpeed.IsChecked = $true
$c.ExportImmediately.IsChecked = $true
$c.ConfirmStage.IsChecked = $true
$c.AfterExport.SelectedIndex = 2
$c.VldFolderCard.Visibility = 'Collapsed'
$c.ReturnFocus.IsChecked = $true
$c.ProgramFolder.Text = 'C:\Users\Operator\Documents\VL programs'
$c.KeepPieces.SelectedIndex = 0
$c.OpenPdf.IsChecked = $true
$c.SharePath.Text = '\\fileserver\metrology\VLConnector'
$c.ShareStatus.Text = 'Connected - jobs, reports and status folders are writable.'
$c.AutoOpenReports.IsChecked = $true
$c.ProgramsSummary.Text = '3 program(s): ABC, BCD, Housing-12'
$c.AgentAutostart.IsChecked = $true
$c.AgentStatus.Text = 'The agent is running.'
$c.LogFolder.Text = 'C:\Users\Operator\AppData\Local\VLConnector\logs'
$c.Versions.Text = "VL Connector        1.0.0`nVL Application      4.6.1.6002`nPolyWorks|Inspector 26.5.0.3238 (2026 IR5)`nWindows             11 Pro 10.0.26300`nPowerShell          5.1.26100"
$c.AboutVersion.Text = 'Version 1.0.0  -  MIT License'

$ok = Get-Brush 'SuccessBrush'; $okBack = Get-Brush 'SuccessBackBrush'
$warn = Get-Brush 'WarningBrush'; $warnBack = Get-Brush 'WarningBackBrush'
$check = [string][char]0xE73E; $alert = [string][char]0xE7BA
$c.StatusList.ItemsSource = @(
    [pscustomobject]@{ Id = 'vl'; Title = 'VL Application 4.6.1'; Detail = 'C:\Program Files\KEYENCE\VL-800 Series\VL Application'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'pw'; Title = 'PolyWorks MS 2026 (Inspector 26.5)'; Detail = 'C:\Program Files\InnovMetric\PolyWorks MS 2026'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'ps'; Title = 'PowerShell full language mode'; Detail = 'Scripts can use Windows and PolyWorks interfaces.'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'button'; Title = 'Measure button in PolyWorks'; Detail = 'Not found in your PolyWorks ribbon yet.'; Glyph = $alert; Fore = $warn; Back = $warnBack; Action = 'Show me how'; ActionVisibility = 'Visible' }
)

$pages = 'Setup', 'Scanning', 'PolyWorks', 'Network', 'Diagnostics', 'About'
foreach ($p in $pages) {
    foreach ($q in $pages) { $c["Page$q"].Visibility = if ($q -eq $p) { 'Visible' } else { 'Collapsed' } }
    $c["Nav$p"].IsChecked = $true
    $file = Join-Path $OutDir ("settings-{0}.png" -f $p.ToLower())
    Save-WindowImage $ui.Window $file
    $file
}
