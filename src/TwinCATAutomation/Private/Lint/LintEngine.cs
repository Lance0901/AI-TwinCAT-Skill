// TwinCAT Semantic Linter (#252) - Phase 1a engine: PROJECT-* and LINT-* rules on disk files. C# 5.
// Rule definitions: openspec/changes/add-semantic-linter/rule-catalog.md section 1. Structure facts:
// research/tc-xml-schema-observed.md. Verdict / coverage contract: design.md D3 / D4 / D6.
namespace TcLintEngine
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Globalization;
    using System.IO;
    using System.Text;
    using System.Text.RegularExpressions;
    using System.Threading;

    public sealed class TcObjectFile
    {
        public string FullPath;
        public string Rel;
        public string Ext;
        public FileBytesInfo Bytes;
        public XmlLoad Xml;
        public XElem Obj;
        public string Kind;          // element name of the object (POU, DUT, ...)
        public string Name;
        public string ObjectPath;
        public bool InScope;
        public bool Downgrade;       // ProductVersion outside the observed range
        public string DeclHeader;    // PROGRAM / FUNCTION_BLOCK / ... for POU objects
        public List<string> PouCalls = new List<string>();
        public string TaskPriority;
        public int TaskLine;
    }

    public sealed class PlcRef
    {
        public string TsprojFull;
        public string Name;
        public string Guid;
        public string PrjFilePath;
        public string PlcprojFull;
        public bool IndependentFile;
        public XElem Element;
    }

    public static class LintEngine
    {
        public const string EngineVersion = "1a.1";

        public static OrderedDictionary Run(LintOptions options)
        {
            CultureInfo ui = Thread.CurrentThread.CurrentUICulture;
            CultureInfo cu = Thread.CurrentThread.CurrentCulture;
            try
            {
                // .NET exception texts (engineDetail) in English and invariant number formatting:
                // the output must be byte-identical under en-US and zh-TW (design.md D5).
                Thread.CurrentThread.CurrentUICulture = CultureInfo.InvariantCulture;
                Thread.CurrentThread.CurrentCulture = CultureInfo.InvariantCulture;
                LintRun r = new LintRun(options);
                return r.Execute();
            }
            finally
            {
                Thread.CurrentThread.CurrentUICulture = ui;
                Thread.CurrentThread.CurrentCulture = cu;
            }
        }

        // SolutionPath mode: every PLC project referenced by the .sln (through its .tsproj files) or by one .tsproj.
        public static ArrayList ListPlcProjects(string slnOrTsproj)
        {
            ArrayList list = new ArrayList();
            List<string> tsprojs = new List<string>();
            if (slnOrTsproj.EndsWith(".tsproj", StringComparison.OrdinalIgnoreCase)) tsprojs.Add(Path.GetFullPath(slnOrTsproj));
            else tsprojs.AddRange(SlnTsprojs(Path.GetFullPath(slnOrTsproj)));
            foreach (string ts in tsprojs)
            {
                List<PlcRef> refs = ReadPlcRefs(ts);
                if (refs == null)
                {
                    OrderedDictionary e = new OrderedDictionary();
                    e["name"] = null; e["plcProjectPath"] = null; e["tsprojPath"] = ts; e["exists"] = false; e["error"] = File.Exists(ts) ? "tsproj-unreadable" : "tsproj-missing";
                    list.Add(e);
                    continue;
                }
                foreach (PlcRef p in refs)
                {
                    OrderedDictionary e = new OrderedDictionary();
                    e["name"] = p.Name; e["plcProjectPath"] = p.PlcprojFull; e["tsprojPath"] = ts;
                    e["exists"] = p.PlcprojFull != null && File.Exists(p.PlcprojFull);
                    e["error"] = p.IndependentFile ? "independent-file-not-supported" : null;
                    list.Add(e);
                }
            }
            return list;
        }

        public static List<string> SlnTsprojs(string sln)
        {
            List<string> outList = new List<string>();
            string text;
            try { text = File.ReadAllText(sln); } catch (Exception) { return outList; }
            string dir = Path.GetDirectoryName(sln);
            foreach (Match m in SlnProjectRx.Matches(text))
            {
                string rel = m.Groups[2].Value;
                if (!rel.EndsWith(".tsproj", StringComparison.OrdinalIgnoreCase)) continue;
                string full = MsPath.Full(dir, rel);
                if (full != null) outList.Add(full);
            }
            return outList;
        }

        public static readonly Regex SlnProjectRx = new Regex(
            "^Project\\(\"\\{[0-9A-Fa-f-]+\\}\"\\)\\s*=\\s*\"([^\"]*)\"\\s*,\\s*\"([^\"]*)\"\\s*,\\s*\"(\\{[0-9A-Fa-f-]+\\})\"",
            RegexOptions.Multiline | RegexOptions.CultureInvariant);

        public static List<PlcRef> ReadPlcRefs(string tsproj)
        {
            if (!File.Exists(tsproj)) return null;
            FileBytesInfo fi = XmlLoader.ReadBytes(tsproj);
            XmlLoad x = XmlLoader.Load(tsproj, fi);
            if (!x.WellFormed) return null;
            return PlcRefsFrom(x.Root, tsproj);
        }

        public static List<PlcRef> PlcRefsFrom(XElem root, string tsproj)
        {
            List<PlcRef> refs = new List<PlcRef>();
            if (root == null || root.Name != "TcSmProject") return refs;
            string dir = Path.GetDirectoryName(tsproj);
            foreach (XElem proj in root.All("Project"))
            {
                foreach (XElem plc in proj.All("Plc"))
                {
                    foreach (XElem p in plc.All("Project"))
                    {
                        PlcRef r = new PlcRef();
                        r.TsprojFull = tsproj; r.Element = p;
                        r.Name = p.Attr("Name"); r.Guid = p.Attr("GUID"); r.PrjFilePath = p.Attr("PrjFilePath");
                        if (r.PrjFilePath == null && p.Attr("File") != null) r.IndependentFile = true;
                        if (r.PrjFilePath != null) r.PlcprojFull = MsPath.Full(dir, r.PrjFilePath);
                        refs.Add(r);
                    }
                }
            }
            return refs;
        }

        public static ArrayList Rules() { return RuleRegistry.ToList(); }
    }

    internal sealed class LintRun
    {
        private readonly LintOptions opt;
        private readonly List<Diagnostic> diags = new List<Diagnostic>();
        private readonly List<CoverageEntry> notAnalyzed = new List<CoverageEntry>();
        private readonly List<CoverageEntry> excluded = new List<CoverageEntry>();
        private readonly List<CoverageEntry> rulesSkipped = new List<CoverageEntry>();
        private readonly List<CoverageEntry> blockingSkipped = new List<CoverageEntry>();
        private readonly List<CoverageEntry> rulesNotRun = new List<CoverageEntry>();
        private readonly List<string> engineDetail = new List<string>();
        private readonly Dictionary<string, RuleOverride> overrides = new Dictionary<string, RuleOverride>(StringComparer.Ordinal);
        private readonly List<TcObjectFile> objects = new List<TcObjectFile>();
        private string plcFull;
        private string plcDir;
        private string plcRel;
        private bool parseFailed;
        private bool incompleteByRead;
        private string slnFull;
        private readonly List<string> tsprojFull = new List<string>();
        private int objectsInScope;
        private int objectsAnalyzed;

        private static readonly HashSet<string> TcObjectExts = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".TcPOU", ".TcDUT", ".TcGVL", ".TcIO", ".TcTTO" };
        private static readonly Dictionary<string, string> KindByExt = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            { ".TcPOU", "POU" }, { ".TcDUT", "DUT" }, { ".TcGVL", "GVL" }, { ".TcIO", "Itf" }, { ".TcTTO", "Task" },
            { ".TcVIS", "Visu" }, { ".TcVMO", "VisuManager" }, { ".TcGTLO", "GlobalTextList" }, { ".TcIPO", "ImagePool" } };
        private static readonly HashSet<string> IdObservedKinds = new HashSet<string>(StringComparer.Ordinal) {
            "POU", "DUT", "GVL", "Method", "Action", "Folder", "Task", "Visu", "VisuManager", "GlobalTextList", "ImagePool" };
        private static readonly HashSet<string> StructuralRules = new HashSet<string>(StringComparer.Ordinal) { "PROJECT-XML-004", "PROJECT-SUB-001" };
        private static readonly Regex GuidRx = new Regex("^\\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\}$", RegexOptions.CultureInvariant);
        private static readonly string[] LanguageElements = { "ST", "CFC", "SFC", "FBD", "LD", "IL", "NWL", "UML", "LDFBD", "XmlArchive" };

        private sealed class IdUse
        {
            public string Id;
            public string File;
            public string ObjectPath;
            public int Line;
            public bool InScope;
        }

        private readonly List<IdUse> ids = new List<IdUse>();

        public LintRun(LintOptions o)
        {
            opt = o;
            // PowerShell assigns "" (not null) when $null goes into a .NET string field
            if (string.IsNullOrEmpty(o.SolutionPath)) o.SolutionPath = null;
            if (string.IsNullOrEmpty(o.TsprojPath)) o.TsprojPath = null;
            if (string.IsNullOrEmpty(o.FailOn)) o.FailOn = "error";
            foreach (RuleOverride ov in o.RuleOverrides) overrides[ov.RuleId] = ov;
        }

        // ================================================================ emit
        private bool Enabled(string ruleId)
        {
            RuleOverride ov;
            return !(overrides.TryGetValue(ruleId, out ov) && ov.Enabled.HasValue && !ov.Enabled.Value);
        }

        private Diagnostic Emit(string ruleId, string file, string objectPath, string section, int line, int col, string message,
            string evidence, string fixHint, string variant, string severity, string blockable, bool downgrade)
        {
            if (!Enabled(ruleId)) return null;
            RuleMeta r = RuleRegistry.Get(ruleId);
            if (r == null) throw new InvalidOperationException("unknown rule " + ruleId);
            Diagnostic d = new Diagnostic();
            d.RuleId = ruleId; d.File = file ?? ""; d.ObjectPath = objectPath ?? ""; d.Section = section;
            d.Line = line < 1 ? 1 : line; d.Column = col < 1 ? 1 : col; d.Message = message; d.Evidence = evidence; d.FixHint = fixHint;
            d.Variant = variant; d.Severity = severity ?? r.Severity; d.Confidence = r.Confidence; d.Blockable = blockable ?? r.Blockable;
            if (downgrade && StructuralRules.Contains(ruleId) && d.Severity == "error") { d.Severity = "warning"; d.Blockable = "false"; d.Variant = (variant == null ? "" : variant + ",") + "unobserved-product-version"; }
            diags.Add(d);
            return d;
        }

        private Diagnostic E(string ruleId, string file, string objectPath, string section, int line, string message, string evidence, string fixHint)
        {
            return Emit(ruleId, file, objectPath, section, line, 1, message, evidence, fixHint, null, null, null, false);
        }

        private static CoverageEntry Cov(string ruleId, string file, string objectPath, string section, string reason)
        {
            CoverageEntry c = new CoverageEntry(); c.RuleId = ruleId; c.File = file; c.ObjectPath = objectPath; c.Section = section; c.Reason = reason;
            return c;
        }

        private void SkipBlocking(string ruleId, string file, string objectPath, string reason)
        {
            if (!Enabled(ruleId)) return;
            RuleMeta r = RuleRegistry.Get(ruleId);
            CoverageEntry c = Cov(ruleId, file, objectPath, null, reason);
            if (r != null && (r.Blockable == "true" || r.Blockable == "pending") && r.CompilerCatches != "yes") blockingSkipped.Add(c);
            else rulesSkipped.Add(c);
        }

        // ================================================================ main
        public OrderedDictionary Execute()
        {
            foreach (RuleOverride ov in opt.RuleOverrides)
                if (ov.Enabled.HasValue && !ov.Enabled.Value) rulesNotRun.Add(Cov(ov.RuleId, null, null, null, "disabled-by-profile"));

            plcFull = Path.GetFullPath(opt.PlcProjectPath);
            plcDir = Path.GetDirectoryName(plcFull);
            plcRel = Path.GetFileName(plcFull);

            if (!File.Exists(plcFull))
            {
                // only reachable from SolutionPath mode: the .tsproj names a .plcproj that is not there
                CheckTsprojForMissingPlcproj();
                return Finish();
            }

            FileBytesInfo pfi = XmlLoader.ReadBytes(plcFull);
            if (pfi.ReadFailed)
            {
                engineDetail.Add(plcRel + ": " + pfi.ReadError);
                notAnalyzed.Add(Cov(null, plcRel, "", "file", "unreadable"));
                incompleteByRead = true;
                return Finish();
            }
            CheckEncoding(plcRel, "", pfi, false);
            if (pfi.InvalidUtf8) { notAnalyzed.Add(Cov(null, plcRel, "", "file", "invalid-encoding")); parseFailed = true; return Finish(); }
            XmlLoad px = XmlLoader.Load(plcFull, pfi);
            if (!px.WellFormed)
            {
                engineDetail.Add(plcRel + ": " + px.ErrorDetail);
                Emit("PROJECT-XML-001", plcRel, "", "file", px.ErrorLine, px.ErrorCol, "The .plcproj is not well-formed XML; nothing else of the project can be checked",
                    null, "Restore the .plcproj from version control or let XAE rewrite it (Reset-TcSolution after fixing the XML)", null, null, null, false);
                parseFailed = true;
                return Finish();
            }
            if (px.Root.Name != "Project")
            {
                E("PROJECT-XML-004", plcRel, "", "file", px.Root.Line, "The .plcproj root element is <" + px.Root.Name + ">, expected the MSBuild <Project>", null, null);
                return Finish();
            }

            List<XElem> compile = new List<XElem>(), folders = new List<XElem>(), placeholders = new List<XElem>(), resolutions = new List<XElem>(), libs = new List<XElem>();
            string projectGuid = null;
            foreach (XElem g in px.Root.Children)
            {
                if (g.Name == "PropertyGroup")
                {
                    XElem pg = g.Child("ProjectGuid");
                    if (pg != null && projectGuid == null) projectGuid = pg.InnerText().Trim();
                }
                if (g.Name != "ItemGroup") continue;
                foreach (XElem it in g.Children)
                {
                    if (it.Name == "Compile") compile.Add(it);
                    else if (it.Name == "Folder") folders.Add(it);
                    else if (it.Name == "PlaceholderReference") placeholders.Add(it);
                    else if (it.Name == "PlaceholderResolution") resolutions.Add(it);
                    else if (it.Name == "LibraryReference") libs.Add(it);
                }
            }

            List<string> objectFiles = CheckCompile(compile, folders);
            CheckLibraries(placeholders, resolutions, libs);
            foreach (string f in objectFiles) LoadObject(f);
            if (opt.ScopeObjects != null)
            {
                foreach (string s in opt.ScopeObjects)
                {
                    bool found = false;
                    foreach (TcObjectFile o in objects) if (string.Equals(o.ObjectPath, TopName(s), StringComparison.OrdinalIgnoreCase)) found = true;
                    if (!found) throw new ArgumentException("SCOPE_OBJECT_NOT_FOUND:" + s);
                }
            }
            foreach (TcObjectFile o in objects) CheckObject(o);
            CheckGuids();
            CheckTsproj(projectGuid);
            return Finish();
        }

        private static string TopName(string objectPath)
        {
            int i = objectPath.IndexOf('.');
            return i < 0 ? objectPath : objectPath.Substring(0, i);
        }

        private bool InScope(string objectPath)
        {
            if (opt.ScopeObjects == null) return true;
            foreach (string s in opt.ScopeObjects) if (string.Equals(TopName(s), TopName(objectPath ?? ""), StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // ================================================================ .plcproj items
        private List<string> CheckCompile(List<XElem> compile, List<XElem> folders)
        {
            List<string> objectFiles = new List<string>();
            Dictionary<string, XElem> seen = new Dictionary<string, XElem>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> folderSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (XElem f in folders)
            {
                string inc = f.Attr("Include");
                bool bad;
                if (inc != null) folderSet.Add(MsPath.Unescape(inc, out bad).Replace('/', '\\').Trim('\\'));
            }
            HashSet<string> missingFolderReported = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (XElem c in compile)
            {
                string inc = c.Attr("Include");
                if (string.IsNullOrEmpty(inc))
                {
                    E("PROJECT-XML-004", plcRel, "", "file", c.Line, "<Compile> item without an Include attribute", null, null);
                    continue;
                }
                bool badEscape;
                string unesc = MsPath.Unescape(inc, out badEscape);
                string full = MsPath.Full(plcDir, unesc);
                if (full == null)
                {
                    Emit("PROJECT-COMPILE-006", plcRel, "", "file", c.Line, 1, "Compile Include is not a valid path", inc, null, "invalid-path", null, null, false);
                    continue;
                }
                // SubType
                XElem st = c.Child("SubType");
                if (st == null) Emit("PROJECT-COMPILE-004", plcRel, "", "file", c.Line, 1, "Compile item has no <SubType> (XAE writes <SubType>Code</SubType>)", inc, null, "missing", null, null, false);
                else if (st.InnerText().Trim() != "Code") Emit("PROJECT-COMPILE-004", plcRel, "", "file", st.Line, 1, "Compile <SubType> is '" + st.InnerText().Trim() + "', XAE writes 'Code'", inc, null, "value", null, null, false);
                // duplicate
                XElem first;
                if (seen.TryGetValue(full, out first))
                {
                    E("PROJECT-COMPILE-002", plcRel, "", "file", c.Line, "The same file is listed twice in <Compile> (first at line " + Inv.S(first.Line) + ")", inc,
                        "Remove one of the two <Compile> items");
                    continue;
                }
                seen[full] = c;
                listed.Add(full);
                // existence, escaping, case
                if (!File.Exists(full))
                {
                    string rawFull = MsPath.Full(plcDir, inc);
                    if (badEscape || (rawFull != null && !string.Equals(rawFull, full, StringComparison.OrdinalIgnoreCase) && File.Exists(rawFull)))
                    {
                        Emit("PROJECT-COMPILE-006", plcRel, "", "file", c.Line, 1,
                            "Compile Include has wrong MSBuild escaping: '%' must be written as %25 (the file on disk is '" + inc + "')", inc, null, "escape", null, null, false);
                        if (rawFull != null && File.Exists(rawFull))
                        {
                            listed.Add(rawFull);
                            // the object itself is still checked (under the name it has on disk)
                            if (Path.GetExtension(rawFull).StartsWith(".Tc", StringComparison.OrdinalIgnoreCase)) objectFiles.Add(OnDisk(rawFull));
                        }
                    }
                    else
                    {
                        E("PROJECT-COMPILE-001", plcRel, "", "file", c.Line, "<Compile> points to a file that does not exist", inc,
                            "Restore the file, or remove the <Compile> item and run Reset-TcSolution");
                    }
                    continue;
                }
                if (badEscape)
                    Emit("PROJECT-COMPILE-006", plcRel, "", "file", c.Line, 1, "Compile Include contains a '%' that is not an MSBuild %XX escape", inc, null, "escape", null, null, false);
                string disk = MsPath.DiskSpelling(plcDir, unesc);
                if (disk != null && !string.Equals(disk, unesc.Replace('/', '\\').TrimStart('.', '\\'), StringComparison.Ordinal)
                    && !string.Equals(disk, unesc.Replace('/', '\\'), StringComparison.Ordinal))
                {
                    Emit("PROJECT-COMPILE-006", plcRel, "", "file", c.Line, 1, "Compile Include differs in case from the file on disk ('" + disk + "')", inc, null, "case", null, null, false);
                }
                // Folder items for the directories used
                string dirPart = Path.GetDirectoryName(unesc.Replace('/', '\\'));
                while (!string.IsNullOrEmpty(dirPart) && dirPart != "." )
                {
                    string norm = dirPart.Trim('\\');
                    if (!folderSet.Contains(norm) && missingFolderReported.Add(norm))
                        E("PROJECT-COMPILE-005", plcRel, "", "file", c.Line, "Directory '" + norm + "' is used by <Compile> items but has no <Folder Include> item", inc, null);
                    dirPart = Path.GetDirectoryName(dirPart);
                }
                string ext = Path.GetExtension(full);
                if (ext.StartsWith(".Tc", StringComparison.OrdinalIgnoreCase)) objectFiles.Add(OnDisk(full));
            }
            // object files on disk that are not compiled
            List<string> onDisk = new List<string>();
            CollectObjectFiles(plcDir, onDisk, 0);
            onDisk.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string f in onDisk)
            {
                if (listed.Contains(f)) continue;
                string rel = MsPath.Relative(plcDir, f);
                E("PROJECT-COMPILE-003", rel, "", "file", 1, "Object file is under the project directory but not listed in <Compile>: it is never compiled", rel.Replace('/', '\\'),
                    "Add it to the project (XAE: Add > Existing Item) or move it out of the project directory");
            }
            objectFiles.Sort(StringComparer.OrdinalIgnoreCase);
            return objectFiles;
        }

        // the path with the spelling the file system has (the Include may differ in case: COMPILE-006)
        private string OnDisk(string full)
        {
            string rel = MsPath.Relative(plcDir, full);
            if (rel.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(rel)) return full;
            string disk = MsPath.DiskSpelling(plcDir, rel);
            return disk == null ? full : Path.Combine(plcDir, disk);
        }

        private static void CollectObjectFiles(string dir, List<string> into, int depth)
        {
            if (depth > 32) return;
            try
            {
                foreach (string f in Directory.GetFiles(dir))
                    if (TcObjectExts.Contains(Path.GetExtension(f))) into.Add(Path.GetFullPath(f));
                foreach (string d in Directory.GetDirectories(dir))
                {
                    FileAttributes a = File.GetAttributes(d);
                    if ((a & FileAttributes.ReparsePoint) != 0) continue;
                    CollectObjectFiles(d, into, depth + 1);
                }
            }
            catch (Exception) { }
        }

        private void CheckLibraries(List<XElem> placeholders, List<XElem> resolutions, List<XElem> libs)
        {
            foreach (XElem p in placeholders)
            {
                string inc = p.Attr("Include");
                XElem dr = p.Child("DefaultResolution");
                if (string.IsNullOrEmpty(inc)) E("PROJECT-LIB-001", plcRel, "", "file", p.Line, "<PlaceholderReference> without Include", null, null);
                if (dr == null || dr.InnerText().Trim().Length == 0)
                    E("PROJECT-LIB-001", plcRel, "", "file", p.Line, "<PlaceholderReference> without <DefaultResolution>", inc, "Add the reference with Add-TcLibrary instead of editing the .plcproj");
            }
            foreach (XElem p in resolutions)
            {
                string inc = p.Attr("Include");
                XElem res = p.Child("Resolution");
                if (string.IsNullOrEmpty(inc)) E("PROJECT-LIB-001", plcRel, "", "file", p.Line, "<PlaceholderResolution> without Include", null, null);
                if (res == null || res.InnerText().Trim().Length == 0) E("PROJECT-LIB-001", plcRel, "", "file", p.Line, "<PlaceholderResolution> without <Resolution>", inc, null);
            }
            foreach (XElem p in libs)
            {
                if (string.IsNullOrEmpty(p.Attr("Include"))) E("PROJECT-LIB-001", plcRel, "", "file", p.Line, "<LibraryReference> without Include", null, null);
            }
        }

        // ================================================================ object files
        private void CheckEncoding(string rel, string objectPath, FileBytesInfo fi, bool objectFile)
        {
            string decl = fi.DeclaredEncoding == null ? null : fi.DeclaredEncoding.ToLowerInvariant();
            bool declUtf8 = decl == "utf-8" || decl == "utf8";
            if (fi.Bom == "utf-8" && decl != null && !declUtf8)
                Emit("PROJECT-XML-002", rel, objectPath, "file", 1, 1, "UTF-8 byte order mark but encoding=\"" + fi.DeclaredEncoding + "\"", null, null, "bom-declaration", null, null, false);
            else if ((fi.Bom == "utf-16le" || fi.Bom == "utf-16be") && decl != null && !decl.StartsWith("utf-16", StringComparison.Ordinal) && decl != "unicode")
                Emit("PROJECT-XML-002", rel, objectPath, "file", 1, 1, "UTF-16 byte order mark but encoding=\"" + fi.DeclaredEncoding + "\"", null, null, "bom-declaration", null, null, false);
            else if (fi.InvalidUtf8)
                Emit("PROJECT-XML-002", rel, objectPath, "file", 1, 1, "Bytes are not valid UTF-8 (byte offset " + Inv.S(fi.InvalidUtf8Offset) + ")", null,
                    "Save the file as UTF-8 (XAE writes UTF-8 with BOM)", "invalid-utf8", null, null, false);
            else if (objectFile && fi.Bom == null && !fi.HasDeclaration && fi.NonAscii)
                Emit("PROJECT-XML-002", rel, objectPath, "file", 1, 1, "No XML declaration and no byte order mark, but non-ASCII content", null, null, "undeclared", null, null, false);
        }

        private void LoadObject(string full)
        {
            TcObjectFile o = new TcObjectFile();
            o.FullPath = full; o.Rel = MsPath.Relative(plcDir, full); o.Ext = Path.GetExtension(full);
            o.Name = Path.GetFileNameWithoutExtension(full); o.ObjectPath = o.Name;
            o.Bytes = XmlLoader.ReadBytes(full);
            if (!o.Bytes.ReadFailed && !o.Bytes.InvalidUtf8)
            {
                o.Xml = XmlLoader.Load(full, o.Bytes);
                if (o.Xml.WellFormed && o.Xml.Root != null && o.Xml.Root.Name == "TcPlcObject")
                {
                    foreach (XElem c in o.Xml.Root.Children) { o.Obj = c; break; }
                    if (o.Obj != null)
                    {
                        o.Kind = o.Obj.Name;
                        string n = o.Obj.Attr("Name");
                        if (!string.IsNullOrEmpty(n)) { o.Name = n; o.ObjectPath = n; }
                    }
                }
            }
            o.InScope = InScope(o.ObjectPath);
            objects.Add(o);
        }

        private bool Excluded(string objectPath, out string reason)
        {
            reason = null;
            foreach (ProfileEntry e in opt.Excludes)
            {
                if (string.Equals(e.ObjectPath, objectPath, StringComparison.OrdinalIgnoreCase)
                    || (objectPath.StartsWith(e.ObjectPath + ".", StringComparison.OrdinalIgnoreCase)))
                { reason = e.Reason; return true; }
            }
            return false;
        }

        private void CheckObject(TcObjectFile o)
        {
            if (!o.InScope) { CollectIdsOnly(o); return; }
            objectsInScope++;
            string rel = o.Rel;
            if (o.Bytes.ReadFailed)
            {
                engineDetail.Add(rel + ": " + o.Bytes.ReadError);
                notAnalyzed.Add(Cov(null, rel, o.ObjectPath, "file", "unreadable"));
                SkipBlocking("PROJECT-XML-001", rel, o.ObjectPath, "file-unreadable");
                incompleteByRead = true;
                return;
            }
            bool objectFile = TcObjectExts.Contains(o.Ext);
            CheckEncoding(rel, o.ObjectPath, o.Bytes, true);
            CheckLineEndings(o);
            if (o.Bytes.InvalidUtf8) { notAnalyzed.Add(Cov(null, rel, o.ObjectPath, "file", "invalid-encoding")); return; }
            if (!o.Xml.WellFormed)
            {
                engineDetail.Add(rel + ": " + o.Xml.ErrorDetail);
                Emit("PROJECT-XML-001", rel, o.ObjectPath, "file", o.Xml.ErrorLine, o.Xml.ErrorCol, "File is not well-formed XML; XAE cannot load the object",
                    null, "Fix the XML (usually a broken CDATA section or an unescaped '<' / '&' outside CDATA), or restore the file", null, null, null, false);
                notAnalyzed.Add(Cov(null, rel, o.ObjectPath, "file", "xml-not-well-formed"));
                return;
            }
            objectsAnalyzed++;
            XElem root = o.Xml.Root;
            if (root.Name != "TcPlcObject")
            {
                E("PROJECT-XML-004", rel, o.ObjectPath, "file", root.Line, "Root element is <" + root.Name + ">, XAE writes <TcPlcObject>", null, null);
                return;
            }
            string pv = root.Attr("ProductVersion");
            if (pv != null && !(pv.StartsWith("3.1.4024.", StringComparison.Ordinal) || pv.StartsWith("3.1.4026.", StringComparison.Ordinal)))
            {
                o.Downgrade = true;
                rulesSkipped.Add(Cov("PROJECT-XML-004", rel, o.ObjectPath, null, "unobserved-product-version"));
            }
            if (!root.HasAttr("Version")) Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", root.Line, 1, "<TcPlcObject> has no Version attribute", null, null, "attribute", null, null, o.Downgrade);
            if (root.Children.Count == 0)
            {
                Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", root.Line, 1, "<TcPlcObject> contains no object element", null, null, "missing-element", null, null, o.Downgrade);
                return;
            }
            if (root.Children.Count > 1)
                Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", root.Children[1].Line, 1, "<TcPlcObject> contains more than one object element (XAE writes exactly one)", "<" + root.Children[1].Name + ">", null, "extra-element", null, null, o.Downgrade);
            XElem obj = o.Obj;
            string expected;
            if (KindByExt.TryGetValue(o.Ext, out expected) && obj.Name != expected)
                E("PROJECT-KIND-001", rel, o.ObjectPath, "file", obj.Line, "Object element <" + obj.Name + "> does not match the file extension " + o.Ext + " (expected <" + expected + ">)", null,
                    "Rename the file or fix the element; XAE expects one object kind per extension");
            string name = obj.Attr("Name");
            if (string.IsNullOrEmpty(name)) Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", obj.Line, 1, "<" + obj.Name + "> has no Name attribute", null, null, "attribute", null, null, o.Downgrade);
            else
            {
                string fileBase = Path.GetFileNameWithoutExtension(o.FullPath);
                if (!string.Equals(fileBase, name, StringComparison.Ordinal))
                    E("PROJECT-NAME-002", rel, o.ObjectPath, "file", obj.Line, "File name '" + fileBase + "' differs from the object name '" + name + "'", null, null);
            }
            AddId(obj, o, o.ObjectPath, IdObservedKinds.Contains(obj.Name));

            switch (obj.Name)
            {
                case "POU": CheckPou(o, obj); break;
                case "DUT": CheckSingleDeclaration(o, obj, "TYPE"); break;
                case "GVL": CheckSingleDeclaration(o, obj, "VAR_GLOBAL"); break;
                case "Itf": CheckItf(o, obj); break;
                case "Task": CheckTask(o, obj); break;
                default: break;
            }
        }

        private void CheckLineEndings(TcObjectFile o)
        {
            FileBytesInfo fi = o.Bytes;
            List<string> facts = new List<string>();
            if (fi.Bom != "utf-8") facts.Add(fi.Bom == null ? "no UTF-8 byte order mark" : "byte order mark " + fi.Bom);
            if (fi.BareLf > 0) facts.Add(Inv.S(fi.BareLf) + " LF-only line ends" + (fi.CrLf > 0 ? " mixed with " + Inv.S(fi.CrLf) + " CRLF" : ""));
            if (fi.BareCr > 0) facts.Add(Inv.S(fi.BareCr) + " CR-only line ends");
            if (facts.Count == 0) return;
            E("PROJECT-ENC-001", o.Rel, o.ObjectPath, "file", 1, "File was written outside XAE (" + string.Join("; ", facts.ToArray()) + "); XAE writes UTF-8 with BOM and CRLF", null,
                "Run Reset-TcSolution so XAE reloads the file; XAE rewrites it in its own format when the object is saved");
        }

        private void AddId(XElem e, TcObjectFile o, string objectPath, bool required)
        {
            string id = e.Attr("Id");
            if (id == null)
            {
                if (required && o.InScope) E("PROJECT-GUID-001", o.Rel, objectPath, "file", e.Line, "<" + e.Name + "> has no Id attribute", null,
                    "Give the element a new GUID: '{' + [guid]::NewGuid().ToString() + '}' (lower case, braces)");
                return;
            }
            IdUse u = new IdUse(); u.Id = id; u.File = o.Rel; u.ObjectPath = objectPath; u.Line = e.Line; u.InScope = o.InScope;
            ids.Add(u);
        }

        private void CollectIdsOnly(TcObjectFile o)
        {
            if (o.Obj == null) return;
            AddId(o.Obj, o, o.ObjectPath, false);
            foreach (XElem c in o.Obj.Children)
            {
                if (c.Name == "Method" || c.Name == "Action" || c.Name == "Property" || c.Name == "Transition" || c.Name == "Folder")
                {
                    string n = c.Attr("Name") ?? "?";
                    AddId(c, o, o.ObjectPath + "." + n, false);
                    if (c.Name == "Property")
                        foreach (XElem acc in c.Children) if (acc.Name == "Get" || acc.Name == "Set") AddId(acc, o, o.ObjectPath + "." + n + "." + acc.Name, false);
                }
            }
        }

        // ---------------------------------------------------------------- POU
        private void CheckPou(TcObjectFile o, XElem pou)
        {
            string rel = o.Rel;
            if (!pou.HasAttr("SpecialFunc")) Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", pou.Line, 1, "<POU> has no SpecialFunc attribute (XAE writes SpecialFunc=\"None\")", null, null, "attribute", null, null, o.Downgrade);
            string[] order = { "Declaration", "Implementation", "Folder", "Action", "Method", "LineIds" };
            bool unknownChild = false;
            int lastRank = -1; bool orderOk = true; XElem orderBreak = null;
            foreach (XElem c in pou.Children)
            {
                int rank = Array.IndexOf(order, c.Name);
                if (rank < 0)
                {
                    unknownChild = true;
                    if (c.Name == "Property" || c.Name == "Transition")
                    {
                        rulesNotRun.Add(Cov("PROJECT-XML-004", rel, o.ObjectPath + "." + (c.Attr("Name") ?? "?"), null, "schema-not-observed"));
                        rulesNotRun.Add(Cov("PROJECT-SUB-001", rel, o.ObjectPath + "." + (c.Attr("Name") ?? "?"), null, "schema-not-observed"));
                    }
                    else Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", c.Line, 1, "Unexpected element <" + c.Name + "> in <POU>", null, null, "unexpected-element", "warning", "false", false);
                    continue;
                }
                if (rank < lastRank && orderOk) { orderOk = false; orderBreak = c; }
                if (rank > lastRank) lastRank = rank;
            }
            if (!orderOk && !unknownChild)
                Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", orderBreak.Line, 1,
                    "<" + orderBreak.Name + "> is out of the order XAE writes (Declaration, Implementation, Folder, Action, Method, LineIds)", null, null, "order", "warning", "false", false);
            if (pou.All("Declaration").Count > 1 || pou.All("Implementation").Count > 1)
                Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", pou.Line, 1, "<POU> has more than one Declaration or Implementation", null, null, "extra-element", null, null, o.Downgrade);

            XElem decl = pou.Child("Declaration");
            XElem impl = pou.Child("Implementation");
            if (decl == null) Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", pou.Line, 1, "<POU> has no <Declaration>", null, null, "missing-element", null, null, o.Downgrade);
            if (impl == null) Emit("PROJECT-XML-004", rel, o.ObjectPath, "file", pou.Line, 1, "<POU> has no <Implementation>", null, null, "missing-element", null, null, o.Downgrade);

            Dictionary<string, string> stTexts = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (decl != null)
            {
                DeclInfo di = AnalyzeDeclaration(o, decl, o.ObjectPath);
                if (di != null)
                {
                    o.DeclHeader = di.HeaderKeyword;
                    CheckHeader(o, o.ObjectPath, di, new string[] { "PROGRAM", "FUNCTION_BLOCK", "FUNCTION" }, true);
                }
            }
            if (impl != null)
            {
                string t = AnalyzeImplementation(o, impl, o.ObjectPath);
                if (t != null) stTexts[o.ObjectPath] = t;
            }
            // sub-objects
            Dictionary<string, XElem> memberNames = new Dictionary<string, XElem>(StringComparer.OrdinalIgnoreCase);
            foreach (XElem c in pou.Children)
            {
                if (c.Name != "Method" && c.Name != "Action" && c.Name != "Property" && c.Name != "Transition" && c.Name != "Folder") continue;
                string mname = c.Attr("Name");
                string path = o.ObjectPath + "." + (string.IsNullOrEmpty(mname) ? "?" : mname);
                bool observed = c.Name != "Property" && c.Name != "Transition";
                if (string.IsNullOrEmpty(mname) && observed) Emit("PROJECT-XML-004", rel, path, "file", c.Line, 1, "<" + c.Name + "> has no Name attribute", null, null, "attribute", null, null, o.Downgrade);
                AddId(c, o, path, observed);
                if (c.Name == "Property")
                    foreach (XElem acc in c.Children) if (acc.Name == "Get" || acc.Name == "Set") AddId(acc, o, path + "." + acc.Name, false);
                if (c.Name == "Folder") continue;
                if (!string.IsNullOrEmpty(mname))
                {
                    XElem prev;
                    if (memberNames.TryGetValue(mname, out prev))
                        E("PROJECT-SUB-002", rel, path, "file", c.Line, "Two sub-objects of " + o.ObjectPath + " are named '" + mname + "' (<" + prev.Name + "> at line " + Inv.S(prev.Line) + " and <" + c.Name + ">)", null,
                            "Rename one of them");
                    else memberNames[mname] = c;
                }
                if (!observed)
                {
                    notAnalyzed.Add(Cov(null, rel, path, "file", "schema-not-observed:" + c.Name));
                    continue;
                }
                XElem md = c.Child("Declaration");
                XElem mi = c.Child("Implementation");
                if (c.Name == "Method")
                {
                    if (md == null) Emit("PROJECT-SUB-001", rel, path, "file", c.Line, 1, "<Method> has no <Declaration>", null, null, "missing-declaration", null, null, o.Downgrade);
                    if (mi == null) Emit("PROJECT-SUB-001", rel, path, "file", c.Line, 1, "<Method> has no <Implementation>", null, null, "missing-implementation", null, null, o.Downgrade);
                    CheckChildOrder(o, c, path, new string[] { "Declaration", "Implementation" });
                    if (md != null)
                    {
                        DeclInfo di = AnalyzeDeclaration(o, md, path);
                        if (di != null) CheckHeader(o, path, di, new string[] { "METHOD" }, true);
                    }
                }
                else
                {
                    if (mi == null) Emit("PROJECT-SUB-001", rel, path, "file", c.Line, 1, "<Action> has no <Implementation>", null, null, "missing-implementation", null, null, o.Downgrade);
                    CheckChildOrder(o, c, path, new string[] { "Implementation" });
                }
                if (mi != null)
                {
                    string t = AnalyzeImplementation(o, mi, path);
                    if (t != null) stTexts[path] = t;
                }
            }
            CheckLineIds(o, pou, stTexts);
        }

        private void CheckChildOrder(TcObjectFile o, XElem e, string path, string[] order)
        {
            int last = -1;
            foreach (XElem c in e.Children)
            {
                int rank = Array.IndexOf(order, c.Name);
                if (rank < 0)
                {
                    Emit("PROJECT-XML-004", o.Rel, path, "file", c.Line, 1, "Unexpected element <" + c.Name + "> in <" + e.Name + ">", null, null, "unexpected-element", "warning", "false", false);
                    continue;
                }
                if (rank < last)
                {
                    Emit("PROJECT-XML-004", o.Rel, path, "file", c.Line, 1, "<" + c.Name + "> is out of the order XAE writes (" + string.Join(", ", order) + ")", null, null, "order", "warning", "false", false);
                    return;
                }
                if (rank == last)
                {
                    Emit("PROJECT-XML-004", o.Rel, path, "file", c.Line, 1, "<" + e.Name + "> has more than one <" + c.Name + ">", null, null, "extra-element", null, null, o.Downgrade);
                    return;
                }
                last = rank;
            }
        }

        private void CheckHeader(TcObjectFile o, string path, DeclInfo di, string[] allowed, bool checkName)
        {
            if (!di.HeaderKnown)
            {
                SkipBlocking("PROJECT-KIND-001", o.Rel, path, "declaration-header-not-analyzed:" + (di.State.Reason ?? di.State.ErrorRule ?? "unknown"));
                if (checkName) SkipBlocking("PROJECT-NAME-001", o.Rel, path, "declaration-header-not-analyzed:" + (di.State.Reason ?? di.State.ErrorRule ?? "unknown"));
                return;
            }
            if (Array.IndexOf(allowed, di.HeaderKeyword) < 0)
            {
                string got = di.HeaderKeyword.Length == 0 ? "an empty declaration" : di.HeaderKeyword;
                E("PROJECT-KIND-001", o.Rel, path, "declaration", di.Name != null ? di.NameLine : 1,
                    "Declaration starts with " + got + ", but the object is <" + (path == o.ObjectPath ? o.Kind : "Method") + "> (expected " + string.Join(" / ", allowed) + ")", null, null);
                return;
            }
            if (!checkName || di.Name == null) return;
            string attrName = path == o.ObjectPath ? o.Obj.Attr("Name") : path.Substring(path.LastIndexOf('.') + 1);
            if (!string.IsNullOrEmpty(attrName) && attrName != "?" && !string.Equals(attrName, di.Name, StringComparison.OrdinalIgnoreCase))
                E("PROJECT-NAME-001", o.Rel, path, "declaration", di.NameLine, "Name attribute '" + attrName + "' differs from the declared name '" + di.Name + "'", di.HeaderKeyword + " " + di.Name,
                    "Make the Name attribute, the declaration and the file name the same");
        }

        private void CheckSingleDeclaration(TcObjectFile o, XElem obj, string header)
        {
            XElem decl = null;
            foreach (XElem c in obj.Children)
            {
                if (c.Name == "Declaration" && decl == null) { decl = c; continue; }
                Emit("PROJECT-XML-004", o.Rel, o.ObjectPath, "file", c.Line, 1, "Unexpected element <" + c.Name + "> in <" + obj.Name + "> (XAE writes only <Declaration>)", null, null, "unexpected-element", "warning", "false", false);
            }
            if (decl == null) { Emit("PROJECT-XML-004", o.Rel, o.ObjectPath, "file", obj.Line, 1, "<" + obj.Name + "> has no <Declaration>", null, null, "missing-element", null, null, o.Downgrade); return; }
            DeclInfo di = AnalyzeDeclaration(o, decl, o.ObjectPath);
            if (di == null) return;
            if (header == "TYPE") CheckHeader(o, o.ObjectPath, di, new string[] { "TYPE" }, true);
            else CheckHeader(o, o.ObjectPath, di, new string[] { "VAR_GLOBAL" }, false);
        }

        private void CheckItf(TcObjectFile o, XElem itf)
        {
            rulesNotRun.Add(Cov("PROJECT-XML-004", o.Rel, o.ObjectPath, null, "schema-not-observed"));
            rulesNotRun.Add(Cov("PROJECT-SUB-001", o.Rel, o.ObjectPath, null, "schema-not-observed"));
            XElem decl = itf.Child("Declaration");
            if (decl != null)
            {
                DeclInfo di = AnalyzeDeclaration(o, decl, o.ObjectPath);
                if (di != null) CheckHeader(o, o.ObjectPath, di, new string[] { "INTERFACE" }, true);
            }
            foreach (XElem c in itf.Children)
            {
                if (c.Name != "Method" && c.Name != "Property") continue;
                string path = o.ObjectPath + "." + (c.Attr("Name") ?? "?");
                AddId(c, o, path, false);
                if (c.Name == "Property")
                    foreach (XElem acc in c.Children) if (acc.Name == "Get" || acc.Name == "Set") AddId(acc, o, path + "." + acc.Name, false);
                XElem md = c.Child("Declaration");
                if (c.Name == "Method" && md != null) AnalyzeDeclaration(o, md, path);
            }
        }

        private void CheckTask(TcObjectFile o, XElem task)
        {
            string[] order = { "CycleTime", "Priority", "PouCall", "TaskFBGuid", "Fb_init", "Fb_exit", "CycleUpdate", "PostCycleUpdate", "ObjectProperties" };
            string[] required = { "CycleTime", "Priority", "PouCall", "TaskFBGuid", "Fb_init", "Fb_exit", "CycleUpdate", "PostCycleUpdate" };
            o.TaskLine = task.Line;
            foreach (string r in required)
                if (task.Child(r) == null) Emit("PROJECT-XML-004", o.Rel, o.ObjectPath, "file", task.Line, 1, "<Task> has no <" + r + ">", null, null, "missing-element", null, null, o.Downgrade);
            int last = -1;
            foreach (XElem c in task.Children)
            {
                int rank = Array.IndexOf(order, c.Name);
                if (rank < 0) { Emit("PROJECT-XML-004", o.Rel, o.ObjectPath, "file", c.Line, 1, "Unexpected element <" + c.Name + "> in <Task>", null, null, "unexpected-element", "warning", "false", false); continue; }
                if (rank < last) { Emit("PROJECT-XML-004", o.Rel, o.ObjectPath, "file", c.Line, 1, "<" + c.Name + "> is out of the order XAE writes", null, null, "order", "warning", "false", false); break; }
                if (rank != 2) last = rank; else last = Math.Max(last, rank);
            }
            XElem pr = task.Child("Priority");
            if (pr != null) o.TaskPriority = pr.InnerText().Trim();
            foreach (XElem pc in task.All("PouCall"))
            {
                XElem n = pc.Child("Name");
                if (n != null && n.InnerText().Trim().Length > 0) o.PouCalls.Add(n.InnerText().Trim());
            }
        }

        // ---------------------------------------------------------------- code sections
        private bool CheckCData(TcObjectFile o, XElem e, string path)
        {
            XText stray = e.StrayText();
            if (stray != null)
            {
                Emit("PROJECT-XML-003", o.Rel, path, "file", stray.Line, 1, "<" + e.Name + "> contains text outside the CDATA section (the code is cut or not wrapped in CDATA)",
                    Short(stray.Value), "Put the whole code in one <![CDATA[ ... ]]> section; code containing ']]>' must be split by XAE, not by hand", "text-outside-cdata", null, "true", false);
                return false;
            }
            if (e.CDataCount() > 1)
            {
                Emit("PROJECT-XML-003", o.Rel, path, "file", e.Line, 1, "<" + e.Name + "> has " + Inv.S(e.CDataCount()) + " CDATA sections (XAE wrote one in every observed file)",
                    null, null, "multiple-cdata", null, "pending", false);
            }
            return true;
        }

        private static string Short(string s)
        {
            s = s.Trim().Replace("\r", " ").Replace("\n", " ");
            return s.Length > 80 ? s.Substring(0, 80) + "..." : s;
        }

        private DeclInfo AnalyzeDeclaration(TcObjectFile o, XElem decl, string path)
        {
            CheckCData(o, decl, path);
            string text = decl.InnerText();
            DeclInfo di = StAnalyzer.ParseDeclaration(text);
            string reason;
            if (Excluded(path, out reason))
            {
                excluded.Add(Cov(null, o.Rel, path, "declaration", reason));
                return di;
            }
            ReportState(o, path, "declaration", di.State);
            return di;
        }

        private string AnalyzeImplementation(TcObjectFile o, XElem impl, string path)
        {
            List<XElem> st = impl.All("ST");
            string reason;
            if (st.Count == 0)
            {
                string lang = null;
                foreach (XElem c in impl.Children) { lang = c.Name; break; }
                if (lang == null)
                {
                    Emit("PROJECT-XML-004", o.Rel, path, "file", impl.Line, 1, "<Implementation> is empty (XAE writes <ST><![CDATA[]]></ST> for empty code)", null, null, "missing-element", null, null, o.Downgrade);
                    return null;
                }
                if (Excluded(path, out reason)) excluded.Add(Cov(null, o.Rel, path, "implementation", reason));
                else notAnalyzed.Add(Cov(null, o.Rel, path, "implementation", "language:" + lang));
                return null;
            }
            foreach (XElem c in impl.Children)
                if (c.Name != "ST") Emit("PROJECT-XML-004", o.Rel, path, "file", c.Line, 1, "Unexpected element <" + c.Name + "> next to <ST> in <Implementation>", null, null, "unexpected-element", "warning", "false", false);
            StringBuilder sb = new StringBuilder();
            bool multi = st.Count > 1;
            for (int i = 0; i < st.Count; i++)
            {
                CheckCData(o, st[i], path);
                if (i > 0) sb.Append('\n');
                sb.Append(st[i].InnerText());
            }
            if (multi)
            {
                Diagnostic d = Emit("LINT-XML-002", o.Rel, path, "file", st[1].Line, 1, "<Implementation> has " + Inv.S(st.Count) + " <ST> elements; all are analysed as one text", null, null, null, null, null, false);
                if (d != null) d.LineUnreliable = true;
            }
            string text = sb.ToString();
            if (Excluded(path, out reason))
            {
                excluded.Add(Cov(null, o.Rel, path, "implementation", reason));
                return multi ? null : text;
            }
            ScanResult sr = StAnalyzer.ScanImplementation(text);
            ReportState(o, path, "implementation", sr.State);
            if (multi)
                foreach (Diagnostic d in diags) if (d.ObjectPath == path && d.Section == "implementation") d.LineUnreliable = true;
            return multi ? null : text;
        }

        private void ReportState(TcObjectFile o, string path, string section, SectionStatus s)
        {
            if (s.Status == "not-analyzed") notAnalyzed.Add(Cov(null, o.Rel, path, section, s.Reason));
            else if (s.Status == "parse-failed")
            {
                Emit(s.ErrorRule, o.Rel, path, section, s.ErrorLine, s.ErrorCol, "Cannot parse the " + section + ": " + s.ErrorMessage, null,
                    "Run BuildProject: if the build succeeds, this is a linter limitation (open an issue and exclude the object in the profile with a reason)", null, null, null, false);
            }
        }

        // ---------------------------------------------------------------- LineIds
        private void CheckLineIds(TcObjectFile o, XElem pou, Dictionary<string, string> stTexts)
        {
            List<XElem> lineIds = pou.All("LineIds");
            if (lineIds.Count == 0) return;
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (XElem li in lineIds)
            {
                string name = li.Attr("Name");
                if (string.IsNullOrEmpty(name)) { E("PROJECT-LINEIDS-001", o.Rel, o.ObjectPath, "file", li.Line, "<LineIds> without Name", null, null); continue; }
                if (!seen.Add(name)) { E("PROJECT-LINEIDS-001", o.Rel, o.ObjectPath, "file", li.Line, "Two <LineIds> for '" + name + "'", null, null); continue; }
                string text;
                if (!stTexts.TryGetValue(name, out text))
                {
                    E("PROJECT-LINEIDS-001", o.Rel, o.ObjectPath, "file", li.Line, "<LineIds Name=\"" + name + "\"> names no ST implementation of this POU", null, null);
                    continue;
                }
                long sum = 0; bool malformed = false;
                foreach (XElem id in li.All("LineId"))
                {
                    int count;
                    if (!int.TryParse(id.Attr("Count") ?? "", NumberStyles.Integer, CultureInfo.InvariantCulture, out count)) { malformed = true; break; }
                    sum += count + 1;
                }
                if (malformed) { E("PROJECT-LINEIDS-001", o.Rel, o.ObjectPath, "file", li.Line, "<LineId> with a missing or non-numeric Count in '" + name + "'", null, null); continue; }
                int lines = StAnalyzer.CountLines(text);
                if (sum != lines)
                    E("PROJECT-LINEIDS-001", o.Rel, name, "file", li.Line, "<LineIds> of '" + name + "' cover " + sum.ToString(CultureInfo.InvariantCulture) + " lines, the implementation has " + Inv.S(lines) + " (code changed outside XAE?)", null,
                        "Run Reset-TcSolution; XAE rewrites LineIds when the object is saved (not measured whether it rebuilds them)");
            }
            List<string> sections = new List<string>(stTexts.Keys);
            sections.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string s in sections)
                if (!seen.Contains(s)) E("PROJECT-LINEIDS-001", o.Rel, s, "file", pou.Line, "ST implementation '" + s + "' has no <LineIds> while other parts of the POU have (member added outside XAE?)", null, null);
        }

        // ================================================================ GUIDs
        private void CheckGuids()
        {
            Dictionary<string, List<IdUse>> byId = new Dictionary<string, List<IdUse>>(StringComparer.OrdinalIgnoreCase);
            foreach (IdUse u in ids)
            {
                if (!GuidRx.IsMatch(u.Id))
                {
                    if (u.InScope) E("PROJECT-GUID-002", u.File, u.ObjectPath, "file", u.Line, "Id '" + u.Id + "' is not a {8-4-4-4-12} hexadecimal GUID in braces", u.Id,
                        "Use a new GUID: '{' + [guid]::NewGuid().ToString() + '}'");
                    continue;
                }
                string hex = u.Id.Substring(1, 36).Replace("-", "");
                if (hex.Trim('0').Length == 0)
                {
                    if (u.InScope) E("PROJECT-GUID-004", u.File, u.ObjectPath, "file", u.Line, "Id is the all-zero GUID", u.Id, "Use a new GUID: '{' + [guid]::NewGuid().ToString() + '}'");
                }
                else if (u.InScope)
                {
                    string why = FakeGuid(u.Id.Substring(1, 36));
                    if (why != null) E("PROJECT-GUID-005", u.File, u.ObjectPath, "file", u.Line, "Id looks hand-written (" + why + ")", u.Id,
                        "Replace it with a new GUID ('{' + [guid]::NewGuid().ToString() + '}'); copied hand-written Ids collide");
                }
                List<IdUse> l;
                if (!byId.TryGetValue(u.Id, out l)) { l = new List<IdUse>(); byId[u.Id] = l; }
                l.Add(u);
            }
            List<string> keys = new List<string>(byId.Keys);
            keys.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string k in keys)
            {
                List<IdUse> l = byId[k];
                if (l.Count < 2) continue;
                bool anyInScope = false;
                foreach (IdUse u in l) if (u.InScope) anyInScope = true;
                if (!anyInScope) continue;
                foreach (IdUse u in l)
                {
                    if (!u.InScope) continue;
                    List<string> others = new List<string>();
                    foreach (IdUse x in l) if (!ReferenceEquals(x, u)) others.Add(x.ObjectPath + " (" + x.File + ")");
                    others.Sort(StringComparer.Ordinal);
                    E("PROJECT-GUID-003", u.File, u.ObjectPath, "file", u.Line, "Id " + u.Id + " is also used by " + string.Join(", ", others.ToArray()), u.Id,
                        "Give the copied object a new GUID ('{' + [guid]::NewGuid().ToString() + '}')");
                }
            }
        }

        // PROJECT-GUID-005 heuristics (rule-catalog.md: sequence / repeated characters / a1b2c3d4 style)
        public static string FakeGuid(string g)
        {
            string[] groups = g.ToLowerInvariant().Split('-');
            string hex = string.Join("", groups);
            int run = 1;
            for (int i = 1; i < hex.Length; i++)
            {
                if (HexVal(hex[i]) == HexVal(hex[i - 1]) + 1) { run++; if (run >= 5) return "ascending digit run"; }
                else run = 1;
            }
            run = 1;
            for (int i = 1; i < hex.Length; i++)
            {
                if (hex[i] == hex[i - 1]) { run++; if (run >= 6) return "repeated digit run"; }
                else run = 1;
            }
            for (int k = 1; k <= 3 && k < groups.Length; k++)
            {
                string grp = groups[k];
                // group 3 starts with the version nibble: "4444" in a version-4 GUID happens by chance (1/4096)
                if (k == 2 && grp.Length > 0 && grp[0] == '4') continue;
                if (grp.Length == 4 && grp.Trim(grp[0]).Length == 0) return "group of one repeated digit";
            }
            if (groups.Length == 5 && groups[4].Length == 12)
            {
                string last = groups[4];
                if (last.Substring(0, 4).Trim(last[0]).Length == 0 && last.Substring(4, 4).Trim(last[4]).Length == 0 && last.Substring(8, 4).Trim(last[8]).Length == 0) return "group of one repeated digit";
            }
            return null;
        }

        private static int HexVal(char c) { return c <= '9' ? c - '0' : c - 'a' + 10; }

        // ================================================================ .tsproj / .sln
        private void FindSolution()
        {
            if (opt.SolutionPath != null && opt.SolutionPath.EndsWith(".sln", StringComparison.OrdinalIgnoreCase)) { slnFull = Path.GetFullPath(opt.SolutionPath); }
            else
            {
                string d = plcDir;
                for (int i = 0; i < 12 && d != null; i++)
                {
                    string[] slns;
                    try { slns = Directory.GetFiles(d, "*.sln"); } catch (Exception) { slns = new string[0]; }
                    if (slns.Length > 0)
                    {
                        Array.Sort(slns, StringComparer.OrdinalIgnoreCase);
                        foreach (string s in slns)
                        {
                            foreach (string ts in LintEngine.SlnTsprojs(s))
                            {
                                List<PlcRef> refs = LintEngine.ReadPlcRefs(ts);
                                if (refs == null) continue;
                                foreach (PlcRef r in refs) if (r.PlcprojFull != null && string.Equals(r.PlcprojFull, plcFull, StringComparison.OrdinalIgnoreCase)) { slnFull = s; break; }
                                if (slnFull != null) break;
                            }
                            if (slnFull != null) break;
                        }
                        if (slnFull == null) slnFull = slns[0];
                        break;
                    }
                    if (Directory.Exists(Path.Combine(d, ".git")) || File.Exists(Path.Combine(d, ".git"))) break;
                    d = Path.GetDirectoryName(d);
                }
            }
            if (opt.TsprojPath != null) tsprojFull.Add(Path.GetFullPath(opt.TsprojPath));
            else if (slnFull != null) tsprojFull.AddRange(LintEngine.SlnTsprojs(slnFull));
            else
            {
                foreach (string d in new string[] { plcDir, Path.GetDirectoryName(plcDir) })
                {
                    if (d == null) continue;
                    try
                    {
                        string[] f = Directory.GetFiles(d, "*.tsproj");
                        Array.Sort(f, StringComparer.OrdinalIgnoreCase);
                        tsprojFull.AddRange(f);
                    }
                    catch (Exception) { }
                }
            }
        }

        private void CheckTsprojForMissingPlcproj()
        {
            string ts = opt.TsprojPath == null ? null : Path.GetFullPath(opt.TsprojPath);
            string tsRel = ts == null ? "" : MsPath.Relative(plcDir, ts);
            List<PlcRef> refs = ts == null ? null : LintEngine.ReadPlcRefs(ts);
            int line = 1;
            if (refs != null) foreach (PlcRef r in refs) if (r.PlcprojFull != null && string.Equals(r.PlcprojFull, plcFull, StringComparison.OrdinalIgnoreCase)) line = r.Element.Line;
            E("PROJECT-TSPROJ-001", tsRel, "", "file", line, "The .tsproj references a .plcproj that does not exist: " + plcFull, null,
                "Fix PrjFilePath in the .tsproj or restore the PLC project directory");
        }

        private void CheckTsproj(string projectGuid)
        {
            FindSolution();
            if (tsprojFull.Count == 0)
            {
                SkipBlocking("PROJECT-TSPROJ-001", plcRel, "", "no-tsproj-found");
                SkipBlocking("PROJECT-TSPROJ-002", plcRel, "", "no-tsproj-found");
                SkipBlocking("PROJECT-TSPROJ-003", plcRel, "", "no-tsproj-found");
                return;
            }
            PlcRef mine = null;
            string slnText = null;
            if (slnFull != null) { try { slnText = File.ReadAllText(slnFull); } catch (Exception) { slnText = null; } }
            foreach (string ts in tsprojFull)
            {
                string tsRel = MsPath.Relative(plcDir, ts);
                if (!File.Exists(ts))
                {
                    E("PROJECT-TSPROJ-001", slnFull == null ? tsRel : MsPath.Relative(plcDir, slnFull), "", "file", 1, "The .sln references a .tsproj that does not exist: " + tsRel, null, null);
                    continue;
                }
                FileBytesInfo fi = XmlLoader.ReadBytes(ts);
                if (fi.ReadFailed) { engineDetail.Add(tsRel + ": " + fi.ReadError); notAnalyzed.Add(Cov(null, tsRel, "", "file", "unreadable")); incompleteByRead = true; continue; }
                CheckEncoding(tsRel, "", fi, false);
                XmlLoad x = XmlLoader.Load(ts, fi);
                if (!x.WellFormed)
                {
                    engineDetail.Add(tsRel + ": " + x.ErrorDetail);
                    Emit("PROJECT-XML-001", tsRel, "", "file", x.ErrorLine, x.ErrorCol, "The .tsproj is not well-formed XML", null, null, null, null, null, false);
                    continue;
                }
                foreach (PlcRef r in LintEngine.PlcRefsFrom(x.Root, ts))
                {
                    if (r.IndependentFile) { rulesNotRun.Add(Cov("PROJECT-TSPROJ-001", tsRel, r.Name ?? "", null, "schema-not-observed:independent-file")); continue; }
                    if (r.PrjFilePath == null || r.PlcprojFull == null)
                    {
                        E("PROJECT-TSPROJ-001", tsRel, "", "file", r.Element.Line, "PLC project '" + (r.Name ?? "?") + "' has no PrjFilePath", null, null);
                        continue;
                    }
                    if (!File.Exists(r.PlcprojFull))
                    {
                        E("PROJECT-TSPROJ-001", tsRel, "", "file", r.Element.Line, "PLC project '" + (r.Name ?? "?") + "' points to a .plcproj that does not exist", r.PrjFilePath,
                            "Fix PrjFilePath or restore the PLC project");
                        continue;
                    }
                    string disk = MsPath.DiskSpelling(Path.GetDirectoryName(ts), r.PrjFilePath);
                    if (disk != null && !string.Equals(disk, r.PrjFilePath.Replace('/', '\\').TrimStart('.', '\\'), StringComparison.Ordinal) && !string.Equals(disk, r.PrjFilePath.Replace('/', '\\'), StringComparison.Ordinal))
                        Emit("PROJECT-TSPROJ-001", tsRel, "", "file", r.Element.Line, 1, "PrjFilePath differs in case from the disk ('" + disk + "')", r.PrjFilePath, null, "path-case", null, null, false);
                    if (string.Equals(r.PlcprojFull, plcFull, StringComparison.OrdinalIgnoreCase))
                    {
                        if (mine == null) mine = r;
                        // TSPROJ-002: GUID in .tsproj vs .plcproj vs .sln
                        if (projectGuid == null)
                            E("PROJECT-TSPROJ-002", plcRel, "", "file", 1, "The .plcproj has no <ProjectGuid>", null, null);
                        else if (r.Guid == null || !string.Equals(r.Guid.Trim(), projectGuid, StringComparison.OrdinalIgnoreCase))
                            E("PROJECT-TSPROJ-002", tsRel, "", "file", r.Element.Line, "PLC project GUID in the .tsproj (" + (r.Guid ?? "none") + ") differs from <ProjectGuid> of the .plcproj (" + projectGuid + ")", null,
                                "The three places must hold the same GUID (case does not matter): .plcproj ProjectGuid, .tsproj Plc/Project@GUID, .sln ProjectConfigurationPlatforms");
                        if (projectGuid != null && slnText != null && slnFull != null && tsprojFull.Count > 0)
                        {
                            string section = SlnSection(slnText, "ProjectConfigurationPlatforms");
                            if (section != null && section.IndexOf(projectGuid, StringComparison.OrdinalIgnoreCase) < 0)
                                E("PROJECT-TSPROJ-002", MsPath.Relative(plcDir, slnFull), "", "file", 1, "The .sln ProjectConfigurationPlatforms section has no entry for the PLC project GUID " + projectGuid, null, null);
                        }
                    }
                }
                if (mine != null && string.Equals(mine.TsprojFull, ts, StringComparison.OrdinalIgnoreCase)) CheckTasks(mine, tsRel);
            }
            if (mine == null)
            {
                E("PROJECT-TSPROJ-001", plcRel, "", "file", 1, "No .tsproj " + (slnFull != null ? "of the solution " : "next to the project ") + "references this .plcproj", null,
                    "Check PrjFilePath of Plc/Project in the .tsproj");
            }
        }

        private static string SlnSection(string text, string name)
        {
            int i = text.IndexOf("GlobalSection(" + name + ")", StringComparison.Ordinal);
            if (i < 0) return null;
            int j = text.IndexOf("EndGlobalSection", i, StringComparison.Ordinal);
            return j < 0 ? text.Substring(i) : text.Substring(i, j - i);
        }

        private void CheckTasks(PlcRef plc, string tsRel)
        {
            // tasks of this PLC project in the .tsproj: Instance/Contexts/Context
            List<XElem> contexts = new List<XElem>();
            foreach (XElem inst in plc.Element.All("Instance"))
                foreach (XElem cs in inst.All("Contexts"))
                    contexts.AddRange(cs.All("Context"));
            List<TcObjectFile> ttos = new List<TcObjectFile>();
            foreach (TcObjectFile o in objects) if (o.Kind == "Task" && string.Equals(o.Ext, ".TcTTO", StringComparison.OrdinalIgnoreCase)) ttos.Add(o);
            if (contexts.Count == 0 && ttos.Count > 0)
            {
                rulesNotRun.Add(Cov("PROJECT-TSPROJ-003", tsRel, "", null, "schema-not-observed:no-contexts"));
            }
            else
            {
                Dictionary<string, XElem> ctxByName = new Dictionary<string, XElem>(StringComparer.OrdinalIgnoreCase);
                foreach (XElem c in contexts)
                {
                    XElem n = c.Child("Name");
                    if (n != null) ctxByName[n.InnerText().Trim()] = c;
                }
                HashSet<string> ttoNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (TcObjectFile t in ttos)
                {
                    ttoNames.Add(t.Name);
                    XElem ctx;
                    if (!ctxByName.TryGetValue(t.Name, out ctx))
                    {
                        E("PROJECT-TSPROJ-003", t.Rel, t.ObjectPath, "file", t.TaskLine, "Task '" + t.Name + "' (.TcTTO) has no matching task context in the .tsproj PLC project", null,
                            "Create tasks with Add-TcPlcTask instead of copying .TcTTO files");
                        continue;
                    }
                    XElem p = ctx.Child("Priority");
                    if (p != null && t.TaskPriority != null && p.InnerText().Trim() != t.TaskPriority)
                        Emit("PROJECT-TSPROJ-003", t.Rel, t.ObjectPath, "file", t.TaskLine, 1, "Task '" + t.Name + "' priority " + t.TaskPriority + " differs from the .tsproj (" + p.InnerText().Trim() + ")", null, null,
                            "priority-mismatch", "warning", "false", false);
                }
                List<string> ctxNames = new List<string>(ctxByName.Keys);
                ctxNames.Sort(StringComparer.OrdinalIgnoreCase);
                foreach (string n in ctxNames)
                    if (!ttoNames.Contains(n))
                        E("PROJECT-TSPROJ-003", tsRel, "", "file", ctxByName[n].Line, "The .tsproj PLC project has task context '" + n + "' but the project has no matching .TcTTO", null, null);
            }
            // PouCall -> PROGRAM
            Dictionary<string, TcObjectFile> pous = new Dictionary<string, TcObjectFile>(StringComparer.OrdinalIgnoreCase);
            bool unreadablePou = false;
            foreach (TcObjectFile o in objects)
            {
                if (o.Kind == "POU" && !pous.ContainsKey(o.Name)) pous[o.Name] = o;
                // a .TcPOU that could not be read / parsed: its name is unknown, so a PouCall that
                // names no known POU cannot be judged (the file already has its own finding)
                if (o.Obj == null && string.Equals(o.Ext, ".TcPOU", StringComparison.OrdinalIgnoreCase)) unreadablePou = true;
            }
            foreach (TcObjectFile t in ttos)
            {
                foreach (string call in t.PouCalls)
                {
                    TcObjectFile target;
                    if (!pous.TryGetValue(call, out target) && unreadablePou)
                        rulesSkipped.Add(Cov("PROJECT-TSPROJ-003", t.Rel, t.ObjectPath, null, "pou-call-target-unreadable"));
                    else if (target == null)
                        E("PROJECT-TSPROJ-003", t.Rel, t.ObjectPath, "file", t.TaskLine, "Task '" + t.Name + "' calls '" + call + "', which is not a POU of this project", call, null);
                    else if (target.DeclHeader != null && target.DeclHeader.Length > 0 && target.DeclHeader != "PROGRAM")
                        E("PROJECT-TSPROJ-003", t.Rel, t.ObjectPath, "file", t.TaskLine, "Task '" + t.Name + "' calls '" + call + "', which is a " + target.DeclHeader + ", not a PROGRAM", call, null);
                }
            }
        }

        // ================================================================ result
        private OrderedDictionary Finish()
        {
            // profile suppressions (objectPath + ruleId; objectPath may name the file for project-level findings)
            foreach (Diagnostic d in diags)
            {
                foreach (ProfileEntry s in opt.Suppressions)
                {
                    if (s.RuleId != d.RuleId) continue;
                    bool match = d.ObjectPath.Length > 0 ? string.Equals(s.ObjectPath, d.ObjectPath, StringComparison.OrdinalIgnoreCase)
                        : string.Equals(s.ObjectPath.Replace('\\', '/'), d.File, StringComparison.OrdinalIgnoreCase);
                    if (match) { d.Suppressed = true; d.SuppressionReason = s.Reason; break; }
                }
            }
            int failRank = Diagnostic.SeverityRank(opt.FailOn);
            foreach (Diagnostic d in diags)
            {
                RuleOverride ov;
                overrides.TryGetValue(d.RuleId, out ov);
                if (ov != null && ov.Severity != null) d.Severity = ov.Severity;
                if (d.Suppressed) { d.Blocking = false; continue; }
                bool? profileBlocking = ov == null ? null : ov.Blocking;
                if (profileBlocking.HasValue && !profileBlocking.Value) { d.Blocking = false; continue; }
                if (d.Blockable == "false")
                {
                    d.Blocking = profileBlocking.HasValue && profileBlocking.Value;
                    if (d.Blocking) d.BlockingSource = "profile";
                    continue;
                }
                bool sevOk = Diagnostic.SeverityRank(d.Severity) >= failRank;
                bool conf = d.Confidence == "high";
                d.Blocking = sevOk && (conf || (profileBlocking.HasValue && profileBlocking.Value));
                if (d.Blocking && !conf) d.BlockingSource = "profile";
            }
            diags.Sort(new DiagnosticComparer());

            // accepted skips
            List<CoverageEntry> stillBlocking = new List<CoverageEntry>();
            List<CoverageEntry> accepted = new List<CoverageEntry>();
            foreach (CoverageEntry c in blockingSkipped)
            {
                ProfileEntry hit = null;
                foreach (ProfileEntry a in opt.AcceptSkips)
                    if (a.RuleId == c.RuleId && (string.Equals(a.ObjectPath, c.ObjectPath, StringComparison.OrdinalIgnoreCase) || (c.ObjectPath == "" && string.Equals(a.ObjectPath.Replace('\\', '/'), c.File, StringComparison.OrdinalIgnoreCase)))) { hit = a; break; }
                if (hit == null) stillBlocking.Add(c);
                else { CoverageEntry x = Cov(c.RuleId, c.File, c.ObjectPath, null, c.Reason + "; accepted: " + hit.Reason); accepted.Add(x); }
            }

            int errors = 0, warnings = 0, infos = 0, blocking = 0, suppressed = 0;
            bool parseDiag = false;
            ArrayList diagList = new ArrayList();
            ArrayList unresolved = new ArrayList();
            foreach (Diagnostic d in diags)
            {
                diagList.Add(d.ToDictionary());
                if (d.Suppressed) { suppressed++; continue; }
                if (d.Severity == "error") errors++; else if (d.Severity == "warning") warnings++; else infos++;
                if (d.Blocking) blocking++;
                if (d.RuleId.StartsWith("LINT-PARSE-", StringComparison.Ordinal)) parseDiag = true;
                RuleMeta r = RuleRegistry.Get(d.RuleId);
                if (r != null && (r.MachineImpact == "behavior" || r.MachineImpact == "crash") && r.CompilerCatches != "yes")
                {
                    OrderedDictionary u = new OrderedDictionary();
                    u["ruleId"] = d.RuleId; u["severity"] = d.Severity; u["blocking"] = d.Blocking; u["file"] = d.File; u["objectPath"] = d.ObjectPath;
                    u["section"] = d.Section; u["line"] = d.Line; u["message"] = d.Message;
                    unresolved.Add(u);
                }
            }
            string verdict, code;
            if (parseFailed || parseDiag) { verdict = "fail"; code = "LINT_PARSE_FAILED"; }
            else if (stillBlocking.Count > 0 || incompleteByRead) { verdict = "incomplete"; code = "LINT_INCOMPLETE"; }
            else if (blocking > 0) { verdict = "fail"; code = "LINT_FAILED"; }
            else { verdict = "pass"; code = null; }

            OrderedDictionary res = new OrderedDictionary();
            res["verdict"] = verdict;
            res["code"] = code;
            OrderedDictionary summary = new OrderedDictionary();
            summary["errors"] = errors; summary["warnings"] = warnings; summary["infos"] = infos; summary["blocking"] = blocking; summary["suppressed"] = suppressed;
            summary["unresolved"] = unresolved.Count;
            res["summary"] = summary;
            res["diagnostics"] = diagList;
            res["unresolved"] = unresolved;
            res["requiresDisposition"] = unresolved.Count > 0;
            OrderedDictionary cov = new OrderedDictionary();
            cov["objectsInScope"] = objectsInScope;
            cov["objectsAnalyzed"] = objectsAnalyzed;
            cov["notAnalyzed"] = CoverageSort.ToSortedList(notAnalyzed);
            cov["excluded"] = CoverageSort.ToSortedList(excluded);
            cov["rulesSkipped"] = CoverageSort.ToSortedList(rulesSkipped);
            cov["blockingRulesSkipped"] = CoverageSort.ToSortedList(stillBlocking);
            cov["acceptedSkips"] = CoverageSort.ToSortedList(accepted);
            cov["rulesNotRun"] = CoverageSort.ToSortedList(rulesNotRun);
            res["coverage"] = cov;
            OrderedDictionary src = new OrderedDictionary();
            src["kind"] = "disk";
            src["plcProjectPath"] = plcFull;
            src["solutionPath"] = slnFull;
            ArrayList ts = new ArrayList(); foreach (string t in tsprojFull) ts.Add(t);
            src["tsprojPaths"] = ts;
            res["source"] = src;
            ArrayList rules = new ArrayList();
            foreach (RuleMeta r in RuleRegistry.All()) if (Enabled(r.Id)) rules.Add(r.Id + "@" + Inv.S(r.Version));
            res["rulesRun"] = rules;
            List<string> det = new List<string>(engineDetail); det.Sort(StringComparer.Ordinal);
            res["engineDetail"] = new ArrayList(det);
            return res;
        }
    }
}
