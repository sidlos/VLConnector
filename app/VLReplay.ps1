<#
  VLReplay.ps1 - VL Connector for PolyWorks: runs AI Replay in the KEYENCE VL-800 "VL Application"
  from outside (the PolyWorks Measure button or the VL Connector scan window) and hands the STL over.

  Steps:
    1. finds a VL window on its start screen (AI Replay button), otherwise opens a new VL window,
    2. clicks AI Replay, chooses the mode (HighSpeed / Standard, or lets the operator choose: Ask)
       and enters the .vld4 program,
    3. the operator works as usual (places the part, presses Measure); VL's stage rotation questions are
       answered by the operator, or by VL Connector with a warning window and a sound only when the
       administrator's policy for this PC allows it (lib\StageWarning.ps1); "scanner not connected" ends
       the run,
    4. when the part is finished, exports the STL via the menu File > Export > STL... (binary, no
       thinning) and checks it,
    5. writes the marker file (STATE=OK/ERROR/CANCELLED/DRYRUN/BUSY, STL=path; see docs\Protocol.md),
    6. optionally minimizes or closes VL (closing only after the STL has been checked again) and
       brings the calling window back to the front.

  VL is driven only by Windows messages and UI Automation (no mouse or keyboard input). Nothing is
  written to KEYENCE files. Options that are not given come from the VL Connector settings.

  Usage:
    VLReplay.cmd ABC                         program ABC.vld4 (searched in the program folders and recent programs)
    VLReplay.cmd "C:\Programs\ABC.vld4" -Mode Standard
    VLReplay.cmd ABC -DryRun                 only walks through the dialogs and cancels the program selection
    VLReplay.cmd -ExportOnly                 only exports the STL from the data already open in VL
    VLReplay.cmd ABC -ExportImmediately On -AfterExport Close
    VLReplay.cmd ABC -Options "-Mode Standard -AfterExport Minimize"
                                             the same options as one text (the PolyWorks project property
                                             "VL options"); options given directly win
    VLReplay.cmd -LaunchFile <file> -MarkerFile <file> -OutputDir <folder>
                                             the Measure button: the template's "VL program" and "VL options"
                                             come in a file (PROGRAM=, OPTIONS=), never on the command line
    VLReplay.cmd -Watch -MarkerFile <file>   waits until the operator starts AI Replay in VL himself, then
                                             follows that run and exports the STL (network scenario agent)
  Which VL Application is started, its menus and whether stage questions may be confirmed come only from
  the settings (the last two only from the administrator's policy for this PC).

  Files next to the marker while the run is active: <marker>.status (current step, read by the callers)
  and <marker>.cancel (created by a caller to cancel the run).
  Exit code: 0 OK, 1 error, 2 cancelled, 3 bad parameters / program not found, 4 already running.
  Log: %LOCALAPPDATA%\VLConnector\logs\VLReplay_<date>.log
#>
using namespace VLConnector.Interop
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Program,
    [string]$Mode = '',
    [string]$OutputDir = '',
    [string]$StlFile,
    [string]$MarkerFile,
    [string]$JobId = '',
    [string[]]$ProgramDir = @(),
    [int]$TimeoutMin = 0,
    [double]$SettleSec = 0,
    [string]$ExportImmediately = '',
    [string]$AfterExport = '',
    [string]$VldFolder = '',
    [string]$ReturnFocus = '',
    [long]$ReturnFocusHwnd = 0,
    [switch]$NewWindow,
    [switch]$DryRun,
    [switch]$ExportOnly,
    [string]$Options = '',
    [string]$LaunchFile = '',
    [switch]$Watch
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'lib\LanguageCheck.ps1') -Caller VLReplay -Mode $ExecutionContext.SessionState.LanguageMode -OutFile $MarkerFile -Keys STATE, STL, PROGRAM, START, END, MESSAGE, USER, COMPUTER, JOBID, VERSION, START_UTC, STL_SHA256
    exit 1
}

$ErrorActionPreference = 'Stop'
$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_CANCELLED = 2; $EXIT_ARGS = 3; $EXIT_BUSY = 4

. (Join-Path $PSScriptRoot 'lib\Settings.ps1')
. (Join-Path $PSScriptRoot 'lib\Log.ps1')
. (Join-Path $PSScriptRoot 'lib\KeyValueFile.ps1')
. (Join-Path $PSScriptRoot 'lib\Interop.ps1')
. (Join-Path $PSScriptRoot 'lib\StageWarning.ps1')
. (Join-Path $PSScriptRoot 'lib\VlPrograms.ps1')

$logFile      = Initialize-VlcLog 'VLReplay'
$operationLog = Join-Path $env:APPDATA 'KEYENCE\VL-800 Series\VL Application\VLOperation.log'
$templateList = Join-Path $env:LOCALAPPDATA 'KEYENCE\VL-800 Series\VL Application\RecentUsedTemplateFiles.xml'
$mySession    = [Diagnostics.Process]::GetCurrentProcess().SessionId
$startTime    = Get-Date
$script:markerPath = $null
$script:statusPath = $null
$script:cancelPath = $null
$script:programPath = ''
$script:mutex = $null
$script:lastStatus = ''
$script:lastMessage = ''
$script:stageWarning = $null
$script:status = $null

# --- Helper functions -----------------------------------------------------------------

function Write-Log([string]$Text, [string]$Color = 'Gray') {
    Write-Host ('{0:HH:mm:ss.fff}  {1}' -f (Get-Date), $Text) -ForegroundColor $Color
    Write-VlcLog $Text
}

function Get-SafeName([string]$Name) {
    return ($Name.Split([IO.Path]::GetInvalidFileNameChars()) -join '_').Trim()
}

function Set-MarkerPath([string]$Path) {
    $script:markerPath = $Path
    $script:statusPath = if ($Path) { "$Path.status" } else { $null }
    $script:cancelPath = if ($Path) { "$Path.cancel" } else { $null }
}

# Marker for the caller (PolyWorks or the scan window). Line order is fixed: callers read by line number.
# STL_SHA256 (line 12) lets the evaluation detect an STL that was replaced after the export.
function Write-Marker([string]$State, [string]$StlPath, [string]$Message) {
    if (-not $script:markerPath) { return }
    $hash = ''
    if ($State -eq 'OK' -and $StlPath -and (Test-Path -LiteralPath $StlPath -PathType Leaf)) {
        try { $hash = (Get-FileHash -LiteralPath $StlPath -Algorithm SHA256).Hash.ToLower() } catch { }
    }
    $pairs = [ordered]@{
        STATE     = $State
        STL       = $StlPath
        PROGRAM   = $script:programPath
        START     = '{0:yyyy-MM-dd HH:mm:ss}' -f $startTime
        END       = '{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date)
        MESSAGE   = $Message
        USER      = $env:USERNAME
        COMPUTER  = $env:COMPUTERNAME
        JOBID     = $JobId
        VERSION   = Get-VlcVersion
        START_UTC = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        STL_SHA256 = $hash
    }
    try {
        Write-KeyValueFile $script:markerPath $pairs
        Write-Log "Marker: $script:markerPath ($State)"
    }
    catch { Write-Log "The marker could not be written: $($_.Exception.Message)" Red }
}

# Current step for the caller's progress display (<marker>.status, VLConnector.Interop.StatusFile): written at
# once when it changes and again every 5 s with a growing BEAT, so the caller sees that the launcher lives (C80).
function Write-Status([string]$Step, [string]$Text, [string]$VlMessage = '') {
    if (-not $script:statusPath) { return }
    $key = "$Step|$Text|$VlMessage"
    if ($key -eq $script:lastStatus) { return }
    $script:lastStatus = $key
    try {
        if (-not $script:status) { $script:status = New-Object VLConnector.Interop.StatusFile($script:statusPath, 5000) }
        $script:status.Set($Step, $Text, $VlMessage)
    }
    catch { Write-Log "The status file could not be written: $($_.Exception.Message)" Yellow }
}

