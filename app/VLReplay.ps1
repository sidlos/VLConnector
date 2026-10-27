<#
  VLReplay.ps1 - VL Connector for PolyWorks: runs AI Replay in the KEYENCE VL-800 "VL Application"
  from outside (the PolyWorks Measure button or the VL Connector scan window) and hands the STL over.

  Steps:
    1. finds a VL window on its start screen (AI Replay button), otherwise opens a new VL window,
    2. clicks AI Replay, chooses the mode (HighSpeed / Standard, or lets the operator choose: Ask)
       and enters the .vld4 program,
    3. the operator works as usual (places the part, presses Measure); VL messages can be answered
       automatically (stage movement) or end the run (scanner not connected),
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

  Files next to the marker while the run is active: <marker>.status (current step, read by the callers)
  and <marker>.cancel (created by a caller to cancel the run).
  Exit code: 0 OK, 1 error, 2 cancelled, 3 bad parameters / program not found, 4 already running.
  Log: %LOCALAPPDATA%\VLConnector\logs\VLReplay_<date>.log
#>
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
    [string]$ConfirmStageMotion = '',
    [string]$AfterExport = '',
    [string]$VldFolder = '',
    [string]$ReturnFocus = '',
    [long]$ReturnFocusHwnd = 0,
    [switch]$NewWindow,
    [switch]$DryRun,
    [switch]$ExportOnly,
    [string]$Menu = '',
    [string]$VlExe = '',
    [string]$VlArgs
)

$ErrorActionPreference = 'Stop'
$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_CANCELLED = 2; $EXIT_ARGS = 3; $EXIT_BUSY = 4

. (Join-Path $PSScriptRoot 'lib\Settings.ps1')
. (Join-Path $PSScriptRoot 'lib\Log.ps1')
. (Join-Path $PSScriptRoot 'lib\KeyValueFile.ps1')
. (Join-Path $PSScriptRoot 'lib\Native.ps1')

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
function Write-Marker([string]$State, [string]$StlPath, [string]$Message) {
    if (-not $script:markerPath) { return }
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
    }
    try {
        Write-KeyValueFile $script:markerPath $pairs
        Write-Log "Marker: $script:markerPath ($State)"
    }
    catch { Write-Log "The marker could not be written: $($_.Exception.Message)" Red }
}

