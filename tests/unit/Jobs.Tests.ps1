# Pester 3.4 unit tests: key=value files, settings layers and the job protocol of the network scenario
# (scanner PC -> shared folder -> station -> report), on a temporary folder without PolyWorks or VL.
$app = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'app'
foreach ($lib in 'Settings', 'KeyValueFile', 'Share', 'Jobs') { . (Join-Path $app "lib\$lib.ps1") }

function New-TestStl([string]$Path, [int]$Triangles = 2) {
    $bytes = New-Object byte[] (84 + 50 * $Triangles)
    [BitConverter]::GetBytes([uint32]$Triangles).CopyTo($bytes, 80)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function New-TestPdf([string]$Path, [switch]$Truncated) {
    $text = "%PDF-1.7`n" + ('x' * 200) + $(if ($Truncated) { '' } else { "`n%%EOF`n" })
    [IO.File]::WriteAllText($Path, $text, [Text.Encoding]::ASCII)
}

Describe 'key=value files' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("vlc_kv_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    It 'round-trips non-ASCII text, keeps the order and writes a BOM' {
        $f = Join-Path $dir 'a.txt'
        Write-KeyValueFile $f ([ordered]@{ STATE = 'OK'; STL = 'C:\Users\Jiří\díl č.stl'; MESSAGE = "two`nlines a=b" })
        $bytes = [IO.File]::ReadAllBytes($f)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $true
        $r = Read-KeyValueFile $f
        @($r.Keys) -join ',' | Should Be 'STATE,STL,MESSAGE'
        $r.STL | Should Be 'C:\Users\Jiří\díl č.stl'
        $r.MESSAGE | Should Be 'two lines a-b'
    }
    It 'reads UTF-16 files written by PolyWorks' {
        $f = Join-Path $dir 'b.txt'
        [IO.File]::WriteAllText($f, "STATE=OK`r`nVERDICT=NOK`r`n", [Text.Encoding]::Unicode)
        (Read-KeyValueFile $f).VERDICT | Should Be 'NOK'
    }
    It 'ignores lines that are not KEY=value' {
        $f = Join-Path $dir 'c.txt'
        [IO.File]::WriteAllText($f, "garbage`r`n=x`r`nbad key=1`r`nGOOD_1=yes`r`n")
        @((Read-KeyValueFile $f).Keys) -join ',' | Should Be 'GOOD_1'
    }
    Remove-Item $dir -Recurse -Force
}

