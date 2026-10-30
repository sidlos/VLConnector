// VL Connector for PolyWorks - Windows interfaces used to drive the VL Application.
// The installer compiles app\interop\*.cs once into bin\VLConnector.Interop.dll (lib\Interop.ps1), so no
// compiler runs while VL Connector is used. docs\IT-Review.md lists every call and why it is needed:
//   - EnumWindows / GetWindowText / GetClassName: find the VL windows and dialogs.
//   - SendMessageTimeout WM_GETTEXT / WM_SETTEXT: read message texts, enter a path in a file dialog.
//   - PostMessage BM_CLICK / WM_CLOSE: press a dialog button, close a window.
//   - WM_GETCONTROLNAME + VirtualAllocEx / ReadProcessMemory / VirtualFreeEx: VL writes the WinForms control
//     name (e.g. "_replayScanButton") of one of its windows into a 1 KB buffer allocated in VL's process,
//     which is read back and freed. The process is opened with memory-operation and read rights only
//     (0x0018); nothing else is written into VL's memory and no code runs in VL.
//   - mouse_event with a 0-pixel move, AttachThreadInput, SetForegroundWindow, ShowWindow: bring a window
//     to the front or minimize it (Windows lets only the process with the last input do that).
//   - OpenInputDesktop / SwitchDesktop, WTSGetActiveConsoleSessionId, ProcessIdToSessionId,
//     GetSystemMetrics(SM_REMOTESESSION): is somebody at this PC (not locked, console, not remote)?
//   - GetWindowRect, Get/SetWindowLong(Ptr) with WS_EX_NOACTIVATE: place the stage warning window next to
//     VL's question and keep it from ever taking the keyboard focus.
namespace VLConnector.Interop
{
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
        [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
        [DllImport("user32.dll")] static extern bool SwitchDesktop(IntPtr desktop);
        [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
        [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();
        [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr64(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr64(IntPtr h, int index, IntPtr value);
        [DllImport("user32.dll", EntryPoint = "GetWindowLong")] static extern int GetWindowLong32(IntPtr h, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLong")] static extern int SetWindowLong32(IntPtr h, int index, int value);

        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

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

        // Process that owns a window (0 when the window is gone).
        public static int ProcessOf(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return (int)p; }

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

        // Tells the dialog that the selection of a combo box changed (WM_COMMAND with CBN_SELCHANGE), as a
        // user's choice would; CB_SETCURSEL alone does not notify the dialog.
        public static void NotifySelectionChanged(IntPtr combo)
        {
            IntPtr parent = GetParent(combo);
            if (parent == IntPtr.Zero) return;
            int id = GetDlgCtrlID(combo);
            IntPtr r;
            SendMessageTimeout(parent, 0x0111, (IntPtr)((1 << 16) | (id & 0xFFFF)), combo, SMTO_ABORTIFHUNG, 3000, out r);
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
                if (!ReadProcessMemory(proc, mem, b, 1024, out read)) return "";
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

        // Brings a window to the front. Windows lets a window come to the foreground only for the process with
        // the last input; with attach, a mouse move by 0 px and joining the input of the window in front
        // satisfy that. The caller allows attach only when the window in front belongs to VL, PolyWorks or
        // VL Connector itself, never to another application the operator is using.
        public static bool BringToFront(IntPtr hwnd, bool attach)
        {
            if (IsIconic(hwnd)) ShowWindow(hwnd, 9);
            IntPtr fg = GetForegroundWindow();
            if (fg == hwnd) return true;
            if (!attach) return SetForegroundWindow(hwnd);
            mouse_event(0x1, 0, 0, 0, UIntPtr.Zero);
            uint ignored;
            uint fgThread = GetWindowThreadProcessId(fg, out ignored);
            uint me = GetCurrentThreadId();
            bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
            try { return SetForegroundWindow(hwnd); }
            finally { if (attached) AttachThreadInput(me, fgThread, false); }
        }

        public static void Minimize(IntPtr hwnd) { ShowWindow(hwnd, 6); }

        // Window position in screen pixels: left, top, right, bottom (empty when the window is gone).
        public static int[] Rect(IntPtr h)
        {
            RECT r;
            if (!GetWindowRect(h, out r)) return new int[0];
            return new int[] { r.Left, r.Top, r.Right, r.Bottom };
        }

        // The stage warning window: never activated (not by showing it, not by a click), no taskbar button.
        public static void SetNoActivate(IntPtr h)
        {
            const int GWL_EXSTYLE = -20;
            const long WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;
            if (IntPtr.Size == 8) SetWindowLongPtr64(h, GWL_EXSTYLE, new IntPtr(GetWindowLongPtr64(h, GWL_EXSTYLE).ToInt64() | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW));
            else SetWindowLong32(h, GWL_EXSTYLE, (int)(GetWindowLong32(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW));
        }

        // Invoke on a menu item that opens a modal dialog returns only after the dialog closes,
        // so it runs on its own thread.
        public static void InvokeAsync(AutomationElement e)
        {
            var t = new Thread(delegate() { try { ((InvokePattern)e.GetCurrentPattern(InvokePattern.Pattern)).Invoke(); } catch { } });
            t.IsBackground = true;
            t.Start();
        }

        // --- Is somebody at this PC? (automatic confirmation of the stage rotation) ---------------------

        // False while the desktop is locked or a secure screen saver runs (the input desktop then belongs to
        // Winlogon and cannot be switched to).
        public static bool InputDesktopActive()
        {
            IntPtr d = OpenInputDesktop(0, false, 0x0100);
            if (d == IntPtr.Zero) return false;
            try { return SwitchDesktop(d); }
            finally { CloseDesktop(d); }
        }

        public static int ActiveConsoleSession() { return unchecked((int)WTSGetActiveConsoleSessionId()); }

        public static int SessionOf(int pid) { uint s; return ProcessIdToSessionId((uint)pid, out s) ? (int)s : -1; }

        public static bool IsRemoteSession() { return GetSystemMetrics(0x1000) != 0; }
    }
}
