<#
  Agent.ps1 - VL Connector for PolyWorks: the background agent of the scanner PC (network scenario).
  It runs in the notification area (tray). The operator works in VL as usual - AI Replay with the program
  chosen in VL - and the agent:
    1. follows every AI Replay run (VLReplay.ps1 -Watch) and exports the STL, named after the .vld4
       program plus date and time; a finished scan is noted in the local inbox at once,
    2. sends the STL to the shared folder for the PolyWorks station (lib\AgentCycle.ps1 in the background:
       inbox -> outbox job -> shared folder; the outbox keeps it while the folder is not reachable),
    3. opens the PDF report when the station has evaluated the scan (only scans made on this PC).
  A NOK result keeps the tray icon red until it is looked at. Problems that last (the watcher keeps failing,
  the settings cannot be read) show an orange icon and the reason in the menu.
  Start: Start menu "VL Connector agent", or at Windows logon (settings window, page Network).
  Only one agent runs per user. Agent.ps1 -Stop ends the running agent (used by the installer).
#>
param([switch]$Stop)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'lib\LanguageCheck.ps1') -Caller Agent -Mode $ExecutionContext.SessionState.LanguageMode -Show:(-not $Stop)
    exit 1
}

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
$script:cycleScript = Join-Path $PSScriptRoot 'lib\AgentCycle.ps1'
$script:watcher = $null
$script:watcherFailures = 0
$script:restartAt = Get-Date
$script:paused = $false
$script:lastPdf = ''
$script:balloonPdf = ''
$script:cycle = $null
$script:cycleRunspace = $null
$script:cycleDue = Get-Date
$script:stationText = 'station: checking...'
$script:stationSeen = @{}
$script:outboxCount = 0
$script:cfg = $null
$script:cfgReadAt = [datetime]::MinValue
$script:settingsError = ''
$script:watcherError = ''
$script:nokPending = $false

# --- tray icon --------------------------------------------------------------------------------------

# The icon of VL Connector with a colored dot in the corner (red: a NOK result not seen yet; orange: a problem).
function New-BadgeIcon([System.Drawing.Icon]$Base, [System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = 'AntiAlias'
        $g.DrawIcon((New-Object System.Drawing.Icon($Base, 32, 32)), (New-Object System.Drawing.Rectangle(0, 0, 32, 32)))
        $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 16, 16, 16, 16)
        $g.FillEllipse((New-Object System.Drawing.SolidBrush($Color)), 18, 18, 12, 12)
    }
    finally { $g.Dispose() }
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$script:iconNormal = New-Object System.Drawing.Icon (Join-Path $PSScriptRoot 'assets\VLC_icon.ico')
$script:iconNok = New-BadgeIcon $script:iconNormal ([System.Drawing.Color]::FromArgb(200, 30, 30))
$script:iconProblem = New-BadgeIcon $script:iconNormal ([System.Drawing.Color]::FromArgb(230, 130, 0))
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $script:iconNormal
$tray.Text = 'VL Connector agent'
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$itemStatus = $menu.Items.Add('Waiting for AI Replay in VL')
$itemStatus.Enabled = $false
$itemProblem = $menu.Items.Add('')
$itemProblem.Enabled = $false
$itemProblem.Visible = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$itemLast = $menu.Items.Add('Open the last report')
$itemLast.Enabled = $false
$itemSeen = $menu.Items.Add('Mark the NOK result as seen')
$itemSeen.Visible = $false
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
    $problem = (@($script:settingsError, $script:watcherError) | Where-Object { $_ }) -join ' '
    $itemProblem.Text = $problem
    $itemProblem.Visible = [bool]$problem
    $itemSeen.Visible = $script:nokPending
    $tray.Icon = if ($script:nokPending) { $script:iconNok } elseif ($problem) { $script:iconProblem } else { $script:iconNormal }
    $text = if ($script:nokPending) { 'VL Connector: a NOK result' } elseif ($problem) { 'VL Connector: needs attention' } else { "VL Connector: $state" }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 63) }
    $tray.Text = $text
}

