<#
  Station-Step.ps1 - VL Connector for PolyWorks: the file work of the PolyWorks station (VLC_Station.pwmacro),
  so that the macro itself only evaluates. Every call writes a KEY=value file (-Out) in a fixed line order.
    -Action Context -Out f            1 STATE (OK/ERROR)  2 SHARE  3 POLL_MS  4 STATUS_FILE  5 MESSAGE  6 STATION
                                      (jobs this PC left unfinished in work\ are reported as failed first)
    -Action Next -Out f               claims the oldest job of the shared folder and prepares the parameters
                                      for VLC_Evaluate.pwmacro:
                                      1 STATE (JOB/IDLE/ERROR)  2 JOBID  3 PART  4 PARAMS  5 RESULT  6 MESSAGE
                                      ERROR without a claimed job pauses the station (e.g. an unusable
                                      Measurement Programs List); a job that fails after it was claimed is
                                      reported as failed to its scanner PC.
    -Action Publish -JobId id -Result f -Out f   publishes the result of VLC_Evaluate (PDF, CSV, verdict) to the
                                      shared folder and moves the job to processed\ or failed\: 1 STATE 2 MESSAGE
  See docs\Protocol.md.
#>
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Context', 'Next', 'Publish')] [string]$Action,
    [string]$Out = '',
    [string]$JobId = '',
    [string]$Result = ''
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    $keys = @{ Context = 'STATE', 'SHARE', 'POLL_MS', 'STATUS_FILE', 'MESSAGE', 'STATION'; Next = 'STATE', 'JOBID', 'PART', 'PARAMS', 'RESULT', 'MESSAGE'; Publish = 'STATE', 'MESSAGE' }[$Action]
    & (Join-Path (Split-Path $PSScriptRoot) 'lib\LanguageCheck.ps1') -Caller Station -Mode $ExecutionContext.SessionState.LanguageMode -OutFile $Out -Keys $keys
    exit 1
}

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $app "lib\$lib.ps1") }
[void](Initialize-VlcLog 'Station')

