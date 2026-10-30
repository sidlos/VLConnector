# Pester 3.4 unit tests: agent and station of the network scenario after the IT audit, on temporary folders without
# PolyWorks or VL. Durable inbox (C78), outbox attempts (C79), reports only complete and marked as downloaded (C28),
# queue order, claims, stale jobs and a station that never loses a claimed job (C34, C36), the Measurement Programs
# List (C75, C29), the role test of the shared folder (C30) and station liveness by the heartbeat counter (C82, C83).
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$app = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'app'
foreach ($lib in 'Settings', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $app "lib\$lib.ps1") }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-TestStl([string]$Path, [int]$Triangles = 2) {
    $bytes = New-Object byte[] (84 + 50 * $Triangles)
    [BitConverter]::GetBytes([uint32]$Triangles).CopyTo($bytes, 80)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-TestPdf([string]$Path) { [IO.File]::WriteAllText($Path, "%PDF-1.7`n" + ('x' * 200) + "`n%%EOF`n", [Text.Encoding]::ASCII) }

# A temporary profile (APPDATA, LOCALAPPDATA) with a station folder holding a workspace file, and a test STL.
# Exit-TestRoot puts the environment back and deletes everything.
function Enter-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('vlc_net_' + [guid]::NewGuid().ToString('N'))
    $t = [pscustomobject]@{
        Root = $root; Share = Join-Path $root 'share'; Local = Join-Path $root 'reports'; Workspace = Join-Path $root 'station\Parts.pwk'
        Stl = Join-Path $root 'scan.stl'; Saved = @{ APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
    }
    foreach ($k in 'APPDATA', 'LOCALAPPDATA') { $d = Join-Path $root $k; New-Item -ItemType Directory -Force -Path $d | Out-Null; Set-Item "env:$k" $d }
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'station') | Out-Null
    [IO.File]::WriteAllText($t.Workspace, 'dummy')
    New-TestStl $t.Stl
    return $t
}

function Exit-TestRoot($T) {
    foreach ($k in $T.Saved.Keys) { Set-Item "env:$k" $T.Saved[$k] }
    Remove-Item -LiteralPath $T.Root -Recurse -Force
}

Describe 'inbox of the agent (C78)' {
    $t = Enter-TestRoot
    It 'turns a noted scan into an outbox job and a pending job, and empties the inbox' {
        $id = New-VlcJobId 'ABC'
        Add-VlcInboxScan $id 'ABC' $t.Stl 'C:\Programs\ABC.vld4'
        $r = Convert-VlcInbox
        @($r.Converted) | Should Be $id
        (Read-KeyValueFile (Join-Path (Get-VlcOutbox) "$id.job")).PROGRAM | Should Be 'ABC.vld4'
        Test-Path -LiteralPath (Join-Path (Get-VlcOutbox) "$id.stl") | Should Be $true
        @(Get-VlcPendingJobs | ForEach-Object { $_.JobId }) | Should Be $id
        @(Get-ChildItem -LiteralPath (Get-VlcInbox)).Count | Should Be 0
    }
    It 'does not send a scan twice when its note comes again' {
        $id = @(Get-VlcPendingJobs)[0].JobId
        Remove-Item -Path (Join-Path (Get-VlcOutbox) "$id.*")
        Add-VlcInboxScan $id 'ABC' $t.Stl 'C:\Programs\ABC.vld4'
        @((Convert-VlcInbox).Converted).Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job').Count | Should Be 0
        @(Get-ChildItem -LiteralPath (Get-VlcInbox)).Count | Should Be 0
    }
    It 'sets a scan aside with the reason when its STL is gone' {
        $id = New-VlcJobId 'ABC'
        Add-VlcInboxScan $id 'ABC' (Join-Path $t.Root 'gone.stl') 'ABC.vld4'
        $r = Convert-VlcInbox
        @($r.Converted).Count | Should Be 0
        $r.Failed[0].JobId | Should Be $id
        Test-Path -LiteralPath (Join-Path (Get-VlcOutbox) "failed\$id.scan") | Should Be $true
        [IO.File]::ReadAllText((Join-Path (Get-VlcOutbox) "failed\$id.reason")) | Should Match 'not a complete binary STL'
        @(Get-VlcPendingJobs | Where-Object { $_.JobId -eq $id }).Count | Should Be 0
    }
    It 'sets a note aside that cannot be read' {
        $bad = Join-Path (Get-VlcInbox) 'PC_ABC_20261030-101500_abcd.scan'
        [IO.File]::WriteAllText($bad, 'garbage')
        (Convert-VlcInbox).Failed[0].JobId | Should Be 'PC_ABC_20261030-101500_abcd'
        Test-Path -LiteralPath $bad | Should Be $false
    }
    It 'refuses an invalid job id' {
        { Add-VlcInboxScan '..\evil' 'ABC' $t.Stl 'ABC.vld4' } | Should Throw
    }
    Exit-TestRoot $t
}