Describe 'network job protocol' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("vlc_jobs_" + [guid]::NewGuid().ToString('N'))
    $share = Join-Path $root 'share'
    $savedLocal = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = Join-Path $root 'local'
    New-Item -ItemType Directory -Force -Path $env:LOCALAPPDATA, (Join-Path $root 'station') | Out-Null
    $workspace = Join-Path $root 'station\Parts.pwk'
    [IO.File]::WriteAllText($workspace, 'dummy')
    $stl = Join-Path $root 'scan.stl'
    New-TestStl $stl

    It 'builds valid job ids from any part name' {
        $id = New-VlcJobId 'Part A/1 (left)'
        Test-VlcJobId $id | Should Be $true
        $id | Should Match '_Part-A-1-left_'
        Test-VlcJobId '..\evil_job' | Should Be $false
    }
    It 'prepares the shared folder and the Measurement Programs List' {
        (Test-VlcShare $share).Ok | Should Be $true
        Save-VlcPrograms $share @([pscustomobject]@{ Program = 'ABC'; Workspace = $workspace; Template = 'ABC template' })
        (Find-VlcProgram $share 'C:\VL\Programs\abc.vld4').Template | Should Be 'ABC template'
        Find-VlcProgram $share 'other.vld4' | Should Be $null
    }
    It 'refuses Measurement Programs List values with separators' {
        { Save-VlcPrograms $share @([pscustomobject]@{ Program = 'A;B'; Workspace = $workspace; Template = 'T' }) } | Should Throw
    }

    $id = New-VlcJobId 'ABC'
    It 'sends a job through the outbox' {
        [void](New-VlcOutboxJob $id 'ABC' $stl 'C:\Programs\abc.vld4')
        Add-VlcPendingJob $id 'ABC'
        @(Send-VlcOutbox $share) | Should Be $id
        Test-Path (Join-Path $share "jobs\$id.job") | Should Be $true
        Test-Path (Join-Path $share "jobs\$id.stl") | Should Be $true
        @(Get-ChildItem (Get-VlcOutbox)).Count | Should Be 0
    }
    It 'keeps a job in the outbox while the shared folder is missing' {
        $id2 = New-VlcJobId 'ABC'
        [void](New-VlcOutboxJob $id2 'ABC' $stl 'abc.vld4')
        @(Send-VlcOutbox (Join-Path $root 'missing')).Count | Should Be 0
        @(Get-ChildItem (Get-VlcOutbox) -Filter '*.job').Count | Should Be 1
        Remove-Item (Join-Path (Get-VlcOutbox) "$id2.*")
    }
    It 'lets the station claim and check the job' {
        $next = Get-VlcNextJob $share
        $next.JobId | Should Be $id
        $next.Map.Template | Should Be 'ABC template'
        Test-Path (Join-Path $share "work\$id.stl") | Should Be $true
        Test-Path (Join-Path $share "jobs\$id.job") | Should Be $false
    }
    It 'publishes the result and the scanner PC receives only its own complete PDF' {
        $pdf = Join-Path $root 'station\report.pdf'; New-TestPdf $pdf
        Complete-VlcJob $share $id ([ordered]@{ STATE = 'OK'; VERDICT = 'NOK'; SUMMARY = '2 of 13 out'; MESSAGE = '' }) $pdf ''
        Test-Path (Join-Path $share "processed\$id.job") | Should Be $true
        # a report of another PC is never fetched
        $foreign = 'OTHERPC_ABC_20260101-120000_abcd'
        Copy-Item $pdf (Join-Path $share "reports\$foreign.pdf")
        Write-KeyValueFile (Join-Path $share "reports\$foreign.result") ([ordered]@{ JOBID = $foreign; STATE = 'OK'; VERDICT = 'OK' })
        $done = @(Receive-VlcReports $share (Join-Path $root 'reports'))
        $done.Count | Should Be 1
        $done[0].Verdict | Should Be 'NOK'
        Test-Path $done[0].Pdf | Should Be $true
        Test-Path (Join-Path $root "reports\$foreign.pdf") | Should Be $false
        @(Get-VlcPendingJobs).Count | Should Be 0
    }
    It 'sends a changed STL to failed with a reason' {
        $id3 = New-VlcJobId 'ABC'
        [void](New-VlcOutboxJob $id3 'ABC' $stl 'abc.vld4'); [void](Send-VlcOutbox $share)
        $bytes = [IO.File]::ReadAllBytes((Join-Path $share "jobs\$id3.stl")); $bytes[100] = 7
        [IO.File]::WriteAllBytes((Join-Path $share "jobs\$id3.stl"), $bytes)
        Get-VlcNextJob $share | Should Be $null
        Test-Path (Join-Path $share "failed\$id3.job") | Should Be $true
        (Read-KeyValueFile (Join-Path $share "reports\$id3.result")).MESSAGE | Should Match 'differs'
    }
    It 'sends a job of an unknown VL program to failed' {
        $id4 = New-VlcJobId 'XYZ'
        [void](New-VlcOutboxJob $id4 'XYZ' $stl 'xyz.vld4'); [void](Send-VlcOutbox $share)
        Get-VlcNextJob $share | Should Be $null
        (Read-KeyValueFile (Join-Path $share "reports\$id4.result")).MESSAGE | Should Match 'not in the Measurement Programs List'
    }
    It 'recognizes complete and truncated PDF and STL files' {
        $p1 = Join-Path $root 'ok.pdf'; New-TestPdf $p1
        $p2 = Join-Path $root 'cut.pdf'; New-TestPdf $p2 -Truncated
        Test-PdfFile $p1 | Should Be $true
        Test-PdfFile $p2 | Should Be $false
        Test-BinaryStlFile $stl | Should Be $true
        [IO.File]::WriteAllBytes((Join-Path $root 'cut.stl'), [IO.File]::ReadAllBytes($stl)[0..120])
        Test-BinaryStlFile (Join-Path $root 'cut.stl') | Should Be $false
    }

    $env:LOCALAPPDATA = $savedLocal
    Remove-Item $root -Recurse -Force
}
