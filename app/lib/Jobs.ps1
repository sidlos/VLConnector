# Jobs of the network scenario (scanner PC -> shared folder -> PolyWorks station -> PDF back). The job
# carries the VL program of the scan; the station finds the template for it in programs.csv.
# Dot-source this file; it needs lib\Settings.ps1, lib\KeyValueFile.ps1 and lib\Share.ps1. See docs\Protocol.md.
#
# Scanner PC: the STL goes to the local outbox first, then to <share>\jobs (<JobId>.stl, then <JobId>.job,
#   both written as .part and renamed). The JobId stays in the local pending list; only reports of pending
#   JobIds are fetched and opened.
# Station: claims the oldest job by moving <JobId>.job to work\, checks it, evaluates it and publishes
#   reports\<JobId>.pdf/.csv/.result (the .result last), then moves the job to processed\ or failed\.

$script:JobIdPattern = '^[A-Za-z0-9-]{1,40}_[A-Za-z0-9-]{1,40}_\d{8}-\d{6}_[0-9a-f]{4}$'
$script:ProtocolVersion = '1'

function ConvertTo-JobIdPart([string]$Text) {
    $t = ($Text -replace '[^A-Za-z0-9-]', '-') -replace '-{2,}', '-'
    $t = $t.Trim('-')
    if (-not $t) { $t = 'x' }
    if ($t.Length -gt 40) { $t = $t.Substring(0, 40) }
    return $t
}

function New-VlcJobId([string]$Part, [datetime]$Time = (Get-Date)) {
    $hex = '{0:x4}' -f (Get-Random -Minimum 0 -Maximum 65536)
    return '{0}_{1}_{2:yyyyMMdd-HHmmss}_{3}' -f (ConvertTo-JobIdPart $env:COMPUTERNAME), (ConvertTo-JobIdPart $Part), $Time, $hex
}

function Test-VlcJobId([string]$JobId) { return [bool]($JobId -cmatch $script:JobIdPattern) }

# A binary STL: 80-byte header, triangle count, 50 bytes per triangle.
function Test-BinaryStlFile([string]$Path) {
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -lt 134) { return $false }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try { $buf = New-Object byte[] 84; [void]$fs.Read($buf, 0, 84) } finally { $fs.Dispose() }
        $count = [BitConverter]::ToUInt32($buf, 80)
        return ($count -gt 0 -and $len -eq (84 + 50 * [int64]$count))
    }
    catch { return $false }
}

# A complete PDF starts with %PDF- and has %%EOF near the end.
function Test-PdfFile([string]$Path) {
    try {
        $len = (Get-Item -LiteralPath $Path).Length
        if ($len -lt 64) { return $false }
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try {
            $head = New-Object byte[] 5; [void]$fs.Read($head, 0, 5)
            $tailLen = [int][Math]::Min(1024, $len)
            [void]$fs.Seek(-$tailLen, 'End'); $tail = New-Object byte[] $tailLen; [void]$fs.Read($tail, 0, $tailLen)
        }
        finally { $fs.Dispose() }
        return ([Text.Encoding]::ASCII.GetString($head) -eq '%PDF-') -and ([Text.Encoding]::ASCII.GetString($tail).Contains('%%EOF'))
    }
    catch { return $false }
}

# Copies a file to <target>.part and renames it, so readers never see half a file.
function Copy-FileAtomic([string]$Source, [string]$Target) {
    $part = "$Target.part"
    Copy-Item -LiteralPath $Source -Destination $part -Force
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
    Move-Item -LiteralPath $part -Destination $Target
}

# ------------------------------------------------------------------------------------------------
# Scanner PC
# ------------------------------------------------------------------------------------------------

