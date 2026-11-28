// The algorithm of the COM Error List read (item 88, review #332 S1 / S3 / S7), independent of EnvDTE: it works on an
// IErrorListSource. ErrorListComReader.cs adapts the IDE's DTE2 to it; tests/Unit/errorlist-com-item88.ps1 compiles this
// file alone and drives it with a fake source (flag restore, busy retry, lagging Count, window not created).
// C# 5 compatible (Add-Type in Windows PowerShell 5.1).
//
// Every read is isolated: one severity per read (ShowErrors only / ShowWarnings only / ShowMessages only), each one
// preceded by an "all three off" step that must show Count = 0 (S3: a Count that has not followed the flag change yet
// would show the previous list; errors and warnings could swap and still add up).
//
// Speed (review of the real-machine report of PR #332, item 2): the first version needed 4.7-5.5 s for 32 rows and 7.0 s for
// 200 rows (VS2022 / XAE 4026, 2026-11-23). What changed: flags are only written when the readback differs (the first
// version wrote all three on every step, about 27 writes per read), the final all-off step before the all-on count is gone
// (the isolation sum check covers it), warnings / messages rows are only fetched when the caller wants them (their COUNT
// still enters the sum check), the per-row ErrorItem reads are Description / FileName / Line / Project (Column is a
// constant 1 and never used, ErrorLevel only where the host has a level table). The time of every kind of call is
// measured in ErrorListComResult.Timing, so the next real-machine run shows where the rest goes.
//
// Where the time goes (measured 2026-11-28, VS2022 17 + XAE 4026, IDE launched hidden, 215 rows, PR #332 round 4 preparation):
// ErrorItems.Count costs 0 ms and getting ErrorItems 5 ms while the flags stay as they are. The first ErrorItems.Count after a
// Show* flag write takes 400-550 ms: the IDE refilters the list then (the write itself is 0-16 ms, sometimes 500 ms when the
// previous refilter is still running), and that first Count already has the new value. A cached ErrorItems object is a snapshot
// (its Count never follows a flag change). So the read time is the number of flag changes, not the number of Count calls:
// Timing reports them as refilters / refilterMs. What this version saves: the Count before the rows (the stable count already
// fetched that ErrorItems), and, when the user has all three buttons on, the final all-on step (the all-on count is read first,
// before any flag is changed, and the restore puts the flags back anyway).
// Rows read before a timeout stay in the result (Partial = true): never an empty list that hides what was read.
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
        public int Column;           // not read (constant 1 on every row, measured 2026-11-23); stays 0
        public string Project;
    }

    public sealed class ErrorListComOptions
    {
        public int SettleMs = 100;        // poll interval of the Count checks
        public int MaxMs = 7500;          // budget of the fixed work (flags, polls)
        public int CapMs = 0;             // hard cap incl. the per-row extension; 0 = MaxMs (no extension)
        public int PerRowMs = 15;         // budget added per row that is fetched (measured about 12 ms per row, 2026-11-23)
        public bool FetchWarnings = true; // false: warnings are only counted (the count still enters the isolation sum)
        public bool FetchMessages = true; // false: messages are only counted
        public bool ReadLevel = true;     // false: ErrorItem.ErrorLevel is not read (Level = 0); true for hosts with a level table
    }

    public sealed class ErrorListComResult
    {
        public bool Ok;
        public string Reason;        // short machine reason when !Ok ('errorlist-create-failed', 'flags-not-set', 'flags-not-effective', 'timeout', 'com-error', ...)
        public string Error;         // exception text when Reason == 'com-error'
        public int HResult;          // COMException HResult (0 when none)
        public string Caption;       // Window.Caption of the Error List window
        public bool Created;         // the Error List window did not exist and this read created it (Lance S7: hidden tab allowed)
        public bool HiddenRestored;  // true when nothing was created, or the created window is hidden / auto-hidden again (read back)
        public bool[] FlagsBefore = new bool[3];   // ShowErrors / ShowWarnings / ShowMessages before the first change
        public bool FlagsRead;       // FlagsBefore holds the user's flags (read here, or passed in by a retry)
        public bool FlagsChanged;    // the first flag change was attempted: the finally block had to restore
        public bool FlagsRestored;   // true when nothing was changed, or the readback equals FlagsBefore
        public bool FlagsMatchBefore;// FlagsAfter (read independently after the restore, twice) equals FlagsBefore
        public bool[] FlagsAfter = new bool[3];    // what the buttons read after the restore (valid when FlagsRead && FlagsChanged)
        public string RestoreNote;   // before / after text when the restore did not read back equal
        public int AllCount;         // ErrorItems.Count with all three flags on
        public int ErrorCount;       // stable ErrorItems.Count under ShowErrors only (-1 = not reached)
        public int WarningCount;     // same for ShowWarnings only
        public int MessageCount;     // same for ShowMessages only
        public bool Partial;         // !Ok but rows were read: Errors / Warnings / Messages hold the rows read so far
        public bool ErrorsComplete;  // every error row was fetched
        public bool WarningsComplete;// every warning row was fetched, or warnings were not asked for (counted only)
        public bool MessagesComplete;// same for messages
        public int BudgetMs;         // budget at the end (MaxMs plus the per-row extension)
        public string Timing;        // 'flagSets=12 flagSetMs=... counts=.. countMs=.. rows=.. rowMs=.. sleepMs=.. (ms)'
        public List<ErrorListComRow> Errors = new List<ErrorListComRow>();     // ShowErrors only
        public List<ErrorListComRow> Warnings = new List<ErrorListComRow>();   // ShowWarnings only
        public List<ErrorListComRow> Messages = new List<ErrorListComRow>();   // ShowMessages only
        public double Ms;
    }

    // Index 0 = Errors, 1 = Warnings, 2 = Messages. Every method may throw COMException.
    public interface IErrorListSource : IDisposable
    {
        // The Error List window if it already exists; false when it does not
        bool Open(out string caption);
        // Creates the Error List window (ToolWindows.ErrorList) WITHOUT Activate / SetFocus / making it visible
        // (S7, Lance: "允許建隱藏分頁,換背景也讀得到"); false when it cannot be created or found afterwards
        bool Create(out string caption);
        // Puts a window that Create made back to hidden / auto-hidden. true only when the readback shows it hidden or
        // auto-hidden (or no window exists); false when it could not be done (reported as is, never assumed)
        bool RestoreHidden();
        bool GetFlag(int index);
        void SetFlag(int index, bool value);
        // ErrorItems.Count; a fresh read of the list, RowAt(1..count) belong to the last Count()
        int Count();
        // withLevel = false: ErrorLevel is not read (one RPC less per row)
        ErrorListComRow RowAt(int index1, bool withLevel);
    }

    // Measures every kind of source call (flag writes, Count, row reads, sleeps) of one Run; the PowerShell result carries it
    // as comRead.timing so a real-machine run shows where the time goes (the first version had no such numbers).
    sealed class TimedSource
    {
        readonly IErrorListSource s;
        public int FlagSets, Counts, Rows, Sleeps, Refilters;
        public long FlagSetMs, CountMs, RowMs, SleepMs, RefilterMs;
        bool dirty;   // a flag was written since the last Count: the next Count pays the refilter
        public TimedSource(IErrorListSource source) { s = source; }
        public bool GetFlag(int i) { return s.GetFlag(i); }
        public void SetFlag(int i, bool v)
        {
            var sw = Stopwatch.StartNew();
            try { s.SetFlag(i, v); }
            finally { FlagSets++; FlagSetMs += sw.ElapsedMilliseconds; dirty = true; }
        }
        public int Count()
        {
            var sw = Stopwatch.StartNew();
            try { return s.Count(); }
            finally
            {
                long ms = sw.ElapsedMilliseconds;
                Counts++; CountMs += ms;
                if (dirty) { Refilters++; RefilterMs += ms; dirty = false; }
            }
        }
        public ErrorListComRow RowAt(int i, bool withLevel)
        {
            var sw = Stopwatch.StartNew();
            try { return s.RowAt(i, withLevel); }
            finally { Rows++; RowMs += sw.ElapsedMilliseconds; }
        }
        public void Sleep(int ms)
        {
            Sleeps++; SleepMs += ms;
            System.Threading.Thread.Sleep(ms);
        }
        public string Text()
        {
            return "flagSets=" + FlagSets + " flagSetMs=" + FlagSetMs + " counts=" + Counts + " countMs=" + CountMs
                + " refilters=" + Refilters + " refilterMs=" + RefilterMs
                + " rows=" + Rows + " rowMs=" + RowMs + " sleeps=" + Sleeps + " sleepMs=" + SleepMs;
        }
    }

    public static class ErrorListComCore
    {
        sealed class Budget
        {
            readonly Stopwatch sw = Stopwatch.StartNew();
            long limit;
            readonly long cap;
            public Budget(int maxMs, int capMs) { limit = maxMs; cap = Math.Max(maxMs, capMs); }
            public bool Over { get { return sw.ElapsedMilliseconds > limit; } }
            // rows that are fetched get time of their own, up to the hard cap (the fixed work stays on MaxMs)
            public void Extend(long ms) { limit = Math.Min(cap, limit + Math.Max(0L, ms)); }
            public int Limit { get { return (int)Math.Min((long)int.MaxValue, limit); } }
        }

        sealed class ReasonException : Exception
        {
            public readonly string Reason;
            public ReasonException(string reason) : base(reason) { Reason = reason; }
        }

        // Writes a flag only when the readback differs (a write makes the IDE refilter the list: that is the expensive call),
        // switching ON first, OFF last; then reads all three back and throws flags-not-set when they differ.
        static void SetFlags(TimedSource s, bool e, bool w, bool m)
        {
            bool[] want = new bool[] { e, w, m };
            for (int i = 0; i < 3; i++) if (want[i] && !s.GetFlag(i)) s.SetFlag(i, true);
            for (int i = 0; i < 3; i++) if (!want[i] && s.GetFlag(i)) s.SetFlag(i, false);
            if (s.GetFlag(0) != e || s.GetFlag(1) != w || s.GetFlag(2) != m) throw new ReasonException("flags-not-set");
        }

        static bool Same(bool[] a, bool[] b)
        {
            return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
        }

        // All three flags off, then wait until the list shows Count = 0: proof that the flag change reached the list.
        static void ZeroBaseline(TimedSource s, int settleMs, Budget b)
        {
            SetFlags(s, false, false, false);
            while (s.Count() != 0)
            {
                if (b.Over) throw new ReasonException("flags-not-effective");
                s.Sleep(settleMs);
            }
        }

        // Count settles a moment after the flags changed: poll until two reads, settleMs apart, agree.
        static int StableCount(TimedSource s, int settleMs, Budget b)
        {
            int prev = -1;
            while (true)
            {
                int c = s.Count();
                if (c == prev) return c;
                prev = c;
                if (b.Over) throw new ReasonException("timeout");
                s.Sleep(settleMs);
            }
        }

        // Rows go into 'into' as they are read: a timeout leaves what was read in the list (Partial), it is not thrown away.
        // The rows belong to the ErrorItems of the last Count (StableCount just read it twice equal): no Count before the rows.
        static void ReadRows(TimedSource s, int count, List<ErrorListComRow> into, ErrorListComOptions o, Budget b)
        {
            b.Extend((long)count * o.PerRowMs);
            for (int i = 1; i <= count; i++)   // 1-based, inclusive
            {
                if (b.Over) throw new ReasonException("timeout");
                into.Add(s.RowAt(i, o.ReadLevel));
            }
            // the list must not have changed while it was being read
            if (s.Count() != count) throw new ReasonException("count-changed");
        }

        // Returns the stable count under the given flags; fetches the rows only when 'fetch' (otherwise they are only counted:
        // the count still enters the isolation sum check).
        static int ReadWithFlags(TimedSource s, bool e, bool w, bool m, bool fetch, List<ErrorListComRow> into, ErrorListComOptions o, Budget b)
        {
            ZeroBaseline(s, o.SettleMs, b);
            SetFlags(s, e, w, m);
            for (int attempt = 0; attempt < 3; attempt++)
            {
                int c = StableCount(s, o.SettleMs, b);
                if (!fetch) return c;
                into.Clear();
                try { ReadRows(s, c, into, o, b); return c; }
                catch (ReasonException ex) { if (ex.Reason != "count-changed") throw; }
            }
            throw new ReasonException("count-unstable");
        }

        public static ErrorListComResult Run(IErrorListSource source, int settleMs, int maxMs, bool[] originalFlags)
        {
            var o = new ErrorListComOptions();
            o.SettleMs = settleMs;
            o.MaxMs = maxMs;
            return Run(source, o, originalFlags);
        }

        // originalFlags: null on the first call. A retry (the caller got RPC_E_CALL_REJECTED) passes the flags of the
        //   FIRST call, so the user's view is never read from a state this helper changed (review #332 S1).
        public static ErrorListComResult Run(IErrorListSource source, ErrorListComOptions o, bool[] originalFlags)
        {
            var res = new ErrorListComResult();
            res.FlagsRestored = true;   // nothing is changed until the first flag change
            res.FlagsMatchBefore = true;
            res.HiddenRestored = true;  // nothing is created until Create
            res.ErrorCount = -1; res.WarningCount = -1; res.MessageCount = -1;
            bool createAttempted = false;
            var s = new TimedSource(source);
            var sw = Stopwatch.StartNew();
            var budget = new Budget(o.MaxMs, o.CapMs);
            try
            {
                string caption;
                if (!source.Open(out caption))
                {
                    // S7 (Lance: hidden tab allowed): create it, never Activate / SetFocus; hidden again in finally
                    createAttempted = true;
                    res.HiddenRestored = false;   // until the readback says otherwise
                    if (!source.Create(out caption)) { res.Reason = "errorlist-create-failed"; return res; }
                    res.Created = true;
                }
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

                // all three on already (the default view): the all-on count is read now, before any change, and the final all-on
                // step is left out (the restore sets the same flags). Otherwise it is read at the end as before.
                bool allOnBefore = res.FlagsBefore[0] && res.FlagsBefore[1] && res.FlagsBefore[2];
                if (allOnBefore) res.AllCount = StableCount(s, o.SettleMs, budget);

                res.FlagsChanged = true;
                res.ErrorCount = ReadWithFlags(s, true, false, false, true, res.Errors, o, budget);
                res.ErrorsComplete = true;
                res.WarningCount = ReadWithFlags(s, false, true, false, o.FetchWarnings, res.Warnings, o, budget);
                res.WarningsComplete = true;
                res.MessageCount = ReadWithFlags(s, false, false, true, o.FetchMessages, res.Messages, o, budget);
                res.MessagesComplete = true;
                // no all-off step here: the sum of the three isolated counts must equal this count (checked by the caller)
                if (!allOnBefore)
                {
                    SetFlags(s, true, true, true);
                    res.AllCount = StableCount(s, o.SettleMs, budget);
                }
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
                    bool applied = false;
                    for (int attempt = 0; attempt < 3 && !applied; attempt++)
                    {
                        try
                        {
                            SetFlags(s, res.FlagsBefore[0], res.FlagsBefore[1], res.FlagsBefore[2]);
                            applied = true;
                        }
                        catch (Exception) { s.Sleep(200); }
                    }
                    // PR #332 real-machine report item 5: a restore is proven by its own readback, not by the writes not throwing.
                    // Read the three buttons again, wait one settle interval and read them again: both reads must equal what the
                    // user had (a button that jumps back after the write is caught by the second read).
                    bool match = false;
                    try
                    {
                        bool[] a = new bool[] { s.GetFlag(0), s.GetFlag(1), s.GetFlag(2) };
                        match = Same(a, res.FlagsBefore);
                        if (match)
                        {
                            s.Sleep(o.SettleMs);
                            a = new bool[] { s.GetFlag(0), s.GetFlag(1), s.GetFlag(2) };
                            match = Same(a, res.FlagsBefore);
                        }
                        res.FlagsAfter = a;
                    }
                    catch (Exception) { match = false; }
                    res.FlagsMatchBefore = match;
                    res.FlagsRestored = applied && match;
                    if (!res.FlagsRestored)
                    {
                        res.RestoreNote = "Errors / Warnings / Messages buttons before the read = "
                            + res.FlagsBefore[0] + "/" + res.FlagsBefore[1] + "/" + res.FlagsBefore[2]
                            + ", after the restore = " + res.FlagsAfter[0] + "/" + res.FlagsAfter[1] + "/" + res.FlagsAfter[2]
                            + (applied ? "" : " (the write did not complete)");
                    }
                }
                if (createAttempted)
                {
                    // after the flags are back: hide what this read created; the readback decides, never the call
                    bool hidden = false;
                    for (int attempt = 0; attempt < 3 && !hidden; attempt++)
                    {
                        try { hidden = source.RestoreHidden(); }
                        catch (Exception) { }
                        if (!hidden) s.Sleep(200);
                    }
                    res.HiddenRestored = hidden;
                }
                res.Partial = !res.Ok && (res.Errors.Count + res.Warnings.Count + res.Messages.Count) > 0;
                res.BudgetMs = budget.Limit;
                res.Timing = s.Text();
                res.Ms = sw.Elapsed.TotalMilliseconds;
            }
            return res;
        }
    }
}
