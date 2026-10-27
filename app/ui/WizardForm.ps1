# VL Connector setup wizard: scenario -> scanning options -> PolyWorks (layouts, ribbon tab) or network
# (shared folder, agent, programs list) -> summary. Every step saves its settings when you go on.
# Dot-source this file (it needs the libraries loaded by VLConnector.ps1) and call Show-SetupWizard.

$script:WizardTitles = @{ Scenario = 'Scenario'; Scanning = 'Scanning'; PolyWorks = 'PolyWorks'; Network = 'Network'; Done = 'Done' }

function Get-WizardKind {
    $c = $script:wc
    if ($c.ChooseStation.IsChecked) { return 'Station' }
    if ($c.ChooseScanner.IsChecked) { return 'Scanner' }
    return 'Local'
}

function Get-WizardPages([string]$Kind) {
    switch ($Kind) {
        'Scanner' { return @('Scenario', 'Scanning', 'Network', 'Done') }
        'Station' { return @('Scenario', 'Network', 'PolyWorks', 'Done') }
        default { return @('Scenario', 'Scanning', 'PolyWorks', 'Done') }
    }
}

function Set-WizardBar($Bar, $Text, [string]$Message, [string]$Tone) {
    $Bar.Style = $script:ww.FindResource(@{ Info = 'InfoBar'; Success = 'SuccessBar'; Warning = 'WarningBar'; Error = 'ErrorBar' }[$Tone])
    $Text.Text = $Message
}

# Lets WPF draw the "please wait" text before a blocking call.
function Update-WizardScreen { $script:ww.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Render) }

function Update-WizardPage([string]$Page) {
    $c = $script:wc
    $kind = Get-WizardKind
    switch ($Page) {
        'Scanning' {
            $exe = [string](Read-VlcSettings).vl.exe
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                $v = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
                Set-WizardBar $c.VlBar $c.VlText "VL Application $v found. VL must show its English user interface." 'Success'
                $c.LocateVl.Visibility = 'Collapsed'
            }
            else {
                Set-WizardBar $c.VlBar $c.VlText "The VL Application was not found ($exe). Locate VLApplication4.exe." 'Warning'
                $c.LocateVl.Visibility = 'Visible'
            }
        }
        'PolyWorks' {
            $what = if ($kind -eq 'Station') { 'Station' } else { 'Measure' }
            $c.TabTitle.Text = "VL Connector tab with the $what button in PolyWorks"
            $c.PropertyHint.Visibility = if ($kind -eq 'Station') { 'Collapsed' } else { 'Visible' }
            $pw = Get-PolyWorksInfo
            if (-not $pw) { Set-WizardBar $c.PwBar $c.PwText 'PolyWorks was not found on this PC. Install PolyWorks Metrology Suite first.' 'Error'; $c.AddTab.IsEnabled = $false; $c.BuildLayouts.IsEnabled = $false }
            else {
                $insp = $null
                try { $insp = Get-VlcRunningInspector } catch { }
                $state = if ($insp) { 'PolyWorks|Inspector is open.' } else { 'Open PolyWorks|Inspector (any project) to add the VL Connector tab.' }
                Set-WizardBar $c.PwBar $c.PwText "$($pw.Name) (Inspector $($pw.InspectorVersion)) found. $state" $(if ($insp) { 'Success' } else { 'Info' })
            }
            $c.LayoutsText.Text = if (Test-VlcReportLayouts) { 'Built from your PolyWorks A4 layout.' } else { 'A4 report with a large color map and a green OK or red NOK verdict. Not built yet.' }
            $c.BuildLayouts.Content = if (Test-VlcReportLayouts) { 'Rebuild' } else { 'Build' }
        }
        'Network' {
            $c.AgentCard.Visibility = if ($kind -eq 'Scanner') { 'Visible' } else { 'Collapsed' }
            $c.AutoOpenCard.Visibility = if ($kind -eq 'Scanner') { 'Visible' } else { 'Collapsed' }
            $c.ProgramsCard.Visibility = if ($kind -eq 'Station') { 'Visible' } else { 'Collapsed' }
        }
        'Done' {
            $cfg = Read-VlcSettings
            $lines = New-Object Collections.Generic.List[string]
            $lines.Add(@{ Local = 'Scenario: PolyWorks on this PC.'; Scanner = 'Scenario: scanner PC, PolyWorks on another PC.'; Station = 'Scenario: PolyWorks station for the scanner PCs.' }[$kind])
            if ($kind -ne 'Station') {
                $mode = @{ HighSpeed = 'High speed'; Standard = 'Standard'; Ask = 'operator chooses' }[[string]$cfg.vl.mode]
                $lines.Add("AI Replay mode: $mode; STL " + $(if ($cfg.vl.exportImmediately) { 'right after the scan.' } else { 'after VL''s alignment.' }))
            }
            if ($kind -ne 'Scanner') {
                if (Test-VlcReportLayouts) { $lines.Add('Report layouts built.') }
                if ($script:tabAdded) { $lines.Add('VL Connector tab added to PolyWorks.') }
            }
            if ($kind -ne 'Local') { $lines.Add("Shared folder: $($cfg.network.share)") }
            if ($kind -eq 'Scanner') { $lines.Add($(if (Test-AgentAutostart) { 'The agent starts with Windows.' } else { 'The agent does not start with Windows (Start menu: VL Connector agent).' })) }
            $c.Summary.ItemsSource = $lines.ToArray()
            $c.NextText.Text = switch ($kind) {
                'Local' { 'Next: open a part template in PolyWorks|Inspector, add the project property "VL program" (path to the .vld4) and press Measure on the VL Connector tab.' }
                'Scanner' { 'Next: scan with AI Replay in VL as usual. The agent exports the STL, sends it to the PolyWorks station and opens the report.' }
                'Station' { 'Next: fill the programs list, open a PolyWorks|Inspector used only for the station and press VL Station on the VL Connector tab.' }
            }
        }
    }
}

