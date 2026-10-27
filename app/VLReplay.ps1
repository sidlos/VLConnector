<#
  vl_replay.ps1 - AI Replay ve VL-800 spusteny zvenku (napr. z PolyWorks), STL do PolyWorks.

  Postup:
    1. najde okno VL s volnou uvodni obrazovkou (tlacitko AI Replay), jinak otevre nove okno VL,
    2. klikne na AI Replay, zvoli rezim (Standard / Rychly) a do dialogu vlozi program .vld4,
    3. operator dal pracuje jako dnes (polozi dil, potvrdi polohu...),
    4. kdyz VL po skenu aplikuje program a okno je volne, vyexportuje STL pres menu
       File > Export > STL... (Binary, bez prorezeni) primo do vystupni slozky,
    5. zkontroluje STL a zapise znacku <program>.hotovo (STAV=OK/CHYBA/ZRUSENO, STL=cesta).

  VL se ovlada jen zpravami Windows a UI Automation (bez mysi a klavesnice). Do souboru
  Keyence nic nezapisuje, patch ani hlidac export_stl.ps1 nejsou potreba.

  Pouziti:
    vl_replay.cmd ABC                         program ABC.vld4 se hleda v Dokumentech / naposledy pouzitych
    vl_replay.cmd "C:\Programy\ABC.vld4" -Rezim Standard   rezim se schvalovanim skladani (vychozi je Rychly)
    vl_replay.cmd ABC -Nanecisto              jen projde dialogy a vybrani programu zrusi (nic se neskenuje)
    vl_replay.cmd -JenExport                  jen vyexportuje STL z dat, ktera uz jsou ve VL otevrena
    vl_replay.cmd ABC -HnedPoSkenu            STL hned po slozeni skenu, bez cekani na zarovnani na program (~20 s);
                                              STL je pak v souradnicich skeneru (PolyWorks si ho zarovna sam)
    vl_replay.cmd ABC -VlDoPozadi             po exportu STL minimalizuje VL a do popredi da okno PolyWorks,
                                              ze ktereho byl spoustec spusten (dalsi beh VL zase obnovi)

  Navratovy kod: 0 OK, 1 chyba, 2 zruseno ve VL, 3 spatne parametry / program nenalezen, 4 uz bezi.
  Log: vl_replay_<uzivatel>.log vedle skriptu.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$Program,
    [ValidateSet('Standard', 'Rychly')] [string]$Rezim = 'Rychly',
    [string]$Vystup = 'C:\PolyWorks\Vstup',
    [string]$StlSoubor,
    [string]$Znacka,
    [string[]]$ProgramDir = @([Environment]::GetFolderPath('MyDocuments')),
    [int]$CasovacMin = 45,
    [double]$KlidSec = 2,
    [switch]$HnedPoSkenu,
    [switch]$NoveOkno,
    [switch]$Nanecisto,
    [switch]$JenExport,
    [switch]$VlDoPozadi,
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

    // Viditelna okna nejvyssi urovne zadaneho procesu.
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

    // Titulek okna (u cizich procesu jen titulek, ne obsah editu).
    public static string Title(IntPtr h) { var s = new StringBuilder(1024); GetWindowText(h, s, s.Capacity); return s.ToString(); }

    // Text jakehokoli okna vcetne editu v cizim procesu (WM_GETTEXT system prenese).
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

    // VL zpracovava zpravy (vlakno oken neni zaneprazdnene): prazdna zprava WM_NULL do 1 s.
    public static bool IsResponsive(IntPtr h)
    {
        IntPtr r;
        return SendMessageTimeout(h, 0x0000, IntPtr.Zero, IntPtr.Zero, SMTO_ABORTIFHUNG, 1000, out r) != IntPtr.Zero;
    }

    // Kliknuti na tlacitko bez mysi; PostMessage necha VL otevrit pripadny modalni dialog.
    public static void Click(IntPtr h) { PostMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
    public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    // Jmeno ovladaciho prvku WinForms (Control.Name), nezavisle na jazyku VL.
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

    // Stejne jako v export_stl.ps1: Windows pusti okno do popredi jen procesu s poslednim
    // vstupem; pohyb mysi o 0 px to splni bez vedlejsich ucinku.
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

    // Invoke na polozce menu, ktera otevre modalni dialog, se vrati az po jeho zavreni,
    // proto bezi ve vlastnim vlakne.
    public static void InvokeAsync(AutomationElement e)
    {
        var t = new Thread(delegate() { try { ((InvokePattern)e.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); } catch { } });
        t.IsBackground = true;
        t.Start();
    }
}
'@

