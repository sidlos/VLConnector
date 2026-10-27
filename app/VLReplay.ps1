<#
  VLReplay.ps1 - starts AI Replay in the VL-800 from outside (e.g. from PolyWorks) and hands the STL over.

  Steps:
    1. finds a VL window on its start screen (AI Replay button), otherwise opens a new VL window,
    2. clicks AI Replay, picks the mode (Standard / HighSpeed) and puts the .vld4 program into the dialog,
    3. the operator works as usual (places the part, confirms the position...),
    4. when VL has applied the program after the scan and the window is idle, exports the STL via the
       menu File > Export > STL... (Binary, no thinning) straight into the output folder,
    5. checks the STL and writes the marker <program>.done (STATE=OK/ERROR/CANCELLED, STL=path).

  VL is driven only by Windows messages and UI Automation (no mouse or keyboard input). Nothing is
  written to KEYENCE files.

  Usage:
    VLReplay.cmd ABC                          program ABC.vld4 is searched in Documents / recently used programs
    VLReplay.cmd "C:\Programs\ABC.vld4" -Mode Standard   mode with stitching confirmation (default is HighSpeed)
    VLReplay.cmd ABC -DryRun                  only walks through the dialogs and cancels the program selection (no scan)
    VLReplay.cmd -ExportOnly                  only exports the STL from the data already open in VL
    VLReplay.cmd ABC -ExportImmediately       STL right after the scan is composed, without waiting for the alignment
                                              to the program (~20 s); the STL is then in scanner coordinates
                                              (PolyWorks aligns it itself)
    VLReplay.cmd ABC -VlToBackground          after the STL export minimizes VL and brings the PolyWorks window
                                              that started the launcher to the front (the next run restores VL)

  Exit code: 0 OK, 1 error, 2 cancelled in VL, 3 bad parameters / program not found, 4 already running.
  Log: VLReplay_<user>.log next to the script.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Program,
    [ValidateSet('Standard', 'HighSpeed')] [string]$Mode = 'HighSpeed',
    [string]$OutputDir = 'C:\PolyWorks\Vstup',
    [string]$StlFile,
    [string]$MarkerFile,
    [string[]]$ProgramDir = @([Environment]::GetFolderPath('MyDocuments')),
    [int]$TimeoutMin = 45,
    [double]$SettleSec = 2,
    [switch]$ExportImmediately,
    [switch]$NewWindow,
    [switch]$DryRun,
    [switch]$ExportOnly,
    [switch]$VlToBackground,
    [string]$Menu = 'File>Export>STL',
    [string]$VlExe = 'C:\Program Files\KEYENCE\VL-800 Series\VL Application\VLApplication4.exe',
    [string]$VlArgs
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

