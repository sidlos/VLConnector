// VL Connector for PolyWorks - a second start of the settings window or the setup wizard brings the open
// one to the front instead of opening another.
namespace VLConnector.Interop
{
    using System;
    using System.Runtime.InteropServices;

    public static class VlcWindow
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

        // Restores and activates the top-level window with exactly this title; false when there is none.
        public static bool Activate(string title)
        {
            IntPtr h = FindWindow(null, title);
            if (h == IntPtr.Zero) return false;
            ShowWindow(h, 9);
            SetForegroundWindow(h);
            return true;
        }
    }
}
