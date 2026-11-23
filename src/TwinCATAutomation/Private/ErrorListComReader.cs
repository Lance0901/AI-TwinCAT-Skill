// Reads DTE2.ToolWindows.ErrorList.ErrorItems with EARLY binding (item 88, re #320 / #329 / #300).
//
// Why C#: from PowerShell (late binding through the IDispatch adapter) ErrorItems.Count reads back a
// fake 0 (measured 2026-11-23, VS2022 17 + XAE, PowerShell 5.1): that is where the old statement "ErrorItems
// is always 0" came from. The same properties read through the EnvDTE80 interfaces return the full list
// (VS2022 4026, XAE 64-bit 4026, XAE 32-bit TcXaeShell 15.0: same row counts as the UI Automation scan;
// 529 rows in 0.96 s), without showing the Error List window or taking the foreground.
// InfoSys / MSDN: ErrorItems is 1-based (https://learn.microsoft.com/en-us/dotnet/api/envdte80.erroritems).
//
// The helper only reads and sets the three Show* flags (restored in finally). It never executes a DTE
// command and never touches the window. Compiled once per process by Initialize-TcErrorListComTypes
// (Add-Type against the IDE's PublicAssemblies\EnvDTE.dll / EnvDTE80.dll; C# 5 compatible).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using EnvDTE;
using EnvDTE80;

namespace TcAutomation
{
    public sealed class ErrorListComRow
    {
        public int Level;
        public string Description;
        public string FileName;
        public int Line;
        public int Column;
        public string Project;
    }

    public sealed class ErrorListComResult
    {
        public bool Ok;
        public string Reason;        // short machine reason when !Ok (e.g. 'flags-not-set', 'timeout', 'com-error')
        public string Error;         // exception text when Reason == 'com-error'
        public int HResult;          // COMException HResult (0 when none)
        public string Caption;       // Window.Caption of the Error List window, null when the window was not found
        public bool[] FlagsBefore = new bool[3];   // ShowErrors / ShowWarnings / ShowMessages before
        public bool FlagsRestored;
        public bool Isolated;        // severities read one flag at a time
        public int AllCount;         // ErrorItems.Count with all three flags on
        public List<ErrorListComRow> All = new List<ErrorListComRow>();        // all flags on (rows of the level-mapped read; empty when Isolated)
        public List<ErrorListComRow> Errors = new List<ErrorListComRow>();     // Isolated: ShowErrors only
        public List<ErrorListComRow> Warnings = new List<ErrorListComRow>();   // Isolated: ShowWarnings only
        public List<ErrorListComRow> Messages = new List<ErrorListComRow>();   // Isolated: ShowMessages only
        public double Ms;
    }

    public static class ErrorListComReader
    {
        const string ErrorListGuid = "{D78612C7-9962-4B83-95D9-268046DAD23A}";

        sealed class Budget
        {
            readonly Stopwatch sw = Stopwatch.StartNew();
            readonly int maxMs;
            public Budget(int maxMs) { this.maxMs = maxMs; }
            public bool Over { get { return sw.ElapsedMilliseconds > maxMs; } }
        }

        sealed class ReasonException : Exception
        {
            public readonly string Reason;
            public ReasonException(string reason) : base(reason) { Reason = reason; }
        }

        static string CaptionOf(DTE2 dte)
        {
            // enumerate by index: Windows.Item(guid) is not needed, ToolWindows.ErrorList already created the window
            try
            {
                int n = dte.Windows.Count;
                for (int i = 1; i <= n; i++)
                {
                    try
                    {
                        Window w = dte.Windows.Item(i);
                        string kind = w.ObjectKind;
                        if (kind != null && kind.ToUpperInvariant() == ErrorListGuid) return w.Caption;
                    }
                    catch (COMException) { }
                }
            }
            catch (COMException) { }
            return null;
        }

        static void SetFlags(ErrorList el, bool e, bool w, bool m)
        {
            // order: switch ON first, OFF last, so the list is never empty by our own doing
            if (e) el.ShowErrors = true;
            if (w) el.ShowWarnings = true;
            if (m) el.ShowMessages = true;
            if (!e) el.ShowErrors = false;
            if (!w) el.ShowWarnings = false;
            if (!m) el.ShowMessages = false;
            if (el.ShowErrors != e || el.ShowWarnings != w || el.ShowMessages != m) throw new ReasonException("flags-not-set");
        }

