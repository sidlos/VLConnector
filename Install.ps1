<#
  Install.ps1 - VL Connector for PolyWorks: installs this package on this PC. Start it with Install.cmd.
    Install.cmd                          install or update in C:\Program Files\VLConnector; Windows asks for
                                         administrator rights
    Install.cmd -InstallDir D:\VLC       another folder (empty, or holding VL Connector)
    Install.cmd -ConfirmStageMotion On   machine policy: VL Connector answers VL's stage rotation questions
                                         itself, with a warning window and a sound (Off: the operator does)
    Install.cmd -MachineSettings f.json  settings for all users of this PC, like machine.json:
                                         { "policy": { ... }, "defaults": { ... } }
    Install.cmd -InteropDll f.dll        an interface DLL that IT built and signed with tools\Build-Interop.ps1
                                         of this package (checked by its source hash)
    Install.cmd -Force                   also an older version over a newer one
    Install.cmd -Quiet                   no questions, for software deployment: run it as administrator or as
                                         SYSTEM. Exit codes: 0 done, 1 failed, 740 administrator rights needed,
                                         1618 VL Connector is in use (retry later)
    Install.cmd -Verify                  checks an installed copy: its files against its manifest, its
                                         permissions, then the status of this PC (no administrator rights)

  What it changes - nothing else:
    1. the program folder, which only administrators can change (the previous version stays in <folder>.old),
    2. the Start menu entries for all users and the event source "VL Connector" in the Application log,
    3. an installation of 1.0.0-rc10 in C:\ProgramData\VLConnector: removed, except files that forward old
       PolyWorks buttons and shortcuts to the new folder,
    4. for the Windows user who runs it (not when started as administrator or SYSTEM): the agent's start with
       Windows and the settings file; other users get the same when they start VL Connector.
#>
param(
    [string]$InstallDir = (Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'VLConnector'),
    [switch]$Verify,
    [switch]$Quiet,
    [switch]$Force,
    [ValidateSet('', 'On', 'Off')] [string]$ConfirmStageMotion = '',
    [string]$MachineSettings = '',
    [string]$InteropDll = '',
    # used by the installer itself: the part that runs with administrator rights, from a local copy
    [switch]$MachinePart,
    [string]$ResultFile = '',
    [string]$RequestedBy = ''
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything else runs
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'app\lib\LanguageCheck.ps1') -Caller Install -Mode $ExecutionContext.SessionState.LanguageMode
    if (-not $Quiet -and -not $MachinePart) { $null = Read-Host 'Press Enter to close' }
    exit 1
}

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'app\lib\Install.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Every line goes to the console and, in the administrator part, to the result file the user part shows.
function Say([string]$Text, [string]$Color = 'Gray') {
    if ($ResultFile) { [IO.File]::AppendAllText($ResultFile, "$Color|$Text`r`n", (New-Object Text.UTF8Encoding($false))) }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Wait-Key { if (-not $Quiet -and -not $MachinePart) { [void](Read-Host 'Press Enter to close') } }

function Confirm-Step([string]$Question) {
    if ($Quiet) { return $true }
    $answer = Read-Host $Question
    return (-not $answer -or $answer -match '^[YyAa]')
}

$version = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'VERSION')) { ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'VERSION'))).Trim() } else { '?' }

# --- administrator part (started by the user part below, elevated, from a local copy of the package) ---------
if ($MachinePart) {
    $code = 1
    try { $code = (Install-VlcMachine -Source $PSScriptRoot -Target $InstallDir -Force:$Force -ConfirmStageMotion $ConfirmStageMotion -MachineSettings $MachineSettings -InteropDll $InteropDll -RequestedBy $RequestedBy -Say ${function:Say}).ExitCode }
    catch { Say "Installation failed: $($_.Exception.Message)" 'Red' }
    Say "$code" 'EXIT'
    exit $code
}

Say "VL Connector for PolyWorks $version" 'Cyan'
Say 'Unofficial tool - not an official KEYENCE or InnovMetric product.'
Say ''

