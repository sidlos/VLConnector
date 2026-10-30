<#
  One network cycle of the agent (scanner PC): scans noted in the inbox become outbox jobs, the outbox is sent,
  the reports of the pending jobs are fetched and the heartbeats of the stations are read. Agent.ps1 runs this
  file in its own runspace, so a slow network folder never freezes the tray. It runs as a file, not as script
  text, so an application control policy that trusts the program folder trusts it too. Returns one object;
  problems are returned (Errors) and logged, never thrown.
#>
param([string]$Share = '', [Parameter(Mandatory = $true)] [string]$Reports)

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $app "lib\$lib.ps1") }
[void](Initialize-VlcLog 'Agent')

$r = [pscustomobject]@{ Converted = @(); Sent = @(); Failed = @(); Done = @(); Stations = @(); Outbox = 0; ShareOk = $false; Errors = @() }
try {
    $c = Convert-VlcInbox
    $r.Converted = @($c.Converted)
    $r.Failed += @($c.Failed)
}
catch { $r.Errors += "Inbox: $($_.Exception.Message)" }
if ($Share) {
    try {
        if (Test-Path -LiteralPath (Join-Path $Share 'jobs')) {
            $r.ShareOk = $true
            $s = Send-VlcOutbox $Share
            $r.Sent = @($s.Sent)
            $r.Failed += @($s.Failed)
            $r.Errors += @($s.Errors)
            if (-not $s.ShareOk) { $r.ShareOk = $false }
            $r.Done = @(Receive-VlcReports $Share $Reports)
            $r.Stations = @(Get-VlcStations $Share)
        }
    }
    catch { $r.Errors += "Shared folder $($Share): $($_.Exception.Message)" }
}
try { $r.Outbox = @(Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job').Count } catch { }
foreach ($id in $r.Converted) { Write-VlcLog "Scan noted as job $id." }
foreach ($id in $r.Sent) { Write-VlcLog "Job $id sent to the shared folder." }
foreach ($f in $r.Failed) { Write-VlcLog "Job $($f.JobId) set aside (outbox\failed): $($f.Message)" }
foreach ($e in $r.Errors) { Write-VlcLog "Network cycle: $e" }
$r