        // Count settles a moment after the flags changed: poll until two reads, settleMs apart, agree.
        static int StableCount(ErrorList el, int settleMs, Budget b)
        {
            int prev = -1;
            while (true)
            {
                int c = el.ErrorItems.Count;
                if (c == prev) return c;
                prev = c;
                if (b.Over) throw new ReasonException("timeout");
                System.Threading.Thread.Sleep(settleMs);
            }
        }

        static List<ErrorListComRow> ReadRows(ErrorList el, int expected, Budget b)
        {
            ErrorItems items = el.ErrorItems;
            int count = items.Count;
            if (count != expected) throw new ReasonException("count-changed");
            var rows = new List<ErrorListComRow>(count);
            for (int i = 1; i <= count; i++)   // 1-based, inclusive
            {
                if (b.Over) throw new ReasonException("timeout");
                ErrorItem it = items.Item(i);
                var r = new ErrorListComRow();
                r.Level = (int)it.ErrorLevel;
                r.Description = it.Description;
                r.FileName = it.FileName;
                r.Line = it.Line;
                r.Column = it.Column;
                r.Project = it.Project;
                rows.Add(r);
            }
            // the list must not have changed while it was being read
            if (el.ErrorItems.Count != count) throw new ReasonException("count-changed");
            return rows;
        }

        static List<ErrorListComRow> ReadWithFlags(ErrorList el, bool e, bool w, bool m, int settleMs, Budget b)
        {
            SetFlags(el, e, w, m);
            for (int attempt = 0; attempt < 3; attempt++)
            {
                int c = StableCount(el, settleMs, b);
                try { return ReadRows(el, c, b); }
                catch (ReasonException ex) { if (ex.Reason != "count-changed") throw; }
            }
            throw new ReasonException("count-unstable");
        }

        // dte: the IDE's DTE (any COM object that answers EnvDTE80.DTE2).
        // isolate: read each severity on its own (ShowErrors only / ShowWarnings only / ShowMessages only);
        //   false: one read with all three flags on (the caller classifies by ErrorLevel).
        public static ErrorListComResult Read(object dte, bool isolate, int settleMs, int maxMs)
        {
            var res = new ErrorListComResult();
            var sw = Stopwatch.StartNew();
            var budget = new Budget(maxMs);
            ErrorList el = null;
            bool haveFlags = false;
            try
            {
                DTE2 d = (DTE2)dte;
                el = d.ToolWindows.ErrorList;     // the first access creates the window when it never existed
                if (el == null) { res.Reason = "no-errorlist"; return res; }
                res.Caption = CaptionOf(d);
                res.FlagsBefore[0] = el.ShowErrors;
                res.FlagsBefore[1] = el.ShowWarnings;
                res.FlagsBefore[2] = el.ShowMessages;
                haveFlags = true;

                if (isolate)
                {
                    res.Isolated = true;
                    res.Errors = ReadWithFlags(el, true, false, false, settleMs, budget);
                    res.Warnings = ReadWithFlags(el, false, true, false, settleMs, budget);
                    res.Messages = ReadWithFlags(el, false, false, true, settleMs, budget);
                    SetFlags(el, true, true, true);
                    res.AllCount = StableCount(el, settleMs, budget);
                }
                else
                {
                    res.All = ReadWithFlags(el, true, true, true, settleMs, budget);
                    res.AllCount = res.All.Count;
                }
                res.Ok = true;
            }
            catch (ReasonException ex) { res.Ok = false; res.Reason = ex.Reason; }
            catch (COMException ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.Message; res.HResult = ex.ErrorCode; }
            catch (InvalidCastException ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.Message; res.HResult = ex.HResult; }
            catch (Exception ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.GetType().Name + ": " + ex.Message; res.HResult = ex.HResult; }
            finally
            {
                if (el != null && haveFlags)
                {
                    bool ok = true;
                    try { el.ShowErrors = res.FlagsBefore[0]; } catch (Exception) { ok = false; }
                    try { el.ShowWarnings = res.FlagsBefore[1]; } catch (Exception) { ok = false; }
                    try { el.ShowMessages = res.FlagsBefore[2]; } catch (Exception) { ok = false; }
                    try { ok = ok && el.ShowErrors == res.FlagsBefore[0] && el.ShowWarnings == res.FlagsBefore[1] && el.ShowMessages == res.FlagsBefore[2]; } catch (Exception) { ok = false; }
                    res.FlagsRestored = ok;
                }
                res.Ms = sw.Elapsed.TotalMilliseconds;
            }
            return res;
        }
    }
}
