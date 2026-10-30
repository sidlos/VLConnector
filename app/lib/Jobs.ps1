# Jobs of the network scenario (scanner PC -> shared folder -> PolyWorks station -> PDF back). The job
# carries the VL program of the scan; the station finds the template for it in programs.csv.
# Dot-source this file; it needs lib\Settings.ps1, lib\KeyValueFile.ps1 and lib\Share.ps1. See docs\Protocol.md.
#
# Scanner PC: the tray of the agent only notes a finished scan in the local inbox (<JobId>.scan). The background
#   cycle of the agent - the only writer of the outbox and of the pending list - turns it into an outbox job
#   (<JobId>.stl + <JobId>.job with the SHA-256), sends it to <share>\jobs (STL first, .job last, each written as
#   .part and renamed) and fetches the reports of its pending jobs. A job that cannot be sent five times, or has
#   lost its STL, is set aside in outbox\failed.
# Station: claims the oldest job (by the time in its JobId) by moving <JobId>.job to work\ and writing
#   <JobId>.claim, checks it, evaluates it and publishes reports\<JobId>.pdf/.csv/.result (the .result last),
#   then moves the job to processed\ or failed\. A job left in work\ longer than network.jobTimeoutMin, or one of
#   a station that was stopped while evaluating, is completed as failed. An OK result is never overwritten.

$script:JobIdPattern = '^[A-Za-z0-9-]{1,40}_[A-Za-z0-9-]{1,40}_\d{8}-\d{6}_[0-9a-f]{4}$'
$script:ProtocolVersion = '1'
$script:MaxStlBytes = 2GB
$script:MaxSendAttempts = 5

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
        $len = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
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
        $len = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length
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

# Copies a file to <target>.part and renames it, so readers never see half a file. File errors here and below
# stop (-ErrorAction Stop), whatever the caller's ErrorActionPreference: a failed step must never count as done.
function Copy-FileAtomic([string]$Source, [string]$Target) {
    $part = "$Target.part"
    Copy-Item -LiteralPath $Source -Destination $part -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force -ErrorAction Stop }
    Move-Item -LiteralPath $part -Destination $Target -ErrorAction Stop
}