$EXIT_OK = 0; $EXIT_ERROR = 1; $EXIT_CANCELLED = 2; $EXIT_ARGS = 3; $EXIT_BUSY = 4

$logFile      = Join-Path $PSScriptRoot ('vl_replay_{0}.log' -f $env:USERNAME)
$operationLog = Join-Path $env:APPDATA 'KEYENCE\VL-800 Series\VL Application\VLOperation.log'
$templateList = Join-Path $env:LOCALAPPDATA 'KEYENCE\VL-800 Series\VL Application\RecentUsedTemplateFiles.xml'
$mySession    = [Diagnostics.Process]::GetCurrentProcess().SessionId
$startTime    = Get-Date

# --- Pomocne funkce -------------------------------------------------------------------

function Write-Log([string]$Text, [string]$Color = 'Gray') {
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Text
    Write-Host $line -ForegroundColor $Color
    # Sdileny zapis: log jde psat, i kdyz ho ma nekdo otevreny (prohlizec, tail).
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

# Znacka pro PolyWorks: zapise se pod docasnym nazvem a prejmenuje, aby nikdy nebyla rozepsana.
function Write-Marker([string]$State, [string]$StlPath, [string]$Message) {
    if (-not $script:markerPath) { return }
    $lines = @(
        "STAV=$State"
        "STL=$StlPath"
        "PROGRAM=$script:programPath"
        ('ZACATEK={0:yyyy-MM-dd HH:mm:ss}' -f $startTime)
        ('KONEC={0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
        "ZPRAVA=$($Message -replace '\r?\n', ' ')"
    )
    try {
        $temp = "$script:markerPath.part"
        [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $script:markerPath) { [IO.File]::Delete($script:markerPath) }
        [IO.File]::Move($temp, $script:markerPath)
        Write-Log "Znacka: $script:markerPath ($State)"
    }
    catch { Write-Log "Znacku se nepodarilo zapsat: $($_.Exception.Message)" Red }
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

# Cesty programu ze seznamu naposledy pouzitych programu VL (stejne jako export_stl.ps1).
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

# Program: plna cesta, nebo nazev hledany v naposledy pouzitych programech a v -ProgramDir.
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
        throw "Program '$Name' je na vice mistech, zadejte plnou cestu:`n  " + ($found -join "`n  ")
    }
    return $null
}

# Nove cele radky ve VLOperation.log (jen do logu, pomaha pri ladeni).
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

# Binarni STL: 80 B hlavicka + pocet trojuhelniku + 50 B na trojuhelnik.
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

# --- Stav oken VL ----------------------------------------------------------------------

$script:replayButtons = @{}

# Okna procesu s titulkem (dialogy, progress); menu a tooltipy titulek nemaji.
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
        Signature   = (($tops | ForEach-Object { if ($_.Enabled) { $_.Title } else { "$($_.Title) [blok]" } }) -join ' | ')
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

# Pole "Nazev souboru" v dialogu Otevrit / Ulozit jako: viditelny Edit uvnitr ComboBoxu.
function Find-FileNameEdit([IntPtr]$Dialog) {
    return @([Vl]::Children($Dialog) | Where-Object {
        [Vl]::ClassOf($_) -eq 'Edit' -and [Vl]::IsWindowVisible($_) -and [Vl]::ClassOf([Vl]::GetParent($_)) -eq 'ComboBox' }) |
        Select-Object -First 1
}

function Find-DialogButton([IntPtr]$Dialog, [int]$Id) {
    return @([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -eq 'Button' -and [Vl]::GetDlgCtrlID($_) -eq $Id }) | Select-Object -First 1
}

# Texty v hlaseni (MessageBox) - do logu a do znacky.
function Get-DialogText([IntPtr]$Dialog) {
    return (@([Vl]::Children($Dialog) | Where-Object { [Vl]::ClassOf($_) -match 'Static' } |
        ForEach-Object { [Vl]::Title($_) } | Where-Object { $_ }) -join ' / ')
}

# --- Okno VL s uvodni obrazovkou ---------------------------------------------------------

function Get-StartScreenVl {
    if (-not $NoveOkno) {
        foreach ($p in Get-VlProcesses) {
            $state = Get-VlState $p.Id
            if ($state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)) {
                Write-Log "Pouziju otevrene okno VL (PID $($p.Id))."
                return $p
            }
        }
    }
    if (-not (Test-Path -LiteralPath $VlExe)) { throw "VL neni nainstalovane: $VlExe" }
    Write-Log 'Volne okno VL s uvodni obrazovkou neni, oteviram nove okno VL...'
    $p = if ($VlArgs) { Start-Process -FilePath $VlExe -ArgumentList $VlArgs -WorkingDirectory (Split-Path $VlExe) -PassThru }
         else { Start-Process -FilePath $VlExe -WorkingDirectory (Split-Path $VlExe) -PassThru }
    $script:lastStartSig = ''
    $ready = Wait-Until 240 {
        if ($p.HasExited) { throw "VL se hned ukoncilo (kod $($p.ExitCode))." }
        $state = Get-VlState $p.Id
        if ($state.Signature -ne $script:lastStartSig) { $script:lastStartSig = $state.Signature; if ($state.Signature) { Write-Log "  okna VL: $($state.Signature)" DarkGray } }
        $state.StartScreen -and $state.Idle -and [Vl]::IsWindowEnabled($state.Button)
    } 500
    if (-not $ready) { throw 'Nove okno VL se do 4 min nedostalo na uvodni obrazovku (viz okna v logu).' }
    Write-Log "VL pripraveno (PID $($p.Id))."
    return $p
}