Describe 'outbox of the agent (C79)' {
    $t = Enter-TestRoot
    [void](Test-VlcShare $t.Share 'Station')
    It 'sends the oldest scan first, by the time in its job id' {
        $older = New-VlcJobId 'B' (Get-Date).AddMinutes(-5)
        $newer = New-VlcJobId 'A'
        foreach ($id in $newer, $older) { [void](New-VlcOutboxJob $id 'x' $t.Stl 'x.vld4') }
        @((Send-VlcOutbox $t.Share).Sent) -join ',' | Should Be "$older,$newer"
    }
    It 'sets a job aside whose STL is missing, without sending it' {
        $id = New-VlcJobId 'C'
        [void](New-VlcOutboxJob $id 'C' $t.Stl 'c.vld4')
        Remove-Item -LiteralPath (Join-Path (Get-VlcOutbox) "$id.stl")
        $r = Send-VlcOutbox $t.Share
        $r.Failed[0].JobId | Should Be $id
        Test-Path -LiteralPath (Join-Path (Get-VlcOutbox) "failed\$id.job") | Should Be $true
        Test-Path -LiteralPath (Join-Path $t.Share "jobs\$id.job") | Should Be $false
    }
    It 'tries a job five times, then sets it aside; the other jobs still go' {
        $stuck = New-VlcJobId 'D' (Get-Date).AddMinutes(-1)
        $other = New-VlcJobId 'E'
        foreach ($id in $stuck, $other) { [void](New-VlcOutboxJob $id 'x' $t.Stl 'x.vld4') }
        # a file in use on the shared folder: the STL of the stuck job cannot be written
        $part = Join-Path $t.Share "jobs\$stuck.stl.part"
        $lock = [IO.File]::Open($part, 'Create', 'ReadWrite', 'None')
        try {
            $r = Send-VlcOutbox $t.Share
            @($r.Sent) | Should Be $other
            $r.ShareOk | Should Be $true
            @($r.Errors)[0] | Should Match 'attempt 1 of 5'
            Test-Path -LiteralPath (Join-Path $t.Share "jobs\$stuck.job") | Should Be $false
            for ($n = 2; $n -le 5; $n++) { $r = Send-VlcOutbox $t.Share }
        }
        finally { $lock.Dispose() }
        $r.Failed[0].JobId | Should Be $stuck
        [IO.File]::ReadAllText((Join-Path (Get-VlcOutbox) "failed\$stuck.reason")) | Should Match 'Not sent after 5 attempts'
        @(Get-ChildItem -LiteralPath (Get-VlcOutbox) -Filter '*.job').Count | Should Be 0
        Remove-Item -LiteralPath $part -Force
    }
    It 'keeps every job, without counting an attempt, while the shared folder is not reachable' {
        $id = New-VlcJobId 'F'
        [void](New-VlcOutboxJob $id 'F' $t.Stl 'f.vld4')
        $r = Send-VlcOutbox (Join-Path $t.Root 'missing')
        $r.ShareOk | Should Be $false
        @($r.Failed).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path (Get-VlcOutbox) "$id.job") | Should Be $true
        Test-Path -LiteralPath (Join-Path (Get-VlcOutbox) "$id.tries") | Should Be $false
    }
    Exit-TestRoot $t
}