# Marks a file copied from the shared folder like a download, so a PDF viewer opens it in its protected mode:
# another PC wrote it (C28).
function Set-VlcDownloadedMark([string]$Path) {
    try { Set-Content -LiteralPath $Path -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3" -ErrorAction Stop } catch { }
}

# The time in a JobId (yyyyMMdd-HHmmss): the order of the queue.
function Get-VlcJobTime([string]$JobId) { return @($JobId -split '_')[2] }

# ------------------------------------------------------------------------------------------------
# Scanner PC
# ------------------------------------------------------------------------------------------------

function Get-VlcOutbox {
    $dir = Join-Path (Get-VlcPaths).DataDir 'outbox'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

function Get-VlcInbox {
    $dir = Join-Path (Get-VlcPaths).DataDir 'inbox'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# Notes a finished scan for the background cycle (the tray of the agent does only this; written in one step).
function Add-VlcInboxScan([string]$JobId, [string]$Part, [string]$StlPath, [string]$Program) {
    if (-not (Test-VlcJobId $JobId)) { throw "Invalid job id $JobId." }
    Write-KeyValueFile (Join-Path (Get-VlcInbox) "$JobId.scan") ([ordered]@{
        JOBID = $JobId; PART = $Part; STL = $StlPath; PROGRAM = $Program; NOTED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
}

# Sets a job of the outbox aside in outbox\failed with the reason; it is not sent again.
function Move-VlcOutboxFailed([string]$JobId, [string]$Reason) {
    $outbox = Get-VlcOutbox
    $failed = Join-Path $outbox 'failed'
    New-Item -ItemType Directory -Force -Path $failed -ErrorAction Stop | Out-Null
    foreach ($ext in 'job', 'stl', 'scan') {
        $f = Join-Path $outbox "$JobId.$ext"
        if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination (Join-Path $failed "$JobId.$ext") -Force -ErrorAction Stop }
    }
    Remove-Item -LiteralPath (Join-Path $outbox "$JobId.tries") -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText((Join-Path $failed "$JobId.reason"), "$((Get-Date).ToString('s'))  $Reason`r`n")
}

# The scans of the inbox become outbox jobs and pending jobs. Returns Converted (JobIds) and Failed (JobId,
# Message: the scan was set aside, e.g. its STL is gone).
function Convert-VlcInbox {
    $converted = New-Object Collections.Generic.List[string]
    $failed = [Collections.Generic.List[object]]::new()
    foreach ($scan in @(Get-ChildItem -LiteralPath (Get-VlcInbox) -Filter '*.scan' | Sort-Object Name)) {
        $s = Read-KeyValueFile $scan.FullName
        $id = if ($s) { [string]$s.JOBID } else { $scan.BaseName }
        try {
            if (-not $s -or $s.JOBID -cne $scan.BaseName) { throw 'The note of the scan cannot be read.' }
            # a note that could not be deleted in an earlier cycle is not sent twice
            if (-not @(Get-VlcPendingJobs | Where-Object { $_.JobId -eq $id }).Count) {
                [void](New-VlcOutboxJob $id $s.PART $s.STL $s.PROGRAM)
                Add-VlcPendingJob $id $s.PART
                $converted.Add($id)
            }
            Remove-Item -LiteralPath $scan.FullName -Force -ErrorAction SilentlyContinue
        }
        catch {
            $message = "Scan $($s.STL): $($_.Exception.Message)"
            # set aside with the reason; if even that fails (a file in use), the next cycle tries again
            try {
                Move-Item -LiteralPath $scan.FullName -Destination (Join-Path (Get-VlcOutbox) "$($scan.BaseName).scan") -Force -ErrorAction Stop
                Move-VlcOutboxFailed $scan.BaseName $message
                $failed.Add([pscustomobject]@{ JobId = $id; Message = $message })
            }
            catch { }
        }
    }
    return [pscustomobject]@{ Converted = $converted.ToArray(); Failed = $failed.ToArray() }
}

# Creates the job in the local outbox: <JobId>.stl (a copy of the exported STL) and <JobId>.job.
function New-VlcOutboxJob([string]$JobId, [string]$Part, [string]$StlPath, [string]$Program) {
    if (-not (Test-VlcJobId $JobId)) { throw "Invalid job id $JobId." }
    if (-not (Test-BinaryStlFile $StlPath)) { throw "The STL $StlPath is not a complete binary STL." }
    $outbox = Get-VlcOutbox
    $stl = Join-Path $outbox "$JobId.stl"
    Copy-Item -LiteralPath $StlPath -Destination $stl -Force -ErrorAction Stop
    $job = [ordered]@{
        PROTOCOL = $script:ProtocolVersion; JOBID = $JobId; PART = $Part; PROGRAM = (Split-Path $Program -Leaf)
        COMPUTER = $env:COMPUTERNAME; USER = $env:USERNAME; CREATED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        STL = "$JobId.stl"; STL_SIZE = (Get-Item -LiteralPath $stl).Length; STL_SHA256 = (Get-FileHash -LiteralPath $stl -Algorithm SHA256).Hash.ToLower()
        VERSION = (Get-VlcVersion)
    }
    Write-KeyValueFile (Join-Path $outbox "$JobId.job") $job
    return $job
}

# Uploads the jobs of the outbox, oldest first (STL first, the .job file last). An unreachable shared folder
# stops the round (the jobs stay and go next time); any other problem skips that job only, and after five
# attempts it is set aside. Returns Sent (JobIds), Failed (JobId, Message: set aside), Errors (texts for the
# log) and ShareOk.
function Send-VlcOutbox([string]$Share) {
    $sent = New-Object Collections.Generic.List[string]
    $failed = [Collections.Generic.List[object]]::new()
    $errors = New-Object Collections.Generic.List[string]
    $shareOk = $true
    $outbox = Get-VlcOutbox
    $jobs = Join-Path $Share 'jobs'
    foreach ($job in @(Get-ChildItem -LiteralPath $outbox -Filter '*.job' | Sort-Object { Get-VlcJobTime $_.BaseName }, Name)) {
        $id = $job.BaseName
        if (-not (Test-Path -LiteralPath $jobs)) { $shareOk = $false; break }
        $stl = Join-Path $outbox "$id.stl"
        if (-not (Test-Path -LiteralPath $stl)) {
            $message = 'The STL of the job is missing in the outbox.'
            try { Move-VlcOutboxFailed $id $message; $failed.Add([pscustomobject]@{ JobId = $id; Message = $message }) }
            catch { $errors.Add("Job ${id}: $message It cannot be set aside: $($_.Exception.Message)") }
            continue
        }
        try {
            Copy-FileAtomic $stl (Join-Path $jobs "$id.stl")
            Copy-FileAtomic $job.FullName (Join-Path $jobs "$id.job")
            # the .job first: a left-over STL is harmless, a .job without its STL would be sent again
            Remove-Item -LiteralPath $job.FullName -Force -ErrorAction Stop
            Remove-Item -LiteralPath $stl, (Join-Path $outbox "$id.tries") -Force -ErrorAction SilentlyContinue
            $sent.Add($id)
        }
        catch {
            if (-not (Test-Path -LiteralPath $jobs)) { $shareOk = $false; break }
            $reason = $_.Exception.Message
            $triesFile = Join-Path $outbox "$id.tries"
            $tries = 1
            if (Test-Path -LiteralPath $triesFile) { $tries = 1 + [int]([IO.File]::ReadAllText($triesFile).Trim()) }
            [IO.File]::WriteAllText($triesFile, [string]$tries)
            $errors.Add("Job $id, attempt $tries of $($script:MaxSendAttempts): $reason")
            if ($tries -ge $script:MaxSendAttempts) {
                $message = "Not sent after $tries attempts: $reason"
                try { Move-VlcOutboxFailed $id $message; $failed.Add([pscustomobject]@{ JobId = $id; Message = $message }) }
                catch { $errors.Add("Job $id cannot be set aside: $($_.Exception.Message)") }
            }
        }
    }
    return [pscustomobject]@{ Sent = $sent.ToArray(); Failed = $failed.ToArray(); Errors = $errors.ToArray(); ShareOk = $shareOk }
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
    Use-VlcLock 'Local\VLConnector_Pending' {
        $jobs = @(Get-VlcPendingJobs | Where-Object { $_.JobId -ne $JobId }) + [pscustomobject]@{ JobId = $JobId; Part = $Part; Submitted = (Get-Date).ToString('s') }
        Set-VlcPendingJobs $jobs
    }
}

# Looks for results of the pending jobs. A finished job: its report is copied to the local reports folder (PDF
# only if complete, marked like a download) and the job leaves the pending list. A result whose PDF has not
# arrived complete yet stays pending for $PdfWaitSec after the station finished. Returns the finished jobs.
function Receive-VlcReports([string]$Share, [string]$LocalReports, [int]$PdfWaitSec = 600) {
    $done = [Collections.Generic.List[object]]::new()
    $reports = Join-Path $Share 'reports'
    if (-not (Test-Path -LiteralPath $reports)) { return @() }
    Use-VlcLock 'Local\VLConnector_Pending' {
        $pending = @(Get-VlcPendingJobs)
        if (-not $pending.Count) { return }
        $left = [Collections.Generic.List[object]]::new()
        foreach ($p in $pending) {
            $r = $null
            try { $r = Read-KeyValueFile (Join-Path $reports "$($p.JobId).result") } catch { }
            if (-not $r -or $r.JOBID -cne $p.JobId) { $left.Add($p); continue }
            $pdfLocal = ''
            $message = [string]$r.MESSAGE
            if ($r.STATE -eq 'OK' -and $r.PDF) {
                $pdfShare = Join-Path $reports "$($p.JobId).pdf"
                try {
                    if ((Test-Path -LiteralPath $pdfShare) -and (Test-PdfFile $pdfShare)) {
                        New-Item -ItemType Directory -Force -Path $LocalReports -ErrorAction Stop | Out-Null
                        $pdfLocal = Join-Path $LocalReports "$($p.JobId).pdf"
                        Copy-Item -LiteralPath $pdfShare -Destination $pdfLocal -Force -ErrorAction Stop
                        if (Test-PdfFile $pdfLocal) { Set-VlcDownloadedMark $pdfLocal } else { Remove-Item -LiteralPath $pdfLocal -Force; $pdfLocal = '' }
                        $csvShare = Join-Path $reports "$($p.JobId).csv"
                        if (Test-Path -LiteralPath $csvShare) {
                            $csvLocal = Join-Path $LocalReports "$($p.JobId).csv"
                            Copy-Item -LiteralPath $csvShare -Destination $csvLocal -Force -ErrorAction Stop
                            Set-VlcDownloadedMark $csvLocal
                        }
                    }
                }
                catch { $pdfLocal = '' }   # copied again in the next cycle
                if (-not $pdfLocal) {
                    $finished = [datetime]::MinValue
                    $known = [datetime]::TryParseExact([string]$r.FINISHED_UTC, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal', [ref]$finished)
                    if ($known -and ([datetime]::UtcNow - $finished).TotalSeconds -lt $PdfWaitSec) { $left.Add($p); continue }
                    $message = ("The PDF report did not arrive from the station. $message").Trim()
                }
            }
            $done.Add([pscustomobject]@{ JobId = $p.JobId; Part = $p.Part; State = $r.STATE; Verdict = $r.VERDICT; Summary = $r.SUMMARY; Message = $message; Pdf = $pdfLocal; Station = $r.STATION })
        }
        if ($done.Count) { Set-VlcPendingJobs $left.ToArray() }
    }
    return $done.ToArray()
}

# The heartbeats of the stations: Name, State, Job, Beat (counter), UpdatedUtc (the station's clock).
function Get-VlcStations([string]$Share) {
    $dir = Join-Path $Share 'status'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -Filter '*.station' | ForEach-Object {
        $s = $null; try { $s = Read-KeyValueFile $_.FullName } catch { }
        if ($s) { [pscustomobject]@{ Key = $_.BaseName; Name = $s.STATION; State = $s.STATE; Job = $s.JOB; Beat = [string]$s.BEAT; UpdatedUtc = [string]$s.UPDATED_UTC } }
    })
}

# Which stations are online, judged with this PC's own clock: a station lives while its heartbeat counter
# (BEAT) changes; it is online up to 2 min after the last change, a busy one up to the job time limit. Clocks of
# other PCs and write rights in status\ are not needed. $Seen keeps the last counter and when it changed
# (one hashtable per agent). On first sight the time in the heartbeat is the best guess.
function Update-VlcStationLiveness([hashtable]$Seen, $Stations, [datetime]$Now, [int]$JobTimeoutMin) {
    foreach ($s in @($Stations)) {
        $last = $Seen[$s.Key]
        if (-not $last) {
            $since = $Now
            $updated = [datetime]::MinValue
            if ([datetime]::TryParseExact($s.UpdatedUtc, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal', [ref]$updated)) {
                $since = $Now.AddSeconds(-[Math]::Max(0, ($Now.ToUniversalTime() - $updated).TotalSeconds))
            }
            $Seen[$s.Key] = @{ Beat = $s.Beat; Since = $since }
        }
        elseif ($last.Beat -ne $s.Beat) { $last.Beat = $s.Beat; $last.Since = $Now }
        $age = ($Now - $Seen[$s.Key].Since).TotalSeconds
        $limit = if ($s.State -eq 'Busy') { [Math]::Max(120, $JobTimeoutMin * 60 + 60) } else { 120 }
        [pscustomobject]@{ Name = $s.Name; State = $s.State; Job = $s.Job; AgeSec = [int]$age; Online = ($s.State -ne 'Stopped' -and $age -lt $limit) }
    }
}

# ------------------------------------------------------------------------------------------------
# Station
# ------------------------------------------------------------------------------------------------

# The name a station shows (network.stationName, otherwise the computer name).
function Get-VlcStationName($Settings) {
    if ($Settings -and $Settings.network.stationName) { return [string]$Settings.network.stationName }
    return $env:COMPUTERNAME
}

# Claims the oldest valid job: moves it to work\, notes the claim and checks it. Returns $null when there is none.
# A file in jobs\ that is no VL Connector job is set aside in jobs\rejected\. An invalid job is moved to failed\
# and gets a result file with STATE=ERROR, so the scanner PC learns why.
function Get-VlcNextJob([string]$Share, [string]$Station = $env:COMPUTERNAME, [bool]$AllowUnc = $false, [int64]$MaxStlBytes = $script:MaxStlBytes) {
    $jobsDir = Join-Path $Share 'jobs'
    $work = Join-Path $Share 'work'
    foreach ($job in @(Get-ChildItem -LiteralPath $jobsDir -Filter '*.job' -File -ErrorAction SilentlyContinue | Sort-Object { Get-VlcJobTime $_.BaseName }, Name)) {
        $id = $job.BaseName
        if (-not (Test-VlcJobId $id)) {
            $rejected = Join-Path $jobsDir 'rejected'
            New-Item -ItemType Directory -Force -Path $rejected | Out-Null
            Move-Item -LiteralPath $job.FullName -Destination (Join-Path $rejected $job.Name) -Force -ErrorAction SilentlyContinue
            continue
        }
        $claimed = Join-Path $work "$id.job"
        try { Move-Item -LiteralPath $job.FullName -Destination $claimed -ErrorAction Stop }
        catch { continue }   # another station took it
        Write-KeyValueFile (Join-Path $work "$id.claim") ([ordered]@{ STATION = $Station; COMPUTER = $env:COMPUTERNAME; CLAIMED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
        $stlShare = Join-Path $jobsDir "$id.stl"
        $stlWork = Join-Path $work "$id.stl"
        $map = $null
        try {
            if (Test-Path -LiteralPath $stlShare) { Move-Item -LiteralPath $stlShare -Destination $stlWork -Force -ErrorAction Stop }
            $j = Read-KeyValueFile $claimed
            if (-not $j) { throw 'The job file cannot be read.' }
            if ($j.PROTOCOL -ne $script:ProtocolVersion) { throw "Protocol $($j.PROTOCOL) is not supported by this station." }
            if ($j.JOBID -cne $id) { throw 'The job file does not belong to this job.' }
            if (-not (Test-Path -LiteralPath $stlWork)) { throw 'The STL of the job is missing.' }
            if ((Get-Item -LiteralPath $stlWork).Length -gt $MaxStlBytes) { throw "The STL is larger than $([Math]::Round($MaxStlBytes / 1MB)) MB." }
            if ((Get-Item -LiteralPath $stlWork).Length -ne [int64]$j.STL_SIZE -or (Get-FileHash -LiteralPath $stlWork -Algorithm SHA256).Hash.ToLower() -ne $j.STL_SHA256) {
                throw 'The STL differs from the one the scanner PC sent.'
            }
            if (-not (Test-BinaryStlFile $stlWork)) { throw 'The STL is not a complete binary STL.' }
            $program = Get-VlcProgramName ([string]$j.PROGRAM)
            $map = Find-VlcProgram $Share $program $AllowUnc
            if (-not $map) { throw "The VL program '$program' is not in the Measurement Programs List of the shared folder (programs.csv)." }
            if (-not (Test-Path -LiteralPath $map.Workspace)) { throw "The workspace $($map.Workspace) of VL program '$program' was not found on this station." }
            return [pscustomobject]@{ JobId = $id; Job = $j; Map = $map; Stl = $stlWork; JobFile = $claimed }
        }
        catch {
            [void](Complete-VlcJob $Share $id ([ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = $_.Exception.Message }) '' '' $map $Station)
        }
    }
    return $null
}

# Publishes the result of a job and moves it to processed\ (STATE=OK) or failed\.
# $Result: STATE, VERDICT, SUMMARY, MESSAGE; $Pdf/$Csv: local files of the station (may be empty); $Map: the line of
# the Measurement Programs List (workspace and template go into the result). An OK result that is already there
# is never overwritten (a job completed twice, e.g. after a time-out): then nothing is published ($false).
function Complete-VlcJob([string]$Share, [string]$JobId, $Result, [string]$Pdf, [string]$Csv, $Map = $null, [string]$Station = $env:COMPUTERNAME) {
    $reports = Join-Path $Share 'reports'
    $resultFile = Join-Path $reports "$JobId.result"
    $existing = $null
    try { $existing = Read-KeyValueFile $resultFile } catch { }
    if ($existing -and $existing.STATE -eq 'OK') { return $false }
    if ($Pdf -and (Test-Path -LiteralPath $Pdf)) { Copy-FileAtomic $Pdf (Join-Path $reports "$JobId.pdf") }
    if ($Csv -and (Test-Path -LiteralPath $Csv)) { Copy-FileAtomic $Csv (Join-Path $reports "$JobId.csv") }
    $out = [ordered]@{
        PROTOCOL = $script:ProtocolVersion; JOBID = $JobId; STATE = $Result.STATE; VERDICT = $Result.VERDICT; SUMMARY = $Result.SUMMARY
        PDF = $(if ($Pdf) { "$JobId.pdf" } else { '' }); CSV = $(if ($Csv) { "$JobId.csv" } else { '' })
        STATION = $Station; FINISHED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); MESSAGE = $Result.MESSAGE
        WORKSPACE = $(if ($Map) { $Map.Workspace } else { '' }); TEMPLATE = $(if ($Map) { $Map.Template } else { '' })
    }
    Write-KeyValueFile $resultFile $out
    $target = Join-Path $Share $(if ($Result.STATE -eq 'OK') { 'processed' } else { 'failed' })
    foreach ($ext in 'job', 'stl') {
        $f = Join-Path (Join-Path $Share 'work') "$JobId.$ext"
        if (Test-Path -LiteralPath $f) { Move-Item -LiteralPath $f -Destination (Join-Path $target "$JobId.$ext") -Force -ErrorAction Stop }
    }
    Remove-Item -LiteralPath (Join-Path (Join-Path $Share 'work') "$JobId.claim") -Force -ErrorAction SilentlyContinue
    return $true
}

# Jobs left in work\: those of this PC when its station starts (it was stopped while evaluating), and those of any
# station older than the job time limit, are completed as failed. Returns the JobIds completed.
function Resolve-VlcStaleJobs([string]$Share, [int]$TimeoutMin, [switch]$OwnOnly, [string]$Station = $env:COMPUTERNAME) {
    $work = Join-Path $Share 'work'
    $resolved = New-Object Collections.Generic.List[string]
    foreach ($job in @(Get-ChildItem -LiteralPath $work -Filter '*.job' -File -ErrorAction SilentlyContinue)) {
        $id = $job.BaseName
        if (-not (Test-VlcJobId $id)) { continue }
        $claim = $null
        try { $claim = Read-KeyValueFile (Join-Path $work "$id.claim") } catch { }
        $since = $job.LastWriteTimeUtc
        $claimed = [datetime]::MinValue
        if ($claim -and [datetime]::TryParseExact([string]$claim.CLAIMED_UTC, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal', [ref]$claimed)) { $since = $claimed }
        $by = if ($claim) { [string]$claim.STATION } else { 'a station' }
        $message = $null
        if ($OwnOnly) {
            if ($claim -and $claim.COMPUTER -eq $env:COMPUTERNAME) { $message = "The station $by was stopped while it evaluated this scan. Scan the part again." }
        }
        elseif (([datetime]::UtcNow - $since).TotalMinutes -ge $TimeoutMin) {
            $message = "The station $by did not finish the evaluation within $TimeoutMin min. Scan the part again."
        }
        if ($message -and (Complete-VlcJob $Share $id ([ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = $message }) '' '' $null $Station)) { $resolved.Add($id) }
    }
    return $resolved.ToArray()
}

# The heartbeat of this station in status\: STATION, STATE (Idle, Busy, Paused, Stopped), JOB, VERSION, UPDATED_UTC
# and BEAT, a counter that grows with every write (the scanner PCs judge liveness by it, with their own clock).
function Write-VlcStationStatus([string]$Share, [string]$State, [string]$JobId = '', [string]$Station = $env:COMPUTERNAME) {
    $file = Join-Path (Join-Path $Share 'status') "$(ConvertTo-JobIdPart $env:COMPUTERNAME).station"
    $beat = 0
    try { $old = Read-KeyValueFile $file; if ($old) { [void][int]::TryParse([string]$old.BEAT, [ref]$beat) } } catch { }
    Write-KeyValueFile $file ([ordered]@{ STATION = $Station; STATE = $State; JOB = $JobId; VERSION = (Get-VlcVersion)
        UPDATED_UTC = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); BEAT = [string]($beat + 1) })
}
