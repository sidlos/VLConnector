# VL Connector scan window (network scenario, scanner PC): starts AI Replay through VLReplay.ps1, sends the
# STL to the shared folder, shows whether the PolyWorks station is online and opens the PDF reports of the
# scans made on this PC. Dot-source this file (it needs the libraries loaded by VLConnector.ps1 plus
# lib\Jobs.ps1) and call Show-ScanWindow.

$script:ScanHistoryMax = 100

function Get-ScanRunsDir {
    $dir = Join-Path (Get-VlcPaths).DataDir 'runs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Get-ScanHistoryFile { return Join-Path (Get-VlcPaths).DataDir 'history.txt' }

# history.txt: JobId;Part;Time;State;Summary;Pdf (newest first)
function Read-ScanHistory {
    $file = Get-ScanHistoryFile
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @([IO.File]::ReadAllLines($file) | Where-Object { $_ } | ForEach-Object {
        $f = $_ -split ';', 6
        [pscustomobject]@{ JobId = $f[0]; Part = $f[1]; Time = $f[2]; State = $f[3]; Summary = $f[4]; Pdf = $f[5] }
    })
}

function Save-ScanHistory {
    $lines = @($script:history | Select-Object -First $script:ScanHistoryMax | ForEach-Object {
        '{0};{1};{2};{3};{4};{5}' -f $_.JobId, $_.Part, $_.Time, $_.State, (($_.Summary -replace ';', ',') -replace '[\r\n]', ' '), $_.Pdf
    })
    try { [IO.File]::WriteAllLines((Get-ScanHistoryFile), [string[]]$lines, (New-Object Text.UTF8Encoding($true))) } catch { }
}

function Set-ScanRow([string]$JobId, [hashtable]$Values) {
    $row = @($script:history | Where-Object { $_.JobId -eq $JobId })[0]
    if (-not $row) { return }
    foreach ($k in $Values.Keys) { $row.$k = $Values[$k] }
    Save-ScanHistory
    Update-ScanHistoryView
}

function Update-ScanHistoryView {
    $tones = @{ OK = 'Success'; NOK = 'Error'; Error = 'Error'; Cancelled = 'Warning' }
    $rows = foreach ($h in $script:history) {
        $tone = $tones[[string]$h.State]
        $fore = if ($tone) { Get-Brush "${tone}Brush" } else { Get-Brush 'AccentBrush' }
        $back = if ($tone) { Get-Brush "${tone}BackBrush" } else { Get-Brush 'AccentLightBrush' }
        $time = try { ([datetime]$h.Time).ToString('HH:mm') } catch { '' }
        [pscustomobject]@{ Time = $time; Part = $h.Part; State = $h.State; Summary = $h.Summary; Pdf = $h.Pdf
            PdfVisibility = $(if ($h.Pdf -and (Test-Path -LiteralPath $h.Pdf)) { 'Visible' } else { 'Collapsed' }); Fore = $fore; Back = $back }
    }
    $script:kc.History.ItemsSource = @($rows)
    $script:kc.HistoryEmpty.Visibility = if ($script:history.Count) { 'Collapsed' } else { 'Visible' }
}

function Set-ScanState([string]$Text, [string]$Tone = 'Info') {
    $c = $script:kc
    $c.StateText.Text = $Text
    $style = @{ Info = 'InfoBar'; Success = 'SuccessBar'; Warning = 'WarningBar'; Error = 'ErrorBar' }[$Tone]
    $c.StateBar.Style = $script:kw.FindResource($style)
    $c.StateIcon.Text = @{ Info = [string][char]0xE946; Success = [string][char]0xE73E; Warning = [string][char]0xE7BA; Error = [string][char]0xE783 }[$Tone]
    $c.StateIcon.Foreground = Get-Brush $(@{ Info = 'AccentBrush'; Success = 'SuccessBrush'; Warning = 'WarningBrush'; Error = 'ErrorBrush' }[$Tone])
}

function Start-Scan {
    $c = $script:kc
    $part = @($script:parts | Where-Object { $_.Part -eq [string]$c.PartList.SelectedItem })[0]
    if (-not $part) { Set-ScanState 'Choose the part first.' 'Warning'; return }
    if (-not $part.VlProgram) { Set-ScanState "The parts list has no VL program for $($part.Part)." 'Warning'; return }
    $id = New-VlcJobId $part.Part
    $marker = Join-Path (Get-ScanRunsDir) "$id.done"
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($script:kw)).Handle
    $launcher = Join-Path (Get-VlcPaths).AppDir 'VLReplay.ps1'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$launcher`"", "`"$($part.VlProgram)`"",
        '-MarkerFile', "`"$marker`"", '-JobId', $id, '-ReturnFocusHwnd', [string][int64]$hwnd)
    if ($part.Options) { $argList += @('-Options', "`"$($part.Options)`"") }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    $script:scan = [pscustomobject]@{ JobId = $id; Part = $part.Part; Program = $part.VlProgram; Marker = $marker; Process = $proc }
    $script:history = @([pscustomobject]@{ JobId = $id; Part = $part.Part; Time = (Get-Date).ToString('s'); State = 'Scanning'; Summary = "VL program $($part.VlProgram)"; Pdf = '' }) + @($script:history)
    Save-ScanHistory
    Update-ScanHistoryView
    $c.StartScan.IsEnabled = $false
    $c.CancelScan.IsEnabled = $true
    $c.PartList.IsEnabled = $false
    Set-ScanState 'Starting AI Replay in VL...'
    Write-VlcLog "Scan $id started ($($part.Part), $($part.VlProgram))."
}

