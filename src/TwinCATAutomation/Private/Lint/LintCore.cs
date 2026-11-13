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

    // Blockable below is the rule default; the IDE measurement of tasks 1a.7 (PR #276 table, XAE 3.1.4026.22 /
    // VS2022, 2026-11-13, openspec/changes/add-semantic-linter/verification/xae-corrupt-file-behavior.md) decided
    // it per variant, so variants that differ from the default pass their own severity / blockable where they are
    // emitted (LintEngine.cs). "pending" is left only for variants nothing measured.
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
            // measured per variant in tasks 1a.7 (verification/xae-corrupt-file-behavior.md, measured 2026-11-13).
            Add("PROJECT-XML-001", "XML file is not well-formed", "error", "true", "project-integrity", "unknown",
                "XML 1.0 well-formedness (any XML parser rejects it); after this finding no other rule evaluates that file", "high", null);
            Add("PROJECT-XML-002", "Encoding declaration does not match the bytes (BOM, declared encoding, invalid UTF-8)", "error", "true", "project-integrity", "unknown",
                "declaration vs bytes mismatch and invalid UTF-8 made XAE show the object as unknown without any message (C09 / C12, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); no declaration / no BOM loaded normally (info)", "high", null);
            Add("PROJECT-XML-003", "Declaration / ST code is not one single CDATA section", "error", "true", "behavior", "unknown",
                "variant escaped-entity-in-cdata blocks (the compiler sees the escape text); text-outside-cdata is a warning (XAE read legal text normally, C02 / C05, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); several CDATA sections are what XAE writes for code containing ]]> and are not reported (verification/xae-generated-xml.md)", "high", "inferred");
            Add("PROJECT-XML-004", "Required element / attribute missing, or element order differs from what XAE writes", "error", "true", "project-integrity", "unknown",
                "structure observed on 4024 / 4026 files (corpus + XAE-generated Property / Itf, verification/xae-generated-xml.md); missing root / Name / Declaration / Implementation block (C06 / C07 / C09 / C10), missing SpecialFunc and order are warnings, unmeasured variants pending; unobserved-msbuild (conditions, imports, wildcards) pending; Transition not observed: schema-not-observed", "high", null);
            Add("PROJECT-KIND-001", "Object element, declaration keyword and file extension disagree", "error", "true", "project-integrity", "unknown",
                "variant declaration (keyword of another family than the XML element) blocks (C14); variant extension is a warning: XAE takes the kind from the element (C13); PROGRAM / FUNCTION_BLOCK / FUNCTION in one POU are not compared (C15, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); skipped when the header cannot be read", "high", null);
            Add("PROJECT-NAME-001", "Name attribute differs from the name in the declaration", "error", "true", "project-integrity", "unknown",
                "compared case-insensitively (TwinCAT identifiers are not case-sensitive); XAE names the object after the Name attribute and reports C0243 (C11 / C16, verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            Add("PROJECT-NAME-002", "File name differs from the object name", "warning", "false", "none", "unknown",
                "XAE takes the name from the XML Name attribute, the file name does not matter (C12, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); Robust Solution NAM-001 can raise it by profile", "high", null);
            Add("PROJECT-GUID-001", "Object or sub-object has no Id", "warning", "false", "project-integrity", "unknown",
                "XAE loads an object without Id and warns (1.3, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); only element kinds observed with an Id", "high", null);
            Add("PROJECT-GUID-002", "Id is not a {8-4-4-4-12} hexadecimal GUID", "error", "true", "project-integrity", "unknown",
                "a malformed Id made the object unknown to XAE (C17, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); upper-case hex digits are accepted (not measured)", "high", null);
            Add("PROJECT-GUID-003", "Id used twice in the project (object or sub-object)", "error", "true", "project-integrity", "unknown",
                "variant same-object blocks (XAE dropped the whole POU); variant cross-file is a warning (XAE gave one of them a new GUID and rewrote the file, 1.3, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); most common source: a file copied without a new Id", "high", null);
            Add("PROJECT-GUID-004", "Id is the all-zero GUID", "info", "false", "project-integrity", "unknown", "", "high", null);
            Add("PROJECT-GUID-005", "Id looks hand-written (ascending / repeated digit patterns)", "warning", "false", "project-integrity", "no",
                "heuristic: an ascending run of 6 hex digits, a digit repeated 6 times, or group 2 / 4 (or the version group when it does not start with 4) of one digit; a random GUID matches with about 0.05 % probability, i.e. about 10 % of projects with 200 Ids show one such warning", "medium", null);
            Add("PROJECT-SUB-001", "Sub-object structure incomplete (Method without Declaration / Implementation, Action without Implementation)", "error", "true", "project-integrity", "unknown",
                "Method / interface method without Declaration blocks (batches 42 / 44); Property without Get / Set is a warning (C0373); other variants pending; ABSTRACT members and Transition not observed (verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            Add("PROJECT-SUB-002", "Two sub-objects (Method / Action / Property) of one POU have the same name", "error", "true", "project-integrity", "unknown",
                "two methods with one name crashed VS2022 when the solution was reopened (batch 43, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); compared case-insensitively", "high", null);
            RuleRegistry.Get("PROJECT-SUB-002").Te1200 = "SA0027 (Light, duplicate names)";
            Add("PROJECT-LINEIDS-001", "LineIds do not match the implementation (name, count of lines)", "info", "false", "none", "no",
                "4026 files without LineIds are normal; only present LineIds are checked; 4026 XAE deleted inconsistent LineIds on the next save (2.4, verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            Add("PROJECT-COMPILE-001", "Compile item points to a file that does not exist", "error", "true", "project-integrity", "unknown",
                "XAE showed an unusable ghost object without error (5a, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); MSBuild-unescaped, compared case-insensitively", "high", null);
            Add("PROJECT-COMPILE-002", "Same file listed twice in Compile", "warning", "false", "project-integrity", "unknown",
                "compared after MSBuild unescape and full-path normalisation, case-insensitively", "high", null);
            Add("PROJECT-COMPILE-003", "Object file under the project directory is not in Compile (it is never compiled)", "warning", "false", "behavior", "no",
                "a file may be kept on purpose (_bak folders)", "high", null);
            Add("PROJECT-COMPILE-004", "Compile SubType differs from the value XAE writes (Code)", "warning", "false", "project-integrity", "unknown",
                "XAE wrote Code for every Compile item of both corpus projects; another SubType loaded normally (5d / 5e, verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            Add("PROJECT-COMPILE-005", "Directory used by Compile items has no Folder item", "info", "false", "none", "no",
                "Folder items without a directory on disk are normal (corpus bfh); XAE added the missing Folder item itself (5h, verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            Add("PROJECT-COMPILE-006", "Compile Include differs from the disk in case, or its MSBuild escaping is wrong", "warning", "false", "project-integrity", "unknown",
                "case differences and %20 loaded normally (5f / 5i, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); outside-project and invalid-path variants are pending (not measured)", "high", null);
            Add("PROJECT-LIB-001", "Library reference item lacks a required part", "error", "pending", "project-integrity", "unknown",
                "missing DefaultResolution is a warning (batch 12); missing Namespace is not reported although removing it stopped XAE in an assertion dialog (batch 11, verification/xae-corrupt-file-behavior.md, measured 2026-11-13): XAE itself wrote Tc2_Utilities without Namespace (4024 corpus); other parts pending", "high", null);
            Add("PROJECT-TSPROJ-001", ".tsproj reference to the .plcproj is missing or wrong", "error", "true", "project-integrity", "unknown",
                "a PrjFilePath to a missing .plcproj crashed VS2022 (batch 8, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); stand-alone PLC projects (no .tsproj) are skipped", "high", null);
            Add("PROJECT-TSPROJ-002", "PLC project GUID differs between .sln, .tsproj and .plcproj", "warning", "false", "project-integrity", "unknown",
                "compared case-insensitively (.plcproj writes lower case, .tsproj / .sln upper case)", "high", null);
            Add("PROJECT-TSPROJ-003", "Task (.TcTTO) and .tsproj disagree, or PouCall names no PROGRAM", "error", "pending", "behavior", "unknown",
                "variant pou-call is a warning, the compiler rejects it (C0046 / C0035, batch 10, verification/xae-corrupt-file-behavior.md, measured 2026-11-13); variant priority-mismatch is a warning; cycle time units are not compared (not sourced); a PLC stored as independent project file (.xti) is not checked (structure not observed)", "high", "inferred");
            Add("PROJECT-ENC-001", "Line endings / BOM differ from what XAE wrote in every observed file", "info", "false", "none", "no",
                "every Tc* object file XAE wrote (corpus, IDE measurement) is UTF-8 with BOM and CRLF; LF / mixed / no-BOM files loaded normally (2.3, verification/xae-corrupt-file-behavior.md, measured 2026-11-13)", "high", null);
            // ---- LINT-* (engine itself)
            Add("LINT-PARSE-001", "Code cannot be tokenized (unterminated string, comment or pragma; line break in a string)", "error", "true", "project-integrity", "yes",
                "downgraded to notAnalyzed when the section contains a construct the parser does not know", "high", null);
            Add("LINT-PARSE-002", "Block keywords do not pair (IF / END_IF, CASE / END_CASE, ...)", "error", "true", "project-integrity", "yes",
                "downgraded to notAnalyzed when the section contains a construct the parser does not know (conditional pragma, ?=, ...); the 4026.22 compiler rejected ?=, **, /* */, E_Enum#Member, T#-5S and non-ASCII identifiers in the IDE measurement (2026-11-13, verification/st-syntax-measured.md D01-D04 / D06 / D16) - they stay notAnalyzed (pass) because 4024 is not measured and the owner has not decided; the coverage reason names the rejection", "high", null);
            Add("LINT-PARSE-003", "Declaration structure broken (VAR block without END_VAR, TYPE without END_TYPE, ...)", "error", "true", "project-integrity", "yes",
                "downgraded to notAnalyzed when the declaration contains a construct the parser does not know; the 4026.22 compiler rejected ?=, **, /* */, E_Enum#Member, T#-5S and non-ASCII identifiers in the IDE measurement (2026-11-13, verification/st-syntax-measured.md D01-D04 / D06 / D16) - they stay notAnalyzed (pass) because 4024 is not measured and the owner has not decided; the coverage reason names the rejection", "high", null);
            // ---- Phase 1b (rule-catalog.md section 2; tasks 1b.2 / 1b.3 / 1b.6)
            Add("SCAN-TEMPFB-001", "Stateful function block (timer / trigger / counter / flip-flop) declared as a temporary instance", "error", "true", "behavior", "unknown",
                "re-initialized on every call: METHOD VAR (InfoSys tc3_plc_intro/2530307467.html), FUNCTION VAR (2530284939.html), VAR_TEMP (12050023819.html, 2528781963.html); METHOD VAR_INST, FB VAR and VAR_STAT are not reported. " +
                "Blocking only for timers (TON TOF TP LTON LTOF LTP) and types listed in profile typeCatalog.stateful; triggers / counters / flip-flops (R_TRIG F_TRIG CTU CTD CTUD RS SR) are warnings that must be disposed: " +
                "12050023819 says 'It is therefore only rarely useful to create an instance as a temporary variable.' (legal when used within one call); STRUCT members (FB as STRUCT member: no InfoSys statement) and Property Get / Set VAR (accessor-var: no InfoSys statement) are warnings. " +
                "Types: TypeCatalog.json v2 (class per type) + profile typeCatalog; project ALIAS, STRUCT / UNION members (nested, ARRAY) and project FBs whose VAR / VAR_STAT / inputs / outputs or EXTENDS chain hold a stateful type (cycle-safe); " +
                "otherwise rulesSkipped project-type / struct-type / unknown-type / type-only (Tc2_MC2), never guessed from a name prefix; variables inside {IF} regions of a declaration are not evaluated", "high", null);
            Add("PROJECT-TASK-001", "PROGRAM body is never executed (on no task, P() called by no POU reachable from a task)", "warning", "false", "behavior", "no",
                "Build compiles only referenced objects: an uncalled PROGRAM with a syntax error still built (measured 2026-11-13, verification/st-syntax-measured.md section 2); only the body counts: a program whose actions / methods are called but not P() -> variant action-only " +
                "(inferred: InfoSys 2530340747 gives the call syntax <program>.<action> but does not say whether the body runs); reading P.x is not a call; FB types count as reachable when declared in a reachable POU, GVL or DUT (over-approximation); " +
                "calls only inside {IF} regions, or the name in a part the linter cannot read (CFC / SFC, unreadable file, visualisation) -> rulesSkipped call-graph-incomplete; a PROGRAM used as a variable type -> rulesSkipped program-used-as-type; no .TcTTO (library) -> not run (no-task)", "high", null);
            Add("PROJECT-TASK-002", "PROGRAM runs more than once per cycle (two tasks, one task twice, task + program, two programs, repeated call)", "error", "true", "behavior", "no",
                "blocking = certain structural fact: two task PouCalls (two-tasks / task-twice), or unconditional P() from programs that run every cycle for certain (task-and-program / two-programs); repeated-call (two unconditional P() in one body) blocks only when P, or what it calls, holds a stateful catalog FB, else warning (legal parameterised calls); " +
                "conditional / loop / action calls and non-exclusive call sites -> possible-double-call warning; a caller that is a function block or function -> fb-or-function-caller warning; callers not reachable from a task are ignored (axis TestCam); " +
                "consequence inferred (double timer / trigger evaluation); InfoSys 12050040971 forbids access to one function block from several task contexts, nothing found for a PROGRAM on two tasks (not verified); a call after RETURN (dead code) still counts", "high", "inferred");
            Add("LINT-SUPPRESS-001", "Suppression directive not applied (no reason, reason under 8 characters, malformed, object directive after the first VAR)", "warning", "true", "none", "no", "", "high", null);
            Add("LINT-SUPPRESS-002", "Suppression names an unknown rule id", "warning", "true", "none", "no", "", "high", null);
            Add("LINT-SUPPRESS-003", "Suppression matches no finding", "info", "false", "none", "no", "", "high", null);
            Add("LINT-SUPPRESS-004", "Inline suppression of a rule that can block (only the profile suppressions[] may suppress it; review B3)", "warning", "true", "none", "no", "", "high", null);
            foreach (string id in new string[] { "SCAN-TEMPFB-001", "PROJECT-TASK-001", "PROJECT-TASK-002", "LINT-SUPPRESS-001", "LINT-SUPPRESS-002", "LINT-SUPPRESS-003", "LINT-SUPPRESS-004" }) RuleRegistry.Get(id).Phase = "1b";
            RuleRegistry.Get("SCAN-TEMPFB-001").Te1200 = "SA0167 (Light, runs after a successful compile)";
            Add("LINT-XML-002", "Implementation has more than one ST element (all are analysed; line numbers unreliable)", "warning", "false", "none", "unknown",
                "XAE always wrote one <ST> (verification/xae-generated-xml.md); line numbers of the joined text do not match Get-TcPouCode", "high", null);
            // ---- Phase 2a (rule-catalog.md section 3; LintRules2a.cs). Local analysis of one ST section: constants are
            // literals, VAR CONSTANT of the section / POU / base FB / GVL ({attribute 'qualified_only'} as GVL.c) and + - * / MOD;
            // anything else is not evaluated and recorded in coverage.rulesSkipped (never guessed).
            Add("SCAN-LOOP-001", "WHILE / REPEAT loop whose condition cannot change inside the loop (busy-wait)", "error", "true", "crash", "no",
                "InfoSys WHILE tc3_plc_intro/9007201783032715.html / REPEAT 9007201783038091.html: a condition that never ends the loop repeats the instructions continuously, 'causing a runtime error'. " +
                "Reported only when every variable of the condition is never written in the body (:=, S=, R=, REF=, =>; any identifier of the written designator counts) and the body has no call of any kind " +
                "(identifier, ']' or '^' before '('), no EXIT / RETURN / JMP and no pointer write; a call in the condition is not reported; a condition variable that is VAR_IN_OUT / REFERENCE / POINTER, or a written " +
                "REFERENCE / VAR_IN_OUT / THIS^ target, is not reported when the body writes anything (aliasing). WHILE TRUE / REPEAT UNTIL FALSE without EXIT / RETURN / JMP is reported even with calls. " +
                "Known false-positive source: another task (other core) changes the condition variable (still a design error, rule-catalog.md). Not evaluated: sections with a conditional pragma, unverified or unsupported syntax (rulesSkipped)", "high", null);
            Add("SCAN-FOR-001", "FOR loop never ends: end value at the counter type's limit (overflow), or BY 0", "error", "true", "crash", "warning",
                "InfoSys FOR tc3_plc_intro/2528280971.html: 'The <end value> must not have the same value as the upper bound of the data type of the counter.'; TwinCAT 2 FOR page (tcplccontrol/925251083.html) names the endless loop; " +
                "the compiler only warns (C0266, InfoSys 21630340363.html), the build succeeds. Counter types SINT..LWORD; end value and step must be constants. Variant step-overflow (start constant, last value + step leaves the type) is a warning: wrap-around with a step other than 1 is inferred, not documented. " +
                "Variant exit-in-body (EXIT / RETURN / JMP in the body): warning, not blocking. Variant by-zero: behaviour of BY 0 not documented (InfoSys only 'can have any integer value'), pending (tasks 2.10). " +
                "Not evaluated (rulesSkipped): counter written in the body (incl. passed bare to a call other than IEC standard functions / type conversions: may be VAR_IN_OUT / ADR), counter type unknown or not an integer type, end / step not constant. " +
                "Corpus 2026-11-13 (axis 4026 / bfh 4024): 0 findings; 17 FOR loops: 10 evaluated, 7 skipped (end not constant 6, counter passed to a method 1)", "high", null);
            Add("SCAN-ARR-001", "Array index of a constant-range FOR loop leaves the declared array bounds", "error", "true", "crash", "no",
                "Indexes counter, counter + k, counter - k, k - counter (k constant) per dimension, for the values start..last of a FOR loop with constant start / end / step whose counter is not written in the body; " +
                "array declared in the section, POU, base FB or a GVL (GVL.a for qualified_only). An access inside an IF / CASE / WHILE that tests the counter, or a body with EXIT / CONTINUE / RETURN / JMP -> variant guarded (warning, not blocking). " +
                "Not evaluated (rulesSkipped): ARRAY[*] (VAR_IN_OUT only, InfoSys 8825257611.html; loops over LOWER_BOUND / UPPER_BOUND have no constant bounds), bounds not constant, array of a struct member / pointer / not resolvable, " +
                "ARRAY OF ARRAY second index, other index expressions. CheckBounds is only present when the project adds it (InfoSys 2530356875.html); the runtime effect of an unchecked access is not documented (not verified)", "high", "inferred");
            Add("SAFETY-ARR-001", "Constant array index outside the declared bounds", "error", "false", "crash", "yes",
                "The compiler rejects it: C0049 (measured 2026-11-13, verification/st-syntax-measured.md section 3) and InfoSys 2530356875.html 'A consistently faulty array index results in a compiler error.' - only the value of reporting before the write; " +
                "constant = literals and VAR CONSTANT expressions; arrays resolved as for SCAN-ARR-001", "high", "inferred");
            Add("SAFETY-DIV-001", "Division / MOD by zero: constant 0, or a variable divisor that no condition on the path tests", "error", "true", "crash", "no",
                "Variant constant-zero-div (/ 0 literal): compiler error C0374 (measured 2026-11-13 for x / 0 and x / 0.0) -> compilerCatches yes on the finding, not in unresolved; / of a named constant or constant expression that is 0: not measured. " +
                "Variant constant-zero-mod (MOD 0): no compiler error or warning (measured 2026-11-13), blocking; InfoSys MOD 2528880779.html: the behaviour 'can vary depending on the target system'. " +
                "InfoSys DIV 2528875403.html: integer division by zero 'always leads to an exception and the corresponding task is stopped'; REAL division by 0 is not described in the PLC manual (task option 'Floating Point Exception', tc3_system/5210416139.html) - reported anyway. " +
                "Variant unchecked-variable-divisor: info, medium, never blocking (heuristic; SA0040 is TE1200 Full only): a plain variable / member / element divisor with no enclosing IF / ELSIF / CASE / WHILE condition, earlier IF that leaves or rewrites it, " +
                "same-expression test mentioning it, assignment in the branch from what the branch condition tests, or a VAR / VAR_STAT with a non-zero initial value no analysed section of its POU writes; " +
                "a divisor that cannot be 0 for other reasons is reported too (no value tracking, no state-machine / caller knowledge); a call result as divisor is not analysed. Info findings are not in unresolved[]. " +
                "Corpus 2026-11-13: 47 info findings (axis 46, bfh 1): 1 real candidate (latched master velocity), 9 divisors that are 0 when an input is 0 (velocity / function input), 35 derived from non-zero configuration inputs (circumference, area), 2 false (value > 0 by construction, check in an earlier state)", "high", null);
            foreach (string id in new string[] { "SCAN-LOOP-001", "SCAN-FOR-001", "SCAN-ARR-001", "SAFETY-ARR-001", "SAFETY-DIV-001" }) RuleRegistry.Get(id).Phase = "2";
            RuleRegistry.Get("SCAN-LOOP-001").Te1200 = "none (SA0041 Full 'loop-invariant code' is a different check)";
            RuleRegistry.Get("SCAN-ARR-001").Te1200 = "SA0172 (Full)";
            RuleRegistry.Get("SAFETY-ARR-001").Te1200 = "SA0172 (Full)";
            RuleRegistry.Get("SAFETY-DIV-001").Te1200 = "SA0040 (Full)";
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
        public string CompilerCatches;  // variant value when it differs from the rule (e.g. TSPROJ-003 pou-call: yes)
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
            if (CompilerCatches != null) d["compilerCatches"] = CompilerCatches;
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
        public List<CatalogType> CatalogTypes = new List<CatalogType>();   // TypeCatalog.json + profile typeCatalog (tasks 1b.1)
        public bool TestFault;
        public long MaxFileBytes = 8L * 1024 * 1024;   // larger files are not read: notAnalyzed too-large, verdict incomplete (should-fix 5)              // tests only: throw inside the engine (LINT_ENGINE_ERROR path)

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
        public void AddCatalogType(string name, string library, string kind, string source, string cls) { CatalogType c = new CatalogType(); c.Name = name; c.Library = library; c.Kind = kind; c.Source = source; c.Class = string.IsNullOrEmpty(cls) ? null : cls; CatalogTypes.Add(c); }
        public void AddScopeObject(string name) { if (ScopeObjects == null) ScopeObjects = new List<string>(); ScopeObjects.Add(name); }

        // LintCandidate (tasks 2.1, design.md D2): an object that is not written yet, laid over the project on disk
        // (PlcProjectPath set) or checked alone (CandidateTextOnly). Text is never written anywhere.
        public bool CandidateMode;
        public bool CandidateTextOnly;
        public string CandidateKind;            // Program FunctionBlock Function DUT GVL Interface Method Property Action Transition
        public string CandidateName;            // FB_X, FB_X.M_Run, FB_X.P, FB_X.P.Get
        public string CandidateDeclaration;
        public string CandidateImplementation;
    }

    public static class Inv
    {
        public static string S(int v) { return v.ToString(CultureInfo.InvariantCulture); }
    }
}