function Remove-RunFiles {
    if ($script:status) { $script:status.Dispose(); $script:status = $null }
    foreach ($p in @($script:statusPath, $script:cancelPath)) {
        if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

function Exit-Run([int]$Code, [string]$State, [string]$Message, [string]$StlPath = '') {
    $color = if ($Code -eq $EXIT_OK) { 'Green' } elseif ($Code -eq $EXIT_CANCELLED) { 'Yellow' } else { 'Red' }
    Write-Log "$State`: $Message" $color
    Write-Marker $State $StlPath $Message
    Remove-RunFiles
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch { } }
    Stop-VlcStageWarning $script:stageWarning
    exit $Code
}

# A caller cancels the run by creating <marker>.cancel.
function Test-CancelRequested {
    if ($script:cancelPath -and (Test-Path -LiteralPath $script:cancelPath)) {
        Exit-Run $EXIT_CANCELLED 'CANCELLED' 'Cancelled by the user.'
    }
}

function Get-FileStamp([string]$Path) {
    $item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($item) { return '{0}/{1}' -f $item.LastWriteTimeUtc.Ticks, $item.Length }
    return ''
}

# Program: full path, or a name searched in the program folders of the settings, then in VL's recent programs
# (lib\VlPrograms.ps1).
function Resolve-Program([string]$Name) {
    return Resolve-VlcProgram $Name $ProgramDir (Get-VlcRecentPrograms $templateList)
}

# New complete lines in VLOperation.log.
function Read-OperationLog {
    if (-not (Test-Path -LiteralPath $operationLog)) { return @() }
    $fs = [IO.File]::Open($operationLog, 'Open', 'Read', 'ReadWrite, Delete')
    try {
        if ($fs.Length -lt $script:opOffset) { $script:opOffset = 0L; $script:opPending = '' }
        $count = [int]($fs.Length - $script:opOffset)
        if ($count -le 0) { return @() }
        [void]$fs.Seek($script:opOffset, 'Begin')
        $buffer = New-Object byte[] $count
        $read = $fs.Read($buffer, 0, $count)
        $script:opOffset += $read
        $parts = ($script:opPending + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)) -split "`r?`n"
        $script:opPending = $parts[-1]
        if ($parts.Count -gt 1) { return $parts[0..($parts.Count - 2)] | Where-Object { "$_".Trim() } }
        return @()
    }
    finally { $fs.Dispose() }
}

function Get-FinishedLength([string]$Path) {
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try { return $fs.Length } finally { $fs.Dispose() }
    }
    catch { return -1 }
}

# Binary STL: 80 byte header + triangle count + 50 bytes per triangle.
function Test-BinaryStl([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 134) { return 0 }
        $head = New-Object byte[] 84
        [void]$fs.Read($head, 0, 84)
        $n = [BitConverter]::ToUInt32($head, 80)
        if ($n -gt 0 -and (84 + 50 * [long]$n) -eq $fs.Length) { return $n }
        return 0
    }
    finally { $fs.Dispose() }
}

# --- VL window state --------------------------------------------------------------------

$script:replayButtons = @{}

# Windows of the process that have a title (dialogs, progress); menus and tooltips have none.
function Get-Tops([int]$ProcId) {
    return @([Vl]::TopWindows($ProcId) | ForEach-Object {
        $title = [Vl]::Title($_)
        if ($title) {
            [pscustomobject]@{ Handle = $_; Title = $title; Class = [Vl]::ClassOf($_); Name = [Vl]::WinFormsName($_); Enabled = [Vl]::IsWindowEnabled($_) }
        }
    })
}

function Get-VlState([int]$ProcId) {
    $tops = @(Get-Tops $ProcId)
    $main = @($tops | Where-Object { $_.Name -eq 'MeshAnalyzerForm' }) | Select-Object -First 1
    $button = [IntPtr]::Zero
    if ($main) {
        $button = $script:replayButtons[$ProcId]
        if (-not $button -or -not [Vl]::IsWindow($button)) {
            $button = [Vl]::FindChild($main.Handle, '_replayScanButton')
            $script:replayButtons[$ProcId] = $button
        }
    }
    $hasButton = ($null -ne $button) -and ($button -ne [IntPtr]::Zero)
    return [pscustomobject]@{
        Tops        = $tops
        Main        = $main
        Button      = $button
        Idle        = [bool]($main -and $tops.Count -eq 1 -and $main.Enabled -and [Vl]::IsResponsive($main.Handle))
        StartScreen = [bool]($hasButton -and [Vl]::IsWindowVisible($button))
        Signature   = (($tops | ForEach-Object { if ($_.Enabled) { $_.Title } else { "$($_.Title) [blocked]" } }) -join ' | ')
    }
}