function Show-WizardStep {
    $c = $script:wc
    $pages = Get-WizardPages (Get-WizardKind)
    $page = $pages[$script:wizStep]
    foreach ($p in 'Scenario', 'Scanning', 'PolyWorks', 'Network', 'Done') { $c["Page$p"].Visibility = if ($p -eq $page) { 'Visible' } else { 'Collapsed' } }
    $c.StepText.Text = "Step $($script:wizStep + 1) of $($pages.Count): $($script:WizardTitles[$page])"
    $c.BackButton.IsEnabled = $script:wizStep -gt 0 -and $page -ne 'Done'
    $c.NextButton.Content = if ($page -eq 'Done') { 'Finish' } else { 'Next' }
    $c.CancelButton.Visibility = if ($page -eq 'Done') { 'Hidden' } else { 'Visible' }
    Update-WizardPage $page
}

# Saves the settings of the current page; returns $false when the step cannot be left yet.
function Save-WizardPage {
    $c = $script:wc
    $kind = Get-WizardKind
    $page = (Get-WizardPages $kind)[$script:wizStep]
    switch ($page) {
        'Scenario' {
            $values = @{ Local = @{ scenario = 'Local' }; Scanner = @{ scenario = 'Network'; role = 'Scanner' }; Station = @{ scenario = 'Network'; role = 'Station' } }[$kind]
            Save-VlcUserSettings $values
        }
        'Scanning' {
            $mode = if ($c.ModeStandard.IsChecked) { 'Standard' } elseif ($c.ModeAsk.IsChecked) { 'Ask' } else { 'HighSpeed' }
            Save-VlcUserSettings @{ 'vl.mode' = $mode; 'vl.exportImmediately' = [bool]$c.ExportImmediately.IsChecked
                'vl.confirmStageMotion' = [bool]$c.ConfirmStage.IsChecked; 'vl.afterExport' = [string]$c.AfterExport.SelectedItem.Tag }
        }
        'PolyWorks' { Save-VlcUserSettings @{ 'polyworks.keepPieces' = [string]$c.KeepPieces.SelectedItem.Tag } }
        'Network' {
            $share = $c.SharePath.Text.Trim()
            if (-not $share) { $c.ShareStatus.Text = 'Enter the shared folder.'; $c.ShareStatus.Foreground = Get-Brush 'ErrorBrush'; return $false }
            Save-VlcUserSettings @{ 'network.share' = $share; 'network.autoOpenReports' = [bool]$c.AutoOpenReports.IsChecked }
            if ($kind -eq 'Scanner') { Set-AgentAutostart ([bool]$c.AgentAutostart.IsChecked) }
        }
        'Done' {
            if ($kind -eq 'Scanner' -and -not (Test-AgentRunning)) { Start-VlcAgent }
        }
    }
    return $true
}

