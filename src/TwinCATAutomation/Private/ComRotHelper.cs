using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

/// <summary>
/// C# helper to enumerate all DTE instances from the Running Object Table (ROT).
/// Marshal.GetActiveObject() only returns ONE instance per ProgID.
/// This helper enumerates ALL registered DTE instances so Connect-TcIde can
/// find the correct IDE even when multiple VS2022/XAE Shell are running.
/// </summary>
public static class ComRotHelper
{
    [DllImport("ole32.dll")]
    private static extern int GetRunningObjectTable(uint reserved, out IRunningObjectTable rot);

    [DllImport("ole32.dll")]
    private static extern int CreateBindCtx(uint reserved, out IBindCtx bindCtx);

    /// <summary>
    /// Enumerates the ROT and returns all COM objects whose moniker display name
    /// contains "VisualStudio.DTE" or "TcXaeShell.DTE".
    /// Each result is a Dictionary with keys: "DisplayName" (string) and "Object" (COM object).
    /// </summary>
    public static List<Dictionary<string, object>> GetAllDteInstances()
    {
        var results = new List<Dictionary<string, object>>();

        IRunningObjectTable rot;
        if (GetRunningObjectTable(0, out rot) != 0)
            return results;

        IEnumMoniker enumMoniker;
        rot.EnumRunning(out enumMoniker);
        if (enumMoniker == null)
            return results;

        IBindCtx bindCtx;
        if (CreateBindCtx(0, out bindCtx) != 0)
            return results;

        IMoniker[] monikers = new IMoniker[1];
        IntPtr fetched = IntPtr.Zero;

        while (enumMoniker.Next(1, monikers, fetched) == 0)
        {
            IMoniker moniker = monikers[0];
            if (moniker == null)
                continue;

            try
            {
                string displayName;
                moniker.GetDisplayName(bindCtx, null, out displayName);

                if (displayName == null)
                    continue;

                // DTE instances register as "!VisualStudio.DTE.17.0:<pid>" or "!TcXaeShell.DTE.17.0:<pid>"
                if (displayName.IndexOf("VisualStudio.DTE", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    displayName.IndexOf("TcXaeShell.DTE", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    object comObj;
                    if (rot.GetObject(moniker, out comObj) == 0 && comObj != null)
                    {
                        var entry = new Dictionary<string, object>();
                        entry["DisplayName"] = displayName;
                        entry["Object"] = comObj;
                        results.Add(entry);
                    }
                }
            }
            catch
            {
                // Skip monikers that fail — don't break enumeration
                continue;
            }
        }

        return results;
    }
}
