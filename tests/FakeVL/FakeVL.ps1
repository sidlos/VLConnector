<#
  FakeVL.ps1 - test stand-in for the KEYENCE VL-800 "VL Application" (tests only, never shipped).

  It shows WinForms windows with the window titles and WinForms control names the launcher drives
  (MeshAnalyzerForm, _replayScanButton, SelectReplayModeDialog, ReplayForm "AI Replay (k/n)",
  StlExporterDialog, _mainMenuStrip File > Export > STL...), real Windows message boxes (#32770)
  and real Open / Save As dialogs. It appends to a fake VLOperation.log and rewrites a fake
  RecentUsedTemplateFiles.xml under %APPDATA% / %LOCALAPPDATA% (the test harness redirects both)
  and "exports" a generated binary STL.

  The test harness starts it through a renamed copy of powershell.exe, so its process name is
  VLApplication4 like the real application. Every step is written to -EventLog for assertions.
  Blocking dialogs run on helper threads, so the WinForms thread never runs a nested modal loop.
#>
param(
    [Parameter(Mandatory = $true)][string]$Scenario,
    [string]$EventLog = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace FakeVlNative
{
    public class Owner : IWin32Window
    {
        private readonly IntPtr handle;
        public Owner(IntPtr h) { handle = h; }
        public IntPtr Handle { get { return handle; } }
    }

    public static class Console
    {
        [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        public static void Hide() { IntPtr h = GetConsoleWindow(); if (h != IntPtr.Zero) ShowWindow(h, 0); }
    }

    // A real MessageBox (#32770) on its own STA thread, owned by the main window.
    public class AsyncBox
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int MessageBoxW(IntPtr h, string text, string caption, uint type);
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr h, int id);
        [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

        public volatile int Result = -1;
        public volatile bool Done;
        private volatile uint threadId;

        public AsyncBox(IntPtr owner, string text, string caption, uint type)
        {
            Thread t = new Thread(delegate()
            {
                threadId = GetCurrentThreadId();
                Result = MessageBoxW(owner, text, caption, type);
                Done = true;
            });
            t.IsBackground = true;
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
        }

        // Simulated operator: press the button with this id (1 OK, 2 Cancel, 6 Yes, 7 No).
        // In an OK-only message box the OK button has id 2 (IDCANCEL), so OK falls back to 2.
        public bool Press(int id)
        {
            if (threadId == 0 || Done) return false;
            bool hit = false;
            EnumThreadWindows(threadId, delegate(IntPtr h, IntPtr l)
            {
                IntPtr b = GetDlgItem(h, id);
                if (b == IntPtr.Zero && id == 1) b = GetDlgItem(h, 2);
                if (b != IntPtr.Zero) { PostMessage(b, 0x00F5, IntPtr.Zero, IntPtr.Zero); hit = true; }
                return true;
            }, IntPtr.Zero);
            return hit;
        }
    }

    // A real Open / Save As dialog on its own STA thread.
    public class AsyncFileDialog
    {
        public volatile bool Done;
        public volatile bool Ok;
        public volatile string FileName = "";

        public AsyncFileDialog(IntPtr owner, bool save, string title, string filter)
        {
            Thread t = new Thread(delegate()
            {
                FileDialog d = save ? (FileDialog)new SaveFileDialog() : (FileDialog)new OpenFileDialog();
                d.Title = title;
                d.Filter = filter;
                try { Ok = d.ShowDialog(new Owner(owner)) == DialogResult.OK; FileName = d.FileName; }
                finally { d.Dispose(); Done = true; }
            });
            t.IsBackground = true;
            t.SetApartmentState(ApartmentState.STA);
            t.Start();
        }
    }
}
'@

# --- Scenario ---------------------------------------------------------------------------

$defaults = [ordered]@{
    startupSec          = 1.5     # until the start screen with the AI Replay button is ready
    startWithData       = $false  # open with scan data already loaded (export-only tests)
    highSpeedEnabled    = $true
    positions           = 2
    operatorMeasureSec  = 1.0     # simulated operator presses Measure after this delay
    scanSec             = 1.5
    rotateDialog        = $true   # "The stage will rotate. Continue?" before positions 2..n
    rotateOperatorOkSec = 2.0     # simulated operator presses OK after this delay; 0 = never
    returnOriginDialog  = $false  # "Return the stage to the origin?" right after the program is opened
    connectHardware     = $false  # "Connect the hardware." after the program is opened, then VL exits
    unknownDialogText   = ''      # message box after position 1, closed by the operator after 2 s
    cancelAtPosition    = 0       # operator cancels the replay at this position (back to the start screen)
    exitAtPosition      = 0       # VL process exits at this position
    compositeSec        = 2.0
    checkResultsSec     = 2.0     # disabled "Check measurement results" window before the final STL Ready
    postStlIdleSec      = 3.0     # idle time after the final STL Ready before VL aligns to the program
    alignSec            = 4.0     # VL aligning to the program (main window busy), then the program list is rewritten
    exportFailCount     = 0       # the first N STL exports fail with an error message box
    operatorModeSec     = 0       # simulated operator picks the replay mode after this delay; 0 = never
    operatorMode        = 'Standard'
    corruptStlAfterSec  = 0       # truncate the exported STL after this delay (tests the check before closing)
    triangles           = 2000
    dataName            = 'demo'
}
$json = Get-Content -LiteralPath $Scenario -Raw | ConvertFrom-Json
$fakevl = if ($json.PSObject.Properties['fakevl']) { $json.fakevl } else { $null }
$cfg = @{}
foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }
if ($fakevl) { foreach ($p in $fakevl.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
if (-not $EventLog) { $EventLog = [IO.Path]::ChangeExtension($Scenario, '.events.log') }

$vlAppData = Join-Path $env:APPDATA 'KEYENCE\VL-800 Series\VL Application'
$vlLocalData = Join-Path $env:LOCALAPPDATA 'KEYENCE\VL-800 Series\VL Application'
New-Item -ItemType Directory -Force -Path $vlAppData, $vlLocalData | Out-Null
$operationLog = Join-Path $vlAppData 'VLOperation.log'
$templateList = Join-Path $vlLocalData 'RecentUsedTemplateFiles.xml'

function Write-Event([string]$Text) {
    $line = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $Text
    [IO.File]::AppendAllText($EventLog, $line + "`r`n")
}

function Write-OperationLog([string]$Text) {
    [IO.File]::AppendAllText($operationLog, ('{0:yyyy/MM/dd HH:mm:ss.fff},Info,{1}' -f (Get-Date), $Text) + "`r`n")
}

function Write-TemplateList([string]$ProgramPath) {
    $esc = [Security.SecurityElement]::Escape($ProgramPath)
    $xml = '<ArrayOfKeyValueOfstringanyType xmlns:i="http://www.w3.org/2001/XMLSchema-instance">' +
        '<KeyValueOfstringanyType><Key>Path</Key><a:Value i:type="b:string" xmlns:b="http://www.w3.org/2001/XMLSchema">' +
        $esc + '</a:Value></KeyValueOfstringanyType></ArrayOfKeyValueOfstringanyType>'
    [IO.File]::WriteAllText($templateList, $xml)
}

# Deterministic binary STL: 80 byte header, triangle count, 50 bytes per triangle.
function Write-BinaryStl([string]$Path, [int]$Count) {
    $fs = [IO.File]::Create($Path)
    $w = New-Object IO.BinaryWriter($fs)
    try {
        $header = [Text.Encoding]::ASCII.GetBytes('FakeVL binary STL'.PadRight(80))
        $w.Write($header, 0, 80)
        $w.Write([uint32]$Count)
        for ($i = 0; $i -lt $Count; $i++) {
            $x = [single]($i % 100); $y = [single][math]::Floor($i / 100)
            foreach ($v in @(0, 0, 1, $x, $y, 0, ($x + 1), $y, 0, $x, ($y + 1), 0)) { $w.Write([single]$v) }
            $w.Write([uint16]0)
        }
    }
    finally { $w.Dispose() }
}

# --- Timed actions -----------------------------------------------------------------------

$script:queue = New-Object System.Collections.ArrayList
$script:waits = New-Object System.Collections.ArrayList

function Invoke-After([double]$Sec, [scriptblock]$Do) {
    [void]$script:queue.Add([pscustomobject]@{ At = (Get-Date).AddSeconds($Sec); Do = $Do })
}

# Run $Then once the async box or file dialog $Obj is done.
function Invoke-WhenDone($Obj, [scriptblock]$Then) {
    [void]$script:waits.Add([pscustomobject]@{ Obj = $Obj; Then = $Then })
}

function Show-Box([string]$Text, [uint32]$Type) {
    $box = New-Object FakeVlNative.AsyncBox($script:main.Handle, $Text, 'VL-800 Series Application', $Type)
    return $box
}

function Show-Busy([string]$Title, [string]$Name, [bool]$Enabled = $true) {
    $f = New-Object Windows.Forms.Form
    $f.Name = $Name; $f.Text = $Title
    $f.Width = 360; $f.Height = 120; $f.StartPosition = 'CenterParent'
    $f.ShowInTaskbar = $false
    $f.Show($script:main)
    $f.Enabled = $Enabled
    return $f
}

function Close-Form($Form) {
    if ($Form -and -not $Form.IsDisposed) { $Form.Close(); $Form.Dispose() }
}

# --- Main window -------------------------------------------------------------------------

[FakeVlNative.Console]::Hide()
$script:main = New-Object Windows.Forms.Form
$script:main.Name = 'MeshAnalyzerForm'
$script:main.Text = 'VL-800 Series Application'
$script:main.Width = 900; $script:main.Height = 560; $script:main.StartPosition = 'CenterScreen'

$menu = New-Object Windows.Forms.MenuStrip
$menu.Name = '_mainMenuStrip'
$fileItem = New-Object Windows.Forms.ToolStripMenuItem('&File')
$exportItem = New-Object Windows.Forms.ToolStripMenuItem('&Export')
$script:stlItem = New-Object Windows.Forms.ToolStripMenuItem('&STL...')
$script:saveAsItem = New-Object Windows.Forms.ToolStripMenuItem('Save &As...')
[void]$exportItem.DropDownItems.Add($script:stlItem)
[void]$fileItem.DropDownItems.Add($script:saveAsItem)
[void]$fileItem.DropDownItems.Add($exportItem)
[void]$menu.Items.Add($fileItem)
$script:main.MainMenuStrip = $menu
$script:main.Controls.Add($menu)

$script:replayButton = New-Object Windows.Forms.Button
$script:replayButton.Name = '_replayScanButton'
$script:replayButton.Text = 'AI Replay'
$script:replayButton.Left = 40; $script:replayButton.Top = 60; $script:replayButton.Width = 160; $script:replayButton.Height = 60
$script:replayButton.Visible = $false
$script:main.Controls.Add($script:replayButton)

$script:hasData = $false
$script:dirty = $false
$script:allowClose = $false
$script:exportBusy = $false
$script:exportFailsLeft = [int]$cfg.exportFailCount
$script:k = 0
$script:program = ''

function Set-DataLoaded([string]$Name) {
    $script:hasData = $true
    $script:dirty = $true
    $script:main.Text = "$Name - VL-800 Series Application"
    $script:replayButton.Visible = $false
    $script:stlItem.Enabled = $true
    $script:saveAsItem.Enabled = $true
}

function Set-StartScreen([string]$Why) {
    Close-Form $script:replay
    Close-Form $script:busy
    $script:main.Enabled = $true
    $script:main.Text = 'VL-800 Series Application'
    $script:replayButton.Visible = $true
    $script:hasData = $false
    $script:dirty = $false
    $script:stlItem.Enabled = $false
    $script:saveAsItem.Enabled = $false
    Write-Event "start-screen:$Why"
}

# --- AI Replay ---------------------------------------------------------------------------

$script:replayButton.Add_Click({
    Write-Event 'click:ai-replay'
    $script:mode = New-Object Windows.Forms.Form
    $script:mode.Name = 'SelectReplayModeDialog'
    $script:mode.Text = 'AI Replay'
    $script:mode.Width = 420; $script:mode.Height = 180; $script:mode.StartPosition = 'CenterParent'
    $script:mode.FormBorderStyle = 'FixedDialog'
    $hs = New-Object Windows.Forms.Button
    $hs.Name = '_highSpeedModeButton'; $hs.Text = 'High-speed mode'; $hs.Left = 20; $hs.Top = 30; $hs.Width = 170; $hs.Height = 60
    $hs.Enabled = [bool]$cfg.highSpeedEnabled
    $nm = New-Object Windows.Forms.Button
    $nm.Name = '_normalModeButton'; $nm.Text = 'Standard mode'; $nm.Left = 210; $nm.Top = 30; $nm.Width = 170; $nm.Height = 60
    $hs.Add_Click({ Select-Mode 'HighSpeed' })
    $nm.Add_Click({ Select-Mode 'Standard' })
    $script:mode.Add_FormClosed({ if (-not $script:modeChosen) { $script:main.Enabled = $true; Write-Event 'mode:closed' } })
    $script:mode.Controls.Add($hs); $script:mode.Controls.Add($nm)
    $script:modeChosen = $false
    $script:main.Enabled = $false
    $script:mode.Show($script:main)
    $script:modeButtons = @{ HighSpeed = $hs; Standard = $nm }
    Write-Event 'mode-dialog'
    if ([double]$cfg.operatorModeSec -gt 0) {
        Invoke-After ([double]$cfg.operatorModeSec) {
            if (-not $script:modeChosen) { Write-Event "operator:mode-$($cfg.operatorMode)"; $script:modeButtons[[string]$cfg.operatorMode].PerformClick() }
        }
    }
})

function Select-Mode([string]$Mode) {
    $script:modeChosen = $true
    Close-Form $script:mode
    Write-Event "mode:$Mode"
    $script:chosenMode = $Mode
    $script:openDialog = New-Object FakeVlNative.AsyncFileDialog($script:main.Handle, $false, 'Open File', 'VL program (*.vld4)|*.vld4|All files (*.*)|*.*')
    Invoke-WhenDone $script:openDialog {
        if ($script:openDialog.Ok) { Open-Program $script:openDialog.FileName }
        else { Set-StartScreen 'open-cancelled' }
    }
}

function Open-Program([string]$Path) {
    $script:program = $Path
    Write-Event "program-opened:$Path"
    $script:replayButton.Visible = $false
    if ($cfg.connectHardware) {
        $script:hwBox = Show-Box 'Connect the hardware.' 0x30
        Write-Event 'dialog:connect-hardware'
        Invoke-After 3.0 { Write-Event 'exit:hardware'; [Environment]::Exit(3) }
        return
    }
    if ($cfg.returnOriginDialog) {
        $script:originBox = Show-Box 'Return the stage to the origin?' 0x21
        Write-Event 'dialog:return-origin'
        if ([double]$cfg.rotateOperatorOkSec -gt 0) {
            Invoke-After ([double]$cfg.rotateOperatorOkSec) { if ($script:originBox.Press(1)) { Write-Event 'operator:origin-ok' } }
        }
        Invoke-WhenDone $script:originBox {
            Write-Event "answer:return-origin:$($script:originBox.Result)"
            if ($script:originBox.Result -eq 1) { $script:k = 1; Start-Position } else { Set-StartScreen 'origin-cancelled' }
        }
        return
    }
    $script:k = 1
    Start-Position
}

function Start-Position {
    if ($script:k -gt 1 -and $cfg.rotateDialog) {
        $script:rotateBox = Show-Box 'The stage will rotate. Continue?                    ' 0x21
        Write-Event "dialog:rotate:$($script:k)"
        if ([double]$cfg.rotateOperatorOkSec -gt 0) {
            Invoke-After ([double]$cfg.rotateOperatorOkSec) { if ($script:rotateBox.Press(1)) { Write-Event 'operator:rotate-ok' } }
        }
        Invoke-WhenDone $script:rotateBox {
            Write-Event "answer:rotate:$($script:rotateBox.Result)"
            if ($script:rotateBox.Result -eq 1) { Show-ReplayForm } else { Set-StartScreen 'rotate-cancelled' }
        }
        return
    }
    Show-ReplayForm
}

function Show-ReplayForm {
    $k = $script:k; $n = [int]$cfg.positions
    $script:replay = New-Object Windows.Forms.Form
    $script:replay.Name = 'ReplayForm'
    $script:replay.Text = "AI Replay ($k/$n)"
    $script:replay.Width = 420; $script:replay.Height = 220; $script:replay.StartPosition = 'CenterParent'
    $core = New-Object Windows.Forms.Panel
    $core.Name = '_coreButton'; $core.Left = 20; $core.Top = 20; $core.Width = 200; $core.Height = 100
    $script:measureButton = New-Object Windows.Forms.Button
    $script:measureButton.Name = '_imageButton'; $script:measureButton.Text = 'Measure'; $script:measureButton.Width = 180; $script:measureButton.Height = 80
    $script:measureButton.Add_Click({ Start-Measure })
    $core.Controls.Add($script:measureButton)
    $script:replay.Controls.Add($core)
    $script:main.Enabled = $false
    $script:replay.Show($script:main)
    Write-Event "replay-form:$k/$n"
    if ([int]$cfg.cancelAtPosition -eq $k) {
        Invoke-After 1.0 { Write-Event 'operator:cancel'; Set-StartScreen 'cancelled' }
        return
    }
    if ([int]$cfg.exitAtPosition -eq $k) {
        Invoke-After 1.0 { Write-Event 'exit:crash'; [Environment]::Exit(1) }
        return
    }
    Invoke-After ([double]$cfg.operatorMeasureSec) {
        if ($script:replay -and -not $script:replay.IsDisposed) { Write-Event 'operator:measure'; $script:measureButton.PerformClick() }
    }
}

function Start-Measure {
    Close-Form $script:replay
    $script:busy = Show-Busy 'Data Acquisition' 'DataAcquisitionForm'
    Invoke-After ([double]$cfg.scanSec) {
        Close-Form $script:busy
        Write-OperationLog 'Capture Ready'
        if ($script:k -eq 1) { Write-OperationLog 'STL Ready' }
        Write-Event "scanned:$($script:k)"
        if ($script:k -eq 1 -and $cfg.unknownDialogText) {
            $script:unknownBox = Show-Box ([string]$cfg.unknownDialogText) 0x40
            Write-Event 'dialog:unknown'
            Invoke-After 2.0 { if ($script:unknownBox.Press(1)) { Write-Event 'operator:unknown-ok' } }
            Invoke-WhenDone $script:unknownBox { Continue-Replay }
            return
        }
        Continue-Replay
    }
}

function Continue-Replay {
    if ($script:k -lt [int]$cfg.positions) { $script:k++; Start-Position; return }
    $script:busy = Show-Busy 'Retrieving Stitching Data...' 'ProgressForm'
    Invoke-After 1.0 {
        Close-Form $script:busy
        $script:busy = Show-Busy 'Compositing 3D Data...' 'ProgressForm'
        Invoke-After ([double]$cfg.compositeSec) {
            Close-Form $script:busy
            Set-DataLoaded ([IO.Path]::GetFileNameWithoutExtension($script:program))
            $script:busy = Show-Busy 'Check measurement results' 'FileAligningConfirmationDialog' $false
            Invoke-After ([double]$cfg.checkResultsSec) {
                Close-Form $script:busy
                $script:main.Enabled = $true
                Write-OperationLog 'STL Ready'
                Write-Event 'final-stl-ready'
                Invoke-After ([double]$cfg.postStlIdleSec) { Start-Align }
            }
        }
    }
}

function Start-Align {
    if ($script:exportBusy) { Invoke-After 1.0 { Start-Align }; return }
    if ($script:main.IsDisposed) { return }
    $script:main.Enabled = $false
    Write-Event 'align:start'
    Invoke-After ([double]$cfg.alignSec) {
        Write-TemplateList $script:program
        $script:main.Enabled = $true
        Write-Event 'template-applied'
    }
}

# --- Export STL and Save As ----------------------------------------------------------------

$script:stlItem.Add_Click({
    $script:exportBusy = $true
    Write-Event 'menu:export-stl'
    $f = New-Object Windows.Forms.Form
    $f.Name = 'StlExporterDialog'; $f.Text = 'Export STL'
    $f.Width = 380; $f.Height = 220; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'
    $script:thinCombo = New-Object Windows.Forms.ComboBox
    $script:thinCombo.Name = '_thinningRatioComboBox'; $script:thinCombo.DropDownStyle = 'DropDownList'; $script:thinCombo.Left = 20; $script:thinCombo.Top = 20
    [void]$script:thinCombo.Items.AddRange(@('1/1', '1/2', '1/4', '1/8'))
    $script:thinCombo.SelectedIndex = 1
    $script:asciiRadio = New-Object Windows.Forms.RadioButton
    $script:asciiRadio.Name = '_asciiRadioButton'; $script:asciiRadio.Text = 'ASCII'; $script:asciiRadio.Left = 20; $script:asciiRadio.Top = 60; $script:asciiRadio.Checked = $true
    $script:binaryRadio = New-Object Windows.Forms.RadioButton
    $script:binaryRadio.Name = '_binaryRadioButton'; $script:binaryRadio.Text = 'Binary'; $script:binaryRadio.Left = 160; $script:binaryRadio.Top = 60
    $ok = New-Object Windows.Forms.Button
    $ok.Name = '_okButton'; $ok.Text = 'OK'; $ok.Left = 160; $ok.Top = 120
    $ok.Add_Click({
        $script:exportThin = $script:thinCombo.SelectedIndex
        $script:exportBinary = $script:binaryRadio.Checked
        Close-Form $script:stlDialog
        Write-Event "stl-options:thin=$($script:exportThin) binary=$($script:exportBinary)"
        $script:saveDialog = New-Object FakeVlNative.AsyncFileDialog($script:main.Handle, $true, 'Save As', 'STL file (*.stl)|*.stl')
        Invoke-WhenDone $script:saveDialog { Complete-StlExport }
    })
    $f.Controls.AddRange(@($script:thinCombo, $script:asciiRadio, $script:binaryRadio, $ok))
    $script:stlDialog = $f
    $script:main.Enabled = $false
    $f.Show($script:main)
})

function Complete-StlExport {
    if (-not $script:saveDialog.Ok) {
        $script:main.Enabled = $true; $script:exportBusy = $false
        Write-Event 'export:cancelled'
        return
    }
    $path = $script:saveDialog.FileName
    if ($script:exportFailsLeft -gt 0) {
        $script:exportFailsLeft--
        $script:failBox = Show-Box 'Failed to export the STL file.' 0x10
        Write-Event 'export:failed'
        Invoke-After 2.0 { if ($script:failBox.Press(1)) { Write-Event 'operator:export-error-ok' } }
        Invoke-WhenDone $script:failBox { $script:main.Enabled = $true; $script:exportBusy = $false }
        return
    }
    if ($script:exportBinary) { Write-BinaryStl $path ([int]$cfg.triangles) }
    else { [IO.File]::WriteAllText($path, "solid fakevl`r`nendsolid fakevl`r`n") }
    Write-OperationLog 'Finish STL Export'
    Write-Event "exported:$path"
    $script:main.Enabled = $true
    $script:exportBusy = $false
    if ([double]$cfg.corruptStlAfterSec -gt 0) {
        $script:corruptPath = $path
        Invoke-After ([double]$cfg.corruptStlAfterSec) {
            $fs = [IO.File]::Open($script:corruptPath, 'Open', 'Write', 'ReadWrite')
            try { $fs.SetLength(1000) } finally { $fs.Dispose() }
            Write-Event 'stl-corrupted'
        }
    }
}

$script:saveAsItem.Add_Click({
    Write-Event 'menu:save-as'
    $script:main.Enabled = $false
    $script:vldDialog = New-Object FakeVlNative.AsyncFileDialog($script:main.Handle, $true, 'Save As', 'VL data (*.vld4)|*.vld4')
    Invoke-WhenDone $script:vldDialog {
        $script:main.Enabled = $true
        if ($script:vldDialog.Ok) {
            [IO.File]::WriteAllText($script:vldDialog.FileName, 'FakeVL data')
            $script:dirty = $false
            Write-Event "saved:$($script:vldDialog.FileName)"
        }
        else { Write-Event 'save:cancelled' }
    }
})

$script:main.Add_Resize({
    if ($script:main.WindowState -eq 'Minimized' -and -not $script:minimizedLogged) { $script:minimizedLogged = $true; Write-Event 'window:minimized' }
})

# --- Closing (save prompt) ---------------------------------------------------------------------

$script:main.Add_FormClosing({
    param($sender, $e)
    if ($script:allowClose -or -not $script:dirty) { Write-Event 'exit:closed'; return }
    $e.Cancel = $true
    if ($script:closeBox -and -not $script:closeBox.Done) { return }
    $script:closeBox = Show-Box 'Do you want to save the changes?' 0x23
    Write-Event 'dialog:save-prompt'
    Invoke-WhenDone $script:closeBox {
        Write-Event "answer:save-prompt:$($script:closeBox.Result)"
        if ($script:closeBox.Result -eq 7) { $script:allowClose = $true; $script:main.Close() }
    }
})

# --- Timer and start -----------------------------------------------------------------------------

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 100
$timer.Add_Tick({
    # an exception must not reach WinForms: its error dialog would look like a VL message box
    foreach ($w in @($script:waits)) {
        if ($w.Obj.Done) {
            [void]$script:waits.Remove($w)
            try { & $w.Then } catch { Write-Event "error:$($_.Exception.Message)" }
        }
    }
    $now = Get-Date
    foreach ($a in @($script:queue | Where-Object { $_.At -le $now })) {
        [void]$script:queue.Remove($a)
        try { & $a.Do } catch { Write-Event "error:$($_.Exception.Message)" }
    }
})

Write-Event "start:pid=$PID scenario=$Scenario"
if ($cfg.startWithData) {
    $script:program = Join-Path $env:TEMP "$($cfg.dataName).vld4"
    Set-DataLoaded ([string]$cfg.dataName)
    Write-Event 'data-loaded'
}
else {
    $script:stlItem.Enabled = $false
    $script:saveAsItem.Enabled = $false
    Invoke-After ([double]$cfg.startupSec) { $script:replayButton.Visible = $true; Write-Event 'start-screen:ready' }
}
$timer.Start()
[Windows.Forms.Application]::Run($script:main)
Write-Event 'exit:end'
