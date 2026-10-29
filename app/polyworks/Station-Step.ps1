<#
  Station-Step.ps1 - VL Connector for PolyWorks: the file work of the PolyWorks station (VLC_Station.pwmacro),
  so that the macro itself only evaluates. Every call writes a KEY=value file (-Out) in a fixed line order.
    -Action Context -Out f            1 STATE (OK/ERROR)  2 SHARE  3 POLL_MS  4 STATUS_FILE  5 MESSAGE
    -Action Next -Out f               claims the oldest job of the shared folder and prepares the parameters
                                      for VLC_Evaluate.pwmacro:
                                      1 STATE (JOB/IDLE/ERROR)  2 JOBID  3 PART  4 PARAMS  5 RESULT  6 MESSAGE
    -Action Publish -JobId id -Result f   publishes the result of VLC_Evaluate (PDF, CSV, verdict) to the
                                      shared folder and moves the job to processed\ or failed\
  See docs\Protocol.md.
#>
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Context', 'Next', 'Publish')] [string]$Action,
    [string]$Out = '',
    [string]$JobId = '',
    [string]$Result = ''
)

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $app "lib\$lib.ps1") }
[void](Initialize-VlcLog 'Station')
$cfg = Read-VlcSettings
$share = [string]$cfg.network.share
$work = Join-Path (Get-VlcPaths).DataDir 'station'
New-Item -ItemType Directory -Force -Path $work | Out-Null

switch ($Action) {
    'Context' {
        $o = [ordered]@{ STATE = 'OK'; SHARE = $share; POLL_MS = [string]([int]$cfg.network.pollSec * 1000); STATUS_FILE = ''; MESSAGE = '' }
        if (-not $share) { $o.STATE = 'ERROR'; $o.MESSAGE = 'No shared folder is set. Open VL Connector settings, choose "PolyWorks on another PC" and enter the shared folder.' }
        else {
            $test = Test-VlcShare $share
            if (-not $test.Ok) { $o.STATE = 'ERROR'; $o.MESSAGE = "Shared folder $share - $($test.Text)" }
            else { $o.STATUS_FILE = Join-Path (Join-Path $share 'status') "$(ConvertTo-JobIdPart $env:COMPUTERNAME).station"; Write-VlcStationStatus $share 'Idle' }
        }
        Write-VlcLog "Station start: $($o.STATE) $($o.MESSAGE)"
        Write-KeyValueFile $Out $o
    }
    'Next' {
        $o = [ordered]@{ STATE = 'IDLE'; JOBID = ''; PART = ''; PARAMS = ''; RESULT = ''; MESSAGE = '' }
        try {
            $next = Get-VlcNextJob $share
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
                }
                foreach ($k in 'PWK', 'STL', 'REPORT_DIR', 'RESULT') { if ([string]$params[$k] -match '=') { throw "The path $($params[$k]) contains '=', which the macro cannot read." } }
                $o.PARAMS = Join-Path $work "$id.params"
                $o.RESULT = $resultFile
                Write-KeyValueFile $o.PARAMS $params
                Write-VlcStationStatus $share 'Busy' $id
                Write-VlcLog "Job $id ($($o.PART)) claimed."
            }
        }
        catch { $o.STATE = 'ERROR'; $o.MESSAGE = $_.Exception.Message; Write-VlcLog "Next job: $($o.MESSAGE)" }
        Write-KeyValueFile $Out $o
    }
    'Publish' {
        if (-not (Test-VlcJobId $JobId)) { throw "Invalid job id $JobId." }
        $r = $null
        try { $r = Read-KeyValueFile $Result } catch { }
        if (-not $r -or -not $r.STATE) {
            $res = [ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = 'The evaluation in PolyWorks did not finish (no result).' }
            Complete-VlcJob $share $JobId $res '' ''
        }
        else {
            $res = [ordered]@{ STATE = $r.STATE; VERDICT = $r.VERDICT; SUMMARY = $r.SUMMARY; MESSAGE = $r.MESSAGE }
            $pdf = if ($r.STATE -eq 'OK' -and $r.PDF -and (Test-Path -LiteralPath $r.PDF) -and (Test-PdfFile $r.PDF)) { $r.PDF } else { '' }
            $csv = if ($r.CSV -and (Test-Path -LiteralPath $r.CSV)) { $r.CSV } else { '' }
            if ($r.STATE -eq 'OK' -and -not $pdf) { $res.MESSAGE = (('The PDF report could not be created. ' + $res.MESSAGE).Trim()) }
            Complete-VlcJob $share $JobId $res $pdf $csv
            foreach ($f in $pdf, $csv) { if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
        }
        foreach ($f in (Join-Path $work "$JobId.params"), $Result) { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force } }
        Write-VlcStationStatus $share 'Idle'
        Write-VlcLog "Job $JobId published: $($res.STATE) $($res.VERDICT) $($res.SUMMARY) $($res.MESSAGE)"
    }
}