public static class Vl
{
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, string l, uint f, uint t, out IntPtr r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, StringBuilder l, uint f, uint t, out IntPtr r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessage(string s);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr a, uint size, uint type, uint protect);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr a, uint size, uint type);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr a, byte[] b, uint size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern void mouse_event(uint flags, int dx, int dy, uint data, UIntPtr extra);

    const uint SMTO_ABORTIFHUNG = 2;
    static readonly uint WM_GETCONTROLNAME = RegisterWindowMessage("WM_GETCONTROLNAME");

    // Visible top-level windows of the given process.
    public static IntPtr[] TopWindows(int pid)
    {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid && IsWindowVisible(h)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static IntPtr[] Children(IntPtr parent)
    {
        var list = new List<IntPtr>();
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) { list.Add(h); return true; }, IntPtr.Zero);
        return list.ToArray();
    }

    public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, s.Capacity); return s.ToString(); }

    // Window title (for windows of other processes only the title, not the content of an edit box).
    public static string Title(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, s.Capacity); return s.ToString(); }

    // Text of any window including edit boxes in another process (the system marshals WM_GETTEXT).
    public static string GetText(IntPtr h)
    {
        var s = new StringBuilder(2048); IntPtr r;
        SendMessageTimeout(h, 0x000D, (IntPtr)s.Capacity, s, SMTO_ABORTIFHUNG, 2000, out r);
        return s.ToString();
    }

    public static bool SetText(IntPtr h, string text)
    {
        IntPtr r;
        return SendMessageTimeout(h, 0x000C, IntPtr.Zero, text, SMTO_ABORTIFHUNG, 3000, out r) != IntPtr.Zero;
    }

    public static long Send(IntPtr h, uint msg, long w)
    {
        IntPtr r;
        SendMessageTimeout(h, msg, (IntPtr)w, IntPtr.Zero, SMTO_ABORTIFHUNG, 3000, out r);
        return (long)r;
    }

    // VL is processing messages (its window thread is not busy): an empty WM_NULL message within 1 s.
    public static bool IsResponsive(IntPtr h)
    {
        IntPtr r;
        return SendMessageTimeout(h, 0x0000, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 1000, out r) != IntPtr.Zero;
    }

    // Button click without the mouse; PostMessage lets VL open a modal dialog if it needs to.
    public static void Click(IntPtr h) { PostMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
    public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    // WinForms control name (Control.Name), independent of the VL user interface language.
    public static string WinFormsName(IntPtr hwnd)
    {
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        IntPtr proc = OpenProcess(0x0008 | 0x0010 | 0x0020 | 0x0400, false, pid);
        if (proc == IntPtr.Zero) return "";
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, 1024, 0x3000, 0x04);
        try
        {
            IntPtr r;
            if (SendMessageTimeout(hwnd, WM_GETCONTROLNAME, (IntPtr)512, mem, SMTO_ABORTIFHUNG, 1000, out r) == IntPtr.Zero) return "";
            byte[] b = new byte[1024]; IntPtr read;
            ReadProcessMemory(proc, mem, b, 1024, out read);
            string s = Encoding.Unicode.GetString(b);
            int z = s.IndexOf('\0');
            return z >= 0 ? s.Substring(0, z) : s;
        }
        finally { VirtualFreeEx(proc, mem, 0, 0x8000); CloseHandle(proc); }
    }

    public static IntPtr FindChild(IntPtr parent, string winFormsName)
    {
        foreach (IntPtr h in Children(parent))
            if (WinFormsName(h) == winFormsName) return h;
        return IntPtr.Zero;
    }

    // Windows lets a window come to the foreground only for the process with the last input;
    // a mouse move by 0 px satisfies that without side effects.
    public static void BringToFront(IntPtr hwnd)
    {
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9);
        IntPtr fg = GetForegroundWindow();
        if (fg == hwnd) return;
        mouse_event(0x1, 0, 0, 0, UIntPtr.Zero);
        uint ignored;
        uint fgThread = GetWindowThreadProcessId(fg, out ignored);
        uint me = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
        try { SetForegroundWindow(hwnd); }
        finally { if (attached) AttachThreadInput(me, fgThread, false); }
    }

    public static void Minimize(IntPtr hwnd) { ShowWindow(hwnd, 6); }

    // Invoke on a menu item that opens a modal dialog returns only after the dialog closes,
    // so it runs on its own thread.
    public static void InvokeAsync(AutomationElement e)
    {
        var t = new Thread(delegate() { try { ((InvokePattern)e.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); } catch { } });
        t.IsBackground = true;
        t.Start();
    }
}
'@

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_CANCELLED = 2; $EXIT_ARGS = 3; $EXIT_BUSY = 4

$logFile      = Join-Path $PSScriptRoot ('VLReplay_{0}.log' -f $env:USERNAME)
$operationLog = Join-Path $env:APPDATA 'KEYENCE\VL-800 Series\VL Application\VLOperation.log'
$templateList = Join-Path $env:LOCALAPPDATA 'KEYENCE\VL-800 Series\VL Application\RecentUsedTemplateFiles.xml'
$mySession    = [Diagnostics.Process]::GetCurrentProcess().SessionId
$startTime    = Get-Date

# --- Helper functions -----------------------------------------------------------------

function Write-Log([string]$Text, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Text
    Write-Host $line -ForegroundColor $Color
    # Shared write: the log can be written even while someone has it open (viewer, tail).
    try {
        $fs = [IO.File]::Open($logFile, 'Append', 'Write', 'ReadWrite, Delete')
        try { $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($bytes, 0, $bytes.Length) }
        finally { $fs.Dispose() }
    }
    catch { }
}

function Get-SafeName([string]$Name) {
    return ($Name.Split([IO.Path]::GetInvalidFileNameChars()) -join '_').Trim()
}