# A balloon never has an empty text (Windows refuses it, and later results would not be shown).
function Show-Note([string]$Title, [string]$Text, [string]$Icon = 'Info', [string]$Pdf = '') {
    if (-not $Title) { $Title = 'VL Connector' }
    if (-not $Text) { $Text = $Title }
    $script:balloonPdf = $Pdf
    $tray.ShowBalloonTip(8000, $Title, $Text, [System.Windows.Forms.ToolTipIcon]$Icon)
}

function Confirm-NokSeen { if ($script:nokPending) { $script:nokPending = $false; Update-Tray } }

# --- settings: read every 5 s; the last good ones stay when they cannot be read -----------------------

function Get-AgentSettings {
    if ($script:cfg -and ((Get-Date) - $script:cfgReadAt).TotalSeconds -lt 5) { return $script:cfg }
    $script:cfgReadAt = Get-Date
    try {
        $script:cfg = Read-VlcSettings
        if ($script:settingsError) { Write-VlcLog 'The settings can be read again.' }
        $script:settingsError = ''
    }
    catch {
        if (-not $script:settingsError) { Write-VlcLog "The settings cannot be read, the last ones stay: $($_.Exception.Message)" }
        $script:settingsError = "The settings cannot be read: $($_.Exception.Message)"
        if (-not $script:cfg) { throw }
    }
    return $script:cfg
}

# --- watcher: VLReplay.ps1 -Watch, one run per scan -----------------------------------------------

function Start-Watcher {
    $marker = Join-Path $script:runs ('watch_{0:yyyyMMdd_HHmmss_fff}.done' -f (Get-Date))
    $launcher = Join-Path $PSScriptRoot 'VLReplay.ps1'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$launcher`"", '-Watch', '-MarkerFile', "`"$marker`"")
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argList -WindowStyle Hidden -PassThru
    $null = $p.Handle
    $script:watcher = [pscustomobject]@{ Process = $p; Marker = $marker; Started = Get-Date }
    Write-VlcLog "Watcher started (PID $($p.Id))."
}

# Pause and Exit: the watcher is asked to stop (Cancel file) and ended when it does not within 8 s. A scan it
# finished in the meantime is still sent.
function Stop-Watcher {
    $w = $script:watcher
    if (-not $w) { return }
    try { [IO.File]::WriteAllText("$($w.Marker).cancel", 'cancel') } catch { }
    if (-not $w.Process.WaitForExit(8000)) {
        Write-VlcLog "The watcher (PID $($w.Process.Id)) did not stop within 8 s; it is ended."
        try { $w.Process.Kill(); [void]$w.Process.WaitForExit(5000) } catch { Write-VlcLog "The watcher could not be ended: $($_.Exception.Message)" }
    }
    Complete-Watcher
}

