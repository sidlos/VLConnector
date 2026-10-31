<#
  Phase B, after a person installed VL Connector on this PC (Install.cmd, Windows asked for administrator rights):
  checks the installation from outside and prints PASS / FAIL / INFO lines. Read only: nothing is changed.
    tests\live\Test-LiveInstallation.ps1 [-InstallDir <folder>] [-Version 1.0.0-rc11]
  Checked: version, Install.cmd -Verify (files, permissions, interface DLL), the folders above, the event source,
  the Start menu for all users, the place of 1.0.0-rc10 (only forwarders, which only administrators can change,
  pointing here), the machine settings, running VL Connector processes and its recent events.
#>
param(
    [string]$InstallDir = (Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'VLConnector'),
    [string]$Version = '',
    [string]$LegacyDir = (Join-Path $env:ProgramData 'VLConnector')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'app\lib\Install.ps1')
$script:failures = 0

function Out-Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $What" -ForegroundColor Green }
    else { Write-Host "FAIL  $What  $Detail" -ForegroundColor Red; $script:failures++ }
}

function Out-Info([string]$Text) { Write-Host "INFO  $Text" -ForegroundColor Cyan }

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & $Exe @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out.Trim() }
}

if (-not $Version) { $Version = ([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim() }
$info = Join-Path $InstallDir 'install-info.txt'
Out-Check "installed in $InstallDir" (Test-Path -LiteralPath $info)
if (-not (Test-Path -LiteralPath $info)) { exit 1 }
$kv = @{}
foreach ($line in [IO.File]::ReadAllLines($info)) { $i = $line.IndexOf('='); if ($i -gt 0) { $kv[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
Out-Check "version $Version" ($kv.VERSION -eq $Version) "installed: $($kv.VERSION)"
Out-Info "installed $($kv.INSTALLED) by $($kv.BY), asked by $($kv.REQUESTED_BY), package fingerprint $($kv.FINGERPRINT)"

# the installed copy checks itself: files against its manifest, permissions, interface DLL
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$verify = Invoke-Native $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallDir 'Install.ps1'), '-Verify', '-Quiet', '-InstallDir', $InstallDir)
Out-Check 'Install.cmd -Verify: files, permissions, interface DLL' ($verify.Code -eq 0) "`n$($verify.Output)"
$parents = @(Get-VlcAclProblems $InstallDir -Parents)
Out-Check 'the folders above can be changed only by administrators' (-not $parents.Count) ($parents -join '; ')
$source = Test-Path -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EventLog\Application\VL Connector'
Out-Check 'event source "VL Connector"' $source
$menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'VL Connector'
Out-Check 'Start menu for all users' ((Test-Path -LiteralPath (Join-Path $menu 'VL Connector.lnk')) -and (Test-Path -LiteralPath (Join-Path $menu 'Uninstall VL Connector.lnk')))

$legacy = Get-VlcFolderKind $LegacyDir
if (-not $legacy) { Out-Info "$LegacyDir does not exist: no 1.0.0-rc10 was installed on this PC" }
else {
    Out-Check "$LegacyDir holds only forwarders" ($legacy.Kind -eq 'Forwarders') "it holds: $($legacy.Kind) $($legacy.Version)"
    $forwarder = Join-Path $LegacyDir 'app\polyworks\VLC_Measure.pwmacro'
    if (Test-Path -LiteralPath $forwarder) {
        Out-Check 'old Measure buttons are forwarded to this installation' ([IO.File]::ReadAllText($forwarder).Contains("$InstallDir\app\polyworks\VLC_Measure.pwmacro"))
    }
    $acl = @(Get-VlcAclProblems $LegacyDir -Recurse)
    Out-Check 'the forwarders can be changed only by administrators' (-not $acl.Count) ($acl -join '; ')
    $left = @(Get-ChildItem -LiteralPath (Split-Path $LegacyDir) -Filter 'VLConnector.removing-*' -Directory -ErrorAction SilentlyContinue)
    Out-Check 'nothing left of the old installation' (-not $left.Count) (@($left | ForEach-Object { $_.FullName }) -join ', ')
}

$machine = Join-Path $InstallDir 'machine.json'
if (Test-Path -LiteralPath $machine) {
    $m = [IO.File]::ReadAllText($machine) | ConvertFrom-Json
    Out-Info "machine.json policy: $($m.policy | ConvertTo-Json -Compress -Depth 6)"
    Out-Info "machine.json defaults: $($m.defaults | ConvertTo-Json -Compress -Depth 6)"
}
else { Out-Info 'no machine.json: product defaults, the operator answers the stage questions' }

foreach ($p in @(Get-VlcProcesses @($InstallDir, $LegacyDir))) { Out-Info "running: $($p.Kind) $($p.Script) (PID $($p.ProcessId), session $($p.SessionId))" }
# Get-WinEvent throws, also for "no events", when nothing matches
$events = @()
if ($source) { try { $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'VL Connector' } -MaxEvents 15 -ErrorAction Stop) } catch { } }
foreach ($e in $events) {
    $text = ($e.Message -replace '\s+', ' ').Trim()
    Out-Info ('event {0} {1:yyyy-MM-dd HH:mm:ss}: {2}' -f $e.Id, $e.TimeCreated, $text.Substring(0, [Math]::Min(200, $text.Length)))
}

if ($script:failures) { Write-Host "$($script:failures) check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host 'Installation checks passed' -ForegroundColor Green
exit 0
