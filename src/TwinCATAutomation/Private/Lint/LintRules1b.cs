// TwinCAT Semantic Linter (#252) - Phase 1b: FB type catalog, SCAN-TEMPFB-001, PROJECT-TASK-001 / 002
// (call graph from .TcTTO PouCall), inline suppression (LINT-SUPPRESS-001..004). C# 5 (see LintCore.cs).
namespace TcLintEngine
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Globalization;
    using System.Text;
    using System.Text.RegularExpressions;

    // ---------------------------------------------------------------- type catalog entries (filled by PowerShell)
    public sealed class CatalogType
    {
        public string Name;
        public string Library;   // library name, or "profile"
        public string Kind;      // stateful / type-only / function-block
        public string Class;     // stateful only: timer / edge / counter / bistable (profile entries: profile)
        public string Source;    // InfoSys URL, or the profile path
    }

    // ---------------------------------------------------------------- inline suppression directives
    public sealed class Directive
    {
        public string Kind;           // next-line / line / object
        public List<string> Ids = new List<string>();
        public string Reason;
        public string Problem;        // null = well-formed; else why it is not effective (LINT-SUPPRESS-001)
        public string File;
        public string ObjectPath;
        public string Section;
        public int Line;
        public int Matched;
        public bool Effective;

        // the identity used for newSuppressions (line numbers are not part of it: moving code is not a new suppression)
        public string Key()
        {
            List<string> ids = new List<string>(Ids);
            ids.Sort(StringComparer.Ordinal);
            return (Kind ?? "?") + "|" + string.Join(",", ids.ToArray()) + "|" + (Reason ?? "");
        }
    }

    public static class Suppressions
    {
        public const string Prefix = "tcauto-lint-disable-";
        public const int MinReason = 8;   // same as profile reasons and the repo's tcauto-allow
        private static readonly Regex BodyRx = new Regex(
            "^tcauto-lint-disable-(next-line|line|object)(?=\\s|:|$)\\s*([A-Za-z0-9_-]+(?:\\s*,\\s*[A-Za-z0-9_-]+)*)?\\s*(?::(.*))?$",
            RegexOptions.CultureInvariant | RegexOptions.Singleline);

        // body = text from "tcauto-lint-disable-" to the end of its line, without a closing "*)" / "]]>"
        public static Directive ParseBody(string body)
        {
            int cut = body.IndexOfAny(new char[] { '\r', '\n' });
            if (cut >= 0) body = body.Substring(0, cut);
            foreach (string end in new string[] { "*)", "]]>" })
            {
                int k = body.IndexOf(end, StringComparison.Ordinal);
                if (k >= 0) body = body.Substring(0, k);
            }
            body = body.Trim();
            Directive d = new Directive();
            Match m = BodyRx.Match(body);
            if (!m.Success) { d.Kind = "malformed"; d.Problem = "malformed directive (expected tcauto-lint-disable-next-line / -line / -object <RULE-ID>[, <RULE-ID>]: <reason>)"; return d; }
            d.Kind = m.Groups[1].Value;
            if (m.Groups[2].Success)
                foreach (string id in m.Groups[2].Value.Split(','))
                {
                    string t = id.Trim().ToUpperInvariant();
                    if (t.Length > 0 && !d.Ids.Contains(t)) d.Ids.Add(t);
                }
            d.Reason = m.Groups[3].Success ? m.Groups[3].Value.Trim() : "";
            if (d.Ids.Count == 0) d.Problem = "no rule id";
            else if (!ReasonOk(d.Reason)) d.Problem = "reason missing, shorter than " + Inv.S(MinReason) + " characters, without any letter, or one repeated character";
            return d;
        }

        // at least MinReason characters, at least one letter (Latin, CJK, ...: \p{L}) and at least 3 different non-space characters
        public static bool ReasonOk(string reason)
        {
            if (reason == null) return false;
            string r = reason.Trim();
            if (r.Length < MinReason || !Regex.IsMatch(r, "\\p{L}", RegexOptions.CultureInvariant)) return false;
            HashSet<char> distinct = new HashSet<char>();
            foreach (char c in r) if (!char.IsWhiteSpace(c)) distinct.Add(char.ToLowerInvariant(c));
            return distinct.Count >= 3;
        }

        // a comment token (// ... or (* ... *)) -> directive, or null when the comment is not one
        public static Directive FromComment(string comment)
        {
            string body;
            if (comment.StartsWith("//", StringComparison.Ordinal)) body = comment.Substring(2);
            else if (comment.StartsWith("(*", StringComparison.Ordinal)) body = comment.Substring(2);
            else return null;
            body = body.TrimStart(' ', '\t');
            if (!body.StartsWith(Prefix, StringComparison.Ordinal)) return null;
            return ParseBody(body);
        }

        // keys of every directive in a Tc* object file text (the base version for newSuppressions), found exactly like the
        // engine finds them: Declaration / ST text through the ST lexer, directives only in comment tokens (review nit:
        // a directive text inside a string or a nested comment is not a suppression). null = not a readable object file.
        public static ArrayList KeysInObjectText(string text)
        {
            if (text == null) return null;
            if (text.Length > 0 && text[0] == '\uFEFF') text = text.Substring(1);
            ArrayList keys = new ArrayList();
            try
            {
                System.Xml.XmlReaderSettings s = new System.Xml.XmlReaderSettings();
                s.DtdProcessing = System.Xml.DtdProcessing.Prohibit; s.XmlResolver = null;
                using (System.IO.StringReader sr = new System.IO.StringReader(text))
                using (System.Xml.XmlReader xr = System.Xml.XmlReader.Create(sr, s))
                {
                    Stack<string> names = new Stack<string>();
                    StringBuilder cur = null;
                    while (xr.Read())
                    {
                        if (xr.NodeType == System.Xml.XmlNodeType.Element)
                        {
                            if (!xr.IsEmptyElement) names.Push(xr.LocalName);
                            if (xr.LocalName == "Declaration" || xr.LocalName == "ST") cur = new StringBuilder();
                        }
                        else if ((xr.NodeType == System.Xml.XmlNodeType.CDATA || xr.NodeType == System.Xml.XmlNodeType.Text) && cur != null) cur.Append(xr.Value);
                        else if (xr.NodeType == System.Xml.XmlNodeType.EndElement)
                        {
                            string n = names.Count > 0 ? names.Pop() : "";
                            if ((n == "Declaration" || n == "ST") && cur != null)
                            {
                                foreach (Comment c in StLexer.Lex(cur.ToString()).Comments)
                                {
                                    Directive d = FromComment(c.Text);
                                    if (d != null) keys.Add(d.Key());
                                }
                                cur = null;
                            }
                        }
                    }
                }
            }
            catch (System.Xml.XmlException) { return null; }
            return keys;
        }
    }

    internal sealed partial class LintRun
    {
        // ================================================================ data collected while checking objects
        private sealed class DeclUnit
        {
            public TcObjectFile O;
            public string Path;
            public DeclInfo Di;
        }

        private readonly List<DeclUnit> declUnits = new List<DeclUnit>();
        private readonly List<Directive> directives = new List<Directive>();

        // called from AnalyzeDeclaration / AnalyzeImplementation for sections that are not excluded
        private void OnSection(TcObjectFile o, string path, string section, LexResult lx, DeclInfo di)
        {
            if (di != null && o.Kind != "Itf") { DeclUnit u = new DeclUnit(); u.O = o; u.Path = path; u.Di = di; declUnits.Add(u); }
            if (lx == null) return;
            int firstVar = int.MaxValue;
            if (di != null && di.VarBlocks.Count > 0) firstVar = di.VarBlocks[0].Line;
            foreach (Comment c in lx.Comments)
            {
                Directive d = Suppressions.FromComment(c.Text);
                if (d == null) continue;
                d.File = o.Rel; d.ObjectPath = path; d.Section = section; d.Line = c.Line;
                if (d.Problem == null && d.Kind == "object" && (section != "declaration" || c.Line >= firstVar))
                    d.Problem = "tcauto-lint-disable-object must be written in the declaration before the first VAR section";
                directives.Add(d);
            }
        }

        // ================================================================ entry
        private void RunPhase1b()
        {
            BuildIndex();
            CheckTempFb();
            CheckTaskGraph();
            RunPhase2a();
        }

        // ================================================================ project index (all objects, in scope or not)
        private sealed class SecCalls
        {
            public string Path;
            public bool Body;            // the POU's own implementation (not an action / method / accessor)
            public bool Uncertain;       // status not ok: calls may come from an inactive conditional branch
            public List<CallSite> Calls = new List<CallSite>();
            public HashSet<string> Locals = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        }

        private sealed class PouNode
        {
            public string Name;
            public TcObjectFile O;
            public string Header;        // PROGRAM / FUNCTION_BLOCK / FUNCTION / "" (unknown)
            public int NameLine;
            public HashSet<string> Members = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            public List<SecCalls> Sections = new List<SecCalls>();
            public HashSet<string> TypeRefs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            public HashSet<string> Edges = new HashSet<string>(StringComparer.OrdinalIgnoreCase);        // all (HoldsState)
            public HashSet<string> BodyEdges = new HashSet<string>(StringComparer.OrdinalIgnoreCase);    // from the POU's own implementation
            public HashSet<string> MemberEdges = new HashSet<string>(StringComparer.OrdinalIgnoreCase);  // from actions / methods / accessors + declared types
            public bool Reachable;       // some part runs
            public bool BodyRuns;        // the implementation itself runs (always true for FB / FUNCTION once reachable)
        }

        // a part of the project the linter could not read as ST: a call to a PROGRAM may hide in it
        private sealed class Uncertain
        {
            public string Owner;         // top object name
            public string File;
            public string Path;
            public HashSet<string> Idents;   // identifier-like words of the part; null = content unknown (names everything)
        }

        private readonly Dictionary<string, PouNode> pouIndex = new Dictionary<string, PouNode>(StringComparer.OrdinalIgnoreCase);
        private readonly List<PouNode> pouList = new List<PouNode>();
        private readonly Dictionary<string, string> typeKinds = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> rootTypeRefs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly List<Uncertain> uncertain = new List<Uncertain>();
        private readonly List<KeyValuePair<string, string>> taskCalls = new List<KeyValuePair<string, string>>();   // task name, called name
        private readonly Dictionary<string, TcObjectFile> taskFiles = new Dictionary<string, TcObjectFile>(StringComparer.OrdinalIgnoreCase);
        private int taskObjects;
        private static readonly Regex IdentRx = new Regex("[A-Za-z_][A-Za-z0-9_]*", RegexOptions.CultureInvariant);

        private void BuildIndex()
        {
            foreach (TcObjectFile o in objects)
            {
                if (string.Equals(o.Ext, ".TcTTO", StringComparison.OrdinalIgnoreCase)) taskObjects++;
                if (o.Obj == null)
                {
                    // unreadable / not well-formed / no object element: any name may be called from it
                    if (IsCodeFile(o)) AddUncertainFile(o);
                    continue;
                }
                switch (o.Kind)
                {
                    case "POU": IndexPou(o); break;
                    case "GVL": IndexGvl(o); break;
                    case "DUT": IndexDut(o); break;
                    case "Itf": typeKinds[o.Name] = "ITF"; break;
                    case "Task":
                        taskFiles[o.Name] = o;
                        foreach (XElem pc in o.Obj.All("PouCall"))
                        {
                            XElem n = pc.Child("Name");
                            if (n != null && n.InnerText().Trim().Length > 0) taskCalls.Add(new KeyValuePair<string, string>(o.Name, n.InnerText().Trim()));
                        }
                        break;
                    default:
                        // visualisations are not analysed; they may reference programs (inferred: visualisation input actions can run ST code, not checked on InfoSys)
                        AddUncertainFile(o);
                        break;
                }
            }
        }

        private static bool IsCodeFile(TcObjectFile o)
        {
            string e = o.Ext ?? "";
            return !string.Equals(e, ".TcTTO", StringComparison.OrdinalIgnoreCase);
        }

        private void AddUncertainFile(TcObjectFile o)
        {
            Uncertain u = new Uncertain(); u.Owner = o.Name; u.File = o.Rel; u.Path = o.ObjectPath;
            if (o.Bytes != null && !o.Bytes.ReadFailed && o.Bytes.Bytes != null)
                u.Idents = IdentSet(new UTF8Encoding(false, false).GetString(o.Bytes.Bytes));
            uncertain.Add(u);
        }

        private void AddUncertainText(TcObjectFile o, string path, string raw, LexResult lx)
        {
            Uncertain u = new Uncertain(); u.Owner = o.Name; u.File = o.Rel; u.Path = path;
            if (lx != null && lx.Error == null)
            {
                u.Idents = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (Token t in lx.Tokens) if (t.Kind == TokKind.Ident) u.Idents.Add(t.Text);
            }
            else if (raw != null) u.Idents = IdentSet(raw);   // raw == null: content unknown, treated as naming everything
            uncertain.Add(u);
        }

        // identifier-like words of a raw text, built once per unit (MentionedIn was regex x program x unit, review nit)
        private static HashSet<string> IdentSet(string raw)
        {
            HashSet<string> s = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (Match m in IdentRx.Matches(raw)) s.Add(m.Value);
            return s;
        }

        // The raw file lines from the element up to the next element in document order. The XML loader does not
        // keep the content of graphical sections (XmlArchive), so a CFC / SFC / Transition is searched in the raw
        // text of that part only (searching the whole file would hit comments elsewhere, e.g. axis FB_AxisControl).
        private readonly Dictionary<TcObjectFile, string[]> rawLines = new Dictionary<TcObjectFile, string[]>();

        private string RawSlice(TcObjectFile o, XElem e)
        {
            string[] lines;
            if (!rawLines.TryGetValue(o, out lines))
            {
                lines = null;
                if (o.Bytes != null && !o.Bytes.ReadFailed && o.Bytes.Bytes != null)
                    lines = new UTF8Encoding(false, false).GetString(o.Bytes.Bytes).Split('\n');
                rawLines[o] = lines;
            }
            if (lines == null) return null;
            int end = int.MaxValue;
            for (XElem x = e; x.Parent != null; x = x.Parent)
            {
                int i = x.Parent.Children.IndexOf(x);
                if (i + 1 < x.Parent.Children.Count) { end = x.Parent.Children[i + 1].Line; break; }
            }
            int from = Math.Max(0, e.Line - 1), to = end == int.MaxValue ? lines.Length : Math.Min(lines.Length, Math.Max(end - 1, from + 1));   // lines before the next element (at least the element's own line)
            StringBuilder sb = new StringBuilder();
            for (int k = from; k < to; k++) sb.Append(lines[k]).Append('\n');
            return sb.ToString();
        }

        private void IndexPou(TcObjectFile o)
        {
            PouNode p = new PouNode(); p.Name = o.Name; p.O = o; p.Header = "";
            XElem decl = o.Obj.Child("Declaration");
            HashSet<string> topLocals = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string why;
            bool excludedObj = Excluded(o.ObjectPath, out why);
            if (decl != null)
            {
                DeclInfo di = StAnalyzer.ParseDeclaration(decl.InnerText());
                if (di.HeaderKnown && di.Name != null) { p.Header = di.HeaderKeyword; p.NameLine = di.NameLine; }
                if (di.Extends.Count > 0) fbExtends[o.Name] = new List<string>(di.Extends);
                // instance data that survives between calls: VAR / VAR_STAT (and the inputs / outputs of an FB / PROGRAM)
                if (di.State.Status == "ok")
                {
                    List<string> st = new List<string>();
                    foreach (VarBlock b in di.VarBlocks)
                        if (b.Kind == "VAR" || b.Kind == "VAR_STAT" || b.Kind == "VAR_INPUT" || b.Kind == "VAR_OUTPUT")
                            foreach (VarDecl v in b.Vars) st.Add(v.TypeText ?? "");
                    fbStateTypes[o.Name] = st;
                }
                AddDeclRefs(p, di, topLocals);
                if (di.State.Status != "ok" || excludedObj) AddUncertainText(o, o.ObjectPath, decl.InnerText(), di.Lex);
            }
            else AddUncertainFile(o);
            if (!pouIndex.ContainsKey(p.Name)) { pouIndex[p.Name] = p; pouList.Add(p); }
            if (p.Header == "FUNCTION_BLOCK") typeKinds[p.Name] = "FB";
            else if (p.Header.Length > 0) typeKinds[p.Name] = p.Header;
            else typeKinds[p.Name] = "POU-UNKNOWN";

            XElem impl = o.Obj.Child("Implementation");
            if (impl != null) IndexCode(p, o, o.ObjectPath, impl, topLocals, null, true);
            foreach (XElem c in o.Obj.Children)
            {
                string cn = c.Attr("Name") ?? "?";
                string path = o.ObjectPath + "." + cn;
                switch (c.Name)
                {
                    case "Declaration": case "Implementation": case "Folder": case "LineIds": case "ObjectProperties": break;
                    case "Action":
                        p.Members.Add(cn);
                        if (c.Child("Implementation") != null) IndexCode(p, o, path, c.Child("Implementation"), topLocals, null, false);
                        break;
                    case "Method":
                        p.Members.Add(cn);
                        IndexMember(p, o, path, c, topLocals);
                        break;
                    case "Property":
                        p.Members.Add(cn);
                        foreach (XElem acc in c.Children)
                            if (acc.Name == "Get" || acc.Name == "Set") IndexMember(p, o, path + "." + acc.Name, acc, topLocals);
                        break;
                    default:
                        // Transition (structure not observed) and anything unknown
                        AddUncertainText(o, path, RawSlice(o, c), null);
                        break;
                }
            }
        }

        private void IndexMember(PouNode p, TcObjectFile o, string path, XElem m, HashSet<string> topLocals)
        {
            HashSet<string> locals = new HashSet<string>(topLocals, StringComparer.OrdinalIgnoreCase);
            XElem md = m.Child("Declaration");
            if (md != null)
            {
                DeclInfo di = StAnalyzer.ParseDeclaration(md.InnerText());
                AddDeclRefs(p, di, locals);
                // METHOD VAR_INST lives in the FB instance (InfoSys 2528798091): it is state of the FB (review N5)
                List<string> st;
                if (di.State.Status == "ok" && fbStateTypes.TryGetValue(p.Name, out st))
                    foreach (VarBlock b in di.VarBlocks) if (b.Kind == "VAR_INST") foreach (VarDecl v in b.Vars) st.Add(v.TypeText ?? "");
                if (di.State.Status != "ok") AddUncertainText(o, path, md.InnerText(), di.Lex);
            }
            XElem mi = m.Child("Implementation");
            if (mi != null) IndexCode(p, o, path, mi, locals, null, false);
        }

        private void AddDeclRefs(PouNode p, DeclInfo di, HashSet<string> locals)
        {
            foreach (string e in di.Extends) p.TypeRefs.Add(LastSegment(e));
            foreach (VarBlock b in di.VarBlocks)
                foreach (VarDecl v in b.Vars)
                {
                    foreach (string n in v.Names) locals.Add(n);
                    if (v.TypeText != null) foreach (Match m in IdentRx.Matches(StripBounds(v.TypeText))) p.TypeRefs.Add(m.Value);
                }
        }

        // ARRAY[0..PRG_B.x] OF T: identifiers in the bounds are values, not types (review nit 9)
        private static string StripBounds(string typeText)
        {
            return Regex.Replace(typeText, "\\[[^\\]]*\\]", " ", RegexOptions.CultureInvariant);
        }

        private static string LastSegment(string s)
        {
            int i = s.LastIndexOf('.');
            return i < 0 ? s : s.Substring(i + 1);
        }

        private void IndexCode(PouNode p, TcObjectFile o, string path, XElem impl, HashSet<string> locals, object unused, bool body)
        {
            List<XElem> st = impl.All("ST");
            string why;
            if (st.Count == 0) { AddUncertainText(o, path, RawSlice(o, impl), null); return; }
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < st.Count; i++) { if (i > 0) sb.Append('\n'); sb.Append(st[i].InnerText()); }
            ScanResult sr = StAnalyzer.ScanImplementation(sb.ToString());
            SecCalls s = new SecCalls(); s.Path = path; s.Body = body; s.Locals = locals; s.Calls = sr.Calls;
            // not-analyzed (conditional pragma, listed syntax): the call sites were still found; only the ones inside a
            // {IF} region are uncertain (review: an empty {IF}{END_IF} must not hide the other calls). unsupported /
            // parse-failed / excluded: nothing of the section is trusted
            s.Uncertain = (sr.State.Status != "ok" && sr.State.Status != "not-analyzed") || Excluded(path, out why);
            if (s.Uncertain || sr.Lex == null || sr.Lex.Error != null) AddUncertainText(o, path, sb.ToString(), sr.Lex);
            else if (sr.State.Status == "not-analyzed")
            {
                // identifiers inside conditional regions may name a program without a call site the scanner saw
                List<int[]> regions = StAnalyzer.PragmaRegions(sr.Lex.Tokens);
                if (regions.Count > 0)
                {
                    Uncertain u = new Uncertain(); u.Owner = o.Name; u.File = o.Rel; u.Path = path; u.Idents = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    foreach (Token t in sr.Lex.Tokens) if (t.Kind == TokKind.Ident && StAnalyzer.InRegion(regions, t.Line, t.Col)) u.Idents.Add(t.Text);
                    uncertain.Add(u);
                }
            }
            p.Sections.Add(s);
        }

        private void IndexGvl(TcObjectFile o)
        {
            XElem decl = o.Obj.Child("Declaration");
            if (decl == null) { AddUncertainFile(o); return; }
            DeclInfo di = StAnalyzer.ParseDeclaration(decl.InnerText());
            if (di.State.Status != "ok") AddUncertainText(o, o.ObjectPath, decl.InnerText(), di.Lex);
            foreach (VarBlock b in di.VarBlocks)
                foreach (VarDecl v in b.Vars)
                    if (v.TypeText != null) foreach (Match m in IdentRx.Matches(v.TypeText)) rootTypeRefs.Add(m.Value);
        }

        private readonly Dictionary<string, string> aliasOf = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, List<string>> structMembers = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, List<string>> fbStateTypes = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, List<string>> fbExtends = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

        private void IndexDut(TcObjectFile o)
        {
            typeKinds[o.Name] = "DUT";
            XElem decl = o.Obj.Child("Declaration");
            if (decl == null) return;
            DeclInfo di = StAnalyzer.ParseDeclaration(decl.InnerText());
            if (di.Type == null) return;
            if (di.Type.Kind == "ALIAS" && di.State.Status == "ok" && di.Type.BaseType != null) aliasOf[o.Name] = di.Type.BaseType;
            if ((di.Type.Kind == "STRUCT" || di.Type.Kind == "UNION") && di.State.Status == "ok")
            {
                List<string> m = new List<string>();
                // TYPE ST EXTENDS ST_Base: "the extended structure has the same structure components as the basic structure"
                // (InfoSys tc3_plc_intro/36028799548445323.html) -> the base is checked like a member (cycle-safe in Classify)
                if (di.Type.Extends != null) m.Add(di.Type.Extends);
                foreach (VarDecl v in di.Type.Members) m.Add(v.TypeText ?? "");
                structMembers[o.Name] = m;
            }
            // FB instances inside a structure: treated as reachable (over-approximation, only makes TASK-001 quieter)
            foreach (VarDecl v in di.Type.Members)
                if (v.TypeText != null) foreach (Match m in IdentRx.Matches(v.TypeText)) rootTypeRefs.Add(m.Value);
        }

        // ================================================================ SCAN-TEMPFB-001
        private static readonly HashSet<string> Elementary = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "BOOL", "BIT", "BYTE", "WORD", "DWORD", "LWORD", "SINT", "USINT", "INT", "UINT", "DINT", "UDINT", "LINT", "ULINT",
            "REAL", "LREAL", "STRING", "WSTRING", "TIME", "LTIME", "DATE", "LDATE", "TIME_OF_DAY", "TOD", "LTOD", "LTIME_OF_DAY",
            "DATE_AND_TIME", "DT", "LDT", "LDATE_AND_TIME", "XINT", "UXINT", "XWORD", "__XINT", "__UXINT", "__XWORD", "PVOID",
            "ANY", "ANY_NUM", "ANY_INT", "ANY_REAL", "ANY_BIT", "ANY_STRING", "ANY_DATE",
            // TwinCAT system data types (InfoSys tc3_plc_intro "Data types"; HRESULT seen in the bfh corpus): not function blocks
            "HRESULT" };

        // Result of a type: "hard" (timer, or a type the profile lists as stateful: blocking), "soft" (trigger / counter /
        // flip-flop: re-initialising them is wrong in a cycle but legal inside one call, InfoSys 12050023819 "only rarely
        // useful": warning), "type-only", "not-fb", "unknown", "skip" (pointer / reference), "project-fb" (no state found),
        // "struct-unknown". viaStruct = the state sits in a STRUCT member (FB as STRUCT member: no InfoSys statement found).
        private string Classify(string typeText, out string typeName) { bool vs; return Classify(typeText, out typeName, out vs, new HashSet<string>(StringComparer.OrdinalIgnoreCase)); }

        private string Classify(string typeText, out string typeName, out bool viaStruct) { return Classify(typeText, out typeName, out viaStruct, new HashSet<string>(StringComparer.OrdinalIgnoreCase)); }

        private string Classify(string typeText, out string typeName, out bool viaStruct, HashSet<string> visiting)
        {
            viaStruct = false;
            typeName = null;
            string t = (typeText ?? "").Trim();
            while (true)
            {
                Match m = Regex.Match(t, "^ARRAY\\s*\\[.*?\\]\\s*OF\\b\\s*(.*)$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Singleline);
                if (!m.Success) break;
                t = m.Groups[1].Value.Trim();
            }
            if (Regex.IsMatch(t, "^(POINTER|REFERENCE)\\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)) return "skip";
            int paren = t.IndexOf('(');
            if (paren >= 0) t = t.Substring(0, paren).Trim();
            if (t.Length == 0 || !Regex.IsMatch(t, "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*$", RegexOptions.CultureInvariant)) { typeName = t; return "unknown"; }
            string ns = null, name = t;
            int dot = t.LastIndexOf('.');
            if (dot >= 0) { ns = t.Substring(0, dot); name = t.Substring(dot + 1); }
            typeName = name;
            if (ns == null)
            {
                if (Elementary.Contains(name)) return "not-fb";
                string k;
                if (typeKinds.TryGetValue(name, out k))
                {
                    // a type that refers back to itself (illegal, or through a pointer we skipped): no state from the cycle
                    if (!visiting.Add(name)) return "not-fb";
                    try
                    {
                        string target, bn; bool vs;
                        // a project ALIAS (TYPE T_Timer : TON; END_TYPE) is its base type
                        if (k == "DUT" && aliasOf.TryGetValue(name, out target)) { string r = Classify(target, out bn, out vs, visiting); viaStruct = vs; if (r == "hard" || r == "soft") return r; typeName = r == "unknown" ? bn : name; return r; }
                        List<string> members;
                        if (k == "DUT" && structMembers.TryGetValue(name, out members))
                        {
                            // SF1: a STRUCT / UNION holding a stateful FB (also nested, also ARRAY OF)
                            string best = "not-fb"; bool unknown = false;
                            foreach (string mt in members)
                            {
                                string r = Classify(mt, out bn, out vs, visiting);
                                if (r == "hard") { best = "hard"; break; }
                                if (r == "soft") best = "soft";
                                else if (r == "unknown" || r == "struct-unknown") unknown = true;
                            }
                            if (best == "hard" || best == "soft") { viaStruct = true; return best; }
                            return unknown ? "struct-unknown" : "not-fb";
                        }
                        if (k != "FB") return "not-fb";
                        CatalogType pc = FindCatalog(name, "profile");
                        if (pc != null && pc.Kind == "stateful") return "hard";
                        // SF2: an FB whose VAR / VAR_STAT (also through EXTENDS) holds a stateful type is stateful itself
                        string res = "project-fb";
                        List<string> parts = new List<string>();
                        List<string> bases;
                        if (fbExtends.TryGetValue(name, out bases)) parts.AddRange(bases);
                        List<string> own;
                        if (fbStateTypes.TryGetValue(name, out own)) parts.AddRange(own);
                        foreach (string b in parts)
                        {
                            string r = Classify(b, out bn, out vs, visiting);
                            if (r == "hard") { res = "hard"; viaStruct = vs; break; }
                            if (r == "soft" && res != "soft") { res = "soft"; viaStruct = vs; }
                        }
                        typeName = name;
                        return res;
                    }
                    finally { visiting.Remove(name); }
                }
            }
            CatalogType c = FindCatalog(name, ns);
            if (c == null) { typeName = t; return "unknown"; }
            if (c.Kind != "stateful") return c.Kind == "type-only" ? "type-only" : "not-fb";
            return (c.Class == "timer" || c.Library == "profile") ? "hard" : "soft";
        }

        // ns null = any library; "profile" = profile entries only
        private CatalogType FindCatalog(string name, string ns)
        {
            // a profile can add state (typeCatalog.stateful), never remove it: profile stateful > built-in > profile functionBlocks
            CatalogType hit = null; int best = 0;
            foreach (CatalogType c in opt.CatalogTypes)
            {
                if (!string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) continue;
                if (ns == "profile" && c.Library != "profile") continue;
                if (ns != null && ns != "profile" && !string.Equals(c.Library, ns, StringComparison.OrdinalIgnoreCase)) continue;
                int rank = c.Library != "profile" ? 2 : (c.Kind == "stateful" ? 3 : 1);
                if (rank > best) { best = rank; hit = c; }
            }
            return hit;
        }

        private void CheckTempFb()
        {
            const string R = "SCAN-TEMPFB-001";
            if (!Enabled(R)) return;
            foreach (DeclUnit u in declUnits)
            {
                DeclInfo di = u.Di;
                string header = di.HeaderKeyword ?? "";
                bool accessor = header == "ACCESSOR" || ((header.StartsWith("VAR", StringComparison.Ordinal)) && (u.Path.EndsWith(".Get", StringComparison.OrdinalIgnoreCase) || u.Path.EndsWith(".Set", StringComparison.OrdinalIgnoreCase)));
                string owner = accessor ? "ACCESSOR" : header;
                if (owner != "METHOD" && owner != "FUNCTION" && owner != "ACCESSOR" && owner != "PROGRAM" && owner != "FUNCTION_BLOCK") continue;
                if (di.State.Status == "unsupported") { SkipBlocking(R, u.O.Rel, u.Path, "declaration-" + (di.State.Reason ?? "unsupported")); continue; }
                List<int[]> regions = null;
                if (di.State.Status != "ok")
                {
                    rulesSkipped.Add(Cov(R, u.O.Rel, u.Path, null, "declaration-" + (di.State.Status == "parse-failed" ? "parse-failed" : (di.State.Reason ?? di.State.Status))));
                    // conditional pragma only: the parser read the whole declaration; variables outside {IF} regions are certain
                    // (review should-fix 4: an empty {IF}{END_IF} must not hide a TON in METHOD VAR)
                    if (di.State.Status != "not-analyzed" || di.State.Reason != "conditional-pragma" || di.Lex == null) continue;
                    regions = StAnalyzer.PragmaRegions(di.Lex.Tokens);
                }
                foreach (VarBlock b in di.VarBlocks)
                {
                    string variant = null;
                    if (b.Kind == "VAR_TEMP") variant = "var-temp";
                    else if (b.Kind == "VAR" && owner == "METHOD") variant = "method-var";
                    else if (b.Kind == "VAR" && owner == "FUNCTION") variant = "function-var";
                    else if (b.Kind == "VAR" && owner == "ACCESSOR") variant = "accessor-var";
                    if (variant == null) continue;
                    foreach (VarDecl v in b.Vars)
                    {
                        if (regions != null && StAnalyzer.InRegion(regions, v.Line, v.Col)) continue;
                        string tn; bool viaStruct;
                        string cls = Classify(v.TypeText, out tn, out viaStruct);
                        if (cls == "unknown") { rulesSkipped.Add(Cov(R, u.O.Rel, u.Path, null, "unknown-type:" + tn)); continue; }
                        if (cls == "struct-unknown") { rulesSkipped.Add(Cov(R, u.O.Rel, u.Path, null, "struct-type:" + tn)); continue; }
                        if (cls == "type-only") { rulesSkipped.Add(Cov(R, u.O.Rel, u.Path, null, "type-only:" + tn)); continue; }
                        if (cls == "project-fb") { rulesSkipped.Add(Cov(R, u.O.Rel, u.Path, null, "project-type:" + tn)); continue; }
                        if (cls != "hard" && cls != "soft") continue;
                        string names = string.Join(", ", v.Names.ToArray());
                        string where = variant == "var-temp" ? "VAR_TEMP" : "VAR of " + (owner == "ACCESSOR" ? "the property accessor" : owner);
                        string basis, fix;
                        string sev = null, blockable = null;
                        if (variant == "method-var")
                        {
                            basis = "TwinCAT re-initializes all variables and function blocks declared in a method with each call (InfoSys tc3_plc_intro/2530307467.html)";
                            fix = "Declare the instance in the function block's VAR section, or in the method's VAR_INST section (not re-initialized, InfoSys 2528798091.html)";
                        }
                        else if (variant == "function-var")
                        {
                            basis = "TwinCAT re-initializes all variables declared in a function each time the function is called (InfoSys tc3_plc_intro/2530284939.html)";
                            fix = "Declare the instance in the calling function block or program and pass it to the function as VAR_IN_OUT";
                        }
                        else if (variant == "var-temp")
                        {
                            basis = "temporary instances (VAR_TEMP) are re-initialized in each processing cycle or with each block call (InfoSys tc3_plc_intro/12050023819.html, 2528781963.html)";
                            fix = "Declare the instance in VAR instead of VAR_TEMP";
                        }
                        else
                        {
                            basis = "a property accessor is a method-like call, its VAR section is assumed to be re-initialized like a method's (no InfoSys statement found, not measured)";
                            fix = "Declare the instance in the function block's VAR section";
                            sev = "warning"; blockable = "false";
                        }
                        string note = "";
                        // SF3: only timers (and types the profile lists) block; a trigger / counter / flip-flop re-initialised on every
                        // call is legal when it is only used inside that one call (InfoSys 12050023819: "only rarely useful")
                        if (cls == "soft") { sev = "warning"; blockable = "false"; note = "; trigger / counter / flip-flop: legal only if used within one call (InfoSys: 'only rarely useful'), so a warning that must be disposed"; }
                        if (viaStruct) { sev = "warning"; blockable = "false"; note += "; the instance is a STRUCT member (FB instances as STRUCT members: no InfoSys statement found, not measured)"; }
                        Emit(R, u.O.Rel, u.Path, "declaration", v.Line, v.Col,
                            "Stateful function block '" + names + " : " + v.TypeText + "' is declared in " + where + ": " + basis +
                            ", so it keeps no state between calls (a timer never reaches Q, an edge trigger fires on every call, a counter restarts)" + note,
                            names + " : " + v.TypeText, fix, variant, sev, blockable, false);
                    }
                }
            }
        }

        // ================================================================ PROJECT-TASK-001 / 002
        private sealed class BodyCall
        {
            public string Caller;
            public string CallerHeader;
            public string Section;
            public int Line;
            public bool Unconditional;
            public bool Uncertain;
            public string FramePath;
            public bool InLoop;
            public bool FromBody;   // the call sits in the caller's own implementation (runs only when the caller's body runs)
        }

        private void CheckTaskGraph()
        {
            const string R1 = "PROJECT-TASK-001", R2 = "PROJECT-TASK-002";
            if (!Enabled(R1) && !Enabled(R2)) return;
            if (taskObjects == 0)
            {
                // a library project has no task: nothing is "on a task"
                rulesNotRun.Add(Cov(R1, plcRel, "", null, "no-task"));
                rulesNotRun.Add(Cov(R2, plcRel, "", null, "no-task"));
                return;
            }
            if (msbuildUnobserved)
            {
                rulesSkipped.Add(Cov(R1, plcRel, "", null, "unobserved-msbuild"));
                rulesSkipped.Add(Cov(R2, plcRel, "", null, "unobserved-msbuild"));
                return;
            }
            usedAsType.Clear();
            // a PouCall naming no PROGRAM of the project (PROJECT-TSPROJ-003, the compiler rejects it): the task's real program is unknown
            bool pouCallUnresolved = false;
            foreach (KeyValuePair<string, string> tc in taskCalls) { PouNode q; if (!pouIndex.TryGetValue(tc.Value, out q) || q.Header != "PROGRAM") pouCallUnresolved = true; }
            // edges and body calls of PROGRAMs
            Dictionary<string, List<BodyCall>> bodyCalls = new Dictionary<string, List<BodyCall>>(StringComparer.OrdinalIgnoreCase);
            foreach (PouNode p in pouList)
            {
                foreach (string t in p.TypeRefs)
                {
                    PouNode q;
                    // a PROGRAM used as a type (not legal ST, inferred - not measured): treated as reached so TASK-001 does not add noise
                    if (pouIndex.TryGetValue(t, out q) && q != p) { p.Edges.Add(q.Name); p.MemberEdges.Add(q.Name); if (q.Header == "PROGRAM") usedAsType.Add(q.Name); }
                }
                foreach (SecCalls s in p.Sections)
                    foreach (CallSite cs in s.Calls)
                    {
                        string[] segs = cs.Target.Replace("[]", "").Replace("^", "").Split('.');
                        string first = segs[0];
                        if (first.Length == 0 || string.Equals(first, "THIS", StringComparison.OrdinalIgnoreCase) || string.Equals(first, "SUPER", StringComparison.OrdinalIgnoreCase)) continue;
                        if (s.Locals.Contains(first)) continue;
                        PouNode q;
                        if (!pouIndex.TryGetValue(first, out q)) continue;
                        // an action / method of P calling P() runs P's body (final review nit); other self references are ignored
                        if (q == p && !(q.Header == "PROGRAM" && segs.Length == 1 && !s.Body)) continue;
                        if (q.Header == "PROGRAM")
                        {
                            if (segs.Length == 1)
                            {
                                p.Edges.Add(q.Name); (s.Body ? p.BodyEdges : p.MemberEdges).Add("body:" + q.Name);
                                BodyCall bc = new BodyCall(); bc.Caller = p.Name; bc.CallerHeader = p.Header; bc.Section = s.Path; bc.Line = cs.Line; bc.FromBody = s.Body;
                                bc.Unconditional = cs.StatementStart && !cs.Conditional && s.Body && !cs.InPragma; bc.Uncertain = s.Uncertain || cs.InPragma;
                                bc.FramePath = cs.FramePath; bc.InLoop = StAnalyzer.InLoop(cs.FramePath);
                                List<BodyCall> l;
                                if (!bodyCalls.TryGetValue(q.Name, out l)) { l = new List<BodyCall>(); bodyCalls[q.Name] = l; }
                                l.Add(bc);
                            }
                            else if (q.Members.Contains(segs[1])) { p.Edges.Add(q.Name); (s.Body ? p.BodyEdges : p.MemberEdges).Add("member:" + q.Name); }
                        }
                        else { p.Edges.Add(q.Name); (s.Body ? p.BodyEdges : p.MemberEdges).Add("body:" + q.Name); }
                    }
            }
            // reachability from the tasks (and FB types instantiated in GVL / DUT)
            // review N3: a PROGRAM reached only through P.Action() runs that code, not its body: only its member sections
            // (actions / methods, over-approximated as all of them) and declared types propagate; P() / a task runs everything
            Queue<PouNode> queue = new Queue<PouNode>();
            foreach (KeyValuePair<string, string> tc in taskCalls) Mark(tc.Value, true, queue);
            foreach (string t in rootTypeRefs) { PouNode q; if (pouIndex.TryGetValue(t, out q) && q.Header != "PROGRAM") Mark(q.Name, true, queue); }
            while (queue.Count > 0)
            {
                PouNode p = queue.Dequeue();
                List<string> next = new List<string>(p.MemberEdges);
                if (p.BodyRuns) next.AddRange(p.BodyEdges);
                next.Sort(StringComparer.Ordinal);
                foreach (string e in next)
                {
                    if (e.StartsWith("body:", StringComparison.Ordinal)) Mark(e.Substring(5), true, queue);
                    else if (e.StartsWith("member:", StringComparison.Ordinal)) Mark(e.Substring(7), false, queue);
                    else Mark(e, true, queue);   // declared FB types
                }
            }
            // PROGRAMs that certainly run every cycle: on a task, or called unconditionally (statement level, not in
            // IF / CASE / loop) from the body of a program that certainly runs. Only these make a double call certain.
            certain.Clear();
            foreach (KeyValuePair<string, string> tc in taskCalls) { PouNode q; if (pouIndex.TryGetValue(tc.Value, out q) && q.Header == "PROGRAM") certain.Add(q.Name); }
            bool grew = true;
            while (grew)
            {
                grew = false;
                foreach (KeyValuePair<string, List<BodyCall>> kv in bodyCalls)
                    foreach (BodyCall bc in kv.Value)
                        if (!certain.Contains(kv.Key) && bc.Unconditional && !bc.Uncertain && bc.CallerHeader == "PROGRAM" && certain.Contains(bc.Caller)) { certain.Add(kv.Key); grew = true; }
            }
            List<PouNode> sorted = new List<PouNode>(pouList);
            sorted.Sort(delegate (PouNode a, PouNode b) { return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
            foreach (PouNode p in sorted)
            {
                if (p.Header != "PROGRAM") continue;
                // a program reached through its actions only, whose body is not called: p.BodyRuns is false
                // SF4: the body runs only through a task PouCall or a P() call from a reachable POU; calling P.Action() runs the
                // action only (inferred from the call syntax P.Action, InfoSys 2530340747 does not say whether the body runs)
                bool onTask = false, bodyCall = false, pragmaCall = false;
                foreach (KeyValuePair<string, string> tc in taskCalls) if (string.Equals(tc.Value, p.Name, StringComparison.OrdinalIgnoreCase)) onTask = true;
                List<BodyCall> bl;
                if (bodyCalls.TryGetValue(p.Name, out bl))
                    foreach (BodyCall bc in bl)
                    {
                        if (!CallRuns(bc)) continue;
                        if (bc.Uncertain) pragmaCall = true; else bodyCall = true;
                    }
                if (!onTask && !bodyCall)
                {
                    if (!Enabled(R1)) continue;
                    if (pouCallUnresolved) { rulesSkipped.Add(Cov(R1, p.O.Rel, p.Name, null, "pou-call-unresolved")); continue; }
                    // a PROGRAM used as a variable type (not legal ST, inferred - not measured): the compiler decides, no TASK-001 noise
                    if (usedAsType.Contains(p.Name)) { rulesSkipped.Add(Cov(R1, p.O.Rel, p.Name, null, "program-used-as-type")); continue; }
                    if (pragmaCall) { rulesSkipped.Add(Cov(R1, p.O.Rel, p.Name, null, "call-graph-incomplete:" + p.Name + "-called-only-in-conditional-pragma-or-unanalysed-code")); continue; }
                    string unc = MentionedIn(p.Name);
                    if (unc != null) { rulesSkipped.Add(Cov(R1, p.O.Rel, p.Name, null, "call-graph-incomplete:" + unc)); continue; }
                    if (p.Reachable)
                        Emit(R1, p.O.Rel, p.Name, "declaration", p.NameLine, 1,
                            "PROGRAM " + p.Name + ": only its actions / methods are called, the program body itself is called by no task and no POU, so the body never runs (inferred from the P.Action() call syntax; InfoSys 2530340747 does not say whether the body runs). Build does not catch this",
                            null, "Call " + p.Name + "() itself from a task program or add it to a task; if only the actions are meant to run, suppress with a reason: // tcauto-lint-disable-next-line PROJECT-TASK-001: <reason>",
                            "action-only", null, null, false);
                    else
                        Emit(R1, p.O.Rel, p.Name, "declaration", p.NameLine, 1,
                            "PROGRAM " + p.Name + " is not called by any task (.TcTTO PouCall) nor by any POU reachable from a task: it never runs. Build does not catch this: an uncalled PROGRAM is not even compiled (a syntax error in it still built, measured 2026-11-13, verification/st-syntax-measured.md section 2)",
                            null, "Call it from a task program or add it to a task (Add-TcPlcTask / LinkProgramToTask); if it is kept on purpose (test harness), suppress with a reason: // tcauto-lint-disable-next-line PROJECT-TASK-001: <reason>",
                            null, null, null, false);
                    continue;
                }
                if (!Enabled(R2)) continue;
                CheckDoubleCall(p, bodyCalls);
            }
        }

        private readonly HashSet<string> certain = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> usedAsType = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        private void Mark(string name, bool body, Queue<PouNode> queue)
        {
            PouNode q;
            if (!pouIndex.TryGetValue(name, out q)) return;
            bool runsBody = body || q.Header != "PROGRAM";
            if (q.Reachable && (q.BodyRuns || !runsBody)) return;
            q.Reachable = true;
            if (runsBody) q.BodyRuns = true;
            queue.Enqueue(q);
        }

        // the call site actually runs: its caller is reachable, and a call in the caller's own implementation needs the body to run
        private bool CallRuns(BodyCall bc)
        {
            PouNode caller;
            if (!pouIndex.TryGetValue(bc.Caller, out caller) || !caller.Reachable) return false;
            return !bc.FromBody || caller.BodyRuns;
        }

        private void CheckDoubleCall(PouNode p, Dictionary<string, List<BodyCall>> bodyCalls)
        {
            const string R2 = "PROJECT-TASK-002";
            List<string> tasks = new List<string>();   // one entry per PouCall (a task may call the program twice)
            foreach (KeyValuePair<string, string> tc in taskCalls) if (string.Equals(tc.Value, p.Name, StringComparison.OrdinalIgnoreCase)) tasks.Add(tc.Key);
            tasks.Sort(StringComparer.OrdinalIgnoreCase);
            HashSet<string> distinctTasks = new HashSet<string>(tasks, StringComparer.OrdinalIgnoreCase);
            List<BodyCall> calls;
            if (!bodyCalls.TryGetValue(p.Name, out calls)) calls = new List<BodyCall>();
            SortedDictionary<string, string> progCallers = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            SortedDictionary<string, string> otherCallers = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, int> unconditional = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> sureCallers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, List<BodyCall>> perCaller = new Dictionary<string, List<BodyCall>>(StringComparer.OrdinalIgnoreCase);
            string multiNote = null;
            bool uncertainCall = false;
            foreach (BodyCall bc in calls)
            {
                if (!CallRuns(bc)) continue;   // an unreachable caller (axis TestCam), or a body that never runs (review N3)
                if (string.Equals(bc.Caller, p.Name, StringComparison.OrdinalIgnoreCase)) continue;   // an own action calling the body is not a second source
                if (bc.Uncertain) { uncertainCall = true; continue; }
                List<BodyCall> pc;
                if (!perCaller.TryGetValue(bc.Caller, out pc)) { pc = new List<BodyCall>(); perCaller[bc.Caller] = pc; }
                pc.Add(bc);
                if (bc.InLoop && multiNote == null) multiNote = "call inside a loop in " + bc.Section + ":" + Inv.S(bc.Line);
                if (bc.CallerHeader == "PROGRAM")
                {
                    if (!progCallers.ContainsKey(bc.Caller)) progCallers[bc.Caller] = bc.Section + ":" + Inv.S(bc.Line);
                    if (bc.Unconditional)
                    {
                        int k; unconditional.TryGetValue(bc.Section, out k); unconditional[bc.Section] = k + 1;
                        if (certain.Contains(bc.Caller)) sureCallers.Add(bc.Caller);
                    }
                }
                else if (!otherCallers.ContainsKey(bc.Caller)) otherCallers[bc.Caller] = bc.Section + ":" + Inv.S(bc.Line);
            }
            // sure = runs every cycle for certain (task PouCall, or an unconditional call from a program that certainly runs)
            int sure = tasks.Count + sureCallers.Count;
            int strong = tasks.Count + progCallers.Count;
            string sources = Describe(tasks, progCallers, otherCallers);
            string variant = null, sev = null, blockable = null;
            if (sure >= 2) variant = sureCallers.Count == 0 ? (distinctTasks.Count >= 2 ? "two-tasks" : "task-twice") : (tasks.Count == 0 ? "two-programs" : "task-and-program");
            else
            {
                List<string> secs = new List<string>(unconditional.Keys); secs.Sort(StringComparer.OrdinalIgnoreCase);
                foreach (string s in secs) if (unconditional[s] >= 2) { variant = "repeated-call"; sources += "; " + Inv.S(unconditional[s]) + " unconditional calls in " + s; break; }
                // SF5: two calls of one program in one body are a legal, parameterised pattern unless the program (or what it
                // calls) holds a stateful FB: only then they certainly corrupt state -> blocking, else a warning to dispose
                if (variant == "repeated-call" && !HoldsState(p.Name, new HashSet<string>(StringComparer.OrdinalIgnoreCase))) { sev = "warning"; blockable = "false"; sources += "; " + p.Name + " holds no stateful function block of the catalog"; }
                // one caller with two call sites that are not in different branches of one IF / CASE (other section,
                // IF + unconditional, two calls in one branch) may run it twice
                if (multiNote == null)
                {
                    List<string> cl = new List<string>(perCaller.Keys); cl.Sort(StringComparer.OrdinalIgnoreCase);
                    foreach (string c in cl)
                    {
                        List<BodyCall> l = perCaller[c];
                        for (int i = 0; i < l.Count && multiNote == null; i++)
                            for (int j = i + 1; j < l.Count && multiNote == null; j++)
                                if (l[i].Section != l[j].Section || !StAnalyzer.Exclusive(l[i].FramePath, l[j].FramePath))
                                    multiNote = "two calls in " + c + " (" + l[i].Section + ":" + Inv.S(l[i].Line) + ", " + l[j].Section + ":" + Inv.S(l[j].Line) + ")";
                        if (multiNote != null) break;
                    }
                }
                if (variant == null && multiNote != null) { variant = otherCallers.Count > 0 ? "fb-or-function-caller" : "possible-double-call"; sev = "warning"; blockable = "false"; sources += "; " + multiNote; }
                // a conditional caller, or a caller that does not run every cycle for certain: it may run twice (warning)
                if (variant == null && (strong + otherCallers.Count >= 2 || otherCallers.Count >= 1)) { variant = otherCallers.Count > 0 ? "fb-or-function-caller" : "possible-double-call"; sev = "warning"; blockable = "false"; }
            }
            if (variant == null)
            {
                string unc = uncertainCall ? p.Name : MentionedIn(p.Name, p.Name);
                // like other notAnalyzed sections (CFC, conditional pragma; Phase 1a decision) this does not make the verdict incomplete
                if (unc != null && (uncertainCall || strong + otherCallers.Count >= 1)) rulesSkipped.Add(Cov(R2, p.O.Rel, p.Name, null, "call-graph-incomplete:" + unc));
                return;
            }
            int sourceCount = distinctTasks.Count + progCallers.Count + otherCallers.Count;
            string impact = variant == "fb-or-function-caller"
                ? "how often the calling function block / function runs per cycle is not analysed, so the program may run more than once per cycle"
                : variant == "possible-double-call"
                ? "it runs twice (or in a loop) in every cycle in which the conditional calls are made (a call inside IF / CASE / a loop / an action or method, or a caller that does not run every cycle for certain)"
                : "it runs more than once in one cycle (a structural fact of the files); inferred consequence: timers / triggers / counters inside are evaluated twice per cycle (an R_TRIG output is reset by the second call)" + (distinctTasks.Count >= 2 ? ", and two tasks access its data concurrently (InfoSys 12050040971 forbids access to one function block from several task contexts; for a PROGRAM no InfoSys statement was found)" : "");
            string where = sourceCount <= 1 && variant != "repeated-call" && variant != "task-twice" ? "is called from " + sources : "is called from more than one place or more than once (" + sources + ")";
            Emit(R2, p.O.Rel, p.Name, "declaration", p.NameLine, 1,
                "PROGRAM " + p.Name + " " + where + ": " + impact,
                sources, "Call the program from exactly one place (one task PouCall or one calling program); if two places are intended, list it in the profile suppressions[] with a reviewed reason",
                variant, sev, blockable, false);
        }

        // SF5: the program, its actions / methods and what they call (programs, function blocks, functions) hold a stateful FB
        private bool HoldsState(string name, HashSet<string> seen)
        {
            if (!seen.Add(name)) return false;
            PouNode p;
            if (!pouIndex.TryGetValue(name, out p)) return false;
            List<string> own;
            if (fbStateTypes.TryGetValue(name, out own))
                foreach (string t in own)
                {
                    string tn; bool vs;
                    string r = Classify(t, out tn, out vs);
                    if (r == "hard" || r == "soft") return true;
                }
            List<string> next = new List<string>(p.Edges); next.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string e in next) if (HoldsState(e, seen)) return true;
            return false;
        }

        private static string Describe(List<string> tasks, SortedDictionary<string, string> prog, SortedDictionary<string, string> other)
        {
            List<string> parts = new List<string>();
            SortedDictionary<string, int> perTask = new SortedDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (string t in tasks) { int n; perTask.TryGetValue(t, out n); perTask[t] = n + 1; }
            foreach (KeyValuePair<string, int> kv in perTask) parts.Add("task " + kv.Key + (kv.Value > 1 ? " (" + Inv.S(kv.Value) + " PouCalls)" : ""));
            foreach (KeyValuePair<string, string> kv in prog) parts.Add("program " + kv.Key + " (" + kv.Value + ")");
            foreach (KeyValuePair<string, string> kv in other) parts.Add("POU " + kv.Key + " (" + kv.Value + ")");
            return string.Join(", ", parts.ToArray());
        }

        // the first unreadable part of the project (other than the program itself) that names 'name', or null
        private string MentionedIn(string name) { return MentionedIn(name, name); }

        private string MentionedIn(string name, string self)
        {
            List<Uncertain> list = new List<Uncertain>(uncertain);
            list.Sort(delegate (Uncertain a, Uncertain b) { int c = string.CompareOrdinal(a.File ?? "", b.File ?? ""); return c != 0 ? c : string.CompareOrdinal(a.Path ?? "", b.Path ?? ""); });
            foreach (Uncertain u in list)
            {
                if (string.Equals(u.Owner, self, StringComparison.OrdinalIgnoreCase)) continue;
                bool hit;
                if (u.Idents != null) hit = u.Idents.Contains(name);
                else hit = true;   // content unknown (file not readable)
                if (hit) return u.Path ?? u.File;
            }
            return null;
        }

        // ================================================================ suppression (called from Finish)
        private void ApplyInlineSuppressions()
        {
            List<Diagnostic> snapshot = new List<Diagnostic>(diags);
            foreach (Directive d in directives)
            {
                if (d.Problem != null)
                {
                    Emit("LINT-SUPPRESS-001", d.File, d.ObjectPath, d.Section, d.Line, 1, "Suppression not applied: " + d.Problem, Short(Suppressions.Prefix + d.Kind + " " + string.Join(", ", d.Ids.ToArray()) + ": " + (d.Reason ?? "")),
                        "Write // tcauto-lint-disable-next-line <RULE-ID>: <reason of at least 8 characters>", null, null, null, false);
                    continue;
                }
                List<string> usable = new List<string>();
                foreach (string id in d.Ids)
                {
                    RuleMeta r = RuleRegistry.Get(id);
                    if (r == null)
                        Emit("LINT-SUPPRESS-002", d.File, d.ObjectPath, d.Section, d.Line, 1, "Suppression names unknown rule id '" + id + "'", id, "Use a rule id from data.rulesRun", null, null, null, false);
                    else if (id.StartsWith("LINT-SUPPRESS-", StringComparison.Ordinal) || ProfileBlocking(id))
                        Refuse(d, id);
                    else usable.Add(id);
                }
                if (usable.Count == 0) continue;
                d.Effective = true;
                HashSet<string> refused = new HashSet<string>(StringComparer.Ordinal);
                bool anyLocation = false;
                foreach (Diagnostic x in snapshot)
                {
                    if (x.Suppressed || !usable.Contains(x.RuleId)) continue;
                    bool hit;
                    if (d.Kind == "object") hit = string.Equals(x.ObjectPath, d.ObjectPath, StringComparison.OrdinalIgnoreCase) || x.ObjectPath.StartsWith(d.ObjectPath + ".", StringComparison.OrdinalIgnoreCase);
                    else
                    {
                        int target = d.Kind == "next-line" ? d.Line + 1 : d.Line;
                        hit = string.Equals(x.ObjectPath, d.ObjectPath, StringComparison.OrdinalIgnoreCase) && x.Section == d.Section && x.Line == target;
                    }
                    if (!hit) continue;
                    anyLocation = true;
                    // the variant decides (accessor-var / fb-or-function-caller are warnings of a blockable rule)
                    if (x.Blockable != "false") { if (refused.Add(x.RuleId)) Refuse(d, x.RuleId); continue; }
                    x.Suppressed = true; x.SuppressionReason = d.Reason; d.Matched++;
                }
                if (!anyLocation)
                    foreach (string id in usable)
                    {
                        RuleMeta r = RuleRegistry.Get(id);
                        if (r.Blockable != "false" && refused.Add(id)) Refuse(d, id);   // nothing here, and the rule can block: refuse as before
                    }
                if (d.Matched == 0 && refused.Count == 0)
                    Emit("LINT-SUPPRESS-003", d.File, d.ObjectPath, d.Section, d.Line, 1, "Suppression of " + string.Join(", ", usable.ToArray()) + " matches no finding (remove it)", null, null, null, null, null, false);
            }
        }

        private bool ProfileBlocking(string id)
        {
            RuleOverride ov;
            return overrides.TryGetValue(id, out ov) && ov.Blocking.HasValue && ov.Blocking.Value;
        }

        private void Refuse(Directive d, string id)
        {
            Emit("LINT-SUPPRESS-004", d.File, d.ObjectPath, d.Section, d.Line, 1, "This " + id + " finding can block (rule, variant or profile), so it cannot be suppressed in the code (the checked agent would suppress its own finding); the finding stays", id,
                "Fix the code, or ask the owner to add an entry to the profile suppressions[] (version-controlled, reviewed)", null, null, null, false);
        }

        private ArrayList SuppressionList(Dictionary<ProfileEntry, int> profileMatches)
        {
            ArrayList list = new ArrayList();
            List<Directive> ds = new List<Directive>(directives);
            ds.Sort(delegate (Directive a, Directive b)
            {
                int c = string.CompareOrdinal(a.File.ToLowerInvariant(), b.File.ToLowerInvariant()); if (c != 0) return c;
                c = string.CompareOrdinal(a.ObjectPath.ToLowerInvariant(), b.ObjectPath.ToLowerInvariant()); if (c != 0) return c;
                c = Diagnostic.SectionRank(a.Section).CompareTo(Diagnostic.SectionRank(b.Section)); if (c != 0) return c;
                return a.Line.CompareTo(b.Line);
            });
            foreach (Directive d in ds)
            {
                OrderedDictionary o = new OrderedDictionary();
                o["source"] = "inline"; o["kind"] = d.Kind; o["ruleIds"] = new ArrayList(d.Ids); o["file"] = d.File; o["objectPath"] = d.ObjectPath;
                o["section"] = d.Section; o["line"] = d.Line; o["reason"] = d.Reason ?? ""; o["effective"] = d.Effective; o["matched"] = d.Matched;
                if (d.Problem != null) o["problem"] = d.Problem;
                o["key"] = d.Key();
                list.Add(o);
            }
            foreach (ProfileEntry e in opt.Suppressions)
            {
                OrderedDictionary o = new OrderedDictionary();
                o["source"] = "profile"; o["kind"] = "profile"; o["ruleIds"] = new ArrayList(new string[] { e.RuleId }); o["file"] = null; o["objectPath"] = e.ObjectPath;
                o["section"] = null; o["line"] = 0; o["reason"] = e.Reason; o["effective"] = true;
                int m; profileMatches.TryGetValue(e, out m); o["matched"] = m;
                o["key"] = "profile|" + e.ObjectPath + "|" + e.RuleId + "|" + e.Reason;
                list.Add(o);
            }
            return list;
        }
    }
}
