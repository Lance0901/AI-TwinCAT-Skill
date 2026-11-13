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
            if (string.IsNullOrEmpty(opt.CandidateImplementation)) return;
            List<Token> t = StLexer.Lex(opt.CandidateImplementation).Tokens;
            HashSet<string> used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
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
            if (used.Count == 0) return;

            HashSet<string> known = KnownNamesForCandidate();
            // a qualified name (GVL_X.c, E_Mode.Auto) whose object cannot be read: the rule cannot know the value
            foreach (TcObjectFile o in objects)
                if ((o.Obj == null || o.Xml == null || !o.Xml.WellFormed) && used.Contains(o.Name ?? "")) AddNeed("context-object-broken:" + o.Rel);
            List<string> missing = new List<string>();
            foreach (string n in used)
            {
                if (known.Contains(n) || BuiltinNames.Contains(n) || ConversionRx.IsMatch(n) || Elementary.Contains(n)) continue;
                if (string.Equals(n, "THIS", StringComparison.OrdinalIgnoreCase) || string.Equals(n, "SUPER", StringComparison.OrdinalIgnoreCase)) continue;
                bool cat = false;
                foreach (CatalogType c in opt.CatalogTypes) if (string.Equals(c.Name, n, StringComparison.OrdinalIgnoreCase)) { cat = true; break; }
                if (cat) continue;
                missing.Add(n);
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
