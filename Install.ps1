<#
  Install.ps1 - VL Connector for PolyWorks: installs this package on this PC. Start it with Install.cmd.
  No administrator rights are needed.
    Install.cmd                       install or update (folder C:\ProgramData\VLConnector)
    Install.cmd -InstallDir D:\VLC    another folder
    Install.cmd -AllUsers             Start menu entries for all users (needs administrator rights)
    Install.cmd -Verify               checks an installed copy against its manifest and shows the status
    Install.cmd -Quiet                no questions (for IT deployment)

  What it does - nothing else is changed on the PC:
    1. checks every file of the package against MANIFEST.sha256 and shows the package fingerprint
       (compare it with the fingerprint you received with the package),
    2. copies app\, docs\, the license and the uninstaller to the install folder (an older app\ is
       replaced, the layouts\ folder of earlier versions is removed; machine settings are kept),
       removes the "downloaded from the internet" mark from these files and compiles the Windows and
       PolyWorks interfaces (app\interop\*.cs) once into bin\VLConnector.Interop.dll,
    3. limits write access to the install folder to administrators, SYSTEM and the installing user
       (all users may only read and run it),
    4. creates the PolyWorks button files (Measure, Station),
    5. creates the Start menu entries VL Connector (settings), VL Connector agent (network scenario) and
       Uninstall VL Connector. The agent starts with Windows only when you switch it on in the settings.
#>
param(
    [string]$InstallDir = (Join-Path $env:ProgramData 'VLConnector'),
    [switch]$AllUsers,
    [switch]$Verify,
    [switch]$Quiet
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything else runs
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'app\lib\LanguageCheck.ps1') -Caller Install -Mode $ExecutionContext.SessionState.LanguageMode
    if (-not $Quiet) { $null = Read-Host 'Press Enter to close' }
    exit 1
}

$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

# Compares the files of a folder with its MANIFEST.sha256 ("<sha256>  <relative/path>" per line).
function Test-Manifest([string]$Root) {
    $manifest = Join-Path $Root 'MANIFEST.sha256'
    if (-not (Test-Path -LiteralPath $manifest)) { return [pscustomobject]@{ Ok = $false; Problems = @('MANIFEST.sha256 is missing.'); Fingerprint = '' } }
    $problems = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($manifest)) {
        if ($line -notmatch '^([0-9a-f]{64})  (.+)$') { continue }
        $file = Join-Path $Root ($Matches[2] -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file)) { $problems.Add("missing: $($Matches[2])"); continue }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLower() -ne $Matches[1]) { $problems.Add("changed: $($Matches[2])") }
    }
    return [pscustomobject]@{
        Ok = ($problems.Count -eq 0); Problems = $problems.ToArray()
        Fingerprint = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash.ToLower()
    }
}

function Wait-Key {
    if (-not $Quiet) { [void](Read-Host 'Press Enter to close') }
}

$version = if (Test-Path -LiteralPath (Join-Path $source 'VERSION')) { ([IO.File]::ReadAllText((Join-Path $source 'VERSION'))).Trim() } else { '?' }
Say "VL Connector for PolyWorks $version" Cyan
Say 'Unofficial tool - not an official KEYENCE or InnovMetric product.'
Say ''

if ($Verify) {
    $check = Test-Manifest $InstallDir
    if ($check.Ok) { Say "All installed files match the manifest ($InstallDir)." Green }
    else { Say "Installed files differ from the manifest:" Yellow; $check.Problems | ForEach-Object { Say "  $_" Yellow } }
    Say "Package fingerprint: $($check.Fingerprint)"
    foreach ($lib in 'Settings', 'PolyWorksSetup', 'Share', 'Prerequisites') { . (Join-Path $InstallDir "app\lib\$lib.ps1") }
    Say ''
    foreach ($item in Get-VlcStatusItems (Read-VlcSettings)) {
        $color = @{ Ok = 'Green'; Warning = 'Yellow'; Error = 'Red' }[$item.Level]
        Say ("{0,-8} {1} - {2}" -f $item.Level, $item.Title, $item.Detail) $color
    }
    Wait-Key
    exit $(if ($check.Ok) { 0 } else { 1 })
}

# 1) package check
Say '1/5  Checking the package...'
$check = Test-Manifest $source
if (-not $check.Ok) {
    Say 'The package is incomplete or was changed after it was built:' Red
    $check.Problems | Select-Object -First 20 | ForEach-Object { Say "  $_" Red }
    Say 'Download the package again. Nothing was installed.' Red
    Wait-Key; exit 1
}
Say "     All files OK. Package fingerprint: $($check.Fingerprint)" Green
Say '     Compare this fingerprint with the one you received with the package.'
if (-not $Quiet) {
    $answer = Read-Host "     Install to $InstallDir ? [Y/n]"
    if ($answer -and $answer -notmatch '^[YyAa]') { Say 'Cancelled. Nothing was installed.'; exit 2 }
}