Describe 'reports for the scanner PC (C28)' {
    $t = Enter-TestRoot
    [void](Test-VlcShare $t.Share 'Station')
    $utcNow = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    function Write-TestResult([string]$JobId, [switch]$Csv) {
        Write-KeyValueFile (Join-Path $t.Share "reports\$JobId.result") ([ordered]@{ PROTOCOL = '1'; JOBID = $JobId; STATE = 'OK'; VERDICT = 'NOK'
            SUMMARY = '1 of 3 controls out of tolerance'; PDF = "$JobId.pdf"; CSV = $(if ($Csv) { "$JobId.csv" } else { '' }); STATION = 'Line 1'
            FINISHED_UTC = $utcNow; MESSAGE = '' })
    }
    It 'keeps a job pending while its PDF has not arrived' {
        $id = New-VlcJobId 'G'
        Add-VlcPendingJob $id 'G'
        Write-TestResult $id
        @(Receive-VlcReports $t.Share $t.Local).Count | Should Be 0
        @(Get-VlcPendingJobs | Where-Object { $_.JobId -eq $id }).Count | Should Be 1
    }
    It 'reports it without the PDF when the PDF does not come in time' {
        $done = @(Receive-VlcReports $t.Share $t.Local 0)
        $done.Count | Should Be 1
        $done[0].Pdf | Should Be ''
        $done[0].Message | Should Match 'did not arrive'
        @(Get-VlcPendingJobs).Count | Should Be 0
    }
    It 'copies a complete PDF and the CSV and marks both as downloaded' {
        $id = New-VlcJobId 'H'
        Add-VlcPendingJob $id 'H'
        New-TestPdf (Join-Path $t.Share "reports\$id.pdf")
        [IO.File]::WriteAllText((Join-Path $t.Share "reports\$id.csv"), "a;b`r`n")
        Write-TestResult $id -Csv
        $done = @(Receive-VlcReports $t.Share $t.Local)
        $done[0].Pdf | Should Be (Join-Path $t.Local "$id.pdf")
        $done[0].Verdict | Should Be 'NOK'
        $done[0].Station | Should Be 'Line 1'
        foreach ($f in "$id.pdf", "$id.csv") { (Get-Content -LiteralPath (Join-Path $t.Local $f) -Stream 'Zone.Identifier') -join ' ' | Should Match 'ZoneId=3' }
    }
    Exit-TestRoot $t
}