# Called every second while a scan runs: progress text from the .status file, end of the launcher.
function Update-Scan {
    $s = $script:scan
    if (-not $s) { return }
    $status = $null
    try { $status = Read-KeyValueFile "$($s.Marker).status" } catch { }
    if ($status -and $status.TEXT) { Set-ScanState $status.TEXT }
    if (-not $s.Process.HasExited -and -not (Test-Path -LiteralPath $s.Marker)) { return }
    $m = $null
    for ($i = 0; $i -lt 10 -and -not $m; $i++) { try { $m = Read-KeyValueFile $s.Marker } catch { Start-Sleep -Milliseconds 200 } }
    if (-not $m -and -not $s.Process.HasExited) { return }
    $script:scan = $null
    $c = $script:kc
    $c.StartScan.IsEnabled = $true; $c.CancelScan.IsEnabled = $false; $c.PartList.IsEnabled = $true
    $state = if ($m) { $m.STATE } else { 'ERROR' }
    $message = if ($m) { $m.MESSAGE } else { 'The scan ended without a result (see the VL Connector log).' }
    switch ($state) {
        'OK' {
            $script:toSubmit.Add([pscustomobject]@{ JobId = $s.JobId; Part = $s.Part; Stl = $m.STL; Program = $s.Program })
            Set-ScanRow $s.JobId @{ State = 'Sending'; Summary = 'STL ready, sending it to the station...' }
            Set-ScanState "Scan of $($s.Part) finished. The PolyWorks station evaluates it; the report opens when it is ready." 'Success'
        }
        'CANCELLED' { Set-ScanRow $s.JobId @{ State = 'Cancelled'; Summary = $message }; Set-ScanState 'The scan was cancelled.' 'Warning' }
        default { Set-ScanRow $s.JobId @{ State = 'Error'; Summary = $message }; Set-ScanState "The scan failed: $message" 'Error' }
    }
    foreach ($f in $s.Marker) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Write-VlcLog "Scan $($s.JobId) ended: $state $message"
}

