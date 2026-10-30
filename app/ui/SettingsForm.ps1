# VL Connector settings window: loads app\ui\SettingsWindow.xaml, fills in the current settings and saves
# every change straight away to %APPDATA%\VLConnector\settings.json (no Save button). Settings the
# administrator locked for this PC are shown read-only; the machine-only ones (stage rotation, VL Application)
# are changed with Set-MachinePolicy.ps1 through Windows' administrator prompt.
# Dot-source this file (it needs lib\Settings.ps1, Ui.ps1, PolyWorksSetup.ps1, Share.ps1, Prerequisites.ps1,
# Diagnostics.ps1) and call Show-SettingsWindow.

$script:SettingsPages = 'Setup', 'Scanning', 'PolyWorks', 'Network', 'Diagnostics', 'About'

# setting key -> the controls that change it (read-only while the administrator's policy sets the key)
$script:SettingControls = [ordered]@{
    'scenario' = 'ScenarioLocal', 'ScenarioNetwork'; 'role' = 'RoleScanner', 'RoleStation'
    'vl.mode' = 'ModeHighSpeed', 'ModeStandard', 'ModeAsk'; 'vl.exportImmediately' = 'ExportImmediately'
    'vl.afterExport' = 'AfterExport'; 'vl.vldFolder' = 'VldFolder', 'VldFolderBrowse'; 'vl.returnFocus' = 'ReturnFocus'
    'vl.programFolders' = 'ProgramFolder', 'ProgramFolderBrowse'; 'polyworks.keepPieces' = 'KeepPieces'; 'polyworks.openPdf' = 'OpenPdf'
    'network.share' = 'SharePath', 'ShareBrowse'; 'network.autoOpenReports' = 'AutoOpenReports'
}

function Show-SettingsToast([string]$Text) {
    $c = $script:sc
    $c.ToastText.Text = $Text
    $anim = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    foreach ($frame in @(@(0, 0.0), @(150, 1.0), @(1800, 1.0), @(2100, 0.0))) {
        $time = [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds($frame[0]))
        [void]$anim.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame -ArgumentList ([double]$frame[1]), $time))
    }
    $c.Toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)
}

function Save-SettingValue([string]$Key, $Value) {
    if ($script:loading) { return }
    try { [void](Set-VlcUserSettings -Set @{ $Key = $Value }); Show-SettingsToast 'Saved' }
    catch { Show-SettingsToast "Not saved: $($_.Exception.Message)" }
}

# The stage card: state of the machine policy (read-only) and the warning while it is on.
function Update-StageCard($Settings) {
    $c = $script:sc
    $on = [bool]$Settings.vl.confirmStageMotion
    $c.StagePillText.Text = if ($on) { 'On (administrator)' } else { 'Off' }
    $c.StagePill.Background = if ($on) { Get-Brush 'WarningBackBrush' } else { Get-Brush 'InfoBackBrush' }
    $c.StagePillText.Foreground = if ($on) { Get-Brush 'WarningBrush' } else { Get-Brush 'TextBrush' }
    $c.StageWarning.Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
}

# After a change by the administrator tool: settings, read-only controls and the status check again.
function Update-AfterPolicyChange {
    $state = Get-VlcSettingsState
    Update-StageCard $state.Settings
    $script:sc.LockedNotice.Visibility = if (Set-VlcLockedControls $script:sc $script:SettingControls $state.Locked) { 'Visible' } else { 'Collapsed' }
    Update-SettingsStatus
}

function Invoke-PolicyTool([string]$Show) {
    if (-not (Start-VlcPolicyTool $Show { Update-AfterPolicyChange })) { Show-SettingsToast 'Not changed: the administrator prompt was cancelled' }
}