Describe 'station queue and claims (C34, C36)' {
    $t = Enter-TestRoot
    [void](Test-VlcShare $t.Share 'Station')
    Save-VlcPrograms $t.Share @([pscustomobject]@{ Program = 'ABC'; Workspace = $t.Workspace; Template = 'ABC template' })
    # a scan of VL program ABC, sent through the outbox; $Part only names the job
    function Send-TestJob([string]$Part = 'ABC', [datetime]$Time = (Get-Date)) {
        $id = New-VlcJobId $Part $Time
        [void](New-VlcOutboxJob $id $Part $t.Stl 'ABC.vld4')
        [void](Send-VlcOutbox $t.Share)
        return $id
    }
    $okResult = [ordered]@{ STATE = 'OK'; VERDICT = 'OK'; SUMMARY = 'all 3 controls within tolerance'; MESSAGE = '' }
    It 'takes the oldest job first, by the time in its job id, and notes who claimed it' {
        $newer = Send-TestJob 'AAA'
        $older = Send-TestJob 'ZZZ' (Get-Date).AddMinutes(-3)
        $next = Get-VlcNextJob $t.Share 'Line 1'
        $next.JobId | Should Be $older
        $claim = Read-KeyValueFile (Join-Path $t.Share "work\$older.claim")
        $claim.STATION | Should Be 'Line 1'
        $claim.COMPUTER | Should Be $env:COMPUTERNAME
        Complete-VlcJob $t.Share $older $okResult '' '' $next.Map 'Line 1' | Should Be $true
        $next = Get-VlcNextJob $t.Share 'Line 1'
        $next.JobId | Should Be $newer
        Complete-VlcJob $t.Share $newer $okResult '' '' $next.Map 'Line 1' | Should Be $true
    }
    It 'sets a file that is no job aside in jobs\rejected' {
        [IO.File]::WriteAllText((Join-Path $t.Share 'jobs\not a job.job'), 'x')
        Get-VlcNextJob $t.Share | Should Be $null
        Test-Path -LiteralPath (Join-Path $t.Share 'jobs\rejected\not a job.job') | Should Be $true
    }
    It 'refuses an STL over the size limit' {
        $id = Send-TestJob
        Get-VlcNextJob $t.Share -MaxStlBytes 100 | Should Be $null
        (Read-KeyValueFile (Join-Path $t.Share "reports\$id.result")).MESSAGE | Should Match 'larger than'
        Test-Path -LiteralPath (Join-Path $t.Share "failed\$id.job") | Should Be $true
    }
    It 'never overwrites an OK result, and names the workspace and the template in it' {
        $id = Send-TestJob
        $next = Get-VlcNextJob $t.Share 'Line 1'
        Complete-VlcJob $t.Share $id $okResult '' '' $next.Map 'Line 1' | Should Be $true
        Complete-VlcJob $t.Share $id ([ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; MESSAGE = 'late' }) '' '' $null 'Line 2' | Should Be $false
        $r = Read-KeyValueFile (Join-Path $t.Share "reports\$id.result")
        $r.STATE | Should Be 'OK'
        $r.STATION | Should Be 'Line 1'
        $r.WORKSPACE | Should Be $t.Workspace
        $r.TEMPLATE | Should Be 'ABC template'
        Test-Path -LiteralPath (Join-Path $t.Share "work\$id.claim") | Should Be $false
    }
    It 'reports a job its own station left unfinished when the station starts, and any job after the time limit' {
        $mine = New-VlcJobId 'ABC'
        $theirs = New-VlcJobId 'ABC'
        $utc = (Get-Date).ToUniversalTime()
        foreach ($c in @(@($mine, $env:COMPUTERNAME), @($theirs, 'OTHERPC'))) {
            [IO.File]::WriteAllText((Join-Path $t.Share "work\$($c[0]).job"), 'x')
            Write-KeyValueFile (Join-Path $t.Share "work\$($c[0]).claim") ([ordered]@{ STATION = 'S'; COMPUTER = $c[1]; CLAIMED_UTC = $utc.ToString('yyyy-MM-ddTHH:mm:ssZ') })
        }
        @(Resolve-VlcStaleJobs $t.Share 15 -OwnOnly) | Should Be $mine
        (Read-KeyValueFile (Join-Path $t.Share "reports\$mine.result")).MESSAGE | Should Match 'was stopped while it evaluated'
        @(Resolve-VlcStaleJobs $t.Share 15).Count | Should Be 0
        Write-KeyValueFile (Join-Path $t.Share "work\$theirs.claim") ([ordered]@{ STATION = 'S'; COMPUTER = 'OTHERPC'; CLAIMED_UTC = $utc.AddMinutes(-20).ToString('yyyy-MM-ddTHH:mm:ssZ') })
        @(Resolve-VlcStaleJobs $t.Share 15) | Should Be $theirs
        (Read-KeyValueFile (Join-Path $t.Share "reports\$theirs.result")).MESSAGE | Should Match 'did not finish the evaluation within 15 min'
        Test-Path -LiteralPath (Join-Path $t.Share "failed\$theirs.job") | Should Be $true
    }
    Exit-TestRoot $t
}

