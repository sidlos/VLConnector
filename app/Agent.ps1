<#
  Agent.ps1 - VL Connector for PolyWorks: the background agent of the scanner PC (network scenario).
  It runs in the notification area (tray). The operator works in VL as usual - AI Replay with the program
  chosen in VL - and the agent:
    1. follows every AI Replay run (VLReplay.ps1 -Watch) and exports the STL, named after the .vld4
       program plus date and time,
    2. sends the STL to the shared folder for the PolyWorks station (a local outbox keeps it while the
       folder is not reachable),
    3. opens the PDF report when the station has evaluated the scan (only scans made on this PC).
  Start: Start menu "VL Connector agent", or at Windows logon (settings window, page Network).
  Only one agent runs per user. Agent.ps1 -Stop ends the running agent (used by the installer).
#>
param([switch]$Stop)

$ErrorActionPreference = 'Stop'
if ($Stop) {
    $e = $null
    if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\VLConnector_AgentStop', [ref]$e)) { [void]$e.Set(); $e.Dispose() }
    exit 0
}
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $PSScriptRoot "lib\$lib.ps1") }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:agentMutex = New-Object System.Threading.Mutex($false, 'Local\VLConnector_Agent')
$owned = $false
try { $owned = $script:agentMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

$script:stopEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\VLConnector_AgentStop')
[void](Initialize-VlcLog 'Agent')
Write-VlcLog "=== Agent $(Get-VlcVersion) started (account $env:USERNAME)."
$script:paths = Get-VlcPaths
$script:runs = Join-Path $script:paths.DataDir 'runs'
New-Item -ItemType Directory -Force -Path $script:runs | Out-Null
$script:reports = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VL Connector\Reports'
$script:watcher = $null
$script:paused = $false
$script:lastPdf = ''
$script:balloonPdf = ''
$script:cycle = $null
$script:cycleDue = Get-Date
$script:stationText = 'station: checking...'
$script:outboxCount = 0

# --- tray icon --------------------------------------------------------------------------------------

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-Object System.Drawing.Icon (Join-Path $PSScriptRoot 'assets\VLC_icon.ico')
$tray.Text = 'VL Connector agent'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemStatus = $menu.Items.Add('Waiting for AI Replay in VL')
$itemStatus.Enabled = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemLast = $menu.Items.Add('Open the last report')
$itemLast.Enabled = $false
$itemFolder = $menu.Items.Add('Reports folder')
$itemSettings = $menu.Items.Add('Settings')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemPause = $menu.Items.Add('Pause')
$itemExit = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu
$tray.Visible = $true

function Update-Tray {
    $state = if ($script:paused) { 'Paused' } elseif ($script:watcher) { 'Waiting for AI Replay in VL' } else { 'Starting...' }
    $outbox = if ($script:outboxCount) { ", $($script:outboxCount) scan(s) waiting to be sent" } else { '' }
    $itemStatus.Text = "$state - $($script:stationText)$outbox"
    $text = "VL Connector: $state"
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $tray.Text = $text
}

function Show-Note([string]$Title, [string]$Text, [string]$Icon = 'Info', [string]$Pdf = '') {
    $script:balloonPdf = $Pdf
    $tray.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]$Icon)
}

# --- watcher: VLReplay.ps1 -Watch, one run per scan -----------------------------------------------

function Start-Watcher {
    $marker = Join-Path $script:runs ('watch_{0:yyyyMMdd_HHmmss_fff}.done' -f (Get-Date))
    $launcher = Join-Path $PSScriptRoot 'VLReplay.ps1'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$launcher`"", '-Watch', '-MarkerFile', "`"$marker`"")
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    $script:watcher = [pscustomobject]@{ Process = $p; Marker = $marker; Started = Get-Date }
    Write-VlcLog "Watcher started (PID $($p.Id))."
}

