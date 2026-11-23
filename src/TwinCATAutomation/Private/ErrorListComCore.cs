// The algorithm of the COM Error List read (item 88, review #332 S1 / S3 / S7), independent of EnvDTE: it works on an
// IErrorListSource. ErrorListComReader.cs adapts the IDE's DTE2 to it; tests/Unit/errorlist-com-item88.ps1 compiles this
// file alone and drives it with a fake source (flag restore, busy retry, lagging Count, window not created).
// C# 5 compatible (Add-Type in Windows PowerShell 5.1).
//
// Every read is isolated: one severity per read (ShowErrors only / ShowWarnings only / ShowMessages only), each one
// preceded by an "all three off" step that must show Count = 0 (S3: a Count that has not followed the flag change yet
// would show the previous list; errors and warnings could swap and still add up).
//
// Deadline (CODING_STANDARDS 1): maxMs is checked BETWEEN source calls (before every row, every poll). One call that
// blocks inside the IDE (modal dialog) cannot be interrupted from here, the same limit as Invoke-TcComRetry; the
// PowerShell caller (Read-TcErrorListCom) runs it inside Invoke-TcComRetry (modal-dialog watchdog, IDE_* classification)
// and under $script:TcComCallDeadline.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

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
        public string Reason;        // short machine reason when !Ok ('errorlist-not-created', 'flags-not-set', 'flags-not-effective', 'timeout', 'com-error', ...)
        public string Error;         // exception text when Reason == 'com-error'
        public int HResult;          // COMException HResult (0 when none)
        public string Caption;       // Window.Caption of the Error List window
        public bool[] FlagsBefore = new bool[3];   // ShowErrors / ShowWarnings / ShowMessages before the first change
        public bool FlagsRead;       // FlagsBefore holds the user's flags (read here, or passed in by a retry)
        public bool FlagsChanged;    // the first flag change was attempted: the finally block had to restore
        public bool FlagsRestored;   // true when nothing was changed, or the readback equals FlagsBefore
        public int AllCount;         // ErrorItems.Count with all three flags on
        public List<ErrorListComRow> Errors = new List<ErrorListComRow>();     // ShowErrors only
        public List<ErrorListComRow> Warnings = new List<ErrorListComRow>();   // ShowWarnings only
        public List<ErrorListComRow> Messages = new List<ErrorListComRow>();   // ShowMessages only
        public double Ms;
    }

    // Index 0 = Errors, 1 = Warnings, 2 = Messages. Every method may throw COMException.
    public interface IErrorListSource : IDisposable
    {
        // The Error List window if it already exists (it is never created: review #332 S7); false when it does not
        bool Open(out string caption);
        bool GetFlag(int index);
        void SetFlag(int index, bool value);
        // ErrorItems.Count; a fresh read of the list, RowAt(1..count) belong to the last Count()
        int Count();
        ErrorListComRow RowAt(int index1);
    }

    public static class ErrorListComCore
    {
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

        static void SetFlags(IErrorListSource s, bool e, bool w, bool m)
        {
            // order: switch ON first, OFF last
            if (e) s.SetFlag(0, true);
            if (w) s.SetFlag(1, true);
            if (m) s.SetFlag(2, true);
            if (!e) s.SetFlag(0, false);
            if (!w) s.SetFlag(1, false);
            if (!m) s.SetFlag(2, false);
            if (s.GetFlag(0) != e || s.GetFlag(1) != w || s.GetFlag(2) != m) throw new ReasonException("flags-not-set");
        }

        // All three flags off, then wait until the list shows Count = 0: proof that the flag change reached the list.
        static void ZeroBaseline(IErrorListSource s, int settleMs, Budget b)
        {
            SetFlags(s, false, false, false);
            while (s.Count() != 0)
            {
                if (b.Over) throw new ReasonException("flags-not-effective");
                System.Threading.Thread.Sleep(settleMs);
            }
        }

        // Count settles a moment after the flags changed: poll until two reads, settleMs apart, agree.
        static int StableCount(IErrorListSource s, int settleMs, Budget b)
        {
            int prev = -1;
            while (true)
            {
                int c = s.Count();
                if (c == prev) return c;
                prev = c;
                if (b.Over) throw new ReasonException("timeout");
                System.Threading.Thread.Sleep(settleMs);
            }
        }

        static List<ErrorListComRow> ReadRows(IErrorListSource s, int expected, Budget b)
        {
            int count = s.Count();
            if (count != expected) throw new ReasonException("count-changed");
            var rows = new List<ErrorListComRow>(count);
            for (int i = 1; i <= count; i++)   // 1-based, inclusive
            {
                if (b.Over) throw new ReasonException("timeout");
                rows.Add(s.RowAt(i));
            }
            // the list must not have changed while it was being read
            if (s.Count() != count) throw new ReasonException("count-changed");
            return rows;
        }

        static List<ErrorListComRow> ReadWithFlags(IErrorListSource s, bool e, bool w, bool m, int settleMs, Budget b)
        {
            ZeroBaseline(s, settleMs, b);
            SetFlags(s, e, w, m);
            for (int attempt = 0; attempt < 3; attempt++)
            {
                int c = StableCount(s, settleMs, b);
                try { return ReadRows(s, c, b); }
                catch (ReasonException ex) { if (ex.Reason != "count-changed") throw; }
            }
            throw new ReasonException("count-unstable");
        }

        // originalFlags: null on the first call. A retry (the caller got RPC_E_CALL_REJECTED) passes the flags of the
        //   FIRST call, so the user's view is never read from a state this helper changed (review #332 S1).
        public static ErrorListComResult Run(IErrorListSource s, int settleMs, int maxMs, bool[] originalFlags)
        {
            var res = new ErrorListComResult();
            res.FlagsRestored = true;   // nothing is changed until the first flag change
            var sw = Stopwatch.StartNew();
            var budget = new Budget(maxMs);
            try
            {
                string caption;
                if (!s.Open(out caption)) { res.Reason = "errorlist-not-created"; return res; }
                res.Caption = caption;
                if (originalFlags != null && originalFlags.Length == 3)
                {
                    res.FlagsBefore[0] = originalFlags[0];
                    res.FlagsBefore[1] = originalFlags[1];
                    res.FlagsBefore[2] = originalFlags[2];
                }
                else
                {
                    res.FlagsBefore[0] = s.GetFlag(0);
                    res.FlagsBefore[1] = s.GetFlag(1);
                    res.FlagsBefore[2] = s.GetFlag(2);
                }
                res.FlagsRead = true;
                res.FlagsRestored = true;   // until the first change

                res.FlagsChanged = true;
                res.Errors = ReadWithFlags(s, true, false, false, settleMs, budget);
                res.Warnings = ReadWithFlags(s, false, true, false, settleMs, budget);
                res.Messages = ReadWithFlags(s, false, false, true, settleMs, budget);
                ZeroBaseline(s, settleMs, budget);
                SetFlags(s, true, true, true);
                res.AllCount = StableCount(s, settleMs, budget);
                res.Ok = true;
            }
            catch (ReasonException ex) { res.Ok = false; res.Reason = ex.Reason; }
            catch (COMException ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.Message; res.HResult = ex.ErrorCode; }
            catch (InvalidCastException ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.Message; res.HResult = ex.HResult; }
            catch (Exception ex) { res.Ok = false; res.Reason = "com-error"; res.Error = ex.GetType().Name + ": " + ex.Message; res.HResult = ex.HResult; }
            finally
            {
                if (res.FlagsRead && res.FlagsChanged)
                {
                    // put the user's flags back: a few tries, the IDE can be busy right after the read
                    bool ok = false;
                    for (int attempt = 0; attempt < 3 && !ok; attempt++)
                    {
                        try
                        {
                            SetFlags(s, res.FlagsBefore[0], res.FlagsBefore[1], res.FlagsBefore[2]);
                            ok = true;
                        }
                        catch (Exception) { System.Threading.Thread.Sleep(200); }
                    }
                    res.FlagsRestored = ok;
                }
                res.Ms = sw.Elapsed.TotalMilliseconds;
            }
            return res;
        }
    }
}