# The watcher ended: an exported STL is noted in the inbox (the background cycle makes the job from it). A watcher
# that keeps ending at once is restarted after a growing pause (30 s up to 10 min) and shown as a problem.
function Complete-Watcher {
    $w = $script:watcher
    $script:watcher = $null
    if (-not $w) { return }
    $m = $null
    try { $m = Read-KeyValueFile $w.Marker } catch { }
    foreach ($f in $w.Marker, "$($w.Marker).cancel", "$($w.Marker).status") { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    $quick = ((Get-Date) - $w.Started).TotalSeconds -lt 10
    $state = if ($m) { [string]$m.STATE } else { '' }
    if ($state -eq 'OK' -or -not $quick) { $script:watcherFailures = 0; $script:watcherError = '' }
    elseif ($state -notin 'CANCELLED', 'BUSY') {
        $script:watcherFailures++
        $wait = [Math]::Min(600, 30 * [Math]::Pow(2, $script:watcherFailures - 1))
        $script:restartAt = (Get-Date).AddSeconds($wait)
        if ($script:watcherFailures -ge 3) { $script:watcherError = "Following VL keeps failing ($($script:watcherFailures) times, see the log); next try in $([int]$wait) s." }
    }
    if (-not $m) { Write-VlcLog "The watcher ended without a marker (exit code $($w.Process.ExitCode))."; return }
    switch ($state) {
        'OK' {
            if (-not $m.PROGRAM) {
                # without the program the station cannot pick the template; a guess could pick a wrong one
                Write-VlcLog "Scan $($m.STL): the VL program was not recognized, not sent."
                Show-Note 'Scan not sent' "The VL program of the scan was not recognized. The STL is saved: $($m.STL)" 'Warning'
                return
            }
            $program = Get-VlcProgramName $m.PROGRAM
            try {
                $id = New-VlcJobId $program
                Add-VlcInboxScan $id $program $m.STL $m.PROGRAM
                Write-VlcLog "Scan $program ($($m.STL)) -> job $id."
                Show-Note 'Scan saved' "$program - it goes to the PolyWorks station for evaluation."
                $script:cycleDue = Get-Date
            }
            catch { Write-VlcLog "Job for $($m.STL): $($_.Exception.Message)"; Show-Note 'Scan not sent' $_.Exception.Message 'Warning' }
        }
        'CANCELLED' { Write-VlcLog "Watcher: cancelled ($($m.MESSAGE))." }
        'BUSY' { $script:restartAt = (Get-Date).AddSeconds(10) }
        default {
            Write-VlcLog "Watcher: $state $($m.MESSAGE)"
            Show-Note 'Scan not exported' $m.MESSAGE 'Warning'
        }
    }
}

# --- network cycle in a background runspace (a slow network folder must not freeze the tray) ------
# One runspace for all cycles; a cycle that hangs longer than 60 s is left behind with its runspace.

function Start-Cycle([string]$Share, [int]$PollSec) {
    if (-not $script:cycleRunspace -or $script:cycleRunspace.RunspaceStateInfo.State -ne 'Opened') {
        $script:cycleRunspace = [RunspaceFactory]::CreateRunspace()
        $script:cycleRunspace.Open()
    }
    $ps = [PowerShell]::Create()
    $ps.Runspace = $script:cycleRunspace
    [void]$ps.AddCommand($script:cycleScript).AddParameter('Share', $Share).AddParameter('Reports', $script:reports)
    $script:cycle = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
    $script:cycleDue = (Get-Date).AddSeconds([Math]::Max(2, $PollSec))
}

function Stop-HungCycle {
    $c = $script:cycle
    $script:cycle = $null
    Write-VlcLog 'The network cycle did not finish within 60 s (network folder not answering?); it is left behind.'
    try { [void]$c.PS.BeginStop($null, $null) } catch { }
    $script:cycleRunspace = $null
    $script:stationText = 'shared folder not answering'
}

function Complete-Cycle([bool]$AutoOpen, [int]$JobTimeoutMin) {
    $c = $script:cycle
    $script:cycle = $null
    $r = $null
    try { $r = @($c.PS.EndInvoke($c.Handle))[0] } catch { Write-VlcLog "Network cycle: $($_.Exception.Message)" }
    if (-not $r -and $c.PS.Streams.Error.Count) { Write-VlcLog "Network cycle: $($c.PS.Streams.Error[0])" }
    $c.PS.Dispose()
    if (-not $r) { return }
    foreach ($f in @($r.Failed)) { Show-Note 'Scan not sent' "$($f.JobId): $($f.Message)" 'Warning' }
    # one note for all results of this cycle; the newest PDF opens (setting "open reports")
    $done = @($r.Done)
    if ($done.Count) {
        foreach ($d in $done) { Write-VlcLog "Report $($d.JobId): $($d.State) $($d.Verdict) $($d.Summary) $($d.Message) $($d.Pdf)".Trim() }
        $nok = @($done | Where-Object { $_.State -ne 'OK' -or $_.Verdict -ne 'OK' })
        $withPdf = @($done | Where-Object { $_.Pdf })
        if ($withPdf.Count) { $script:lastPdf = $withPdf[-1].Pdf; $itemLast.Enabled = $true }
        if ($nok.Count) { $script:nokPending = $true }
        $lines = @($done | ForEach-Object {
            if ($_.State -eq 'OK') { "$($_.Part): $($_.Verdict) - $($_.Summary)" } else { "$($_.Part): not evaluated - $($_.Message)" } })
        $title = if ($done.Count -eq 1) { $lines[0] -replace ' - .*$', '' } else { "$($done.Count) results, $($nok.Count) not OK" }
        $icon = if (@($done | Where-Object { $_.State -ne 'OK' }).Count) { 'Error' } elseif ($nok.Count) { 'Warning' } else { 'Info' }
        Show-Note $title ($lines -join "`n") $icon $(if ($withPdf.Count) { $withPdf[-1].Pdf } else { '' })
        if ($withPdf.Count -and $AutoOpen) { try { Start-Process -FilePath $withPdf[-1].Pdf } catch { } }
    }
    $script:outboxCount = [int]$r.Outbox
    $live = @(Update-VlcStationLiveness $script:stationSeen @($r.Stations) (Get-Date) $JobTimeoutMin | Where-Object { $_.Online })
    $working = @($live | Where-Object { $_.State -ne 'Paused' })
    $script:stationText = if (-not $r.ShareOk) { 'shared folder not reachable' } elseif ($working.Count) { 'station online' } elseif ($live.Count) { 'station paused' } else { 'station offline' }
}

# --- events and main loop --------------------------------------------------------------------------

$openLast = { Confirm-NokSeen; if ($script:lastPdf -and (Test-Path -LiteralPath $script:lastPdf)) { Start-Process -FilePath $script:lastPdf } }
$itemLast.Add_Click($openLast)
$tray.Add_DoubleClick($openLast)
$tray.Add_BalloonTipClicked({ Confirm-NokSeen; if ($script:balloonPdf -and (Test-Path -LiteralPath $script:balloonPdf)) { Start-Process -FilePath $script:balloonPdf } })
$itemSeen.Add_Click({ Confirm-NokSeen })
$itemFolder.Add_Click({
    New-Item -ItemType Directory -Force -Path $script:reports | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:reports)`""
})
$itemSettings.Add_Click({
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $PSScriptRoot 'VLConnector.ps1')`"" -WindowStyle Hidden
})
$itemPause.Add_Click({
    if ($script:paused) { $script:paused = $false; $script:watcherFailures = 0; $script:restartAt = Get-Date; $itemPause.Text = 'Pause'; Write-VlcLog 'Resumed.' }
    else { $script:paused = $true; $itemPause.Text = 'Resume'; Stop-Watcher; Write-VlcLog 'Paused.' }
    Update-Tray
})
$itemExit.Add_Click({ [System.Windows.Forms.Application]::Exit() })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        if ($script:stopEvent.WaitOne(0)) { Write-VlcLog 'Stop requested.'; [System.Windows.Forms.Application]::Exit(); return }
        $cfg = Get-AgentSettings
        if ($script:watcher -and $script:watcher.Process.HasExited) { Complete-Watcher }
        if (-not $script:paused -and -not $script:watcher -and (Get-Date) -ge $script:restartAt) { Start-Watcher }
        if ($script:cycle -and $script:cycle.Handle.IsCompleted) { Complete-Cycle ([bool]$cfg.network.autoOpenReports) ([int]$cfg.network.jobTimeoutMin) }
        elseif ($script:cycle -and ((Get-Date) - $script:cycle.Started).TotalSeconds -gt 60) { Stop-HungCycle }
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
