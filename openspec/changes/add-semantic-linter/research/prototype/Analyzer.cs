// Throwaway prototype for #252 design research. NOT product code. C# 5.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Xml;

namespace StLintProto
{
    public class Finding
    {
        public string RuleId; public string Severity; public string Confidence; public string File; public string Object; public int Line; public string Message;
        public string Key() { return RuleId + "|" + File + "|" + Object + "|" + Line.ToString("D6") + "|" + Message; }
    }

    public class SectionResult { public Section Sec; public string DeclError; public string ImplError; public DeclInfo Decl; public StmtInfo Stmt; public bool ImplAnalyzed; }

    public class ProjectResult
    {
        public string PlcProj; public List<string> CompileItems = new List<string>(); public List<TcObject> Objects = new List<TcObject>();
        public List<SectionResult> Sections = new List<SectionResult>(); public List<Finding> Findings = new List<Finding>();
        public Dictionary<string, int> Stats = new Dictionary<string, int>();
        public List<string> Failures = new List<string>();
        void Inc(string k) { int v; Stats.TryGetValue(k, out v); Stats[k] = v + 1; }

        static readonly HashSet<string> StdStateful = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "TON","TOF","TP","LTON","LTOF","LTP","R_TRIG","F_TRIG","CTU","CTD","CTUD","RS","SR","TON_TIME","TOF_TIME" };
        // Explicit library FB catalog (prototype). Names only; a type not listed here is "unknown" and not evaluated.
        // Tc2_MC2 FB names from InfoSys Tc2_MC2 docs (product would ship a reviewed, versioned catalog).
        static readonly HashSet<string> LibFb = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "MC_Power","MC_Reset","MC_Home","MC_Stop","MC_Halt","MC_MoveAbsolute","MC_MoveRelative","MC_MoveAdditive","MC_MoveVelocity",
            "MC_MoveModulo","MC_ReadActualPosition","MC_ReadActualVelocity","MC_ReadStatus","MC_ReadAxisError","MC_GearIn","MC_GearOut",
            "MC_CamIn","MC_CamOut","MC_CamTableSelect","MC_SetPosition","MC_Jog","MC_ReadParameter","MC_WriteParameter","MC_TouchProbe",
            "MC_AbortTrigger","MC_GearInDyn","MC_ReadBoolParameter","MC_WriteBoolParameter","MC_CamScaling","MC_CamExchange" };
        static readonly HashSet<string> TimerTrig = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "TON","TOF","TP","LTON","LTOF","LTP","R_TRIG","F_TRIG","CTU","CTD","CTUD" };

        public static ProjectResult Analyze(string plcproj, Dictionary<string, DeclInfo> baseline)
        {
            var r = new ProjectResult { PlcProj = plcproj };
            string dir = Path.GetDirectoryName(plcproj);
            var doc = new XmlDocument(); doc.XmlResolver = null; doc.Load(plcproj);
            var ns = new XmlNamespaceManager(doc.NameTable); ns.AddNamespace("m", doc.DocumentElement.NamespaceURI);
            var seen = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
            foreach (XmlElement c in doc.SelectNodes("//m:Compile", ns))
            {
                string inc = c.GetAttribute("Include"); r.CompileItems.Add(inc);
                int cnt; seen.TryGetValue(inc, out cnt); seen[inc] = cnt + 1;
                if (cnt == 1) r.Add("PROJECT-COMPILE-002", "error", "high", plcproj, inc, 0, "duplicate Compile entry");
                string full = Path.Combine(dir, inc);
                if (!File.Exists(full)) r.Add("PROJECT-COMPILE-001", "error", "high", plcproj, inc, 0, "Compile entry points to missing file");
            }
            // orphan object files on disk not in Compile list
            var exts = new[] { ".TcPOU", ".TcDUT", ".TcGVL", ".TcIO", ".TcTTO" };
            foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
            {
                if (!exts.Any(e => f.EndsWith(e, StringComparison.OrdinalIgnoreCase))) continue;
                string rel = f.Substring(dir.Length + 1);
                if (!seen.ContainsKey(rel)) r.Add("PROJECT-COMPILE-003", "warning", "high", plcproj, rel, 0, "object file on disk is not in .plcproj Compile list (not compiled)");
            }
            // load compiled objects
            var ids = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var inc in r.CompileItems.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                string full = Path.Combine(dir, inc);
                string ext = Path.GetExtension(inc);
                if (!File.Exists(full) || !exts.Any(e => e.Equals(ext, StringComparison.OrdinalIgnoreCase))) continue;
                r.Inc("files" + ext);
                if (ext.Equals(".TcTTO", StringComparison.OrdinalIgnoreCase)) continue;
                var o = TcXml.Load(full);
                if (o.LoadError != null) { r.Failures.Add("XML " + inc + ": " + o.LoadError); r.Add("LINT-XML-001", "error", "high", inc, "", 0, o.LoadError); continue; }
                r.Objects.Add(o); r.Inc("obj." + o.XmlKind);
                string expected = ext.Equals(".TcPOU", StringComparison.OrdinalIgnoreCase) ? "POU" : ext.Equals(".TcDUT", StringComparison.OrdinalIgnoreCase) ? "DUT" : ext.Equals(".TcGVL", StringComparison.OrdinalIgnoreCase) ? "GVL" : "Itf";
                if (o.XmlKind != expected) r.Add("PROJECT-KIND-001", "error", "high", inc, o.Name, 0, "file extension " + ext + " holds <" + o.XmlKind + ">");
                if (!Path.GetFileNameWithoutExtension(inc).Equals(o.Name, StringComparison.OrdinalIgnoreCase)) r.Add("PROJECT-NAME-001", "warning", "high", inc, o.Name, 0, "file name differs from object name");
                foreach (var s in o.Sections)
                {
                    if (string.IsNullOrEmpty(s.Id)) continue;
                    string prev;
                    if (ids.TryGetValue(s.Id, out prev)) r.Add("PROJECT-GUID-001", "error", "high", inc, s.Owner, 0, "duplicate object Id " + s.Id + " (also " + prev + ")");
                    else ids[s.Id] = inc + "#" + s.Owner;
                }
                foreach (var s in o.Sections) r.ParseSection(inc, s);
            }
            r.RunSemanticRules(baseline);
            return r;
        }

        void ParseSection(string file, Section s)
        {
            var sr = new SectionResult { Sec = s };
            Inc("sections." + s.Kind);
            if (s.Decl != null)
            {
                Inc("decl.total");
                try { sr.Decl = new DeclParser(Lexer.Lex(s.Decl, false)).Parse(); Inc("decl.ok"); }
                catch (LexError e) { sr.DeclError = "lex L" + e.Line + ": " + e.Message; Inc("decl.lexfail"); }
                catch (ParseError e) { sr.DeclError = "parse L" + e.Line + ": " + e.Message; Inc("decl.parsefail"); }
                if (sr.DeclError != null) { Failures.Add("DECL " + file + "#" + s.Owner + " " + sr.DeclError); Add("LINT-PARSE-001", "error", "high", file, s.Owner, 0, "declaration not analyzed: " + sr.DeclError); }
            }
            if (s.ImplLang != null)
            {
                Inc("impl.lang." + s.ImplLang);
                if (s.ImplLang == "ST")
                {
                    Inc("impl.st.total");
                    try { var toks = Lexer.Lex(s.Impl ?? "", false); Inc("impl.st.lexok"); sr.Stmt = StmtScanner.Scan(toks); Inc("impl.st.structok"); sr.ImplAnalyzed = true; }
                    catch (LexError e) { sr.ImplError = "lex L" + e.Line + ": " + e.Message; }
                    catch (ParseError e) { sr.ImplError = "struct L" + e.Line + ": " + e.Message; }
                    if (sr.ImplError != null) { Failures.Add("IMPL " + file + "#" + s.Owner + " " + sr.ImplError); Add("LINT-PARSE-002", "error", "high", file, s.Owner, 0, "implementation not analyzed: " + sr.ImplError); }
                }
                else Add("LINT-COVERAGE-001", "info", "high", file, s.Owner, 0, "implementation language " + s.ImplLang + " not analyzed");
            }
            Sections.Add(sr);
        }

        void RunSemanticRules(Dictionary<string, DeclInfo> baseline)
        {
            // type registry from this project
            var fbTypes = new HashSet<string>(StdStateful, StringComparer.OrdinalIgnoreCase);
            var types = new Dictionary<string, DeclInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (var sr in Sections)
            {
                if (sr.Decl == null || sr.Decl.Name == null) continue;
                if (sr.Sec.Kind == "POU" || sr.Sec.Kind == "DUT" || sr.Sec.Kind == "Itf") types[sr.Decl.Name] = sr.Decl;
                if (sr.Decl.Kind == "FUNCTION_BLOCK") fbTypes.Add(sr.Decl.Name);
            }
            // group sections by owning top-level object
            foreach (var grp in Sections.GroupBy(x => x.Sec.Owner.Split('.')[0], StringComparer.OrdinalIgnoreCase))
            {
                var main = grp.FirstOrDefault(x => x.Sec.Owner.IndexOf('.') < 0);
                if (main == null || main.Decl == null) continue;
                bool allImplAnalyzed = grp.All(x => x.Sec.ImplLang == null || x.ImplAnalyzed);
                var calls = grp.Where(x => x.Stmt != null).SelectMany(x => x.Stmt.Calls.Select(c => new { S = x, C = c })).ToList();
                var refs = new HashSet<string>(grp.Where(x => x.Stmt != null).SelectMany(x => x.Stmt.IdentRefs), StringComparer.OrdinalIgnoreCase);
                // also refs in other sections' declarations initializers (e.g. REFERENCE init) are ignored in proto
                var file = Files(main);
                foreach (var sr in grp.Where(x => x.Decl != null))
                {
                    foreach (var v in sr.Decl.Vars)
                    {
                        if (v.IsPointerOrRef) continue;
                        if (v.Section.StartsWith("VAR_INPUT") || v.Section.StartsWith("VAR_IN_OUT") || v.Section.StartsWith("VAR_OUTPUT") || v.Section.StartsWith("VAR_GLOBAL") || v.Section.StartsWith("VAR_EXTERNAL") || v.Section == "STRUCT") continue;
                        bool isFb = fbTypes.Contains(v.BaseType) || LibFb.Contains(v.BaseType);
                        if (!isFb) continue;
                        // locality: method-local instance only searched in its own section
                        var scopeCalls = sr.Sec.Owner.IndexOf('.') >= 0 && sr.Sec.Kind == "Method" ? calls.Where(x => x.S == sr).ToList() : calls;
                        var mine = scopeCalls.Where(x => x.C.Instance.Equals(v.Name, StringComparison.OrdinalIgnoreCase)).ToList();
                        if (!allImplAnalyzed) continue; // coverage incomplete -> rule not evaluated
                        if (mine.Count == 0)
                        {
                            if (!refs.Contains(v.Name)) Add("SCAN-FBCALL-002", "info", "high", file, sr.Sec.Owner, v.Line, "FB instance '" + v.Name + " : " + v.BaseType + "' is never referenced");
                            else Add("SCAN-FBCALL-001", "warning", "medium", file, sr.Sec.Owner, v.Line, "FB instance '" + v.Name + " : " + v.BaseType + "' is referenced but never called (no body or method call)");
                            continue;
                        }
                        if (TimerTrig.Contains(v.BaseType))
                        {
                            var body = mine.Where(x => x.C.Member == null).ToList();
                            // refinement 1: calls in every branch of a top-level IF..ELSE count as unconditional
                            bool coveredByIfElse = body.Where(x => x.C.TopIfId >= 0).GroupBy(x => new { x.S, x.C.TopIfId }).Any(g => { var ib = g.Key.S.Stmt.Ifs[g.Key.TopIfId]; return ib.HasElse && g.Select(x => x.C.TopBranch).Distinct().Count() == ib.Branches; });
                            // refinement 2: call inside an Action/Method that the POU body calls unconditionally counts as body call
                            var mainStmt = grp.FirstOrDefault(x => x.Sec.Owner.IndexOf('.') < 0 && x.Stmt != null);
                            bool viaUncondAction = mainStmt != null && body.Any(x => x.C.CondDepth == 0 && x.S.Sec.Kind == "Action" && mainStmt.Stmt.Calls.Any(c => c.CondDepth == 0 && c.Member == null && c.Instance.Equals(x.S.Sec.Owner.Substring(x.S.Sec.Owner.LastIndexOf('.') + 1), StringComparison.OrdinalIgnoreCase)));
                            if (coveredByIfElse || viaUncondAction) { }
                            else if (body.Count > 0 && body.All(x => x.C.CondDepth > 0))
                                Add("SCAN-TIMER-001", "warning", "medium", file, sr.Sec.Owner, body[0].C.Line, v.BaseType + " instance '" + v.Name + "' is only called inside IF/CASE (" + body[0].C.Context + ") in " + body[0].S.Sec.Owner);
                            else if (body.Count > 0 && body.All(x => x.S.Sec.Kind != "POU"))
                                Add("SCAN-TIMER-002", "info", "low", file, sr.Sec.Owner, body[0].C.Line, v.BaseType + " instance '" + v.Name + "' is only called inside Method/Action " + body[0].S.Sec.Owner + " (cyclic call not provable)");
                            if (body.Count > 1 && !coveredByIfElse) Add("SCAN-TIMER-003", "warning", "medium", file, sr.Sec.Owner, body[1].C.Line, v.BaseType + " instance '" + v.Name + "' is called " + body.Count + " times");
                        }
                    }
                }
                // CONTRACT-ITF-001: FB IMPLEMENTS I: method names + return + VAR_INPUT types must match
                foreach (var itfName in main.Decl.Implements)
                {
                    DeclInfo itf; if (!types.TryGetValue(itfName, out itf)) { Add("CONTRACT-ITF-000", "info", "high", file, main.Sec.Owner, 0, "interface " + itfName + " not in project (library?) - not checked"); continue; }
                    var itfSecs = Sections.Where(x => x.Sec.Owner.StartsWith(itfName + ".", StringComparison.OrdinalIgnoreCase) && x.Sec.Kind == "Method" && x.Decl != null).ToList();
                    foreach (var im in itfSecs)
                    {
                        var fm = grp.FirstOrDefault(x => x.Sec.Kind == "Method" && x.Decl != null && string.Equals(x.Decl.Name, im.Decl.Name, StringComparison.OrdinalIgnoreCase));
                        if (fm == null) { Add("CONTRACT-ITF-001", "error", "high", file, main.Sec.Owner, 0, "method " + im.Decl.Name + " of " + itfName + " not implemented (may be inherited - proto does not follow EXTENDS)"); continue; }
                        string a = Sig(im.Decl), b = Sig(fm.Decl);
                        if (!a.Equals(b, StringComparison.OrdinalIgnoreCase)) Add("CONTRACT-ITF-002", "error", "high", file, fm.Sec.Owner, 0, "signature differs from " + itfName + ": itf=" + a + " impl=" + b);
                    }
                }
            }
            // CONTRACT-DUT/ENUM vs baseline
            if (baseline != null)
            {
                foreach (var kv in types)
                {
                    DeclInfo old; if (!baseline.TryGetValue(kv.Key, out old)) continue;
                    var cur = kv.Value;
                    if (cur.Kind == "ENUM" && old.Kind == "ENUM")
                    {
                        var oldMap = EnumMap(old); var curMap = EnumMap(cur);
                        foreach (var m in oldMap)
                        {
                            string nv; if (!curMap.TryGetValue(m.Key, out nv)) Add("CONTRACT-ENUM-001", "error", "high", "baseline", kv.Key, 0, "enum member " + m.Key + " removed");
                            else if (nv != m.Value) Add("CONTRACT-ENUM-002", "error", "high", "baseline", kv.Key, 0, "enum member " + m.Key + " value " + m.Value + " -> " + nv);
                        }
                    }
                    if (cur.Kind == "STRUCT" && old.Kind == "STRUCT")
                    {
                        var o = old.Vars.Select(v => v.Name + ":" + v.TypeText).ToList(); var c = cur.Vars.Select(v => v.Name + ":" + v.TypeText).ToList();
                        int k = 0; while (k < o.Count && k < c.Count && o[k].Equals(c[k], StringComparison.OrdinalIgnoreCase)) k++;
                        if (k < o.Count) Add("CONTRACT-DUT-001", "error", "high", "baseline", kv.Key, 0, "public struct layout changed at field #" + k + ": " + o[k] + " -> " + (k < c.Count ? c[k] : "(removed)"));
                    }
                }
            }
        }
        static Dictionary<string, string> EnumMap(DeclInfo d)
        {
            var m = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); int next = 0;
            foreach (var e in d.EnumMembers)
            {
                var parts = e.Split('='); string val;
                int iv;
                if (parts.Length > 1) { val = parts[1].Trim(); if (int.TryParse(val, out iv)) next = iv + 1; else next = int.MinValue; }
                else { val = next == int.MinValue ? "?" : next.ToString(); if (next != int.MinValue) next++; }
                m[parts[0].Trim()] = val;
            }
            return m;
        }
        static string Sig(DeclInfo d)
        {
            return (d.ReturnType ?? "") + "(" + string.Join(",", d.Vars.Where(v => v.Section.StartsWith("VAR_INPUT") || v.Section.StartsWith("VAR_OUTPUT") || v.Section.StartsWith("VAR_IN_OUT")).Select(v => v.Section.Split(' ')[0] + " " + v.Name + ":" + v.TypeText).ToArray()) + ")";
        }
        string Files(SectionResult s)
        {
            foreach (var o in Objects) if (o.Sections.Contains(s.Sec)) return Path.GetFileName(o.File);
            return "?";
        }
        public void Add(string id, string sev, string conf, string file, string obj, int line, string msg)
        { Findings.Add(new Finding { RuleId = id, Severity = sev, Confidence = conf, File = file, Object = obj, Line = line, Message = msg }); }

        public List<Finding> Sorted() { return Findings.OrderBy(f => f.Key(), StringComparer.Ordinal).ToList(); }

        public static Dictionary<string, DeclInfo> Snapshot(ProjectResult r)
        {
            var m = new Dictionary<string, DeclInfo>(StringComparer.OrdinalIgnoreCase);
            foreach (var s in r.Sections) if (s.Decl != null && s.Decl.IsTypeDecl && s.Decl.Name != null) m[s.Decl.Name] = s.Decl;
            return m;
        }
    }
}