$script:ScanCycleWork = {
    param($AppDir, $Share, $Submit, $LocalReports)
    foreach ($lib in 'Settings', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $AppDir "lib\$lib.ps1") }
    $result = [pscustomobject]@{ Submitted = @(); SubmitErrors = @(); Sent = @(); Done = @(); Stations = @(); Outbox = 0; ShareOk = $false }
    foreach ($j in $Submit) {
        try { [void](New-VlcOutboxJob $j.JobId $j.Part $j.Stl $j.Program); Add-VlcPendingJob $j.JobId $j.Part; $result.Submitted += $j.JobId }
        catch { $result.SubmitErrors += [pscustomobject]@{ JobId = $j.JobId; Message = $_.Exception.Message } }
    }
    if ($Share -and (Test-Path -LiteralPath (Join-Path $Share 'jobs'))) {
        $result.ShareOk = $true
        $result.Sent = @(Send-VlcOutbox $Share)
        $result.Done = @(Receive-VlcReports $Share $LocalReports)
        $result.Stations = @(Get-VlcStations $Share)
    }
    $result.Outbox = @(Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job').Count
    $result
}

function Start-ScanCycle {
    if ($script:cycleRunning) { return }
    $script:cycleRunning = $true
    $submit = $script:toSubmit.ToArray()
    $script:toSubmit.Clear()
    Start-UiJob $script:ScanCycleWork @((Get-VlcPaths).AppDir, $script:share, $submit, $script:localReports) {
        param($Out, $ErrorText)
        $script:cycleRunning = $false
        $c = $script:kc
        $r = @($Out)[0]
        if ($ErrorText -or -not $r) { $c.StationText.Text = 'Station: unknown'; Write-VlcLog "Cycle: $ErrorText"; return }
        foreach ($e in $r.SubmitErrors) { Set-ScanRow $e.JobId @{ State = 'Error'; Summary = $e.Message } }
        foreach ($id in $r.Submitted) { Set-ScanRow $id @{ State = 'Sending'; Summary = 'Waiting for the shared folder...' } }
        foreach ($id in $r.Sent) { Set-ScanRow $id @{ State = 'Waiting'; Summary = 'Sent. Waiting for the PolyWorks station...' } }
        foreach ($d in $r.Done) {
            $state = if ($d.State -eq 'OK') { $d.Verdict } else { 'Error' }
            $summary = if ($d.State -eq 'OK') { $d.Summary } else { $d.Message }
            Set-ScanRow $d.JobId @{ State = $state; Summary = $summary; Pdf = $d.Pdf }
            Write-VlcLog "Report $($d.JobId): $state $summary"
            if ($d.Pdf -and $script:autoOpen) { try { Start-Process -FilePath $d.Pdf } catch { } }
            if ($d.State -eq 'OK') { Set-ScanState "$($d.Part): $($d.Verdict) - $($d.Summary)" $(if ($d.Verdict -eq 'OK') { 'Success' } else { 'Error' }) }
        }
        $c.OutboxText.Text = if ($r.Outbox) { "$($r.Outbox) scan(s) waiting to be sent" } elseif (-not $r.ShareOk) { 'Shared folder not reachable' } else { '' }
        $live = @($r.Stations | Where-Object { $_.State -ne 'Stopped' -and $_.Age -lt 120 })
        if ($live.Count) {
            $c.StationDot.Fill = Get-Brush 'SuccessBrush'
            $c.StationText.Text = 'Station online: ' + (($live | ForEach-Object { if ($_.State -eq 'Busy') { "$($_.Name) (busy)" } else { $_.Name } }) -join ', ')
        }
        else {
            $c.StationDot.Fill = Get-Brush 'ErrorBrush'
            $c.StationText.Text = if ($r.ShareOk) { 'Station offline' } else { 'Shared folder not reachable' }
        }
    }
}

