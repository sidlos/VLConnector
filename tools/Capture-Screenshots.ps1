<#
  Development tool: renders the windows offscreen with sample values and saves PNG screenshots for
  the documentation and the README (docs\images). Nothing is shown on screen. Run with powershell.exe -STA.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'docs\images'))

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'app\lib\Ui.ps1')
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# Save-WindowImage renders a window's content without the window: the content takes the window's background
# and text settings here, which it inherits only inside the window
function Set-ContentLook($Window) {
    $root = $Window.Content
    if (-not $root.Background) { $root.Background = $Window.Background }
    foreach ($p in [System.Windows.Documents.TextElement]::FontFamilyProperty, [System.Windows.Documents.TextElement]::FontSizeProperty,
        [System.Windows.Documents.TextElement]::ForegroundProperty) { $root.SetValue($p, $Window.GetValue($p)) }
}

$ui = Import-Window 'SettingsWindow.xaml'
$c = $ui.Controls
$c.AppIcon.Source = Get-AppImage 'VLC_icon_256.png'
$c.AboutIcon.Source = Get-AppImage 'VLC_icon_256.png'
$c.ScenarioLocal.IsChecked = $true
$c.ModeHighSpeed.IsChecked = $true
$c.ExportImmediately.IsChecked = $true
$c.StagePillText.Text = 'Off'
$c.StageWarning.Visibility = 'Collapsed'
$c.AfterExport.SelectedIndex = 2
$c.VldFolderCard.Visibility = 'Collapsed'
$c.ReturnFocus.IsChecked = $true
$c.ProgramFolder.Text = 'C:\Users\Operator\Documents\VL programs'
$c.OpenPdf.IsChecked = $true
$c.SharePath.Text = '\\fileserver\metrology\VLConnector'
$c.ShareStatus.Text = 'Connected - jobs, reports and status folders are writable.'
$c.AutoOpenReports.IsChecked = $true
$c.ProgramsSummary.Text = '3 program(s): ABC, BCD, Housing-12'
$c.AgentAutostart.IsChecked = $true
$c.AgentStatus.Text = 'VL Connector runs in the notification area.'
$c.LogFolder.Text = 'C:\Users\Operator\AppData\Local\VLConnector\logs'
$version = ([IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'VERSION'))).Trim()
$c.Versions.Text = "VL Connector        $version`nVL Application      4.6.1.6002`nPolyWorks|Inspector 26.5.0.3238 (2026 IR5)`nWindows             11 Pro 10.0.26300`nPowerShell          5.1.26100"
$c.AboutVersion.Text = "Version $version  -  MIT License"

$ok = Get-Brush 'SuccessBrush'; $okBack = Get-Brush 'SuccessBackBrush'
$warn = Get-Brush 'WarningBrush'; $warnBack = Get-Brush 'WarningBackBrush'
$check = [string][char]0xE73E; $alert = [string][char]0xE7BA
$c.StatusList.ItemsSource = @(
    [pscustomobject]@{ Id = 'vl'; Title = 'VL Application 4.6.1'; Detail = 'C:\Program Files\KEYENCE\VL-800 Series\VL Application'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'pw'; Title = 'PolyWorks MS 2026 (Inspector 26.5)'; Detail = 'C:\Program Files\InnovMetric\PolyWorks MS 2026'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'ps'; Title = 'PowerShell full language mode'; Detail = 'Scripts can use Windows and PolyWorks interfaces.'; Glyph = $check; Fore = $ok; Back = $okBack; Action = ''; ActionVisibility = 'Collapsed' }
    [pscustomobject]@{ Id = 'button'; Title = 'Measure button in PolyWorks'; Detail = 'Not found in your PolyWorks ribbon yet.'; Glyph = $alert; Fore = $warn; Back = $warnBack; Action = 'Show me how'; ActionVisibility = 'Visible' }
)

Set-ContentLook $ui.Window
$pages = 'Setup', 'Scanning', 'PolyWorks', 'Network', 'Diagnostics', 'About'
foreach ($p in $pages) {
    foreach ($q in $pages) { $c["Page$q"].Visibility = if ($q -eq $p) { 'Visible' } else { 'Collapsed' } }
    $c["Nav$p"].IsChecked = $true
    $file = Join-Path $OutDir ("settings-{0}.png" -f $p.ToLower())
    Save-WindowImage $ui.Window $file
    $file
}

# the setup wizard (ui\WizardForm.ps1) for PolyWorks on this PC: the first step, and the step that adds the
# VL Connector tab with the Measure button to PolyWorks
$ui = Import-Window 'WizardWindow.xaml'
$c = $ui.Controls
$c.AppIcon.Source = Get-AppImage 'VLC_icon_256.png'
$c.ChooseLocal.IsChecked = $true
$c.PwBar.Style = $ui.Window.FindResource('SuccessBar')
$c.PwText.Text = 'PolyWorks MS 2026 (Inspector 26.5) found. PolyWorks|Inspector is open.'
$c.TabTitle.Text = 'VL Connector tab with the Measure button in PolyWorks'
Set-ContentLook $ui.Window
$steps = [ordered]@{ Scenario = 'Step 1 of 4: Scenario'; PolyWorks = 'Step 3 of 4: PolyWorks' }
foreach ($p in $steps.Keys) {
    foreach ($q in 'Scenario', 'Scanning', 'PolyWorks', 'Network', 'Done') { $c["Page$q"].Visibility = if ($q -eq $p) { 'Visible' } else { 'Collapsed' } }
    $c.StepText.Text = $steps[$p]
    $c.BackButton.IsEnabled = $p -ne 'Scenario'
    $file = Join-Path $OutDir ("wizard-{0}.png" -f $p.ToLower())
    Save-WindowImage $ui.Window $file 860 680
    $file
}

# the stage warning window (lib\StageWarningWindow.ps1) as it appears when VL Connector answers a stage question
$source = [IO.File]::ReadAllText((Join-Path (Split-Path $PSScriptRoot) 'app\lib\StageWarningWindow.ps1'))
$warning = [System.Windows.Markup.XamlReader]::Parse([regex]::Match($source, "(?s)Parse\(@'\r?\n(.*?)\r?\n'@\)").Groups[1].Value)
# the window sets its headline when it is shown (StageWarningWindow.ps1): this is the one of a stage question
$warning.FindName('Headline').Text = 'The stage rotates - keep clear of the scanner'
$warning.FindName('Detail').Text = "VL asks 'The stage will rotate. Continue?' - VL Connector answers OK (set by the administrator for this PC). Program: Housing-12.vld4"
# only the content is rendered: it takes the window's background
$warning.Content.Background = $warning.Background
$warning.Content.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
$file = Join-Path $OutDir 'stage-warning.png'
Save-WindowImage $warning $file ([int][Math]::Ceiling($warning.Content.DesiredSize.Width)) ([int][Math]::Ceiling($warning.Content.DesiredSize.Height))
$file