Describe 'Measurement Programs List (C75, C29)' {
    $t = Enter-TestRoot
    [void](Test-VlcShare $t.Share 'Station')
    function Set-List([string[]]$Lines) { [IO.File]::WriteAllLines((Join-Path $t.Share 'programs.csv'), $Lines, (New-Object Text.UTF8Encoding($true))) }
    It 'matches program names exactly, dots included' {
        Save-VlcPrograms $t.Share @([pscustomobject]@{ Program = 'Part'; Workspace = $t.Workspace; Template = 'T1' }, [pscustomobject]@{ Program = 'Part.A'; Workspace = $t.Workspace; Template = 'T2' })
        (Find-VlcProgram $t.Share 'Part.A.vld4').Template | Should Be 'T2'
        (Find-VlcProgram $t.Share 'C:\VL\Programs\part.vld4').Template | Should Be 'T1'
        Find-VlcProgram $t.Share 'Part.B' | Should Be $null
    }
    It 'leaves out every unusable line and names it' {
        $ws = $t.Workspace
        Set-List @('Program;Workspace;Template', "Good;$ws;T", 'Two;values', "Eq;$ws;T=1", 'Relative;parts.pwk;T', 'NoPwk;C:\x\parts.txt;T',
            'Unc;\\fileserver\metrology\parts.pwk;T', "Twice;$ws;T", "twice;$ws;T2")
        $l = Read-VlcProgramsList $t.Share
        @($l.Rows | ForEach-Object { $_.Program }) -join ',' | Should Be 'Good'
        $l.Fatal | Should Be ''
        $l.Problems.Count | Should Be 6
        $l.Problems[0] | Should Match 'line 3: three values'
        $l.Problems[1] | Should Match "line 4: '=' and quotes"
        $l.Problems[2] | Should Match 'line 5: the workspace must be the full path'
        $l.Problems[3] | Should Match 'line 6: the workspace must be the full path'
        $l.Problems[4] | Should Match 'line 7: .*network path'
        $l.Problems[5] | Should Match 'line 9: program twice is listed twice \(also line 8\)'
        @((Read-VlcProgramsList $t.Share $true).Rows | ForEach-Object { $_.Program }) -join ',' | Should Be 'Good,Unc'
    }
    It 'is not usable at all without its header line' {
        Set-List @("Good;$($t.Workspace);T")
        (Read-VlcProgramsList $t.Share).Fatal | Should Match 'must start with the line Program;Workspace;Template'
        @(Get-VlcPrograms $t.Share).Count | Should Be 0
    }
    Exit-TestRoot $t
}

Describe 'role test of the shared folder (C30)' {
    $t = Enter-TestRoot
    It 'checks what a scanner PC needs: send jobs, read reports and status' {
        $r = Test-VlcShare $t.Share 'Scanner'
        $r.Ok | Should Be $true
        $r.Text | Should Match 'jobs can be sent'
        Test-Path -LiteralPath (Join-Path $t.Share 'work') | Should Be $false
    }
    It 'checks that a station can write in every folder' {
        $r = Test-VlcShare $t.Share 'Station'
        $r.Ok | Should Be $true
        foreach ($f in 'jobs', 'work', 'reports', 'processed', 'failed', 'status') { Test-Path -LiteralPath (Join-Path $t.Share $f) | Should Be $true }
    }
    It 'names the step that does not work' {
        $bad = Join-Path $t.Root 'bad'
        New-Item -ItemType Directory -Path $bad | Out-Null
        [IO.File]::WriteAllText((Join-Path $bad 'jobs'), 'a file, not a folder')
        $r = Test-VlcShare $bad 'Scanner'
        $r.Ok | Should Be $false
        $r.Text | Should Match 'cannot write in jobs'
        (Test-VlcShare 'metrology\share' 'Scanner').Ok | Should Be $false
    }
    Exit-TestRoot $t
}