function Stop-Watcher {
    $w = $script:watcher
    if (-not $w) { return }
    try { [IO.File]::WriteAllText("$($w.Marker).cancel", 'cancel') } catch { }
    if (-not $w.Process.WaitForExit(8000)) { Write-VlcLog 'The watcher did not stop in time.' }
    foreach ($f in $w.Marker, "$($w.Marker).cancel", "$($w.Marker).status") { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $script:watcher = $null
}

# The watcher ended: an exported STL becomes a job for the PolyWorks station.
function Complete-Watcher {
    $w = $script:watcher
    $script:watcher = $null
    $m = $null
    try { $m = Read-KeyValueFile $w.Marker } catch { }
    foreach ($f in $w.Marker, "$($w.Marker).cancel", "$($w.Marker).status") { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    if (-not $m) {
        Write-VlcLog "The watcher ended without a marker (exit code $($w.Process.ExitCode))."
        # do not restart in a tight loop when something is broken
        if (((Get-Date) - $w.Started).TotalSeconds -lt 10) { $script:restartAt = (Get-Date).AddSeconds(30) }
        return
    }
    switch ($m.STATE) {
        'OK' {
            if (-not $m.PROGRAM) {
                # without the program the station cannot pick the template; a guess could pick a wrong one
                Write-VlcLog "Scan $($m.STL): the VL program was not recognized, not sent."
                Show-Note 'Scan not sent' "The VL program of the scan was not recognized. The STL is saved: $($m.STL)" 'Warning'
                return
            }
            $program = [IO.Path]::GetFileNameWithoutExtension($m.PROGRAM)
            try {
                $id = New-VlcJobId $program
                [void](New-VlcOutboxJob $id $program $m.STL $m.PROGRAM)
                Add-VlcPendingJob $id $program
                Write-VlcLog "Scan $program ($($m.STL)) -> job $id."
                Show-Note 'Scan saved' "$program - sent to the PolyWorks station for evaluation."
                $script:cycleDue = Get-Date
            }
            catch { Write-VlcLog "Job for $($m.STL): $($_.Exception.Message)"; Show-Note 'Scan not sent' $_.Exception.Message 'Warning' }
        }
        'CANCELLED' { Write-VlcLog "Watcher: cancelled ($($m.MESSAGE))." }
        'BUSY' { $script:restartAt = (Get-Date).AddSeconds(10) }
        default {
            Write-VlcLog "Watcher: $($m.STATE) $($m.MESSAGE)"
            Show-Note 'Scan not exported' $m.MESSAGE 'Warning'
            if (((Get-Date) - $w.Started).TotalSeconds -lt 10) { $script:restartAt = (Get-Date).AddSeconds(30) }
        }
    }
}

# --- network cycle in a background runspace (a slow network folder must not freeze the tray) ------

$script:CycleWork = {
    param($AppDir, $Share, $Reports)
    foreach ($lib in 'Settings', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $AppDir "lib\$lib.ps1") }
    $r = [pscustomobject]@{ Sent = @(); Done = @(); Stations = @(); Outbox = 0; ShareOk = $false }
    if ($Share -and (Test-Path -LiteralPath (Join-Path $Share 'jobs'))) {
        $r.ShareOk = $true
        $r.Sent = @(Send-VlcOutbox $Share)
        $r.Done = @(Receive-VlcReports $Share $Reports)
        $r.Stations = @(Get-VlcStations $Share)
    }
    $r.Outbox = @(Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job').Count
    $r
}

function Start-Cycle([string]$Share, [int]$PollSec) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($script:CycleWork.ToString()).AddArgument($PSScriptRoot).AddArgument($Share).AddArgument($script:reports)
    $script:cycle = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    $script:cycleDue = (Get-Date).AddSeconds([Math]::Max(2, $PollSec))
}

function Complete-Cycle([bool]$AutoOpen) {
    $c = $script:cycle
    $script:cycle = $null
    $r = $null
    try { $r = @($c.PS.EndInvoke($c.Handle))[0] } catch { Write-VlcLog "Network cycle: $($_.Exception.Message)" }
    $c.PS.Dispose()
    if (-not $r) { return }
    foreach ($id in $r.Sent) { Write-VlcLog "Job $id sent to the shared folder." }
    foreach ($d in $r.Done) {
        if ($d.State -eq 'OK') {
            Write-VlcLog "Report $($d.JobId): $($d.Verdict) $($d.Summary) $($d.Pdf)"
            if ($d.Pdf) { $script:lastPdf = $d.Pdf; $itemLast.Enabled = $true }
            Show-Note "$($d.Part): $($d.Verdict)" $d.Summary $(if ($d.Verdict -eq 'OK') { 'Info' } else { 'Warning' }) $d.Pdf
            if ($d.Pdf -and $AutoOpen) { try { Start-Process -FilePath $d.Pdf } catch { } }
        }
        else {
            Write-VlcLog "Report $($d.JobId): evaluation failed - $($d.Message)"
            Show-Note "$($d.Part): not evaluated" $d.Message 'Error'
        }
    }
    $script:outboxCount = $r.Outbox
    $live = @($r.Stations | Where-Object { $_.State -ne 'Stopped' -and $_.Age -lt 120 })
    $script:stationText = if (-not $r.ShareOk) { 'shared folder not reachable' } elseif ($live.Count) { 'station online' } else { 'station offline' }
}

# --- events and main loop --------------------------------------------------------------------------

$itemLast.Add_Click({ if ($script:lastPdf -and (Test-Path -LiteralPath $script:lastPdf)) { Start-Process -FilePath $script:lastPdf } })
$tray.Add_BalloonTipClicked({ if ($script:balloonPdf -and (Test-Path -LiteralPath $script:balloonPdf)) { Start-Process -FilePath $script:balloonPdf } })
$tray.Add_DoubleClick({ if ($script:lastPdf -and (Test-Path -LiteralPath $script:lastPdf)) { Start-Process -FilePath $script:lastPdf } })
$itemFolder.Add_Click({
    New-Item -ItemType Directory -Force -Path $script:reports | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:reports)`""
})
$itemSettings.Add_Click({
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $PSScriptRoot 'VLConnector.ps1')`"" -WindowStyle Hidden
})
$itemPause.Add_Click({
    if ($script:paused) { $script:paused = $false; $itemPause.Text = 'Pause'; Write-VlcLog 'Resumed.' }
    else { $script:paused = $true; $itemPause.Text = 'Resume'; Stop-Watcher; Write-VlcLog 'Paused.' }
    Update-Tray
})
$itemExit.Add_Click({ [System.Windows.Forms.Application]::Exit() })

$script:restartAt = Get-Date
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        if ($script:stopEvent.WaitOne(0)) { Write-VlcLog 'Stop requested.'; [System.Windows.Forms.Application]::Exit(); return }
        $cfg = Read-VlcSettings
        if ($script:watcher -and $script:watcher.Process.HasExited) { Complete-Watcher }
        if (-not $script:paused -and -not $script:watcher -and (Get-Date) -ge $script:restartAt) { Start-Watcher }
        if ($script:cycle -and $script:cycle.Handle.IsCompleted) { Complete-Cycle ([bool]$cfg.network.autoOpenReports) }
        if (-not $script:cycle -and (Get-Date) -ge $script:cycleDue) { Start-Cycle ([string]$cfg.network.share) ([int]$cfg.network.pollSec) }
        Update-Tray
    }
    catch { Write-VlcLog "Agent: $($_.Exception.Message)" }
})
$timer.Start()
Update-Tray
try { [System.Windows.Forms.Application]::Run() }
finally {
    $timer.Stop()
    Stop-Watcher
    $tray.Visible = $false
    $tray.Dispose()
    Write-VlcLog 'Agent stopped.'
    $script:agentMutex.ReleaseMutex()
}
