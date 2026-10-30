// VL Connector for PolyWorks - the status file of a running scan (<marker>.status), read by the PolyWorks Measure
// macro and the agent. It is written at once when the step changes and again every few seconds with a growing
// BEAT, so a caller sees that the launcher is still alive even while it waits for VL. Line order is fixed:
// STEP, TEXT, VLMESSAGE, UPDATED, BEAT (UTF-8 with BOM, written under a temporary name and swapped in).
// A write that fails (a caller reads the file at that moment) is repeated at the next beat.
namespace VLConnector.Interop
{
    using System;
    using System.Globalization;
    using System.IO;
    using System.Text;
    using System.Threading;

    public sealed class StatusFile : IDisposable
    {
        readonly string path;
        readonly object gate = new object();
        readonly Timer timer;
        string step = "", text = "", vlMessage = "";
        long beat;
        bool disposed;

        public StatusFile(string path, int intervalMs)
        {
            this.path = path;
            timer = new Timer(delegate { lock (gate) { if (!disposed) { beat++; Write(); } } }, null, intervalMs, intervalMs);
        }

        public long Beat { get { lock (gate) { return beat; } } }

        public void Set(string step, string text, string vlMessage)
        {
            lock (gate)
            {
                this.step = step ?? ""; this.text = text ?? ""; this.vlMessage = vlMessage ?? "";
                if (!disposed) Write();
            }
        }

        // the PolyWorks macro reads a line up to the next '=': values stay on one line and '=' becomes '-'
        static string Safe(string value)
        {
            return value.Replace("\r", " ").Replace("\n", " ").Replace('=', '-').Trim();
        }

        void Write()
        {
            string temp = path + ".part";
            try
            {
                string content = "STEP=" + Safe(step) + "\r\nTEXT=" + Safe(text) + "\r\nVLMESSAGE=" + Safe(vlMessage) +
                    "\r\nUPDATED=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture) + "\r\nBEAT=" + beat + "\r\n";
                File.WriteAllText(temp, content, new UTF8Encoding(true));
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
            }
            catch { try { File.Delete(temp); } catch { } }
        }

        public void Dispose()
        {
            lock (gate) { disposed = true; }
            timer.Dispose();
        }
    }
}