Describe 'station liveness (C82, C83)' {
    $now = [datetime]::new(2026, 10, 30, 10, 0, 0, [DateTimeKind]::Local)
    function New-Beat([string]$State, [string]$Beat, [string]$UpdatedUtc) { [pscustomobject]@{ Key = 'PC1'; Name = 'Line 1'; State = $State; Job = ''; Beat = $Beat; UpdatedUtc = $UpdatedUtc } }
    function Get-Utc([int]$Seconds) { $now.ToUniversalTime().AddSeconds($Seconds).ToString('yyyy-MM-ddTHH:mm:ssZ') }
    It 'is online while the heartbeat counter changes, measured with the own clock' {
        $seen = @{}
        $s = Update-VlcStationLiveness $seen @(New-Beat 'Idle' '5' (Get-Utc -30)) $now 15
        $s.Online | Should Be $true
        $s.AgeSec | Should Be 30
        (Update-VlcStationLiveness $seen @(New-Beat 'Idle' '5' (Get-Utc -30)) $now.AddSeconds(100) 15).Online | Should Be $false
        (Update-VlcStationLiveness $seen @(New-Beat 'Idle' '6' (Get-Utc -30)) $now.AddSeconds(105) 15).Online | Should Be $true
    }
    It 'does not trust the clock of the station' {
        $seen = @{}
        $s = Update-VlcStationLiveness $seen @(New-Beat 'Idle' '1' (Get-Utc 3600)) $now 15
        $s.AgeSec | Should Be 0
        $s.Online | Should Be $true
        (Update-VlcStationLiveness $seen @(New-Beat 'Idle' '1' 'garbage') $now.AddSeconds(130) 15).Online | Should Be $false
    }
    It 'keeps a busy station online up to the job time limit' {
        $seen = @{}
        [void](Update-VlcStationLiveness $seen @(New-Beat 'Busy' '7' (Get-Utc 0)) $now 10)
        (Update-VlcStationLiveness $seen @(New-Beat 'Busy' '7' (Get-Utc 0)) $now.AddSeconds(600) 10).Online | Should Be $true
        (Update-VlcStationLiveness $seen @(New-Beat 'Busy' '7' (Get-Utc 0)) $now.AddSeconds(700) 10).Online | Should Be $false
    }
    It 'shows a stopped station offline at once' {
        (Update-VlcStationLiveness @{} @(New-Beat 'Stopped' '9' (Get-Utc 0)) $now 15).Online | Should Be $false
    }
}

