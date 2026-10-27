# Adds the VL Connector tab with the Measure (or Station) button to the PolyWorks|Inspector ribbon - the
# same thing a user does by hand in File > Visual Layout > Customize - and undoes it. It works only with
# documented PolyWorks macro commands, sent through the PolyWorks programming interface (COM) to the
# PolyWorks|Inspector that is open on this PC:
#   1. WINDOW VISUAL_LAYOUT EXPORT                      backup of the current visual layout (user's profile)
#   2. WINDOW VISUAL_LAYOUT IMPORT_MACRO_SCRIPTS        imports the button macro with its icon
#   3. WINDOW VISUAL_LAYOUT EXPORT                      the layout with the imported button
#   4. (here) a "VL Connector" ribbon tab with that button is added to the exported layout.xml
#   5. WINDOW VISUAL_LAYOUT LOAD                        loads it; the backup can be loaded back (Undo)
# Dot-source this file; it needs lib\Settings.ps1 and lib\PolyWorksSetup.ps1.

if (-not ('VlcPolyWorks' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// PolyWorks programming interface (from the PolyWorks SDK). Only these calls are used: find the running
// PolyWorks|Inspector, create a command center in it and run a macro script text.
[ComImport, Guid("C2A13346-A194-4A07-BDE4-95FCA4FA1B67"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVlcWorkspaceManager {
    [PreserveSig] int CommandCenterCreate([MarshalAs(UnmanagedType.IUnknown)] out object cc);
    [PreserveSig] int ModuleGet([MarshalAs(UnmanagedType.LPWStr)] string pwk, [MarshalAs(UnmanagedType.LPWStr)] string project, [MarshalAs(UnmanagedType.IUnknown)] out object module);
    [PreserveSig] int ModuleStart(int type, [MarshalAs(UnmanagedType.LPWStr)] string pwk, [MarshalAs(UnmanagedType.LPWStr)] string project, [MarshalAs(UnmanagedType.IUnknown)] out object module);
    [PreserveSig] int RunningModulesGet(int type,
        [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_BSTR)] out string[] pwks,
        [MarshalAs(UnmanagedType.SafeArray, SafeArraySubType = VarEnum.VT_BSTR)] out string[] projects);
}
[ComImport, Guid("10976620-fc02-11d6-9394-00b0d0224d3a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVlcInspect {
    [PreserveSig] int Login([MarshalAs(UnmanagedType.LPWStr)] string user);
    [PreserveSig] int ProjectGetCurrent(out IVlcInspectProject project);
}
[ComImport, Guid("2d90e82a-1460-11d7-9397-00b0d0224d3a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVlcInspectProject {
    [PreserveSig] int CommandCenterCreate(out IVlcCommandCenter cc);
}
[ComImport, Guid("214c846e-fbfd-11d6-9394-00b0d0224d3a"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVlcCommandCenter {
    [PreserveSig] int CommandExecute([MarshalAs(UnmanagedType.LPWStr)] string cmd, out int ret);
    [PreserveSig] int ReturnValueGetAsString(int code, [MarshalAs(UnmanagedType.BStr)] out string text);
    [PreserveSig] int ReturnValueIsSuccess(int code, out int isSuccess);
    [PreserveSig] int ScriptExecuteFromBuffer([MarshalAs(UnmanagedType.LPWStr)] string script, [MarshalAs(UnmanagedType.LPWStr)] string args, out int ret);
    [PreserveSig] int ScriptExecuteFromFile([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.LPWStr)] string args, out int ret);
    [PreserveSig] int ScriptVariableGetValueAsFloat([MarshalAs(UnmanagedType.LPWStr)] string name, int index, out float value, out int ret);
    [PreserveSig] int ScriptVariableGetValueAsInt([MarshalAs(UnmanagedType.LPWStr)] string name, int index, out int value, out int ret);
    [PreserveSig] int ScriptVariableGetValueAsString([MarshalAs(UnmanagedType.LPWStr)] string name, int index, [MarshalAs(UnmanagedType.BStr)] out string value, out int ret);
    [PreserveSig] int ScriptVariableGetNbValues([MarshalAs(UnmanagedType.LPWStr)] string name, out int nb);
}

public static class VlcPolyWorks {
    // The running PolyWorks|Inspector modules: "workspace|project" (empty when PolyWorks is not running).
    // The Workspace Manager is never started from here: only an already running one is used.
    public static string[] RunningInspectors() {
        Type t = Type.GetTypeFromProgID("InnovMetric.PolyWorks.WorkspaceManager");
        if (t == null) return new string[0];
        if (System.Diagnostics.Process.GetProcessesByName("polyworks").Length == 0) return new string[0];
        IVlcWorkspaceManager wm = (IVlcWorkspaceManager)Activator.CreateInstance(t);
        string[] pwks, projects;
        if (wm.RunningModulesGet(2, out pwks, out projects) != 0 || projects == null) return new string[0];
        string[] r = new string[projects.Length];
        for (int i = 0; i < projects.Length; i++) r[i] = pwks[i] + "|" + projects[i];
        return r;
    }

    // Runs a macro script text in the given Inspector and returns the values of the variables (name=value lines).
    public static string Run(string pwk, string project, string script, string[] vars) {
        IVlcWorkspaceManager wm = (IVlcWorkspaceManager)Activator.CreateInstance(Type.GetTypeFromProgID("InnovMetric.PolyWorks.WorkspaceManager"));
        object mod;
        int hr = wm.ModuleGet(pwk, project, out mod);
        if (hr != 0 || mod == null) throw new Exception("PolyWorks|Inspector is not reachable (0x" + hr.ToString("X8") + ").");
        IVlcInspectProject proj;
        hr = ((IVlcInspect)mod).ProjectGetCurrent(out proj);
        if (hr != 0) throw new Exception("No project is open in PolyWorks|Inspector (0x" + hr.ToString("X8") + ").");
        IVlcCommandCenter cc;
        proj.CommandCenterCreate(out cc);
        int ret; cc.ScriptExecuteFromBuffer(script, "", out ret);
        int ok; cc.ReturnValueIsSuccess(ret, out ok);
        var sb = new System.Text.StringBuilder();
        foreach (string v in vars) {
            string value; int r; cc.ScriptVariableGetValueAsString(v, 1, out value, out r);
            sb.Append(v).Append('=').Append(value).Append('\n');
        }
        if (ok == 0) { string text; cc.ReturnValueGetAsString(ret, out text); sb.Append("SCRIPT_ERROR=").Append(text).Append('\n'); }
        return sb.ToString();
    }
}

// Retries COM calls while PolyWorks is busy (same idea as the message filter in the PolyWorks SDK samples).
[ComImport, Guid("00000016-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IVlcMessageFilter {
    [PreserveSig] int HandleInComingCall(int callType, IntPtr caller, int tick, IntPtr info);
    [PreserveSig] int RetryRejectedCall(IntPtr callee, int tick, int rejectType);
    [PreserveSig] int MessagePending(IntPtr callee, int tick, int pendingType);
}
public class VlcRetryFilter : IVlcMessageFilter {
    [DllImport("ole32.dll")] static extern int CoRegisterMessageFilter(IVlcMessageFilter f, out IVlcMessageFilter old);
    public static void Register() { IVlcMessageFilter old; CoRegisterMessageFilter(new VlcRetryFilter(), out old); }
    public int HandleInComingCall(int callType, IntPtr caller, int tick, IntPtr info) { return 0; }
    public int RetryRejectedCall(IntPtr callee, int tick, int rejectType) { return rejectType == 2 && tick < 120000 ? 200 : -1; }
    public int MessagePending(IntPtr callee, int tick, int pendingType) { return 2; }
}
'@
}

function Get-VlcLayoutWorkDir {
    $dir = Join-Path (Get-VlcPaths).DataDir 'polyworks-layout'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    return $dir
}

# The PolyWorks|Inspector to work with: the first running one, $null when none runs.
function Get-VlcRunningInspector {
    $list = @([VlcPolyWorks]::RunningInspectors())
    if (-not $list.Count) { return $null }
    $parts = $list[0] -split '\|', 2
    return [pscustomobject]@{ Pwk = $parts[0]; Project = $parts[1]; Count = $list.Count }
}

function Invoke-VlcInspectorScript($Inspector, [string]$Script, [string[]]$Vars) {
    [VlcRetryFilter]::Register()
    $text = [VlcPolyWorks]::Run($Inspector.Pwk, $Inspector.Project, $Script, $Vars)
    $result = @{}
    foreach ($line in $text -split "`n") { $i = $line.IndexOf('='); if ($i -gt 0) { $result[$line.Substring(0, $i)] = $line.Substring($i + 1) } }
    if ($result.SCRIPT_ERROR) { throw "PolyWorks: $($result.SCRIPT_ERROR)" }
    return $result
}

function Read-ZipText([string]$Zip, [string]$Entry) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $e = $z.GetEntry($Entry)
        if (-not $e) { return $null }
        $r = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
        try { return $r.ReadToEnd() } finally { $r.Dispose() }
    }
    finally { $z.Dispose() }
}

# Copies a layout ZIP and replaces layout.xml.
function Write-LayoutWithXml([string]$Source, [string]$Target, [string]$Xml) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force }
    $in = [IO.Compression.ZipFile]::OpenRead($Source)
    $out = [IO.Compression.ZipFile]::Open($Target, 'Create')
    try {
        foreach ($e in $in.Entries) {
            $ne = $out.CreateEntry($e.FullName)
            $ws = $ne.Open()
            try {
                if ($e.FullName -eq 'layout.xml') { $b = (New-Object Text.UTF8Encoding($false)).GetBytes($Xml); $ws.Write($b, 0, $b.Length) }
                else { $rs = $e.Open(); try { $rs.CopyTo($ws) } finally { $rs.Dispose() } }
            }
            finally { $ws.Dispose() }
        }
    }
    finally { $out.Dispose(); $in.Dispose() }
}

# A minimal visual layout with only the VL Connector button macro: macro text, icon (SVG) and description,
# in the format PolyWorks itself exports.
function New-VlcButtonLayout([string]$Path, [string]$Kind, [string]$InfoXml) {
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $name = "VLC_${Kind}_Button.pwmacro"
    $stubPath = Get-VlcButtonStubPath $Kind
    if (-not (Test-Path -LiteralPath $stubPath)) { [void](New-VlcButtonStub -Kind $Kind) }
    $macro = [IO.File]::ReadAllBytes($stubPath)
    $svg = [IO.File]::ReadAllBytes((Join-Path (Get-VlcPaths).AppDir 'assets\VLC_icon.svg'))
    $icon = New-Object byte[] (2 + $svg.Length + 4)
    [BitConverter]::GetBytes([uint16]$svg.Length).CopyTo($icon, 0); $svg.CopyTo($icon, 2); [BitConverter]::GetBytes([uint32]1).CopyTo($icon, 2 + $svg.Length)
    $descText = @{ Measure = 'VL Connector - Measure'; Station = 'VL Connector - Station' }[$Kind]
    $chars = [Text.Encoding]::Unicode.GetBytes($descText)
    $desc = New-Object byte[] (4 + $chars.Length)
    $desc[0] = 0xFF; $desc[1] = 0xFE; $desc[2] = 0xFF; $desc[3] = [byte]$descText.Length; $chars.CopyTo($desc, 4)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($e in @(@('info.xml', [Text.Encoding]::UTF8.GetBytes($InfoXml)), @("macro\$name", $macro), @("icon/$name", $icon), @("desc/$name", $desc))) {
            $entry = $zip.CreateEntry($e[0]); $s = $entry.Open()
            try { $s.Write($e[1], 0, $e[1].Length) } finally { $s.Dispose() }
        }
    }
    finally { $zip.Dispose() }
    return $name
}

# Adds (or renews) the "VL Connector" ribbon tab with the button of $Kind (Measure or Station) in the open
# PolyWorks|Inspector. Returns the path of the backup of the previous layout.
function Install-VlcPolyWorksTab([ValidateSet('Measure', 'Station')] [string]$Kind = 'Measure') {
    $insp = Get-VlcRunningInspector
    if (-not $insp) { throw 'Open PolyWorks|Inspector first (any project), then try again.' }
    $work = Get-VlcLayoutWorkDir
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backup = Join-Path $work "backup_$stamp"
    $exported = Join-Path $work "export_$stamp"
    $buttons = Join-Path $work 'VL Connector buttons'
    $final = Join-Path $work "with_tab_$stamp"

    # 1) backup
    $r = Invoke-VlcInspectorScript $insp ("version `"7.0`"`r`nMACRO END_ON_ERROR ( `"Off`" )`r`nDECLARE vSt `"`"`r`nDECLARE vErr `"`"`r`nWINDOW VISUAL_LAYOUT EXPORT ( `"$backup`" )`r`nMACRO GET_ERROR_STATUS ( vSt, vErr )`r`n") @('vSt', 'vErr')
    if ($r.vSt -ne 'No Error' -or -not (Test-Path -LiteralPath $backup)) { throw "The PolyWorks visual layout could not be saved: $($r.vErr)" }
    $info = Read-ZipText $backup 'info.xml'
    if (-not $info) { throw 'The PolyWorks visual layout has an unknown format (no info.xml).' }

    # 2) + 3) import the button macro, export the result
    $macroName = New-VlcButtonLayout $buttons $Kind $info
    $script = "version `"7.0`"`r`nMACRO END_ON_ERROR ( `"Off`" )`r`nDECLARE vSt `"`"`r`nDECLARE vErr `"`"`r`nDECLARE vSt2 `"`"`r`nDECLARE vErr2 `"`"`r`n" +
        "WINDOW VISUAL_LAYOUT IMPORT_MACRO_SCRIPTS FROM_LAYOUT ( `"$buttons`" )`r`nMACRO GET_ERROR_STATUS ( vSt, vErr )`r`n" +
        "WINDOW VISUAL_LAYOUT EXPORT ( `"$exported`" )`r`nMACRO GET_ERROR_STATUS ( vSt2, vErr2 )`r`n"
    $r = Invoke-VlcInspectorScript $insp $script @('vSt', 'vErr', 'vSt2', 'vErr2')
    if ($r.vSt -ne 'No Error') { throw "PolyWorks could not import the button: $($r.vErr)" }
    if ($r.vSt2 -ne 'No Error' -or -not (Test-Path -LiteralPath $exported)) { throw "The PolyWorks visual layout could not be read: $($r.vErr2)" }

    # 4) the button control PolyWorks created (with its icon), moved into a "VL Connector" ribbon tab
    $xml = Read-ZipText $exported 'layout.xml'
    $esc = [regex]::Escape($macroName)
    $ctl = [regex]::Match($xml, '<Control Class="CIMXtControlButtonMacro"[^>]*resString="' + $esc + '".*?</Control>', 'Singleline')
    if (-not $ctl.Success) { throw 'PolyWorks did not create the button (layout format unknown). Add it by hand, see the User Guide.' }
    $caption = @{ Measure = 'Measure'; Station = 'VL Station' }[$Kind]
    $control = $ctl.Value -replace ('Caption="' + $esc + '"'), ('Caption="' + $caption + '"')
    # the hidden toolbars that the import created ("Macros from ...") are not needed
    $xml = [regex]::Replace($xml, '<CommandBar Class="CIMXtToolBar"[^>]*Title="Macros from VL Connector buttons[^"]*".*?</CommandBar>', '', 'Singleline')
    # an older VL Connector tab is replaced
    $xml = [regex]::Replace($xml, '<Tab Class="CIMXtRibbonTab" Caption="VL Connector".*?</Tab>', '', 'Singleline')
    $tab = '<Tab Class="CIMXtRibbonTab" Caption="VL Connector" tabType="2"><Groups><Group Class="CIMXtRibbonGroup" Caption="VL Connector" groupType="2"><Controls>' +
        $control + '</Controls><ControlGroupOption Flags="16" HideFlags="129" Width="0" Height="0"/><ControlGroupPopup Type="3" Id="0" Flags="24" HideFlags="128" Caption="VL Connector" Width="0" Height="0"/></Group></Groups></Tab>'
    $anchor = [regex]::Matches($xml, '<Tab Class="CIMXtRibbonTab" Caption="[^"]*" tabType="2">.*?</Tab>', 'Singleline') | Select-Object -Last 1
    if (-not $anchor) { $anchor = [regex]::Match($xml, '<Tab Class="CIMXtRibbonTab" Caption="Help".*?</Tab>', 'Singleline') }
    if (-not $anchor -or -not $anchor.Success) { throw 'The ribbon of this PolyWorks version has an unknown format. Add the button by hand, see the User Guide.' }
    $xml = $xml.Insert($anchor.Index + $anchor.Length, $tab)
    Write-LayoutWithXml $exported $final $xml

    # 5) load it and check
    $check = Join-Path $work "check_$stamp"
    $script = "version `"7.0`"`r`nMACRO END_ON_ERROR ( `"Off`" )`r`nDECLARE vSt `"`"`r`nDECLARE vErr `"`"`r`n" +
        "WINDOW VISUAL_LAYOUT LOAD ( `"$final`", `"Off`" )`r`nMACRO GET_ERROR_STATUS ( vSt, vErr )`r`nWINDOW VISUAL_LAYOUT EXPORT ( `"$check`" )`r`n"
    $r = Invoke-VlcInspectorScript $insp $script @('vSt', 'vErr')
    $ok = $false
    if ($r.vSt -eq 'No Error' -and (Test-Path -LiteralPath $check)) {
        $ok = [regex]::IsMatch((Read-ZipText $check 'layout.xml'), ('Caption="VL Connector" tabType="2"><Groups>.*?resString="' + $esc + '"'), 'Singleline')
    }
    if (-not $ok) {
        [void](Invoke-VlcInspectorScript $insp ("version `"7.0`"`r`nWINDOW VISUAL_LAYOUT LOAD ( `"$backup`", `"Off`" )`r`n") @())
        throw "PolyWorks did not take the new ribbon tab ($($r.vErr)); the previous layout was loaded back."
    }
    foreach ($f in $exported, $final, $check, $buttons) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    return $backup
}

# Loads the layout backup made by Install-VlcPolyWorksTab back into the open PolyWorks|Inspector.
function Restore-VlcPolyWorksLayout([string]$Backup) {
    $insp = Get-VlcRunningInspector
    if (-not $insp) { throw 'Open PolyWorks|Inspector first, then try again.' }
    if (-not (Test-Path -LiteralPath $Backup)) { throw "The layout backup $Backup was not found." }
    $r = Invoke-VlcInspectorScript $insp ("version `"7.0`"`r`nMACRO END_ON_ERROR ( `"Off`" )`r`nDECLARE vSt `"`"`r`nDECLARE vErr `"`"`r`nWINDOW VISUAL_LAYOUT LOAD ( `"$Backup`", `"Off`" )`r`nMACRO GET_ERROR_STATUS ( vSt, vErr )`r`n") @('vSt', 'vErr')
    if ($r.vSt -ne 'No Error') { throw "PolyWorks could not load the backup: $($r.vErr)" }
}

function Get-VlcLayoutBackups {
    return @(Get-ChildItem -LiteralPath (Get-VlcLayoutWorkDir) -Filter 'backup_*' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
}