# --- check of an installed copy ------------------------------------------------------------------------------
if ($Verify) {
    $ok = $true
    try {
        $manifest = Read-VlcManifest $InstallDir
        $check = Test-VlcPackageTree $InstallDir $manifest $script:VlcGeneratedFiles -Strict
    }
    catch { Say "$($_.Exception.Message) $InstallDir is not a complete VL Connector installation." 'Red'; Wait-Key; exit 1 }
    if ($check.Ok) { Say "All installed files match the manifest ($InstallDir)." 'Green' }
    else { $ok = $false; Say 'Installed files differ from the manifest:' 'Yellow'; foreach ($p in @($check.Problems | Select-Object -First 20)) { Say "  $p" 'Yellow' } }
    Say "Package fingerprint: $($manifest.Fingerprint)"
    $acl = @(Get-VlcAclProblems $InstallDir -Recurse) + @(Get-VlcAclProblems $InstallDir -Parents)
    if ($acl.Count) { $ok = $false; Say 'Users other than the administrators can change the program folder:' 'Yellow'; foreach ($p in @($acl | Select-Object -First 10)) { Say "  $p" 'Yellow' } }
    else { Say 'Only administrators can change the program folder.' 'Green' }
    if (-not $check.Ok) {
        # nothing of an installed copy that differs from its package is loaded
        Say 'The installed scripts are not loaded. Repair VL Connector: an administrator runs Install.cmd of the package again.' 'Yellow'
        Wait-Key; exit 1
    }
    . (Join-Path $InstallDir 'app\lib\Interop.ps1')
    $dllHash = if (Test-Path -LiteralPath (Get-VlcInteropDllPath)) { Get-VlcInteropDllHash (Get-VlcInteropDllPath) } else { '' }
    if ($dllHash -and $dllHash -eq (Get-VlcInteropSource).Sha256) { Say "Interface DLL belongs to the installed scripts (source SHA-256 $dllHash)." 'Green' }
    else { $ok = $false; Say 'The interface DLL is missing or does not belong to the installed scripts. Repair VL Connector.' 'Yellow' }
    foreach ($lib in 'Settings', 'PolyWorksSetup', 'Share', 'Prerequisites') { . (Join-Path $InstallDir "app\lib\$lib.ps1") }
    Say ''
    $state = Get-VlcSettingsState
    foreach ($item in Get-VlcStatusItems $state.Settings $state.Warnings) {
        $color = @{ Ok = 'Green'; Warning = 'Yellow'; Error = 'Red' }[$item.Level]
        Say ("{0,-8} {1} - {2}" -f $item.Level, $item.Title, $item.Detail) $color
    }
    Wait-Key
    exit $(if ($ok) { 0 } else { 1 })
}

$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# --- started as administrator or SYSTEM (software deployment): the machine part only ------------------------
if (Test-VlcAdministrator) {
    if (-not (Confirm-Step "Install to $InstallDir ? [Y/n]")) { Say 'Cancelled. Nothing was installed.'; exit 2 }
    $code = 1
    try { $code = (Install-VlcMachine -Source $PSScriptRoot -Target $InstallDir -Force:$Force -ConfirmStageMotion $ConfirmStageMotion -MachineSettings $MachineSettings -InteropDll $InteropDll -RequestedBy $me -Say ${function:Say}).ExitCode }
    catch { Say "Installation failed: $($_.Exception.Message)" 'Red' }
    if ($code -eq 0) {
        Say ''
        Say "VL Connector $version is installed. Each Windows user's shortcuts and settings are brought up to date when they start VL Connector." 'Green'
    }
    Wait-Key
    exit $code
}