function Get-VlcOutbox {
    $dir = Join-Path (Get-VlcPaths).DataDir 'outbox'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# Creates the job in the local outbox: <JobId>.stl (moved there from the launcher output) and <JobId>.job.
function New-VlcOutboxJob([string]$JobId, [string]$Part, [string]$StlPath, [string]$Program) {
    if (-not (Test-VlcJobId $JobId)) { throw "Invalid job id $JobId." }
    if (-not (Test-BinaryStlFile $StlPath)) { throw "The STL $StlPath is not a complete binary STL." }
    $outbox = Get-VlcOutbox
    $stl = Join-Path $outbox "$JobId.stl"
    Copy-Item -LiteralPath $StlPath -Destination $stl -Force
    $job = [ordered]@{
        PROTOCOL = $script:ProtocolVersion; JOBID = $JobId; PART = $Part; PROGRAM = (Split-Path $Program -Leaf)
        COMPUTER = $env:COMPUTERNAME; USER = $env:USERNAME; CREATED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        STL = "$JobId.stl"; STL_SIZE = (Get-Item -LiteralPath $stl).Length; STL_SHA256 = (Get-FileHash -LiteralPath $stl -Algorithm SHA256).Hash.ToLower()
        VERSION = (Get-VlcVersion)
    }
    Write-KeyValueFile (Join-Path $outbox "$JobId.job") $job
    return $job
}

# Uploads every job of the outbox (STL first, the .job file last). Returns the JobIds sent; a job stays in
# the outbox when the share is not reachable and is sent on the next call.
function Send-VlcOutbox([string]$Share) {
    $sent = New-Object Collections.Generic.List[string]
    $jobs = Join-Path $Share 'jobs'
    foreach ($job in Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job' | Sort-Object LastWriteTime) {
        $id = $job.BaseName
        $stl = Join-Path $job.DirectoryName "$id.stl"
        try {
            if (-not (Test-Path -LiteralPath $jobs)) { throw "The shared folder $Share is not reachable." }
            Copy-FileAtomic $stl (Join-Path $jobs "$id.stl")
            Copy-FileAtomic $job.FullName (Join-Path $jobs "$id.job")
            Remove-Item -LiteralPath $stl, $job.FullName -Force
            $sent.Add($id)
        }
        catch { break }
    }
    return $sent.ToArray()
}

function Get-VlcPendingFile { return Join-Path (Get-VlcPaths).DataDir 'pending.txt' }

# Pending jobs of this PC: one line per job "JobId;Part;submitted (ISO)".
function Get-VlcPendingJobs {
    $file = Get-VlcPendingFile
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    return @([IO.File]::ReadAllLines($file) | Where-Object { $_ } | ForEach-Object {
        $f = $_ -split ';'
        if (Test-VlcJobId $f[0]) { [pscustomobject]@{ JobId = $f[0]; Part = $f[1]; Submitted = $f[2] } }
    })
}

function Set-VlcPendingJobs($Jobs) {
    $file = Get-VlcPendingFile
    New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
    $lines = @($Jobs | ForEach-Object { '{0};{1};{2}' -f $_.JobId, $_.Part, $_.Submitted })
    [IO.File]::WriteAllLines("$file.part", [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
    [IO.File]::Move("$file.part", $file)
}

function Add-VlcPendingJob([string]$JobId, [string]$Part) {
    $jobs = @(Get-VlcPendingJobs) + [pscustomobject]@{ JobId = $JobId; Part = $Part; Submitted = (Get-Date).ToString('s') }
    Set-VlcPendingJobs $jobs
}

# Looks for results of the pending jobs. A finished job: its report is copied to the local reports folder
# (PDF only if complete) and the job leaves the pending list. Returns the finished jobs.
function Receive-VlcReports([string]$Share, [string]$LocalReports) {
    $done = New-Object Collections.Generic.List[object]
    $pending = @(Get-VlcPendingJobs)
    if (-not $pending.Count) { return @() }
    $reports = Join-Path $Share 'reports'
    if (-not (Test-Path -LiteralPath $reports)) { return @() }
    $left = New-Object Collections.Generic.List[object]
    foreach ($p in $pending) {
        $resultFile = Join-Path $reports "$($p.JobId).result"
        $r = $null
        try { $r = Read-KeyValueFile $resultFile } catch { }
        if (-not $r -or $r.JOBID -ne $p.JobId) { $left.Add($p); continue }
        $pdfLocal = ''
        $pdfShare = Join-Path $reports "$($p.JobId).pdf"
        if ($r.STATE -eq 'OK' -and (Test-Path -LiteralPath $pdfShare) -and (Test-PdfFile $pdfShare)) {
            New-Item -ItemType Directory -Force -Path $LocalReports | Out-Null
            $pdfLocal = Join-Path $LocalReports "$($p.JobId).pdf"
            Copy-Item -LiteralPath $pdfShare -Destination $pdfLocal -Force
            if (-not (Test-PdfFile $pdfLocal)) { Remove-Item -LiteralPath $pdfLocal -Force; $pdfLocal = '' }
            $csvShare = Join-Path $reports "$($p.JobId).csv"
            if (Test-Path -LiteralPath $csvShare) { Copy-Item -LiteralPath $csvShare -Destination (Join-Path $LocalReports "$($p.JobId).csv") -Force }
        }
        $done.Add([pscustomobject]@{ JobId = $p.JobId; Part = $p.Part; State = $r.STATE; Verdict = $r.VERDICT; Summary = $r.SUMMARY; Message = $r.MESSAGE; Pdf = $pdfLocal; Station = $r.STATION })
    }
    if ($done.Count) { Set-VlcPendingJobs $left.ToArray() }
    return $done.ToArray()
}

# The newest heartbeat of the stations: Name, State, Updated (local time), Age (seconds), Job.
function Get-VlcStations([string]$Share) {
    $dir = Join-Path $Share 'status'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.station' | ForEach-Object {
        $s = $null; try { $s = Read-KeyValueFile $_.FullName } catch { }
        if ($s) {
            [pscustomobject]@{ Name = $s.STATION; State = $s.STATE; Job = $s.JOB; Updated = $_.LastWriteTime
                Age = [int]((Get-Date) - $_.LastWriteTime).TotalSeconds }
        }
    })
}

# ------------------------------------------------------------------------------------------------
# Station
# ------------------------------------------------------------------------------------------------

# Claims the oldest valid job: moves it to work\ and checks it. Returns $null when there is none.
# An invalid job is moved to failed\ and gets a result file with STATE=ERROR, so the scanner PC learns why.
function Get-VlcNextJob([string]$Share) {
    $jobsDir = Join-Path $Share 'jobs'
    $work = Join-Path $Share 'work'
    foreach ($job in Get-ChildItem -LiteralPath $jobsDir -Filter '*.job' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime) {
        $id = $job.BaseName
        if (-not (Test-VlcJobId $id)) { continue }
        $claimed = Join-Path $work "$id.job"
        try { Move-Item -LiteralPath $job.FullName -Destination $claimed -ErrorAction Stop }
        catch { continue }   # another station took it
        $stlShare = Join-Path $jobsDir "$id.stl"
        $stlWork = Join-Path $work "$id.stl"
        try {
            if (Test-Path -LiteralPath $stlShare) { Move-Item -LiteralPath $stlShare -Destination $stlWork -Force }
            $j = Read-KeyValueFile $claimed
            if ($j.PROTOCOL -ne $script:ProtocolVersion) { throw "Protocol $($j.PROTOCOL) is not supported by this station." }
            if ($j.JOBID -cne $id) { throw 'The job file does not belong to this job.' }
            if (-not (Test-Path -LiteralPath $stlWork)) { throw 'The STL of the job is missing.' }
            if ((Get-Item -LiteralPath $stlWork).Length -ne [int64]$j.STL_SIZE -or (Get-FileHash -LiteralPath $stlWork -Algorithm SHA256).Hash.ToLower() -ne $j.STL_SHA256) {
                throw 'The STL differs from the one the scanner PC sent.'
            }
            if (-not (Test-BinaryStlFile $stlWork)) { throw 'The STL is not a complete binary STL.' }
            $program = [IO.Path]::GetFileNameWithoutExtension([string]$j.PROGRAM)
            $map = Find-VlcProgram $Share $program
            if (-not $map) { throw "The VL program '$program' is not in the programs list of the shared folder (programs.csv)." }
            if (-not (Test-Path -LiteralPath $map.Workspace)) { throw "The workspace $($map.Workspace) of VL program '$program' was not found on this station." }
            return [pscustomobject]@{ JobId = $id; Job = $j; Map = $map; Stl = $stlWork; JobFile = $claimed }
        }
        catch {
            Complete-VlcJob $Share $id ([ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = $_.Exception.Message }) '' ''
        }
    }
    return $null
}

# Publishes the result of a job and moves it to processed\ (STATE=OK) or failed\.
# $Result: STATE, VERDICT, SUMMARY, MESSAGE; $Pdf/$Csv: local files of the station (may be empty).
function Complete-VlcJob([string]$Share, [string]$JobId, $Result, [string]$Pdf, [string]$Csv) {
    $reports = Join-Path $Share 'reports'
    if ($Pdf -and (Test-Path -LiteralPath $Pdf)) { Copy-FileAtomic $Pdf (Join-Path $reports "$JobId.pdf") }
    if ($Csv -and (Test-Path -LiteralPath $Csv)) { Copy-FileAtomic $Csv (Join-Path $reports "$JobId.csv") }
    $out = [ordered]@{
        PROTOCOL = $script:ProtocolVersion; JOBID = $JobId; STATE = $Result.STATE; VERDICT = $Result.VERDICT; SUMMARY = $Result.SUMMARY
        PDF = $(if ($Pdf) { "$JobId.pdf" } else { '' }); CSV = $(if ($Csv) { "$JobId.csv" } else { '' })
        STATION = $env:COMPUTERNAME; FINISHED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); MESSAGE = $Result.MESSAGE
    }
    Write-KeyValueFile (Join-Path $reports "$JobId.result") $out
    $target = Join-Path $Share $(if ($Result.STATE -eq 'OK') { 'processed' } else { 'failed' })
    foreach ($ext in 'job', 'stl') {
        $f = Join-Path (Join-Path $Share 'work') "$JobId.$ext"
        if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination (Join-Path $target "$JobId.$ext") -Force }
    }
}

function Write-VlcStationStatus([string]$Share, [string]$State, [string]$JobId = '') {
    $file = Join-Path (Join-Path $Share 'status') "$(ConvertTo-JobIdPart $env:COMPUTERNAME).station"
    Write-KeyValueFile $file ([ordered]@{ STATION = $env:COMPUTERNAME; STATE = $State; JOB = $JobId; VERSION = (Get-VlcVersion); UPDATED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
}
