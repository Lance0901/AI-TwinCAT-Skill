// TwinCAT Semantic Linter (#252) - Phase 2b rules: SCAN-FBCALL-001 / 002, SCAN-TIMER-001 / 002 / 004 / 005
// (rule-catalog.md, tasks 2.5). C# 5. An FB instance declared in VAR / VAR_STAT of a FUNCTION_BLOCK or PROGRAM is
// evaluated only when every way it could be used is visible in the owner's own ST sections: passed as a parameter,
// ADR / REF= / assignment, a qualified access from anywhere in the project (PRG.inst, fb.inst), a derived FB (EXTENDS)
// that inherits it, a part the linter cannot read, a shadowing local or an array -> not evaluated, coverage.rulesSkipped
// with the reason. Missing a finding is accepted; reporting "never called" for an instance called elsewhere is not.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    internal sealed partial class LintRun
    {
        private const string RFb1 = "SCAN-FBCALL-001";
        private const string RFb2 = "SCAN-FBCALL-002";
        private const string RTm1 = "SCAN-TIMER-001";
        private const string RTm2 = "SCAN-TIMER-002";
        private const string RTm4 = "SCAN-TIMER-004";
        private const string RTm5 = "SCAN-TIMER-005";
        private static readonly string[] Rules2b = { RFb1, RFb2, RTm1, RTm2, RTm4, RTm5 };

        private sealed class InstUse
        {
            public ImplUnit U;
            public string Kind;        // body-call / member-call / member / escape
            public string Member;
            public bool Assign;        // inst.Member := ...
            public int Line, Col;
            public CallSite Call;      // body-call only
            public Dictionary<string, string> Args;   // body-call: NAME (upper) -> value text; null = positional arguments
        }

        private sealed class Inst
        {
            public DeclUnit Owner;
            public string Name;
            public VarDecl V;
            public string TypeName;
            public string Class;       // timer / edge / counter / bistable (catalog stateful), type-only, project-fb
            public string Skip;        // reason the instance is not evaluated
            public List<InstUse> Uses = new List<InstUse>();
        }

        private Dictionary<string, HashSet<string>> dotNames;
        private HashSet<string> derivedBases;

        // ================================================================ entry (called at the end of RunPhase1b)
        private void RunPhase2b()
        {
            bool any = false;
            foreach (string id in Rules2b) if (Enabled(id)) any = true;
            if (!any) return;
            BuildDotNames();
            derivedBases = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, List<string>> kv in fbExtends) foreach (string b in kv.Value) derivedBases.Add(LastSegment(b));
            foreach (DeclUnit du in declUnits)
            {
                if (du.Path != du.O.ObjectPath) continue;
                string h = du.Di.HeaderKeyword ?? "";
                if (h != "FUNCTION_BLOCK" && h != "PROGRAM") continue;
                EvaluateOwner(du);
            }
        }

        // every identifier written after '.' anywhere in the project (all objects, in scope or not), except THIS^.x:
        // a qualified access PRG.inst / fb.inst from another POU (or another instance of the same FB)
        private void BuildDotNames()
        {
            dotNames = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
            foreach (TcObjectFile o in objects)
            {
                if (o.Obj == null) continue;
                List<XElem> code = new List<XElem>();
                CollectCode(o.Obj, code);
                foreach (XElem e in code)
                {
                    LexResult lx = StLexer.Lex(e.InnerText());
                    List<Token> t = lx.Tokens;
                    for (int i = 1; i < t.Count; i++)
                    {
                        if (t[i].Kind != TokKind.Ident || !t[i - 1].IsOp(".")) continue;
                        if (i >= 3 && t[i - 2].IsOp("^") && t[i - 3].Is("THIS")) continue;
                        HashSet<string> s;
                        if (!dotNames.TryGetValue(t[i].Text, out s)) { s = new HashSet<string>(StringComparer.OrdinalIgnoreCase); dotNames[t[i].Text] = s; }
                        s.Add(o.Name);
                    }
                }
            }
        }

        private static void CollectCode(XElem e, List<XElem> into)
        {
            foreach (XElem c in e.Children)
            {
                if (c.Name == "ST" || c.Name == "Declaration") into.Add(c);
                else CollectCode(c, into);
            }
        }

        private void Skip2b(string id, Inst x, string reason)
        {
            if (Enabled(id)) rulesSkipped.Add(Cov(id, x.Owner.O.Rel, x.Owner.Path, null, reason + ":" + x.Name));
        }

        private bool IsTimerish(Inst x) { return x.Class == "timer" || x.Class == "edge"; }

        // ================================================================ one FUNCTION_BLOCK / PROGRAM
        private void EvaluateOwner(DeclUnit du)
        {
            TcObjectFile o = du.O;
            List<ImplUnit> secs = new List<ImplUnit>();
            foreach (ImplUnit u in implUnits) if (u.O == o) secs.Add(u);
            List<DeclUnit> decls = new List<DeclUnit>();
            foreach (DeclUnit d in declUnits) if (d.O == o) decls.Add(d);
            string ownerProblem = null;
            if (du.Di.State.Status != "ok") ownerProblem = "declaration-not-analyzed";
            foreach (DeclUnit d in decls) if (d.Di.State.Status != "ok") ownerProblem = "member-declaration-not-analyzed";
            foreach (ImplUnit u in secs) if (u.Scan == null || u.Scan.State.Status != "ok" || u.Scan.Lex == null) ownerProblem = "implementation-not-analyzed";
            // the POU's own body must be an analysed ST section (missing / graphical / excluded body: its uses are unknown)
            bool hasBody = false;
            foreach (ImplUnit u in secs) if (u.Path == du.Path) hasBody = true;
            if (!hasBody) ownerProblem = "implementation-not-analyzed";

            List<Inst> insts = new List<Inst>();
            foreach (VarBlock b in du.Di.VarBlocks)
            {
                if (b.Kind != "VAR" && b.Kind != "VAR_STAT") continue;
                foreach (VarDecl v in b.Vars)
                {
                    string tt = (v.TypeText ?? "").Trim();
                    bool array = tt.StartsWith("ARRAY", StringComparison.OrdinalIgnoreCase);
                    string tn; bool vs;
                    string cls = Classify(tt, out tn, out vs);
                    if (cls == "not-fb" || cls == "skip") continue;
                    foreach (string n in v.Names)
                    {
                        Inst x = new Inst(); x.Owner = du; x.Name = n; x.V = v; x.TypeName = tn;
                        if (cls == "unknown") { x.Skip = "unknown-type"; }
                        else if (cls == "struct-unknown") { continue; }
                        else if (array) x.Skip = "array-instance";
                        else if (vs) x.Skip = "struct-type";
                        else
                        {
                            string bare = tt; int dot = bare.LastIndexOf('.'); if (dot >= 0) bare = bare.Substring(dot + 1);
                            int par = bare.IndexOf('('); if (par >= 0) bare = bare.Substring(0, par).Trim();
                            CatalogType c = FindCatalog(bare, null);
                            string k;
                            if (typeKinds.TryGetValue(bare, out k) && k == "FB") x.Class = "project-fb";
                            else if (c != null && c.Kind == "stateful") x.Class = c.Class == "profile" ? "stateful" : c.Class;
                            else if (c != null && c.Kind == "type-only") x.Class = "type-only";
                            else if (cls == "hard" || cls == "soft") x.Skip = "type-alias";
                            else continue;
                            x.TypeName = bare;
                        }
                        insts.Add(x);
                    }
                }
            }
            if (insts.Count == 0) return;

            Dictionary<string, Dictionary<string, HashSet<string>>> branchMaps = new Dictionary<string, Dictionary<string, HashSet<string>>>(StringComparer.Ordinal);
            foreach (Inst x in insts)
            {
                if (x.Skip == null && ownerProblem != null) x.Skip = ownerProblem;
                if (x.Skip == null && derivedBases.Contains(o.Name)) x.Skip = "inherited-use";
                HashSet<string> dn;
                if (x.Skip == null && dotNames.TryGetValue(x.Name, out dn)) x.Skip = "qualified-access";
                if (x.Skip == null)
                    foreach (Uncertain un in uncertain)
                        if ((un.Idents == null && string.Equals(un.Owner, o.Name, StringComparison.OrdinalIgnoreCase)) || (un.Idents != null && un.Idents.Contains(x.Name))) { x.Skip = "unanalysed-part"; break; }
                if (x.Skip == null) x.Skip = DeclarationUse(x, decls);
                if (x.Skip == null)
                    foreach (ImplUnit u in secs) { CollectUses(x, u); if (x.Skip != null) break; }
                if (x.Skip != null)
                {
                    if (x.Skip == "unknown-type" || x.Skip == "type-alias") { Skip2b(RFb1, x, x.Skip + ":" + x.TypeName); continue; }
                    Skip2b(RFb1, x, x.Skip);
                    if (IsTimerish(x)) Skip2b(RTm1, x, x.Skip);
                    continue;
                }
                CheckFbCall(x);
                if (IsTimerish(x)) CheckTimer(x, secs, branchMaps);
            }
        }

        // the name in a declaration other than its own declaration (initialiser of another variable: ADR(inst),
        // REFERENCE TO ... := inst, FB_init argument) -> escape; a local of a method with the same name -> shadowed
        private string DeclarationUse(Inst x, List<DeclUnit> decls)
        {
            foreach (DeclUnit d in decls)
            {
                if (d.Di.Lex == null) return "declaration-not-analyzed";
                List<Token> t = d.Di.Lex.Tokens;
                for (int i = 0; i < t.Count; i++)
                {
                    if (t[i].Kind != TokKind.Ident || !string.Equals(t[i].Text, x.Name, StringComparison.OrdinalIgnoreCase)) continue;
                    if (i > 0 && t[i - 1].IsOp(".")) continue;
                    bool declares = i + 1 < t.Count && (t[i + 1].IsOp(":") || t[i + 1].IsOp(",") || t[i + 1].Kind == TokKind.Address || t[i + 1].Is("AT"));
                    if (declares) { if (d != x.Owner) return "shadowed-name"; continue; }
                    return "referenced-in-declaration";
                }
            }
            return null;
        }

        private void CollectUses(Inst x, ImplUnit u)
        {
            List<Token> t = u.Scan.Lex.Tokens;
            for (int i = 0; i < t.Count; i++)
            {
                if (t[i].Kind != TokKind.Ident || !string.Equals(t[i].Text, x.Name, StringComparison.OrdinalIgnoreCase)) continue;
                int start = i;
                if (i > 0 && t[i - 1].IsOp("."))
                {
                    if (i >= 3 && t[i - 2].IsOp("^") && t[i - 3].Is("THIS")) start = i - 3;
                    else continue;   // other.name: a member of something else (dotNames already covers x.Name after '.')
                }
                InstUse use = new InstUse(); use.U = u; use.Line = t[start].Line; use.Col = t[start].Col;
                Token nx = i + 1 < t.Count ? t[i + 1] : null;
                if (nx != null && nx.IsOp("("))
                {
                    use.Kind = "body-call";
                    foreach (CallSite cs in u.Scan.Calls) if (cs.Line == t[start].Line && cs.Col == t[start].Col) { use.Call = cs; break; }
                    if (use.Call == null) { x.Skip = "call-site-not-found"; return; }
                    use.Args = ReadArgs(t, i + 1);
                }
                else if (nx != null && nx.IsOp(".") && i + 2 < t.Count && t[i + 2].Kind == TokKind.Ident)
                {
                    use.Member = t[i + 2].Text;
                    Token n3 = i + 3 < t.Count ? t[i + 3] : null;
                    if (n3 != null && n3.IsOp("(")) use.Kind = "member-call";
                    else { use.Kind = "member"; use.Assign = n3 != null && n3.IsOp(":="); }
                    if (n3 != null && (n3.IsOp(".") || n3.IsOp("[") || n3.IsOp("^"))) { x.Skip = "nested-member-access"; return; }
                }
                else { x.Skip = "passed-or-aliased"; return; }   // f(inst), ADR(inst), r REF= inst, itf := inst, inst := other
                x.Uses.Add(use);
            }
        }

        // named arguments of a call: '(' at index open; null when an argument is not 'NAME := value' / 'NAME => var'
        private static Dictionary<string, string> ReadArgs(List<Token> t, int open)
        {
            Dictionary<string, string> args = new Dictionary<string, string>(StringComparer.Ordinal);
            int depth = 0, i = open;

            List<List<Token>> parts = new List<List<Token>>();
            List<Token> cur = new List<Token>();
            for (; i < t.Count && t[i].Kind != TokKind.EOF; i++)
            {
                Token x = t[i];
                if (x.IsOp("(") || x.IsOp("[")) { depth++; if (depth == 1) continue; }
                else if (x.IsOp(")") || x.IsOp("]")) { depth--; if (depth == 0) break; }
                if (depth == 1 && x.IsOp(",")) { parts.Add(cur); cur = new List<Token>(); continue; }
                cur.Add(x);
            }
            if (cur.Count > 0) parts.Add(cur);
            foreach (List<Token> p in parts)
            {
                if (p.Count < 2 || p[0].Kind != TokKind.Ident || !(p[1].IsOp(":=") || p[1].IsOp("=>"))) return null;
                if (p[1].IsOp("=>")) continue;
                List<string> v = new List<string>();
                for (int k = 2; k < p.Count; k++) v.Add(p[k].Kind == TokKind.Ident ? p[k].Upper : p[k].Text);
                args[p[0].Upper] = string.Join(" ", v.ToArray());
            }
            return args;
        }

        // ================================================================ SCAN-FBCALL-001 / 002
        private void CheckFbCall(Inst x)
        {
            bool called = false;
            InstUse first = null;
            HashSet<string> members = x.Class == "project-fb" ? ChainMembers(x.TypeName) : new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (InstUse u in x.Uses)
            {
                if (first == null) first = u;
                if (u.Kind == "body-call") called = true;
                else if (x.Class == "project-fb" && (members == null || u.Kind == "member-call" || members.Contains(u.Member))) called = true;   // method / action / property (accessor code runs)
                else if (u.Kind == "member-call") { Skip2b(RFb1, x, "member-call-of-library-fb"); return; }
            }
            string decl = x.Name + " : " + x.V.TypeText;
            if (x.Uses.Count == 0)
            {
                if (x.Class == "project-fb" || x.Class == "timer" || x.Class == "edge" || x.Class == "counter" || x.Class == "bistable" || x.Class == "stateful" || x.Class == "type-only")
                    Emit(RFb2, x.Owner.O.Rel, x.Owner.Path, "declaration", x.V.Line, x.V.Col,
                        "Function block instance '" + decl + "' is declared but never used in " + x.Owner.Path + " (no call, no member access, not passed on)",
                        decl, "Remove the instance, or call it where it is meant to run", null, null, null, false);
                return;
            }
            if (called) return;
            Emit(RFb1, x.Owner.O.Rel, x.Owner.Path, "declaration", x.V.Line, x.V.Col,
                "Function block instance '" + decl + "' is used (" + first.U.Path + " line " + Inv.S(first.Line) + ": ." + (first.Member ?? "?") + ") but never called: " +
                "its outputs are only computed when the instance is called, so they stay at their initial values",
                decl, "Call " + x.Name + "(...) every cycle where its outputs are needed (or remove the reads)", null, null, null, false);
        }

        // members (Method / Action / Property) of a project FB and its EXTENDS chain; null when a base is outside the project
        private HashSet<string> ChainMembers(string type)
        {
            HashSet<string> m = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string cur = type;
            while (cur != null && seen.Add(cur))
            {
                PouNode p;
                if (!pouIndex.TryGetValue(cur, out p)) return null;
                m.UnionWith(p.Members);
                List<string> bases;
                cur = fbExtends.TryGetValue(cur, out bases) && bases.Count > 0 ? LastSegment(bases[0]) : null;
            }
            return m;
        }

        // ================================================================ SCAN-TIMER-001 / 002 / 004 / 005
        private static readonly HashSet<string> TimerTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "TON", "TOF", "TP", "LTON", "LTOF", "LTP" };
        private static readonly HashSet<string> OnDelay = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "TON", "LTON" };

        private void CheckTimer(Inst x, List<ImplUnit> secs, Dictionary<string, Dictionary<string, HashSet<string>>> branchMaps)
        {
            List<InstUse> calls = new List<InstUse>();
            foreach (InstUse u in x.Uses) if (u.Kind == "body-call") calls.Add(u);
            if (calls.Count == 0) return;   // SCAN-FBCALL-001 / 002
            foreach (InstUse u in x.Uses) if (u.Kind == "member-call") { Skip2b(RTm1, x, "member-call"); return; }
            string input = x.Class == "edge" ? "CLK" : "IN";
            bool positional = false, reset = false, allInTrue = true, allInFalse = true, ptSet = !string.IsNullOrEmpty(x.V.InitText), inWritten = false;
            foreach (InstUse u in x.Uses)
            {
                if (u.Kind == "member" && u.Assign && string.Equals(u.Member, "PT", StringComparison.OrdinalIgnoreCase)) ptSet = true;
                if (u.Kind == "member" && u.Assign && string.Equals(u.Member, input, StringComparison.OrdinalIgnoreCase)) { inWritten = true; reset = true; }
            }
            foreach (InstUse c in calls)
            {
                if (c.Args == null) { positional = true; continue; }
                string v;
                if (c.Args.ContainsKey("PT")) ptSet = true;
                if (!c.Args.TryGetValue(input, out v)) { allInTrue = false; allInFalse = false; continue; }
                if (v == "FALSE") reset = true; else allInFalse = false;
                if (v != "TRUE") allInTrue = false;
            }

            // ---- 004 (timers only): PT never set / IN always the constant FALSE
            if (TimerTypes.Contains(x.TypeName))
            {
                if (positional) Skip2b(RTm4, x, "positional-arguments");
                else
                {
                    InstUse c0 = calls[0];
                    if (!ptSet)
                        Emit(RTm4, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                            "Timer '" + x.Name + " : " + x.TypeName + "' never gets PT (no PT := in any call, no " + x.Name + ".PT :=, no initial value): PT stays T#0s and the timer gives no delay " +
                            "(measured 2026-11-13, XAE 4026.22 / UmRT: TON with PT = T#0S has Q = TRUE in the cycle IN rises)",
                            x.Name, "Pass PT := <time> in the call or initialise PT in the declaration", "pt-unset", null, null, false);
                    else if (allInFalse && !inWritten)
                        Emit(RTm4, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                            "Timer '" + x.Name + " : " + x.TypeName + "' is always called with IN := FALSE: it never starts",
                            x.Name, "Connect IN to the start condition", "in-constant", null, null, false);
                }
            }

            // ---- where the calls run: the POU body, or a member the body calls unconditionally every time it runs
            string top = x.Owner.Path;
            List<InstUse> level = new List<InstUse>();
            List<InstUse> other = new List<InstUse>();
            foreach (InstUse c in calls)
            {
                if (c.Call.InPragma) { Skip2b(RTm1, x, "call-in-pragma"); return; }
                if (c.U.Path == top || MemberRunsEveryTime(c.U.Path, top, secs)) level.Add(c); else other.Add(c);
            }
            foreach (InstUse c in level) if (!c.Call.Conditional) return;   // unconditional call: 001 / 002 / 005 fine
            if (level.Count == 0)
            {
                InstUse c0 = other[0];
                Emit(RTm2, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                    "Timer / trigger '" + x.Name + " : " + x.TypeName + "' is only called in method / action " + c0.U.Path + ", which the POU body does not call unconditionally: it is not proven to be updated every cycle",
                    x.Name, "Call the instance (or the member that calls it) unconditionally in the POU body", null, null, null, false);
                return;
            }
            if (other.Count > 0) { Skip2b(RTm1, x, "also-called-in-member"); return; }
            foreach (InstUse c in level) if (StAnalyzer.InLoop(c.Call.FramePath)) { Skip2b(RTm1, x, "call-in-loop"); return; }
            // every branch of an IF ... ELSE / CASE ... ELSE (nested) calls it: called every time the section runs
            Dictionary<ImplUnit, List<string[]>> bySec = new Dictionary<ImplUnit, List<string[]>>();
            foreach (InstUse c in level)
            {
                List<string[]> l;
                if (!bySec.TryGetValue(c.U, out l)) { l = new List<string[]>(); bySec[c.U] = l; }
                l.Add(c.Call.FramePath.Split('>'));
            }
            foreach (KeyValuePair<ImplUnit, List<string[]>> kv in bySec)
            {
                Dictionary<string, HashSet<string>> bm;
                if (!branchMaps.TryGetValue(kv.Key.Path, out bm)) { bm = BranchMap(kv.Key.Scan.Lex.Tokens); branchMaps[kv.Key.Path] = bm; }
                if (Exhaustive(kv.Value, 0, bm)) return;
            }
            InstUse first = level[0];
            // ---- 005: on-delay timer of a state machine (all calls in branches of one CASE), IN := TRUE, never reset
            string caseKey = null; bool oneCase = true;
            foreach (InstUse c in level)
            {
                string k = null;
                foreach (string seg in c.Call.FramePath.Split('>')) if (seg.StartsWith("CASE@", StringComparison.Ordinal)) { k = c.U.Path + "/" + seg.Substring(0, seg.IndexOf('|')); break; }
                if (k == null || (caseKey != null && k != caseKey)) oneCase = false;
                caseKey = k;
            }
            if (OnDelay.Contains(x.TypeName) && oneCase && !reset && allInTrue && !positional)
            {
                Emit(RTm5, x.Owner.O.Rel, first.U.Path, "implementation", first.Line, first.Col,
                    "State timer '" + x.Name + " : " + x.TypeName + "' is only called with IN := TRUE inside CASE branches and never with IN := FALSE: after the state is left, IN stays TRUE, " +
                    "so the next entry has no rising edge and the elapsed time keeps counting (measured 2026-11-13, XAE 4026.22 / UmRT: a TON not called for 3 s had Q = TRUE in its first call again)",
                    x.Name, "Call " + x.Name + "(IN := FALSE) when the state is left (or in every other state)", null, null, null, false);
                return;
            }
            if (reset) { Skip2b(RTm1, x, "explicit-reset"); return; }
            Emit(RTm1, x.Owner.O.Rel, first.U.Path, "implementation", first.Line, first.Col,
                "Timer / trigger '" + x.Name + " : " + x.TypeName + "' is only called inside IF / CASE (" + first.Call.Blocks + "): in cycles it is not called its inputs are not sampled " +
                (x.Class == "edge" ? "(an edge between two calls is missed)" : "(a TON keeps measuring wall-clock time while not called and can be elapsed at once on the next call, measured 2026-11-13, XAE 4026.22 / UmRT)"),
                x.Name, "Call the instance unconditionally every cycle and put the condition on IN / CLK", null, null, null, false);
        }

        // an action / method of the owner that the owner's body calls unconditionally (statement, outside IF / CASE / loop)
        private bool MemberRunsEveryTime(string path, string top, List<ImplUnit> secs)
        {
            if (!path.StartsWith(top + ".", StringComparison.OrdinalIgnoreCase)) return false;
            string member = path.Substring(top.Length + 1);
            if (member.IndexOf('.') >= 0) return false;   // property accessor
            foreach (ImplUnit u in secs)
            {
                if (u.Path != top) continue;
                foreach (CallSite cs in u.Scan.Calls)
                {
                    string tg = cs.Target ?? "";
                    if (tg.StartsWith("THIS^.", StringComparison.OrdinalIgnoreCase)) tg = tg.Substring(6);
                    if (string.Equals(tg, member, StringComparison.OrdinalIgnoreCase) && cs.StatementStart && !cs.Conditional && !cs.InPragma) return true;
                }
            }
            return false;
        }

        // branches of every IF / CASE of a section, keyed like CallSite.FramePath ("IF@3:1" -> then, elsif#1, else);
        // mirrors StAnalyzer.ScanImplementation (ELSIF index, ':' inside CASE starts a label)
        private static Dictionary<string, HashSet<string>> BranchMap(List<Token> t)
        {
            Dictionary<string, HashSet<string>> map = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
            List<string> kinds = new List<string>(); List<string> keys = new List<string>(); List<int> idx = new List<int>();
            foreach (Token x in t)
            {
                int top = kinds.Count - 1;
                if (x.Kind == TokKind.Op)
                {
                    if (x.Text == ":" && top >= 0 && kinds[top] == "CASE") { idx[top]++; map[keys[top]].Add("label#" + Inv.S(idx[top])); }
                    continue;
                }
                if (x.Kind != TokKind.Ident) continue;
                string u = x.Upper;
                if (u == "IF" || u == "CASE" || u == "FOR" || u == "WHILE" || u == "REPEAT" || u == "__TRY")
                {
                    string kind = u == "__TRY" ? "TRY" : u;
                    string key = kind + "@" + Inv.S(x.Line) + ":" + Inv.S(x.Col);
                    kinds.Add(kind); keys.Add(key); idx.Add(0);
                    map[key] = new HashSet<string>(StringComparer.Ordinal);
                    if (kind == "IF") map[key].Add("then");
                }
                else if (u == "ELSIF" && top >= 0 && kinds[top] == "IF") { idx[top]++; map[keys[top]].Add("elsif#" + Inv.S(idx[top])); }
                else if (u == "ELSE" && top >= 0 && kinds[top] == "IF") map[keys[top]].Add("else");
                else if (u == "ELSE" && top >= 0 && kinds[top] == "CASE") map[keys[top]].Add("case-else");
                else if ((u == "END_IF" || u == "END_CASE" || u == "END_FOR" || u == "END_WHILE" || u == "END_REPEAT" || u == "__ENDTRY") && top >= 0)
                { kinds.RemoveAt(top); keys.RemoveAt(top); idx.RemoveAt(top); }
            }
            return map;
        }

        // the calls (frame paths from depth on) cover every path through the block: a call at this depth, or one IF / CASE
        // with an ELSE whose every branch is covered again
        private static bool Exhaustive(List<string[]> paths, int depth, Dictionary<string, HashSet<string>> map)
        {
            foreach (string[] p in paths) if (p.Length <= depth || (p.Length == 1 && p[0].Length == 0)) return true;
            Dictionary<string, List<string[]>> groups = new Dictionary<string, List<string[]>>(StringComparer.Ordinal);
            foreach (string[] p in paths)
            {
                string key = p[depth].Substring(0, p[depth].IndexOf('|'));
                List<string[]> l;
                if (!groups.TryGetValue(key, out l)) { l = new List<string[]>(); groups[key] = l; }
                l.Add(p);
            }
            foreach (KeyValuePair<string, List<string[]>> g in groups)
            {
                HashSet<string> branches;
                if (!map.TryGetValue(g.Key, out branches)) continue;
                if (!branches.Contains("else") && !branches.Contains("case-else")) continue;
                bool all = true;
                foreach (string b in branches)
                {
                    List<string[]> sub = new List<string[]>();
                    foreach (string[] p in g.Value) if (p[depth].Substring(p[depth].IndexOf('|') + 1) == b) sub.Add(p);
                    if (sub.Count == 0 || !Exhaustive(sub, depth + 1, map)) { all = false; break; }
                }
                if (all) return true;
            }
            return false;
        }
    }
}
