// TwinCAT Semantic Linter (#252) - Phase 3a rules: SCAN-REF-001 (rule-catalog.md Phase 3, tasks 3.1). C# 5.
// Principle (PR #284 / #289 reviews): what cannot be proven -> coverage.rulesSkipped with a reason; never a silent pass, never a guess.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    public static partial class RuleRegistry
    {
        private static void Register3Ref()
        {
        }
    }

    internal sealed partial class LintRun
    {
        private void RunPhase3Ref()
        {
        }
    }
}