# A VL that another run is closing right now is left alone.
function Test-VlBeingClosed([int]$ProcId) {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting("Local\VLConnector_Closing_$ProcId", [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

# VL processes of this session, newest first.
function Get-VlProcesses {
    return @(Get-Process -Name VLApplication4 -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $mySession -and -not (Test-VlBeingClosed $_.Id) } | Sort-Object StartTime -Descending)
}

# Brings a window to the front. The input of the window in front is joined (Vl.BringToFront) only while that
# window belongs to VL, PolyWorks or this launcher: an application the operator works in is never taken over,
# Windows then only flashes the taskbar button (C09).
function Set-WindowToFront([IntPtr]$Hwnd) {
    $owner = [Vl]::ProcessOf([Vl]::GetForegroundWindow())
    $attach = $owner -eq $PID
    if (-not $attach -and $owner) {
        $p = Get-Process -Id $owner -ErrorAction SilentlyContinue
        $attach = [bool]($p -and $p.SessionId -eq $mySession -and $p.ProcessName -in 'VLApplication4', 'iminspect', 'polyworks')
    }
    return [Vl]::BringToFront($Hwnd, $attach)
}

# Repeats $Condition until it returns something or the time is up. A cancel of the caller (<marker>.cancel) ends
# the run in every wait, except while VL shows an export or save dialog of this run (-NoCancel): that is finished
# first, so no dialog stays open in VL.
function Wait-Until([int]$TimeoutSec, [scriptblock]$Condition, [int]$StepMs = 250, [switch]$NoCancel) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        if (-not $NoCancel) { Test-CancelRequested }
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds $StepMs
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-NewWindow([int]$ProcId, $Before, [int]$TimeoutSec, [scriptblock]$Filter, [int]$StepMs = 250, [switch]$NoCancel) {
    return Wait-Until $TimeoutSec {
        @(Get-Tops $ProcId | Where-Object { $Before -notcontains $_.Handle } | Where-Object $Filter) | Select-Object -First 1
    } $StepMs -NoCancel:$NoCancel
}

# VL's program dialog: a file dialog titled "Open File" (the title VL gives it). Any other file dialog, such as
# the Save As of the STL export, is never taken for it.
function Test-ProgramDialog($Window) { return $Window.Class -eq '#32770' -and $Window.Title -eq 'Open File' -and [bool](Find-FileNameEdit $Window.Handle) }

# A save dialog of VL (STL export, Save As): a file dialog that is not the program dialog. Its title comes from
# Windows and depends on the Windows language.
function Test-SaveDialog($Window) { return $Window.Class -eq '#32770' -and $Window.Title -ne 'Open File' -and [bool](Find-FileNameEdit $Window.Handle) }

# "File name" box in the Open / Save As dialog: a visible Edit inside a ComboBox.
function Find-FileNameEdit([IntPtr]$Dialog) {
    return @([Vl]::Children($Dialog) | Where-Object {
        [Vl]::ClassOf($_) -eq 'Edit' -and [Vl]::IsWindowVisible($_) -and [Vl]::ClassOf([Vl]::GetParent($_)) -eq 'ComboBox' }) |
        Select-Object -First 1
}

function Find-DialogButton([IntPtr]$Dialog, [int]$Id) {
    return @([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -eq 'Button' -and [Vl]::GetDlgCtrlID($_) -eq $Id }) | Select-Object -First 1
}

# OK of a message box: id 1, or the only button (an OK-only message box gives its OK button id 2).
function Find-OkButton([IntPtr]$Dialog) {
    $ok = Find-DialogButton $Dialog 1
    if ($ok) { return $ok }
    $buttons = @([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -eq 'Button' -and [Vl]::IsWindowVisible($_) })
    if ($buttons.Count -eq 1) { return $buttons[0] }
    return $null
}

# Texts of a message box, blanks folded.
function Get-DialogText([IntPtr]$Dialog) {
    $text = (@([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -match 'Static' } |
        ForEach-Object { [Vl]::Title($_) } | Where-Object { $_ }) -join ' / ')
    return ($text -replace '\s+', ' ').Trim()
}

# Rule for a VL message box from the settings (vl.dialogRules): ScannerNotConnected or ''. No rule can confirm
# anything: only the two stage questions of lib\StageWarning.ps1 are ever confirmed, and only by the policy.
function Get-DialogRule([string]$Text) {
    foreach ($rule in @($script:dialogRules)) {
        if ($rule.match -and $Text.IndexOf([string]$rule.match, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$rule.action }
    }
    return ''
}

# --- VL window on its start screen -------------------------------------------------------

# The VL window to start AI Replay in: one of this session, idle on its start screen. VL is started only when
# none runs at all; a VL that is busy (the operator works in it, a message is open) is never joined by a second
# VL window: after waiting 15 s for it, the run ends with BUSY (C44).
function Get-StartScreenVl {
    if ($NewWindow) { Write-Log '-NewWindow is ignored: VL Connector never opens a second VL window.' Yellow }
    $idle = {
        foreach ($p in Get-VlProcesses) {
            $state = Get-VlState $p.Id
            if ($state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)) { return $p }
        }
    }
    $running = @(Get-VlProcesses)
    if ($running.Count) {
        $p = Wait-Until 15 $idle 500
        if ($p) { Write-Log "Using the open VL window (PID $($p.Id))."; return $p }
        Exit-Run $EXIT_BUSY 'BUSY' "VL is open but not idle on its start screen (PID $(($running | ForEach-Object Id) -join ', ')). Finish or close the work in VL, then start the scan again."
    }
    $exe = $script:vlExe
    if (-not (Test-Path -LiteralPath $exe)) { throw "VL is not installed: $exe" }
    Write-Log 'No idle VL window on its start screen, opening a new VL window...'
    Write-Status 'starting' 'Starting VL...'
    $p = if ($script:vlArgs) { Start-Process -FilePath $exe -ArgumentList $script:vlArgs -WorkingDirectory (Split-Path $exe) -PassThru }
         else { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -PassThru }
    $script:lastStartSig = ''
    $startDialogs = @{}
    $ready = Wait-Until 240 {
        if ($p.HasExited) { throw "VL exited right away (code $($p.ExitCode))." }
        $state = Get-VlState $p.Id
        if ($state.Signature -ne $script:lastStartSig) { $script:lastStartSig = $state.Signature; if ($state.Signature) { Write-Log "  VL windows: $($state.Signature)" DarkGray } }
        # messages of VL while it starts ("Connect the hardware") end the run at once
        Invoke-DialogRules $state $startDialogs $p
        $state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)
    } 500
    if (-not $ready) { throw 'The new VL window did not reach its start screen within 4 min (see the windows in the log).' }
    Write-Log "VL ready (PID $($p.Id))."
    return $p
}

# --- AI Replay: button -> mode -> program selection ------------------------------------------

function Start-AiReplay($Proc, [string]$ProgramPath) {
    $state = Get-VlState $Proc.Id
    [void](Set-WindowToFront $state.Main.Handle)

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($state.Button)
    $modeDialog = Wait-NewWindow $Proc.Id $before 15 { $_.Name -eq 'SelectReplayModeDialog' }
    if (-not $modeDialog) { throw 'The mode selection window did not open after clicking AI Replay.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    if ($Mode -eq 'Ask') {
        Write-Log 'Waiting for the operator to choose the replay mode in VL.'
        Write-Status 'mode' 'Choose the replay mode in VL.'
        $closed = Wait-Until 900 { -not [Vl]::IsWindow($modeDialog.Handle) -or -not [Vl]::IsWindowVisible($modeDialog.Handle) } 300
        if (-not $closed) { throw 'No replay mode was chosen within 15 min.' }
        $openDialog = Wait-NewWindow $Proc.Id $before 30 { Test-ProgramDialog $_ }
        if (-not $openDialog) { Exit-Run $EXIT_CANCELLED 'CANCELLED' 'The replay mode selection was closed in VL.' }
    }
    else {
        $buttonName = if ($Mode -eq 'HighSpeed') { '_highSpeedModeButton' } else { '_normalModeButton' }
        $modeButton = [Vl]::FindChild($modeDialog.Handle, $buttonName)
        if ($Mode -eq 'HighSpeed' -and ($modeButton -eq [IntPtr]::Zero -or -not [Vl]::IsWindowEnabled($modeButton))) {
            Write-Log 'High-speed mode is disabled in VL (GPU load limit), using Standard.' Yellow
            $modeButton = [Vl]::FindChild($modeDialog.Handle, '_normalModeButton')
        }
        if ($modeButton -eq [IntPtr]::Zero) { [Vl]::Close($modeDialog.Handle); throw 'The mode button is missing in the mode selection window.' }
        [Vl]::Click($modeButton)
        $openDialog = Wait-NewWindow $Proc.Id $before 20 { Test-ProgramDialog $_ }
        if (-not $openDialog) { throw 'The AI Replay program selection dialog did not open.' }
    }
    Write-Log "Dialog '$($openDialog.Title)', entering the program."

    $edit = Find-FileNameEdit $openDialog.Handle
    if (-not $edit) { throw 'The File name box is missing in the program selection dialog.' }
    [void][Vl]::SetText($edit, $ProgramPath)
    $typed = [Vl]::GetText($edit)
    if ($typed -ne $ProgramPath) { throw "The path could not be entered (the box contains '$typed')." }

    if ($DryRun) {
        [Vl]::Click((Find-DialogButton $openDialog.Handle 2))
        $closed = Wait-Until 10 { -not [Vl]::IsWindow($openDialog.Handle) -or -not [Vl]::IsWindowVisible($openDialog.Handle) }
        return [bool]$closed
    }

    [Vl]::Click((Find-DialogButton $openDialog.Handle 1))
    $closed = Wait-Until 15 { -not [Vl]::IsWindow($openDialog.Handle) -or -not [Vl]::IsWindowVisible($openDialog.Handle) }
    if (-not $closed) {
        $reason = (@(Get-Tops $Proc.Id | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $openDialog.Handle } |
            ForEach-Object { Get-DialogText $_.Handle }) -join ' / ')
        throw "VL did not accept the program, the dialog stayed open. $reason"
    }
    return $true
}

# --- VL message boxes during the replay -----------------------------------------------------------

# Handles the open VL message boxes: the stage questions (Confirm-StageQuestion) and the dialog rules of the
# settings, which can only end the run (scanner not connected). A text read empty right after the box appeared
# is read again on the next pass.
function Invoke-DialogRules($State, [hashtable]$Seen, $Proc) {
    foreach ($d in @($State.Tops | Where-Object { $_.Class -eq '#32770' })) {
        $h = [string]$d.Handle
        if (-not $Seen.ContainsKey($h)) { $Seen[$h] = @{ Text = ''; First = Get-Date; Tries = 0; Last = [datetime]::MinValue; Skipped = '' } }
        $info = $Seen[$h]
        if (-not $info.Text) {
            $info.Text = Get-DialogText $d.Handle
            if ($info.Text) {
                $script:lastMessage = "VL message '$($d.Title)': $($info.Text)"
                Write-Log "  $script:lastMessage" Yellow
                Write-Status 'message' 'VL shows a message.' $info.Text
            }
        }
        if (Test-VlcStageQuestion $info.Text) { Confirm-StageQuestion $d $info $Proc; continue }
        if ((Get-DialogRule $info.Text) -eq 'ScannerNotConnected') {
            $ok = Find-OkButton $d.Handle
            if ($ok) { [Vl]::Click($ok) }
            Exit-Run $EXIT_ERROR 'ERROR' "The scanner is not connected (VL: '$($info.Text)'). Check the scanner cable and power, then start again."
        }
    }
}

