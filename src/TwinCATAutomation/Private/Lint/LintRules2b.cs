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
            public bool? AssignConst;  // inst.Member := <constant TRUE / FALSE>; null = not a constant (variable, expression)
            public bool Passed;        // inst.Member handed on: call argument (VAR_IN_OUT / ADR / MEMCPY / =>), REF= source
            public int Line, Col;
            public CallSite Call;      // body-call only
            public string Via;         // review SF3: the call is judged at the body's call of this action / method
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

        // a reason that stops the timer checks: one rulesSkipped entry per timer rule that applies to the type and is
        // still open (t2: SCAN-TIMER-002 not decided yet, t4: SCAN-TIMER-004 not decided yet)
        private void SkipTimer(Inst x, string reason, bool t2, bool t4)
        {
            if (!IsTimerish(x)) return;
            Skip2b(RTm1, x, reason);
            if (t2) Skip2b(RTm2, x, reason);
            if (t4 && TimerTypes.Contains(x.TypeName)) Skip2b(RTm4, x, reason);
            if (OnDelay.Contains(x.TypeName)) Skip2b(RTm5, x, reason);
        }

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
                        if (cls == "unknown" && LibraryNotFb(tn)) continue;   // review nit 5: certainly not an FB (enum / struct / alias)
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
                    // one entry per rule that applies: FBCALL-001 / 002 to every FB instance, TIMER-* by type
                    if (x.Skip == "unknown-type" || x.Skip == "type-alias") { Skip2b(RFb1, x, x.Skip + ":" + x.TypeName); Skip2b(RFb2, x, x.Skip + ":" + x.TypeName); continue; }
                    Skip2b(RFb1, x, x.Skip);
                    Skip2b(RFb2, x, x.Skip);
                    SkipTimer(x, x.Skip, true, true);
                    continue;
                }
                CheckFbCall(x);
                if (IsTimerish(x)) CheckTimer(x, secs, branchMaps);
            }
        }

        // a type outside the project that is certainly not a function block, so no FBCALL / TIMER rule applies (rule-catalog
        // Phase 2b): Tc2_System / Tc2_Utilities / Tc2_MC2 string aliases, enums and structs listed by name, and the Beckhoff
        // naming convention E_ (enum) / ST_ (struct) of library types (inferred from the naming convention, not read from
        // the library). Everything else outside the project stays rulesSkipped unknown-type.
        private static readonly HashSet<string> LibNonFb = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "T_MaxString", "T_AmsNetId", "T_AmsNetIdArr", "T_AmsPort", "T_FILETIME", "TIMESTRUCT", "T_Arg",
            "MC_Direction", "MC_StartMode", "MC_BufferMode", "MC_CamActivationMode", "MC_CamOperationMode",
            "MC_CAM_ID", "MC_CAM_REF", "MC_MotionFunctionPoint", "MC_HomingMode", "MC_HomingParameter"
        };

        private static bool LibraryNotFb(string typeName)
        {
            if (string.IsNullOrEmpty(typeName)) return false;
            string n = typeName; int dot = n.LastIndexOf('.'); if (dot >= 0) n = n.Substring(dot + 1);
            if (LibNonFb.Contains(n)) return true;
            return n.StartsWith("E_", StringComparison.OrdinalIgnoreCase) || n.StartsWith("ST_", StringComparison.OrdinalIgnoreCase);
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
                    if (use.Assign) use.AssignConst = ConstBool2b(t, i + 4, StatementEnd(t, i + 4));
                    else if (use.Kind == "member") use.Passed = HandedOn(t, start);
                }
                else { x.Skip = "passed-or-aliased"; return; }   // f(inst), ADR(inst), r REF= inst, itf := inst, inst := other
                x.Uses.Add(use);
            }
        }

        // index of the ';' (or end) that closes the statement starting at from (depth 0)
        private static int StatementEnd(List<Token> t, int from)
        {
            int depth = 0;
            for (int k = from; k < t.Count; k++)
            {
                if (t[k].Kind == TokKind.EOF) return k;
                if (t[k].IsOp("(") || t[k].IsOp("[")) depth++;
                else if (t[k].IsOp(")") || t[k].IsOp("]")) depth--;
                else if (depth <= 0 && t[k].IsOp(";")) return k;
            }
            return t.Count;
        }

        // inst.Member at index at is handed on, so something else may write it: the source of REF=, or inside the argument
        // list of a call (F(inst.PT), F(x := inst.PT) with VAR_IN_OUT, ADR(inst.PT), MEMCPY(ADR(inst.PT), ...), fb(Q => inst.IN));
        // a value-only use (TIME_TO_DINT(inst.PT)) counts too - conservative, recorded as a skip
        private static bool HandedOn(List<Token> t, int at)
        {
            if (at > 0 && t[at - 1].IsOp("REF=")) return true;
            int depth = 0;
            for (int k = at - 1; k >= 0; k--)
            {
                Token p = t[k];
                if (p.IsOp(";")) return false;
                if (p.IsOp(")")) depth++;
                else if (p.IsOp("("))
                {
                    // '(' of a call (any identifier before it, ADR / SIZEOF included) -> handed on; a grouping '(' -> look further out
                    if (depth == 0) { if (k > 0 && t[k - 1].Kind == TokKind.Ident && (!StLexer.Keywords.Contains(t[k - 1].Upper) || t[k - 1].Upper == "ADR" || t[k - 1].Upper == "REF")) return true; }
                    else depth--;
                }
                else if (depth == 0 && p.Kind == TokKind.Ident && (p.Upper == "THEN" || p.Upper == "ELSE" || p.Upper == "DO" || p.Upper == "OF" || p.Upper == "IF" || p.Upper == "ELSIF")) return false;
            }
            return false;
        }

        // value of a constant boolean expression in t[from, to): TRUE / FALSE, NOT, parentheses, AND / OR / XOR (and the
        // short-circuit forms), comparisons of integer literals; null = not a constant the linter evaluates
        private static bool? ConstBool2b(List<Token> t, int from, int to)
        {
            while (to > from + 1 && t[from].IsOp("(") && t[to - 1].IsOp(")") && Closes(t, from) == to - 1) { from++; to--; }
            if (to <= from) return null;
            string[][] levels = { new string[] { "OR", "OR_ELSE" }, new string[] { "XOR" }, new string[] { "AND", "AND_THEN", "&" } };
            foreach (string[] ops in levels)
            {
                int depth = 0;
                for (int k = to - 1; k > from; k--)
                {
                    if (t[k].IsOp(")")) depth++;
                    else if (t[k].IsOp("(")) depth--;
                    else if (depth == 0 && ((t[k].Kind == TokKind.Ident && Array.IndexOf(ops, t[k].Upper) >= 0) || (t[k].Kind == TokKind.Op && Array.IndexOf(ops, t[k].Text) >= 0)))
                    {
                        bool? l = ConstBool2b(t, from, k), r = ConstBool2b(t, k + 1, to);
                        if (!l.HasValue || !r.HasValue) return null;
                        return ops[0] == "OR" ? l.Value || r.Value : ops[0] == "XOR" ? l.Value != r.Value : l.Value && r.Value;
                    }
                }
            }
            if (t[from].Is("NOT")) { bool? v = ConstBool2b(t, from + 1, to); return v.HasValue ? !v.Value : (bool?)null; }
            if (to == from + 1 && t[from].Is("TRUE")) return true;
            if (to == from + 1 && t[from].Is("FALSE")) return false;
            if (to == from + 3 && t[from].Kind == TokKind.Number && t[from + 2].Kind == TokKind.Number && t[from + 1].Kind == TokKind.Op)
            {
                long l, r;
                if (!long.TryParse(t[from].Text.Replace("_", ""), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out l) ||
                    !long.TryParse(t[from + 2].Text.Replace("_", ""), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out r)) return null;
                switch (t[from + 1].Text)
                {
                    case "=": return l == r;
                    case "<>": return l != r;
                    case "<": return l < r;
                    case ">": return l > r;
                    case "<=": return l <= r;
                    case ">=": return l >= r;
                }
            }
            return null;
        }

        private static int Closes(List<Token> t, int open)
        {
            int depth = 0;
            for (int k = open; k < t.Count; k++)
            {
                if (t[k].IsOp("(")) depth++;
                else if (t[k].IsOp(")")) { depth--; if (depth == 0) return k; }
            }
            return -1;
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
            // a library base in the EXTENDS chain (members == null): variables declared by the project part of the chain are
            // plain data (no code runs); any other name may be a Property / Method of the library base -> skip, never silent
            HashSet<string> chainVars = x.Class == "project-fb" && members == null ? ChainVars(x.TypeName) : null;
            bool unknownMember = false;
            foreach (InstUse u in x.Uses)
            {
                if (first == null) first = u;
                if (u.Kind == "body-call") called = true;
                else if (x.Class == "project-fb" && (u.Kind == "member-call" || (members != null && members.Contains(u.Member)))) called = true;   // method / action / property (accessor code runs)
                else if (x.Class == "project-fb" && members == null) { if (!chainVars.Contains(u.Member)) unknownMember = true; }
                else if (u.Kind == "member-call") { Skip2b(RFb1, x, "member-call-of-library-fb"); return; }
            }
            string decl = x.Name + " : " + x.V.TypeText;
            if (x.Uses.Count == 0)
            {
                // FB_init / FB_reinit / FB_exit run without any reference (constructor arguments, registration): not dead
                if (x.Class == "project-fb")
                {
                    HashSet<string> m = members;
                    if (m == null || m.Contains("FB_init") || m.Contains("FB_reinit") || m.Contains("FB_exit") || (x.V.TypeText ?? "").IndexOf('(') >= 0) { Skip2b(RFb2, x, "fb-init"); return; }
                }
                if (x.Class == "project-fb" || x.Class == "timer" || x.Class == "edge" || x.Class == "counter" || x.Class == "bistable" || x.Class == "stateful" || x.Class == "type-only")
                    Emit(RFb2, x.Owner.O.Rel, x.Owner.Path, "declaration", x.V.Line, x.V.Col,
                        "Function block instance '" + decl + "' is declared but never used in " + x.Owner.Path + " (no call, no member access, not passed on)",
                        decl, "Remove the instance, or call it where it is meant to run", null, null, null, false);
                return;
            }
            if (called) return;
            if (unknownMember) { Skip2b(RFb1, x, "library-base-members-unknown"); return; }
            Emit(RFb1, x.Owner.O.Rel, x.Owner.Path, "declaration", x.V.Line, x.V.Col,
                "Function block instance '" + decl + "' is used (" + first.U.Path + " implementation line " + Inv.S(first.Line) + ": ." + (first.Member ?? "?") + ") but never called: " +
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

        // variables declared (any VAR block) by the project FBs of an EXTENDS chain, up to the first base outside the project
        private HashSet<string> ChainVars(string type)
        {
            HashSet<string> v = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string cur = type;
            while (cur != null && seen.Add(cur))
            {
                PouNode p;
                if (!pouIndex.TryGetValue(cur, out p)) break;
                foreach (DeclUnit d in declUnits)
                {
                    if (d.O != p.O || d.Path != d.O.ObjectPath) continue;
                    foreach (VarBlock b in d.Di.VarBlocks) foreach (VarDecl vd in b.Vars) foreach (string n in vd.Names) v.Add(n);
                }
                List<string> bases;
                cur = fbExtends.TryGetValue(cur, out bases) && bases.Count > 0 ? LastSegment(bases[0]) : null;
            }
            return v;
        }

        // ================================================================ SCAN-TIMER-001 / 002 / 004 / 005
        private static readonly HashSet<string> TimerTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "TON", "TOF", "TP", "LTON", "LTOF", "LTP" };
        // only TON is measured (runtime-semantics-measured.md sections 4 / 5); TOF / TP / LT* and R_TRIG / F_TRIG -> inferred
        private static string TimerBasis(string type) { return string.Equals(type, "TON", StringComparison.OrdinalIgnoreCase) ? null : "inferred"; }
        private static readonly HashSet<string> OnDelay = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "TON", "LTON" };

        private void CheckTimer(Inst x, List<ImplUnit> secs, Dictionary<string, Dictionary<string, HashSet<string>>> branchMaps)
        {
            List<InstUse> calls = new List<InstUse>();
            foreach (InstUse u in x.Uses) if (u.Kind == "body-call") calls.Add(u);
            if (calls.Count == 0) return;   // SCAN-FBCALL-001 / 002
            foreach (InstUse u in x.Uses) if (u.Kind == "member-call") { SkipTimer(x, "member-call", true, true); return; }
            string input = x.Class == "edge" ? "CLK" : "IN";
            bool positional = false, reset = false, allInTrue = true, allInFalse = true, inWritten = false, inWriteUnsampled = false;
            string init = InitHasPt(x.V.InitText);   // set / unset / unknown
            bool ptSet = init == "set";
            bool ptPassed = false, inPassed = false;   // inst.PT / inst.IN handed to a call, ADR or REF=: may be written there
            Dictionary<InstUse, bool?> sampledIn = new Dictionary<InstUse, bool?>();   // call without IN argument -> value of the inst.IN := before it
            foreach (InstUse u in x.Uses)
            {
                if (u.Kind == "member" && u.Passed && string.Equals(u.Member, "PT", StringComparison.OrdinalIgnoreCase)) ptPassed = true;
                if (u.Kind == "member" && u.Passed && string.Equals(u.Member, input, StringComparison.OrdinalIgnoreCase)) inPassed = true;
                if (u.Kind == "member" && u.Assign && string.Equals(u.Member, "PT", StringComparison.OrdinalIgnoreCase)) ptSet = true;
                if (u.Kind == "member" && u.Assign && string.Equals(u.Member, input, StringComparison.OrdinalIgnoreCase))
                {
                    // inst.IN := v only reaches the FB when a later call without an IN argument runs on the same path;
                    // otherwise the next call passes its own IN (inferred from IEC FB call semantics, not measured).
                    // Only the constant FALSE is a reset; TRUE makes that call an IN := TRUE call, anything else a variable IN.
                    InstUse by;
                    string eff = InWriteSampled(x, u, input, out by);
                    if (eff == "unknown") { SkipTimer(x, "input-write-unresolved", true, true); return; }
                    if (eff == "yes") { inWritten = true; if (u.AssignConst == false) reset = true; sampledIn[by] = u.AssignConst; }
                    else if (u.AssignConst == false) inWriteUnsampled = true;   // inst.IN := FALSE not sampled by a later call (inferred)
                }
            }
            foreach (InstUse c in calls)
            {
                if (c.Args == null) { positional = true; continue; }
                string v;
                if (c.Args.ContainsKey("PT")) ptSet = true;
                bool? sv;
                if (!c.Args.TryGetValue(input, out v))
                {
                    if (sampledIn.TryGetValue(c, out sv) && sv.HasValue) v = sv.Value ? "TRUE" : "FALSE";
                    else { allInTrue = false; allInFalse = false; continue; }
                }
                if (v == "FALSE") reset = true; else allInFalse = false;
                if (v != "TRUE") allInTrue = false;
            }

            // ---- 004 (timers only): PT never set / IN always the constant FALSE
            if (TimerTypes.Contains(x.TypeName))
            {
                if (positional) Skip2b(RTm4, x, "positional-arguments");
                else if (init == "unknown" && !ptSet) Skip2b(RTm4, x, "initialiser-not-parsed");
                else
                {
                    InstUse c0 = calls[0];
                    if (!ptSet && ptPassed) Skip2b(RTm4, x, "pt-passed-or-aliased");
                    else if (!ptSet)
                    {
                        Diagnostic d = Emit(RTm4, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                            "Timer '" + x.Name + " : " + x.TypeName + "' never gets PT (no PT := in any call, no " + x.Name + ".PT :=, no initial value): PT stays T#0s and the timer gives no delay " +
                            "(measured 2026-11-13, XAE 4026.22 / UmRT: TON with PT = T#0S has Q = TRUE in the cycle IN rises)",
                            x.Name, "Pass PT := <time> in the call or initialise PT in the declaration", "pt-unset", null, null, false);
                        if (d != null) d.ImpactBasis = TimerBasis(x.TypeName);
                    }
                    else if (allInFalse && !inWritten && inPassed) Skip2b(RTm4, x, "in-passed-or-aliased");
                    else if (allInFalse && !inWritten)
                    {
                        Diagnostic d = Emit(RTm4, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                            "Timer '" + x.Name + " : " + x.TypeName + "' is always called with IN := FALSE: it never starts",
                            x.Name, "Connect IN to the start condition", "in-constant", null, null, false);
                        if (d != null) { d.Confidence = "medium"; d.ImpactBasis = "inferred"; }   // rule-catalog: in-constant medium (constant folding not done); "never starts" not measured
                    }
                }
            }

            // ---- where the calls run: the POU body, or a member the body calls unconditionally every time it runs
            string top = x.Owner.Path;
            List<InstUse> level = new List<InstUse>();
            List<InstUse> other = new List<InstUse>();
            foreach (InstUse c in calls)
            {
                if (c.Call.InPragma) { SkipTimer(x, "call-in-pragma", true, false); return; }
                if (c.U.Path == top || MemberRunsEveryTime(c.U.Path, top, secs)) level.Add(c); else other.Add(c);
            }
            // review SF3: an unconditional call in an action / method that the body calls at exactly one place (a statement in
            // an IF / CASE branch) and nothing else can call -> judged at that place (001 / 005); otherwise 002 + the reason
            string elsewhere = null;
            for (int oi = other.Count - 1; oi >= 0; oi--)
            {
                string why;
                InstUse s = AtMemberCallSite(x, other[oi], top, secs, out why);
                if (s != null) { level.Add(s); other.RemoveAt(oi); }
                else if (why != null) elsewhere = why;
            }
            foreach (InstUse c in level) if (!c.Call.Conditional) return;   // unconditional call: 001 / 002 / 005 fine
            // IF TRUE THEN / IF 1 = 1 THEN: always runs; IF FALSE THEN: never runs (the call is dropped)
            bool droppedFalse = false;
            for (int li = level.Count - 1; li >= 0; li--)
            {
                bool? cc = ConstFrames(level[li]);
                if (cc == true) return;
                if (cc == false) { level.RemoveAt(li); droppedFalse = true; }
            }
            if (level.Count == 0 && other.Count == 0) { if (droppedFalse) Skip2b(RTm1, x, "constant-false-condition"); return; }
            if (level.Count == 0)
            {
                InstUse c0 = other[0];
                string where = c0.U.Path.Length > top.Length + 1 && c0.U.Path.Substring(top.Length + 1).IndexOf('.') >= 0 ? "property accessor " : "method / action ";
                Emit(RTm2, x.Owner.O.Rel, c0.U.Path, "implementation", c0.Line, c0.Col,
                    "Timer / trigger '" + x.Name + " : " + x.TypeName + "' is only called in " + where + c0.U.Path + ", which the POU body does not call unconditionally: it is not proven to be updated every cycle",
                    x.Name, "Call the instance (or the member that calls it) unconditionally in the POU body", null, null, null, false);
                if (elsewhere != null) { Skip2b(RTm1, x, elsewhere); if (OnDelay.Contains(x.TypeName)) Skip2b(RTm5, x, elsewhere); }
                return;
            }
            if (other.Count > 0) { SkipTimer(x, "also-called-in-member", false, false); return; }
            foreach (InstUse c in level) if (StAnalyzer.InLoop(c.Call.FramePath)) { SkipTimer(x, "call-in-loop", false, false); return; }
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
            if (OnDelay.Contains(x.TypeName) && oneCase && !reset && allInTrue && !positional && inPassed) Skip2b(RTm5, x, "in-passed-or-aliased");
            else if (OnDelay.Contains(x.TypeName) && oneCase && !reset && allInTrue && !positional)
            {
                Diagnostic d5 = Emit(RTm5, x.Owner.O.Rel, first.U.Path, "implementation", first.Line, first.Col,
                    "State timer '" + x.Name + " : " + x.TypeName + "' is only called with IN := TRUE inside CASE branches" + (first.Via != null ? " (through " + first.Via + ")" : "") + " and never with IN := FALSE: after the state is left, IN stays TRUE, " +
                    "so the next entry has no rising edge and the elapsed time keeps counting (measured 2026-11-13, XAE 4026.22 / UmRT: a TON not called for 3 s had Q = TRUE in its first call again)",
                    x.Name, "Call " + x.Name + "(IN := FALSE) when the state is left (or in every other state)", null, null, null, false);
                // inst.IN := FALSE without a later call (not sampled) is inferred from IEC call semantics; LTON is not measured
                if (d5 != null && (inWriteUnsampled || TimerBasis(x.TypeName) != null)) d5.ImpactBasis = "inferred";
                return;
            }
            if (reset) { Skip2b(RTm1, x, "explicit-reset"); return; }
            Diagnostic d1 = Emit(RTm1, x.Owner.O.Rel, first.U.Path, "implementation", first.Line, first.Col,
                "Timer / trigger '" + x.Name + " : " + x.TypeName + "' is only called inside IF / CASE (" + first.Call.Blocks + (first.Via != null ? ", through " + first.Via : "") + "): in cycles it is not called its inputs are not sampled " +
                (x.Class == "edge" ? "(an edge between two calls is missed)"
                    : string.Equals(x.TypeName, "TON", StringComparison.OrdinalIgnoreCase) ? "(a TON keeps measuring wall-clock time while not called and can be elapsed at once on the next call, measured 2026-11-13, XAE 4026.22 / UmRT)"
                    : "(a " + x.TypeName + " may change its output at once on the next call because its time keeps running while not called - inferred from the measured TON behaviour, only TON was measured)"),
                x.Name, "Call the instance unconditionally every cycle and put the condition on IN / CLK", null, null, null, false);
            if (d1 != null) d1.ImpactBasis = TimerBasis(x.TypeName);
        }

        // review SF3: c is an unconditional timer call inside an action / method M of the owner. When the owner's body calls M at
        // exactly one place, as a statement (not in a loop / {IF} region), no other section calls it, no '.M' appears anywhere in
        // the project (fb.M() from outside), the owner IMPLEMENTS no interface and no FB EXTENDS it -> a use at that body call
        // site. why: rulesSkipped reason when M may be called from elsewhere (member-called-elsewhere), null otherwise
        private InstUse AtMemberCallSite(Inst x, InstUse c, string top, List<ImplUnit> secs, out string why)
        {
            why = null;
            if (c.Call.Conditional || !c.U.Path.StartsWith(top + ".", StringComparison.OrdinalIgnoreCase)) return null;
            string member = c.U.Path.Substring(top.Length + 1);
            if (member.IndexOf('.') >= 0) return null;   // property accessor
            bool impl = false;
            if (x.Owner.Di.Lex != null) foreach (Token k in x.Owner.Di.Lex.Tokens) if (k.Is("IMPLEMENTS")) { impl = true; break; }
            if (dotNames.ContainsKey(member) || impl || derivedBases.Contains(x.Owner.O.Name)) { why = "member-called-elsewhere"; return null; }
            CallSite site = null; ImplUnit at = null; int n = 0;
            foreach (ImplUnit u in secs)
                foreach (CallSite cs in u.Scan.Calls)
                {
                    string tg = cs.Target ?? "";
                    if (tg.StartsWith("THIS^.", StringComparison.OrdinalIgnoreCase)) tg = tg.Substring(6);
                    if (!string.Equals(tg, member, StringComparison.OrdinalIgnoreCase)) continue;
                    n++; site = cs; at = u;
                }
            if (n != 1) { if (n > 1) why = "member-called-elsewhere"; return null; }
            if (at.Path != top || site.InPragma || !site.Conditional || StAnalyzer.InLoop(site.FramePath) || !StatementStart(site, at.Scan.Lex.Tokens)) return null;
            InstUse s = new InstUse();
            s.U = at; s.Kind = "body-call"; s.Line = site.Line; s.Col = site.Col; s.Call = site; s.Args = c.Args; s.Via = member;
            return s;
        }

        // the call's enclosing blocks: true when every one is the THEN branch of an IF whose condition is a constant TRUE
        // (IF TRUE THEN, IF 1 = 1 THEN); false when one is the THEN branch of an IF with a constant FALSE condition (never
        // runs); null otherwise
        private static bool? ConstFrames(InstUse c)
        {
            string fp = c.Call.FramePath ?? "";
            if (fp.Length == 0) return null;
            List<Token> t = c.U.Scan.Lex.Tokens;
            bool allTrue = true;
            foreach (string seg in fp.Split('>'))
            {
                bool? v = null;
                int atSign = seg.IndexOf('@'), colon = seg.IndexOf(':'), bar = seg.IndexOf('|');
                int ln, cl;
                if (seg.StartsWith("IF@", StringComparison.Ordinal) && bar > colon && colon > atSign && seg.Substring(bar + 1) == "then" &&
                    int.TryParse(seg.Substring(atSign + 1, colon - atSign - 1), out ln) && int.TryParse(seg.Substring(colon + 1, bar - colon - 1), out cl))
                {
                    int open = -1;
                    for (int i = 0; i < t.Count; i++) if (t[i].Line == ln && t[i].Col == cl) { open = i; break; }
                    if (open >= 0)
                    {
                        int end = -1;
                        for (int i = open + 1; i < t.Count; i++) if (t[i].Is("THEN")) { end = i; break; }
                        if (end > open + 1) v = ConstBool2b(t, open + 1, end);
                    }
                }
                if (v == false) return false;
                if (v != true) allTrue = false;
            }
            return allTrue ? true : (bool?)null;
        }

        // an action / method of the owner that runs every time the owner's body runs: called from the body (or from a member
        // that itself runs every time, e.g. body -> M_Outer -> M_Inner) as a statement or inside an expression (x := M(),
        // IF M() THEN: a value-returning call is evaluated too), outside IF / CASE / loop branches and not behind AND_THEN /
        // OR_ELSE; the condition of a top-level IF / CASE / WHILE / FOR counts (it is evaluated every time)
        private bool MemberRunsEveryTime(string path, string top, List<ImplUnit> secs)
        {
            return MemberRunsEveryTime(path, top, secs, new HashSet<string>(StringComparer.OrdinalIgnoreCase));
        }

        private bool MemberRunsEveryTime(string path, string top, List<ImplUnit> secs, HashSet<string> seen)
        {
            if (!path.StartsWith(top + ".", StringComparison.OrdinalIgnoreCase)) return false;
            string member = path.Substring(top.Length + 1);
            if (member.IndexOf('.') >= 0) return false;   // property accessor
            if (!seen.Add(member)) return false;
            foreach (ImplUnit u in secs)
            {
                if (u.Path != top && !MemberRunsEveryTime(u.Path, top, secs, seen)) continue;
                List<string[]> paths = new List<string[]>();
                foreach (CallSite cs in u.Scan.Calls)
                {
                    string tg = cs.Target ?? "";
                    if (tg.StartsWith("THIS^.", StringComparison.OrdinalIgnoreCase)) tg = tg.Substring(6);
                    if (!string.Equals(tg, member, StringComparison.OrdinalIgnoreCase) || cs.InPragma) continue;
                    if (CallEvaluatedEveryTime(cs, u.Scan.Lex.Tokens)) return true;
                    if (cs.Conditional && !string.IsNullOrEmpty(cs.FramePath) && !StAnalyzer.InLoop(cs.FramePath) && StatementStart(cs, u.Scan.Lex.Tokens)) paths.Add(cs.FramePath.Split('>'));
                }
                // every branch of an IF ... ELSE / CASE ... ELSE calls it (same rule as a direct timer call, SCAN-TIMER-001)
                if (paths.Count > 0 && Exhaustive(paths, 0, BranchMap(u.Scan.Lex.Tokens))) return true;
            }
            return false;
        }

        // the call starts a statement of its branch (or is the value of x := M()), not behind AND_THEN / OR_ELSE or in a condition
        private static bool StatementStart(CallSite cs, List<Token> t)
        {
            int at = -1;
            for (int i = 0; i < t.Count; i++) if (t[i].Line == cs.Line && t[i].Col == cs.Col) { at = i; break; }
            if (at < 0) return false;
            for (int i = at - 1; i >= 0; i--)
            {
                if (t[i].IsOp(";") || t[i].IsOp(":")) return true;   // previous statement / CASE label
                if (t[i].Kind != TokKind.Ident) continue;
                string u = t[i].Upper;
                if (u == "THEN" || u == "ELSE" || u == "DO") return true;
                if (u == "AND_THEN" || u == "OR_ELSE" || u == "IF" || u == "ELSIF" || u == "CASE" || u == "WHILE" || u == "UNTIL") return false;
            }
            return true;
        }

        // PT in the declaration initialiser: "set" / "unset" (no initialiser, or a (NAME := v, ...) list without PT) /
        // "unknown" (anything the linter does not parse)
        private static string InitHasPt(string init)
        {
            if (init == null || init.Trim().Length == 0) return "unset";
            LexResult lx = StLexer.Lex(init);
            if (lx.Error != null || lx.Unknown.Count > 0) return "unknown";
            List<Token> t = new List<Token>();
            foreach (Token k in lx.Tokens) if (k.Kind != TokKind.EOF) t.Add(k);
            if (t.Count < 2 || !t[0].IsOp("(") || !t[t.Count - 1].IsOp(")")) return "unknown";
            int depth = 0; bool expectName = true;
            for (int i = 0; i < t.Count; i++)
            {
                if (t[i].IsOp("(") || t[i].IsOp("[")) { depth++; if (depth == 1) continue; }
                else if (t[i].IsOp(")") || t[i].IsOp("]")) { depth--; continue; }
                if (depth != 1) continue;
                if (t[i].IsOp(",")) { expectName = true; continue; }
                if (expectName)
                {
                    if (t[i].Kind != TokKind.Ident || i + 1 >= t.Count || !t[i + 1].IsOp(":=")) return "unknown";
                    if (t[i].Upper == "PT") return "set";
                    expectName = false;
                }
            }
            return "unset";
        }

        // inst.IN := v (use w): "yes" when a later call inst(...) without an IN argument runs on the same statement path
        // (same block, not inside a nested IF / CASE / loop); "no" when no call in the owner can sample it; "unknown"
        // when another section calls the instance (a member may run between the write and the next call) or the call
        // that follows has positional arguments
        private string InWriteSampled(Inst x, InstUse w, string input, out InstUse by)
        {
            by = null;
            List<Token> t = w.U.Scan.Lex.Tokens;
            int at = -1;
            for (int i = 0; i < t.Count; i++) if (t[i].Line == w.Line && t[i].Col == w.Col) { at = i; break; }
            if (at < 0) return "unknown";
            int depth = 0;
            for (int i = at + 1; i < t.Count; i++)
            {
                Token k = t[i];
                if (k.Kind == TokKind.Op) { if (depth == 0 && k.Text == ":") break; continue; }
                if (k.Kind != TokKind.Ident) continue;
                string u = k.Upper;
                if (u == "IF" || u == "CASE" || u == "FOR" || u == "WHILE" || u == "REPEAT" || u == "__TRY") { depth++; continue; }
                if (u.StartsWith("END_", StringComparison.Ordinal) || u == "__ENDTRY") { depth--; if (depth < 0) break; continue; }
                if (depth == 0 && (u == "ELSE" || u == "ELSIF" || u == "RETURN" || u == "JMP" || u == "EXIT" || u == "CONTINUE")) break;
                if (depth != 0 || !string.Equals(k.Text, x.Name, StringComparison.OrdinalIgnoreCase) || (i > 0 && t[i - 1].IsOp("."))) continue;
                foreach (InstUse c in x.Uses)
                {
                    if (c.Kind != "body-call" || c.U != w.U || c.Line != k.Line || c.Col != k.Col) continue;
                    if (c.Args == null) return "unknown";
                    if (!c.Args.ContainsKey(input)) { by = c; return "yes"; }
                }
            }
            foreach (InstUse c in x.Uses) if (c.Kind == "body-call" && c.U != w.U) return "unknown";
            return "no";
        }

        private static readonly Dictionary<string, string> CondEnd = new Dictionary<string, string>(StringComparer.Ordinal) { { "IF", "THEN" }, { "CASE", "OF" }, { "WHILE", "DO" }, { "FOR", "DO" } };

        // the call is outside every branch (or in the condition of the one enclosing IF / CASE / WHILE / FOR) and no
        // AND_THEN / OR_ELSE before it in its statement / condition can skip it
        private static bool CallEvaluatedEveryTime(CallSite cs, List<Token> t)
        {
            int at = -1;
            for (int i = 0; i < t.Count; i++) if (t[i].Line == cs.Line && t[i].Col == cs.Col) { at = i; break; }
            if (at < 0) return false;
            int from;
            if (!cs.Conditional) from = -1;
            else
            {
                string fp = cs.FramePath ?? "";
                if (fp.Length == 0 || fp.IndexOf('>') >= 0) return false;
                int atSign = fp.IndexOf('@'), colon = fp.IndexOf(':'), bar = fp.IndexOf('|');
                if (atSign < 0 || colon < atSign || bar < colon) return false;
                string kind = fp.Substring(0, atSign);
                string end;
                if (!CondEnd.TryGetValue(kind, out end)) return false;
                int ln, cl;
                if (!int.TryParse(fp.Substring(atSign + 1, colon - atSign - 1), out ln) || !int.TryParse(fp.Substring(colon + 1, bar - colon - 1), out cl)) return false;
                int open = -1;
                for (int i = 0; i < at; i++) if (t[i].Line == ln && t[i].Col == cl) { open = i; break; }
                if (open < 0) return false;
                for (int i = open + 1; i < at; i++) if (t[i].Kind == TokKind.Ident && t[i].Upper == end) return false;   // past the condition: in a branch
                from = open;
            }
            for (int i = at - 1; i > from; i--)
            {
                if (t[i].IsOp(";")) break;
                if (t[i].Kind == TokKind.Ident && (t[i].Upper == "AND_THEN" || t[i].Upper == "OR_ELSE")) return false;
                if (from < 0 && t[i].Kind == TokKind.Ident && (t[i].Upper == "THEN" || t[i].Upper == "ELSE" || t[i].Upper == "DO" || t[i].Upper == "OF" || t[i].Upper.StartsWith("END_", StringComparison.Ordinal))) break;
            }
            return true;
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
