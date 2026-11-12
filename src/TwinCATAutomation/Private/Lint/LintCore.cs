// TwinCAT Semantic Linter (#252) - core model: rule metadata, diagnostics, coverage, ordering.
// C# 5 only: Windows PowerShell 5.1 Add-Type compiles with the .NET Framework csc (no string
// interpolation, no ?., no nameof, no expression-bodied members, no property initializers).
// The namespace name TcLintEngine is replaced by TcLint_<sha256 prefix of all Lint/*.cs> before
// compiling (Private/Lint/LintEngineLoader.ps1, design.md D1): a changed source is a new type even
// in a session that already loaded an older engine (Add-Type assemblies cannot be unloaded).
namespace TcLintEngine
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Globalization;

    // ---------------------------------------------------------------- rule metadata
    public sealed class RuleMeta
    {
        public string Id;
        public int Version;
        public string Category;        // ST / SCAN / CONTRACT / PROJECT / SAFETY / POLICY / LINT
        public string Severity;        // error / warning / info
        public string Confidence;      // high / medium / low
        public string Blockable;       // true / false / pending
        public string Requires;        // project-context / baseline / ide / type-catalog / none
        public string AppliesTo;
        public string Limits;
        public string Te1200;
        public string CompilerCatches; // yes / warning / no / unknown / measured:<date>
        public string MachineImpact;   // none / project-integrity / behavior / crash
        public string Phase;
        public string ImpactBasis;     // null or "inferred"
        public string Title;

        public OrderedDictionary ToDictionary()
        {
            OrderedDictionary d = new OrderedDictionary();
            d["id"] = Id; d["version"] = Version; d["category"] = Category; d["title"] = Title;
            d["severity"] = Severity; d["confidence"] = Confidence; d["blockable"] = Blockable;
            d["requires"] = Requires; d["appliesTo"] = AppliesTo; d["limits"] = Limits; d["te1200"] = Te1200;
            d["compilerCatches"] = CompilerCatches; d["machineImpact"] = MachineImpact; d["phase"] = Phase;
            if (ImpactBasis != null) d["impactBasis"] = ImpactBasis;
            return d;
        }
    }

    // The single switch point for every "pending" decision (tasks 1a.7): Blockable below.
    // A rule whose XAE behaviour is measured changes "pending" to "true" or "false" here only.
    public static class RuleRegistry
    {
        private static readonly List<RuleMeta> rules = new List<RuleMeta>();
        private static readonly Dictionary<string, RuleMeta> byId = new Dictionary<string, RuleMeta>(StringComparer.Ordinal);

        private static void Add(string id, string title, string severity, string blockable, string impact,
            string compiler, string limits, string confidence, string impactBasis)
        {
            RuleMeta r = new RuleMeta();
            r.Id = id; r.Version = 1; r.Title = title;
            r.Category = id.StartsWith("LINT-", StringComparison.Ordinal) ? "LINT" : id.Substring(0, id.IndexOf('-'));
            r.Severity = severity; r.Confidence = confidence; r.Blockable = blockable;
            r.Requires = "project-context"; r.AppliesTo = "TwinCAT 3.1 build 4024 / 4026 file formats (research/tc-xml-schema-observed.md); other ProductVersion values: structural rules downgrade to warning";
            r.Limits = limits; r.Te1200 = "-"; r.CompilerCatches = compiler; r.MachineImpact = impact; r.Phase = "1a";
            r.ImpactBasis = impactBasis;
            rules.Add(r); byId[id] = r;
        }

        static RuleRegistry()
        {
            // ---- PROJECT-* (rule-catalog.md section 1). blockable "pending" = detection is certain,
            // whether XAE treats it as an error is not measured yet (tasks 1a.7).
            Add("PROJECT-XML-001", "XML file is not well-formed", "error", "true", "project-integrity", "unknown",
                "XML 1.0 well-formedness (any XML parser rejects it); after this finding no other rule evaluates that file", "high", null);
            Add("PROJECT-XML-002", "Encoding declaration does not match the bytes (BOM, declared encoding, invalid UTF-8)", "error", "pending", "project-integrity", "unknown",
                "XAE tolerance of encoding mismatches is not measured", "high", null);
            Add("PROJECT-XML-003", "Declaration / ST code is not one single CDATA section", "error", "true", "behavior", "unknown",
                "variant text-outside-cdata is blockable true (XAE wrote 242 + 176 single CDATA sections); variant multiple-cdata is pending: XAE may split code that contains ]]> itself (tasks 1a.7)", "high", "inferred");
            Add("PROJECT-XML-004", "Required element / attribute missing, or element order differs from what XAE writes", "error", "pending", "project-integrity", "unknown",
                "structure observed on 4024 / 4026 files only; variant order is a warning (effect of a different order not measured); Itf / Property / Transition not observed: schema-not-observed", "high", null);
            Add("PROJECT-KIND-001", "Object element, declaration keyword and file extension disagree", "error", "pending", "project-integrity", "unknown",
                "skipped when the declaration header cannot be read (conditional pragma before the header)", "high", null);
            Add("PROJECT-NAME-001", "Name attribute differs from the name in the declaration", "error", "pending", "project-integrity", "unknown",
                "compared case-insensitively (TwinCAT identifiers are not case-sensitive); which name XAE uses is not measured", "high", null);
            Add("PROJECT-NAME-002", "File name differs from the object name", "warning", "false", "none", "unknown",
                "whether XAE accepts it is not measured; Robust Solution NAM-001 can raise it by profile", "high", null);
            Add("PROJECT-GUID-001", "Object or sub-object has no Id", "error", "pending", "project-integrity", "unknown",
                "only element kinds observed with an Id (POU, DUT, GVL, Method, Action, Folder, Task, Visu objects)", "high", null);
            Add("PROJECT-GUID-002", "Id is not a {8-4-4-4-12} hexadecimal GUID", "error", "pending", "project-integrity", "unknown",
                "upper-case hex digits are accepted (XAE writes lower case; acceptance of upper case not measured)", "high", null);
            Add("PROJECT-GUID-003", "Id used twice in the project (object or sub-object)", "error", "pending", "project-integrity", "unknown",
                "most common source: a file copied and renamed without a new Id", "high", null);
            Add("PROJECT-GUID-004", "Id is the all-zero GUID", "error", "pending", "project-integrity", "unknown", "", "high", null);
            Add("PROJECT-GUID-005", "Id looks hand-written (ascending / repeated digit patterns)", "warning", "false", "project-integrity", "no",
                "heuristic: an ascending run of 5 hex digits, a digit repeated 6 times, or a 4-digit group of one digit; a random GUID matches with about 0.1 % probability", "medium", null);
            Add("PROJECT-SUB-001", "Sub-object structure incomplete (Method without Declaration / Implementation, Action without Implementation)", "error", "pending", "project-integrity", "unknown",
                "Property / Transition structure not observed: schema-not-observed", "high", null);
            Add("PROJECT-SUB-002", "Two sub-objects (Method / Action / Property) of one POU have the same name", "error", "pending", "project-integrity", "unknown",
                "compiler probably rejects it (not measured); compared case-insensitively", "high", null);
            Add("PROJECT-LINEIDS-001", "LineIds do not match the implementation (name, count of lines)", "info", "false", "none", "no",
                "4026 files without LineIds are normal; only present LineIds are checked; whether XAE rebuilds them is not measured", "high", null);
            Add("PROJECT-COMPILE-001", "Compile item points to a file that does not exist", "error", "pending", "project-integrity", "unknown",
                "MSBuild-unescaped, compared case-insensitively", "high", null);
            Add("PROJECT-COMPILE-002", "Same file listed twice in Compile", "error", "pending", "project-integrity", "unknown",
                "compared after MSBuild unescape and full-path normalisation, case-insensitively", "high", null);
            Add("PROJECT-COMPILE-003", "Object file under the project directory is not in Compile (it is never compiled)", "warning", "false", "behavior", "no",
                "a file may be kept on purpose (_bak folders)", "high", null);
            Add("PROJECT-COMPILE-004", "Compile SubType differs from the value XAE writes (Code)", "error", "pending", "project-integrity", "unknown",
                "XAE wrote Code for every Compile item of both corpus projects", "high", null);
            Add("PROJECT-COMPILE-005", "Directory used by Compile items has no Folder item", "info", "false", "none", "no",
                "Folder items without a directory on disk are normal (XAE keeps empty folders only in the project file)", "high", null);
            Add("PROJECT-COMPILE-006", "Compile Include differs from the disk in case, or its MSBuild escaping is wrong", "error", "pending", "project-integrity", "unknown",
                "how XAE writes names with blanks / ' / % is not measured (tasks 1a.7)", "high", null);
            Add("PROJECT-LIB-001", "Library reference item lacks a required part", "error", "pending", "project-integrity", "unknown",
                "PlaceholderReference needs Include + DefaultResolution, PlaceholderResolution needs Include + Resolution, LibraryReference needs Include (corpus observation)", "high", null);
            Add("PROJECT-TSPROJ-001", ".tsproj reference to the .plcproj is missing or wrong", "error", "pending", "project-integrity", "unknown",
                "only PLC projects of .tsproj files referenced by the .sln (or found next to the .plcproj when there is no .sln)", "high", null);
            Add("PROJECT-TSPROJ-002", "PLC project GUID differs between .sln, .tsproj and .plcproj", "error", "pending", "project-integrity", "unknown",
                "compared case-insensitively (.plcproj writes lower case, .tsproj / .sln upper case)", "high", null);
            Add("PROJECT-TSPROJ-003", "Task (.TcTTO) and .tsproj disagree, or PouCall names no PROGRAM", "error", "pending", "behavior", "unknown",
                "variant priority-mismatch is a warning; cycle time units are not compared (not sourced)", "high", "inferred");
            Add("PROJECT-ENC-001", "Line endings / BOM differ from what XAE writes (file written outside XAE)", "info", "false", "none", "no",
                "XAE writes Tc* object files as UTF-8 with BOM and CRLF; a difference only means the file was written by another tool", "high", null);
            // ---- LINT-* (engine itself)
            Add("LINT-PARSE-001", "Code cannot be tokenized (unterminated string, comment or pragma; line break in a string)", "error", "true", "project-integrity", "unknown",
                "downgraded to notAnalyzed when the section contains a construct the parser does not know", "high", null);
            Add("LINT-PARSE-002", "Block keywords do not pair (IF / END_IF, CASE / END_CASE, ...)", "error", "true", "project-integrity", "unknown",
                "downgraded to notAnalyzed when the section contains a construct the parser does not know (conditional pragma, ?=, ...)", "high", null);
            Add("LINT-PARSE-003", "Declaration structure broken (VAR block without END_VAR, TYPE without END_TYPE, ...)", "error", "true", "project-integrity", "unknown",
                "downgraded to notAnalyzed when the declaration contains a construct the parser does not know", "high", null);
            Add("LINT-XML-002", "Implementation has more than one ST element (all are analysed; line numbers unreliable)", "warning", "false", "none", "unknown",
                "not observed in XAE files; line numbers of the joined text do not match Get-TcPouCode", "high", null);
        }

        public static RuleMeta Get(string id)
        {
            RuleMeta r;
            return byId.TryGetValue(id, out r) ? r : null;
        }

        public static List<RuleMeta> All() { return new List<RuleMeta>(rules); }

        public static ArrayList ToList()
        {
            ArrayList list = new ArrayList();
            foreach (RuleMeta r in rules) list.Add(r.ToDictionary());
            return list;
        }
    }

    // ---------------------------------------------------------------- diagnostics
    public sealed class Diagnostic
    {
        public string RuleId;
        public string Severity;
        public string Confidence;
        public string Blockable;        // effective (variant may override)
        public string Variant;
        public bool Blocking;
        public string BlockingSource;   // null or "profile"
        public bool Suppressed;
        public string SuppressionReason;
        public string File;             // relative to the .plcproj directory, '/' separated
        public string ObjectPath;       // "" for project-level files
        public string Section;          // file / declaration / implementation
        public int Line;
        public int Column;
        public string Message;
        public string Evidence;
        public string FixHint;
        public bool LineUnreliable;

        public static int SectionRank(string s)
        {
            if (s == "file") return 0;
            if (s == "declaration") return 1;
            if (s == "implementation") return 2;
            return 3;
        }

        public static int SeverityRank(string s)
        {
            if (s == "error") return 3;
            if (s == "warning") return 2;
            if (s == "info") return 1;
            return 0;
        }

        public OrderedDictionary ToDictionary()
        {
            RuleMeta r = RuleRegistry.Get(RuleId);
            OrderedDictionary d = new OrderedDictionary();
            d["ruleId"] = RuleId;
            d["ruleVersion"] = r == null ? 0 : r.Version;
            d["severity"] = Severity;
            d["confidence"] = Confidence;
            d["blocking"] = Blocking;
            d["suppressed"] = Suppressed;
            if (Suppressed) d["suppressionReason"] = SuppressionReason;
            d["machineImpact"] = r == null ? "none" : r.MachineImpact;
            if (Blockable == "pending") d["blockableBasis"] = "pending-measurement";
            if (BlockingSource != null) d["blockingSource"] = BlockingSource;
            if (r != null && r.ImpactBasis != null) d["impactBasis"] = r.ImpactBasis;
            if (Variant != null) d["variant"] = Variant;
            d["file"] = File;
            d["objectPath"] = ObjectPath;
            d["section"] = Section;
            d["line"] = Line;
            d["column"] = Column;
            d["message"] = Message;
            if (Evidence != null) d["evidence"] = Evidence;
            if (FixHint != null) d["fixHint"] = FixHint;
            d["autoFix"] = "none";
            if (LineUnreliable) d["lineUnreliable"] = true;
            return d;
        }
    }

    // design.md D5 ordering: file (lower-case invariant, ordinal) -> objectPath -> section ->
    // line -> column -> ruleId -> message. No culture-sensitive comparison anywhere.
    public sealed class DiagnosticComparer : IComparer<Diagnostic>
    {
        public int Compare(Diagnostic a, Diagnostic b)
        {
            int c = string.CompareOrdinal(Low(a.File), Low(b.File)); if (c != 0) return c;
            c = string.CompareOrdinal(a.File, b.File); if (c != 0) return c;
            c = string.CompareOrdinal(Low(a.ObjectPath), Low(b.ObjectPath)); if (c != 0) return c;
            c = Diagnostic.SectionRank(a.Section).CompareTo(Diagnostic.SectionRank(b.Section)); if (c != 0) return c;
            c = a.Line.CompareTo(b.Line); if (c != 0) return c;
            c = a.Column.CompareTo(b.Column); if (c != 0) return c;
            c = string.CompareOrdinal(a.RuleId, b.RuleId); if (c != 0) return c;
            c = string.CompareOrdinal(a.Message, b.Message); if (c != 0) return c;
            return string.CompareOrdinal(a.Evidence ?? "", b.Evidence ?? "");
        }

        private static string Low(string s) { return (s ?? "").ToLowerInvariant(); }
    }

    // ---------------------------------------------------------------- coverage
    public sealed class CoverageEntry
    {
        public string RuleId;
        public string File;
        public string ObjectPath;
        public string Section;
        public string Reason;

        public OrderedDictionary ToDictionary()
        {
            OrderedDictionary d = new OrderedDictionary();
            if (RuleId != null) d["ruleId"] = RuleId;
            if (File != null) d["file"] = File;
            if (ObjectPath != null) d["objectPath"] = ObjectPath;
            if (Section != null) d["section"] = Section;
            d["reason"] = Reason;
            return d;
        }

        public string Key()
        {
            return (RuleId ?? "") + "|" + (File ?? "").ToLowerInvariant() + "|" + (ObjectPath ?? "").ToLowerInvariant() + "|" + (Section ?? "") + "|" + Reason;
        }
    }

    public static class CoverageSort
    {
        public static ArrayList ToSortedList(List<CoverageEntry> items)
        {
            List<CoverageEntry> copy = new List<CoverageEntry>();
            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (CoverageEntry e in items) { if (seen.Add(e.Key())) copy.Add(e); }
            copy.Sort(delegate (CoverageEntry a, CoverageEntry b) { return string.CompareOrdinal(a.Key(), b.Key()); });
            ArrayList list = new ArrayList();
            foreach (CoverageEntry e in copy) list.Add(e.ToDictionary());
            return list;
        }
    }

    // ---------------------------------------------------------------- options (filled by PowerShell)
    public sealed class RuleOverride
    {
        public string RuleId;
        public bool? Enabled;
        public string Severity;
        public bool? Blocking;
    }

    public sealed class ProfileEntry
    {
        public string ObjectPath;
        public string RuleId;
        public string Reason;
    }

    public sealed class LintOptions
    {
        public string PlcProjectPath;
        public string SolutionPath;          // optional: the .sln (or null)
        public string TsprojPath;            // optional: .tsproj given by the caller
        public string FailOn = "error";
        public List<string> ScopeObjects;    // null = all objects
        public List<RuleOverride> RuleOverrides = new List<RuleOverride>();
        public List<ProfileEntry> Excludes = new List<ProfileEntry>();
        public List<ProfileEntry> Suppressions = new List<ProfileEntry>();
        public List<ProfileEntry> AcceptSkips = new List<ProfileEntry>();
        public bool TestFault;              // tests only: throw inside the engine (LINT_ENGINE_ERROR path)

        public void AddRuleOverride(string id, object enabled, string severity, object blocking)
        {
            RuleOverride o = new RuleOverride();
            o.RuleId = id;
            if (enabled is bool) o.Enabled = (bool)enabled;
            o.Severity = string.IsNullOrEmpty(severity) ? null : severity;
            if (blocking is bool) o.Blocking = (bool)blocking;
            RuleOverrides.Add(o);
        }

        public void AddExclude(string objectPath, string reason) { ProfileEntry e = new ProfileEntry(); e.ObjectPath = objectPath; e.Reason = reason; Excludes.Add(e); }
        public void AddSuppression(string objectPath, string ruleId, string reason) { ProfileEntry e = new ProfileEntry(); e.ObjectPath = objectPath; e.RuleId = ruleId; e.Reason = reason; Suppressions.Add(e); }
        public void AddAcceptSkip(string objectPath, string ruleId, string reason) { ProfileEntry e = new ProfileEntry(); e.ObjectPath = objectPath; e.RuleId = ruleId; e.Reason = reason; AcceptSkips.Add(e); }
        public void AddScopeObject(string name) { if (ScopeObjects == null) ScopeObjects = new List<string>(); ScopeObjects.Add(name); }
    }

    public static class Inv
    {
        public static string S(int v) { return v.ToString(CultureInfo.InvariantCulture); }
    }
}
