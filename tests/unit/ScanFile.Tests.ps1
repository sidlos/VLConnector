# Pester 3.4 unit tests: right before VLC_Evaluate.pwmacro imports a scan, Test-ScanFile.ps1 checks that the STL is
# the one VL Connector exported (C26). VL Connector gives no verdict of its own; this is its only check of a scan.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
. (Join-Path $app 'lib\KeyValueFile.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Invoke-ScanCheck([string]$Stl, [string]$Sha256, [string]$Out) {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'polyworks\Test-ScanFile.ps1') -Stl $Stl -Sha256 $Sha256 -Out $Out
    return Read-KeyValueFile $Out
}

Describe 'Test-ScanFile.ps1' {
    $dir = Join-Path $TestDrive 'scans'
    New-Item -ItemType Directory -Path $dir | Out-Null
    $stl = Join-Path $dir 'ABC_20261104_101500.stl'
    [IO.File]::WriteAllBytes($stl, [byte[]](1..200))
    $hash = (Get-FileHash -LiteralPath $stl -Algorithm SHA256).Hash.ToLower()

    It 'accepts the STL that was exported (the hash in any letter case), in the order the macro reads' {
        $out = Join-Path $dir 'ok.check'
        $r = Invoke-ScanCheck $stl $hash.ToUpper() $out
        @($r.Keys) -join ',' | Should Be 'STATE,MESSAGE'
        $r.STATE | Should Be 'OK'
        $r.MESSAGE | Should BeNullOrEmpty
    }
    It 'refuses an STL that was replaced after the export' {
        $out = Join-Path $dir 'other.check'
        $other = Join-Path $dir 'other.stl'
        [IO.File]::WriteAllBytes($other, [byte[]](2..201))
        $r = Invoke-ScanCheck $other $hash $out
        $r.STATE | Should Be 'ERROR'
        $r.MESSAGE | Should Match "not the one that was scanned .*expected $hash"
    }
    It 'refuses a missing STL' {
        $out = Join-Path $dir 'missing.check'
        $r = Invoke-ScanCheck (Join-Path $dir 'none.stl') $hash $out
        $r.STATE | Should Be 'ERROR'
        $r.MESSAGE | Should Match 'was not found'
    }
}