# --- started by a user: the machine part runs elevated (Windows asks), then this user's part ----------------
if ($Quiet) { Say 'Administrator rights are needed: run Install.cmd -Quiet as administrator or as SYSTEM.' 'Red'; exit 740 }
Say '1/3  Checking the package...'
try {
    $manifest = Read-VlcManifest $PSScriptRoot
    $check = Test-VlcPackageTree $PSScriptRoot $manifest
}
catch { Say "$($_.Exception.Message) Download the package again. Nothing was installed." 'Red'; Wait-Key; exit 1 }
if (-not $check.Ok) {
    Say 'The package is incomplete or was changed after it was built:' 'Red'
    foreach ($p in @($check.Problems | Select-Object -First 20)) { Say "  $p" 'Red' }
    Say 'Download the package again. Nothing was installed.' 'Red'
    Wait-Key; exit 1
}
Say "     All files OK. Package fingerprint: $($manifest.Fingerprint)" 'Green'
Say '     Compare this fingerprint with the one published with the package.'
if (-not (Confirm-Step "     Install to $InstallDir ? Windows asks for administrator rights next. [Y/n]")) { Say 'Cancelled. Nothing was installed.'; exit 2 }

$agentWasRunning = $false
$m = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\VLConnector_Agent', [ref]$m)) { $m.Dispose(); $agentWasRunning = $true }

# the administrator part runs from a local copy: an elevated process does not see a mapped network drive
$temp = Join-Path ([IO.Path]::GetTempPath()) ('VLConnector-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$result = Join-Path $temp 'result.txt'
$code = 1
try {
    [void][IO.Directory]::CreateDirectory($temp)
    $copy = Join-Path $temp 'package'
    Copy-VlcPackage $PSScriptRoot $copy $manifest
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$copy\Install.ps1`"", '-MachinePart',
        '-InstallDir', "`"$InstallDir`"", '-ResultFile', "`"$result`"", '-RequestedBy', "`"$me`"")
    if ($Force) { $argList += '-Force' }
    if ($ConfirmStageMotion) { $argList += '-ConfirmStageMotion', $ConfirmStageMotion }
    if ($MachineSettings) { [IO.File]::Copy($MachineSettings, "$temp\machine-settings.json"); $argList += '-MachineSettings', "`"$temp\machine-settings.json`"" }
    if ($InteropDll) { [IO.File]::Copy($InteropDll, "$temp\VLConnector.Interop.dll"); $argList += '-InteropDll', "`"$temp\VLConnector.Interop.dll`"" }
    Say '2/3  Installing with administrator rights (confirm the Windows prompt)...'
    $p = $null
    try { $p = Start-Process -FilePath $ps -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru }
    catch { Say 'Administrator rights were not given. Nothing was installed.' 'Yellow'; Wait-Key; exit 2 }
    [void]$p.Handle
    $p.WaitForExit()
    $code = $p.ExitCode
    if (Test-Path -LiteralPath $result) {
        foreach ($line in [IO.File]::ReadAllLines($result)) {
            $parts = $line -split '\|', 2
            if ($parts[0] -eq 'EXIT') { if ($null -eq $code) { $code = [int]$parts[1] }; continue }
            Write-Host $parts[1] -ForegroundColor $parts[0]
        }
    }
    elseif ($code -ne 0) { Write-Host 'The administrator part stopped without a message. Run Install.cmd in a command prompt opened as administrator to see why.' -ForegroundColor Red }
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
if ($code -ne 0) { Wait-Key; exit $code }

Say '3/3  Shortcuts and settings of this Windows user...'
try {
    foreach ($lib in 'Settings', 'AgentControl') { . (Join-Path $InstallDir "app\lib\$lib.ps1") }
    foreach ($c in @(Repair-VlcUserShortcuts)) { Say "     Brought up to date: $c" }
    $removed = @(Repair-VlcUserSettings)
    if ($removed.Count) { Say "     Settings cleaned up: $($removed -join ', ')" }
    if ($agentWasRunning) { Start-VlcAgent; Say '     Agent started again.' 'Green' }
}
catch { Say "     Not everything could be brought up to date: $($_.Exception.Message) (done again when you start VL Connector)" 'Yellow' }
Say ''
Say "VL Connector $version is installed in $InstallDir." 'Green'
Say 'Next: the setup wizard (also later: Start menu > VL Connector).'
if (Confirm-Step 'Open the setup wizard now? [Y/n]') {
    Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-WindowStyle', 'Hidden', '-File', "`"$(Join-Path $InstallDir 'app\VLConnector.ps1')`"", '-Show', 'Wizard' -WindowStyle Hidden
}
exit 0
