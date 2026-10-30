<#
  Runs the launcher against FakeVL for one scenario and checks the result.

  - %APPDATA% and %LOCALAPPDATA% of the launcher (and so of FakeVL, which it starts) point to a
    per-scenario work folder, so VL's operation log and program list are fakes.
  - The product launcher (flavor en) runs from a copy laid out like an installation: <work>\install with
    app\, VERSION, install-info.txt and bin\VLConnector.Interop.dll (built once per source version into
    tests\_work\interop), so it loads the DLL like an installed copy and never compiles.
  - FakeVL runs through a renamed copy of powershell.exe (process name VLApplication4).
  - The test refuses to run while the real VL application is running: the launcher picks up any
    VLApplication4 window of the session.

  Scenario file (JSON): { "fakevl": {...}, "launcher": {...}, "machine": {...}, "user": {...},
    "prestartFakeVl": bool, "holdMutex": bool, "expect": {...}, "expectByFlavor": { "<flavor>": {...} } }
  launcher: exportImmediately, dryRun, exportOnly, mode (HighSpeed|Standard), timeoutMin, afterExport,
            returnFocus, watch, extra { <flavor>: [args] },
            confirmStageMotion (the machine policy of the copy allows VL Connector to answer stage questions),
            extraRaw (text appended to the command line as it is)
  launchFile: { program, options } passed as -LaunchFile, as the Measure button does (program default: the demo)
  machine:  written as <install>\machine.json (the machine settings file of that copy); its policy always gets
            FakeVL as vl.exe / vl.args and the FakeVL version as vl.testedVersions (unless the scenario sets it)
  user:     written as the user's settings.json
  programDataMachine: written as %ProgramData%\VLConnector\machine.json of the launcher (a fake ProgramData)
  pending:  the scenario is skipped by Run-Tests.ps1 (unless -IncludePending) until this step is done
  programFile: file name of the program in the program folder (default demo-part.vld4); programByName: pass only
            its name (without .vld4) and the folder as -ProgramDir
  cancelAfterSec, cancelOnce: the caller creates <marker>.cancel after this time (cancelOnce: only once)
  expect:   state (canonical OK|ERROR|CANCELLED|DRYRUN|BUSY|none), exitCode, stl (bool),
            eventsInclude [...], eventsExclude [...], eventsOrder [...], vlRunning (bool),
            logIncludes [...], logExcludes [...], maxSeconds, vldExists (bool),
            stageAnsweredBy (operator|launcher): who answered every stage dialog of the run (at least one),
            neverConfirmed (bool): the launcher confirmed nothing; every stage dialog shown was answered by
            the simulated operator,
            warningVisibleOnAnswer (bool): VL Connector's stage warning window was (not) on screen at every
            answer to a stage dialog, minAnswerSec: no stage dialog was answered sooner,
            vlStarts: how many FakeVL processes were started in the scenario
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
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

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
                  ExportImmediately = @('-ExportImmediately', 'On'); DryRun = @('-DryRun'); ExportOnly = @('-ExportOnly')
                  HighSpeed = @('-Mode', 'HighSpeed'); Standard = @('-Mode', 'Standard'); Ask = @('-Mode', 'Ask') }
        StateKey = 'STATE'; MessageKey = 'MESSAGE'; Mutex = 'Local\VLConnector_VLReplay'; Installed = $true
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

# A VLApplication4 process outside the test folder is the real VL; one whose path cannot be read counts as real
# too (an elevated VL). A fake VL of the previous scenario that is just ending has no path either, so look again
# for a few seconds before giving up.
function Get-RealVlProcesses {
    @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'VLApplication4.exe'" -ErrorAction SilentlyContinue |
        Where-Object { -not $_.ExecutablePath -or $_.ExecutablePath -notlike "$bin*" })
}