# --- AI Replay: tlacitko -> rezim -> vyber programu ------------------------------------------

function Start-AiReplay($Proc, [string]$ProgramPath) {
    $state = Get-VlState $Proc.Id
    [Vl]::BringToFront($state.Main.Handle)

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($state.Button)
    $modeDialog = Wait-NewWindow $Proc.Id $before 15 { $_.Name -eq 'SelectReplayModeDialog' }
    if (-not $modeDialog) { throw 'Po kliknuti na AI Replay se neotevrelo okno volby rezimu.' }

    $buttonName = if ($Rezim -eq 'Rychly') { '_highSpeedModeButton' } else { '_normalModeButton' }
    $modeButton = [Vl]::FindChild($modeDialog.Handle, $buttonName)
    if ($Rezim -eq 'Rychly' -and ($modeButton -eq [IntPtr]::Zero -or -not [Vl]::IsWindowEnabled($modeButton))) {
        Write-Log 'Rychly rezim je ve VL vypnuty (omezeni zateze GPU), pouziju Standard.' Yellow
        $modeButton = [Vl]::FindChild($modeDialog.Handle, '_normalModeButton')
    }
    if ($modeButton -eq [IntPtr]::Zero) { [Vl]::Close($modeDialog.Handle); throw 'V okne volby rezimu chybi tlacitko rezimu.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($modeButton)
    $openDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' }
    if (-not $openDialog) { throw 'Neotevrel se dialog pro vyber programu AI Replay.' }
    Write-Log "Dialog '$($openDialog.Title)', vkladam program."

    $edit = Find-FileNameEdit $openDialog.Handle
    if (-not $edit) { throw 'V dialogu pro vyber programu chybi pole Nazev souboru.' }
    [void][Vl]::SetText($edit, $ProgramPath)
    $typed = [Vl]::GetText($edit)
    if ($typed -ne $ProgramPath) { throw "Cestu se nepodarilo vlozit (v poli je '$typed')." }

    if ($Nanecisto) {
        [Vl]::Click((Find-DialogButton $openDialog.Handle 2))
        $closed = Wait-Until 10 { -not [Vl]::IsWindow($openDialog.Handle) -or -not [Vl]::IsWindowVisible($openDialog.Handle) }
        return [bool]$closed
    }

    [Vl]::Click((Find-DialogButton $openDialog.Handle 1))
    $closed = Wait-Until 15 { -not [Vl]::IsWindow($openDialog.Handle) -or -not [Vl]::IsWindowVisible($openDialog.Handle) }
    if (-not $closed) {
        $reason = (@(Get-Tops $Proc.Id | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $openDialog.Handle } |
            ForEach-Object { Get-DialogText $_.Handle }) -join ' / ')
        throw "VL program neprijalo, dialog zustal otevreny. $reason"
    }
    return $true
}