Describe 'station steps of the PolyWorks macro (Station-Step.ps1)' {
    $t = Enter-TestRoot
    New-Item -ItemType Directory -Force -Path (Join-Path $env:APPDATA 'VLConnector') | Out-Null
    $user = @{ scenario = 'Network'; role = 'Station'; network = @{ share = $t.Share; stationName = 'Line 2' } }
    [IO.File]::WriteAllText((Join-Path $env:APPDATA 'VLConnector\settings.json'), ($user | ConvertTo-Json))
    $stationDir = Join-Path $env:LOCALAPPDATA 'VLConnector\station'
    $statusFile = Join-Path $t.Share "status\$(ConvertTo-JobIdPart $env:COMPUTERNAME).station"
    function Invoke-Step([string]$Action, [string[]]$More = @()) {
        $out = Join-Path $t.Root "$Action.out"
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'polyworks\Station-Step.ps1') -Action $Action -Out $out @More
        return Read-KeyValueFile $out
    }
    function Send-TestJob {
        $id = New-VlcJobId 'ABC'
        [void](New-VlcOutboxJob $id 'ABC' $t.Stl 'ABC.vld4')
        [void](Send-VlcOutbox $t.Share)
        return $id
    }
    It 'starts with the station name and a first heartbeat' {
        $o = Invoke-Step 'Context'
        @($o.Keys) -join ',' | Should Be 'STATE,SHARE,POLL_MS,STATUS_FILE,MESSAGE,STATION'
        $o.STATE | Should Be 'OK'
        $o.STATION | Should Be 'Line 2'
        $o.STATUS_FILE | Should Be $statusFile
        $s = Read-KeyValueFile $statusFile
        @($s.Keys) -join ',' | Should Be 'STATION,STATE,JOB,VERSION,UPDATED_UTC,BEAT'
        $s.STATION | Should Be 'Line 2'
        $s.STATE | Should Be 'Idle'
        $s.BEAT | Should Be '1'
    }
    It 'answers IDLE without a job and keeps the heartbeat going' {
        (Invoke-Step 'Next').STATE | Should Be 'IDLE'
        (Read-KeyValueFile $statusFile).BEAT | Should Be '2'
    }
    Save-VlcPrograms $t.Share @([pscustomobject]@{ Program = 'ABC'; Workspace = $t.Workspace; Template = 'ABC template' })
    $id = Send-TestJob
    It 'claims a job and writes the parameters of VLC_Evaluate' {
        $o = Invoke-Step 'Next'
        $o.STATE | Should Be 'JOB'
        $o.JOBID | Should Be $id
        $o.PART | Should Be 'ABC'
        $p = Read-KeyValueFile $o.PARAMS
        $p.PWK | Should Be $t.Workspace
        $p.TEMPLATE | Should Be 'ABC template'
        $p.STL | Should Be (Join-Path $t.Share "work\$id.stl")
        $p.JOBID | Should Be $id
        (Read-KeyValueFile $statusFile).STATE | Should Be 'Busy'
        (Read-KeyValueFile (Join-Path $t.Share "work\$id.claim")).STATION | Should Be 'Line 2'
    }
    It 'publishes PDF, CSV and verdict with the workspace and the template; the station is idle again' {
        $reports = Join-Path $stationDir 'reports'
        $pdf = Join-Path $reports 'piece.pdf'
        New-TestPdf $pdf
        $csv = Join-Path $reports 'piece.csv'
        [IO.File]::WriteAllText($csv, "a;b`r`n")
        $result = Join-Path $stationDir "$id.result"
        Write-KeyValueFile $result ([ordered]@{ STATE = 'OK'; VERDICT = 'NOK'; SUMMARY = '1 of 3 controls out of tolerance'; PDF = $pdf; CSV = $csv; PIECE = 'p'; PIECE_KEPT = '1'; MESSAGE = '' })
        $o = Invoke-Step 'Publish' @('-JobId', $id, '-Result', $result)
        @($o.Keys) -join ',' | Should Be 'STATE,MESSAGE'
        $o.STATE | Should Be 'OK'
        $o.MESSAGE | Should Be ''
        $r = Read-KeyValueFile (Join-Path $t.Share "reports\$id.result")
        $r.VERDICT | Should Be 'NOK'
        $r.WORKSPACE | Should Be $t.Workspace
        $r.TEMPLATE | Should Be 'ABC template'
        $r.STATION | Should Be 'Line 2'
        Test-PdfFile (Join-Path $t.Share "reports\$id.pdf") | Should Be $true
        Test-Path -LiteralPath (Join-Path $t.Share "reports\$id.csv") | Should Be $true
        Test-Path -LiteralPath (Join-Path $t.Share "processed\$id.job") | Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $t.Share 'work')).Count | Should Be 0
        Test-Path -LiteralPath (Join-Path $stationDir "$id.params") | Should Be $false
        (Read-KeyValueFile $statusFile).STATE | Should Be 'Idle'
    }
    It 'leaves an OK result as it is when the job is published again' {
        $o = Invoke-Step 'Publish' @('-JobId', $id, '-Result', (Join-Path $stationDir "$id.result"))
        $o.STATE | Should Be 'OK'
        $o.MESSAGE | Should Match 'OK result already'
        (Read-KeyValueFile (Join-Path $t.Share "reports\$id.result")).VERDICT | Should Be 'NOK'
    }
    It 'reports a job that fails after its claim to the scanner PC, and pauses' {
        $id2 = Send-TestJob
        # a folder where the parameter file goes: the step fails after the claim
        $blocker = Join-Path $stationDir "$id2.params"
        New-Item -ItemType Directory -Path $blocker | Out-Null
        try { $o = Invoke-Step 'Next' } finally { Remove-Item -LiteralPath $blocker -Recurse -Force }
        $o.STATE | Should Be 'ERROR'
        $o.JOBID | Should Be ''
        (Read-KeyValueFile (Join-Path $t.Share "reports\$id2.result")).STATE | Should Be 'ERROR'
        Test-Path -LiteralPath (Join-Path $t.Share "failed\$id2.job") | Should Be $true
        @(Get-ChildItem -LiteralPath (Join-Path $t.Share 'work')).Count | Should Be 0
        (Read-KeyValueFile $statusFile).STATE | Should Be 'Paused'
    }
    It 'pauses without claiming while the Measurement Programs List is not usable' {
        [IO.File]::WriteAllLines((Join-Path $t.Share 'programs.csv'), [string[]]@("ABC;$($t.Workspace);ABC template"))
        $id3 = Send-TestJob
        $o = Invoke-Step 'Next'
        $o.STATE | Should Be 'ERROR'
        $o.MESSAGE | Should Match 'must start with'
        Test-Path -LiteralPath (Join-Path $t.Share "jobs\$id3.job") | Should Be $true
        (Read-KeyValueFile $statusFile).STATE | Should Be 'Paused'
    }
    Exit-TestRoot $t
}