# Current step for the caller's progress display; written only when it changes.
function Write-Status([string]$Step, [string]$Text, [string]$VlMessage = '') {
    if (-not $script:statusPath) { return }
    $key = "$Step|$Text|$VlMessage"
    if ($key -eq $script:lastStatus) { return }
    $script:lastStatus = $key
    try { Write-KeyValueFile $script:statusPath ([ordered]@{ STEP = $Step; TEXT = $Text; VLMESSAGE = $VlMessage; UPDATED = '{0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date) }) }
    catch { }
}

function Remove-RunFiles {
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

# Program paths from the VL list of recently used programs.
function Get-RecentTemplatePaths {
    try {
        $fs = [IO.File]::Open($templateList, 'Open', 'Read', 'ReadWrite, Delete')
        try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() }
        finally { $fs.Dispose() }
    }
    catch { return @() }
    return @([regex]::Matches($text, 'i:type="b:string"[^>]*>([^<]+)</a:Value>') |
        ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } |
        Where-Object { $_ -match '^([A-Za-z]:\\|\\\\)' })
}

# Program: full path, or a name searched in the recently used programs and in the program folders.
function Resolve-Program([string]$Name) {
    foreach ($candidate in @($Name, "$Name.vld4")) {
        if ([IO.Path]::IsPathRooted($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    if ($Name -match '[\\/]') {
        $full = [IO.Path]::GetFullPath($Name)
        if (Test-Path -LiteralPath $full -PathType Leaf) { return $full }
        return $null
    }
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $recent = @(Get-RecentTemplatePaths | Where-Object {
        [IO.Path]::GetFileNameWithoutExtension($_) -eq $base -and $_ -match '\.vld4$' -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
        Select-Object -Unique)
    if ($recent.Count -eq 1) { return $recent[0] }
    $found = @(@(foreach ($dir in $ProgramDir) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Get-ChildItem -LiteralPath $dir -Filter "$base.vld4" -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        }
    }) + $recent | Select-Object -Unique)
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -gt 1) {
        throw "Program '$Name' exists in several places, give the full path: " + ($found -join '; ')
    }
    return $null
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

function Wait-Until([int]$TimeoutSec, [scriptblock]$Condition, [int]$StepMs = 250) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $result = & $Condition
        if ($result) { return $result }
        Start-Sleep -Milliseconds $StepMs
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-NewWindow([int]$ProcId, $Before, [int]$TimeoutSec, [scriptblock]$Filter, [int]$StepMs = 250) {
    return Wait-Until $TimeoutSec {
        @(Get-Tops $ProcId | Where-Object { $Before -notcontains $_.Handle } | Where-Object $Filter) | Select-Object -First 1
    } $StepMs
}

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

# Rule for a VL message box from the settings (vl.dialogRules): ConfirmStageMotion, ScannerNotConnected or ''.
function Get-DialogRule([string]$Text) {
    foreach ($rule in @($script:dialogRules)) {
        if ($rule.match -and $Text.IndexOf([string]$rule.match, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return [string]$rule.action }
    }
    return ''
}

# --- VL window on its start screen -------------------------------------------------------

function Get-StartScreenVl {
    if (-not $NewWindow) {
        foreach ($p in Get-VlProcesses) {
            $state = Get-VlState $p.Id
            if ($state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)) {
                Write-Log "Using the open VL window (PID $($p.Id))."
                return $p
            }
        }
    }
    if (-not (Test-Path -LiteralPath $VlExe)) { throw "VL is not installed: $VlExe" }
    Write-Log 'No idle VL window on its start screen, opening a new VL window...'
    Write-Status 'starting' 'Starting VL...'
    $p = if ($VlArgs) { Start-Process -FilePath $VlExe -ArgumentList $VlArgs -WorkingDirectory (Split-Path $VlExe) -PassThru }
         else { Start-Process -FilePath $VlExe -WorkingDirectory (Split-Path $VlExe) -PassThru }
    $script:lastStartSig = ''
    $ready = Wait-Until 240 {
        Test-CancelRequested
        if ($p.HasExited) { throw "VL exited right away (code $($p.ExitCode))." }
        $state = Get-VlState $p.Id
        if ($state.Signature -ne $script:lastStartSig) { $script:lastStartSig = $state.Signature; if ($state.Signature) { Write-Log "  VL windows: $($state.Signature)" DarkGray } }
        $state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)
    } 500
    if (-not $ready) { throw 'The new VL window did not reach its start screen within 4 min (see the windows in the log).' }
    Write-Log "VL ready (PID $($p.Id))."
    return $p
}

# --- AI Replay: button -> mode -> program selection ------------------------------------------

function Start-AiReplay($Proc, [string]$ProgramPath) {
    $state = Get-VlState $Proc.Id
    [Vl]::BringToFront($state.Main.Handle)

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($state.Button)
    $modeDialog = Wait-NewWindow $Proc.Id $before 15 { $_.Name -eq 'SelectReplayModeDialog' }
    if (-not $modeDialog) { throw 'The mode selection window did not open after clicking AI Replay.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    if ($Mode -eq 'Ask') {
        Write-Log 'Waiting for the operator to choose the replay mode in VL.'
        Write-Status 'mode' 'Choose the replay mode in VL.'
        $closed = Wait-Until 900 { Test-CancelRequested; -not [Vl]::IsWindow($modeDialog.Handle) -or -not [Vl]::IsWindowVisible($modeDialog.Handle) } 300
        if (-not $closed) { throw 'No replay mode was chosen within 15 min.' }
        $openDialog = Wait-NewWindow $Proc.Id $before 30 { $_.Class -eq '#32770' }
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
        $openDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' }
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

# Handles the open VL message boxes by the dialog rules. Stage movement is confirmed (OK) only with
# -ConfirmStageMotion On, at least 0.5 s after the box appeared, retried every 2 s up to 3 times.
function Invoke-DialogRules($State, [hashtable]$Seen) {
    foreach ($d in @($State.Tops | Where-Object { $_.Class -eq '#32770' })) {
        $h = [string]$d.Handle
        if (-not $Seen.ContainsKey($h)) {
            $text = Get-DialogText $d.Handle
            $Seen[$h] = @{ Text = $text; First = Get-Date; Tries = 0; Last = [datetime]::MinValue }
            if ($text) {
                $script:lastMessage = "VL message '$($d.Title)': $text"
                Write-Log "  $script:lastMessage" Yellow
                Write-Status 'message' 'VL shows a message.' $text
            }
        }
        $info = $Seen[$h]
        switch (Get-DialogRule $info.Text) {
            'ScannerNotConnected' {
                $ok = Find-OkButton $d.Handle
                if ($ok) { [Vl]::Click($ok) }
                Exit-Run $EXIT_ERROR 'ERROR' "The scanner is not connected (VL: '$($info.Text)'). Check the scanner cable and power, then start again."
            }
            'ConfirmStageMotion' {
                if ($ConfirmStageMotion -ne 'On' -or $info.Tries -ge 3) { break }
                $now = Get-Date
                if (($now - $info.First).TotalMilliseconds -lt 500 -or ($now - $info.Last).TotalSeconds -lt 2) { break }
                $ok = Find-OkButton $d.Handle
                if (-not $ok) { break }
                [Vl]::BringToFront($d.Handle)
                Start-Sleep -Milliseconds 200
                [Vl]::Click($ok)
                $info.Tries++; $info.Last = Get-Date
                Write-Log "  Confirmed: $($info.Text)"
            }
        }
    }
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
    $deadline = $startTime.AddMinutes($TimeoutMin)
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
        Invoke-DialogRules $state $seenDialogs

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
    [Vl]::BringToFront($state.Main.Handle)
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
    $finished = Wait-Until 600 {
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
    $state = Invoke-VlMenu $Proc $Menu
    $before = @($state.Tops | ForEach-Object { $_.Handle })
    $stlDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Name -eq 'StlExporterDialog' } 50
    if (-not $stlDialog) { throw 'The STL export window did not open after selecting Export > STL.' }

    # Binary, no thinning; VL switches hole filling off by itself every time the window opens.
    $thinning = [Vl]::FindChild($stlDialog.Handle, '_thinningRatioComboBox')
    if ($thinning -ne [IntPtr]::Zero -and [Vl]::Send($thinning, 0x0147, 0) -ne 0) {
        [void][Vl]::Send($thinning, 0x014E, 0)
        Write-Log 'Thinning set to 1:1.'
    }
    $binary = [Vl]::FindChild($stlDialog.Handle, '_binaryRadioButton')
    if ($binary -ne [IntPtr]::Zero) { [Vl]::Click($binary); Start-Sleep -Milliseconds 50 }
    $ok = [Vl]::FindChild($stlDialog.Handle, '_okButton')
    if ($ok -eq [IntPtr]::Zero) { [Vl]::Close($stlDialog.Handle); throw 'The OK button is missing in the STL export window.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($ok)
    $saveDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' } 50
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
    $saveDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' } 50
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
            if ([Vl]::IsWindow($h)) { [Vl]::BringToFront($h); Write-Log 'The calling window is in front.' }
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
                [Vl]::BringToFront($parent.MainWindowHandle)
                Write-Log "$($parent.ProcessName) (PID $id) is in front."
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

# Closes VL; the save prompt is answered No (the data is either saved already or not wanted). Never kills VL.
function Close-Vl($Proc) {
    $state = Get-VlState $Proc.Id
    if (-not $state.Main) { return $Proc.HasExited }
    [Vl]::Close($state.Main.Handle)
    $script:closeAnswered = $false
    $closed = Wait-Until 60 {
        if ($Proc.HasExited) { return $true }
        foreach ($d in @(Get-Tops $Proc.Id | Where-Object { $_.Class -eq '#32770' })) {
            $no = Find-DialogButton $d.Handle 7
            if ($no -and -not $script:closeAnswered) {
                Write-Log "  VL asks: $(Get-DialogText $d.Handle) - answering No."
                [Vl]::Click($no); $script:closeAnswered = $true
            }
            elseif (-not $no) { throw "VL shows a message while closing: $(Get-DialogText $d.Handle)" }
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
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Exit-Run $EXIT_ARGS 'ERROR' "PowerShell runs in $($ExecutionContext.SessionState.LanguageMode) mode; VL Connector needs FullLanguage (see the notes for IT)."
}
try {
    $cfg = Read-VlcSettings
    if (-not $Mode) { $Mode = [string]$cfg.vl.mode }
    if (-not $OutputDir) { $OutputDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VL Connector\Scans' }
    if (-not $ProgramDir) { $ProgramDir = @($cfg.vl.programFolders | Where-Object { $_ }) }
    if (-not $ProgramDir) { $ProgramDir = @([Environment]::GetFolderPath('MyDocuments')) }
    if ($TimeoutMin -le 0) { $TimeoutMin = [int]$cfg.vl.timeoutMin }
    if ($SettleSec -le 0) { $SettleSec = [double]$cfg.vl.settleSec }
    if (-not $ExportImmediately) { $ExportImmediately = if ($cfg.vl.exportImmediately) { 'On' } else { 'Off' } }
    if (-not $ConfirmStageMotion) { $ConfirmStageMotion = if ($cfg.vl.confirmStageMotion) { 'On' } else { 'Off' } }
    if (-not $AfterExport) { $AfterExport = [string]$cfg.vl.afterExport }
    if (-not $VldFolder) { $VldFolder = [string]$cfg.vl.vldFolder }
    if (-not $ReturnFocus) { $ReturnFocus = if ($cfg.vl.returnFocus) { 'On' } else { 'Off' } }
    if (-not $Menu) { $Menu = [string]$cfg.vl.menuExportStl }
    if (-not $VlExe) { $VlExe = [string]$cfg.vl.exe }
    $script:menuSaveAs = [string]$cfg.vl.menuSaveAs
    $script:closeWaitSec = [int]$cfg.vl.closeWaitSec
    $script:dialogRules = @($cfg.vl.dialogRules)
    $script:testedVersions = @($cfg.vl.testedVersions)
}
catch { Exit-Run $EXIT_ARGS 'ERROR' "Settings: $($_.Exception.Message)" }
$checks = @(
    @('Mode', $Mode, @('HighSpeed', 'Standard', 'Ask')),
    @('ExportImmediately', $ExportImmediately, @('On', 'Off')),
    @('ConfirmStageMotion', $ConfirmStageMotion, @('On', 'Off')),
    @('AfterExport', $AfterExport, @('None', 'Minimize', 'Close', 'SaveAndClose')),
    @('ReturnFocus', $ReturnFocus, @('On', 'Off')))
foreach ($c in $checks) {
    if ($c[2] -notcontains $c[1]) { Exit-Run $EXIT_ARGS 'ERROR' "-$($c[0]) '$($c[1])' is not valid (use $($c[2] -join ', '))." }
}

# --- Start -----------------------------------------------------------------------------

$script:mutex = New-Object System.Threading.Mutex($false, 'Local\VLConnector_VLReplay')
try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) {
    $script:mutex = $null
    Exit-Run $EXIT_BUSY 'BUSY' 'Another scan is running on this PC. Finish it in VL first.'
}

$Host.UI.RawUI.WindowTitle = 'VL Connector - AI Replay'
$what = if ($ExportOnly) { "export only $Program".Trim() } else { $Program }
$flags = @($(if ($DryRun) { 'DRY RUN' }), $(if ($NewWindow) { 'new window' })) | Where-Object { $_ }
Write-Log ("=== VLReplay $(Get-VlcVersion) $what | account $env:USERNAME | mode $Mode | export immediately $ExportImmediately | confirm stage $ConfirmStageMotion | after export $AfterExport " + ($flags -join ' | ')).Trim() Cyan
if (Test-Path -LiteralPath $VlExe) {
    $vlVersion = (Get-Item -LiteralPath $VlExe).VersionInfo.FileVersion
    if ($vlVersion -and $script:testedVersions -and $script:testedVersions -notcontains $vlVersion) {
        Write-Log "VL version $vlVersion has not been tested with VL Connector (tested: $($script:testedVersions -join ', '))." Yellow
    }
}
if ($script:cancelPath -and (Test-Path -LiteralPath $script:cancelPath)) { Remove-Item -LiteralPath $script:cancelPath -Force }

$runName = ''
if (-not $ExportOnly) {
    if (-not $Program) { Exit-Run $EXIT_ARGS 'ERROR' 'Give the program: VLReplay.cmd <program or path to the .vld4>' }
    $runName = '{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName ([IO.Path]::GetFileNameWithoutExtension($Program))), $startTime
    # A dry run writes a marker (STATE=DRYRUN) only with -MarkerFile, so that calls from PolyWorks can be tested.
    if (-not $DryRun -and -not $MarkerFile) { Set-MarkerPath (Join-Path $OutputDir "$runName.done") }
    try {
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        if ($script:markerPath -and (Test-Path -LiteralPath $script:markerPath)) { Remove-Item -LiteralPath $script:markerPath -Force }
        $script:programPath = Resolve-Program $Program
    }
    catch { Exit-Run $EXIT_ARGS 'ERROR' $_.Exception.Message }
    if (-not $script:programPath) { Exit-Run $EXIT_ARGS 'ERROR' "Program '$Program' not found (searched in the recently used programs and in $($ProgramDir -join ', '))." }
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
        $name = if ($Program) { [IO.Path]::GetFileNameWithoutExtension($Program) } else { $dataName }
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
        Invoke-AfterExport $proc $target $triangles $finish
        Write-Log 'Done.' Green
        exit $EXIT_OK
    }

    Write-Status 'starting' 'Opening VL...'
    $proc = Get-StartScreenVl
    $started = Start-AiReplay $proc $script:programPath
    if ($DryRun) {
        if ($started) {
            $dryRunText = 'AI Replay -> mode -> program entered -> Cancel. VL is back on its start screen.'
            if ($script:markerPath) { Exit-Run $EXIT_OK 'DRYRUN' $dryRunText }
            Write-Log "DRY RUN: $dryRunText" Green; $script:mutex.ReleaseMutex(); exit $EXIT_OK
        }
        throw 'DRY RUN: the program selection dialog did not close.'
    }
    Write-Log 'AI Replay is running - the operator continues in VL as usual.' Green
    Write-Status 'replay' 'AI Replay is running. Follow the steps in VL.'

    $finish = Wait-ReplayFinished $proc
    switch ($finish.Result) {
        'Cancelled' { Exit-Run $EXIT_CANCELLED 'CANCELLED' $finish.Message }
        'Error'     { Exit-Run $EXIT_ERROR 'ERROR' $finish.Message }
    }
    if ($finish.Message) { Write-Log $finish.Message Yellow }

    $target = Get-TargetPath $runName
    $triangles = $null
    for ($attempt = 1; $attempt -le 2 -and -not $triangles; $attempt++) {
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
    Invoke-AfterExport $proc $target $triangles $finish
    Write-Log 'Done.' Green
    exit $EXIT_OK
}
catch {
    Exit-Run $EXIT_ERROR 'ERROR' $_.Exception.Message
}