$o = switch ($Action) {
    'Context' { [ordered]@{ STATE = 'ERROR'; SHARE = ''; POLL_MS = '3000'; STATUS_FILE = ''; MESSAGE = ''; STATION = '' } }
    'Next' { [ordered]@{ STATE = 'IDLE'; JOBID = ''; PART = ''; PARAMS = ''; RESULT = ''; MESSAGE = '' } }
    'Publish' { [ordered]@{ STATE = 'ERROR'; MESSAGE = '' } }
}
$next = $null
try {
    $cfg = Read-VlcSettings
    $share = [string]$cfg.network.share
    $station = Get-VlcStationName $cfg
    $allowUnc = [bool]$cfg.network.allowUncWorkspaces
    $work = Join-Path (Get-VlcPaths).DataDir 'station'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    if (-not $share -and $Action -ne 'Context') { throw 'No shared folder is set.' }
    switch ($Action) {
        'Context' {
            $o.SHARE = $share
            $o.POLL_MS = [string]([int]$cfg.network.pollSec * 1000)
            $o.STATION = $station
            if (-not $share) { throw 'No shared folder is set. Open VL Connector settings, choose "PolyWorks on another PC" and enter the shared folder.' }
            # the macro reads a line up to the next '=': paths with '=' cannot go through it
            foreach ($p in $share, $work, $app) { if ($p.Contains('=')) { throw "The path $p contains '=', which the PolyWorks macro cannot read." } }
            $test = Test-VlcShare $share 'Station'
            if (-not $test.Ok) { throw "Shared folder $share - $($test.Text)" }
            foreach ($id in @(Resolve-VlcStaleJobs $share ([int]$cfg.network.jobTimeoutMin) -OwnOnly -Station $station)) { Write-VlcLog "Job $id was left unfinished by this station: reported as failed." }
            $o.STATUS_FILE = Join-Path (Join-Path $share 'status') "$(ConvertTo-JobIdPart $env:COMPUTERNAME).station"
            Write-VlcStationStatus $share 'Idle' '' $station
            $o.STATE = 'OK'
            Write-VlcLog "Station $station started on $share."
        }
        'Next' {
            foreach ($id in @(Resolve-VlcStaleJobs $share ([int]$cfg.network.jobTimeoutMin) -Station $station)) { Write-VlcLog "Job $id was not finished in time: reported as failed." }
            # an unusable Measurement Programs List pauses the station: no job is claimed and failed for it
            $list = Read-VlcProgramsList $share $allowUnc
            if ($list.Fatal) { throw $list.Fatal }
            $next = Get-VlcNextJob $share $station $allowUnc
            if ($next) {
                $id = $next.JobId
                $o.STATE = 'JOB'; $o.JOBID = $id; $o.PART = $next.Map.Program
                $reports = Join-Path $work 'reports'
                New-Item -ItemType Directory -Force -Path $reports | Out-Null
                $resultFile = Join-Path $work "$id.result"
                if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force }
                $run = ($id -split '_', 3)[2]   # yyyyMMdd-HHmmss_hhhh: unique piece name per job
                $params = [ordered]@{
                    PWK = $next.Map.Workspace; TEMPLATE = $next.Map.Template; STL = $next.Stl; RUN = $run; REPORT_DIR = $reports
                    OPERATOR = "$($next.Job.USER) ($($next.Job.COMPUTER))"
                    PROGRAM = $next.Job.PROGRAM; UTC = $next.Job.CREATED_UTC; KEEP_PIECES = [string]$cfg.polyworks.keepPieces
                    COLOR_SCALE = ([double]$cfg.polyworks.colorScaleMm).ToString([Globalization.CultureInfo]::InvariantCulture)
                    DEVICE = [string]$cfg.polyworks.deviceText; RESULT = $resultFile; JOBID = $id
                    APP = $app; STL_SHA256 = [string]$next.Job.STL_SHA256
                }
                foreach ($k in 'PWK', 'STL', 'REPORT_DIR', 'RESULT', 'APP') { if ([string]$params[$k] -match '=') { throw "The path $($params[$k]) contains '=', which the PolyWorks macro cannot read." } }
                $o.PARAMS = Join-Path $work "$id.params"
                $o.RESULT = $resultFile
                Write-KeyValueFile $o.PARAMS $params
                Write-VlcStationStatus $share 'Busy' $id $station
                Write-VlcLog "Job $id ($($o.PART)) claimed."
            }
            # nothing claimable although the macro saw a job file: the heartbeat goes on
            else { Write-VlcStationStatus $share 'Idle' '' $station }
        }
        'Publish' {
            if (-not (Test-VlcJobId $JobId)) { throw "Invalid job id $JobId." }
            $r = $null
            try { $r = Read-KeyValueFile $Result } catch { }
            $params = $null
            try { $params = Read-KeyValueFile (Join-Path $work "$JobId.params") } catch { }
            $map = if ($params) { [pscustomobject]@{ Workspace = $params.PWK; Template = $params.TEMPLATE } } else { $null }
            if (-not $r -or -not $r.STATE) {
                $res = [ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = 'The evaluation in PolyWorks did not finish (no result).' }
                $published = Complete-VlcJob $share $JobId $res '' '' $map $station
            }
            else {
                $res = [ordered]@{ STATE = $r.STATE; VERDICT = $r.VERDICT; SUMMARY = $r.SUMMARY; MESSAGE = $r.MESSAGE }
                $pdf = if ($r.STATE -eq 'OK' -and $r.PDF -and (Test-Path -LiteralPath $r.PDF) -and (Test-PdfFile $r.PDF)) { $r.PDF } else { '' }
                $csv = if ($r.CSV -and (Test-Path -LiteralPath $r.CSV)) { $r.CSV } else { '' }
                if ($r.STATE -eq 'OK' -and -not $pdf) { $res.MESSAGE = (('The PDF report could not be created. ' + $res.MESSAGE).Trim()) }
                $published = Complete-VlcJob $share $JobId $res $pdf $csv $map $station
                foreach ($f in $pdf, $csv) { if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
            }
            foreach ($f in (Join-Path $work "$JobId.params"), $Result) { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force } }
            Write-VlcStationStatus $share 'Idle' '' $station
            if (-not $published) { $o.MESSAGE = "Job $JobId has an OK result already (from another run); it was left as it is." }
            $o.STATE = 'OK'
            Write-VlcLog "Job $JobId published: $($res.STATE) $($res.VERDICT) $($res.SUMMARY) $($res.MESSAGE) $($o.MESSAGE)".Trim()
        }
    }
}
catch {
    $o.STATE = 'ERROR'
    $o.MESSAGE = $_.Exception.Message
    Write-VlcLog "$Action`: ERROR $($o.MESSAGE)"
    if ($Action -eq 'Next' -and $share) {
        # a job claimed in this call is never left in work\: its scanner PC gets the reason
        if ($next) {
            try { [void](Complete-VlcJob $share $next.JobId ([ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = $o.MESSAGE }) '' '' $next.Map $station) } catch { }
            $o.JOBID = ''; $o.PART = ''; $o.PARAMS = ''; $o.RESULT = ''
        }
        # the macro waits a poll and tries again; the scanner PCs see the station alive, but paused
        try { Write-VlcStationStatus $share 'Paused' '' $station } catch { }
    }
}
if ($Out) { Write-KeyValueFile $Out $o }