$real = Get-RealVlProcesses
for ($i = 0; $real.Count -and $i -lt 10; $i++) { Start-Sleep -Milliseconds 500; $real = Get-RealVlProcesses }
if ($real.Count) { throw "The real VL application is running (PID $(@($real | ForEach-Object { $_.ProcessId }) -join ', ')). Close it before running launcher tests." }
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
$program = Join-Path $programs $(if ($scenario.programFile) { [string]$scenario.programFile } else { 'demo-part.vld4' })
[IO.File]::WriteAllText($program, 'FakeVL program')
$marker = Join-Path $out 'run.marker.txt'
$events = Join-Path $work 'fakevl.events.log'
$scenarioCopy = Join-Path $work 'scenario.json'
Copy-Item -LiteralPath $ScenarioFile $scenarioCopy
if ($fl.Installed) {
    # the product launcher runs from an installation-like copy; the interface DLL is built once per source version
    . (Join-Path $repo 'app\lib\Interop.ps1')
    $dll = Join-Path $WorkRoot 'interop\VLConnector.Interop.dll'
    if (-not (Test-Path -LiteralPath $dll) -or (Get-VlcInteropDllHash $dll) -ne (Get-VlcInteropSource).Sha256) {
        New-Item -ItemType Directory -Force -Path (Split-Path $dll) | Out-Null
        $built = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'tools\Build-Interop.ps1') -OutputPath $dll
        if ($LASTEXITCODE -ne 0) { throw "Build-Interop failed: $built" }
    }
    $install = Join-Path $work 'install'
    New-Item -ItemType Directory -Force -Path (Join-Path $install 'bin') | Out-Null
    Copy-Item -LiteralPath (Split-Path $Launcher) -Destination $install -Recurse
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination $install
    Copy-Item -LiteralPath $dll -Destination (Join-Path $install 'bin')
    [IO.File]::WriteAllText((Join-Path $install 'install-info.txt'), "VERSION=test`r`nINSTALLED=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n")
    $launcherPath = Join-Path $install "app\$(Split-Path $Launcher -Leaf)"
}
else { $launcherPath = Join-Path $launcherDir 'VLReplay.ps1'; Copy-Item -LiteralPath $Launcher $launcherPath }
if ($scenario.user) {
    New-Item -ItemType Directory -Force -Path (Join-Path $appData 'VLConnector') | Out-Null
    [IO.File]::WriteAllText((Join-Path $appData 'VLConnector\settings.json'), ($scenario.user | ConvertTo-Json -Depth 10))
}
$programData = $null
if ($scenario.programDataMachine) {
    $programData = Join-Path $work 'programdata'
    New-Item -ItemType Directory -Force -Path (Join-Path $programData 'VLConnector') | Out-Null
    [IO.File]::WriteAllText((Join-Path $programData 'VLConnector\machine.json'), ($scenario.programDataMachine | ConvertTo-Json -Depth 10))
}
$fakeArgs = "-NoProfile -STA -ExecutionPolicy Bypass -File $(Join-Path $repo 'tests\FakeVL\FakeVL.ps1') -Scenario $scenarioCopy -EventLog $events"
if ($fl.Installed) {
    # machine.json of the copy: the scenario's sections, and in the policy (machine-only keys) FakeVL as the VL
    # Application of this "PC", its version as a tested one, and launcher.confirmStageMotion as the stage policy
    $machine = if ($scenario.machine) { $scenario.machine | ConvertTo-Json -Depth 10 | ConvertFrom-Json } else { [pscustomobject]@{} }
    if (-not $machine.PSObject.Properties['policy']) { $machine | Add-Member -NotePropertyName policy -NotePropertyValue ([pscustomobject]@{}) }
    if (-not $machine.policy.PSObject.Properties['vl']) { $machine.policy | Add-Member -NotePropertyName vl -NotePropertyValue ([pscustomobject]@{}) }
    $policyVl = [ordered]@{ exe = $fakeExe; args = $fakeArgs }
    if (-not $machine.policy.vl.PSObject.Properties['testedVersions']) { $policyVl['testedVersions'] = @((Get-Item -LiteralPath $fakeExe).VersionInfo.FileVersion) }
    if ($scenario.launcher -and $scenario.launcher.confirmStageMotion) { $policyVl['confirmStageMotion'] = $true }
    foreach ($k in $policyVl.Keys) { $machine.policy.vl | Add-Member -NotePropertyName $k -NotePropertyValue $policyVl[$k] -Force }
    [IO.File]::WriteAllText((Join-Path $install 'machine.json'), ($machine | ConvertTo-Json -Depth 10))
}

function New-StartInfo([string]$File, [string]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo($File, $Arguments)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['APPDATA'] = $appData
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $localData
    $psi.EnvironmentVariables['FAKEVL_PROGRAM'] = $program
    if ($programData) { $psi.EnvironmentVariables['ProgramData'] = $programData }
    return $psi
}

