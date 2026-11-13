// TwinCAT Semantic Linter (#252) - Phase 3a rule SCAN-SM-001 (rule-catalog.md Phase 3, tasks 3.1). C# 5.
// A state variable (CASE <single variable> OF) gets a value that no CASE label on it handles while no CASE on it has an ELSE:
// in that state no branch runs (the machine stops in it). Evaluated only when every write of the variable is visible in the
// owner's own ST sections and every label is a computable constant.
// Principle (PR #284 / #289 reviews): what cannot be proven -> coverage.rulesSkipped with a reason; never a silent pass, never a guess.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    public static partial class RuleRegistry
    {
        private static void Register3Sm()
        {
            Add("SCAN-SM-001", "State variable is assigned a value that no CASE label handles, and the CASE has no ELSE", "warning", "false", "behavior", "no",
                "Candidates: CASE <identifier> OF where the identifier is a VAR / VAR_STAT / VAR_OUTPUT of the FUNCTION_BLOCK / PROGRAM itself (not a method local) of an integer type or of an ENUM declared in the project. " +
                "Labels: literals, ranges a..b, lists, project ENUM members (qualified or not; members without a value count up from the previous one, the first from 0) and VAR CONSTANT / VAR_GLOBAL CONSTANT names. " +
                "Values: every 'sel :=' in the body, actions, methods and property accessors; each constant value outside every label of every CASE on the variable is reported at its assignment. " +
                "Not reported: any CASE on the variable has ELSE; a value equal to the initial value (explicit, else 0 for an integer; for an ENUM without one the first member, IEC default not verified -> rulesSkipped initial-value-implicit): the designed idle state that code outside the CASE leaves (iStep := 0 without label 0). rulesSkipped <reason>:<variable>: label-not-evaluable (library constant / enum, expression), value-not-evaluable (sel := other, sel := sel + 1, fb(out => sel); constant values are still reported), " +
                "written-elsewhere (VAR_INPUT / VAR_IN_OUT / GVL selector), qualified-access (x.sel anywhere in the project that may be the owner), passed-or-aliased (ADR / REF= / a call argument that may be VAR_IN_OUT / a declaration initialiser), " +
                "inherited-use (the FB is EXTENDS-ed), declared-in-base, selector-unresolved, selector-type-unknown, unanalysed-part / implementation-not-analyzed. " +
                "Known misses: an unhandled initial value, a value reaching the variable through a method parameter, unreachable assignments are still reported. " +
                "Basis: CASE without a matching label and without ELSE executes no branch (IEC 61131-3 CASE semantics; InfoSys CASE page, see rule-catalog).", "high", null);
            RuleRegistry.Get("SCAN-SM-001").Phase = "3";
            RuleRegistry.Get("SCAN-SM-001").Te1200 = "SA0076 (Full, related: missing enumeration constant); SA0075 (Full): CASE without ELSE";
        }
    }

    internal sealed partial class LintRun
    {
        private const string RSm = "SCAN-SM-001";

        private static readonly HashSet<string> Sm3IntTypes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "SINT", "INT", "DINT", "LINT", "USINT", "UINT", "UDINT", "ULINT", "BYTE", "WORD", "DWORD", "LWORD"
        };

        private sealed class Sm3Case
        {
            public ImplUnit U;
            public int Line;
            public bool HasElse;
            public List<List<Token>> Labels = new List<List<Token>>();   // each: tokens of one label element (value or a..b)
        }

        private void RunPhase3Sm()
        {
            if (!Enabled(RSm)) return;
            Ensure3Index();
            foreach (DeclUnit du in declUnits)
            {
                if (du.Path != du.O.ObjectPath || du.Di == null) continue;
                string h = du.Di.HeaderKeyword ?? "";
                if (h != "FUNCTION_BLOCK" && h != "PROGRAM") continue;
                Sm3Owner(du);
            }
        }

        // shared by the Phase 3a rules: the scope index (RunPhase2a) and the '.name' index (RunPhase2b) are only built when a rule
        // of that phase is enabled
        private void Ensure3Index()
        {
            if (declByPath.Count == 0 && pouByName.Count == 0 && gvlList.Count == 0) BuildScopeIndex();
            if (dotNames == null) BuildDotNames();
            if (derivedBases == null)
            {
                derivedBases = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (KeyValuePair<string, List<string>> kv in fbExtends) foreach (string b in kv.Value) derivedBases.Add(LastSegment(b));
            }
        }

        private void Sm3Skip(DeclUnit du, string reason, string name)
        {
            rulesSkipped.Add(Cov(RSm, du.O.Rel, du.Path, null, reason + ":" + name));
        }

        private void Sm3Owner(DeclUnit du)
        {
            TcObjectFile o = du.O;
            List<ImplUnit> secs = new List<ImplUnit>();
            foreach (ImplUnit u in implUnits) if (u.O == o) secs.Add(u);
            List<DeclUnit> decls = new List<DeclUnit>();
            foreach (DeclUnit d in declUnits) if (d.O == o) decls.Add(d);
            string ownerProblem = null;
            if (du.Di.State.Status != "ok") ownerProblem = "declaration-not-analyzed";
            foreach (DeclUnit d in decls) if (d.Di == null || d.Di.State.Status != "ok") ownerProblem = "member-declaration-not-analyzed";
            foreach (ImplUnit u in secs) if (u.Scan == null || u.Scan.State.Status != "ok" || u.Scan.Lex == null) ownerProblem = "implementation-not-analyzed";

            // CASE statements with a single identifier selector, grouped by selector name
            Dictionary<string, List<Sm3Case>> bySel = new Dictionary<string, List<Sm3Case>>(StringComparer.OrdinalIgnoreCase);
            List<string> order = new List<string>();
            foreach (ImplUnit u in secs)
            {
                if (u.Scan == null || u.Scan.Lex == null) continue;
                List<Token> t = NoPragmas(u.Scan.Lex.Tokens);
                for (int i = 0; i + 2 < t.Count; i++)
                {
                    if (!t[i].Is("CASE")) continue;
                    if (t[i + 1].Kind != TokKind.Ident || StLexer.Keywords.Contains(t[i + 1].Upper) || !t[i + 2].Is("OF")) continue;
                    if (i > 0 && t[i - 1].IsOp(".")) continue;
                    Sm3Case c = Sm3ParseCase(t, i + 3);
                    if (c == null) { Sm3Skip(du, "case-structure-not-understood", t[i + 1].Text); continue; }
                    c.U = u; c.Line = t[i].Line;
                    List<Sm3Case> l;
                    if (!bySel.TryGetValue(t[i + 1].Text, out l)) { l = new List<Sm3Case>(); bySel[t[i + 1].Text] = l; order.Add(t[i + 1].Text); }
                    l.Add(c);
                }
            }
            foreach (string sel in order) Sm3Selector(du, sel, bySel[sel], secs, decls, ownerProblem);
        }

        // labels of one CASE whose tokens start right after OF; null = structure not understood
        private static Sm3Case Sm3ParseCase(List<Token> t, int from)
        {
            Sm3Case c = new Sm3Case();
            int depth = 0;
            bool stmtStart = true;
            for (int k = from; k < t.Count; k++)
            {
                Token x = t[k];
                if (x.Kind == TokKind.EOF) return null;
                if (depth == 0)
                {
                    if (x.Is("END_CASE")) return c;
                    if (x.Is("ELSE")) { c.HasElse = true; stmtStart = true; continue; }
                    if (stmtStart && !Sm3StatementKeyword(x))
                    {
                        // try a label list: tokens up to ':' with no ':=' / ';' / '=>' in between
                        int e = k; bool label = false;
                        for (; e < t.Count; e++)
                        {
                            if (t[e].IsOp(":")) { label = true; break; }
                            if (t[e].IsOp(":=") || t[e].IsOp(";") || t[e].IsOp("=>") || t[e].Kind == TokKind.EOF || (t[e].Kind == TokKind.Ident && StLexer.Keywords.Contains(t[e].Upper) && !t[e].Is("OR") && !t[e].Is("AND") && !t[e].Is("XOR") && !t[e].Is("MOD") && !t[e].Is("NOT"))) break;
                        }
                        if (label && !c.HasElse)
                        {
                            List<Token> cur = new List<Token>();
                            int pd = 0;
                            for (int q = k; q < e; q++)
                            {
                                if (t[q].IsOp("(")) pd++; else if (t[q].IsOp(")")) pd--;
                                if (pd == 0 && t[q].IsOp(",")) { if (cur.Count == 0) return null; c.Labels.Add(cur); cur = new List<Token>(); continue; }
                                cur.Add(t[q]);
                            }
                            if (cur.Count == 0) return null;
                            c.Labels.Add(cur);
                            k = e; stmtStart = true;
                            continue;
                        }
                    }
                }
                stmtStart = false;
                if (x.Is("IF") || x.Is("CASE") || x.Is("FOR") || x.Is("WHILE") || x.Is("REPEAT")) depth++;
                else if (x.Is("END_IF") || x.Is("END_CASE") || x.Is("END_FOR") || x.Is("END_WHILE") || x.Is("END_REPEAT")) { depth--; if (depth < 0) return null; if (depth == 0) { stmtStart = true; continue; } }
                if (depth == 0 && x.IsOp(";")) stmtStart = true;
            }
            return null;
        }

        private static bool Sm3StatementKeyword(Token x)
        {
            return x.Kind == TokKind.Ident && StLexer.Keywords.Contains(x.Upper) && !x.Is("THIS") && !x.Is("SUPER");
        }

        private void Sm3Selector(DeclUnit du, string sel, List<Sm3Case> cases, List<ImplUnit> secs, List<DeclUnit> decls, string ownerProblem)
        {
            // the selector must be the owner's own VAR / VAR_STAT / VAR_OUTPUT (resolved from the body scope)
            Scope bodyScope = null;
            foreach (ImplUnit u in secs) if (u.Path == du.Path) bodyScope = ScopeOf(u);
            VarRef own = FindIn(du.Di, sel, null);
            if (own == null)
            {
                // a method local / base member / GVL / unresolved name used as selector
                Scope sc0 = ScopeOf(cases[0].U);
                VarRef r0 = Resolve(sc0, sel);
                if (r0 == null) { Sm3Skip(du, "selector-unresolved", sel); return; }
                if (r0.DeclScope != null && r0.DeclScope.Gvl != null) { Sm3Skip(du, "written-elsewhere", sel); return; }
                if (r0.Block != null && r0.Block.Kind == "VAR_GLOBAL") { Sm3Skip(du, "written-elsewhere", sel); return; }
                foreach (DeclInfo b in sc0.Bases) if (FindIn(b, sel, null) != null) { Sm3Skip(du, "declared-in-base", sel); return; }
                return;   // a method / accessor local (re-initialised on every call): not a state variable, not a candidate
            }
            // every CASE on the name must see the owner's variable (not a local of the same name)
            List<Sm3Case> mine = new List<Sm3Case>();
            foreach (Sm3Case c in cases)
            {
                Scope sc = ScopeOf(c.U);
                if (sc.LocalUnknown) { Sm3Skip(du, "unanalysed-part", sel); return; }
                VarRef loc = sc.Local == du.Di ? null : FindIn(sc.Local, sel, null);
                if (loc == null) mine.Add(c);
            }
            if (mine.Count == 0) return;
            string kind = own.Block == null ? "" : own.Block.Kind;
            if (kind == "VAR_INPUT" || kind == "VAR_IN_OUT") { Sm3Skip(du, "written-elsewhere", sel); return; }
            if (kind != "VAR" && kind != "VAR_STAT" && kind != "VAR_OUTPUT") return;
            if (own.Constant) return;
            if (ownerProblem != null) { Sm3Skip(du, ownerProblem, sel); return; }
            if (derivedBases.Contains(du.O.Name)) { Sm3Skip(du, "inherited-use", sel); return; }
            HashSet<string> dn;
            if (dotNames.TryGetValue(sel, out dn) && QualifiedMayBeOwn(sel, du.O.Name)) { Sm3Skip(du, "qualified-access", sel); return; }
            foreach (Uncertain un in uncertain)
                if ((un.Idents == null && string.Equals(un.Owner, du.O.Name, StringComparison.OrdinalIgnoreCase)) || (un.Idents != null && un.Idents.Contains(sel))) { Sm3Skip(du, "unanalysed-part", sel); return; }

            // selector type: integer or a project ENUM
            string tt = (own.TypeText ?? "").Trim();
            TypeDef en = null;
            if (!Sm3IntTypes.Contains(tt))
            {
                en = Sm3Enum(tt);
                if (en == null) { Sm3Skip(du, "selector-type-unknown", sel); return; }
            }
            Dictionary<string, decimal> enumVals = null;
            if (en != null)
            {
                enumVals = Sm3EnumValues(en);
                if (enumVals == null) { Sm3Skip(du, "label-not-evaluable", sel); return; }
            }

            // the variable in other declarations of the object (ADR(sel) / REF= / FB_init argument in an initialiser)
            foreach (DeclUnit d in decls)
            {
                if (d.Di.Lex == null) { Sm3Skip(du, "declaration-not-analyzed", sel); return; }
                List<Token> dt = d.Di.Lex.Tokens;
                for (int i = 0; i < dt.Count; i++)
                {
                    if (dt[i].Kind != TokKind.Ident || !string.Equals(dt[i].Text, sel, StringComparison.OrdinalIgnoreCase)) continue;
                    if (i > 0 && dt[i - 1].IsOp(".")) continue;
                    bool declares = i + 1 < dt.Count && (dt[i + 1].IsOp(":") || dt[i + 1].IsOp(",") || dt[i + 1].Is("AT"));
                    if (declares) continue;
                    Sm3Skip(du, "passed-or-aliased", sel); return;
                }
            }

            // labels
            bool anyElse = false;
            List<decimal[]> ranges = new List<decimal[]>();
            foreach (Sm3Case c in mine)
            {
                if (c.HasElse) anyElse = true;
                Scope sc = ScopeOf(c.U);
                foreach (List<Token> lab in c.Labels)
                {
                    int dd = -1;
                    for (int q = 0; q < lab.Count; q++) if (lab[q].IsOp("..")) dd = q;
                    decimal? lo, hi;
                    if (dd < 0) { lo = Sm3Value(sc, lab, 0, lab.Count, en, enumVals); hi = lo; }
                    else { lo = Sm3Value(sc, lab, 0, dd, en, enumVals); hi = Sm3Value(sc, lab, dd + 1, lab.Count, en, enumVals); }
                    if (!lo.HasValue || !hi.HasValue) { if (!anyElse) { Sm3Skip(du, "label-not-evaluable", sel); return; } continue; }
                    ranges.Add(new decimal[] { lo.Value, hi.Value });
                }
            }
            if (anyElse) return;

            // values written to the variable
            List<object[]> found = new List<object[]>();   // { ImplUnit (null = declaration), line, col, value text, decimal value }
            bool notEvaluable = false;
            if (!string.IsNullOrEmpty(own.V.InitText))
            {
                LexResult lx = StLexer.Lex(own.V.InitText);
                List<Token> it = lx.Error == null ? NoPragmas(lx.Tokens) : null;
                decimal? v = it == null ? null : Sm3Value(bodyScope ?? ScopeOf(cases[0].U), it, 0, it.Count - 1, en, enumVals);
                if (v.HasValue) found.Add(new object[] { null, own.V.Line, own.V.Col, own.V.InitText.Trim(), v.Value });
                else notEvaluable = true;
            }
            foreach (ImplUnit u in secs)
            {
                Scope sc = ScopeOf(u);
                if (u.Path != du.Path)
                {
                    if (sc.LocalUnknown) { Sm3Skip(du, "unanalysed-part", sel); return; }
                    if (sc.Local != du.Di && FindIn(sc.Local, sel, null) != null) continue;   // a local of the same name
                }
                List<Token> t = NoPragmas(u.Scan.Lex.Tokens);
                for (int i = 0; i < t.Count; i++)
                {
                    if (t[i].Kind != TokKind.Ident || !string.Equals(t[i].Text, sel, StringComparison.OrdinalIgnoreCase)) continue;
                    int start = i;
                    if (i > 0 && t[i - 1].IsOp("."))
                    {
                        if (i >= 3 && t[i - 2].IsOp("^") && t[i - 3].Is("THIS")) start = i - 3;
                        else continue;   // other.sel: a member of something else (dotNames covers the owner's)
                    }
                    Token prev = start > 0 ? t[start - 1] : null;
                    Token nx = i + 1 < t.Count ? t[i + 1] : null;
                    if (nx != null && nx.IsOp(":=") && prev != null && (prev.IsOp("(") || prev.IsOp(",")) && Sm3InCall(t, start)) continue;   // formal parameter of a call
                    if (nx != null && nx.IsOp(":="))
                    {
                        int e = StatementEnd(t, i + 2);
                        decimal? v = Sm3Value(sc, t, i + 2, e, en, enumVals);
                        if (v.HasValue)
                        {
                            List<string> parts = new List<string>();
                            for (int q = i + 2; q < e && q < t.Count; q++) parts.Add(t[q].Text);
                            found.Add(new object[] { u, t[start].Line, t[start].Col, string.Join(" ", parts.ToArray()), v.Value });
                        }
                        else notEvaluable = true;
                        continue;
                    }
                    if (prev != null && prev.IsOp("=>")) { notEvaluable = true; continue; }
                    if (prev != null && prev.IsOp("REF=")) { Sm3Skip(du, "passed-or-aliased", sel); return; }
                    if (nx != null && nx.IsOp("REF=")) continue;
                    // a whole call argument (ADR(sel), F(sel), F(x := sel)): may be VAR_IN_OUT / an address
                    if (prev != null && (prev.IsOp("(") || prev.IsOp(",") || prev.IsOp(":=")) && nx != null && (nx.IsOp(")") || nx.IsOp(",")) && Sm3InCall(t, start))
                    { Sm3Skip(du, "passed-or-aliased", sel); return; }
                }
            }
            if (notEvaluable) Sm3Skip(du, "value-not-evaluable", sel);

            // the initial value is the state the program starts in: a value equal to it is the designed idle state that code outside
            // the CASE leaves (iStep := 0 with no label 0), not a lost state. Implicit initial value: 0 for an integer; for an ENUM the
            // first member (IEC 61131-3 default of an enumerated type; not verified on InfoSys) -> such a value is recorded, not reported
            decimal? idle = null; bool idleImplicitEnum = false;
            if (string.IsNullOrEmpty(own.V.InitText)) { if (en == null) idle = 0; else if (en.EnumMembers.Count > 0) { idle = enumVals[en.EnumMembers[0].Name]; idleImplicitEnum = true; } }
            else foreach (object[] f in found) if (f[0] == null) idle = (decimal)f[4];
            foreach (object[] f in found)
            {
                decimal v = (decimal)f[4];
                if (f[0] == null) continue;   // the initial value itself defines the idle state
                if (idle.HasValue && v == idle.Value)
                {
                    if (idleImplicitEnum && !Sm3Covered(ranges, v)) Sm3Skip(du, "initial-value-implicit", sel);
                    continue;
                }
                bool handled = false;
                foreach (decimal[] r in ranges) if (v >= Math.Min(r[0], r[1]) && v <= Math.Max(r[0], r[1])) { handled = true; break; }
                if (handled) continue;
                ImplUnit u = (ImplUnit)f[0];
                string where = u == null ? "declaration initial value" : (u.Path + " line " + Inv.S((int)f[1]));
                string caseLines = "";
                foreach (Sm3Case c in mine) caseLines += (caseLines.Length > 0 ? ", " : "") + c.U.Path + " line " + Inv.S(c.Line);
                Emit(RSm, du.O.Rel, u == null ? du.Path : u.Path, u == null ? "declaration" : "implementation", (int)f[1], (int)f[2],
                    "State variable '" + sel + "' gets the value " + (string)f[3] + " (" + where + ") but no CASE " + sel + " OF (" + caseLines + ") has a label for it and none has ELSE: " +
                    "in that state no branch runs and the state machine stays there",
                    sel + " := " + (string)f[3], "Add a CASE label for this value (or an ELSE branch that handles unexpected states), or assign an existing state",
                    "value-not-handled", null, null, false);
            }
        }

        private static bool Sm3Covered(List<decimal[]> ranges, decimal v)
        {
            foreach (decimal[] r in ranges) if (v >= Math.Min(r[0], r[1]) && v <= Math.Max(r[0], r[1])) return true;
            return false;
        }

        // the token at index at is inside the argument list of a call (an '(' preceded by an identifier or ']' / ')')
        private static bool Sm3InCall(List<Token> t, int at)
        {
            int depth = 0;
            for (int k = at - 1; k >= 0; k--)
            {
                if (t[k].IsOp(";")) return false;
                if (t[k].IsOp(")")) depth++;
                else if (t[k].IsOp("("))
                {
                    if (depth > 0) { depth--; continue; }
                    return k > 0 && (t[k - 1].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[k - 1].Upper) || t[k - 1].Is("ADR") || t[k - 1].Is("SIZEOF") || t[k - 1].IsOp("]"));
                }
            }
            return false;
        }

        // project ENUM by type name (optionally namespace-qualified with the project name: not supported -> null)
        private TypeDef Sm3Enum(string typeName)
        {
            if (string.IsNullOrEmpty(typeName) || typeName.IndexOf('.') >= 0 || typeName.IndexOf(' ') >= 0) return null;
            TypeDef hit = null;
            foreach (DeclUnit d in declUnits)
            {
                if (d.Di == null || d.Di.Type == null || d.Di.State.Status != "ok") continue;
                if (!string.Equals(d.Di.Type.Name, typeName, StringComparison.OrdinalIgnoreCase)) continue;
                if (d.Di.Type.Kind != "ENUM") return null;
                if (hit != null) return null;   // two declarations of one name: unknown
                hit = d.Di.Type;
            }
            return hit;
        }

        // member values: explicit value (constant expression of literals / earlier members), else previous + 1, the first 0
        private Dictionary<string, decimal> Sm3EnumValues(TypeDef en)
        {
            Dictionary<string, decimal> vals = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
            decimal next = 0;
            Scope none = new Scope(); none.LocalUnknown = true; none.PouUnknown = true;
            foreach (EnumMember m in en.EnumMembers)
            {
                decimal v = next;
                if (!string.IsNullOrEmpty(m.ValueText))
                {
                    LexResult lx = StLexer.Lex(m.ValueText);
                    if (lx.Error != null) return null;
                    List<Token> t = NoPragmas(lx.Tokens);
                    decimal? x = null;
                    if (t.Count == 2 && t[0].Kind == TokKind.Ident && vals.ContainsKey(t[0].Text)) x = vals[t[0].Text];
                    else x = new ConstEval(this, none, t, 0, t.Count - 1, null, 0, true, 0).Run();
                    if (!x.HasValue) return null;
                    v = x.Value;
                }
                if (vals.ContainsKey(m.Name)) return null;
                vals[m.Name] = v;
                next = v + 1;
            }
            return vals.Count == 0 ? null : vals;
        }

        // constant value of t[from..to) (to exclusive): an enum member of the selector type (E.M / M), else a constant expression
        private decimal? Sm3Value(Scope sc, List<Token> t, int from, int to, TypeDef en, Dictionary<string, decimal> enumVals)
        {
            if (to > t.Count) to = t.Count;
            while (to > from && t[to - 1].Kind == TokKind.EOF) to--;
            if (to <= from) return null;
            if (en != null)
            {
                if (to - from == 3 && t[from].Kind == TokKind.Ident && t[from + 1].IsOp(".") && t[from + 2].Kind == TokKind.Ident
                    && string.Equals(t[from].Text, en.Name, StringComparison.OrdinalIgnoreCase) && enumVals.ContainsKey(t[from + 2].Text))
                    return enumVals[t[from + 2].Text];
                if (to - from == 1 && t[from].Kind == TokKind.Ident && enumVals.ContainsKey(t[from].Text) && Resolve(sc, t[from].Text) == null)
                    return enumVals[t[from].Text];
                // E_Other.X or a computed value of an enum: only a literal / constant number is accepted below
            }
            return new ConstEval(this, sc, t, from, to, null, 0, true, 0).Run();
        }
    }
}