# --- Cekani na konec dilu ----------------------------------------------------------------------

# Hotovo: data ve VL, VL zacalo aplikovat program (prepise seznam programu az po zarovnani
# skenu na referenci programu, tedy po poslednim skenu), byla videt posledni poloha
# "AI Replay (n/n)" a pak je hlavni okno 5 s volne a odpovida. Kdyz posledni poloha videt
# nebyla, staci 30 s klidu po aplikaci programu. Kdyz se program neaplikuje, ale VL uz sken
# prevzalo (STL Ready) a posledni poloha probehla, export po 120 s klidu.
# Zruseno: zpet uvodni obrazovka a 30 s klid.
function Wait-ReplayFinished($Proc) {
    $templateStamp = Get-FileStamp $templateList
    $templateApplied = $false
    $deadline = $startTime.AddMinutes($CasovacMin)
    $idleSince = $null
    $lastChange = Get-Date
    $lastSignature = $null
    $lastMessage = ''
    $seenDialogs = @{}
    $stlReady = 0
    $finalScan = $false    # 'STL Ready' prislo az po posledni poloze n/n = slozeny sken je ve VL
    $position = $null      # posledni "AI Replay (k/n)" z titulku okna pred polohou
    $appliedWaitLogged = $false

    while ($true) {
        Start-Sleep -Milliseconds 500
        $now = Get-Date
        if ($Proc.HasExited) { return @{ Result = 'Error'; Message = "Okno VL se zavrelo (PID $($Proc.Id)). $lastMessage" } }
        if ($now -gt $deadline) { return @{ Result = 'Error'; Message = "Dil nebyl hotovy do $CasovacMin min." } }

        # VLOperation.log: 'STL Ready' = VL prevzalo sken (po 1. poloze a po slozeni vsech poloh).
        foreach ($line in @(Read-OperationLog)) {
            Write-Log "  VL: $($line.Trim())" DarkGray
            $lastChange = $now
            if ($line -match 'STL Ready') {
                $stlReady++
                if ($position -and $position.K -ge $position.N) { $finalScan = $true; Write-Log 'Slozeny sken je ve VL (STL Ready po posledni poloze).' }
            }
        }

        $state = Get-VlState $Proc.Id
        if ($state.Signature -ne $lastSignature) {
            $lastSignature = $state.Signature
            $lastChange = $now
            Write-Log "  okna VL: $($state.Signature)" DarkGray
            foreach ($d in $state.Tops | Where-Object { $_.Class -eq '#32770' -and -not $seenDialogs.ContainsKey($_.Handle) }) {
                $seenDialogs[$d.Handle] = $true
                $text = Get-DialogText $d.Handle
                if ($text) { $lastMessage = "Hlaseni VL '$($d.Title)': $text"; Write-Log "  $lastMessage" Yellow }
            }
        }

        # Okno pred kazdou polohou (ReplayForm) ma v titulku "AI Replay (k/n)".
        foreach ($w in $state.Tops) {
            if (($w.Name -eq 'ReplayForm' -or $w.Title -match '^AI Replay') -and $w.Title -match '\((\d+)\s*/\s*(\d+)\)') {
                $k = [int]$Matches[1]; $n = [int]$Matches[2]
                if (-not $position -or $position.K -ne $k -or $position.N -ne $n) {
                    $position = @{ K = $k; N = $n }
                    Write-Log "AI Replay: poloha $k/$n"
                }
            }
        }
        # Bez titulku k/n (jiny jazyk, jina verze VL) se na posledni polohu neceka.
        $lastPosition = (-not $position) -or ($position.K -ge $position.N)

        $stamp = Get-FileStamp $templateList
        if (-not $templateApplied -and $stamp -ne $templateStamp) {
            $templateApplied = $true
            Write-Log 'VL aplikovalo program (seznam programu prepsan).'
            $idleSince = $null
        }

        if ($state.Idle) { if (-not $idleSince) { $idleSince = $now } } else { $idleSince = $null }
        $idleFor = if ($idleSince) { ($now - $idleSince).TotalSeconds } else { 0 }

        # -HnedPoSkenu: export hned po slozeni skenu, bez cekani na zarovnani na program
        # (VL zarovnava ~20 s na pozadi; STL je pak v souradnicich skeneru, ne programu).
        if ($HnedPoSkenu -and $finalScan -and $state.Idle -and -not $state.StartScreen -and $idleFor -ge 1) {
            return @{ Result = 'Done'; Message = 'STL hned po skenu (pred zarovnanim na program, souradnice skeneru).' }
        }
        if ($state.Idle -and -not $state.StartScreen) {
            if ($templateApplied -and $idleFor -ge $KlidSec -and -not $lastPosition -and -not $appliedWaitLogged) {
                $appliedWaitLogged = $true
                Write-Log "Program aplikovan, ale posledni poloha nebyla videt (naposledy $($position.K)/$($position.N)) - cekam." Yellow
            }
            if ($templateApplied -and (($lastPosition -and $idleFor -ge $KlidSec) -or $idleFor -ge 30)) {
                if (-not $stlReady) { Write-Log 'Ve VLOperation.log nebylo STL Ready - pokracuji podle aplikace programu.' Yellow }
                return @{ Result = 'Done'; Message = '' }
            }
            if (-not $templateApplied -and $stlReady -and $lastPosition -and $idleFor -ge 120 -and ($now - $lastChange).TotalSeconds -ge 120) {
                return @{ Result = 'Done'; Message = 'VL po skenu neaplikovalo program, STL je bez vyhodnoceni VL.' }
            }
        }
        if ($state.Idle -and $state.StartScreen -and $idleFor -ge 30 -and ($now - $lastChange).TotalSeconds -ge 30) {
            return @{ Result = 'Cancelled'; Message = "AI Replay byl zrusen nebo selhal, VL je zpet na uvodni obrazovce. $lastMessage".Trim() }
        }
    }
}