# A stage question of VL ("The stage will rotate. Continue?"). Answered by VL Connector only when the
# administrator's policy allows it and nothing blocks it (Get-VlcStageConfirmBlocker); then, at least 0.5 s after
# the question appeared: warning window and sound, and OK only after Windows reports the window on screen.
# Otherwise the operator answers in VL; a policy that is on but blocked is logged with the reason (log and
# Windows event log 1101). Every automatic answer goes to the log and the Windows event log (1100).
function Confirm-StageQuestion($Dialog, $Info, $Proc) {
    if ($Info.Tries -ge 3) { return }
    $now = Get-Date
    if (($now - $Info.First).TotalMilliseconds -lt 500 -or ($now - $Info.Last).TotalSeconds -lt 2) { return }
    $blocker = Get-VlcStageConfirmBlocker $Proc
    if ($blocker -eq 'off') { return }
    $ok = $null
    if (-not $blocker) {
        $ok = Find-DialogButton $Dialog.Handle 1
        if (-not $ok -or -not [Vl]::IsWindowEnabled($ok)) { $blocker = 'the OK button of the question is missing or disabled' }
    }
    if (-not $blocker -and -not ($script:stageWarning -and $script:stageWarning.Ready)) {
        # the policy was switched on during the run
        $script:stageWarning = Start-VlcStageWarning
        if (-not $script:stageWarning.Ready) { $blocker = "the warning window cannot be shown ($($script:stageWarning.Error))" }
    }
    if (-not $blocker) {
        $cfgNow = (Get-VlcSettingsState).Settings
        $text = "VL asks '$($Info.Text)' - VL Connector answers OK (set by the administrator for this PC). Program: $([IO.Path]::GetFileName($script:programPath))"
        $shown = Show-VlcStageWarning $script:stageWarning $text ([int]$cfgNow.safety.stageWarningSec) ([bool]$cfgNow.safety.stageSound) ([Vl]::Rect($Dialog.Handle))
        if (-not $shown) { $blocker = 'Windows did not show the warning window within 1 s' }
        # the question must still be the one checked above
        elseif ((Get-DialogText $Dialog.Handle) -ne $Info.Text) { $blocker = 'the question changed' }
    }
    $who = "user $env:USERDOMAIN\$env:USERNAME, PC $env:COMPUTERNAME, program $script:programPath, VL question '$($Info.Text)'"
    if ($blocker) {
        if ($Info.Skipped -ne $blocker) {
            $Info.Skipped = $blocker
            Write-Log "  Not confirmed automatically, the operator answers in VL: $blocker." Yellow
            [void](Write-VlcEventLog "VL Connector did not answer a stage question of VL itself because $blocker; the operator answers it in VL ($who)." 1101 'Warning')
        }
        $Info.Last = Get-Date
        return
    }
    [void](Set-WindowToFront $Dialog.Handle)
    Start-Sleep -Milliseconds 200
    [Vl]::Click($ok)
    $Info.Tries++; $Info.Last = Get-Date
    Write-Log "  Confirmed: $($Info.Text) (automatically, administrator's policy for this PC; warning shown)"
    [void](Write-VlcEventLog "VL Connector answered a stage question of VL with OK (administrator's policy for this PC, warning window shown; $who)." 1100)
}

# --- Waiting for the end of the part ------------------------------------------------------------

# Done: data in VL, VL started applying the program (it rewrites the program list only after the
# scan has been aligned to the program reference, i.e. after the last scan), the last position
# "AI Replay (n/n)" was seen and then the main window is idle and responsive for SettleSec. If the
# last position was not seen, 30 s of quiet after the program was applied are enough. If the
# program is not applied but VL has taken the scan over (STL Ready) and the last position ran,
# export after 120 s of quiet. With -ExportImmediately On: export as soon as the composed scan is in VL.
# Cancelled: back on the start screen and 30 s of quiet.
function Wait-ReplayFinished($Proc) {
    $templateStamp = Get-FileStamp $templateList
    $templateApplied = $false
    # the time limit counts from the start of AI Replay (not from the start of VL), in wall-clock time
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    $idleSince = $null
    $lastChange = Get-Date
    $lastSignature = $null
    $seenDialogs = @{}
    $stlReady = 0
    $finalScan = $false    # 'STL Ready' came only after the last position n/n = the composed scan is in VL
    $position = $null      # last "AI Replay (k/n)" from the title of the window before a position
    $appliedWaitLogged = $false

    while ($true) {
        Start-Sleep -Milliseconds 500
        Test-CancelRequested
        $now = Get-Date
        if ($Proc.HasExited) { return @{ Result = 'Error'; Message = "The VL window closed (PID $($Proc.Id)). $script:lastMessage".Trim() } }
        if ($now -gt $deadline) { return @{ Result = 'Error'; Message = "The part was not finished within $TimeoutMin min." } }

        # VLOperation.log: 'STL Ready' = VL has taken the scan over (after position 1 and after composing all positions).
        foreach ($line in @(Read-OperationLog)) {
            Write-Log "  VL: $($line.Trim())" DarkGray
            $lastChange = $now
            if ($line -match 'STL Ready') {
                $stlReady++
                if ($position -and $position.K -ge $position.N) {
                    $finalScan = $true
                    Write-Log 'The composed scan is in VL (STL Ready after the last position).'
                    Write-Status 'composed' 'The scan is complete, VL finishes the part.'
                }
            }
        }

        $state = Get-VlState $Proc.Id
        if ($state.Signature -ne $lastSignature) {
            $lastSignature = $state.Signature
            $lastChange = $now
            Write-Log "  VL windows: $($state.Signature)" DarkGray
        }
        Invoke-DialogRules $state $seenDialogs $Proc

        # The window before each position (ReplayForm) has "AI Replay (k/n)" in its title.
        foreach ($w in $state.Tops) {
            if (($w.Name -eq 'ReplayForm' -or $w.Title -match '^AI Replay') -and $w.Title -match '\((\d+)\s*/\s*(\d+)\)') {
                $k = [int]$Matches[1]; $n = [int]$Matches[2]
                if (-not $position -or $position.K -ne $k -or $position.N -ne $n) {
                    $position = @{ K = $k; N = $n }
                    Write-Log "AI Replay: position $k/$n"
                    Write-Status 'position' "Position $k of ${n}: place the part and press Measure in VL."
                }
            }
        }
        # Without a k/n title (other language, other VL version) there is no wait for the last position.
        $lastPosition = (-not $position) -or ($position.K -ge $position.N)

        $stamp = Get-FileStamp $templateList
        if (-not $templateApplied -and $stamp -ne $templateStamp) {
            $templateApplied = $true
            Write-Log 'VL applied the program (program list rewritten).'
            $idleSince = $null
        }

        if ($state.Idle) { if (-not $idleSince) { $idleSince = $now } } else { $idleSince = $null }
        $idleFor = if ($idleSince) { ($now - $idleSince).TotalSeconds } else { 0 }

        # Export right after the scan is composed, without waiting for the alignment to the program
        # (VL aligns for ~20 s in the background; the STL is then in scanner coordinates, not program coordinates).
        if ($ExportImmediately -eq 'On' -and $finalScan -and $state.Idle -and -not $state.StartScreen -and $idleFor -ge 1) {
            return @{ Result = 'Done'; TemplateApplied = $templateApplied; TemplateStamp = $templateStamp; Message = 'STL right after the scan (before the alignment to the program, scanner coordinates).' }
        }
        if ($state.Idle -and -not $state.StartScreen) {
            if ($templateApplied -and $idleFor -ge $SettleSec -and -not $lastPosition -and -not $appliedWaitLogged) {
                $appliedWaitLogged = $true
                Write-Log "Program applied, but the last position was not seen (last $($position.K)/$($position.N)) - waiting." Yellow
            }
            if ($templateApplied -and (($lastPosition -and $idleFor -ge $SettleSec) -or $idleFor -ge 30)) {
                if (-not $stlReady) { Write-Log 'There was no STL Ready in VLOperation.log - continuing because the program was applied.' Yellow }
                return @{ Result = 'Done'; TemplateApplied = $true; TemplateStamp = $templateStamp; Message = '' }
            }
            if (-not $templateApplied -and $stlReady -and $lastPosition -and $idleFor -ge 120 -and ($now - $lastChange).TotalSeconds -ge 120) {
                return @{ Result = 'Done'; TemplateApplied = $false; TemplateStamp = $templateStamp; Message = 'VL did not apply the program after the scan, the STL has no VL evaluation.' }
            }
        }
        if ($state.Idle -and $state.StartScreen -and $idleFor -ge 30 -and ($now - $lastChange).TotalSeconds -ge 30) {
            return @{ Result = 'Cancelled'; Message = "AI Replay was cancelled or failed, VL is back on its start screen. $script:lastMessage".Trim() }
        }
    }
}

# --- Watch mode: follow an AI Replay that the operator starts in VL ---------------------------------------