# Marker for PolyWorks: written under a temporary name and renamed, so it is never half-written.
function Write-Marker([string]$State, [string]$StlPath, [string]$Message) {
    if (-not $script:markerPath) { return }
    $lines = @(
        "STATE=$State"
        "STL=$StlPath"
        "PROGRAM=$script:programPath"
        ('START={0:yyyy-MM-dd HH:mm:ss}' -f $startTime)
        ('END={0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
        "MESSAGE=$($Message -replace '\r?\n', ' ')"
    )
    try {
        $temp = "$script:markerPath.part"
        [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $script:markerPath) { [IO.File]::Delete($script:markerPath) }
        [IO.File]::Move($temp, $script:markerPath)
        Write-Log "Marker: $script:markerPath ($State)"
    }
    catch { Write-Log "The marker could not be written: $($_.Exception.Message)" Red }
}

function Exit-Run([int]$Code, [string]$State, [string]$Message, [string]$StlPath = '') {
    $color = if ($Code -eq $EXIT_OK) { 'Green' } elseif ($Code -eq $EXIT_CANCELLED) { 'Yellow' } else { 'Red' }
    Write-Log "$State`: $Message" $color
    Write-Marker $State $StlPath $Message
    if ($script:mutex) { try { $script:mutex.ReleaseMutex() } catch { } }
    exit $Code
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

# Program: full path, or a name searched in the recently used programs and in -ProgramDir.
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
        throw "Program '$Name' exists in several places, give the full path:`n  " + ($found -join "`n  ")
    }
    return $null
}

# New complete lines in VLOperation.log (only for the log, helps with debugging).
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

function Get-VlProcesses {
    return @(Get-Process -Name VLApplication4 -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $mySession } | Sort-Object StartTime -Descending)
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