# --- Export STL pres menu File > Export > STL... -----------------------------------------------------

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

# Cilene hledani v menu: polozky hlavni listy menu, pak deti rozbalene polozky (~0.07 s).
# Prohledavani vsech UIA potomku vsech oken VL (Find-MenuItem) trvalo ~1.2 s na polozku.
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
    if (-not $state.Idle) { throw "Okno VL neni volne: $($state.Signature)" }
    [Vl]::BringToFront($state.Main.Handle)
    Start-Sleep -Milliseconds 100

    $strip = $script:menuStrips[$Proc.Id]
    if (-not $strip -or -not [Vl]::IsWindow($strip)) {
        $strip = [Vl]::FindChild($state.Main.Handle, '_mainMenuStrip')
        $script:menuStrips[$Proc.Id] = $strip
    }
    if ($strip -eq [IntPtr]::Zero) { throw 'V okne VL chybi hlavni menu (_mainMenuStrip).' }

    $before = @($state.Tops | ForEach-Object { $_.Handle })
    $topItem = $null
    try {
        $parent = [System.Windows.Automation.AutomationElement]::FromHandle($strip)
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $item = Find-ChildMenuItem $parent $parts[$i]
            if (-not $item) { throw "V menu VL chybi polozka '$($parts[$i])' (cesta $Menu)." }
            if (-not $item.Current.IsEnabled) { throw "Polozka menu '$($parts[$i])' je ve VL vypnuta." }
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
    if (-not $stlDialog) { throw 'Po vyberu Export > STL se neotevrelo okno exportu STL.' }

    # Binary, bez prorezeni; doplneni der VL pri kazdem otevreni vypina samo.
    $thinning = [Vl]::FindChild($stlDialog.Handle, '_thinningRatioComboBox')
    if ($thinning -ne [IntPtr]::Zero -and [Vl]::Send($thinning, 0x0147, 0) -ne 0) {
        [void][Vl]::Send($thinning, 0x014E, 0)
        Write-Log 'Prorezeni nastaveno na 1:1.'
    }
    $binary = [Vl]::FindChild($stlDialog.Handle, '_binaryRadioButton')
    if ($binary -ne [IntPtr]::Zero) { [Vl]::Click($binary); Start-Sleep -Milliseconds 50 }
    $ok = [Vl]::FindChild($stlDialog.Handle, '_okButton')
    if ($ok -eq [IntPtr]::Zero) { [Vl]::Close($stlDialog.Handle); throw 'V okne exportu STL chybi tlacitko OK.' }

    $before = @(Get-Tops $Proc.Id | ForEach-Object { $_.Handle })
    [Vl]::Click($ok)
    $saveDialog = Wait-NewWindow $Proc.Id $before 20 { $_.Class -eq '#32770' } 50
    if (-not $saveDialog) { [Vl]::Close($stlDialog.Handle); throw 'Neotevrel se dialog Ulozit jako pro STL.' }
    $edit = Find-FileNameEdit $saveDialog.Handle
    if (-not $edit) { [Vl]::Click((Find-DialogButton $saveDialog.Handle 2)); throw 'V dialogu Ulozit jako chybi pole Nazev souboru.' }
    [void][Vl]::SetText($edit, $Target)
    if ([Vl]::GetText($edit) -ne $Target) { [Vl]::Click((Find-DialogButton $saveDialog.Handle 2)); throw 'Cilovou cestu STL se nepodarilo vlozit.' }
    [Vl]::Click((Find-DialogButton $saveDialog.Handle 1))
    Write-Log "Exportuji STL: $Target"

    # Hotovo, kdyz zmizi oba dialogy, VL je volne a soubor uz nikdo nezapisuje
    # (VL zapsalo 'Finish STL Export', nebo se velikost dvakrat po sobe nezmenila).
    $script:lastLength = -2
    $script:finishSeen = $false
    $finished = Wait-Until 600 {
        foreach ($l in @(Read-OperationLog)) { if ($l -match 'Finish STL Export') { $script:finishSeen = $true } }
        $tops = @(Get-Tops $Proc.Id)
        $other = @($tops | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $saveDialog.Handle })
        if ($other) { throw "VL pri exportu STL hlasi: $((Get-DialogText $other[0].Handle))" }
        if ($Proc.HasExited) { throw 'VL se pri exportu STL zavrelo.' }
        $busy = @($tops | Where-Object { $_.Name -ne 'MeshAnalyzerForm' }).Count -gt 0
        $length = if (Test-Path -LiteralPath $Target) { Get-FinishedLength $Target } else { -1 }
        $stable = $length -gt 0 -and ($script:finishSeen -or $length -eq $script:lastLength)
        $script:lastLength = $length
        (-not $busy) -and $stable
    } 100
    if (-not $finished) { throw 'Export STL nedobehl do 10 min.' }

    $triangles = Test-BinaryStl $Target
    if (-not $triangles) { throw "Soubor $Target neni platne binarni STL." }
    if (-not $script:finishSeen -and -not (@(Read-OperationLog) -match 'Finish STL Export')) { Write-Log 'VL nezapsalo do VLOperation.log Finish STL Export (soubor je ale v poradku).' Yellow }
    return $triangles
}