# FakeVL already open with scan data (export-only tests)
if ($scenario.prestartFakeVl) {
    [void][Diagnostics.Process]::Start((New-StartInfo $fakeExe $fakeArgs))
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not ((Test-Path -LiteralPath $events) -and (Get-Content -LiteralPath $events -Raw) -match 'data-loaded|start-screen:ready')) { Start-Sleep -Milliseconds 200 }
    Start-Sleep -Seconds 1
}

# another launcher already running
$holder = $null
if ($scenario.holdMutex) {
    $holderScript = "`$m = New-Object Threading.Mutex(`$false, '$($fl.Mutex)'); [void]`$m.WaitOne(); Start-Sleep -Seconds 60"
    $holder = Start-Process $psExe -ArgumentList '-NoProfile', '-Command', $holderScript -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
}

$a = $fl.Args
$opt = $scenario.launcher
$launcherArgs = New-Object Collections.Generic.List[string]
if ($scenario.launchFile) {
    # like the Measure button: the template's program and options in a UTF-16 file
    $launch = Join-Path $out 'run.launch'
    $launchProgram = if ($scenario.launchFile.program) { [string]$scenario.launchFile.program } else { $program }
    [IO.File]::WriteAllLines($launch, [string[]]@("PROGRAM=$launchProgram", "OPTIONS=$([string]$scenario.launchFile.options)"), [Text.Encoding]::Unicode)
    $launcherArgs.AddRange([string[]]@('-LaunchFile', $launch))
}
elseif ($scenario.programByName) {
    # the name only (as typed by an operator), found in the program folder
    $launcherArgs.AddRange([string[]]@([IO.Path]::GetFileName($program) -replace '\.vld4$', '', '-ProgramDir', $programs))
}
elseif (-not ($opt -and ($opt.exportOnly -or $opt.watch))) { $launcherArgs.Add($program) }
if ($opt -and $opt.watch) { $launcherArgs.Add('-Watch') }
$launcherArgs.AddRange([string[]]@($a.Out, $out, $a.Marker, $marker, $a.Timeout, '3'))
# the prototype takes FakeVL on its command line; the product only from the machine policy
if (-not $fl.Installed) { $launcherArgs.AddRange([string[]]@('-VlExe', $fakeExe)) }
if ($Flavor -eq 'en') {
    # deterministic options; the scenario overrides single ones. The stage confirmation is never forced Off
    # here: the safety scenarios check that nothing but the machine policy switches it on.
    $fixed = [ordered]@{ '-ExportImmediately' = 'Off'; '-AfterExport' = 'None'; '-ReturnFocus' = 'Off' }
    if ($opt) {
        if ($opt.exportImmediately) { $fixed['-ExportImmediately'] = 'On' }
        if ($opt.afterExport) { $fixed['-AfterExport'] = [string]$opt.afterExport }
        if ($opt.returnFocus) { $fixed['-ReturnFocus'] = 'On' }
    }
    foreach ($k in $fixed.Keys) { $launcherArgs.Add($k); $launcherArgs.Add($fixed[$k]) }
}
elseif ($opt -and $opt.exportImmediately) { $launcherArgs.AddRange([string[]]$a.ExportImmediately) }
if ($opt) {
    if ($opt.dryRun) { $launcherArgs.AddRange([string[]]$a.DryRun) }
    if ($opt.exportOnly) { $launcherArgs.AddRange([string[]]$a.ExportOnly) }
    if ($opt.mode) { $launcherArgs.AddRange([string[]]$a[[string]$opt.mode]) }
    if ($opt.extra -and $opt.extra.$Flavor) { $launcherArgs.AddRange([string[]]@($opt.extra.$Flavor)) }
}
$argLine = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $launcherPath + '" ' +
    (($launcherArgs | ForEach-Object { '"' + $_ + '"' }) -join ' ') + $(if (-not $fl.Installed) { ' -VlArgs "' + $fakeArgs + '"' })
if ($opt -and $opt.extraRaw) { $argLine += ' ' + [string]$opt.extraRaw }

