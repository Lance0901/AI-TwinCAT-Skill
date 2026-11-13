// TwinCAT Semantic Linter (#252) - Phase 2a rules (rule-catalog.md section 3). C# 5.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    internal sealed partial class LintRun
    {
        private sealed class ImplUnit
        {
            public TcObjectFile O;
            public string Path;
            public ScanResult Scan;
            public bool Joined;
        }

        private readonly List<ImplUnit> implUnits = new List<ImplUnit>();

        private void OnImplementation(TcObjectFile o, string path, ScanResult sr, bool joined)
        {
            ImplUnit u = new ImplUnit(); u.O = o; u.Path = path; u.Scan = sr; u.Joined = joined;
            implUnits.Add(u);
        }

        private void RunPhase2a()
        {
        }
    }
}