# -VlDoPozadi: VL minimalizovat a do popredi dat okno PolyWorks, ze ktereho spoustec bezi
# (predek iminspect.exe: iminspect -> cmd -> powershell). Bez PolyWorks jen minimalizuje VL.
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
                Write-Log "VL minimalizovano, PolyWorks (PID $id) v popredi."
                return
            }
        }
        Write-Log 'VL minimalizovano (spoustec nebezel z PolyWorks).'
    }
    catch { Write-Log "VL do pozadi: $($_.Exception.Message)" Yellow }
}

# Bez oddelovacu tisicu a s desetinnou teckou, at je znacka stejna na kazdem PC.
function Format-StlInfo([string]$Path, $Triangles) {
    $mb = (Get-Item -LiteralPath $Path).Length / 1MB
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, 'STL {0:0.0} MB, {1} trojuhelniku.', $mb, $Triangles)
}

function Get-TargetPath([string]$Name) {
    if ($StlSoubor) { return [IO.Path]::GetFullPath($StlSoubor) }
    $base = Join-Path $Vystup ('{0}_{1:yyyy-MM-dd_HH-mm-ss}' -f (Get-SafeName $Name), (Get-Date))
    $target = "$base.stl"
    $n = 2
    while (Test-Path -LiteralPath $target) { $target = "${base}_$n.stl"; $n++ }
    return $target
}