# 2) copy (a running agent of this user is stopped first and started again at the end)
Say "2/5  Copying to $InstallDir ..."
$agentWasRunning = $false
$stopAgent = $null
if ([System.Threading.EventWaitHandle]::TryOpenExisting('Local\VLConnector_AgentStop', [ref]$stopAgent)) {
    [void]$stopAgent.Set(); $stopAgent.Dispose(); $agentWasRunning = $true; Start-Sleep -Seconds 3
    Say '     The running agent was stopped for the update.'
}
try {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    # layouts\ held the report layouts that versions before 1.0.0-rc10 built from PolyWorks
    foreach ($old in 'app', 'docs', 'tools', 'layouts', 'bin') {
        $path = Join-Path $InstallDir $old
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    foreach ($item in 'app', 'docs', 'LICENSE', 'README.md', 'CHANGELOG.md', 'VERSION', 'MANIFEST.sha256', 'Install.cmd', 'Install.ps1', 'Uninstall.cmd', 'Uninstall.ps1', 'tools') {
        $from = Join-Path $source $item
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination $InstallDir -Recurse -Force }
    }
    Get-ChildItem -LiteralPath $InstallDir -Recurse -File | Unblock-File
    # the Windows and PolyWorks interfaces are compiled once, here: VL Connector itself never compiles
    $built = & { $ErrorActionPreference = 'Continue'; & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallDir 'tools\Build-Interop.ps1') -OutputPath (Join-Path $InstallDir 'bin\VLConnector.Interop.dll') 2>&1 }
    if ($LASTEXITCODE -ne 0) { throw "The Windows and PolyWorks interfaces could not be compiled: $($built | Out-String)" }
    Say "     Interfaces compiled (source SHA-256 $(@($built)[-1]))." Green
}
catch {
    Say "Installing the files failed: $($_.Exception.Message)" Red
    Say 'If VL Connector was installed by another Windows user, ask that user or an administrator to update it.' Red
    Wait-Key; exit 1
}

# 3) permissions: everybody may read and run, only administrators, SYSTEM and the installing user may change
Say '3/5  Setting folder permissions...'
$me = '*' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$acl = & icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${me}:(OI)(CI)M" '*S-1-5-32-545:(OI)(CI)RX' 2>&1
if ($LASTEXITCODE -ne 0) { Say "     Could not set all permissions: $($acl | Out-String)" Yellow } else { Say '     Done.' Green }

# 4) PolyWorks: button files
Say '4/5  Preparing PolyWorks...'
$app = Join-Path $InstallDir 'app'
foreach ($lib in 'Settings', 'PolyWorksSetup') { . (Join-Path $app "lib\$lib.ps1") }
$stub = New-VlcButtonStub -Kind Measure
Say "     Measure button file: $stub" Green
$stub = New-VlcButtonStub -Kind Station
Say "     Station button file: $stub" Green
$pw = Get-PolyWorksInfo
if ($pw) { Say "     $($pw.Name) found." Green }
else { Say '     PolyWorks is not installed on this PC (fine for a scanner PC in the network scenario).' }

# 5) Start menu
Say '5/5  Creating Start menu entries...'
$menuRoot = if ($AllUsers) { [Environment]::GetFolderPath('CommonPrograms') } else { [Environment]::GetFolderPath('Programs') }
$menu = Join-Path $menuRoot 'VL Connector'
New-Item -ItemType Directory -Force -Path $menu | Out-Null
$shell = New-Object -ComObject WScript.Shell
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$icon = Join-Path $app 'assets\VLC_icon.ico'
$entries = [ordered]@{
    'VL Connector'           = @{ Args = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$app\VLConnector.ps1`""; Description = 'VL Connector for PolyWorks - settings' }
    'VL Connector agent'     = @{ Args = "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File `"$app\Agent.ps1`""; Description = 'VL Connector agent - exports the STL after AI Replay and opens the reports (network scenario, scanner PC)' }
}
foreach ($name in $entries.Keys) {
    $lnk = $shell.CreateShortcut((Join-Path $menu "$name.lnk"))
    $lnk.TargetPath = $ps
    $lnk.Arguments = $entries[$name].Args
    $lnk.WorkingDirectory = $app
    $lnk.IconLocation = "$icon,0"
    $lnk.Description = $entries[$name].Description
    $lnk.WindowStyle = 7
    $lnk.Save()
}
$lnk = $shell.CreateShortcut((Join-Path $menu 'Uninstall VL Connector.lnk'))
$lnk.TargetPath = Join-Path $InstallDir 'Uninstall.cmd'
$lnk.WorkingDirectory = $InstallDir
$lnk.IconLocation = "$icon,0"
$lnk.Description = 'Removes VL Connector for PolyWorks from this PC'
$lnk.Save()
Say "     $menu" Green

if ($agentWasRunning) { Start-Process -FilePath $ps -ArgumentList $entries['VL Connector agent'].Args -WindowStyle Hidden; Say '     Agent started again.' Green }
[IO.File]::WriteAllText((Join-Path $InstallDir 'install-info.txt'), ("VERSION={0}`r`nINSTALLED={1:yyyy-MM-dd HH:mm:ss}`r`nUSER={2}`r`nCOMPUTER={3}`r`nFINGERPRINT={4}`r`n" -f $version, (Get-Date), $env:USERNAME, $env:COMPUTERNAME, $check.Fingerprint))
Say ''
Say "VL Connector $version is installed." Green
Say 'Next: the setup wizard (also later: Start menu > VL Connector > Setup wizard).'
if (-not $Quiet) {
    $answer = Read-Host 'Open the setup wizard now? [Y/n]'
    if (-not $answer -or $answer -match '^[YyAa]') { Start-Process -FilePath $ps -ArgumentList ($entries['VL Connector'].Args + ' -Show Wizard') -WindowStyle Hidden }
}
exit 0