Describe 'one network cycle of the agent (AgentCycle.ps1)' {
    $t = Enter-TestRoot
    [void](Test-VlcShare $t.Share 'Station')
    Save-VlcPrograms $t.Share @([pscustomobject]@{ Program = 'ABC'; Workspace = $t.Workspace; Template = 'ABC template' })
    $cycle = Join-Path $app 'lib\AgentCycle.ps1'
    It 'sends a noted scan, reads the stations, and fetches the report in a later cycle' {
        Write-VlcStationStatus $t.Share 'Idle' '' 'Line 1'
        $id = New-VlcJobId 'ABC'
        Add-VlcInboxScan $id 'ABC' $t.Stl 'ABC.vld4'
        $r = & $cycle -Share $t.Share -Reports $t.Local
        @($r.Converted) | Should Be $id
        @($r.Sent) | Should Be $id
        $r.ShareOk | Should Be $true
        $r.Outbox | Should Be 0
        @($r.Errors).Count | Should Be 0
        $r.Stations[0].Name | Should Be 'Line 1'
        $next = Get-VlcNextJob $t.Share 'Line 1'
        $pdf = Join-Path $t.Root 'station\report.pdf'
        New-TestPdf $pdf
        [void](Complete-VlcJob $t.Share $id ([ordered]@{ STATE = 'OK'; VERDICT = 'OK'; SUMMARY = 'all 3 controls within tolerance'; MESSAGE = '' }) $pdf '' $next.Map 'Line 1')
        $r = & $cycle -Share $t.Share -Reports $t.Local
        $r.Done[0].JobId | Should Be $id
        Test-Path -LiteralPath $r.Done[0].Pdf | Should Be $true
    }
    It 'keeps the scans, and says so, while the shared folder is not reachable' {
        $id = New-VlcJobId 'ABC'
        Add-VlcInboxScan $id 'ABC' $t.Stl 'ABC.vld4'
        $r = & $cycle -Share (Join-Path $t.Root 'missing') -Reports $t.Local
        @($r.Converted) | Should Be $id
        $r.ShareOk | Should Be $false
        $r.Outbox | Should Be 1
    }
    Exit-TestRoot $t
}
