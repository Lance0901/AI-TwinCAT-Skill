// Reads DTE2.ToolWindows.ErrorList.ErrorItems with EARLY binding (item 88, re #320 / #329 / #300).
//
// Why C#: from PowerShell (late binding through the IDispatch adapter) ErrorItems.Count reads back a
// fake 0 (measured 2026-11-23, VS2022 17 + XAE, PowerShell 5.1): that is where the old statement "ErrorItems
// is always 0" came from. The same properties read through the EnvDTE80 interfaces return the full list
// (VS2022 4026, XAE 64-bit 4026, XAE 32-bit TcXaeShell 15.0: same row counts as the UI Automation scan;
// 529 rows in 0.96 s), without showing the Error List window or taking the foreground.
// InfoSys / MSDN: ErrorItems is 1-based (https://learn.microsoft.com/en-us/dotnet/api/envdte80.erroritems).
//
// This file only adapts the IDE's DTE2 to IErrorListSource; the algorithm (flags, baseline, restore, deadline) is in
// ErrorListComCore.cs. The helper only reads and sets the three Show* flags (restored in finally). It never executes a
// DTE command and never touches the window. Compiled once per process by Initialize-TcErrorListComTypes
// (Add-Type -Path ErrorListComCore.cs, ErrorListComReader.cs against the IDE's PublicAssemblies\EnvDTE.dll / EnvDTE80.dll).
using System;
using System.Runtime.InteropServices;
using EnvDTE;
using EnvDTE80;

namespace TcAutomation
{
    public static class ErrorListComReader
    {
        const string ErrorListGuid = "{D78612C7-9962-4B83-95D9-268046DAD23A}";

        // review #332 N2: every RCW this adapter obtains is released once (Marshal.ReleaseComObject decrements the
        // reference count of that obtain; the DTE passed in by the caller is not ours and is never released)
        static void Release(object o)
        {
            try { if (o != null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o); }
            catch (Exception) { }
        }

        // RPC_E_CALL_REJECTED / RPC_E_SERVERCALL_RETRYLATER (busy), RPC_S_CALL_FAILED / RPC_S_SERVER_UNAVAILABLE /
        // RPC_E_DISCONNECTED (dead): never swallowed, the PowerShell caller retries or classifies them
        static bool IsRpcFailure(int hr)
        {
            uint u = unchecked((uint)hr);
            return u == 0x80010001u || u == 0x8001010Au || u == 0x800706BEu || u == 0x800706BAu || u == 0x80010108u;
        }

        sealed class DteSource : IErrorListSource
        {
            readonly object dteObject;
            Window win;
            ErrorList el;
            ErrorItems items;

            public DteSource(object dte) { dteObject = dte; }

            // Finds the Error List window among the IDE's windows WITHOUT creating it (review #332 S7: the first access to
            // ToolWindows.ErrorList creates the window when it never existed and changes the user's layout).
            public bool Open(out string caption)
            {
                caption = null;
                DTE2 d = (DTE2)dteObject;
                EnvDTE.Windows ws = null;
                try
                {
                    ws = d.Windows;
                    int n = ws.Count;
                    for (int i = 1; i <= n && win == null; i++)
                    {
                        Window w = null;
                        bool keep = false;
                        try
                        {
                            w = ws.Item(i);
                            string kind = w.ObjectKind;
                            if (kind != null && kind.ToUpperInvariant() == ErrorListGuid) { win = w; keep = true; }
                        }
                        catch (COMException ex) { if (IsRpcFailure(ex.ErrorCode)) throw; }
                        finally { if (!keep) Release(w); }
                    }
                }
                finally { Release(ws); }
                if (win == null) return false;
                caption = win.Caption;
                el = d.ToolWindows.ErrorList;     // the window exists: this creates nothing
                return el != null;
            }

            public bool GetFlag(int index)
            {
                if (index == 0) return el.ShowErrors;
                if (index == 1) return el.ShowWarnings;
                return el.ShowMessages;
            }

            public void SetFlag(int index, bool value)
            {
                if (index == 0) el.ShowErrors = value;
                else if (index == 1) el.ShowWarnings = value;
                else el.ShowMessages = value;
            }

            public int Count()
            {
                Release(items);
                items = el.ErrorItems;
                return items.Count;
            }

            public ErrorListComRow RowAt(int index1)
            {
                ErrorItem it = items.Item(index1);
                try
                {
                    var r = new ErrorListComRow();
                    r.Level = (int)it.ErrorLevel;
                    r.Description = it.Description;
                    r.FileName = it.FileName;
                    r.Line = it.Line;
                    r.Column = it.Column;
                    r.Project = it.Project;
                    return r;
                }
                finally { Release(it); }
            }

            public void Dispose()
            {
                Release(items); items = null;
                Release(el); el = null;
                Release(win); win = null;
            }
        }

        // dte: the IDE's DTE (any COM object that answers EnvDTE80.DTE2).
        public static ErrorListComResult Read(object dte, int settleMs, int maxMs, bool[] originalFlags)
        {
            using (var s = new DteSource(dte)) return ErrorListComCore.Run(s, settleMs, maxMs, originalFlags);
        }
    }
}
