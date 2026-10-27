<#
  Runs the launcher against FakeVL for one scenario and checks the result.

  - %APPDATA% and %LOCALAPPDATA% of the launcher (and so of FakeVL, which it starts) point to a
    per-scenario work folder, so VL's operation log and program list are fakes.
  - FakeVL runs through a renamed copy of powershell.exe (process name VLApplication4).
  - The test refuses to run while the real VL application is running: the launcher picks up any
    VLApplication4 window of the session.

  Scenario file (JSON): { "fakevl": {...}, "launcher": {...}, "prestartFakeVl": bool,
    "holdMutex": bool, "expect": {...}, "expectByFlavor": { "<flavor>": {...} } }
  launcher: exportImmediately, dryRun, exportOnly, mode (HighSpeed|Standard), timeoutMin
  expect:   state (canonical OK|ERROR|CANCELLED|DRYRUN|BUSY|none), exitCode, stl (bool),
            eventsInclude [...], eventsOrder [...], vlRunning (bool)
#>
param(
    [Parameter(Mandatory = $true)][string]$ScenarioFile,
    [ValidateSet('proto', 'en')][string]$Flavor = 'en',
    [string]$Launcher = '',
    [string]$WorkRoot = '',
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
if (-not $Launcher) { $Launcher = Join-Path $repo 'app\VLReplay.ps1' }
if (-not $WorkRoot) { $WorkRoot = Join-Path $repo 'tests\_work' }

# Parameter names and marker keys of each launcher version.
$flavors = @{
    proto = @{
        Args = @{ Out = '-Vystup'; Marker = '-Znacka'; Timeout = '-CasovacMin'
                  ExportImmediately = @('-HnedPoSkenu'); DryRun = @('-Nanecisto'); ExportOnly = @('-JenExport')
                  HighSpeed = @('-Rezim', 'Rychly'); Standard = @('-Rezim', 'Standard') }
        StateKey = 'STAV'; MessageKey = 'ZPRAVA'; Mutex = 'Local\VL_replay'
        States = @{ OK = 'OK'; CHYBA = 'ERROR'; ZRUSENO = 'CANCELLED'; NANECISTO = 'DRYRUN' }
    }
    en = @{
        Args = @{ Out = '-OutputDir'; Marker = '-MarkerFile'; Timeout = '-TimeoutMin'
                  ExportImmediately = @('-ExportImmediately'); DryRun = @('-DryRun'); ExportOnly = @('-ExportOnly')
                  HighSpeed = @('-Mode', 'HighSpeed'); Standard = @('-Mode', 'Standard') }
        StateKey = 'STATE'; MessageKey = 'MESSAGE'; Mutex = 'Local\VL_replay'
        States = @{ OK = 'OK'; ERROR = 'ERROR'; CANCELLED = 'CANCELLED'; DRYRUN = 'DRYRUN'; BUSY = 'BUSY' }
    }
}
$fl = $flavors[$Flavor]

$scenario = Get-Content -LiteralPath $ScenarioFile -Raw | ConvertFrom-Json
$name = [IO.Path]::GetFileNameWithoutExtension($ScenarioFile)
$work = Join-Path $WorkRoot "$Flavor\$name"
$bin = Join-Path $WorkRoot 'bin'
$fakeExe = Join-Path $bin 'VLApplication4.exe'

function Get-FakeVlProcesses {
    @(Get-Process VLApplication4 -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$bin*" })
}

$real = @(Get-Process VLApplication4 -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -notlike "$bin*" })
if ($real) { throw "The real VL application is running (PID $($real.Id -join ', ')). Close it before running launcher tests." }
Get-FakeVlProcesses | Stop-Process -Force
Start-Sleep -Milliseconds 300

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
$appData = Join-Path $work 'appdata'; $localData = Join-Path $work 'localappdata'
$out = Join-Path $work 'out'; $programs = Join-Path $work 'programs'; $launcherDir = Join-Path $work 'launcher'
New-Item -ItemType Directory -Force -Path $appData, $localData, $out, $programs, $launcherDir, $bin | Out-Null
if (-not (Test-Path -LiteralPath $fakeExe)) {
    Copy-Item (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') $fakeExe
}
# Like VL (targets .NET 4.8): current WinForms accessibility, which exposes the menu items to UI Automation.
$fakeConfig = @'
<configuration>
  <startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.8" /></startup>
  <runtime>
    <AppContextSwitchOverrides value="Switch.UseLegacyAccessibilityFeatures=false;Switch.UseLegacyAccessibilityFeatures.2=false;Switch.UseLegacyAccessibilityFeatures.3=false;Switch.UseLegacyAccessibilityFeatures.4=false" />
  </runtime>
</configuration>
'@
[IO.File]::WriteAllText("$fakeExe.config", $fakeConfig)
$program = Join-Path $programs 'demo-part.vld4'
[IO.File]::WriteAllText($program, 'FakeVL program')
$marker = Join-Path $out 'run.marker.txt'
$events = Join-Path $work 'fakevl.events.log'
$scenarioCopy = Join-Path $work 'scenario.json'
Copy-Item -LiteralPath $ScenarioFile $scenarioCopy
Copy-Item -LiteralPath $Launcher (Join-Path $launcherDir 'VLReplay.ps1')
$fakeArgs = "-NoProfile -STA -ExecutionPolicy Bypass -File $(Join-Path $repo 'tests\FakeVL\FakeVL.ps1') -Scenario $scenarioCopy -EventLog $events"

function New-StartInfo([string]$File, [string]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo($File, $Arguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['APPDATA'] = $appData
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $localData
    return $psi
}

# FakeVL already open with scan data (export-only tests)
if ($scenario.prestartFakeVl) {
    [void][Diagnostics.Process]::Start((New-StartInfo $fakeExe $fakeArgs))
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path -LiteralPath $events) -and (Get-Content -LiteralPath $events -Raw) -match 'data-loaded')) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Seconds 1
}

