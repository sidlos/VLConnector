# The stage safety of VL Connector (docs\IT-Review). Only when the administrator's policy for this PC allows it,
# VL Connector answers VL's stage rotation questions itself; before every such answer a warning window (on top of
# all windows, never taking the keyboard focus) and a sound appear, and OK is pressed only after Windows reports
# the window on screen. Nobody must be away from the PC for it: the PC must be unlocked and used at its own
# screen, not over Remote Desktop. Dot-source this file; it needs lib\Settings.ps1 and lib\Interop.ps1 (after
# Import-VlcInterop).

$script:StageWarningWindowScript = Join-Path $PSScriptRoot 'StageWarningWindow.ps1'

# VL's questions that may be confirmed, exactly (blanks folded): nothing else is ever confirmed automatically.
$script:StageQuestions = @('The stage will rotate. Continue?', 'Return the stage to the origin?')

function Test-VlcStageQuestion([string]$Text) {
    foreach ($q in $script:StageQuestions) { if ([string]::Equals($Text, $q, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

# Starts the warning window in its own STA thread, hidden until it is needed. Ready is $false (reason in Error)
# when it could not be started; VL Connector then leaves every stage question to the operator.
function Start-VlcStageWarning {
    $sync = [hashtable]::Synchronized(@{ Ready = $false; Error = ''; Hwnd = [IntPtr]::Zero; Request = $null; Shown = 0; HideAt = $null; Quit = $false })
    $runspace = [RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddCommand($script:StageWarningWindowScript).AddParameter('Sync', $sync)
    $async = $ps.BeginInvoke()
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $sync.Ready -and -not $sync.Error -and -not $async.IsCompleted -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if (-not $sync.Ready -and -not $sync.Error) {
        $sync.Error = if ($ps.Streams.Error.Count) { $ps.Streams.Error[0].ToString() } else { 'it did not start within 15 s' }
    }
    return [pscustomobject]@{ Sync = $sync; PowerShell = $ps; Runspace = $runspace; Async = $async; Ready = [bool]$sync.Ready; Error = [string]$sync.Error; Next = 0 }
}

# Shows the warning for $Seconds, with the sound when $Sound, away from VL's question ($Avoid: its window
# rectangle). Returns $true once Windows reports the window visible, $false when that does not happen within 1 s.
function Show-VlcStageWarning($Warning, [string]$Text, [int]$Seconds, [bool]$Sound, [int[]]$Avoid = @()) {
    if (-not $Warning -or -not $Warning.Ready -or $Warning.Async.IsCompleted) { return $false }
    $Warning.Next = $Warning.Next + 1
    $id = $Warning.Next
    $Warning.Sync.Request = @{ Id = $id; Text = $Text; Seconds = $Seconds; Sound = $Sound; Avoid = $Avoid }
    $deadline = (Get-Date).AddSeconds(1)
    do {
        if ($Warning.Sync.Shown -eq $id -and [VLConnector.Interop.Vl]::IsWindowVisible($Warning.Sync.Hwnd)) { return $true }
        Start-Sleep -Milliseconds 20
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Stop-VlcStageWarning($Warning) {
    if (-not $Warning) { return }
    $Warning.Sync.Quit = $true
    try { [void]$Warning.Async.AsyncWaitHandle.WaitOne(2000) } catch { }
    try { $Warning.PowerShell.Dispose(); $Warning.Runspace.Dispose() } catch { }
}

# Why VL Connector must not answer a stage question of VL ($Proc: the VL process) itself now; '' = it may, 'off'
# = the administrator's policy does not allow it (the normal case). The policy is read again for every question,
# so switching it off applies at once; VL must be a tested version (the questions depend on the VL build), and
# somebody must be at this PC (Get-VlcSessionBlocker).
function Get-VlcStageConfirmBlocker($Proc) {
    $cfgNow = (Get-VlcSettingsState).Settings
    if (-not $cfgNow.vl.confirmStageMotion) { return 'off' }
    $version = ''
    try { $version = [string]$Proc.MainModule.FileVersionInfo.FileVersion } catch { }
    if (-not $version -or @($cfgNow.vl.testedVersions) -notcontains $version) { return "VL version '$version' is not one of the tested versions" }
    return Get-VlcSessionBlocker
}

# Why nobody at this PC can watch the scanner from this session ('' when somebody can): the PC is locked (or a
# secure screen saver runs), this is a Remote Desktop session, or it is not the session at the PC's own screen.
function Get-VlcSessionBlocker {
    if (-not [VLConnector.Interop.Vl]::InputDesktopActive()) { return 'the PC is locked' }
    if ([VLConnector.Interop.Vl]::IsRemoteSession()) { return 'this is a Remote Desktop session' }
    if ([VLConnector.Interop.Vl]::SessionOf($PID) -ne [VLConnector.Interop.Vl]::ActiveConsoleSession()) { return "this is not the session at the PC's own screen" }
    return ''
}
