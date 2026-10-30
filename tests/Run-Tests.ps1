<#
  Test runner.
    Run-Tests.ps1 -Static                     source checks (tools\Test-Static.ps1)
    Run-Tests.ps1 -Unit                       Pester unit tests (tests\unit)
    Run-Tests.ps1 -Launcher [-Flavor en] [-Only name,...]   launcher scenarios against FakeVL
  Results of launcher scenarios are written to tests\_work\<flavor>\summary.json.
#>
param(
    [switch]$Static,
    [switch]$Unit,
    [switch]$Launcher,
    [ValidateSet('proto', 'en')][string]$Flavor = 'en',
    [string[]]$Only = @()
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$failed = 0
# powershell.exe -File passes "-Only a,b" as one string
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

if ($Static) {
    & (Join-Path $repo 'tools\Test-Static.ps1')
    if (-not $?) { $failed++ }
}

if ($Unit) {
    # the tests use Pester 3 syntax (Should Be); Windows ships 3.4.0, CI runners may carry newer versions
    Import-Module Pester -RequiredVersion 3.4.0
    # the tests and the scripts they start never see the real profile of this user
    $saved = @{ APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA }
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ('vlc_unit_' + [guid]::NewGuid().ToString('N'))
    foreach ($k in 'APPDATA', 'LOCALAPPDATA') { $d = Join-Path $profileDir $k; New-Item -ItemType Directory -Force -Path $d | Out-Null; Set-Item "env:$k" $d }
    try {
        $r = Invoke-Pester -Path (Join-Path $PSScriptRoot 'unit') -PassThru
        $failed += $r.FailedCount
    }
    finally {
        foreach ($k in $saved.Keys) { Set-Item "env:$k" $saved[$k] }
        Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Launcher) {
    $results = @()
    foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'FakeVL\scenarios') -Filter '*.json' | Sort-Object Name) {
        if ($Only -and $Only -notcontains $f.BaseName) { continue }
        $flavors = (Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json).flavors
        if ($flavors -and $flavors -notcontains $Flavor) { continue }
        Write-Host ("{0,-24}" -f $f.BaseName) -NoNewline
        $r = & (Join-Path $PSScriptRoot 'integration\Invoke-LauncherScenario.ps1') -ScenarioFile $f.FullName -Flavor $Flavor
        if ($r.Passed) { Write-Host ("PASS  {0,6}s  {1}" -f $r.Seconds, $r.State) -ForegroundColor Green }
        else { Write-Host ("FAIL  {0,6}s  {1}" -f $r.Seconds, ($r.Failures -join '; ')) -ForegroundColor Red; $failed++ }
        $results += $r
    }
    $summaryDir = Join-Path $PSScriptRoot "_work\$Flavor"
    New-Item -ItemType Directory -Force -Path $summaryDir | Out-Null
    $results | Select-Object Scenario, Passed, State, ExitCode, StlValid, Triangles, StlHash, VlRunning, Seconds, Failures |
        ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $summaryDir 'summary.json') -Encoding UTF8
}

if ($failed) { Write-Host "$failed failed" -ForegroundColor Red; exit 1 }
Write-Host 'All passed' -ForegroundColor Green