# VL's program dialog ("Open File" with a File name box) of a VL process: @{ Dialog; Edit }, $null if none.
function Find-ProgramDialog([int]$ProcId) {
    foreach ($w in @(Get-Tops $ProcId | Where-Object { Test-ProgramDialog $_ })) {
        $edit = Find-FileNameEdit $w.Handle
        if ($edit) { return @{ Dialog = $w.Handle; Edit = $edit } }
    }
    return $null
}

# Reads the File name box every 30 ms until the program dialog closes and returns the last name in it. A
# program chosen by double-click stands in the box only for a moment before the dialog closes.
function Read-ProgramDialog($Found) {
    $last = ''
    $n = 0
    while ([Vl]::IsWindow($Found.Dialog) -and [Vl]::IsWindowVisible($Found.Dialog)) {
        $t = ([string][Vl]::GetText($Found.Edit)).Trim()
        if ($t) { $last = $t }
        if ((++$n % 30) -eq 0) { Test-CancelRequested }
        Start-Sleep -Milliseconds 30
    }
    return $last
}

function Test-ReplayRunning($State) {
    return [bool]@($State.Tops | Where-Object { $_.Name -eq 'ReplayForm' -or $_.Title -match '^AI Replay\s*\(' }).Count
}

# Waits (without a time limit, until the .cancel file) until AI Replay runs in a VL window of this session.
# Remembers the program the operator chose in VL's program dialog. A replay that another VL Connector run
# started (the Measure button holds the run mutex) is left to that run.
function Wait-WatchedReplay {
    $program = ''
    $stamp = Get-FileStamp $templateList
    $modeDialogs = @{}
    Write-Status 'watching' 'Waiting for AI Replay in VL.'
    while ($true) {
        Test-CancelRequested
        $procs = @(Get-VlProcesses)
        if (-not $procs.Count) { Start-Sleep -Milliseconds 1000; continue }
        foreach ($p in $procs) {
            $state = Get-VlState $p.Id
            foreach ($d in @($state.Tops | Where-Object { $_.Name -eq 'SelectReplayModeDialog' })) {
                if (-not $modeDialogs.ContainsKey([string]$d.Handle)) {
                    $modeDialogs[[string]$d.Handle] = $true; $program = ''; $stamp = Get-FileStamp $templateList
                    Write-Log "AI Replay started in VL (PID $($p.Id)), waiting for the program."
                }
            }
            $dialog = Find-ProgramDialog $p.Id
            if ($dialog) {
                $name = Read-ProgramDialog $dialog
                if ($name -and $name -notmatch '\.vld4$') { Write-Log "Ignored in VL's program dialog (not a .vld4): $name" Yellow }
                elseif ($name -and $name -ne $program) { $program = $name; Write-Log "Program chosen in VL: $program" }
            }
            if (Test-ReplayRunning $state) {
                $mutex = New-Object System.Threading.Mutex($false, 'Local\VLConnector_VLReplay')
                $owned = $false
                try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
                if ($owned) { $script:mutex = $mutex; return @{ Proc = $p; Program = $program; TemplateStamp = $stamp } }
                $mutex.Dispose()
                Write-Log 'This AI Replay belongs to another VL Connector run (Measure button), not exported here.'
                [void](Wait-Until 86400 { Test-CancelRequested; $p.HasExited -or -not (Test-ReplayRunning (Get-VlState $p.Id)) } 1000)
                $program = ''
            }
        }
        Start-Sleep -Milliseconds 250
    }
}

# Program of a watched run: the name chosen in VL's program dialog (looked up like a program given to the
# launcher), else the data name in the VL window title (VL names the data after the .vld4), else the program
# VL applies after this scan: the newest entry of VL's list of recent programs (the last one; VL keeps the
# list oldest first), but only once VL has rewritten that list during this run (waits up to 90 s). An older entry may belong to another part, so it is never used:
# then the program stays unknown and the station reports it instead of using a wrong template.
function Resolve-WatchedProgram([string]$Seen, $Proc, [string]$StampAtStart) {
    if ($Seen) {
        try { $path = Resolve-Program $Seen; if ($path) { return $path } } catch { }
        return $Seen
    }
    $main = (Get-VlState $Proc.Id).Main
    if ($main -and $main.Title -match '^\W*(.+?)\W*\s-\sVL-800') { Write-Log "Program taken from the VL window title: $($Matches[1])" Yellow; return $Matches[1] }
    Write-Log 'The program was not seen in VL; waiting until VL applies it (list of recent programs).' Yellow
    $applied = Wait-Until 90 { (Get-FileStamp $templateList) -ne $StampAtStart } 1000
    $recent = @(Get-VlcRecentPrograms $templateList)
    if ($applied -and $recent.Count) { Write-Log "Program applied by VL in this run: $($recent[-1])" Yellow; return $recent[-1] }
    Write-Log 'The VL program of this scan is not known (VL did not apply a program within 90 s).' Yellow
    return ''
}

# --- Menu commands (File > Export > STL..., File > Save As...) -----------------------------------------

# Targeted menu search: items of the main menu bar, then the children of the expanded item (~0.07 s).
function Find-ChildMenuItem($Parent, [string]$Name, [int]$TimeoutMs = 3000) {
    $isItem = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $hit = @($Parent.FindAll('Children', $isItem) | Where-Object { ($_.Current.Name -replace '&', '' -replace '\.\.\.$', '').Trim() -eq $Name }) | Select-Object -First 1
        if ($hit) { return $hit }
        Start-Sleep -Milliseconds 30
    } while ((Get-Date) -lt $deadline)
    return $null
}

$script:menuStrips = @{}

# Opens a menu command of the idle VL main window, e.g. 'File>Export>STL'.
function Invoke-VlMenu($Proc, [string]$Path) {
    $parts = @($Path -split '>' | ForEach-Object { $_.Trim() })
    $state = Get-VlState $Proc.Id
    if (-not $state.Idle) { throw "The VL window is not idle: $($state.Signature)" }
    [void](Set-WindowToFront $state.Main.Handle)
    Start-Sleep -Milliseconds 100

    $strip = $script:menuStrips[$Proc.Id]
    if (-not $strip -or -not [Vl]::IsWindow($strip)) {
        $strip = [Vl]::FindChild($state.Main.Handle, '_mainMenuStrip')
        $script:menuStrips[$Proc.Id] = $strip
    }
    if ($strip -eq [IntPtr]::Zero) { throw 'The main menu (_mainMenuStrip) is missing in the VL window.' }

    $topItem = $null
    try {
        $parent = [System.Windows.Automation.AutomationElement]::FromHandle($strip)
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $item = Find-ChildMenuItem $parent $parts[$i]
            if (-not $item) { throw "The VL menu has no item '$($parts[$i])' (path $Path)." }
            if (-not $item.Current.IsEnabled) { throw "The menu item '$($parts[$i])' is disabled in VL." }
            if ($i -eq 0) { $topItem = $item }
            if ($i -lt $parts.Count - 1) {
                $item.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
                $parent = $item
            }
            else { [Vl]::InvokeAsync($item) }
        }
    }
    catch {
        if ($topItem) { try { $topItem.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse() } catch { } }
        throw
    }
    return $state
}

# Fills the Save As dialog with $Target and presses Save.
function Complete-SaveDialog($SaveDialog, [string]$Target) {
    $edit = Find-FileNameEdit $SaveDialog.Handle
    if (-not $edit) { [Vl]::Click((Find-DialogButton $SaveDialog.Handle 2)); throw 'The File name box is missing in the Save As dialog.' }
    [void][Vl]::SetText($edit, $Target)
    if ([Vl]::GetText($edit) -ne $Target) { [Vl]::Click((Find-DialogButton $SaveDialog.Handle 2)); throw 'The target path could not be entered.' }
    [Vl]::Click((Find-DialogButton $SaveDialog.Handle 1))
}

