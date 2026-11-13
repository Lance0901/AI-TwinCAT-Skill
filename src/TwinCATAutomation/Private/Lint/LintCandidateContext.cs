// TwinCAT Semantic Linter (#252) - LintCandidate on a project: names the rules depend on must resolve (PR #284 review S2).
// A candidate that uses a name the overlaid project cannot resolve (not declared anywhere, or declared in an object
// that cannot be read) must not pass: the rule that needed the name could not judge. C# 5.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    internal sealed partial class LintRun
    {
        // Only names in the positions the Phase 2a rules evaluate: FOR headers, WHILE / UNTIL conditions, array names and
        // index expressions, divisors (after '/', MOD, DIV( / MOD( ). A library name elsewhere (MC_MoveAbsolute(...),
        // AXIS_REF) does not make a normal candidate incomplete (review S2: "library identifiers do not count").
        private void FindOverlayContextNeeds()
        {
            HashSet<string> used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<Token> t = StLexer.Lex(opt.CandidateImplementation ?? "").Tokens;
            List<Token> dt = StLexer.Lex(opt.CandidateDeclaration ?? "").Tokens;
            // review 3 S2d: the declaration too - array bounds and the initial values of VAR CONSTANT (the values the rules
            // evaluate); initial values of other variables (library enums, MC_Direction.MC_Shortest_Way) are not needed
            {
                bool init = false, constBlock = false; int br = 0;
                for (int k = 0; k < dt.Count && dt[k].Kind != TokKind.EOF; k++)
                {
                    if (dt[k].Kind == TokKind.Ident && dt[k].Upper.StartsWith("VAR", StringComparison.Ordinal) && dt[k].Upper != "VARIANT")
                    { constBlock = k + 1 < dt.Count && dt[k + 1].Is("CONSTANT"); continue; }
                    if (dt[k].Is("END_VAR")) { constBlock = false; continue; }
                    // only ARRAY[ ... ] bounds; an array initial value [a, b] is not a bound (review 4 blocker 2, S2n)
                    if (dt[k].IsOp("[")) { if (br > 0 || (k > 0 && dt[k - 1].Is("ARRAY"))) br++; continue; }
                    if (dt[k].IsOp("]")) { if (br > 0) br--; continue; }
                    if (dt[k].IsOp(":=")) { init = true; continue; }
                    if (dt[k].IsOp(";")) { init = false; continue; }
                    if (br > 0 || (init && constBlock)) AddIfRoot(dt, k, used);
                }
            }
            int i = 0;
            while (i < t.Count && t[i].Kind != TokKind.EOF)
            {
                Token x = t[i];
                if (x.Is("FOR")) { CollectUntil(t, i + 1, "DO", used); i++; continue; }
                if (x.Is("WHILE")) { CollectUntil(t, i + 1, "DO", used); i++; continue; }
                if (x.Is("UNTIL")) { CollectUntil(t, i + 1, "END_REPEAT", used); i++; continue; }
                if (x.IsOp("["))
                {
                    if (i > 0 && t[i - 1].Kind == TokKind.Ident) AddRoot(t, i - 1, used);
                    int depth = 0, k = i;
                    for (; k < t.Count && t[k].Kind != TokKind.EOF; k++)
                    {
                        if (t[k].IsOp("[")) depth++;
                        else if (t[k].IsOp("]")) { depth--; if (depth == 0) break; }
                        else AddIfRoot(t, k, used);
                    }
                    i++; continue;
                }
                if (x.IsOp("/") || x.Is("MOD"))
                {
                    int k = i + 1;
                    while (k < t.Count && (t[k].IsOp("(") || t[k].IsOp("-"))) k++;
                    if (k < t.Count) AddIfRoot(t, k, used);
                    i++; continue;
                }
                if ((x.Is("DIV") || x.Is("MOD")) && i + 1 < t.Count && t[i + 1].IsOp("("))
                {
                    int depth = 0;
                    for (int k = i + 1; k < t.Count && t[k].Kind != TokKind.EOF; k++)
                    {
                        if (t[k].IsOp("(")) depth++;
                        else if (t[k].IsOp(")")) { depth--; if (depth == 0) break; }
                        else AddIfRoot(t, k, used);
                    }
                }
                i++;
            }
            // review 3 S2f: a rule skipped a candidate section because a type / bound / array was unknown, and some object of
            // the project cannot be read: the unknown part may be declared there
            bool brokenAny = false;
            foreach (TcObjectFile o in objects) if (o.Obj == null || o.Xml == null || !o.Xml.WellFormed) brokenAny = true;
            if (brokenAny)
            {
                foreach (CoverageEntry c in rulesSkipped)
                {
                    if (c.RuleId == null || c.Reason == null || c.ObjectPath == null) continue;
                    if (!(c.RuleId.StartsWith("SCAN-LOOP", StringComparison.Ordinal) || c.RuleId.StartsWith("SCAN-FOR", StringComparison.Ordinal) || c.RuleId.StartsWith("SCAN-ARR", StringComparison.Ordinal) || c.RuleId.StartsWith("SAFETY-", StringComparison.Ordinal))) continue;
                    if (!(string.Equals(c.ObjectPath, candPath, StringComparison.OrdinalIgnoreCase) || c.ObjectPath.StartsWith(candPath + ".", StringComparison.OrdinalIgnoreCase))) continue;
                    string rs = c.Reason.ToLowerInvariant();
                    // review 4 should-fix 1: 'not-constant' only counts when a name the rules read comes from outside the candidate
                    // (a local non-constant FOR bound has nothing to do with a broken object)
                    bool outside = false;
                    HashSet<string> localNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    AddDeclNames(StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? ""), localNames);
                    foreach (string u in used) if (!localNames.Contains(u)) outside = true;
                    if (rs.Contains("unknown") || rs.Contains("unresolved") || (rs.Contains("not-constant") && outside))
                    {
                        foreach (TcObjectFile o in objects) if (o.Obj == null || o.Xml == null || !o.Xml.WellFormed) AddNeed("context-object-broken:" + o.Rel);
                        break;
                    }
                }
            }
            if (used.Count == 0) return;

            HashSet<string> known = KnownNamesForCandidate();
            // review 3 S2a / S2b: GVL.x / E_Enum.x must name a variable of that GVL / a member of that enum
            List<Token> all = new List<Token>(t); all.AddRange(dt);
            for (int k = 0; k + 2 < all.Count; k++)
            {
                if (all[k].Kind != TokKind.Ident || !all[k + 1].IsOp(".") || all[k + 2].Kind != TokKind.Ident) continue;
                if (k > 0 && all[k - 1].IsOp(".")) continue;
                if (!used.Contains(all[k].Text)) continue;
                foreach (TcObjectFile o in objects)
                {
                    if (o.Obj == null || !string.Equals(o.Name, all[k].Text, StringComparison.OrdinalIgnoreCase)) continue;
                    if (o.Obj.Name != "GVL" && o.Obj.Name != "DUT") break;
                    DeclInfo di = DeclOf(o.Obj);
                    if (di == null) break;
                    if (o.Obj.Name == "DUT" && (di.Type == null || di.Type.Kind != "ENUM")) break;
                    HashSet<string> members = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    AddDeclNames(di, members);
                    if (!members.Contains(all[k + 2].Text)) AddNeed("unresolved-identifier:" + all[k].Text + "." + all[k + 2].Text);
                    break;
                }
            }
            // a qualified name (GVL_X.c, E_Mode.Auto) whose object cannot be read: the rule cannot know the value
            foreach (TcObjectFile o in objects)
                if ((o.Obj == null || o.Xml == null || !o.Xml.WellFormed) && used.Contains(o.Name ?? "")) AddNeed("context-object-broken:" + o.Rel);
            List<string> missing = new List<string>();
            foreach (string n in used)
            {
                if (known.Contains(n) || BuiltinNames.Contains(n) || ConversionRx.IsMatch(n) || Elementary.Contains(n)) continue;
                if (string.Equals(n, "THIS", StringComparison.OrdinalIgnoreCase) || string.Equals(n, "SUPER", StringComparison.OrdinalIgnoreCase)) continue;
                if (SystemNames.Contains(n)) continue;
                bool cat = false;
                foreach (CatalogType c in opt.CatalogTypes) if (string.Equals(c.Name, n, StringComparison.OrdinalIgnoreCase)) { cat = true; break; }
                if (cat) continue;
                missing.Add(n);
            }
            // review 4 blocker 2: X.Y with an unknown X is a library enum / GVL as often as a typo (MC_BufferMode.MC_Aborting):
            // the linter has no symbol list of the libraries, so when the project references libraries such a qualifier is
            // recorded (rulesSkipped library-or-unknown:X), not required; an unqualified unknown name stays required
            if (libraryRefs > 0)
            {
                HashSet<string> qualifiers = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                List<Token> allq = new List<Token>(t); allq.AddRange(dt);
                for (int k = 0; k + 1 < allq.Count; k++)
                    if (allq[k].Kind == TokKind.Ident && allq[k + 1].IsOp(".") && !(k > 0 && allq[k - 1].IsOp("."))) qualifiers.Add(allq[k].Text);
                List<string> still = new List<string>();
                foreach (string n in missing)
                {
                    if (qualifiers.Contains(n)) rulesSkipped.Add(Cov(null, candFile, candPath, "implementation", "library-or-unknown:" + n));
                    else still.Add(n);
                }
                missing = still;
            }
            if (missing.Count == 0) return;
            missing.Sort(StringComparer.OrdinalIgnoreCase);
            foreach (string n in missing)
            {
                AddNeed("unresolved-identifier:" + n);
                rulesSkipped.Add(Cov(null, candFile, candPath, "implementation", "unresolved-identifier:" + n));
            }
            // a name that is not found may be declared in an object the linter could not read
            foreach (TcObjectFile o in objects)
                if (o.Obj == null || o.Xml == null || !o.Xml.WellFormed) AddNeed("context-object-broken:" + o.Rel);
        }

        // implicit / system library names every TwinCAT PLC project has (review 3 S2e): the global list
        // TwinCAT_SystemInfoVarList (_TaskInfo, _AppInfo) and the Tc2_System task index functions
        private static readonly HashSet<string> SystemNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "TwinCAT_SystemInfoVarList", "GETCURTASKINDEX", "GETCURTASKINDEXEX" };

        private static void CollectUntil(List<Token> t, int from, string endKeyword, HashSet<string> into)
        {
            for (int k = from; k < t.Count && t[k].Kind != TokKind.EOF && !t[k].Is(endKeyword); k++) AddIfRoot(t, k, into);
        }

        // the first identifier of a designator (not after '.', not a keyword, not a named call parameter)
        private static void AddIfRoot(List<Token> t, int k, HashSet<string> into)
        {
            Token x = t[k];
            if (x.Kind != TokKind.Ident || StLexer.Keywords.Contains(x.Upper)) return;
            if (k > 0 && (t[k - 1].IsOp(".") || t[k - 1].IsOp("#"))) return;
            if (k + 1 < t.Count && (t[k + 1].IsOp(":=") || t[k + 1].IsOp("=>"))) return;
            into.Add(x.Text);
        }

        // designator ending at k (a[ ... with a.b.c before '['): its first identifier
        private static void AddRoot(List<Token> t, int k, HashSet<string> into)
        {
            int j = k;
            while (j - 2 >= 0 && t[j - 1].IsOp(".") && t[j - 2].Kind == TokKind.Ident) j -= 2;
            AddIfRoot(t, j, into);
        }

        // names a candidate can use: its own declaration, its POU (member candidates) and the EXTENDS chain, every object
        // name of the project (POU, DUT incl. enums as E.x, GVL as G.x, interface), every variable of a GVL without
        // qualified_only; JMP labels of the candidate
        private HashSet<string> KnownNamesForCandidate()
        {
            HashSet<string> k = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string[] seg = candPath.Split('.');
            k.Add(seg[0]);
            if (seg.Length > 1) k.Add(seg[1]);
            AddDeclNames(StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? ""), k);
            List<Token> t = StLexer.Lex(opt.CandidateImplementation ?? "").Tokens;
            for (int i = 0; i + 1 < t.Count; i++)
            {
                if (t[i].Kind != TokKind.Ident) continue;
                if ((t[i + 1].IsOp(":") && (i == 0 || t[i - 1].IsOp(";"))) || (i > 0 && t[i - 1].Is("JMP"))) k.Add(t[i].Text);
            }
            foreach (TcObjectFile o in objects) if (!string.IsNullOrEmpty(o.Name)) k.Add(o.Name);
            HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            Queue<string> pous = new Queue<string>();
            pous.Enqueue(seg[0]);
            if (seg.Length > 1)
            {
                // the declaration of the candidate's POU itself may extend another FB
                DeclInfo own = StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? "");
                foreach (string e in own.Extends) pous.Enqueue(e);
            }
            else foreach (string e in StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? "").Extends) pous.Enqueue(e);
            // declarations are read from the (overlaid) XML of every object: objects outside the candidate scope are not
            // analysed, so declUnits does not have them
            while (pous.Count > 0)
            {
                string p = pous.Dequeue();
                if (!seen.Add(p)) continue;
                foreach (TcObjectFile o in objects)
                {
                    if (o.Obj == null || !string.Equals(o.Name, p, StringComparison.OrdinalIgnoreCase)) continue;
                    DeclInfo di = DeclOf(o.Obj);
                    if (di != null) { AddDeclNames(di, k); foreach (string e in di.Extends) pous.Enqueue(e); }
                    // methods / actions / properties of the POU are callable by name inside it
                    foreach (XElem c in o.Obj.Children) { string n = c.Attr("Name"); if (!string.IsNullOrEmpty(n)) k.Add(n); }
                }
            }
            foreach (TcObjectFile o in objects)
            {
                if (o.Obj == null || o.Obj.Name != "GVL") continue;
                DeclInfo di = DeclOf(o.Obj);
                if (di == null) continue;
                bool qualified = false;
                foreach (string a in di.Attributes) if (a.IndexOf("qualified_only", StringComparison.OrdinalIgnoreCase) >= 0) qualified = true;
                if (!qualified) AddDeclNames(di, k);
            }
            return k;
        }

        private static DeclInfo DeclOf(XElem obj)
        {
            XElem d = obj.Child("Declaration");
            return d == null ? null : StAnalyzer.ParseDeclaration(d.InnerText());
        }

        private static void AddDeclNames(DeclInfo di, HashSet<string> into)
        {
            foreach (VarBlock b in di.VarBlocks) foreach (VarDecl v in b.Vars) foreach (string n in v.Names) into.Add(n);
            if (di.Type != null)
            {
                foreach (VarDecl v in di.Type.Members) foreach (string n in v.Names) into.Add(n);
                foreach (EnumMember m in di.Type.EnumMembers) into.Add(m.Name);
            }
            if (!string.IsNullOrEmpty(di.Name)) into.Add(di.Name);
        }
    }
}