# --- Start -----------------------------------------------------------------------------

$script:mutex = New-Object System.Threading.Mutex($false, 'Local\VL_replay')
try { $owned = $script:mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { $script:mutex = $null; Write-Log 'vl_replay uz bezi (jiny dil), konec.' Red; exit $EXIT_BUSY }

$script:programPath = ''
$script:markerPath = $null
$Host.UI.RawUI.WindowTitle = 'VL AI Replay -> PolyWorks'
$what = if ($JenExport) { "jen export $Program".Trim() } else { $Program }
$flags = @($(if ($Nanecisto) { 'NANECISTO' }), $(if ($NoveOkno) { 'nove okno' })) | Where-Object { $_ }
Write-Log ("=== vl_replay $what | ucet $env:USERNAME | rezim $Rezim " + ($flags -join ' | ')).Trim() Cyan

$watcherRunning = $false
$watcherMutex = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\VL_export_stl', [ref]$watcherMutex)) { $watcherRunning = $true; $watcherMutex.Dispose() }
if ($watcherRunning) { Write-Log 'Bezi hlidac export_stl.ps1 - po dilu vznikne STL dvakrat. Pro tento rezim ho vypnete.' Yellow }
if (Test-Path -LiteralPath (Join-Path (Split-Path $VlExe) 'Keyence.VlStlPatch.dll')) { Write-Log 'Je nasazeny testovaci patch STL - ulozi dalsi STL do slozky reportu.' Yellow }

if (-not $JenExport) {
    if (-not $Program) { Write-Log 'Zadejte program: vl_replay.cmd <program nebo cesta k .vld4>' Red; $script:mutex.ReleaseMutex(); exit $EXIT_ARGS }
    $programName = Get-SafeName ([IO.Path]::GetFileNameWithoutExtension($Program))
    # Nanecisto zapise znacku (STAV=NANECISTO) jen se zadanou -Znacka, aby slo zkouset volani z PolyWorks.
    if (-not $Nanecisto -or $Znacka) { $script:markerPath = if ($Znacka) { $Znacka } else { Join-Path $Vystup "$programName.hotovo" } }
    try {
        New-Item -ItemType Directory -Force -Path $Vystup | Out-Null
        if ($script:markerPath -and (Test-Path -LiteralPath $script:markerPath)) { Remove-Item -LiteralPath $script:markerPath -Force }
        $script:programPath = Resolve-Program $Program
    }
    catch { Exit-Run $EXIT_ARGS 'CHYBA' $_.Exception.Message }
    if (-not $script:programPath) { Exit-Run $EXIT_ARGS 'CHYBA' "Program '$Program' nenalezen (hledano v naposledy pouzitych a v $($ProgramDir -join ', '))." }
    Write-Log "Program: $script:programPath"
}

try {
    $script:opOffset = 0L; $script:opPending = ''
    if (Test-Path -LiteralPath $operationLog) { $script:opOffset = (Get-Item -LiteralPath $operationLog).Length }

    if ($JenExport) {
        # se zadanou -Znackou ji zapsat i pri chybe pred nalezenim okna VL
        if ($Znacka) { $script:markerPath = $Znacka }
        $proc = $null
        foreach ($p in Get-VlProcesses) {
            $s = Get-VlState $p.Id
            if ($s.Idle -and -not $s.StartScreen -and $s.Main) { $proc = $p; $state = $s; break }
        }
        if (-not $proc) { throw 'Zadne volne okno VL s otevrenymi daty.' }
        $dataName = if ($state.Main.Title -match '^\W*(.+?)\W*\s-\sVL-800') { $Matches[1] } else { 'VL' }
        $name = if ($Program) { [IO.Path]::GetFileNameWithoutExtension($Program) } else { $dataName }
        $script:markerPath = if ($Znacka) { $Znacka } else { Join-Path $Vystup "$(Get-SafeName $name).hotovo" }
        New-Item -ItemType Directory -Force -Path $Vystup | Out-Null
        if (Test-Path -LiteralPath $script:markerPath) { Remove-Item -LiteralPath $script:markerPath -Force }
        Write-Log "Export z okna VL PID $($proc.Id): $($state.Main.Title)"
        $target = Get-TargetPath $name
        $triangles = Export-StlFile $proc $target
        if ($VlDoPozadi) { Move-VlToBackground $proc }
        Exit-Run $EXIT_OK 'OK' (Format-StlInfo $target $triangles) $target
    }


    $proc = Get-StartScreenVl
    $started = Start-AiReplay $proc $script:programPath
    if ($Nanecisto) {
        if ($started) {
            $dryRunText = 'AI Replay -> rezim -> program vlozen -> Storno. VL je zpet na uvodni obrazovce.'
            if ($script:markerPath) { Exit-Run $EXIT_OK 'NANECISTO' $dryRunText }
            Write-Log "NANECISTO: $dryRunText" Green; $script:mutex.ReleaseMutex(); exit $EXIT_OK
        }
        throw 'NANECISTO: dialog pro vyber programu se nezavrel.'
    }
    Write-Log 'AI Replay bezi - operator pokracuje ve VL jako obvykle.' Green

    $finish = Wait-ReplayFinished $proc
    switch ($finish.Result) {
        'Cancelled' { Exit-Run $EXIT_CANCELLED 'ZRUSENO' $finish.Message }
        'Error'     { Exit-Run $EXIT_ERROR 'CHYBA' $finish.Message }
    }
    if ($finish.Message) { Write-Log $finish.Message Yellow }

    $target = Get-TargetPath $programName
    $triangles = $null
    for ($attempt = 1; $attempt -le 2 -and -not $triangles; $attempt++) {
        try { $triangles = Export-StlFile $proc $target }
        catch {
            Write-Log "Export STL (pokus $attempt): $($_.Exception.Message)" Yellow
            if ($attempt -eq 2) { throw }
            Start-Sleep -Seconds 3
            [void](Wait-Until 60 { (Get-VlState $proc.Id).Idle } 500)
        }
    }
    $message = ((Format-StlInfo $target $triangles) + ' ' + $finish.Message).Trim()
    if ($VlDoPozadi) { Move-VlToBackground $proc }
    Exit-Run $EXIT_OK 'OK' $message $target
}
catch {
    Exit-Run $EXIT_ERROR 'CHYBA' $_.Exception.Message
}
