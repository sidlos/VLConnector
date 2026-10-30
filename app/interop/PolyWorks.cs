// VL Connector for PolyWorks - the PolyWorks programming interface (from the PolyWorks SDK). Only these calls
// are used: find the running PolyWorks|Inspector, create a command center in it and run a macro script text
// ("Add to PolyWorks" in the setup wizard and the settings window). PolyWorks is never started from here.
namespace VLConnector.Interop
{
    using System;
    using System.Runtime.InteropServices;

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
}
