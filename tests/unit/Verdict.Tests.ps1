# Pester 3.4 unit tests: the verdict of a measured piece is fail-closed (C40, C41, C84), the CSV is safe to open
# in a spreadsheet (C55) and a replaced STL is detected (C26). Without PolyWorks: the control data that
# VLC_Evaluate.pwmacro writes is made here.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
foreach ($lib in 'KeyValueFile', 'Verdict') { . (Join-Path $app "lib\$lib.ps1") }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Control data as VLC_Evaluate writes it (UTF-16). $Controls: @( @('Plane 1', 'Flatness', 'Within positive safe zone'), ... )
function New-ControlsFile([string]$Path, [object[]]$Controls, [hashtable]$Header = @{}, [string]$End = '', [switch]$Ascii) {
    $h = [ordered]@{ FORMAT = 'VLC-CONTROLS-1'; RUN = '20261030_101500'; JOBID = ''; PIECE = 'ABC_20261030_101500'; TEMPLATE = 'ABC'; PROGRAM = 'ABC.vld4'
        OPERATOR = 'Jiří Novák'; STL = ''; STL_SHA256 = ''; REPORT_DIR = (Split-Path $Path); CSV = (Join-Path (Split-Path $Path) 'ABC_20261030_101500.csv')
        ALIGN_STATUS = ''; ALIGN_ERROR = ''; EXTRACT_STATUS = ''; EXTRACT_ERROR = '' }
    foreach ($k in $Header.Keys) { $h[$k] = $Header[$k] }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($k in $h.Keys) { $lines.Add("$k=$($h[$k])") }
    foreach ($c in $Controls) {
        foreach ($pair in @(@('CONTROL', $c[0]), @('NAME', $c[1]), @('NOMINAL', '10'), @('MEASURED', '10.02'), @('DEVIATION', '-0.02'),
                @('UPPER_TOL', '0.1'), @('UPPER_WARN', '0.08'), @('LOWER_WARN', '-0.08'), @('LOWER_TOL', '-0.1'), @('RESULT', $c[2]))) {
            $lines.Add("$($pair[0])=$($pair[1])")
        }
    }
    $lines.Add("END=$(if ($End) { $End } else { @($Controls).Count })")
    [IO.File]::WriteAllLines($Path, [string[]]$lines, $(if ($Ascii) { [Text.Encoding]::ASCII } else { [Text.Encoding]::Unicode }))
    return $Path
}

Describe 'verdict of one control' {
    It 'is OK only for the documented results inside the tolerance' {
        Get-VlcControlVerdict 'Within positive safe zone' | Should Be 'OK'
        Get-VlcControlVerdict 'Within negative safe zone' | Should Be 'OK'
        Get-VlcControlVerdict 'Within upper warning zone' | Should Be 'OK (warning)'
        Get-VlcControlVerdict 'Within lower warning zone' | Should Be 'OK (warning)'
        Get-VlcControlVerdict 'Beyond upper tolerance limit' | Should Be 'NOK'
        Get-VlcControlVerdict 'Beyond lower tolerance limit' | Should Be 'NOK'
        Get-VlcControlVerdict '' | Should Be 'NOT MEASURED'
        Get-VlcControlVerdict '   ' | Should Be 'NOT MEASURED'
        Get-VlcControlVerdict 'Pass' | Should Be 'UNKNOWN'
        Get-VlcControlVerdict 'Within tolerance' | Should Be 'UNKNOWN'
    }
}