$t0 = Get-Date
$proc = [Diagnostics.Process]::Start((New-StartInfo $psExe $argLine))
# a caller cancels by creating <marker>.cancel (cancelOnce: once, like a Cancel pressed while the launcher starts)
if ($scenario.cancelAfterSec) {
    $cancelAt = $t0.AddSeconds([double]$scenario.cancelAfterSec)
    $cancelled = $false
    while (-not $proc.HasExited -and (Get-Date) -lt $t0.AddSeconds($TimeoutSec)) {
        if ((Get-Date) -ge $cancelAt -and -not (Test-Path -LiteralPath "$marker.cancel") -and -not ($scenario.cancelOnce -and $cancelled)) {
            [IO.File]::WriteAllText("$marker.cancel", 'cancel'); $cancelled = $true
        }
        Start-Sleep -Milliseconds 100
    }
}
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
$logFiles = @(Get-ChildItem -LiteralPath $launcherDir, $localData -Recurse -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notlike "$work\install\*" })
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
foreach ($t in @($expect.logExcludes)) {
    if ($t -and $launcherLog -match [regex]::Escape($t)) { $failures.Add("log contains '$t'") }
}
# stage dialogs FakeVL showed, and how many of them the simulated operator answered
$count = { param($prefix) @($eventTexts | Where-Object { $_.StartsWith($prefix) }).Count }
$stageShown = (& $count 'dialog:rotate:') + (& $count 'dialog:return-origin')
$stageByOperator = (& $count 'operator:rotate-ok') + (& $count 'operator:origin-ok')
if ($expect.ContainsKey('stageAnsweredBy')) {
    if (-not $stageShown) { $failures.Add('no stage dialog was shown') }
    elseif ($expect.stageAnsweredBy -eq 'operator' -and $stageByOperator -ne $stageShown) { $failures.Add("the operator answered $stageByOperator of $stageShown stage dialogs, expected all") }
    elseif ($expect.stageAnsweredBy -eq 'launcher' -and $stageByOperator) { $failures.Add("the operator answered $stageByOperator of $stageShown stage dialogs, expected none") }
}
if ($expect.neverConfirmed) {
    if ($launcherLog -match 'Confirmed:') { $failures.Add('the launcher confirmed a VL message') }
    if ($stageByOperator -ne $stageShown) { $failures.Add("the operator answered $stageByOperator of $stageShown stage dialogs, expected all") }
}
# every answer to a stage dialog: was VL Connector's warning window on screen, how long was the question open
$answers = @($eventTexts | ForEach-Object {
    if ($_ -match '^answer:(?:rotate|return-origin):-?\d+ warning=(\d) open=([\d.]+)') {
        [pscustomobject]@{ Warning = $Matches[1] -eq '1'; Open = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture) }
    } })
if ($expect.ContainsKey('warningVisibleOnAnswer')) {
    if (-not $answers.Count) { $failures.Add('no stage dialog was answered') }
    foreach ($x in $answers) {
        if ($x.Warning -ne [bool]$expect.warningVisibleOnAnswer) { $failures.Add("a stage dialog was answered with the warning window $(if ($x.Warning) { 'visible' } else { 'not visible' })") }
    }
}
if ($expect.ContainsKey('minAnswerSec')) {
    foreach ($x in $answers) { if ($x.Open -lt [double]$expect.minAnswerSec) { $failures.Add("a stage dialog was answered after $($x.Open) s, expected at least $($expect.minAnswerSec) s") } }
}
if ($expect.ContainsKey('maxSeconds') -and $duration -gt [double]$expect.maxSeconds) { $failures.Add("took $([math]::Round($duration, 1)) s, expected at most $($expect.maxSeconds) s") }
if ($expect.ContainsKey('vlStarts')) {
    $starts = @($eventTexts | Where-Object { $_.StartsWith('start:pid=') }).Count
    if ($starts -ne [int]$expect.vlStarts) { $failures.Add("FakeVL was started $starts time(s), expected $($expect.vlStarts)") }
}
if ($expect.ContainsKey('vldExists')) {
    $vld = @(Get-ChildItem -LiteralPath $out -Filter '*.vld4' -ErrorAction SilentlyContinue).Count -gt 0
    if ($vld -ne [bool]$expect.vldExists) { $failures.Add("VL data file exists $vld, expected $($expect.vldExists)") }
}
if ($Flavor -eq 'en') {
    foreach ($f in "$marker.status", "$marker.cancel") { if (Test-Path -LiteralPath $f) { $failures.Add("run file left behind: $(Split-Path -Leaf $f)") } }
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