# another launcher already running
$holder = $null
if ($scenario.holdMutex) {
    $holderScript = "`$m = New-Object Threading.Mutex(`$false, '$($fl.Mutex)'); [void]`$m.WaitOne(); Start-Sleep -Seconds 60"
    $holder = Start-Process powershell.exe -ArgumentList '-NoProfile', '-Command', $holderScript -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

$a = $fl.Args
$launcherArgs = New-Object Collections.Generic.List[string]
if (-not ($scenario.launcher -and $scenario.launcher.exportOnly)) { $launcherArgs.Add($program) }
$launcherArgs.AddRange([string[]]@($a.Out, $out, $a.Marker, $marker, $a.Timeout, '3', '-VlExe', $fakeExe))
$opt = $scenario.launcher
if ($opt) {
    if ($opt.exportImmediately) { $launcherArgs.AddRange([string[]]$a.ExportImmediately) }
    if ($opt.dryRun) { $launcherArgs.AddRange([string[]]$a.DryRun) }
    if ($opt.exportOnly) { $launcherArgs.AddRange([string[]]$a.ExportOnly) }
    if ($opt.mode) { $launcherArgs.AddRange([string[]]$a[[string]$opt.mode]) }
    if ($opt.extra -and $opt.extra.$Flavor) { $launcherArgs.AddRange([string[]]@($opt.extra.$Flavor)) }
}
$argLine = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + (Join-Path $launcherDir 'VLReplay.ps1') + '" ' +
    (($launcherArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ') + ' -VlArgs "' + $fakeArgs + '"'

$t0 = Get-Date
$proc = [Diagnostics.Process]::Start((New-StartInfo 'powershell.exe' $argLine))
$finished = $proc.WaitForExit($TimeoutSec * 1000)
$duration = ((Get-Date) - $t0).TotalSeconds
if (-not $finished) { $proc.Kill() }
$exitCode = if ($finished) { $proc.ExitCode } else { -1 }
if ($holder -and -not $holder.HasExited) { $holder.Kill() }

Start-Sleep -Milliseconds 500
$vlRunning = (Get-FakeVlProcesses).Count -gt 0
Get-FakeVlProcesses | Stop-Process -Force

# --- Collect ---------------------------------------------------------------------------------
$markerData = @{}
if (Test-Path -LiteralPath $marker) {
    foreach ($line in [IO.File]::ReadAllLines($marker)) {
        $i = $line.IndexOf('='); if ($i -gt 0) { $markerData[$line.Substring(0, $i)] = $line.Substring($i + 1) }
    }
}
$rawState = $markerData[$fl.StateKey]
$state = if ($null -eq $rawState) { 'none' } elseif ($fl.States.ContainsKey($rawState)) { $fl.States[$rawState] } else { "?$rawState" }
$stlPath = $markerData['STL']
$stlOk = $false; $triangles = 0; $stlHash = ''
if ($stlPath -and (Test-Path -LiteralPath $stlPath)) {
    $len = (Get-Item -LiteralPath $stlPath).Length
    $bytes = [IO.File]::ReadAllBytes($stlPath)
    if ($len -ge 134) { $triangles = [BitConverter]::ToUInt32($bytes, 80); $stlOk = (84 + 50 * [long]$triangles) -eq $len }
    $stlHash = (Get-FileHash -LiteralPath $stlPath -Algorithm SHA256).Hash
}
$eventLines = if (Test-Path -LiteralPath $events) { @(Get-Content -LiteralPath $events) } else { @() }
$eventTexts = @($eventLines | ForEach-Object { if ($_.Length -gt 13) { $_.Substring(13) } else { $_ } })
$logFiles = @(Get-ChildItem -LiteralPath $launcherDir, $localData -Recurse -Filter '*.log' -ErrorAction SilentlyContinue)
$launcherLog = ($logFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName }) -join "`n"

# --- Check -----------------------------------------------------------------------------------
$expect = @{}
if ($scenario.expect) { foreach ($p in $scenario.expect.PSObject.Properties) { $expect[$p.Name] = $p.Value } }
if ($scenario.expectByFlavor -and $scenario.expectByFlavor.$Flavor) {
    foreach ($p in $scenario.expectByFlavor.$Flavor.PSObject.Properties) { $expect[$p.Name] = $p.Value }
}
$failures = New-Object Collections.Generic.List[string]
if ($expect.ContainsKey('state') -and $state -ne $expect.state) { $failures.Add("state $state, expected $($expect.state)") }
if ($expect.ContainsKey('exitCode') -and $exitCode -ne [int]$expect.exitCode) { $failures.Add("exit code $exitCode, expected $($expect.exitCode)") }
if ($expect.ContainsKey('stl') -and [bool]$expect.stl -ne $stlOk) { $failures.Add("valid STL $stlOk, expected $($expect.stl)") }
if ($expect.ContainsKey('vlRunning') -and [bool]$expect.vlRunning -ne $vlRunning) { $failures.Add("VL running $vlRunning, expected $($expect.vlRunning)") }
foreach ($e in @($expect.eventsInclude)) {
    if ($e -and -not ($eventTexts | Where-Object { $_.StartsWith($e) })) { $failures.Add("missing event '$e'") }
}
foreach ($e in @($expect.eventsExclude)) {
    if ($e -and ($eventTexts | Where-Object { $_.StartsWith($e) })) { $failures.Add("unexpected event '$e'") }
}
$last = -1
foreach ($e in @($expect.eventsOrder)) {
    if (-not $e) { continue }
    $idx = -1
    for ($i = 0; $i -lt $eventTexts.Count; $i++) { if ($eventTexts[$i].StartsWith($e)) { $idx = $i; break } }
    if ($idx -lt 0) { $failures.Add("order: missing '$e'"); continue }
    if ($idx -lt $last) { $failures.Add("order: '$e' too early") }
    $last = $idx
}
foreach ($t in @($expect.logIncludes)) {
    if ($t -and $launcherLog -notmatch [regex]::Escape($t)) { $failures.Add("log lacks '$t'") }
}

$result = [pscustomobject]@{
    Scenario  = $name
    Flavor    = $Flavor
    Passed    = $failures.Count -eq 0
    Failures  = @($failures)
    State     = $state
    ExitCode  = $exitCode
    StlValid  = $stlOk
    Triangles = $triangles
    StlHash   = $stlHash
    VlRunning = $vlRunning
    Seconds   = [math]::Round($duration, 1)
    Message   = $markerData[$fl.MessageKey]
    Events    = $eventTexts
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work 'result.json') -Encoding UTF8
return $result