# Texts of a message box (MessageBox) - for the log and the marker.
function Get-DialogText([IntPtr]$Dialog) {
    return (@([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -match 'Static' } |
        ForEach-Object { [Vl]::Title($_) } | Where-Object { $_ }) -join ' / ')
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
    $p = if ($VlArgs) { Start-Process -FilePath $VlExe -ArgumentList $VlArgs -WorkingDirectory (Split-Path $VlExe) -PassThru }
         else { Start-Process -FilePath $VlExe -WorkingDirectory (Split-Path $VlExe) -PassThru }
    $script:lastStartSig = ''
    $ready = Wait-Until 240 {
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

    $buttonName = if ($Mode -eq 'HighSpeed') { '_highSpeedModeButton' } else { '_normalModeButton' }
    $modeButton = [Vl]::FindChild($modeDialog.Handle, $buttonName)
    if ($Mode -eq 'HighSpeed' -and ($modeButton -eq [IntPtr]::Zero -or -not [Vl]::IsWindowEnabled($modeButton))) {
        Write-Log 'High-speed mode is disabled in VL (GPU load limit), using Standard.' Yellow
        $modeButton = [Vl]::FindChild($modeDialog.Handle, '_normalModeButton')
    }
    if ($modeButton -eq [IntPtr]::Zero) { [Vl]::Close($modeDialog.Handle); throw 'The mode button is missing in the mode selection window.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($modeButton)
    $openDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' }
    if (-not $openDialog) { throw 'The AI Replay program selection dialog did not open.' }
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

# --- Waiting for the end of the part ------------------------------------------------------------

# Done: data in VL, VL started applying the program (it rewrites the program list only after the
# scan has been aligned to the program reference, i.e. after the last scan), the last position
# "AI Replay (n/n)" was seen and then the main window is idle and responsive for SettleSec. If the
# last position was not seen, 30 s of quiet after the program was applied are enough. If the
# program is not applied but VL has taken the scan over (STL Ready) and the last position ran,
# export after 120 s of quiet.
# Cancelled: back on the start screen and 30 s of quiet.
function Wait-ReplayFinished($Proc) {
    $templateStamp = Get-FileStamp $templateList
    $templateApplied = $false
    $deadline = $startTime.AddMinutes($TimeoutMin)
    $idleSince = $null
    $lastChange = Get-Date
    $lastSignature = $null
    $lastMessage = ''
    $seenDialogs = @{}
    $stlReady = 0
    $finalScan = $false    # 'STL Ready' came only after the last position n/n = the composed scan is in VL
    $position = $null      # last "AI Replay (k/n)" from the title of the window before a position
    $appliedWaitLogged = $false

    while ($true) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if ($Proc.HasExited) { return @{ Result = 'Error'; Message = "The VL window closed (PID $($Proc.Id)). $lastMessage" } }
        if ($now -gt $deadline) { return @{ Result = 'Error'; Message = "The part was not finished within $TimeoutMin min." } }

        # VLOperation.log: 'STL Ready' = VL has taken the scan over (after position 1 and after composing all positions).
        foreach ($line in @(Read-OperationLog)) {
            Write-Log "  VL: $($line.Trim())" DarkGray
            $lastChange = $now
            if ($line -match 'STL Ready') {
                $stlReady++
                if ($position -and $position.K -ge $position.N) { $finalScan = $true; Write-Log 'The composed scan is in VL (STL Ready after the last position).' }
            }
        }

        $state = Get-VlState $Proc.Id
        if ($state.Signature -ne $lastSignature) {
            $lastSignature = $state.Signature
            $lastChange = $now
            Write-Log "  VL windows: $($state.Signature)" DarkGray
            foreach ($d in $state.Tops | Where-Object { $_.Class -eq '#32770' -and -not $seenDialogs.ContainsKey($_.Handle) }) {
                $seenDialogs[$d.Handle] = $true
                $text = Get-DialogText $d.Handle
                if ($text) { $lastMessage = "VL message '$($d.Title)': $text"; Write-Log "  $lastMessage" Yellow }
            }
        }

        # The window before each position (ReplayForm) has "AI Replay (k/n)" in its title.
        foreach ($w in $state.Tops) {
            if (($w.Name -eq 'ReplayForm' -or $w.Title -match '^AI Replay') -and $w.Title -match '\((\d+)\s*/\s*(\d+)\)') {
                $k = [int]$Matches[1]; $n = [int]$Matches[2]
                if (-not $position -or $position.K -ne $k -or $position.N -ne $n) {
                    $position = @{ K = $k; N = $n }
                    Write-Log "AI Replay: position $k/$n"
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

        # -ExportImmediately: export right after the scan is composed, without waiting for the alignment to the program
        # (VL aligns for ~20 s in the background; the STL is then in scanner coordinates, not program coordinates).
        if ($ExportImmediately -and $finalScan -and $state.Idle -and -not $state.StartScreen -and $idleFor -ge 1) {
            return @{ Result = 'Done'; Message = 'STL right after the scan (before the alignment to the program, scanner coordinates).' }
        }
        if ($state.Idle -and -not $state.StartScreen) {
            if ($templateApplied -and $idleFor -ge $SettleSec -and -not $lastPosition -and -not $appliedWaitLogged) {
                $appliedWaitLogged = $true
                Write-Log "Program applied, but the last position was not seen (last $($position.K)/$($position.N)) - waiting." Yellow
            }
            if ($templateApplied -and (($lastPosition -and $idleFor -ge $SettleSec) -or $idleFor -ge 30)) {
                if (-not $stlReady) { Write-Log 'There was no STL Ready in VLOperation.log - continuing because the program was applied.' Yellow }
                return @{ Result = 'Done'; Message = '' }
            }
            if (-not $templateApplied -and $stlReady -and $lastPosition -and $idleFor -ge 120 -and ($now - $lastChange).TotalSeconds -ge 120) {
                return @{ Result = 'Done'; Message = 'VL did not apply the program after the scan, the STL has no VL evaluation.' }
            }
        }
        if ($state.Idle -and $state.StartScreen -and $idleFor -ge 30 -and ($now - $lastChange).TotalSeconds -ge 30) {
            return @{ Result = 'Cancelled'; Message = "AI Replay was cancelled or failed, VL is back on its start screen. $lastMessage".Trim() }
        }
    }
}

# --- STL export via the menu File > Export > STL... -----------------------------------------------------

function Get-MenuItems([int]$ProcId) {
    $byPid = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcId)
    $isItem = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)
    return @([System.Windows.Automation.AutomationElement]::RootElement.FindAll('Children', $byPid) |
        ForEach-Object { $_.FindAll('Descendants', $isItem) })
}

function Find-MenuItem([int]$ProcId, [string]$Name, [int]$TimeoutSec = 5) {
    return Wait-Until $TimeoutSec {
        @(Get-MenuItems $ProcId | Where-Object { ($_.Current.Name -replace '&', '' -replace '\.\.\.$', '').Trim() -eq $Name }) | Select-Object -First 1
    }
}

# Targeted menu search: items of the main menu bar, then the children of the expanded item (~0.07 s).
# Searching all UIA descendants of all VL windows (Find-MenuItem) took ~1.2 s per item.
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

function Export-StlFile($Proc, [string]$Target) {
    $parts = @($Menu -split '>' | ForEach-Object { $_.Trim() })
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

    $before = @($state.Tops | ForEach-Object { $_.Handle })
    $topItem = $null
    try {
        $parent = [System.Windows.Automation.AutomationElement]::FromHandle($strip)
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $item = Find-ChildMenuItem $parent $parts[$i]
            if (-not $item) { throw "The VL menu has no item '$($parts[$i])' (path $Menu)." }
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
    $edit = Find-FileNameEdit $saveDialog.Handle
    if (-not $edit) { [Vl]::Click((Find-DialogButton $saveDialog.Handle 2)); throw 'The File name box is missing in the Save As dialog.' }
    [void][Vl]::SetText($edit, $Target)
    if ([Vl]::GetText($edit) -ne $Target) { [Vl]::Click((Find-DialogButton $saveDialog.Handle 2)); throw 'The STL target path could not be entered.' }
    [Vl]::Click((Find-DialogButton $saveDialog.Handle 1))
    Write-Log "Exporting STL: $Target"

    # Done when both dialogs are gone, VL is idle and nobody writes the file any more
    # (VL wrote 'Finish STL Export', or the size did not change twice in a row).
    $script:lastLength = -2
    $script:finishSeen = $false
    $finished = Wait-Until 600 {
        foreach ($l in @(Read-OperationLog)) { if ($l -match 'Finish STL Export') { $script:finishSeen = $true } }
        $tops = @(Get-Tops $Proc.Id)
        $other = @($tops | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $saveDialog.Handle })
        if ($other) { throw "VL reports during the STL export: $((Get-DialogText $other[0].Handle))" }
        if ($Proc.HasExited) { throw 'VL closed during the STL export.' }
        $busy = @($tops | Where-Object { $_.Name -ne 'MeshAnalyzerForm' }).Count -gt 0
        $length = if (Test-Path -LiteralPath $Target) { Get-FinishedLength $Target } else { -1 }
        $stable = $length -gt 0 -and ($script:finishSeen -or $length -eq $script:lastLength)
        $script:lastLength = $length
        (-not $busy) -and $stable
    } 100
    if (-not $finished) { throw 'The STL export did not finish within 10 min.' }

    $triangles = Test-BinaryStl $Target
    if (-not $triangles) { throw "File $Target is not a valid binary STL." }
    if (-not $script:finishSeen -and -not (@(Read-OperationLog) -match 'Finish STL Export')) { Write-Log 'VL did not write Finish STL Export to VLOperation.log (the file is fine though).' Yellow }
    return $triangles
}

# -VlToBackground: minimize VL and bring the PolyWorks window the launcher runs from to the front
# (ancestor iminspect.exe: iminspect -> cmd -> powershell). Without PolyWorks it only minimizes VL.
function Move-VlToBackground($Proc) {
    try {
        $main = (Get-VlState $Proc.Id).Main
        if ($main) { [Vl]::Minimize($main.Handle) }
        $id = $PID
        for ($i = 0; $i -lt 6; $i++) {
            $me = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
            if (-not $me) { break }
            $id = [int]$me.ParentProcessId
            $parent = Get-Process -Id $id -ErrorAction SilentlyContinue
            if (-not $parent) { break }
            if ($parent.ProcessName -eq 'iminspect' -and $parent.MainWindowHandle -ne [IntPtr]::Zero) {
                [Vl]::BringToFront($parent.MainWindowHandle)
                Write-Log "VL minimized, PolyWorks (PID $id) in front."
                return
            }
        }
        Write-Log 'VL minimized (the launcher was not started from PolyWorks).'
    }
    catch { Write-Log "VL to background: $($_.Exception.Message)" Yellow }
}

# Without thousands separators and with a decimal point, so the marker is the same on every PC.
function Format-StlInfo([string]$Path, $Triangles) {
    $mb = (Get-Item -LiteralPath $Path).Length / 1MB
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'STL {0:0.0} MB, {1} triangles.', $mb, $Triangles)
}

function Get-TargetPath([string]$Name) {
    if ($StlFile) { return [IO.Path]::GetFullPath($StlFile) }
    $base = Join-Path $OutputDir ('{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName $Name), (Get-Date))
    $target = "$base.stl"
    $n = 2
    while (Test-Path -LiteralPath $target) { $target = "${base}_$n.stl"; $n++ }
    return $target
}

# --- Start -----------------------------------------------------------------------------

$script:mutex = New-Object System.Threading.Mutex($false, 'Local\VL_replay')
try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { $script:mutex = $null; Write-Log 'The launcher is already running (another part), exiting.' Red; exit $EXIT_BUSY }

$script:programPath = ''
$script:markerPath = $null
$Host.UI.RawUI.WindowTitle = 'VL Connector - AI Replay'
$what = if ($ExportOnly) { "export only $Program".Trim() } else { $Program }
$flags = @($(if ($DryRun) { 'DRY RUN' }), $(if ($NewWindow) { 'new window' })) | Where-Object { $_ }
Write-Log ("=== VLReplay $what | account $env:USERNAME | mode $Mode " + ($flags -join ' | ')).Trim() Cyan

$watcherRunning = $false
$watcherMutex = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\VL_export_stl', [ref]$watcherMutex)) { $watcherRunning = $true; $watcherMutex.Dispose() }
if ($watcherRunning) { Write-Log 'The export_stl.ps1 watcher is running - every part will produce two STL files. Switch it off for this mode.' Yellow }
if (Test-Path -LiteralPath (Join-Path (Split-Path $VlExe) 'Keyence.VlStlPatch.dll')) { Write-Log 'The STL test patch is deployed - it saves another STL into the report folder.' Yellow }

if (-not $ExportOnly) {
    if (-not $Program) { Write-Log 'Give the program: VLReplay.cmd <program or path to the .vld4>' Red; $script:mutex.ReleaseMutex(); exit $EXIT_ARGS }
    $programName = Get-SafeName ([IO.Path]::GetFileNameWithoutExtension($Program))
    # A dry run writes a marker (STATE=DRYRUN) only with -MarkerFile, so that calls from PolyWorks can be tested.
    if (-not $DryRun -or $MarkerFile) { $script:markerPath = if ($MarkerFile) { $MarkerFile } else { Join-Path $OutputDir "$programName.done" } }
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
        # with -MarkerFile write the marker even on an error before a VL window is found
        if ($MarkerFile) { $script:markerPath = $MarkerFile }
        $proc = $null
        foreach ($p in Get-VlProcesses) {
            $s = Get-VlState $p.Id
            if ($s.Idle -and -not $s.StartScreen -and $s.Main) { $proc = $p; $state = $s; break }
        }
        if (-not $proc) { throw 'No idle VL window with open data.' }
        $dataName = if ($state.Main.Title -match '^\W*(.+?)\W*\s-\sVL-800') { $Matches[1] } else { 'VL' }
        $name = if ($Program) { [IO.Path]::GetFileNameWithoutExtension($Program) } else { $dataName }
        $script:markerPath = if ($MarkerFile) { $MarkerFile } else { Join-Path $OutputDir "$(Get-SafeName $name).done" }
        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
        if (Test-Path -LiteralPath $script:markerPath) { Remove-Item -LiteralPath $script:markerPath -Force }
        Write-Log "Export from VL window PID $($proc.Id): $($state.Main.Title)"
        $target = Get-TargetPath $name
        $triangles = Export-StlFile $proc $target
        if ($VlToBackground) { Move-VlToBackground $proc }
        Exit-Run $EXIT_OK 'OK' (Format-StlInfo $target $triangles) $target
    }


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

    $finish = Wait-ReplayFinished $proc
    switch ($finish.Result) {
        'Cancelled' { Exit-Run $EXIT_CANCELLED 'CANCELLED' $finish.Message }
        'Error'     { Exit-Run $EXIT_ERROR 'ERROR' $finish.Message }
    }
    if ($finish.Message) { Write-Log $finish.Message Yellow }

    $target = Get-TargetPath $programName
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
    if ($VlToBackground) { Move-VlToBackground $proc }
    Exit-Run $EXIT_OK 'OK' $message $target
}
catch {
    Exit-Run $EXIT_ERROR 'ERROR' $_.Exception.Message
}