function Show-SetupWizard {
    $ui = Import-Window 'WizardWindow.xaml'
    $script:ww = $ui.Window
    $script:wc = $ui.Controls
    $c = $script:wc
    $cfg = Read-VlcSettings
    $script:wizStep = 0
    $script:tabAdded = $false
    $script:lastBackup = ''

    $icon = Get-AppImage 'VLC_icon_256.png'
    $script:ww.Icon = $icon
    $c.AppIcon.Source = $icon
    $network = $cfg.scenario -eq 'Network'
    $c.ChooseLocal.IsChecked = -not $network
    $c.ChooseScanner.IsChecked = $network -and $cfg.role -ne 'Station'
    $c.ChooseStation.IsChecked = $network -and $cfg.role -eq 'Station'
    $c.ModeHighSpeed.IsChecked = $cfg.vl.mode -eq 'HighSpeed'
    $c.ModeStandard.IsChecked = $cfg.vl.mode -eq 'Standard'
    $c.ModeAsk.IsChecked = $cfg.vl.mode -eq 'Ask'
    $c.ExportImmediately.IsChecked = [bool]$cfg.vl.exportImmediately
    $c.ConfirmStage.IsChecked = [bool]$cfg.vl.confirmStageMotion
    foreach ($item in $c.AfterExport.Items) { if ([string]$item.Tag -eq [string]$cfg.vl.afterExport) { $c.AfterExport.SelectedItem = $item } }
    foreach ($item in $c.KeepPieces.Items) { if ([string]$item.Tag -eq [string]$cfg.polyworks.keepPieces) { $c.KeepPieces.SelectedItem = $item } }
    $c.SharePath.Text = [string]$cfg.network.share
    $c.AutoOpenReports.IsChecked = [bool]$cfg.network.autoOpenReports
    $c.AgentAutostart.IsChecked = $true

    $c.NextButton.Add_Click({
        try {
            if (-not (Save-WizardPage)) { return }
            $pages = Get-WizardPages (Get-WizardKind)
            if ($script:wizStep -ge $pages.Count - 1) { $script:ww.Close(); return }
            $script:wizStep++
            Show-WizardStep
        }
        catch { [void][System.Windows.MessageBox]::Show($script:ww, $_.Exception.Message, 'VL Connector', 'OK', 'Warning') }
    })
    $c.BackButton.Add_Click({ if ($script:wizStep -gt 0) { $script:wizStep--; Show-WizardStep } })
    $c.CancelButton.Add_Click({ $script:ww.Close() })
    $c.LocateVl.Add_Click({
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Filter = 'VL Application (VLApplication4.exe)|VLApplication4.exe|Programs (*.exe)|*.exe'
        if ($dlg.ShowDialog($script:ww)) { Save-VlcUserSettings @{ 'vl.exe' = $dlg.FileName }; Update-WizardPage 'Scanning' }
    })
    $c.AddTab.Add_Click({
        $kind = if ((Get-WizardKind) -eq 'Station') { 'Station' } else { 'Measure' }
        $c2 = $script:wc
        Set-WizardBar $c2.PwBar $c2.PwText 'Adding the VL Connector tab to PolyWorks... (a few seconds)' 'Info'
        Update-WizardScreen
        try {
            $script:lastBackup = Install-VlcPolyWorksTab $kind
            $script:tabAdded = $true
            Set-WizardBar $c2.PwBar $c2.PwText "Done: PolyWorks|Inspector has the tab 'VL Connector' with the $(if ($kind -eq 'Station') { 'VL Station' } else { 'Measure' }) button. The previous layout was saved." 'Success'
            $c2.UndoTab.Visibility = 'Visible'
            $c2.AddTab.Content = 'Add again'
        }
        catch { Set-WizardBar $c2.PwBar $c2.PwText $_.Exception.Message 'Warning' }
    })
    $c.UndoTab.Add_Click({
        $c2 = $script:wc
        try {
            Restore-VlcPolyWorksLayout $script:lastBackup
            $script:tabAdded = $false
            Set-WizardBar $c2.PwBar $c2.PwText 'The previous PolyWorks layout was loaded back.' 'Info'
            $c2.UndoTab.Visibility = 'Collapsed'
            $c2.AddTab.Content = 'Add to PolyWorks'
        }
        catch { Set-WizardBar $c2.PwBar $c2.PwText $_.Exception.Message 'Warning' }
    })
    $c.BuildLayouts.Add_Click({
        $c2 = $script:wc
        $c2.LayoutsText.Text = 'Building...'
        Update-WizardScreen
        try { & (Join-Path (Get-VlcPaths).AppDir 'polyworks\Make-ReportLayouts.ps1') | Out-Null; $c2.LayoutsText.Text = 'Built from your PolyWorks A4 layout.'; $c2.BuildLayouts.Content = 'Rebuild' }
        catch { $c2.LayoutsText.Text = $_.Exception.Message }
    })
    $c.ShareBrowse.Add_Click({
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dlg.ShowDialog() -eq 'OK') { $script:wc.SharePath.Text = $dlg.SelectedPath }
    })
    $c.ShareTest.Add_Click({
        $c2 = $script:wc
        $c2.ShareStatus.Text = 'Testing...'
        $c2.ShareTest.IsEnabled = $false
        Start-UiJob { param($AppDir, $Path) . (Join-Path $AppDir 'lib\Share.ps1'); Test-VlcShare $Path } @((Get-VlcPaths).AppDir, $c2.SharePath.Text.Trim()) {
            param($Out, $ErrorText)
            $r = @($Out)[0]
            $script:wc.ShareStatus.Text = if ($ErrorText) { $ErrorText } else { $r.Text }
            $script:wc.ShareStatus.Foreground = if ($r -and $r.Ok) { Get-Brush 'SuccessBrush' } else { Get-Brush 'ErrorBrush' }
            $script:wc.ShareTest.IsEnabled = $true
        }
    })
    $c.EditPrograms.Add_Click({
        $share = $script:wc.SharePath.Text.Trim()
        if (-not $share) { $script:wc.ShareStatus.Text = 'Enter the shared folder first.'; return }
        try {
            $file = Get-VlcProgramsFile $share
            if (-not (Test-Path -LiteralPath $file)) { Save-VlcPrograms $share @() }
            Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$file`""
        }
        catch { $script:wc.ShareStatus.Text = $_.Exception.Message }
    })
    Show-WizardStep
    [void]$script:ww.ShowDialog()
}
