# Windows interfaces used to drive the VL Application. Dot-source this file (it has no param block).
#
# VL is driven only with documented Windows messages and UI Automation, never with mouse or keyboard
# input. What each call is for is explained in docs\IT-Review.md. In short:
#   - EnumWindows / GetWindowText / GetClassName: find the VL windows and dialogs.
#   - SendMessageTimeout WM_GETTEXT / WM_SETTEXT: read message texts, enter a path in a file dialog.
#   - PostMessage BM_CLICK / WM_CLOSE: press a dialog button, close a window.
#   - WM_GETCONTROLNAME + VirtualAllocEx / ReadProcessMemory / VirtualFreeEx: read the WinForms
#     control name (e.g. "_replayScanButton") of a VL window, so the launcher works whatever the
#     VL user interface language is. The process is opened with read and memory-operation rights
#     only (0x0018); nothing is written into VL's memory by this script.
#   - mouse_event with a 0-pixel move, AttachThreadInput, SetForegroundWindow, ShowWindow: bring a
#     window to the front or minimize it (Windows lets only the process with the last input do that).

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('Vl' -as [type])) {
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
    const uint PROCESS_VM_OPERATION = 0x0008;
    const uint PROCESS_VM_READ = 0x0010;
    static readonly uint WM_GETCONTROLNAME = RegisterWindowMessage("WM_GETCONTROLNAME");
    static readonly Dictionary<IntPtr, string> nameCache = new Dictionary<IntPtr, string>();

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
    public static void Click(IntPtr h) { if (h != IntPtr.Zero) PostMessage(h, 0x00F5, IntPtr.Zero, IntPtr.Zero); }
    public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }

    // WinForms control name (Control.Name), independent of the VL user interface language.
    // WinForms writes the name into a buffer in its own process; it is read back from there.
    // Names are cached per window (a window keeps its name for its whole life).
    public static string WinFormsName(IntPtr hwnd)
    {
        string cached;
        lock (nameCache)
        {
            if (nameCache.TryGetValue(hwnd, out cached))
            {
                if (IsWindow(hwnd)) return cached;
                nameCache.Remove(hwnd);
            }
        }
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        IntPtr proc = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ, false, pid);
        if (proc == IntPtr.Zero) return "";
        IntPtr mem = VirtualAllocEx(proc, IntPtr.Zero, 1024, 0x3000, 0x04);
        try
        {
            if (mem == IntPtr.Zero) return "";
            IntPtr r;
            if (SendMessageTimeout(hwnd, WM_GETCONTROLNAME, (IntPtr)512, mem, SMTO_ABORTIFHUNG, 1000, out r) == IntPtr.Zero) return "";
            byte[] b = new byte[1024]; IntPtr read;
            ReadProcessMemory(proc, mem, b, 1024, out read);
            string s = Encoding.Unicode.GetString(b);
            int z = s.IndexOf('\0');
            string name = z >= 0 ? s.Substring(0, z) : s;
            lock (nameCache) { nameCache[hwnd] = name; }
            return name;
        }
        finally { if (mem != IntPtr.Zero) VirtualFreeEx(proc, mem, 0, 0x8000); CloseHandle(proc); }
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
}