# Waits until both dialogs are gone, VL is idle and nobody writes $Target any more
# (VL wrote $FinishText to its operation log, or the size did not change twice in a row).
function Wait-FileSaved($Proc, $SaveDialog, [string]$Target, [string]$FinishText) {
    $script:lastLength = -2
    $script:finishSeen = $false
    $finished = Wait-Until 600 -NoCancel -Condition {
        foreach ($l in @(Read-OperationLog)) { if ($FinishText -and $l -match $FinishText) { $script:finishSeen = $true } }
        $tops = @(Get-Tops $Proc.Id)
        $other = @($tops | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $SaveDialog.Handle })
        if ($other) { throw "VL reports while saving: $((Get-DialogText $other[0].Handle))" }
        if ($Proc.HasExited) { throw 'VL closed while saving.' }
        $busy = @($tops | Where-Object { $_.Name -ne 'MeshAnalyzerForm' }).Count -gt 0
        $length = if (Test-Path -LiteralPath $Target) { Get-FinishedLength $Target } else { -1 }
        $stable = $length -gt 0 -and ($script:finishSeen -or $length -eq $script:lastLength)
        $script:lastLength = $length
        (-not $busy) -and $stable
    } 100
    if (-not $finished) { throw 'Saving did not finish within 10 min.' }
}

function Export-StlFile($Proc, [string]$Target) {
    $state = Invoke-VlMenu $Proc $script:menuExportStl
    $before = @($state.Tops | ForEach-Object { $_.Handle })
    $stlDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Name -eq 'StlExporterDialog' } 50 -NoCancel
    if (-not $stlDialog) { throw 'The STL export window did not open after selecting Export > STL.' }

    # Binary, no thinning; VL switches hole filling off by itself every time the window opens. The thinning is
    # chosen like a user's choice (with the selection notification, so VL takes it) and checked.
    $thinning = [Vl]::FindChild($stlDialog.Handle, '_thinningRatioComboBox')
    if ($thinning -ne [IntPtr]::Zero -and [Vl]::Send($thinning, 0x0147, 0) -ne 0) {
        [void][Vl]::Send($thinning, 0x014E, 0)
        [Vl]::NotifySelectionChanged($thinning)
        if ([Vl]::Send($thinning, 0x0147, 0) -ne 0) { [Vl]::Close($stlDialog.Handle); throw 'The thinning could not be set to 1:1 in the STL export window.' }
        Write-Log 'Thinning set to 1:1.'
    }
    $binary = [Vl]::FindChild($stlDialog.Handle, '_binaryRadioButton')
    if ($binary -ne [IntPtr]::Zero) { [Vl]::Click($binary); Start-Sleep -Milliseconds 50 }
    $ok = [Vl]::FindChild($stlDialog.Handle, '_okButton')
    if ($ok -eq [IntPtr]::Zero) { [Vl]::Close($stlDialog.Handle); throw 'The OK button is missing in the STL export window.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($ok)
    $saveDialog = Wait-NewWindow $Proc.Id $before 20 { Test-SaveDialog $_ } 50 -NoCancel
    if (-not $saveDialog) { [Vl]::Close($stlDialog.Handle); throw 'The Save As dialog for the STL did not open.' }
    Complete-SaveDialog $saveDialog $Target
    Write-Log "Exporting STL: $Target"
    Write-Status 'exporting' 'Exporting the STL file...'
    Wait-FileSaved $Proc $saveDialog $Target 'Finish STL Export'

    $triangles = Test-BinaryStl $Target
    if (-not $triangles) { throw "File $Target is not a valid binary STL." }
    if (-not $script:finishSeen) { Write-Log 'VL did not write Finish STL Export to VLOperation.log (the file is fine though).' Yellow }
    return $triangles
}

# Saves the open VL data as a .vld4 file (File > Save As...).
function Save-VlData($Proc, [string]$Target) {
    $state = Invoke-VlMenu $Proc $script:menuSaveAs
    $before = @($state.Tops | ForEach-Object { $_.Handle })
    $saveDialog = Wait-NewWindow $Proc.Id $before 20 { Test-SaveDialog $_ } 50 -NoCancel
    if (-not $saveDialog) { throw 'The Save As dialog for the VL data did not open.' }
    Complete-SaveDialog $saveDialog $Target
    Write-Log "Saving VL data: $Target"
    Wait-FileSaved $Proc $saveDialog $Target ''
}

# --- After the export ------------------------------------------------------------------------

# Brings the caller's window to the front: the given window handle, otherwise the nearest parent
# process with a window that is not a console (PolyWorks|Inspector when started by the Measure button).
function Set-CallerToFront {
    try {
        if ($ReturnFocusHwnd -ne 0) {
            $h = [IntPtr]$ReturnFocusHwnd
            if ([Vl]::IsWindow($h)) {
                if (Set-WindowToFront $h) { Write-Log 'The calling window is in front.' }
                else { Write-Log 'The calling window was not brought to the front: another application is in front.' }
            }
            return
        }
        $consoles = 'cmd', 'powershell', 'pwsh', 'conhost', 'OpenConsole', 'WindowsTerminal'
        $id = $PID
        for ($i = 0; $i -lt 8; $i++) {
            $me = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
            if (-not $me) { return }
            $id = [int]$me.ParentProcessId
            $parent = Get-Process -Id $id -ErrorAction SilentlyContinue
            if (-not $parent) { return }
            if ($consoles -notcontains $parent.ProcessName -and $parent.MainWindowHandle -ne [IntPtr]::Zero) {
                if (Set-WindowToFront $parent.MainWindowHandle) { Write-Log "$($parent.ProcessName) (PID $id) is in front." }
                else { Write-Log "$($parent.ProcessName) (PID $id) was not brought to the front: another application is in front." }
                return
            }
        }
    }
    catch { Write-Log "Bringing the caller to the front failed: $($_.Exception.Message)" Yellow }
}