Describe 'control data' {
    $dir = Join-Path $TestDrive 'data'
    New-Item -ItemType Directory -Path $dir | Out-Null
    It 'is read with its header and every control, also with non-ASCII names' {
        $f = New-ControlsFile (Join-Path $dir 'a.controls') @(@('Plane 1', 'Rovinnost č.1', 'Within positive safe zone'), @('Cylinder=2', 'Diameter', 'Beyond upper tolerance limit'))
        $d = Read-VlcControlsFile $f
        $d.Header.OPERATOR | Should Be 'Jiří Novák'
        @($d.Controls).Count | Should Be 2
        $d.Controls[0].NAME | Should Be 'Rovinnost č.1'
        $d.Controls[1].CONTROL | Should Be 'Cylinder=2'
    }
    It 'is refused when it is cut off, out of order, miscounted or of another format' {
        $c = @(@('P', 'F', 'Within positive safe zone'), @('Q', 'G', 'Within positive safe zone'))
        $f = New-ControlsFile (Join-Path $dir 'b.controls') $c
        $text = [IO.File]::ReadAllText($f)
        [IO.File]::WriteAllText($f, ($text -replace 'END=2\r?\n?$', ''), [Text.Encoding]::Unicode)
        { Read-VlcControlsFile $f } | Should Throw 'cut off'
        [IO.File]::WriteAllText($f, ($text -replace 'RESULT=Within positive safe zone\r\nCONTROL=Q', 'CONTROL=Q'), [Text.Encoding]::Unicode)
        { Read-VlcControlsFile $f } | Should Throw 'incomplete at control 1'
        { Read-VlcControlsFile (New-ControlsFile (Join-Path $dir 'c.controls') $c -End 3) } | Should Throw "its END line says '3'"
        { Read-VlcControlsFile (New-ControlsFile (Join-Path $dir 'd.controls') $c -Header @{ FORMAT = 'X' }) } | Should Throw 'unknown format'
        { Read-VlcControlsFile (Join-Path $dir 'missing.controls') } | Should Throw 'is missing'
        [IO.File]::WriteAllText($f, "FORMAT=VLC-CONTROLS-1`r`nJOBID=`r`n", [Text.Encoding]::Unicode)
        { Read-VlcControlsFile $f } | Should Throw 'no RUN in line 2'
    }
}

Describe 'verdict of a piece' {
    $dir = Join-Path $TestDrive 'piece'
    New-Item -ItemType Directory -Path $dir | Out-Null
    $ok = @('Plane 1', 'Flatness', 'Within positive safe zone')
    function Get-Result([object[]]$Controls, [hashtable]$Header = @{}, [string]$Hash = '') {
        return Get-VlcEvaluation (Read-VlcControlsFile (New-ControlsFile (Join-Path $dir 'p.controls') $Controls $Header)) $Hash
    }
    It 'is OK when every control is inside the tolerance' {
        $r = Get-Result @($ok, @('Cyl 1', 'Diameter', 'Within negative safe zone'), @('Pt 1', 'Dev', 'Within upper warning zone'))
        $r.State | Should Be 'OK'
        $r.Verdict | Should Be 'OK'
        $r.Summary | Should Be 'all 3 controls within tolerance (1 in the warning zone)'
    }
    It 'is NOK for a control out of tolerance, one not measured or one with an unknown result' {
        (Get-Result @($ok, @('Cyl 1', 'Diameter', 'Beyond lower tolerance limit'))).Verdict | Should Be 'NOK'
        $r = Get-Result @($ok, @('Cyl 1', 'Diameter', ''))
        $r.Verdict | Should Be 'NOK'
        $r.Summary | Should Be '0 of 2 controls out of tolerance, 1 not measured'
        $r = Get-Result @($ok, @('Cyl 1', 'Diameter', 'Passed'))
        $r.Verdict | Should Be 'NOK'
        $r.Summary | Should Match "1 with a result VL Connector does not know \(Cyl 1 Diameter: 'Passed'\)"
    }
    It 'gives no verdict without controls, after a failed alignment or measurement, or for another STL' {
        foreach ($case in @(
                @{ C = @(); H = @{}; Why = 'has no controls' }
                @{ C = @(,$ok); H = @{ ALIGN_STATUS = 'Error'; ALIGN_ERROR = 'not enough overlap' }; Why = 'alignment to the CAD failed: not enough overlap' }
                @{ C = @(,$ok); H = @{ EXTRACT_STATUS = 'Error'; EXTRACT_ERROR = 'no data' }; Why = 'measurement of the features failed: no data' }
                @{ C = @(,$ok); H = @{ STL_SHA256 = 'AB12' }; Why = 'STL is not the one that was scanned' })) {
            $r = Get-Result $case.C $case.H 'ff00'
            $r.State | Should Be 'ERROR'
            $r.Verdict | Should Be ''
            $r.Message | Should Match $case.Why
        }
        (Get-Result @(,$ok) @{ STL_SHA256 = 'AB12' } 'ab12').Verdict | Should Be 'OK'
    }
}