function Show-SettingsPage([string]$Name) {
    foreach ($p in $script:SettingsPages) { $script:sc["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' } }
    $script:sc.Scroll.ScrollToTop()
    if (-not $script:sc["Nav$Name"].IsChecked) { $script:sc["Nav$Name"].IsChecked = $true }
}

function Select-ComboTag($Combo, [string]$Tag) {
    foreach ($item in $Combo.Items) { if ([string]$item.Tag -eq $Tag) { $Combo.SelectedItem = $item; return } }
    $Combo.SelectedIndex = 0
}

function Open-VlcPath([string]$Path) {
    if (-not ($Path -and (Test-Path -LiteralPath $Path))) { Show-SettingsToast "Not found: $Path"; return }
    if ([IO.Path]::GetExtension($Path)) { Start-Process -FilePath $Path }
    else { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$Path`"" }
}

function Select-VlcFolder([string]$Start) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($Start -and (Test-Path -LiteralPath $Start)) { $dlg.SelectedPath = $Start }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    return $null
}

function Update-SettingsStatus {
    $c = $script:sc
    $c.StatusList.ItemsSource = @([pscustomobject]@{ Id = ''; Title = 'Checking this PC...'; Detail = ''; Glyph = [string][char]0xE895
        Fore = Get-Brush 'SecondaryTextBrush'; Back = Get-Brush 'PaneBrush'; Action = ''; ActionVisibility = 'Collapsed' })
    Start-UiJob 'Status' @{} {
        param($Items, $ErrorText)
        $glyphs = @{ Ok = [string][char]0xE73E; Warning = [string][char]0xE7BA; Error = [string][char]0xE711 }
        if ($ErrorText) { $Items = @([pscustomobject]@{ Id = ''; Level = 'Error'; Title = 'The check failed'; Detail = $ErrorText; Action = '' }) }
        $tones = @{ Ok = 'Success'; Warning = 'Warning'; Error = 'Error' }
        $rows = foreach ($i in $Items) {
            $tone = $tones[[string]$i.Level]
            [pscustomobject]@{ Id = $i.Id; Title = $i.Title; Detail = $i.Detail; Glyph = $glyphs[[string]$i.Level]
                Fore = Get-Brush "${tone}Brush"; Back = Get-Brush "${tone}BackBrush"; Action = $i.Action
                ActionVisibility = if ($i.Action) { 'Visible' } else { 'Collapsed' } }
        }
        $script:sc.StatusList.ItemsSource = @($rows)
    }
}

function Update-PolyWorksPage {
    $c = $script:sc
    if (Test-Path -LiteralPath (Get-VlcButtonStubPath)) {
        $c.ButtonPill.Background = Get-Brush 'SuccessBackBrush'; $c.ButtonPillText.Foreground = Get-Brush 'SuccessBrush'; $c.ButtonPillText.Text = 'Button file ready'
    }
    else {
        $c.ButtonPill.Background = Get-Brush 'WarningBackBrush'; $c.ButtonPillText.Foreground = Get-Brush 'WarningBrush'; $c.ButtonPillText.Text = 'Not set up yet'
    }
}

function Update-ProgramsSummary([string]$Share) {
    $c = $script:sc
    if (-not $Share) { $c.ProgramsSummary.Text = 'Which PolyWorks template evaluates the scans of each VL program (.vld4).'; return }
    try {
        $list = Read-VlcProgramsList $Share ([bool](Read-VlcSettings).network.allowUncWorkspaces)
        $programs = @($list.Rows)
        $text = if ($list.Fatal) { $list.Fatal } elseif ($programs.Count) { "$($programs.Count) program(s): " + (($programs | Select-Object -First 5 | ForEach-Object Program) -join ', ') } else { 'No programs yet.' }
        if (-not $list.Fatal -and $list.Problems.Count) { $text += " - $($list.Problems.Count) line(s) not used: $($list.Problems[0])" }
        $c.ProgramsSummary.Text = $text
    }
    catch { $c.ProgramsSummary.Text = "The Measurement Programs List cannot be read: $($_.Exception.Message)" }
}

function Update-AgentStatus {
    $script:sc.AgentStatus.Text = if (Test-AgentRunning) { 'The agent is running.' } else { 'The agent is not running.' }
}

function Invoke-StatusAction([string]$Id) {
    switch ($Id) {
        'vl' { Invoke-PolicyTool 'VlExe' }
        'settings' { Open-VlcPath (Get-VlcPaths).LogDir }
        'button' { Show-SettingsPage 'PolyWorks' }
        'share' { Show-SettingsPage 'Network' }
        'programs' { Show-SettingsPage 'Network' }
        'agent' { Show-SettingsPage 'Network' }
    }
}

function Show-SettingsWindow {
    $ui = Import-Window 'SettingsWindow.xaml'
    $script:sw = $ui.Window
    $script:sc = $ui.Controls
    $c = $script:sc
    $paths = Get-VlcPaths
    $state = Get-VlcSettingsState
    $cfg = $state.Settings
    $script:loading = $true

    $icon = Get-AppImage 'VLC_icon_256.png'
    $script:sw.Icon = $icon
    $c.AppIcon.Source = $icon
    $c.AboutIcon.Source = $icon
    $c.AboutVersion.Text = "Version $(Get-VlcVersion)  -  MIT License"

    # --- values ---------------------------------------------------------------------------------
    $network = $cfg.scenario -eq 'Network'
    $c.ScenarioLocal.IsChecked = -not $network
    $c.ScenarioNetwork.IsChecked = $network
    $c.RoleCard.Visibility = if ($network) { 'Visible' } else { 'Collapsed' }
    $c.RoleScanner.IsChecked = $cfg.role -ne 'Station'
    $c.RoleStation.IsChecked = $cfg.role -eq 'Station'
    $c.ModeHighSpeed.IsChecked = $cfg.vl.mode -eq 'HighSpeed'
    $c.ModeStandard.IsChecked = $cfg.vl.mode -eq 'Standard'
    $c.ModeAsk.IsChecked = $cfg.vl.mode -eq 'Ask'
    $c.ExportImmediately.IsChecked = [bool]$cfg.vl.exportImmediately
    Update-StageCard $cfg
    Select-ComboTag $c.AfterExport ([string]$cfg.vl.afterExport)
    $c.VldFolderCard.Visibility = if ($cfg.vl.afterExport -eq 'SaveAndClose') { 'Visible' } else { 'Collapsed' }
    $c.VldFolder.Text = [string]$cfg.vl.vldFolder
    $c.ReturnFocus.IsChecked = [bool]$cfg.vl.returnFocus
    $c.ProgramFolder.Text = (@($cfg.vl.programFolders) | Where-Object { $_ }) -join '; '
    Select-ComboTag $c.KeepPieces ([string]$cfg.polyworks.keepPieces)
    $c.OpenPdf.IsChecked = [bool]$cfg.polyworks.openPdf
    $c.SharePath.Text = [string]$cfg.network.share
    $c.AutoOpenReports.IsChecked = [bool]$cfg.network.autoOpenReports
    $c.LogFolder.Text = $paths.LogDir
    $c.Versions.Text = Get-VlcVersionsText $cfg
    Update-PolyWorksPage
    Update-ProgramsSummary ([string]$cfg.network.share)
    $c.AgentAutostart.IsChecked = Test-AgentAutostart
    Update-AgentStatus
    $c.LockedNotice.Visibility = if (Set-VlcLockedControls $c $script:SettingControls $state.Locked) { 'Visible' } else { 'Collapsed' }

    # --- navigation -----------------------------------------------------------------------------
    foreach ($p in $script:SettingsPages) { $c["Nav$p"].Add_Checked({ Show-SettingsPage ($this.Name -replace '^Nav', '') }) }

    # --- Setup ----------------------------------------------------------------------------------
    $c.ScenarioLocal.Add_Checked({ $script:sc.RoleCard.Visibility = 'Collapsed'; Save-SettingValue 'scenario' 'Local'; if (-not $script:loading) { Update-SettingsStatus } })
    $c.ScenarioNetwork.Add_Checked({ $script:sc.RoleCard.Visibility = 'Visible'; Save-SettingValue 'scenario' 'Network'; if (-not $script:loading) { Update-SettingsStatus } })
    $c.RoleScanner.Add_Checked({ Save-SettingValue 'role' 'Scanner'; if (-not $script:loading) { Update-SettingsStatus } })
    $c.RoleStation.Add_Checked({ Save-SettingValue 'role' 'Station'; if (-not $script:loading) { Update-SettingsStatus } })
    $c.StatusList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) { Invoke-StatusAction ([string]$e.OriginalSource.Tag) }
    })

    # --- Scanning -------------------------------------------------------------------------------
    $c.ModeHighSpeed.Add_Checked({ Save-SettingValue 'vl.mode' 'HighSpeed' })
    $c.ModeStandard.Add_Checked({ Save-SettingValue 'vl.mode' 'Standard' })
    $c.ModeAsk.Add_Checked({ Save-SettingValue 'vl.mode' 'Ask' })
    $c.ExportImmediately.Add_Checked({ Save-SettingValue 'vl.exportImmediately' $true }); $c.ExportImmediately.Add_Unchecked({ Save-SettingValue 'vl.exportImmediately' $false })
    $c.ChangeStagePolicy.Add_Click({ Invoke-PolicyTool 'StageMotion' })
    $c.AfterExport.Add_SelectionChanged({
        $tag = [string]$this.SelectedItem.Tag
        $script:sc.VldFolderCard.Visibility = if ($tag -eq 'SaveAndClose') { 'Visible' } else { 'Collapsed' }
        Save-SettingValue 'vl.afterExport' $tag
    })
    $c.VldFolder.Add_LostFocus({ Save-SettingValue 'vl.vldFolder' $this.Text.Trim() })
    $c.VldFolderBrowse.Add_Click({
        $f = Select-VlcFolder $script:sc.VldFolder.Text
        if ($f) { $script:sc.VldFolder.Text = $f; Save-SettingValue 'vl.vldFolder' $f }
    })
    $c.ReturnFocus.Add_Checked({ Save-SettingValue 'vl.returnFocus' $true }); $c.ReturnFocus.Add_Unchecked({ Save-SettingValue 'vl.returnFocus' $false })
    $c.ProgramFolder.Add_LostFocus({ Save-SettingValue 'vl.programFolders' @($this.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) })
    $c.ProgramFolderBrowse.Add_Click({
        $f = Select-VlcFolder (($script:sc.ProgramFolder.Text -split ';')[0]).Trim()
        if ($f) { $script:sc.ProgramFolder.Text = $f; Save-SettingValue 'vl.programFolders' @($f) }
    })

    # --- PolyWorks ------------------------------------------------------------------------------
    $c.KeepPieces.Add_SelectionChanged({ Save-SettingValue 'polyworks.keepPieces' ([string]$this.SelectedItem.Tag) })
    $c.OpenPdf.Add_Checked({ Save-SettingValue 'polyworks.openPdf' $true }); $c.OpenPdf.Add_Unchecked({ Save-SettingValue 'polyworks.openPdf' $false })
    $c.CopyMacroPath.Add_Click({
        try {
            $cfgNow = Read-VlcSettings
            $kind = if ($cfgNow.scenario -eq 'Network' -and $cfgNow.role -eq 'Station') { 'Station' } else { 'Measure' }
            $stub = Get-VlcButtonStubPath $kind
            if (-not (Test-Path -LiteralPath $stub)) { [void](New-VlcButtonStub -Kind $kind) }
            [System.Windows.Clipboard]::SetText($stub)
            Show-SettingsToast 'Macro path copied'
        }
        catch { [void][System.Windows.MessageBox]::Show($script:sw, "The button file cannot be created: $($_.Exception.Message)", 'VL Connector', 'OK', 'Warning') }
        Update-PolyWorksPage
    })
    $c.CopyIconPath.Add_Click({
        [System.Windows.Clipboard]::SetText((Join-Path (Get-VlcPaths).AppDir 'assets\VLC_icon_32.png'))
        Show-SettingsToast 'Icon path copied'
    })
    $c.ButtonHelp.Add_Click({ Open-VlcPath (Join-Path (Get-VlcPaths).InstallDir 'docs\User-Guide.html') })
    $c.AddToPolyWorks.Add_Click({
        $cfgNow = Read-VlcSettings
        $kind = if ($cfgNow.scenario -eq 'Network' -and $cfgNow.role -eq 'Station') { 'Station' } else { 'Measure' }
        $script:sc.ButtonPillText.Text = 'Adding...'
        $script:sw.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render)
        try {
            [void](Install-VlcPolyWorksTab $kind)
            Show-SettingsToast 'The VL Connector tab is in PolyWorks'
            $script:sc.ButtonPill.Background = Get-Brush 'SuccessBackBrush'; $script:sc.ButtonPillText.Foreground = Get-Brush 'SuccessBrush'
            $script:sc.ButtonPillText.Text = 'Added to PolyWorks'
        }
        catch { Update-PolyWorksPage; [void][System.Windows.MessageBox]::Show($script:sw, $_.Exception.Message, 'VL Connector', 'OK', 'Warning') }
    })
    $c.RunWizard.Add_Click({
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path (Get-VlcPaths).AppDir 'VLConnector.ps1')`"", '-Show', 'Wizard' -WindowStyle Hidden
    })

    # --- Network --------------------------------------------------------------------------------
    $c.SharePath.Add_LostFocus({
        $path = $this.Text.Trim()
        if ($this.IsEnabled -and $path -ne [string](Read-VlcSettings).network.share) { Save-SettingValue 'network.share' $path; Update-ProgramsSummary $path }
    })
    $c.ShareBrowse.Add_Click({
        $f = Select-VlcFolder $script:sc.SharePath.Text
        if ($f) { $script:sc.SharePath.Text = $f; Save-SettingValue 'network.share' $f; Update-ProgramsSummary $f }
    })
    $c.ShareTest.Add_Click({
        $path = $script:sc.SharePath.Text.Trim()
        $script:sc.ShareStatus.Text = 'Testing...'
        $script:sc.ShareTest.IsEnabled = $false
        $role = if ($script:sc.RoleStation.IsChecked) { 'Station' } else { 'Scanner' }
        Start-UiJob 'ShareTest' @{ Path = $path; Role = $role } {
            param($Out, $ErrorText)
            $r = @($Out)[0]
            $script:sc.ShareStatus.Text = if ($ErrorText) { $ErrorText } else { $r.Text }
            $script:sc.ShareStatus.Foreground = if ($r -and $r.Ok) { Get-Brush 'SuccessBrush' } else { Get-Brush 'ErrorBrush' }
            $script:sc.ShareTest.IsEnabled = $true
            Update-ProgramsSummary $script:sc.SharePath.Text.Trim()
        }
    })
    $c.AutoOpenReports.Add_Checked({ Save-SettingValue 'network.autoOpenReports' $true }); $c.AutoOpenReports.Add_Unchecked({ Save-SettingValue 'network.autoOpenReports' $false })
    $c.AgentAutostart.Add_Checked({ try { Set-AgentAutostart $true; Show-SettingsToast 'The agent starts with Windows' } catch { Show-SettingsToast "Not saved: $($_.Exception.Message)" } })
    $c.AgentAutostart.Add_Unchecked({ try { Set-AgentAutostart $false; Show-SettingsToast 'The agent no longer starts with Windows' } catch { Show-SettingsToast "Not saved: $($_.Exception.Message)" } })
    $c.StartAgent.Add_Click({
        if (Test-AgentRunning) { Show-SettingsToast 'The agent is already running'; return }
        Start-VlcAgent
        Show-SettingsToast 'Agent started'
        $t = New-Object System.Windows.Threading.DispatcherTimer
        $t.Interval = [TimeSpan]::FromSeconds(3)
        $t.Add_Tick({ $this.Stop(); Update-AgentStatus })
        $t.Start()
    })
    $c.EditPrograms.Add_Click({
        $share = $script:sc.SharePath.Text.Trim()
        if (-not $share) { Show-SettingsToast 'Enter the shared folder first'; return }
        $file = Get-VlcProgramsFile $share
        try {
            if (-not (Test-Path -LiteralPath $file)) { Save-VlcPrograms $share @() }
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`""
        }
        catch { [void][System.Windows.MessageBox]::Show($script:sw, $_.Exception.Message, 'VL Connector', 'OK', 'Warning') }
    })

    # --- Diagnostics and About -----------------------------------------------------------------
    $c.OpenLogs.Add_Click({
        $dir = (Get-VlcPaths).LogDir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$dir`""
    })
    $c.CollectDiagnostics.Add_Click({
        try {
            $zip = New-VlcDiagnosticsZip
            Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$zip`""
            Show-SettingsToast 'Diagnostics ZIP created on the desktop'
        }
        catch { [void][System.Windows.MessageBox]::Show($script:sw, $_.Exception.Message, 'VL Connector', 'OK', 'Warning') }
    })
    $c.OpenGuide.Add_Click({ Open-VlcPath (Join-Path (Get-VlcPaths).InstallDir 'docs\User-Guide.html') })
    $c.OpenItReview.Add_Click({ Open-VlcPath (Join-Path (Get-VlcPaths).InstallDir 'docs\IT-Review.html') })
    $c.OpenLicense.Add_Click({ Open-VlcPath (Join-Path (Get-VlcPaths).InstallDir 'LICENSE') })

    $script:sw.Add_ContentRendered({ Update-SettingsStatus })
    $script:loading = $false
    [void]$script:sw.ShowDialog()
}