# Waits until VL has finished its own work on the part (program applied, or idle for 60 s).
function Wait-VlReadyToClose($Proc, $Finish) {
    $deadline = (Get-Date).AddSeconds($script:closeWaitSec)
    $idleSince = $null
    while ((Get-Date) -lt $deadline) {
        if ($Proc.HasExited) { return $true }
        $applied = $Finish.TemplateApplied -or ((Get-FileStamp $templateList) -ne $Finish.TemplateStamp)
        $state = Get-VlState $Proc.Id
        if ($state.Idle) { if (-not $idleSince) { $idleSince = Get-Date } } else { $idleSince = $null }
        $idleFor = if ($idleSince) { ((Get-Date) - $idleSince).TotalSeconds } else { 0 }
        if (($applied -and $idleFor -ge [math]::Max($SettleSec, 1)) -or $idleFor -ge 60) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Closes VL; its question whether to save is answered No (the data is either saved already or not wanted), and
# only that question: any other message stops the closing and VL stays open. Never kills VL.
function Close-Vl($Proc) {
    $state = Get-VlState $Proc.Id
    if (-not $state.Main) { return $Proc.HasExited }
    [Vl]::Close($state.Main.Handle)
    $script:closeAnswered = $false
    $closed = Wait-Until 60 -NoCancel -Condition {
        if ($Proc.HasExited) { return $true }
        foreach ($d in @(Get-Tops $Proc.Id | Where-Object { $_.Class -eq '#32770' })) {
            $text = Get-DialogText $d.Handle
            if (-not $text) { continue }
            $no = Find-DialogButton $d.Handle 7
            if (-not ($no -and $text -match '\bsave\b')) { throw "VL shows a message while closing: $text" }
            if (-not $script:closeAnswered) {
                Write-Log "  VL asks: $text - answering No."
                [Vl]::Click($no); $script:closeAnswered = $true
            }
        }
        $false
    } 300
    return [bool]$closed
}

# Minimizes or closes VL after the marker was written. Discarding the scan data happens only after the
# STL has been checked again (same triangle count, still a valid binary STL).
function Invoke-AfterExport($Proc, [string]$Target, $Triangles, $Finish) {
    if ($AfterExport -eq 'Minimize') {
        $main = (Get-VlState $Proc.Id).Main
        if ($main) { [Vl]::Minimize($main.Handle); Write-Log 'VL minimized.' }
    }
    if ($ReturnFocus -eq 'On') { Set-CallerToFront }
    if ($AfterExport -notin 'Close', 'SaveAndClose') { return }

    $closing = New-Object System.Threading.Mutex($false, "Local\VLConnector_Closing_$($Proc.Id)")
    try {
        if (-not (Wait-VlReadyToClose $Proc $Finish)) { Write-Log 'VL did not finish its work on the part in time, it stays open.' Yellow; return }
        if ($Proc.HasExited) { return }
        if ($AfterExport -eq 'SaveAndClose') {
            $folder = if ($VldFolder) { $VldFolder } else { Split-Path $Target }
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            $vld = Join-Path $folder ([IO.Path]::GetFileNameWithoutExtension($Target) + '.vld4')
            try { Save-VlData $Proc $vld }
            catch { Write-Log "VL data could not be saved, VL stays open: $($_.Exception.Message)" Yellow; return }
            if ($ReturnFocus -eq 'On') { Set-CallerToFront }
        }
        $check = Test-BinaryStl $Target
        if ($check -ne $Triangles) {
            Write-Log "The STL check before closing failed ($Target has $check triangles, expected $Triangles). VL stays open with the scan." Yellow
            return
        }
        if (Close-Vl $Proc) { Write-Log 'VL closed.' } else { Write-Log 'VL did not close within 60 s, it stays open.' Yellow }
    }
    catch { Write-Log "Closing VL: $($_.Exception.Message) - VL stays open." Yellow }
    finally { $closing.Dispose() }
}

# Without thousands separators and with a decimal point, so the marker is the same on every PC.
function Format-StlInfo([string]$Path, $Triangles) {
    $mb = (Get-Item -LiteralPath $Path).Length / 1MB
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'STL {0:0.0} MB, {1} triangles.', $mb, $Triangles)
}

function Get-TargetPath([string]$RunName) {
    if ($StlFile) { return [IO.Path]::GetFullPath($StlFile) }
    $base = Join-Path $OutputDir $RunName
    $target = "$base.stl"
    $n = 2
    while (Test-Path -LiteralPath $target) { $target = "${base}_$n.stl"; $n++ }
    return $target
}

# --- Settings and checks -------------------------------------------------------------------------

if ($MarkerFile) { Set-MarkerPath $MarkerFile }
try { Import-VlcInterop }
catch { Exit-Run $EXIT_ERROR 'ERROR' $_.Exception.Message }
# -LaunchFile: the template's "VL program" and "VL options", written by the Measure button macro as PROGRAM= and
# OPTIONS= lines. Template values never reach the command line, where a quote in a property could add launcher
# parameters (C25).
if ($LaunchFile) {
    try { $launch = Read-KeyValueFile $LaunchFile } catch { Exit-Run $EXIT_ARGS 'ERROR' "The launch file cannot be read: $($_.Exception.Message)" }
    if ($null -eq $launch) { Exit-Run $EXIT_ARGS 'ERROR' "The launch file $LaunchFile is missing." }
    if (-not $Program) { $Program = [string]$launch['PROGRAM'] }
    if (-not $Options) { $Options = [string]$launch['OPTIONS'] }
}
# -Options: a few options as one text, e.g. "-Mode Standard -AfterExport Minimize" from the PolyWorks
# project property "VL options". Only these names are accepted; options given directly win.
if ($Options) {
    $valueOptions = 'Mode', 'ExportImmediately', 'AfterExport', 'ReturnFocus', 'TimeoutMin', 'SettleSec'
    $tokens = @($Options.Trim() -split '\s+' | Where-Object { $_ })
    try {
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -notmatch '^-([A-Za-z]+)$') { throw "'$($tokens[$i])' is not an option" }
            if ($Matches[1] -eq 'ConfirmStageMotion') { throw '-ConfirmStageMotion is not a template option any more: whether VL Connector may answer the stage questions of VL is set by the administrator for all users of this PC (settings window, page Scanning)' }
            $name = @($valueOptions + 'NewWindow' | Where-Object { $_ -eq $Matches[1] })[0]
            if (-not $name) { throw "unknown option $($tokens[$i]) (allowed: -$($valueOptions -join ', -'), -NewWindow)" }
            if ($name -eq 'NewWindow') {
                if (-not $PSBoundParameters.ContainsKey('NewWindow')) { $NewWindow = [switch]$true }
                continue
            }
            if ($i + 1 -ge $tokens.Count) { throw "-$name needs a value" }
            $i++
            if ($PSBoundParameters.ContainsKey($name)) { continue }
            switch ($name) {
                'TimeoutMin' { $TimeoutMin = [int]::Parse($tokens[$i], [Globalization.CultureInfo]::InvariantCulture) }
                'SettleSec' { $SettleSec = [double]::Parse($tokens[$i], [Globalization.CultureInfo]::InvariantCulture) }
                default { Set-Variable -Name $name -Value $tokens[$i] }
            }
        }
    }
    catch { Exit-Run $EXIT_ARGS 'ERROR' "VL options '$Options': $($_.Exception.Message -replace '^Exception calling .*?: ', '')." }
}
try {
    $settingsState = Get-VlcSettingsState
    $cfg = $settingsState.Settings
    foreach ($w in $settingsState.Warnings) { Write-Log "Settings: $w" Yellow }
    if (-not $Mode) { $Mode = [string]$cfg.vl.mode }
    if (-not $OutputDir) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VL Connector\Scans' }
    $OutputDir = [IO.Path]::GetFullPath($OutputDir)
    # only the program folders of the settings are searched (and VL's recent programs), never all of Documents
    if (-not $ProgramDir) { $ProgramDir = @($cfg.vl.programFolders | Where-Object { $_ }) }
    if ($TimeoutMin -le 0) { $TimeoutMin = [int]$cfg.vl.timeoutMin }
    if ($SettleSec -le 0) { $SettleSec = [double]$cfg.vl.settleSec }
    if (-not $ExportImmediately) { $ExportImmediately = if ($cfg.vl.exportImmediately) { 'On' } else { 'Off' } }
    if (-not $AfterExport) { $AfterExport = [string]$cfg.vl.afterExport }
    if (-not $VldFolder) { $VldFolder = [string]$cfg.vl.vldFolder }
    if (-not $ReturnFocus) { $ReturnFocus = if ($cfg.vl.returnFocus) { 'On' } else { 'Off' } }
    # machine-only settings: VL Application, its menus, the stage questions (read again for every question)
    $script:vlExe = [string]$cfg.vl.exe
    $script:vlArgs = [string]$cfg.vl.args
    $script:menuExportStl = [string]$cfg.vl.menuExportStl
    $script:menuSaveAs = [string]$cfg.vl.menuSaveAs
    $script:closeWaitSec = [int]$cfg.vl.closeWaitSec
    $script:dialogRules = @($cfg.vl.dialogRules)
    $script:testedVersions = @($cfg.vl.testedVersions)
    # in watch mode nobody waits for the STL in front of a window: the operator stays in VL, and VL is closed
    # under the operator's hands only when the administrator allows it
    if ($Watch) {
        $ReturnFocus = 'Off'
        if ($AfterExport -in 'Close', 'SaveAndClose' -and -not $cfg.safety.watchAllowClose) {
            Write-Log "After export '$AfterExport' is not used while the agent follows the scans (the administrator has not allowed it): VL stays open." Yellow
            $AfterExport = 'None'
        }
    }
}
catch { Exit-Run $EXIT_ARGS 'ERROR' "Settings: $($_.Exception.Message)" }
$checks = @(
    @('Mode', $Mode, @('HighSpeed', 'Standard', 'Ask')),
    @('ExportImmediately', $ExportImmediately, @('On', 'Off')),
    @('AfterExport', $AfterExport, @('None', 'Minimize', 'Close', 'SaveAndClose')),
    @('ReturnFocus', $ReturnFocus, @('On', 'Off')))
foreach ($c in $checks) {
    if ($c[2] -notcontains $c[1]) { Exit-Run $EXIT_ARGS 'ERROR' "-$($c[0]) '$($c[1])' is not valid (use $($c[2] -join ', '))." }
}
if ($TimeoutMin -lt 1 -or $TimeoutMin -gt 600) { Exit-Run $EXIT_ARGS 'ERROR' "-TimeoutMin $TimeoutMin is not valid (1 to 600 minutes)." }
if ($SettleSec -lt 0 -or $SettleSec -gt 60) { Exit-Run $EXIT_ARGS 'ERROR' "-SettleSec $SettleSec is not valid (0 to 60 seconds)." }
# first sign of life for the caller; from now on the status file gets a beat every 5 s
Write-Status 'started' 'VL Connector is starting.'

# --- Start -----------------------------------------------------------------------------

if (-not $Watch) {
    $script:mutex = New-Object System.Threading.Mutex($false, 'Local\VLConnector_VLReplay')
    try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        $script:mutex = $null
        Exit-Run $EXIT_BUSY 'BUSY' 'Another scan is running on this PC. Finish it in VL first.'
    }
}