Describe 'CSV of a piece' {
    It 'protects text that a spreadsheet would run as a formula and keeps numbers' {
        ConvertTo-VlcCsvCell '=HYPERLINK("x")' | Should Be '"''=HYPERLINK(""x"")"'
        ConvertTo-VlcCsvCell '+1' | Should Be "'+1"
        ConvertTo-VlcCsvCell '@SUM' | Should Be "'@SUM"
        ConvertTo-VlcCsvCell '-0.05' -Number | Should Be '-0.05'
        ConvertTo-VlcCsvCell '-0,05' -Number | Should Be '-0,05'
        ConvertTo-VlcCsvCell '-cmd' -Number | Should Be "'-cmd"
        ConvertTo-VlcCsvCell 'a;b' | Should Be '"a;b"'
        ConvertTo-VlcCsvCell 'say "x"' | Should Be '"say ""x"""'
    }
    It 'is written by Complete-Evaluation.ps1 as UTF-8 with BOM, with the verdict file in the order the macro reads' {
        $dir = Join-Path $TestDrive 'report'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $stl = Join-Path $dir 'scan.stl'
        [IO.File]::WriteAllBytes($stl, [byte[]](1..200))
        $hash = (Get-FileHash -LiteralPath $stl -Algorithm SHA256).Hash.ToLower()
        $f = New-ControlsFile (Join-Path $dir 'run.controls') @(,@('=cmd|calc', 'Plošnost', 'Within positive safe zone')) @{ STL = $stl; STL_SHA256 = $hash; JOBID = 'job1' }
        $out = Join-Path $dir 'run.verdict'
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'polyworks\Complete-Evaluation.ps1') -Controls $f -Out $out
        $v = Read-KeyValueFile $out
        @($v.Keys) -join ',' | Should Be 'STATE,VERDICT,SUMMARY,COUNT,RUN,JOBID,CSV,MESSAGE'
        $v.STATE | Should Be 'OK'
        $v.VERDICT | Should Be 'OK'
        $v.COUNT | Should Be '1'
        $v.RUN | Should Be '20261030_101500'
        $v.JOBID | Should Be 'job1'
        $bytes = [IO.File]::ReadAllBytes($v.CSV)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should Be $true
        $csv = [IO.File]::ReadAllLines($v.CSV)
        $csv[0] | Should Be 'Part;ABC_20261030_101500;VL program;ABC.vld4;Operator;Jiří Novák'
        $csv[2] | Should Be "STL;scan.stl;SHA-256;$hash"
        $csv[4] | Should Be "'=cmd|calc;Plošnost;10;10.02;-0.02;0.1;-0.1;OK"
        $csv[-1] | Should Be 'RESULT;OK - all 1 controls within tolerance'
    }
    It 'is not written for a piece without verdict, and never outside the report folder' {
        $dir = Join-Path $TestDrive 'report2'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $out = Join-Path $dir 'run.verdict'
        $f = New-ControlsFile (Join-Path $dir 'run.controls') @(,@('P', 'F', 'Within positive safe zone')) @{ CSV = (Join-Path $TestDrive 'elsewhere.csv') }
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'polyworks\Complete-Evaluation.ps1') -Controls $f -Out $out
        $v = Read-KeyValueFile $out
        $v.STATE | Should Be 'ERROR'
        $v.MESSAGE | Should Match 'not a .csv file in the report folder'
        Test-Path -LiteralPath (Join-Path $TestDrive 'elsewhere.csv') | Should Be $false
        & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'polyworks\Complete-Evaluation.ps1') -Controls (Join-Path $dir 'nothing.controls') -Out $out
        (Read-KeyValueFile $out).STATE | Should Be 'ERROR'
    }
}