function Show-ScanWindow {
    $ui = Import-Window 'ScanWindow.xaml'
    $script:kw = $ui.Window
    $script:kc = $ui.Controls
    $c = $script:kc
    $cfg = Read-VlcSettings
    $script:share = [string]$cfg.network.share
    $script:autoOpen = [bool]$cfg.network.autoOpenReports
    $script:localReports = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VL Connector\Reports'
    $script:toSubmit = New-Object Collections.Generic.List[object]
    $script:history = @(Read-ScanHistory)
    $script:scan = $null
    $script:parts = @()
    $script:cycleRunning = $false

    $icon = Get-AppImage 'VLC_icon_256.png'
    $script:kw.Icon = $icon
    $c.AppIcon.Source = $icon
    $c.ShareText.Text = if ($script:share) { "Shared folder: $($script:share)" } else { 'No shared folder set - open Settings, page Network.' }
    # a scan still marked as running from an earlier session cannot be followed any more
    foreach ($h in $script:history) { if ($h.State -eq 'Scanning') { $h.State = 'Error'; $h.Summary = 'The window was closed during the scan.' } }
    Update-ScanHistoryView

    if ($script:share) {
        try {
            $script:parts = @(Get-VlcParts $script:share)
            $c.PartList.ItemsSource = @($script:parts | ForEach-Object { $_.Part })
            if (-not $script:parts.Count) { Set-ScanState 'The parts list is empty. Add parts in Settings, page Network.' 'Warning' }
        }
        catch { Set-ScanState "The parts list cannot be read: $($_.Exception.Message)" 'Error' }
    }
    else { Set-ScanState 'Set the shared folder in Settings (page Network) first.' 'Warning'; $c.StartScan.IsEnabled = $false }

    $c.PartList.Add_SelectionChanged({
        $p = @($script:parts | Where-Object { $_.Part -eq [string]$this.SelectedItem })[0]
        $script:kc.PartInfo.Text = if ($p) { "VL program: $($p.VlProgram)    Template: $($p.Template)" + $(if ($p.Options) { "    Options: $($p.Options)" } else { '' }) } else { '' }
    })
    if ($script:parts.Count -eq 1) { $c.PartList.SelectedIndex = 0 }
    $c.StartScan.Add_Click({ Start-Scan })
    $c.CancelScan.Add_Click({
        if ($script:scan) { [IO.File]::WriteAllText("$($script:scan.Marker).cancel", 'cancel'); Set-ScanState 'Cancelling...' 'Warning' }
    })
    $c.History.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($sender, $e)
        $pdf = [string]$e.OriginalSource.Tag
        if ($pdf -and (Test-Path -LiteralPath $pdf)) { Start-Process -FilePath $pdf }
    })
    $c.OpenReports.Add_Click({
        New-Item -ItemType Directory -Force -Path $script:localReports | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:localReports)`""
    })
    $c.OpenSettings.Add_Click({
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path (Get-VlcPaths).AppDir 'VLConnector.ps1')`"" -WindowStyle Hidden
    })
    $script:kw.Add_Closing({
        param($sender, $e)
        if ($script:scan) {
            $answer = [System.Windows.MessageBox]::Show($script:kw, 'A scan is running. If you close this window, its STL is not sent to the station. Close anyway?', 'VL Connector', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $e.Cancel = $true }
        }
    })

    $fast = New-Object System.Windows.Threading.DispatcherTimer
    $fast.Interval = [TimeSpan]::FromSeconds(1)
    $fast.Add_Tick({ Update-Scan; if ($script:toSubmit.Count) { Start-ScanCycle } })
    $fast.Start()
    $slow = New-Object System.Windows.Threading.DispatcherTimer
    $slow.Interval = [TimeSpan]::FromSeconds([Math]::Max(2, [int]$cfg.network.pollSec))
    $slow.Add_Tick({ Start-ScanCycle })
    $slow.Start()
    $script:kw.Add_ContentRendered({ Start-ScanCycle })
    [void]$script:kw.ShowDialog()
    $fast.Stop(); $slow.Stop()
}