$Host.UI.RawUI.WindowTitle = 'VL Connector - AI Replay'
$what = if ($ExportOnly) { "export only $Program".Trim() } elseif ($Watch) { 'watching for AI Replay' } else { $Program }
$flags = @($(if ($DryRun) { 'DRY RUN' }), $(if ($NewWindow) { 'new window' })) | Where-Object { $_ }
$stagePolicy = if ($cfg.vl.confirmStageMotion) { 'by VL Connector (administrator)' } else { 'by the operator' }
Write-Log ("=== VLReplay $(Get-VlcVersion) $what | account $env:USERNAME | mode $Mode | export immediately $ExportImmediately | stage questions $stagePolicy | after export $AfterExport " + ($flags -join ' | ')).Trim() Cyan
if (Test-Path -LiteralPath $script:vlExe) {
    $vlVersion = (Get-Item -LiteralPath $script:vlExe).VersionInfo.FileVersion
    if ($vlVersion -and $script:testedVersions -and $script:testedVersions -notcontains $vlVersion) {
        Write-Log "VL version $vlVersion has not been tested with VL Connector (tested: $($script:testedVersions -join ', '))." Yellow
    }
}
# the warning window is prepared now, so that it appears at once when a stage question comes
if ($cfg.vl.confirmStageMotion) {
    $script:stageWarning = Start-VlcStageWarning
    if (-not $script:stageWarning.Ready) { Write-Log "The stage warning window cannot be prepared ($($script:stageWarning.Error)); the operator answers the stage questions in VL." Yellow }
}
# a .cancel next to the marker is never deleted here: a Cancel pressed while VL Connector starts must count
# (the Measure button removes an old one before it starts the run)

$runName = ''
if (-not $ExportOnly -and -not $Watch) {
    if (-not $Program) { Exit-Run $EXIT_ARGS 'ERROR' 'Give the program: VLReplay.cmd <program or path to the .vld4>' }
    $runName = '{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName (Get-VlcProgramName $Program)), $startTime
    # A dry run writes a marker (STATE=DRYRUN) only with -MarkerFile, so that calls from PolyWorks can be tested.
    if (-not $DryRun -and -not $MarkerFile) { Set-MarkerPath (Join-Path $OutputDir "$runName.done") }
    try {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        if ($script:markerPath -and (Test-Path -LiteralPath $script:markerPath)) { Remove-Item -LiteralPath $script:markerPath -Force }
        $script:programPath = Resolve-Program $Program
    }
    catch { Exit-Run $EXIT_ARGS 'ERROR' $_.Exception.Message }
    if (-not $script:programPath) {
        $where = if ($ProgramDir) { "the program folders ($($ProgramDir -join ', ')) and VL's recently used programs" } else { "VL's recently used programs (no program folder is set)" }
        Exit-Run $EXIT_ARGS 'ERROR' "Program '$Program' not found in $where."
    }
    Write-Log "Program: $script:programPath"
}

try {
    $script:opOffset = 0L; $script:opPending = ''
    if (Test-Path -LiteralPath $operationLog) { $script:opOffset = (Get-Item -LiteralPath $operationLog).Length }

    if ($ExportOnly) {
        $proc = $null
        foreach ($p in Get-VlProcesses) {
            $s = Get-VlState $p.Id
            if ($s.Idle -and -not $s.StartScreen -and $s.Main) { $proc = $p; $state = $s; break }
        }
        if (-not $proc) { throw 'No idle VL window with open data.' }
        $dataName = if ($state.Main.Title -match '^\W*(.+?)\W*\s-\sVL-800') { $Matches[1] } else { 'VL' }
        $name = if ($Program) { Get-VlcProgramName $Program } else { $dataName }
        $runName = '{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName $name), $startTime
        if (-not $script:markerPath) { Set-MarkerPath (Join-Path $OutputDir "$runName.done") }
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        if (Test-Path -LiteralPath $script:markerPath) { Remove-Item -LiteralPath $script:markerPath -Force }
        Write-Log "Export from VL window PID $($proc.Id): $($state.Main.Title)"
        $target = Get-TargetPath $runName
        $triangles = Export-StlFile $proc $target
        $finish = @{ TemplateApplied = $true; TemplateStamp = (Get-FileStamp $templateList) }
        Write-Marker 'OK' $target (Format-StlInfo $target $triangles)
        Remove-RunFiles
        $script:mutex.ReleaseMutex(); $script:mutex = $null
        # the STL is delivered: a problem from here on is logged, never written over the OK marker (C45)
        try { Invoke-AfterExport $proc $target $triangles $finish } catch { Write-Log "After the export: $($_.Exception.Message)" Yellow }
        Write-Log 'Done.' Green
        Stop-VlcStageWarning $script:stageWarning
        exit $EXIT_OK
    }

    if ($Watch) {
        if (-not $script:markerPath) { Exit-Run $EXIT_ARGS 'ERROR' 'Watch mode needs -MarkerFile.' }
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        $watched = Wait-WatchedReplay
        $proc = $watched.Proc
        $startTime = Get-Date
        $script:opOffset = 0L; $script:opPending = ''
        if (Test-Path -LiteralPath $operationLog) { $script:opOffset = (Get-Item -LiteralPath $operationLog).Length }
        $script:watchedProgram = $watched.Program
        $script:watchedStamp = $watched.TemplateStamp
        Write-Log "AI Replay is running in VL (PID $($proc.Id))." Green
    }
    else {
        Write-Status 'starting' 'Opening VL...'
        $proc = Get-StartScreenVl
        $started = Start-AiReplay $proc $script:programPath
        if ($DryRun) {
            if ($started) {
                $dryRunText = 'AI Replay -> mode -> program entered -> Cancel. VL is back on its start screen.'
                if ($script:markerPath) { Exit-Run $EXIT_OK 'DRYRUN' $dryRunText }
                Write-Log "DRY RUN: $dryRunText" Green; $script:mutex.ReleaseMutex(); Stop-VlcStageWarning $script:stageWarning; exit $EXIT_OK
            }
            throw 'DRY RUN: the program selection dialog did not close.'
        }
        Write-Log 'AI Replay is running - the operator continues in VL as usual.' Green
    }
    Write-Status 'replay' 'AI Replay is running. Follow the steps in VL.'

    $finish = Wait-ReplayFinished $proc
    switch ($finish.Result) {
        'Cancelled' { Exit-Run $EXIT_CANCELLED 'CANCELLED' $finish.Message }
        'Error'     { Exit-Run $EXIT_ERROR 'ERROR' $finish.Message }
    }
    if ($finish.Message) { Write-Log $finish.Message Yellow }
    if ($Watch) {
        # the STL is named after the .vld4 program (+ date and time); the PolyWorks station finds the template by it
        $script:programPath = Resolve-WatchedProgram $script:watchedProgram $proc $script:watchedStamp
        $programName = if ($script:programPath) { Get-VlcProgramName $script:programPath } else { 'VL' }
        $runName = '{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName $programName), $startTime
        Write-Log "Program: $script:programPath"
    }

    $triangles = $null
    for ($attempt = 1; $attempt -le 2 -and -not $triangles; $attempt++) {
        # every attempt gets a name of its own: a file left by a failed attempt would make VL ask to overwrite it
        $target = Get-TargetPath $runName
        try { $triangles = Export-StlFile $proc $target }
        catch {
            Write-Log "STL export (attempt $attempt): $($_.Exception.Message)" Yellow
            if ($attempt -eq 2) { throw }
            Start-Sleep -Seconds 3
            [void](Wait-Until 60 { (Get-VlState $proc.Id).Idle } 500)
        }
    }
    $message = ((Format-StlInfo $target $triangles) + ' ' + $finish.Message).Trim()
    Write-Marker 'OK' $target $message
    Remove-RunFiles
    $script:mutex.ReleaseMutex(); $script:mutex = $null
    # the STL is delivered: a problem from here on is logged, never written over the OK marker (C45)
    try { Invoke-AfterExport $proc $target $triangles $finish } catch { Write-Log "After the export: $($_.Exception.Message)" Yellow }
    Write-Log 'Done.' Green
    Stop-VlcStageWarning $script:stageWarning
    exit $EXIT_OK
}
catch {
    Exit-Run $EXIT_ERROR 'ERROR' $_.Exception.Message
}
