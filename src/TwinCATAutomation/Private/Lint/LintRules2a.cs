// TwinCAT Semantic Linter (#252) - Phase 2a rules: SCAN-LOOP-001, SCAN-FOR-001, SCAN-ARR-001, SAFETY-ARR-001,
// SAFETY-DIV-001 (rule-catalog.md section 3). C# 5. Local analysis of one ST section with the declarations of
// the section, its POU and the project's GVL / constants; no general data flow (design.md Non-Goals).
// Whatever cannot be decided from the text (a bound that is not a constant, an array declared elsewhere,
// a counter written in the body) is not evaluated and recorded in coverage.rulesSkipped - never guessed.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;
    using System.Globalization;
    using System.Text;

    internal sealed partial class LintRun
    {
        // one ST implementation section that was scanned (excluded sections never get here)
        private sealed class ImplUnit
        {
            public TcObjectFile O;
            public string Path;        // object path (FB_X, FB_X.M_Run, FB_X.P.Get)
            public ScanResult Scan;    // Scan.State.Status: ok / not-analyzed / unsupported / parse-failed
            public bool Joined;        // several <ST> elements joined: line numbers unreliable
        }

        private readonly List<ImplUnit> implUnits = new List<ImplUnit>();

        private void OnImplementation(TcObjectFile o, string path, ScanResult sr, bool joined)
        {
            ImplUnit u = new ImplUnit(); u.O = o; u.Path = path; u.Scan = sr; u.Joined = joined;
            implUnits.Add(u);
        }

        private const string RLoop = "SCAN-LOOP-001";
        private const string RFor = "SCAN-FOR-001";
        private const string RArr = "SCAN-ARR-001";
        private const string RCArr = "SAFETY-ARR-001";
        private const string RDiv = "SAFETY-DIV-001";
        private static readonly string[] Rules2a = { RLoop, RFor, RArr, RCArr, RDiv };

        // ================================================================ entry
        private void RunPhase2a()
        {
            bool any = false;
            foreach (string id in Rules2a) if (Enabled(id)) any = true;
            if (!any) return;
            BuildScopeIndex();
            foreach (ImplUnit u in implUnits)
            {
                if (u.Scan == null) continue;
                if (u.Scan.State.Status != "ok") { SkipSection(u); continue; }
                Section2a s = new Section2a(this, u);
                if (!s.BuildBlocks())
                {
                    // the scanner paired the blocks, so this is a linter limitation: skip, never pass silently
                    foreach (string id in Rules2a) Skip2(id, u, "block-structure-not-understood");
                    continue;
                }
                s.CheckLoops();
                s.CheckFor();
                s.CheckArrays();
                s.CheckDivisions();
            }
        }

        // Section not analysed (conditional pragma, unverified syntax, unsupported, parse failure): the rules that
        // could apply (keywords present in the tokens) are recorded; unsupported -> blockingRulesSkipped (as SCAN-TEMPFB-001).
        private void SkipSection(ImplUnit u)
        {
            SectionStatus st = u.Scan.State;
            string reason = "implementation-" + (st.Status == "parse-failed" ? "parse-failed" : (st.Reason ?? st.Status));
            bool loop = true, forl = true, arr = true, div = true;
            if (u.Scan.Lex != null && u.Scan.Lex.Error == null)
            {
                loop = forl = arr = div = false;
                foreach (Token x in u.Scan.Lex.Tokens)
                {
                    if (x.Is("WHILE") || x.Is("REPEAT")) loop = true;
                    else if (x.Is("FOR")) forl = true;
                    else if (x.IsOp("[")) arr = true;
                    else if (x.IsOp("/") || x.Is("MOD") || x.Is("DIV")) div = true;
                }
            }
            List<string> ids = new List<string>();
            if (loop) ids.Add(RLoop);
            if (forl) { ids.Add(RFor); ids.Add(RArr); }
            if (arr) ids.Add(RCArr);
            if (div) ids.Add(RDiv);
            foreach (string id in ids)
            {
                if (st.Status == "unsupported") SkipBlocking(id, u.O.Rel, u.Path, reason);
                else Skip2(id, u, reason);
            }
        }

        private void Skip2(string id, ImplUnit u, string reason)
        {
            if (Enabled(id)) rulesSkipped.Add(Cov(id, u.O.Rel, u.Path, null, reason));
        }

        // ================================================================ declarations visible from a section
        private sealed class VarRef
        {
            public VarDecl V;
            public VarBlock Block;   // null for the return variable of a METHOD / FUNCTION
            public string TypeText;
            public bool Constant;
            public Scope DeclScope;  // where the declaration lives (constants are evaluated there)
        }

        private sealed class GvlInfo
        {
            public string Name;
            public DeclInfo Di;
            public bool QualifiedOnly;
            public bool Ok;
        }

        private sealed class Scope
        {
            public DeclInfo Local;          // METHOD / accessor / POU declaration of the section
            public bool LocalUnknown;
            public DeclInfo Pou;
            public bool PouUnknown;
            public List<DeclInfo> Bases = new List<DeclInfo>();
            public bool BasesUnknown;
            public GvlInfo Gvl;             // set: the scope of a GVL (constants declared there)
        }

        private readonly Dictionary<string, DeclInfo> declByPath = new Dictionary<string, DeclInfo>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, GvlInfo> gvlByName = new Dictionary<string, GvlInfo>(StringComparer.OrdinalIgnoreCase);
        private readonly List<GvlInfo> gvlList = new List<GvlInfo>();
        private readonly Dictionary<string, TcObjectFile> pouByName = new Dictionary<string, TcObjectFile>(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<TcObjectFile, DeclInfo> parsedPou = new Dictionary<TcObjectFile, DeclInfo>();

        private void BuildScopeIndex()
        {
            foreach (DeclUnit d in declUnits) if (!declByPath.ContainsKey(d.Path)) declByPath[d.Path] = d.Di;
            List<TcObjectFile> sorted = new List<TcObjectFile>(objects);
            sorted.Sort(delegate (TcObjectFile a, TcObjectFile b) { return string.CompareOrdinal((a.Rel ?? "").ToLowerInvariant(), (b.Rel ?? "").ToLowerInvariant()); });
            foreach (TcObjectFile o in sorted)
            {
                if (o.Obj == null || string.IsNullOrEmpty(o.Name)) continue;
                if (o.Kind == "POU") { if (!pouByName.ContainsKey(o.Name)) pouByName[o.Name] = o; continue; }
                if (o.Kind != "GVL") continue;
                XElem decl = o.Obj.Child("Declaration");
                GvlInfo g = new GvlInfo(); g.Name = o.Name;
                if (decl != null)
                {
                    g.Di = StAnalyzer.ParseDeclaration(decl.InnerText());
                    g.Ok = g.Di.State.Status == "ok";
                    foreach (string a in g.Di.Attributes) if (a.IndexOf("qualified_only", StringComparison.OrdinalIgnoreCase) >= 0) g.QualifiedOnly = true;
                }
                if (gvlByName.ContainsKey(o.Name)) { gvlByName[o.Name].Ok = false; continue; }   // two GVLs, one name: unknown
                gvlByName[o.Name] = g; gvlList.Add(g);
            }
        }

        private DeclInfo PouDecl(string name)
        {
            DeclInfo di;
            if (declByPath.TryGetValue(name, out di)) return di;
            TcObjectFile o;
            if (!pouByName.TryGetValue(name, out o)) return null;
            if (parsedPou.TryGetValue(o, out di)) return di;
            XElem decl = o.Obj.Child("Declaration");
            di = decl == null ? null : StAnalyzer.ParseDeclaration(decl.InnerText());
            parsedPou[o] = di;
            return di;
        }

        private Scope ScopeOf(ImplUnit u)
        {
            Scope s = new Scope();
            int dot = u.Path.IndexOf('.');
            string top = dot < 0 ? u.Path : u.Path.Substring(0, dot);
            s.Pou = PouDecl(top);
            s.PouUnknown = s.Pou == null || s.Pou.State.Status != "ok";
            if (dot < 0) { s.Local = s.Pou; s.LocalUnknown = s.PouUnknown; }
            else
            {
                DeclInfo di;
                if (declByPath.TryGetValue(u.Path, out di)) { s.Local = di; s.LocalUnknown = di.State.Status != "ok"; }
                else
                {
                    // an Action has no declaration of its own (it uses the POU's variables); anything else: unknown
                    string member = u.Path.Substring(dot + 1);
                    bool action = false;
                    if (u.O.Obj != null)
                        foreach (XElem c in u.O.Obj.Children)
                            if (c.Name == "Action" && string.Equals(c.Attr("Name"), member, StringComparison.OrdinalIgnoreCase)) action = true;
                    s.LocalUnknown = !action;
                }
            }
            if (s.Pou != null)
            {
                HashSet<string> seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                seen.Add(top);
                List<string> todo = new List<string>(s.Pou.Extends);
                while (todo.Count > 0)
                {
                    string b = todo[0]; todo.RemoveAt(0);
                    if (!seen.Add(b)) continue;
                    DeclInfo bd = PouDecl(b);
                    if (bd == null || bd.State.Status != "ok") { s.BasesUnknown = true; break; }   // library base FB: its members are unknown
                    s.Bases.Add(bd);
                    todo.AddRange(bd.Extends);
                }
            }
            return s;
        }

        private static VarRef FindIn(DeclInfo di, string name, Scope declScope)
        {
            if (di == null) return null;
            foreach (VarBlock b in di.VarBlocks)
                foreach (VarDecl v in b.Vars)
                    foreach (string n in v.Names)
                        if (string.Equals(n, name, StringComparison.OrdinalIgnoreCase))
                        {
                            VarRef r = new VarRef(); r.V = v; r.Block = b; r.TypeText = v.TypeText; r.DeclScope = declScope;
                            // only VAR CONSTANT / VAR_GLOBAL CONSTANT are compile-time constants (InfoSys 2529284235 "The constants are
                            // replaced with the initial value when the code is compiled"); VAR_INPUT CONSTANT is a parameter set per instance
                            // (CFC "Edit Parameters", 2532058763) and VAR_IN_OUT CONSTANT a read-only reference (2528771211): their initial
                            // value is a default, not a constant (search-result summaries of those pages, 2026-11-13; not measured)
                            r.Constant = b.Qualifiers.Contains("CONSTANT") && (b.Kind == "VAR" || b.Kind == "VAR_GLOBAL");
                            return r;
                        }
            if (di.Name != null && di.ReturnType != null && string.Equals(di.Name, name, StringComparison.OrdinalIgnoreCase)
                && (di.HeaderKeyword == "METHOD" || di.HeaderKeyword == "FUNCTION"))
            {
                VarRef r = new VarRef(); r.TypeText = di.ReturnType.Trim(); r.DeclScope = declScope;
                return r;
            }
            return null;
        }

        private Scope GvlScope(GvlInfo g)
        {
            Scope s = new Scope(); s.Gvl = g; s.LocalUnknown = false; s.PouUnknown = false;
            return s;
        }

        // name = "x" or "GVL.x". null = not found, or not decidable (a level is unknown, ambiguous GVL name).
        private VarRef Resolve(Scope s, string name)
        {
            int dot = name.IndexOf('.');
            if (dot >= 0)
            {
                string g = name.Substring(0, dot), v = name.Substring(dot + 1);
                if (v.IndexOf('.') >= 0) return null;
                GvlInfo gi;
                if (!gvlByName.TryGetValue(g, out gi) || !gi.Ok) return null;
                return FindIn(gi.Di, v, GvlScope(gi));
            }
            if (s.Gvl != null)
            {
                VarRef own = FindIn(s.Gvl.Di, name, s);
                if (own != null) return own;
            }
            else
            {
                if (s.LocalUnknown) return null;
                VarRef r = FindIn(s.Local, name, s);
                if (r != null) return r;
                if (s.PouUnknown) return null;
                r = FindIn(s.Pou, name, s);
                if (r != null) return r;
                if (s.BasesUnknown) return null;
                foreach (DeclInfo b in s.Bases) { r = FindIn(b, name, s); if (r != null) return r; }
            }
            VarRef found = null;
            foreach (GvlInfo g in gvlList)
            {
                if (g.QualifiedOnly && g != s.Gvl) continue;
                if (!g.Ok) { if (g.Di != null && FindIn(g.Di, name, null) != null) return null; continue; }
                VarRef r = FindIn(g.Di, name, GvlScope(g));
                if (r == null) continue;
                if (found != null) return null;   // two global lists declare the name: not decidable here
                found = r;
            }
            return found;
        }

        private readonly Dictionary<VarDecl, decimal?> constCache = new Dictionary<VarDecl, decimal?>();

        // value of a VAR CONSTANT / VAR_GLOBAL CONSTANT (InfoSys 2529284235: "The constants are replaced with the
        // initial value when the code is compiled."); null = not a constant or not a constant expression
        private decimal? ConstValue(Scope s, string name, int depth, bool intOnly)
        {
            if (depth > 16) return null;
            VarRef r = Resolve(s, name);
            if (r == null || !r.Constant || r.V == null || string.IsNullOrEmpty(r.V.InitText)) return null;
            decimal? v;
            if (constCache.TryGetValue(r.V, out v)) return intOnly && v.HasValue && v.Value != decimal.Truncate(v.Value) ? null : v;
            constCache[r.V] = null;   // cycle guard
            LexResult lx = StLexer.Lex(r.V.InitText);
            if (lx.Error != null || lx.Unknown.Count > 0) return null;
            List<Token> t = NoPragmas(lx.Tokens);
            v = new ConstEval(this, r.DeclScope, t, 0, t.Count - 1, null, 0, false, depth + 1).Run();
            constCache[r.V] = v;
            if (intOnly && v.HasValue && v.Value != decimal.Truncate(v.Value)) return null;
            return v;
        }

        private static List<Token> NoPragmas(List<Token> src)
        {
            List<Token> t = new List<Token>(src.Count);
            foreach (Token x in src) if (x.Kind != TokKind.Pragma) t.Add(x);
            if (t.Count == 0 || t[t.Count - 1].Kind != TokKind.EOF) { Token e = new Token(); e.Kind = TokKind.EOF; e.Text = ""; e.Upper = ""; t.Add(e); }
            return t;
        }

        // ---------------------------------------------------------------- constant expressions
        // integer / real literals (16#FF, 2#..., INT#5, '_'), constants, + - * / MOD, parentheses, unary -.
        private sealed class ConstEval
        {
            private readonly LintRun run; private readonly Scope sc; private readonly List<Token> t;
            private int p; private readonly int end; private readonly string bind; private readonly decimal bindVal;
            private readonly bool intOnly; private readonly int depth; private bool failed;

            public ConstEval(LintRun run, Scope sc, List<Token> t, int from, int to, string bind, decimal bindVal, bool intOnly, int depth)
            {
                this.run = run; this.sc = sc; this.t = t; p = from; end = to; this.bind = bind; this.bindVal = bindVal; this.intOnly = intOnly; this.depth = depth;
            }

            public decimal? Run()
            {
                if (p >= end) return null;
                try
                {
                    decimal v = Expr();
                    if (failed || p != end) return null;
                    return v;
                }
                catch (OverflowException) { return null; }
                catch (DivideByZeroException) { return null; }
            }

            private Token Cur { get { return p < end ? t[p] : null; } }

            private decimal Expr()
            {
                decimal v = Term();
                while (!failed && Cur != null && (Cur.IsOp("+") || Cur.IsOp("-")))
                {
                    bool plus = t[p].IsOp("+"); p++;
                    decimal w = Term();
                    v = plus ? v + w : v - w;
                }
                return v;
            }

            private decimal Term()
            {
                decimal v = Unary();
                while (!failed && Cur != null && (Cur.IsOp("*") || Cur.IsOp("/") || Cur.Is("MOD")))
                {
                    Token op = t[p]; p++;
                    decimal w = Unary();
                    if (failed) return 0;
                    if (op.IsOp("*")) v = v * w;
                    else if (w == 0) { failed = true; return 0; }
                    else if (op.IsOp("/")) v = intOnly || (IsInt(v) && IsInt(w) && intLiteralsOnly) ? decimal.Truncate(v / w) : v / w;
                    else v = v % w;
                }
                return v;
            }

            private bool intLiteralsOnly = true;
            private static bool IsInt(decimal d) { return d == decimal.Truncate(d); }

            private decimal Unary()
            {
                if (Cur != null && Cur.IsOp("-")) { p++; return -Unary(); }
                if (Cur != null && Cur.IsOp("+")) { p++; return Unary(); }
                return Primary();
            }

            private decimal Primary()
            {
                Token x = Cur;
                if (x == null) { failed = true; return 0; }
                if (x.Kind == TokKind.Number || x.Kind == TokKind.TypedLiteral)
                {
                    p++;
                    bool real;
                    decimal? v = ParseLiteral(x.Text, out real);
                    if (!v.HasValue || (real && intOnly)) { failed = true; return 0; }
                    if (real) intLiteralsOnly = false;
                    return v.Value;
                }
                if (x.IsOp("("))
                {
                    p++;
                    decimal v = Expr();
                    if (Cur == null || !Cur.IsOp(")")) { failed = true; return 0; }
                    p++;
                    return v;
                }
                if (x.Kind == TokKind.Ident && !StLexer.Keywords.Contains(x.Upper))
                {
                    p++;
                    string name = x.Text;
                    if (Cur != null && Cur.IsOp(".") && p + 1 < end && t[p + 1].Kind == TokKind.Ident) { name += "." + t[p + 1].Text; p += 2; }
                    if (Cur != null && (Cur.IsOp(".") || Cur.IsOp("(") || Cur.IsOp("[") || Cur.IsOp("^"))) { failed = true; return 0; }
                    if (bind != null && string.Equals(name, bind, StringComparison.OrdinalIgnoreCase)) return bindVal;
                    decimal? v = run.ConstValue(sc, name, depth, intOnly);
                    if (!v.HasValue) { failed = true; return 0; }
                    if (!IsInt(v.Value)) intLiteralsOnly = false;
                    return v.Value;
                }
                failed = true; return 0;
            }
        }

        // IEC literal value (InvariantCulture). real = has a fraction / exponent or a REAL / LREAL prefix.
        private static decimal? ParseLiteral(string text, out bool real)
        {
            real = false;
            string s = text.Replace("_", "");
            int h = s.IndexOf('#');
            if (h >= 0)
            {
                string pre = s.Substring(0, h).ToUpperInvariant(), rest = s.Substring(h + 1);
                int b = pre == "2" ? 2 : pre == "8" ? 8 : pre == "16" ? 16 : 0;
                if (b > 0)
                {
                    if (rest.Length == 0) return null;
                    decimal acc = 0;
                    foreach (char c in rest)
                    {
                        int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : 99;
                        if (d >= b) return null;
                        try { acc = acc * b + d; } catch (OverflowException) { return null; }
                    }
                    return acc;
                }
                if (pre == "REAL" || pre == "LREAL") { bool r2; decimal? v2 = ParseLiteral(rest, out r2); real = true; return v2; }
                if (IntTypes.ContainsKey(pre)) { decimal? v3 = ParseLiteral(rest, out real); return real ? null : v3; }
                return null;   // T#, enum#member, BOOL#...
            }
            if (s.Length == 0 || !(char.IsDigit(s[0]) || s[0] == '-' || s[0] == '+')) return null;
            real = s.IndexOf('.') >= 0 || s.IndexOf('e') >= 0 || s.IndexOf('E') >= 0;
            decimal v;
            if (decimal.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out v)) return v;
            return null;
        }

        // integer types (InfoSys tc3_plc_intro/2529388939.html integer data types)
        private static readonly Dictionary<string, decimal[]> IntTypes = new Dictionary<string, decimal[]>(StringComparer.OrdinalIgnoreCase) {
            { "SINT", new decimal[] { -128m, 127m } }, { "USINT", new decimal[] { 0m, 255m } }, { "BYTE", new decimal[] { 0m, 255m } },
            { "INT", new decimal[] { -32768m, 32767m } }, { "UINT", new decimal[] { 0m, 65535m } }, { "WORD", new decimal[] { 0m, 65535m } },
            { "DINT", new decimal[] { -2147483648m, 2147483647m } }, { "UDINT", new decimal[] { 0m, 4294967295m } }, { "DWORD", new decimal[] { 0m, 4294967295m } },
            { "LINT", new decimal[] { -9223372036854775808m, 9223372036854775807m } }, { "ULINT", new decimal[] { 0m, 18446744073709551615m } },
            { "LWORD", new decimal[] { 0m, 18446744073709551615m } } };

        // ---------------------------------------------------------------- ARRAY declarations
        private sealed class ArrayDecl
        {
            public string Problem;          // null = usable; else rulesSkipped reason
            public List<decimal[]> Dims = new List<decimal[]>();
            public bool Nested;             // ARRAY[..] OF ARRAY[..]: only the first level is evaluated
            public string Text;
        }

        private ArrayDecl ParseArray(VarRef r)
        {
            ArrayDecl a = new ArrayDecl();
            a.Text = r.TypeText ?? "";
            LexResult lx = StLexer.Lex(a.Text);
            if (lx.Error != null) { a.Problem = "array-type-not-understood"; return a; }
            List<Token> t = NoPragmas(lx.Tokens);
            int i = 0;
            if (t[i].Is("REFERENCE") && t[i + 1].Is("TO")) i += 2;
            if (!t[i].Is("ARRAY")) { a.Problem = "not-an-array"; return a; }
            i++;
            if (!t[i].IsOp("[")) { a.Problem = "array-type-not-understood"; return a; }
            i++;
            int close = -1, depth = 0;
            for (int k = i; k < t.Count; k++)
            {
                if (t[k].IsOp("[") || t[k].IsOp("(")) depth++;
                else if (t[k].IsOp(")")) depth--;
                else if (t[k].IsOp("]")) { if (depth == 0) { close = k; break; } depth--; }
            }
            if (close < 0) { a.Problem = "array-type-not-understood"; return a; }
            foreach (int[] dim in SplitTop(t, i, close))
            {
                if (dim[1] - dim[0] == 1 && t[dim[0]].IsOp("*")) { a.Problem = "variable-length-array"; return a; }
                int dd = -1, dep = 0;
                for (int k = dim[0]; k < dim[1]; k++) { if (t[k].IsOp("(")) dep++; else if (t[k].IsOp(")")) dep--; else if (dep == 0 && t[k].IsOp("..")) { dd = k; break; } }
                if (dd < 0) { a.Problem = "array-type-not-understood"; return a; }
                decimal? lo = new ConstEval(this, r.DeclScope, t, dim[0], dd, null, 0, true, 0).Run();
                decimal? hi = new ConstEval(this, r.DeclScope, t, dd + 1, dim[1], null, 0, true, 0).Run();
                if (!lo.HasValue || !hi.HasValue) { a.Problem = "bounds-not-constant"; return a; }
                a.Dims.Add(new decimal[] { lo.Value, hi.Value });
            }
            if (close + 2 < t.Count && t[close + 1].Is("OF") && t[close + 2].Is("ARRAY")) a.Nested = true;
            return a;
        }

        // [from, to) split at ',' outside parentheses / brackets
        private static List<int[]> SplitTop(List<Token> t, int from, int to)
        {
            List<int[]> r = new List<int[]>();
            int s = from, depth = 0;
            for (int k = from; k < to; k++)
            {
                if (t[k].IsOp("(") || t[k].IsOp("[")) depth++;
                else if (t[k].IsOp(")") || t[k].IsOp("]")) depth--;
                else if (depth == 0 && t[k].IsOp(",")) { r.Add(new int[] { s, k }); s = k + 1; }
            }
            r.Add(new int[] { s, to });
            return r;
        }

        private static string Num(decimal d) { return d.ToString(CultureInfo.InvariantCulture); }

        private readonly Dictionary<string, HashSet<string>> propsCache = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);

        // Property names of a POU / interface and its EXTENDS chain (Property child elements of the project files), upper case
        private HashSet<string> PropsOf(string name)
        {
            HashSet<string> r;
            if (propsCache.TryGetValue(name, out r)) return r;
            r = new HashSet<string>(StringComparer.Ordinal);
            propsCache[name] = r;   // cycle guard
            foreach (TcObjectFile o in objects)
            {
                if (o.Obj == null || !string.Equals(o.Name, name, StringComparison.OrdinalIgnoreCase) || (o.Kind != "POU" && o.Kind != "Itf")) continue;
                foreach (XElem c in o.Obj.Children) if (c.Name == "Property" && !string.IsNullOrEmpty(c.Attr("Name"))) r.Add(c.Attr("Name").ToUpperInvariant());
            }
            DeclInfo di = PouDecl(name);
            if (di != null) foreach (string b in di.Extends) r.UnionWith(PropsOf(b));
            return r;
        }

        private HashSet<string> writtenAll;
        private HashSet<string> unreadTops;
        private Dictionary<string, HashSet<string>> writtenByTop;

        // name written in an analysed ST section of its POU (of any POU for a PROGRAM: PRG.x can be written from outside),
        // or the POU has a section the linter could not read
        private bool WrittenSomewhere(string upperName, string top)
        {
            if (writtenAll == null)
            {
                writtenAll = new HashSet<string>(StringComparer.Ordinal);
                unreadTops = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                writtenByTop = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
                foreach (ImplUnit x in implUnits)
                {
                    int dot = x.Path.IndexOf('.');
                    string tp = dot < 0 ? x.Path : x.Path.Substring(0, dot);
                    if (x.Scan == null || x.Scan.State.Status != "ok" || x.Scan.Lex == null) { unreadTops.Add(tp); continue; }
                    Writes w = new Section2a(this, x).AllWrites();
                    writtenAll.UnionWith(w.Names); writtenAll.UnionWith(w.CallArgs);
                    HashSet<string> own;
                    if (!writtenByTop.TryGetValue(tp, out own)) { own = new HashSet<string>(StringComparer.Ordinal); writtenByTop[tp] = own; }
                    own.UnionWith(w.Names); own.UnionWith(w.CallArgs);
                    if (w.Deref) unreadTops.Add(tp);
                }
                foreach (CoverageEntry c in notAnalyzed) if (c.ObjectPath != null) { int dot = c.ObjectPath.IndexOf('.'); unreadTops.Add(dot < 0 ? c.ObjectPath : c.ObjectPath.Substring(0, dot)); }
            }
            if (unreadTops.Contains(top)) return true;
            HashSet<string> mine;
            if (writtenByTop.TryGetValue(top, out mine) && mine.Contains(upperName)) return true;
            DeclInfo pd = PouDecl(top);
            return pd == null || pd.HeaderKeyword != "FUNCTION_BLOCK" && pd.HeaderKeyword != "FUNCTION" ? writtenAll.Contains(upperName) : false;
        }

        // ================================================================ one section
        private sealed class Br { public int CondFrom = -1, CondTo = -1, BodyFrom = -1, BodyTo = -1; }

        private sealed class Blk
        {
            public string Kind;   // IF CASE FOR WHILE REPEAT TRY
            public int Open, End = -1;
            public List<Br> Branches = new List<Br>();
            public int Counter = -1, StartFrom, StartTo, EndFrom, EndTo, StepFrom = -1, StepTo = -1;   // FOR header
        }

        private sealed class Writes
        {
            public HashSet<string> Names = new HashSet<string>(StringComparer.Ordinal);    // upper-case identifiers of written designators
            public HashSet<string> CallArgs = new HashSet<string>(StringComparer.Ordinal); // identifiers passed bare to a call (may be VAR_IN_OUT / ADR)
            public List<string> Roots = new List<string>();                                // first identifier of each written designator
            public List<List<string>> Paths = new List<List<string>>();                    // full written designators (Section2a.ParseDsg components)
            public bool Any, Deref, Calls;
            public string ExitLike;                                                        // EXIT / RETURN / JMP / CONTINUE seen
        }

        private sealed class Section2a
        {
            private readonly LintRun run; private readonly ImplUnit u; private readonly List<Token> t;
            private readonly List<Blk> blocks = new List<Blk>();
            private Scope scope;

            public Section2a(LintRun run, ImplUnit u) { this.run = run; this.u = u; t = NoPragmas(u.Scan.Lex.Tokens); }

            private Scope Sc { get { if (scope == null) scope = run.ScopeOf(u); return scope; } }

            private Diagnostic Emit(string rule, Token at, string message, string evidence, string fix, string variant, string severity, string blockable)
            {
                Diagnostic d = run.Emit(rule, u.O.Rel, u.Path, "implementation", at.Line, at.Col, message, evidence, fix, variant, severity, blockable, false);
                if (d != null && u.Joined) d.LineUnreliable = true;
                return d;
            }

            private void Skip(string rule, string reason) { run.Skip2(rule, u, reason); }

            // ---------------------------------------------------------------- block structure
            public bool BuildBlocks()
            {
                List<Blk> st = new List<Blk>();
                for (int i = 0; i < t.Count; i++)
                {
                    Token x = t[i];
                    if (x.Kind != TokKind.Ident) continue;
                    Blk top = st.Count == 0 ? null : st[st.Count - 1];
                    Br br = top == null || top.Branches.Count == 0 ? null : top.Branches[top.Branches.Count - 1];
                    switch (x.Upper)
                    {
                        case "IF": { Blk b = New("IF", i, st); Br n = new Br(); n.CondFrom = i + 1; b.Branches.Add(n); break; }
                        case "THEN": if (top == null || top.Kind != "IF" || br.BodyFrom >= 0) return false; br.CondTo = i; br.BodyFrom = i + 1; break;
                        case "ELSIF": { if (top == null || top.Kind != "IF") return false; br.BodyTo = i; Br n = new Br(); n.CondFrom = i + 1; top.Branches.Add(n); break; }
                        case "ELSE":
                            if (top != null && top.Kind == "IF") { br.BodyTo = i; Br n = new Br(); n.BodyFrom = i + 1; top.Branches.Add(n); }
                            else if (top == null || top.Kind != "CASE") return false;
                            break;
                        case "CASE": { Blk b = New("CASE", i, st); Br n = new Br(); n.CondFrom = i + 1; b.Branches.Add(n); break; }
                        case "OF": if (top != null && top.Kind == "CASE" && br.BodyFrom < 0) { br.CondTo = i; br.BodyFrom = i + 1; } break;
                        case "FOR": { Blk b = New("FOR", i, st); b.Branches.Add(new Br()); break; }
                        case "WHILE": { Blk b = New("WHILE", i, st); Br n = new Br(); n.CondFrom = i + 1; b.Branches.Add(n); break; }
                        case "DO":
                            if (top == null || br.BodyFrom >= 0) return false;
                            if (top.Kind == "FOR") { if (!ForHeader(top, i)) top.Counter = -1; br.BodyFrom = i + 1; }
                            else if (top.Kind == "WHILE") { br.CondTo = i; br.BodyFrom = i + 1; }
                            else return false;
                            break;
                        case "REPEAT": { Blk b = New("REPEAT", i, st); Br n = new Br(); n.BodyFrom = i + 1; b.Branches.Add(n); break; }
                        case "UNTIL": if (top == null || top.Kind != "REPEAT") return false; br.BodyTo = i; br.CondFrom = i + 1; break;
                        case "__TRY": { Blk b = New("TRY", i, st); Br n = new Br(); n.BodyFrom = i + 1; b.Branches.Add(n); break; }
                        case "END_IF": if (!Close(st, "IF", i)) return false; break;
                        case "END_CASE": if (!Close(st, "CASE", i)) return false; break;
                        case "END_FOR": if (!Close(st, "FOR", i)) return false; break;
                        case "END_WHILE": if (!Close(st, "WHILE", i)) return false; break;
                        case "END_REPEAT":
                            if (top == null || top.Kind != "REPEAT" || br.CondFrom < 0) return false;
                            br.CondTo = i; top.End = i; st.RemoveAt(st.Count - 1); break;
                        case "__ENDTRY": if (!Close(st, "TRY", i)) return false; break;
                    }
                }
                if (st.Count > 0) return false;
                foreach (Blk b in blocks) foreach (Br r in b.Branches) if (r.CondFrom >= 0 && r.CondTo < 0) return false;
                return true;
            }

            private Blk New(string kind, int i, List<Blk> st)
            {
                Blk b = new Blk(); b.Kind = kind; b.Open = i; blocks.Add(b); st.Add(b);
                return b;
            }

            private static bool Close(List<Blk> st, string kind, int i)
            {
                if (st.Count == 0 || st[st.Count - 1].Kind != kind) return false;
                Blk b = st[st.Count - 1];
                Br br = b.Branches[b.Branches.Count - 1];
                if (br.BodyFrom < 0) return false;
                br.BodyTo = i; b.End = i; st.RemoveAt(st.Count - 1);
                return true;
            }

            // FOR <counter> := <start> TO <end> [BY <step>] DO
            private bool ForHeader(Blk b, int doIdx)
            {
                int c = b.Open + 1;
                if (c + 2 >= doIdx || t[c].Kind != TokKind.Ident || StLexer.Keywords.Contains(t[c].Upper) || !t[c + 1].IsOp(":=")) return false;
                int to = -1, by = -1, depth = 0;
                for (int k = c + 2; k < doIdx; k++)
                {
                    if (t[k].IsOp("(") || t[k].IsOp("[")) depth++;
                    else if (t[k].IsOp(")") || t[k].IsOp("]")) depth--;
                    else if (depth == 0 && t[k].Is("TO") && to < 0) to = k;
                    else if (depth == 0 && t[k].Is("BY") && to >= 0) by = k;
                }
                if (to < 0) return false;
                b.Counter = c; b.StartFrom = c + 2; b.StartTo = to; b.EndFrom = to + 1; b.EndTo = by < 0 ? doIdx : by;
                if (by >= 0) { b.StepFrom = by + 1; b.StepTo = doIdx; }
                return true;
            }

            // ---------------------------------------------------------------- helpers
            private bool IsCallParen(int k)
            {
                if (k <= 0 || !t[k].IsOp("(")) return false;
                Token p = t[k - 1];
                if (p.Kind == TokKind.Ident) return !StLexer.Keywords.Contains(p.Upper) || p.Upper == "THIS" || p.Upper == "SUPER";
                return p.IsOp("]") || p.IsOp("^");
            }

            private int MatchForward(int k, string open, string close, int limit)
            {
                int depth = 0;
                for (int j = k; j < limit; j++)
                {
                    if (t[j].IsOp(open)) depth++;
                    else if (t[j].IsOp(close)) { depth--; if (depth == 0) return j; }
                }
                return -1;
            }

            private int MatchBack(int k, string open, string close, int limit)
            {
                int depth = 0;
                for (int j = k; j >= limit; j--)
                {
                    if (t[j].IsOp(close)) depth++;
                    else if (t[j].IsOp(open)) { depth--; if (depth == 0) return j; }
                }
                return -1;
            }

            private Writes WritesIn(int from, int to)
            {
                Writes w = new Writes();
                List<string> parens = new List<string>();   // callee (upper case, "" = unknown) of a call parenthesis, null = not a call
                int loops = 0;                              // FOR / WHILE / REPEAT nested inside the range: EXIT / CONTINUE there act on that loop
                for (int k = from; k < to; k++)
                {
                    Token x = t[k];
                    if (x.IsOp("("))
                    {
                        bool call = IsCallParen(k);
                        string callee = call ? (t[k - 1].Kind == TokKind.Ident ? t[k - 1].Upper : "") : null;
                        parens.Add(callee);
                        if (call && !ValueOnly(callee)) w.Calls = true;   // IEC standard functions / conversions change nothing (review S3)
                        continue;
                    }
                    if (x.IsOp(")")) { if (parens.Count > 0) parens.RemoveAt(parens.Count - 1); continue; }
                    if (x.Kind == TokKind.Ident && (x.Upper == "FOR" || x.Upper == "WHILE" || x.Upper == "REPEAT")) { loops++; continue; }
                    if (x.Kind == TokKind.Ident && (x.Upper == "END_FOR" || x.Upper == "END_WHILE" || x.Upper == "END_REPEAT")) { loops--; continue; }
                    if (x.Kind == TokKind.Ident && (x.Upper == "EXIT" || x.Upper == "RETURN" || x.Upper == "JMP" || x.Upper == "CONTINUE"))
                    {
                        // review B2: EXIT / CONTINUE inside a nested loop do not leave this one; RETURN / JMP always do
                        if ((x.Upper == "EXIT" || x.Upper == "CONTINUE") && loops > 0) continue;
                        if (w.ExitLike == null || x.Upper != "CONTINUE") w.ExitLike = x.Upper;
                        continue;
                    }
                    if (x.Kind == TokKind.Ident && !StLexer.Keywords.Contains(x.Upper) && parens.Count > 0 && parens[parens.Count - 1] != null
                        && !ValueOnly(parens[parens.Count - 1]) && (t[k - 1].IsOp("(") || t[k - 1].IsOp(",")) && (t[k + 1].IsOp(",") || t[k + 1].IsOp(")")))
                        w.CallArgs.Add(x.Upper);
                    if (x.IsOp(":=") && parens.Count > 0 && parens[parens.Count - 1] != null && k >= 2 && t[k - 1].Kind == TokKind.Ident && (t[k - 2].IsOp("(") || t[k - 2].IsOp(",")))
                    {
                        // formal parameter of a call (fb(IN := x)): it names an input of the callee, not a designator of this section;
                        // kept in Names only (a caller writes the input of that POU: WrittenSomewhere / FixedNonZero / counter checks unchanged)
                        w.Names.Add(t[k - 1].Upper);
                        continue;
                    }
                    if (x.IsOp(":=") || x.IsOp("S=") || x.IsOp("R=") || x.IsOp("REF="))
                    {
                        // left-hand designator, read backwards: ident ( . ident | ^ | [ ... ] )*
                        int j = k - 1; string root = null; bool any = false;
                        while (j >= from)
                        {
                            Token y = t[j];
                            // THIS^ / SUPER^ address the own instance (ParseDsg normalises THIS^.x to x): not a pointer write (review 2 of PR #284)
                            if (y.IsOp("^")) { if (!(j - 1 >= from && (t[j - 1].Is("THIS") || t[j - 1].Is("SUPER")))) w.Deref = true; j--; continue; }
                            if (y.IsOp("]")) { j = MatchBack(j, "[", "]", from); if (j < 0) break; j--; continue; }
                            if (y.Kind == TokKind.Ident && (!StLexer.Keywords.Contains(y.Upper) || y.Upper == "THIS" || y.Upper == "SUPER"))
                            {
                                w.Names.Add(y.Upper); root = y.Upper; any = true; j--;
                                if (j >= from && t[j].IsOp(".")) { j--; continue; }
                            }
                            break;
                        }
                        if (any) { w.Any = true; w.Roots.Add(root); w.Paths.Add(ParseDsg(j + 1, k).C); }
                        continue;
                    }
                    if (x.IsOp("=>"))
                    {
                        if (k + 1 < to && t[k + 1].Kind == TokKind.Ident) w.Paths.Add(ParseDsg(k + 1, to).C);
                        int j = k + 1; bool first = true;
                        while (j < to)
                        {
                            Token y = t[j];
                            if (y.Kind == TokKind.Ident && !StLexer.Keywords.Contains(y.Upper)) { w.Names.Add(y.Upper); if (first) w.Roots.Add(y.Upper); first = false; w.Any = true; j++; if (j < to && t[j].IsOp(".")) { j++; continue; } }
                            if (j < to && t[j].IsOp("^")) { if (!(t[j - 1].Is("THIS") || t[j - 1].Is("SUPER"))) w.Deref = true; j++; continue; }
                            if (j < to && t[j].IsOp("[")) { int m = MatchForward(j, "[", "]", to); if (m < 0) break; j = m + 1; continue; }
                            break;
                        }
                    }
                }
                return w;
            }

            // ---------------------------------------------------------------- designators (review S2: compare full member paths)
            private sealed class Dsg { public List<string> C = new List<string>(); public int Start, End; public bool Call; }

            // ident ( . ident | ^ | [ index ] )*; THIS^.x / SUPER^.x -> x; an index is "[<constant>]" or "[*]" (variable)
            private Dsg ParseDsg(int k, int limit)
            {
                Dsg d = new Dsg(); d.Start = k; int j = k;
                if (j + 3 < limit && (t[j].Is("THIS") || t[j].Is("SUPER")) && t[j + 1].IsOp("^") && t[j + 2].IsOp(".") && t[j + 3].Kind == TokKind.Ident) j += 3;
                if (j >= limit || t[j].Kind != TokKind.Ident) { d.End = k + 1; return d; }
                d.C.Add(t[j].Upper); j++;
                while (j < limit)
                {
                    if (t[j].IsOp(".") && j + 1 < limit && t[j + 1].Kind == TokKind.Ident) { d.C.Add(t[j + 1].Upper); j += 2; continue; }
                    if (t[j].IsOp("^")) { d.C.Add("^"); j++; continue; }
                    if (t[j].IsOp("["))
                    {
                        int m = MatchForward(j, "[", "]", limit);
                        if (m < 0) break;
                        decimal? v = Eval(j + 1, m, null, 0, true);
                        d.C.Add(v.HasValue ? "[" + Num(v.Value) + "]" : "[*]");
                        j = m + 1; continue;
                    }
                    break;
                }
                d.End = j; d.Call = j < limit && t[j].IsOp("(");
                return d;
            }

            // every designator in [from, to) (identifiers inside an index are designators of their own)
            private List<Dsg> Dsgs(int from, int to)
            {
                List<Dsg> r = new List<Dsg>();
                for (int k = from; k < to; k++)
                {
                    Token x = t[k];
                    if (x.Kind != TokKind.Ident || (StLexer.Keywords.Contains(x.Upper) && x.Upper != "THIS" && x.Upper != "SUPER")) continue;
                    if (k > 0 && (t[k - 1].IsOp(".") || (t[k - 1].IsOp("^") && k > 1 && (t[k - 2].Is("THIS") || t[k - 2].Is("SUPER"))))) continue;
                    Dsg d = ParseDsg(k, to);
                    if (d.C.Count > 0) r.Add(d);
                }
                return r;
            }

            // 0 = different variables, 1 = same (one is a prefix of the other), 2 = maybe the same (variable index)
            private static int Conflict(List<string> a, List<string> b)
            {
                int n = Math.Min(a.Count, b.Count), maybe = 0;
                for (int i = 0; i < n; i++)
                {
                    if (a[i] == b[i]) { if (a[i] == "[*]") maybe = 2; continue; }
                    bool ia = a[i].StartsWith("[", StringComparison.Ordinal), ib = b[i].StartsWith("[", StringComparison.Ordinal);
                    if (ia && ib && (a[i] == "[*]" || b[i] == "[*]")) { maybe = 2; continue; }
                    return 0;
                }
                return maybe == 2 ? 2 : 1;
            }

            // review B3: a property access is a call (Get / Set run code); names / member types the linter cannot resolve are not guessed
            private string Unsure(List<string> c)
            {
                if (c.Count == 0) return null;
                string root = c[0];
                int dot = u.Path.IndexOf('.');
                string top = dot < 0 ? u.Path : u.Path.Substring(0, dot);
                if (run.PropsOf(top).Contains(root)) return "property-access";
                VarRef vr = run.Resolve(Sc, root);
                if (vr == null)
                {
                    if (run.gvlByName.ContainsKey(root))
                        return c.Count >= 2 && !c[1].StartsWith("[", StringComparison.Ordinal) && c[1] != "^" && run.Resolve(Sc, root + "." + c[1]) == null ? "name-unresolved" : null;
                    if (run.pouByName.ContainsKey(root)) return c.Count >= 2 && run.PropsOf(root).Contains(c[1]) ? "property-access" : null;
                    if (run.typeKinds.ContainsKey(root)) return null;   // E_Enum.Member
                    return "name-unresolved";
                }
                if (c.Count < 2) return null;
                if (c[1].StartsWith("[", StringComparison.Ordinal)) return c.Count > 2 ? "member-type-unknown" : null;
                if (c[1] == "^") return null;   // pointer deref: handled as aliasing
                string ty = (vr.TypeText ?? "").Trim();
                if (ty.StartsWith("REFERENCE TO ", StringComparison.OrdinalIgnoreCase)) ty = ty.Substring(13).Trim();
                if (run.pouByName.ContainsKey(ty)) return run.PropsOf(ty).Contains(c[1]) ? "property-access" : null;
                string kind;
                if (run.typeKinds.TryGetValue(ty, out kind)) return kind == "ITF" ? "property-access" : null;
                int ld = ty.LastIndexOf('.');
                if (run.FindCatalog(ld < 0 ? ty : ty.Substring(ld + 1), null) != null) return null;
                return "member-type-unknown";
            }

            // IEC standard functions and type conversions take their arguments by value (InfoSys tc3_plc_intro: operators /
            // type conversion functions), so passing the counter to them does not write it
            private static readonly HashSet<string> ValueFunctions = new HashSet<string>(StringComparer.Ordinal) {
                "ABS", "SQRT", "LN", "LOG", "EXP", "EXPT", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "MIN", "MAX", "LIMIT", "SEL", "MUX",
                "TRUNC", "TRUNC_INT", "SIZEOF", "SHL", "SHR", "ROL", "ROR", "LOWER_BOUND", "UPPER_BOUND" };

            private static bool ValueOnly(string callee)
            {
                if (string.IsNullOrEmpty(callee)) return false;
                if (ValueFunctions.Contains(callee)) return true;
                if (callee.StartsWith("TO_", StringComparison.Ordinal)) return true;
                int i = callee.IndexOf("_TO_", StringComparison.Ordinal);
                return i > 0 && callee.IndexOf('_') == i && callee.LastIndexOf('_') == i + 3;
            }

            private bool Mentions(int from, int to, HashSet<string> names)
            {
                for (int k = Math.Max(0, from); k < to && k < t.Count; k++)
                    if (t[k].Kind == TokKind.Ident && MentionsAt(k, names)) return true;
                return false;
            }

            // the identifier at k, or a member path starting at k (ST.BOK), is in names
            private bool MentionsAt(int k, HashSet<string> names)
            {
                if (names.Contains(t[k].Upper)) return true;
                if (k > 0 && t[k - 1].IsOp(".")) return false;
                StringBuilder p = new StringBuilder(t[k].Upper);
                for (int q = k; q + 2 < t.Count && t[q + 1].IsOp(".") && t[q + 2].Kind == TokKind.Ident; q += 2)
                {
                    p.Append('.').Append(t[q + 2].Upper);
                    if (names.Contains(p.ToString())) return true;
                }
                return false;
            }

            private List<Blk> Enclosing(int idx, int after)
            {
                List<Blk> r = new List<Blk>();
                foreach (Blk b in blocks) if (b.Open > after && b.Open < idx && idx < b.End) r.Add(b);
                r.Sort(delegate (Blk a, Blk b) { return a.Open.CompareTo(b.Open); });
                return r;
            }

            // a condition that decides whether idx runs mentions one of names: IF / ELSIF branches up to the one
            // holding idx (and that condition itself before idx: AND_THEN), CASE selector, WHILE condition
            private bool GuardedBy(int idx, int after, HashSet<string> names)
            {
                foreach (Blk b in Enclosing(idx, after))
                {
                    if (b.Kind == "IF")
                    {
                        for (int j = 0; j < b.Branches.Count; j++)
                        {
                            Br r = b.Branches[j];
                            bool inCond = r.CondFrom >= 0 && idx >= r.CondFrom && idx < r.CondTo;
                            bool inBody = idx >= r.BodyFrom && idx < r.BodyTo;
                            if (r.CondFrom >= 0 && Mentions(r.CondFrom, inCond ? idx : r.CondTo, names)) return true;
                            if (inCond || inBody) break;
                        }
                    }
                    else if (b.Kind == "CASE" || b.Kind == "WHILE")
                    {
                        Br r = b.Branches[0];
                        if (Mentions(r.CondFrom, Math.Min(r.CondTo, idx), names)) return true;
                    }
                }
                return false;
            }

            private string Text(int from, int to)
            {
                StringBuilder sb = new StringBuilder();
                for (int k = Math.Max(0, from); k < to && k < t.Count; k++)
                {
                    if (t[k].Kind == TokKind.EOF) break;
                    string x = t[k].Text;
                    if (sb.Length > 0)
                    {
                        string prev = t[k - 1].Text;
                        bool noBefore = x == "." || x == ")" || x == "]" || x == "," || x == ";" || x == "^" || x == "[" || (x == "(" && IsCallParen(k));
                        bool noAfter = prev == "." || prev == "(" || prev == "[" || prev == "^" && x != ":=";
                        if (!noBefore && !noAfter) sb.Append(' ');
                    }
                    sb.Append(x);
                    if (sb.Length > 160) { sb.Append(" ..."); break; }
                }
                return sb.ToString();
            }

            private decimal? Eval(int from, int to, string bind, decimal bindVal, bool intOnly)
            {
                return new ConstEval(run, Sc, t, from, to, bind, bindVal, intOnly, 0).Run();
            }

            // ================================================================ SCAN-LOOP-001
            public void CheckLoops()
            {
                if (!run.Enabled(RLoop)) return;
                foreach (Blk b in blocks)
                {
                    if (b.Kind != "WHILE" && b.Kind != "REPEAT") continue;
                    Br r = b.Branches[0];
                    int cf = r.CondFrom, ct = r.CondTo;
                    while (ct > cf && t[ct - 1].IsOp(";")) ct--;
                    if (ct <= cf) continue;
                    Writes body = WritesIn(r.BodyFrom, r.BodyTo);
                    if (body.ExitLike != null && body.ExitLike != "CONTINUE") continue;   // EXIT / RETURN / JMP can leave the loop
                    HashSet<string> condNames = new HashSet<string>(StringComparer.Ordinal);
                    bool condCall = false, condDeref = false;
                    List<string> members = new List<string>();
                    List<string> inputs = new List<string>();
                    for (int k = cf; k < ct; k++)
                    {
                        Token x = t[k];
                        if (x.IsOp("(") && IsCallParen(k) && !ValueOnly(t[k - 1].Kind == TokKind.Ident ? t[k - 1].Upper : "")) condCall = true;
                        if (x.IsOp("^")) condDeref = true;
                        if (x.Kind == TokKind.Address) inputs.Add(x.Text);
                        if (x.Kind != TokKind.Ident || (StLexer.Keywords.Contains(x.Upper) && x.Upper != "THIS" && x.Upper != "SUPER")) continue;
                        condNames.Add(x.Upper);
                        if (k + 2 < ct && t[k + 1].IsOp(".") && t[k + 2].Kind == TokKind.Ident && !(k > cf && t[k - 1].IsOp("."))) members.Add(x.Text + "." + t[k + 2].Text);
                    }
                    if (condCall) { Skip(RLoop, "call-in-condition"); continue; }   // a function / method call may return another value: recorded, not silent (second review B1)
                    string what;
                    if (condNames.Count == 0)
                    {
                        // a constant condition: only WHILE TRUE / REPEAT ... UNTIL FALSE never end
                        string lit = Text(cf, ct).Replace("(", "").Replace(")", "").Trim().ToUpperInvariant();
                        if (!(b.Kind == "WHILE" && lit == "TRUE") && !(b.Kind == "REPEAT" && lit == "FALSE")) continue;
                        what = "the condition is the constant " + lit + " and the body has no EXIT / RETURN / JMP";
                    }
                    else
                    {
                        if (body.Deref) { Skip(RLoop, "pointer-write"); continue; }   // a pointer write may change it: recorded, not silent
                        List<Dsg> cds = Dsgs(cf, ct);
                        string unsure = null;
                        foreach (Dsg d in cds) if (unsure == null) unsure = Unsure(d.C);
                        foreach (List<string> pth in body.Paths) if (unsure == null) unsure = Unsure(pth);
                        if (unsure != null) { Skip(RLoop, unsure); continue; }
                        int conflict = 0;
                        foreach (Dsg d in cds) foreach (List<string> pth in body.Paths) { int cf2 = Conflict(d.C, pth); conflict = Math.Max(conflict, cf2 == 1 ? 3 : cf2); }
                        if (conflict == 3)
                        {
                            // review 3 S1 variant: the body writes the condition only from outputs of catalog FBs it calls
                            // (bDone := ton1.Q; ton1(Q => bDone); IF ton1.Q THEN bDone := TRUE) - still a wait inside one cycle
                            HashSet<string> roots3 = new HashSet<string>(StringComparer.Ordinal);
                            foreach (Dsg d in cds) if (d.C.Count > 0) roots3.Add(d.C[0]);
                            BodyCalls bc3 = CallsIn(r.BodyFrom, r.BodyTo);
                            List<string> fed = new List<string>();
                            if (!bc3.Unknown && bc3.Instances.Count > 0 && FedOnlyByFbs(r.BodyFrom, r.BodyTo, roots3, bc3, fed)) FbWaitLoop(b, r, cf, ct, fed);
                            continue;   // the body writes the condition
                        }
                        if (conflict == 2) { Skip(RLoop, "written-element-may-be-the-condition"); continue; }
                        // second review B1: a call in the body only hides the busy-wait when it can reach the condition
                        BodyCalls bc = CallsIn(r.BodyFrom, r.BodyTo);
                        HashSet<string> condRoots = new HashSet<string>(StringComparer.Ordinal);
                        foreach (Dsg d in cds) if (d.C.Count > 0) condRoots.Add(d.C[0]);
                        bool passed = false;
                        foreach (string root in condRoots) if (bc.Passed.Contains(root)) passed = true;
                        if (passed) { Skip(RLoop, "call-in-body"); continue; }   // a condition variable is given to a call (VAR_IN_OUT / ADR / REF= may write it)
                        List<string> waited = new List<string>();
                        bool otherRoots = false;
                        foreach (string root in condRoots) { if (bc.Instances.Contains(root)) waited.Add(root); else otherRoots = true; }
                        if (bc.Unknown && (waited.Count == 0 || otherRoots)) { Skip(RLoop, "call-in-body"); continue; }   // project function / method / action / unknown type: cannot tell
                        if (body.Any && (condDeref || AliasRisk(condNames) || AliasRiskRoots(body.Roots))) { Skip(RLoop, "possible-alias"); continue; }   // REFERENCE / VAR_IN_OUT / pointer may alias
                        if (waited.Count > 0) { FbWaitLoop(b, r, cf, ct, waited); continue; }
                        List<string> cn = new List<string>(condNames); cn.Sort(StringComparer.Ordinal);
                        what = "nothing in the body writes " + string.Join(", ", cn.ToArray()) +
                            (bc.Any ? ", the body calls only function blocks of the type catalog / IEC standard functions that do not receive it" : " and the body has no call") +
                            ", no EXIT / RETURN / JMP and no pointer write";
                        foreach (string n in cn)
                        {
                            VarRef vr = run.Resolve(Sc, n);
                            if (vr != null && vr.V != null && vr.V.Address != null && vr.V.Address.StartsWith("%I", StringComparison.OrdinalIgnoreCase)) inputs.Add(n + " AT " + vr.V.Address);
                        }
                    }
                    string note = "";
                    // second review S4: the order is documented (input update, cycle update, output update); that the input stays the same during the program is inferred from it
                    if (inputs.Count > 0) note += "; the condition reads the input " + string.Join(", ", inputs.ToArray()) + " - the task updates its inputs before the program runs (InfoSys TwinCAT real-time tc3_grundlagen/6828869003.html: input update, then cycle update, then output update), so the loop never sees a new value (inferred from that order, not measured)";
                    // second review N1: only an output of a function block instance is described as one
                    List<string> fbOuts = new List<string>();
                    foreach (string m in members) if (IsFbInstance(m.Substring(0, m.IndexOf('.')))) fbOuts.Add(m);
                    if (fbOuts.Count > 0) note += "; the condition reads the function block output " + string.Join(", ", fbOuts.ToArray()) + " - the block is not called in the loop, so its outputs do not change";
                    string ev = b.Kind == "WHILE" ? Text(b.Open, r.BodyFrom) : "REPEAT ... UNTIL " + Text(cf, ct);
                    Emit(RLoop, t[b.Open],
                        b.Kind + " loop never ends within the cycle: " + what + note + ". The task stays in the loop (InfoSys " +
                        (b.Kind == "WHILE" ? "WHILE 9007201783032715: 'If the Boolean expression never takes the value FALSE, the instructions are repeated continuously, causing a runtime error.'"
                                           : "REPEAT 9007201783038091: 'If the Boolean expression never takes the value TRUE, the instructions are repeated continuously, causing a runtime error.'") + ")",
                        ev, "Do not wait inside one cycle: replace the loop by an IF / state machine step that checks the condition once per cycle", null, null, null);
                }
            }

            private bool AliasRisk(HashSet<string> names)
            {
                foreach (string n in names)
                {
                    VarRef r = run.Resolve(Sc, n);
                    if (r == null) continue;
                    if (IsAliasing(r)) return true;
                }
                return false;
            }

            private bool AliasRiskRoots(List<string> roots)
            {
                foreach (string n in roots)
                {
                    if (n == "THIS" || n == "SUPER") continue;   // own instance: THIS^.x is compared as x by its full path (ParseDsg), no alias
                    VarRef r = run.Resolve(Sc, n);
                    if (r != null && IsAliasing(r)) return true;
                }
                return false;
            }

            private static bool IsAliasing(VarRef r)
            {
                string ty = (r.TypeText ?? "").TrimStart().ToUpperInvariant();
                return (r.Block != null && r.Block.Kind == "VAR_IN_OUT") || ty.StartsWith("REFERENCE", StringComparison.Ordinal) || ty.StartsWith("POINTER", StringComparison.Ordinal);
            }

            // calls of a loop body (second review B1)
            private sealed class BodyCalls
            {
                public bool Any;        // any call other than IEC standard functions / type conversions
                public bool Unknown;    // a call the linter cannot judge: project function / FB, method, action, array element, pointer, unknown type
                public HashSet<string> Instances = new HashSet<string>(StringComparer.Ordinal);   // called instances of a type-catalog FB (upper case)
                public HashSet<string> Passed = new HashSet<string>(StringComparer.Ordinal);      // roots given to a call (any argument), to ADR or as REF= source
            }

            private string CatalogTypeOf(string name)
            {
                VarRef vr = run.Resolve(Sc, name);
                if (vr == null || vr.V == null) return null;
                string ty = (vr.TypeText ?? "").Trim();
                if (ty.IndexOf(' ') >= 0 || ty.IndexOf('[') >= 0) return null;   // REFERENCE TO / POINTER TO / ARRAY: not a plain instance
                int ld = ty.LastIndexOf('.');
                string bare = ld < 0 ? ty : ty.Substring(ld + 1);
                return run.FindCatalog(bare, null) != null ? bare : null;
            }

            private bool IsFbInstance(string name)
            {
                if (CatalogTypeOf(name) != null) return true;
                VarRef vr = run.Resolve(Sc, name);
                if (vr == null || vr.V == null) return false;
                string ty = (vr.TypeText ?? "").Trim();
                DeclInfo pd = run.PouDecl(ty);
                return pd != null && pd.HeaderKeyword == "FUNCTION_BLOCK";
            }

            private BodyCalls CallsIn(int from, int to)
            {
                BodyCalls bc = new BodyCalls();
                for (int k = from; k < to; k++)
                {
                    if (t[k].IsOp("REF=") && k + 1 < to && t[k + 1].Kind == TokKind.Ident) { bc.Passed.Add(t[k + 1].Upper); continue; }
                    if (!t[k].IsOp("(")) continue;
                    bool adr = k > 0 && t[k - 1].Is("ADR");
                    if (!adr && !IsCallParen(k)) continue;
                    Token p = t[k - 1];
                    string callee = p.Kind == TokKind.Ident ? p.Upper : "";
                    if (ValueOnly(callee)) continue;   // arguments by value (InfoSys tc3_plc_intro operators / type conversion)
                    bc.Any = true;
                    bool member = k >= 2 && (t[k - 2].IsOp(".") || t[k - 2].IsOp("^"));
                    if (adr) { }
                    else if (p.Kind == TokKind.Ident && !member && CatalogTypeOf(p.Text) != null) bc.Instances.Add(callee);
                    else bc.Unknown = true;
                    if (member && t[k - 2].IsOp(".") && k >= 3 && t[k - 3].Kind == TokKind.Ident) bc.Passed.Add(t[k - 3].Upper);   // inst.M(): the method may change inst
                    int c = MatchForward(k, "(", ")", to);
                    if (c < 0) { bc.Unknown = true; continue; }
                    for (int q = k + 1; q < c; q++)
                    {
                        Token y = t[q];
                        if (y.Kind != TokKind.Ident || (StLexer.Keywords.Contains(y.Upper) && y.Upper != "THIS" && y.Upper != "SUPER")) continue;
                        if (t[q - 1].IsOp(".")) continue;                                                         // member name
                        if (q + 1 < c && (t[q + 1].IsOp(":=") || t[q + 1].IsOp("=>")) && (t[q - 1].IsOp("(") || t[q - 1].IsOp(","))) continue;   // formal parameter
                        if (q + 1 < c && t[q + 1].IsOp("(")) continue;                                             // nested callee
                        bc.Passed.Add(y.Upper);
                    }
                }
                return bc;
            }

            // every write of a condition root in the body takes its value from a called catalog FB instance: v := inst.Q (only
            // instance members / literals / boolean operators on the right), inst(... Q => v), or a literal inside an IF whose
            // condition reads an instance member
            private bool FedOnlyByFbs(int from, int to, HashSet<string> roots, BodyCalls bc, List<string> fbs)
            {
                int writes = 0;
                for (int k = from; k < to; k++)
                {
                    if (t[k].IsOp(":=") && k - 1 >= from && t[k - 1].Kind == TokKind.Ident && !(k - 2 >= from && (t[k - 2].IsOp(".") || t[k - 2].IsOp("^") || t[k - 2].IsOp("]"))))
                    {
                        if (!roots.Contains(t[k - 1].Upper)) continue;
                        if (k - 2 >= from && t[k - 2].IsOp("(")) continue;   // formal parameter of a call
                        bool comma = k - 2 >= from && t[k - 2].IsOp(",");
                        if (comma) continue;
                        writes++;
                        bool inst = false, literalOnly = true;
                        int q = k + 1;
                        for (; q < to && !t[q].IsOp(";") && !IsStmtKeyword(t[q]); q++)
                        {
                            Token y = t[q];
                            if (y.Kind != TokKind.Ident) continue;
                            if (y.Is("TRUE") || y.Is("FALSE") || y.Is("NOT") || y.Is("AND") || y.Is("OR") || y.Is("XOR") || y.Is("AND_THEN") || y.Is("OR_ELSE")) continue;
                            if (q > 0 && t[q - 1].IsOp(".")) continue;
                            if (bc.Instances.Contains(y.Upper) && q + 1 < to && t[q + 1].IsOp(".")) { inst = true; literalOnly = false; if (!fbs.Contains(y.Upper)) fbs.Add(y.Upper); continue; }
                            return false;   // another variable or call feeds the condition
                        }
                        if (inst) continue;
                        if (!literalOnly) return false;
                        // literal: the enclosing IF must read an instance member
                        string fb = EnclosingIfInstance(from, k, bc);
                        if (fb == null) return false;
                        if (!fbs.Contains(fb)) fbs.Add(fb);
                        continue;
                    }
                    if (t[k].IsOp("=>") && k + 1 < to && t[k + 1].Kind == TokKind.Ident && roots.Contains(t[k + 1].Upper) && !(k + 2 < to && t[k + 2].IsOp(".")))
                    {
                        writes++;
                        int depth = 0, p = k - 1;
                        for (; p >= from; p--)
                        {
                            if (t[p].IsOp(")")) depth++;
                            else if (t[p].IsOp("(")) { if (depth == 0) break; depth--; }
                        }
                        if (p - 1 < from || t[p - 1].Kind != TokKind.Ident || !bc.Instances.Contains(t[p - 1].Upper)) return false;
                        if (!fbs.Contains(t[p - 1].Upper)) fbs.Add(t[p - 1].Upper);
                    }
                }
                return writes > 0 && fbs.Count > 0;
            }

            private string EnclosingIfInstance(int from, int k, BodyCalls bc)
            {
                int then = -1;
                // an ELSE / ELSIF between the write and THEN: the write is not in the branch the instance test opens (review 4 nit 1)
                for (int p = k - 1; p >= from; p--) { if (t[p].Is("THEN")) { then = p; break; } if (t[p].Is("END_IF") || t[p].Is("ELSE") || t[p].Is("ELSIF")) return null; }
                if (then < 0) return null;
                int ifk = -1;
                for (int p = then - 1; p >= from; p--) if (t[p].Is("IF") || t[p].Is("ELSIF")) { ifk = p; break; }
                if (ifk < 0) return null;
                for (int p = ifk + 1; p < then; p++)
                    if (t[p].Kind == TokKind.Ident && bc.Instances.Contains(t[p].Upper) && p + 1 < then && t[p + 1].IsOp(".")) return t[p].Upper;
                return null;
            }

            // second review S1: the condition reads an output of a type-catalog FB instance that the body calls
            private void FbWaitLoop(Blk b, Br r, int cf, int ct, List<string> waited)
            {
                List<string> names = new List<string>();
                foreach (string w in waited)
                {
                    string shown = w;
                    for (int k = cf; k < ct; k++) if (t[k].Kind == TokKind.Ident && t[k].Upper == w) { shown = t[k].Text; break; }
                    names.Add(shown + " : " + CatalogTypeOf(shown));
                }
                string ev = b.Kind == "WHILE" ? Text(b.Open, r.BodyFrom) : "REPEAT ... UNTIL " + Text(cf, ct);
                Emit(RLoop, t[b.Open],
                    b.Kind + " loop waits inside one cycle for the function block " + string.Join(", ", names.ToArray()) + ": the condition reads its output and the body calls it again. " +
                    "Whether repeated calls within one PLC cycle can change that output is not documented: Tc2_MC2 axis data NcToPlc is 'cyclically exchanged between PLC and NC' (InfoSys AXIS_REF tcplclib_tc2_mc2/70132363.html), " +
                    "the TON page only says 'the time in milliseconds is counted up in ET' (tcplclib_tc2_standard/74406539.html) - not verified (tasks 2.10, UmRT). " +
                    "Either the loop never ends (InfoSys WHILE 9007201783032715 / REPEAT 9007201783038091: the instructions are repeated continuously, causing a runtime error) or it holds the task for the whole wait",
                    ev, "Call the block once per cycle and test its output in the next cycle (IF / state machine step), not in a loop", "fb-wait-loop", "warning", "false");
            }

            // ================================================================ SCAN-FOR-001
            private sealed class ForInfo
            {
                public Blk B;
                public string Counter;           // upper-case
                public bool CounterWritten;
                public Writes Body;
                public decimal? Start, End, Step;
            }

            private readonly List<ForInfo> fors = new List<ForInfo>();

            private void AnalyzeFors()
            {
                if (fors.Count > 0) return;
                foreach (Blk b in blocks)
                {
                    if (b.Kind != "FOR") continue;
                    ForInfo f = new ForInfo(); f.B = b;
                    fors.Add(f);
                    if (b.Counter < 0) continue;
                    f.Counter = t[b.Counter].Upper;
                    Br r = b.Branches[0];
                    f.Body = WritesIn(r.BodyFrom, r.BodyTo);
                    f.CounterWritten = f.Body.Names.Contains(f.Counter) || f.Body.CallArgs.Contains(f.Counter);
                    f.Start = Eval(b.StartFrom, b.StartTo, null, 0, true);
                    f.End = Eval(b.EndFrom, b.EndTo, null, 0, true);
                    f.Step = b.StepFrom < 0 ? (decimal?)1m : Eval(b.StepFrom, b.StepTo, null, 0, true);
                }
            }

            public void CheckFor()
            {
                AnalyzeFors();
                if (!run.Enabled(RFor)) return;
                foreach (ForInfo f in fors)
                {
                    Blk b = f.B;
                    if (b.Counter < 0) { Skip(RFor, "for-header-not-understood"); continue; }
                    if (f.CounterWritten) { Skip(RFor, "counter-written-in-body:" + t[b.Counter].Text); continue; }
                    if (!f.Step.HasValue) { Skip(RFor, "step-not-constant"); continue; }
                    string header = Text(b.Open, b.Branches[0].BodyFrom);
                    bool exit = f.Body.ExitLike == "EXIT" || f.Body.ExitLike == "RETURN" || f.Body.ExitLike == "JMP";
                    if (f.Step.Value == 0)
                    {
                        Emit(RFor, t[b.Open], "FOR step BY 0: the counter " + t[b.Counter].Text + " never advances, so the loop cannot reach its end value" +
                            (exit ? " (the body has " + f.Body.ExitLike + ")" : "") + ". The behaviour of BY 0 is not documented (InfoSys FOR 2528280971 only says 'The step size <increment> can have any integer value.'; not measured, tasks 2.10)",
                            header, "Use a non-zero step", "by-zero", null, "pending");
                        continue;
                    }
                    VarRef vr = run.Resolve(Sc, t[b.Counter].Text);
                    if (vr == null) { Skip(RFor, "counter-type-unknown:" + t[b.Counter].Text); continue; }
                    string ty = (vr.TypeText ?? "").Trim();
                    decimal[] range;
                    if (!IntTypes.TryGetValue(ty, out range)) { Skip(RFor, "counter-type-not-integer:" + ty); continue; }
                    if (!f.End.HasValue) { Skip(RFor, "end-not-constant"); continue; }
                    decimal end = f.End.Value, step = f.Step.Value;
                    string variant = null, why = null;
                    if (step > 0 && end >= range[1])
                        why = "the end value " + Num(end) + " is not below the upper bound " + Num(range[1]) + " of " + ty + ": the counter can never exceed it, the last increment overflows";
                    else if (step < 0 && end <= range[0])
                        why = "the end value " + Num(end) + " is not above the lower bound " + Num(range[0]) + " of " + ty + ": the counter can never fall below it, the last decrement overflows";
                    else if (f.Start.HasValue && ((step > 0 && f.Start.Value <= end) || (step < 0 && f.Start.Value >= end)))
                    {
                        decimal last = f.Start.Value + decimal.Truncate((end - f.Start.Value) / step) * step;
                        if ((step > 0 && last + step > range[1]) || (step < 0 && last + step < range[0]))
                        {
                            why = "the last counter value " + Num(last) + " plus the step " + Num(step) + " leaves the range of " + ty + " before the counter passes the end value " + Num(end);
                            variant = "step-overflow";
                        }
                    }
                    if (why == null) continue;
                    string sev = null, blk = null;
                    if (exit) { variant = variant == null ? "exit-in-body" : variant + ",exit-in-body"; sev = "warning"; blk = "false"; }
                    Emit(RFor, t[b.Open], "FOR loop on " + t[b.Counter].Text + " : " + ty + " never ends: " + why +
                        " (InfoSys FOR 2528280971: 'The <end value> must not have the same value as the upper bound of the data type of the counter.'; the compiler only warns C0266, the build succeeds)" +
                        (exit ? "; the body has " + f.Body.ExitLike + ", which may end the loop - check that it always does" : "") +
                        (variant != null && variant.StartsWith("step-overflow", StringComparison.Ordinal) ? "; FOR 2528280971: 'Whenever the <instructions> have been executed, the <counter> is automatically incremented by the step size' and 'The counter is checked before each loop pass', so the increment after the last value leaves the type before the end value is passed (the wrap-around itself is inferred from the step-1 case, not measured)" : ""),
                        header, "Use a counter type with a larger range (e.g. INT / DINT for a BYTE range), or an end value below the type's limit", variant, sev, blk);
                }
            }

            // ================================================================ SCAN-ARR-001 / SAFETY-ARR-001
            private sealed class Access
            {
                public int Bracket;        // index of '['
                public int Close;          // index of ']'
                public Token NameTok;
                public string Name;        // "a" or "GVL.a"; null = not resolvable here (member of a struct, pointer, second index group)
                public string Problem;     // why Name is null
            }

            private List<Access> accesses;

            private List<Access> Accesses()
            {
                if (accesses != null) return accesses;
                accesses = new List<Access>();
                for (int k = 1; k < t.Count; k++)
                {
                    if (!t[k].IsOp("[")) continue;
                    Token p = t[k - 1];
                    Access a = new Access(); a.Bracket = k; a.Close = MatchForward(k, "[", "]", t.Count);
                    if (a.Close < 0) continue;
                    if (p.IsOp("]")) { a.Problem = "nested-array-index"; a.NameTok = p; }
                    else if (p.IsOp("^")) { a.Problem = "array-unknown:pointer"; a.NameTok = p; }
                    else if (p.Kind == TokKind.Ident && !StLexer.Keywords.Contains(p.Upper))
                    {
                        a.NameTok = p;
                        bool member = k >= 2 && t[k - 2].IsOp(".");
                        if (!member) a.Name = p.Text;
                        else if (k >= 3 && t[k - 3].Kind == TokKind.Ident && !(k >= 4 && (t[k - 4].IsOp(".") || t[k - 4].IsOp("^") || t[k - 4].IsOp("]"))) && run.gvlByName.ContainsKey(t[k - 3].Text))
                        { a.Name = t[k - 3].Text + "." + p.Text; a.NameTok = t[k - 3]; }
                        else a.Problem = "array-unknown:member";
                    }
                    else continue;   // array literal [1, 2, 3] or something else that is not an index
                    accesses.Add(a);
                }
                return accesses;
            }

            // second review B2: the counter and every variable assigned before idx in the loop body from an expression that
            // reads one of them (v := <expression with i>, transitive). Simple taint, no value tracking.
            private HashSet<string> Tainted(int bodyFrom, int idx, string counter)
            {
                // review 3: the left side may be a member path (st.bOk := i > 0 -> "ST.BOK", B2e); the assignments are taken in
                // program order, so an unconditional later write from an untainted value removes the taint again (B2b)
                HashSet<string> set = new HashSet<string>(StringComparer.Ordinal); set.Add(counter);
                int depth = 0;
                for (int k = bodyFrom; k < idx; k++)
                {
                    if (t[k].IsOp("(") || t[k].IsOp("[")) { depth++; continue; }
                    if (t[k].IsOp(")") || t[k].IsOp("]")) { depth--; continue; }
                    if (depth != 0 || !t[k].IsOp(":=") || k <= bodyFrom || t[k - 1].Kind != TokKind.Ident || StLexer.Keywords.Contains(t[k - 1].Upper)) continue;
                    int s = k - 1;
                    while (s - 2 >= bodyFrom && t[s - 1].IsOp(".") && t[s - 2].Kind == TokKind.Ident) s -= 2;
                    if (s - 1 >= bodyFrom && (t[s - 1].IsOp(".") || t[s - 1].IsOp("^") || t[s - 1].IsOp("]"))) continue;
                    StringBuilder lp = new StringBuilder();
                    for (int q = s; q < k; q += 2) { if (lp.Length > 0) lp.Append('.'); lp.Append(t[q].Upper); }
                    string lhs = lp.ToString();
                    bool tainted = false;
                    for (int q = k + 1; q < idx && !t[q].IsOp(";") && !IsStmtKeyword(t[q]) && !t[q].Is("TO") && !t[q].Is("BY") && !tainted; q++)
                        if (t[q].Kind == TokKind.Ident && !t[q - 1].IsOp(".") && MentionsAt(q, set)) tainted = true;
                    // review 4 blocker 1: a write inside an IF / CASE whose condition / selector depends on the counter is
                    // control-dependent on it (IF i > 0 THEN bOk := TRUE; ... IF bOk THEN a[i])
                    if (!tainted)
                        foreach (Blk eb in Enclosing(k, bodyFrom - 1))   // a block may open on the first token of the body
                        {
                            if (eb.Kind != "IF" && eb.Kind != "CASE") continue;
                            foreach (Br br in eb.Branches)
                                if (br.CondFrom >= 0 && br.CondFrom < k && Mentions(br.CondFrom, Math.Min(br.CondTo, k), set)) { tainted = true; break; }
                            if (tainted) break;
                        }
                    if (tainted) set.Add(lhs);
                    else if (lhs != counter && set.Contains(lhs) && Enclosing(k, bodyFrom - 1).Count == 0) set.Remove(lhs);
                }
                return set;
            }

            private bool ContainsIdent(int from, int to, string upper)
            {
                for (int k = from; k < to; k++) if (t[k].Kind == TokKind.Ident && t[k].Upper == upper) return true;
                return false;
            }

            // index = counter + / - constants only (the counter once, not inside parentheses, no * / MOD): min / max at the ends
            private bool AffineInCounter(int from, int to, string counter)
            {
                int count = 0, depth = 0;
                for (int k = from; k < to; k++)
                {
                    Token x = t[k];
                    if (x.IsOp("(") || x.IsOp("[")) { depth++; continue; }
                    if (x.IsOp(")") || x.IsOp("]")) { depth--; continue; }
                    if (x.Kind == TokKind.Ident && x.Upper == counter) { if (depth > 0) return false; count++; continue; }
                    if (depth == 0 && (x.IsOp("*") || x.IsOp("/") || x.Is("MOD") || x.IsOp("**"))) return false;
                }
                return count == 1;
            }

            private readonly Dictionary<string, ArrayDecl> arrayCache = new Dictionary<string, ArrayDecl>(StringComparer.OrdinalIgnoreCase);

            private ArrayDecl ArrayOf(string name)
            {
                ArrayDecl a;
                if (arrayCache.TryGetValue(name, out a)) return a;
                VarRef r = run.Resolve(Sc, name);
                if (r == null) { a = new ArrayDecl(); a.Problem = "array-unknown:" + name; }
                else a = run.ParseArray(r);
                arrayCache[name] = a;
                return a;
            }

            public void CheckArrays()
            {
                AnalyzeFors();
                bool scan = run.Enabled(RArr), safety = run.Enabled(RCArr);
                if (!scan && !safety) return;
                HashSet<int> loopDims = new HashSet<int>();   // "[" index * 1000 + dim that a FOR evaluated
                if (scan)
                {
                    foreach (ForInfo f in fors)
                    {
                        Blk b = f.B;
                        if (b.Counter < 0) continue;
                        Br body = b.Branches[0];
                        List<Access> inBody = new List<Access>();
                        foreach (Access a in Accesses()) if (a.Bracket > body.BodyFrom && a.Bracket < body.BodyTo && ContainsIdent(a.Bracket, a.Close, f.Counter)) inBody.Add(a);
                        if (inBody.Count == 0) continue;
                        if (f.CounterWritten) { Skip(RArr, "counter-written-in-body:" + t[b.Counter].Text); continue; }
                        if (!f.Start.HasValue || !f.End.HasValue || !f.Step.HasValue) { Skip(RArr, "loop-bounds-not-constant"); continue; }
                        decimal s = f.Start.Value, e = f.End.Value, st = f.Step.Value;
                        if (st == 0 || (st > 0 && s > e) || (st < 0 && s < e)) continue;   // BY 0 (SCAN-FOR-001) / loop body never runs
                        decimal last = s + decimal.Truncate((e - s) / st) * st;
                        decimal lo = Math.Min(s, last), hi = Math.Max(s, last);
                        HashSet<string> cn = new HashSet<string>(StringComparer.Ordinal); cn.Add(f.Counter);
                        foreach (Access a in inBody)
                        {
                            if (a.Name == null) { Skip(RArr, a.Problem); continue; }
                            ArrayDecl ad = ArrayOf(a.Name);
                            if (ad.Problem != null) { Skip(RArr, ad.Problem); continue; }
                            List<int[]> dims = SplitTop(t, a.Bracket + 1, a.Close);
                            if (dims.Count != ad.Dims.Count) { Skip(RArr, "dimension-count-differs:" + a.Name); continue; }
                            List<string> bad = new List<string>();
                            for (int d = 0; d < dims.Count; d++)
                            {
                                int[] dm = dims[d];
                                if (!ContainsIdent(dm[0], dm[1], f.Counter)) continue;
                                if (!AffineInCounter(dm[0], dm[1], f.Counter)) { Skip(RArr, "index-expression-not-evaluated"); continue; }
                                decimal? v1 = Eval(dm[0], dm[1], t[b.Counter].Text, lo, true), v2 = Eval(dm[0], dm[1], t[b.Counter].Text, hi, true);
                                if (!v1.HasValue || !v2.HasValue) { Skip(RArr, "index-expression-not-evaluated"); continue; }
                                loopDims.Add(a.Bracket * 1000 + d);
                                decimal mn = Math.Min(v1.Value, v2.Value), mx = Math.Max(v1.Value, v2.Value);
                                decimal[] bd = ad.Dims[d];
                                if (mn < bd[0] || mx > bd[1])
                                    bad.Add((dims.Count > 1 ? "dimension " + Inv.S(d + 1) + ": " : "") + "index " + Text(dm[0], dm[1]) + " runs " + Num(mn) + ".." + Num(mx) + ", declared " + Num(bd[0]) + ".." + Num(bd[1]));
                            }
                            if (bad.Count == 0) continue;
                            bool guarded = GuardedBy(a.Bracket, b.Open, Tainted(body.BodyFrom, a.Bracket, f.Counter)) || (f.Body.ExitLike != null);
                            Emit(RArr, a.NameTok, "Array index out of range in the FOR loop on " + t[b.Counter].Text + " (" + Num(s) + " TO " + Num(e) + (st != 1 ? " BY " + Num(st) : "") + "): " + a.Name + "[" + Text(a.Bracket + 1, a.Close) + "]: " +
                                string.Join("; ", bad.ToArray()) + " (" + ad.Text + "). Without the implicit check CheckBounds (InfoSys 2530356875, only present when added to the project) the access is not checked; its runtime effect is not documented (not verified)" +
                                (guarded ? "; the access is inside an IF / CASE / WHILE whose condition tests " + t[b.Counter].Text + " (directly or through a variable computed from it earlier in the body), or the body has EXIT / CONTINUE / RETURN - check that it excludes the out-of-range values" : ""),
                                Text(a.NameTok == null ? a.Bracket : t.IndexOf(a.NameTok), a.Close + 1), "Make the loop bounds match the array bounds (use LOWER_BOUND / UPPER_BOUND or the constants of the declaration)",
                                guarded ? "guarded" : null, guarded ? "warning" : null, guarded ? "false" : null);
                        }
                    }
                }
                if (!safety) return;
                foreach (Access a in Accesses())
                {
                    List<int[]> dims = SplitTop(t, a.Bracket + 1, a.Close);
                    List<decimal?> vals = new List<decimal?>();
                    bool anyConst = false;
                    for (int d = 0; d < dims.Count; d++)
                    {
                        decimal? v = loopDims.Contains(a.Bracket * 1000 + d) ? null : Eval(dims[d][0], dims[d][1], null, 0, true);
                        vals.Add(v);
                        if (v.HasValue) anyConst = true;
                    }
                    if (!anyConst) continue;
                    if (a.Name == null) { Skip(RCArr, a.Problem); continue; }
                    ArrayDecl ad = ArrayOf(a.Name);
                    if (ad.Problem != null) { if (ad.Problem != "not-an-array") Skip(RCArr, ad.Problem); continue; }
                    if (dims.Count != ad.Dims.Count) { Skip(RCArr, "dimension-count-differs:" + a.Name); continue; }
                    List<string> bad = new List<string>();
                    for (int d = 0; d < dims.Count; d++)
                    {
                        if (!vals[d].HasValue) continue;
                        decimal[] bd = ad.Dims[d];
                        if (vals[d].Value < bd[0] || vals[d].Value > bd[1])
                            bad.Add((dims.Count > 1 ? "dimension " + Inv.S(d + 1) + ": " : "") + "index " + Num(vals[d].Value) + " outside " + Num(bd[0]) + ".." + Num(bd[1]));
                    }
                    if (bad.Count == 0) continue;
                    Emit(RCArr, a.NameTok, "Constant array index out of range: " + a.Name + "[" + Text(a.Bracket + 1, a.Close) + "]: " + string.Join("; ", bad.ToArray()) + " (" + ad.Text +
                        "). The compiler rejects it (C0049, measured 2026-11-13; InfoSys 2530356875: 'A consistently faulty array index results in a compiler error.'), this finding only reports it before the write",
                        Text(t.IndexOf(a.NameTok), a.Close + 1), "Use an index inside the declared range", null, null, null);
                }
            }

            // ================================================================ SAFETY-DIV-001
            public void CheckDivisions()
            {
                if (!run.Enabled(RDiv)) return;
                for (int k = 1; k < t.Count - 1; k++)
                {
                    bool mod = t[k].Is("MOD");
                    Token pv = t[k - 1];
                    bool infixPos = (pv.Kind == TokKind.Ident && (!StLexer.Keywords.Contains(pv.Upper) || pv.Upper == "TRUE" || pv.Upper == "FALSE")) || pv.Kind == TokKind.Number || pv.Kind == TokKind.TypedLiteral || pv.IsOp(")") || pv.IsOp("]") || pv.IsOp("^");
                    if ((t[k].Is("DIV") || mod) && t[k + 1].IsOp("(") && !infixPos)
                    {
                        // review S4: function form DIV(a, b) / MOD(a, b); the compiler's reaction to a constant 0 here is not measured
                        int c = MatchForward(k + 1, "(", ")", t.Count);
                        if (c < 0) continue;
                        List<int[]> args = SplitTop(t, k + 2, c);
                        if (args.Count != 2 || args[1][1] <= args[1][0]) { Skip(RDiv, "div-function-form-not-understood"); continue; }
                        int a0 = args[1][0], a1 = args[1][1];
                        decimal? fv = Eval(a0, a1, null, 0, false);
                        if (fv.HasValue) { if (fv.Value == 0) ZeroDivisor(k, mod, t[k], t[k].Upper + "(..., " + Text(a0, a1) + ")", false); continue; }
                        Dsg fd = ParseDsg(a0, a1);
                        if (fd.C.Count > 0 && fd.End == a1 && !fd.Call) VariableDivisor(k, a0, a1, mod);
                        continue;
                    }
                    if (!mod && !t[k].IsOp("/")) continue;
                    int j = k + 1;
                    while (j < t.Count && (t[j].IsOp("-") || t[j].IsOp("+"))) j++;
                    Token x = t[j];
                    string op = mod ? "MOD" : "/";
                    if (x.Kind == TokKind.Number || x.Kind == TokKind.TypedLiteral)
                    {
                        bool real;
                        decimal? v = ParseLiteral(x.Text, out real);
                        // nit1: only the measured forms x / 0 and x / 0.0 (C0374) are marked compilerCatches yes
                        if (v.HasValue && v.Value == 0) ZeroDivisor(k, mod, x, op + " " + (j > k + 1 ? Text(k + 1, j + 1) : x.Text), j == k + 1 && (x.Text == "0" || x.Text == "0.0"));
                        continue;
                    }
                    if (x.IsOp("("))
                    {
                        int c = MatchForward(j, "(", ")", t.Count);
                        if (c < 0) continue;
                        decimal? v = Eval(j, c + 1, null, 0, false);
                        if (v.HasValue && v.Value == 0) ZeroDivisor(k, mod, x, op + " " + Text(j, c + 1), false);
                        continue;
                    }
                    if (x.Kind != TokKind.Ident || (StLexer.Keywords.Contains(x.Upper) && x.Upper != "THIS" && x.Upper != "SUPER")) continue;
                    // divisor designator: ident ( . ident | ^ | [ ... ] )*
                    int e = j + 1;
                    while (e < t.Count)
                    {
                        if (t[e].IsOp(".") && e + 1 < t.Count && t[e + 1].Kind == TokKind.Ident) { e += 2; continue; }
                        if (t[e].IsOp("^")) { e++; continue; }
                        if (t[e].IsOp("[")) { int m = MatchForward(e, "[", "]", t.Count); if (m < 0) break; e = m + 1; continue; }
                        break;
                    }
                    if (e < t.Count && t[e].IsOp("(")) continue;   // the divisor is a call result: not analysed
                    string name = null;
                    if (e == j + 1) name = x.Text;
                    else if (e == j + 3 && t[j + 1].IsOp(".") && run.gvlByName.ContainsKey(x.Text)) name = x.Text + "." + t[j + 2].Text;
                    if (name != null)
                    {
                        VarRef r = run.Resolve(Sc, name);
                        if (r != null && r.Constant)
                        {
                            decimal? v = run.ConstValue(Sc, name, 0, false);
                            if (v.HasValue && v.Value == 0) ZeroDivisor(k, mod, x, op + " " + name, false);
                            continue;
                        }
                        if (r != null && FixedNonZero(r, name)) continue;
                    }
                    VariableDivisor(k, j, e, mod);
                }
            }

            private void VariableDivisor(int k, int j, int e, bool mod)
            {
                {
                    List<string> seq = new List<string>();
                    for (int q = j; q < e; q++) seq.Add(t[q].Kind == TokKind.Ident ? t[q].Upper : t[q].Text);
                    if (DivisorChecked(k, seq)) return;
                    string dv = Text(j, e);
                    Diagnostic d = Emit(RDiv, t[k], "Divisor " + dv + " is a variable and no IF / CASE / WHILE condition on this path tests it before the " + (mod ? "MOD" : "division") +
                        " (InfoSys 12292258059: 'To prevent runtime errors, a non-zero query should always be made before a division.'; DIV 2528875403: 'In TwinCAT, division by zero always leads to an exception and the corresponding task is stopped.'). " +
                        "Heuristic: the linter does not follow values, so a divisor that can never be 0 is reported too (info, never blocking)",
                        StatementText(k), "Test the divisor first (IF " + dv + " <> 0 THEN ...), or suppress with a reason why it cannot be 0", "unchecked-variable-divisor", "info", "false");
                    if (d != null) d.Confidence = "medium";
                }
            }

            // a VAR / VAR_STAT / VAR_INST of the section or POU with a non-zero constant initial value that no analysed ST section
            // of the project writes (:=, S=, R=, REF=, =>, passed bare to a call) and whose POU has no section the linter could not read:
            // used as a constant (corpus: gear ratios, rated torques). ADS / HMI writes are not visible (info rule only).
            private bool FixedNonZero(VarRef r, string name)
            {
                if (r.V == null || r.Block == null || r.DeclScope == null || r.DeclScope.Gvl != null || string.IsNullOrEmpty(r.V.InitText)) return false;
                if (r.Block.Kind != "VAR" && r.Block.Kind != "VAR_STAT" && r.Block.Kind != "VAR_INST") return false;
                if (r.Block.Qualifiers.Contains("PERSISTENT") || r.Block.Qualifiers.Contains("RETAIN")) return false;
                LexResult lx = StLexer.Lex(r.V.InitText);
                if (lx.Error != null || lx.Unknown.Count > 0) return false;
                List<Token> it = NoPragmas(lx.Tokens);
                decimal? v = new ConstEval(run, r.DeclScope, it, 0, it.Count - 1, null, 0, false, 0).Run();
                if (!v.HasValue || v.Value == 0) return false;
                int dot = u.Path.IndexOf('.');
                return !run.WrittenSomewhere(name.ToUpperInvariant(), dot < 0 ? u.Path : u.Path.Substring(0, dot));
            }

            public Writes AllWrites() { return WritesIn(0, t.Count); }

            private void ZeroDivisor(int k, bool mod, Token at, string ev, bool literal)
            {
                string variant = mod ? "constant-zero-mod" : "constant-zero-div";
                string msg = mod
                    ? "MOD by the constant 0: the compiler does not report it (no error or warning, measured 2026-11-13); InfoSys MOD 2528880779: 'The behavior when dividing by zero or MOD 0 can vary depending on the target system!' / 'An exception may occur and the corresponding task may be stopped.'"
                    : "Division by the constant 0" + (literal ? ": the compiler rejects it (C0374 Division by zero, measured 2026-11-13 for x / 0 and x / 0.0), this finding only reports it before the write"
                                                              : ": a constant expression / named constant that is 0 (not measured whether the compiler rejects this form)") +
                      "; InfoSys DIV 2528875403 (permitted data types include REAL and LREAL): 'In TwinCAT, division by zero always leads to an exception and the corresponding task is stopped.' (runtime result not measured, tasks 2.10)";
                Diagnostic d = Emit(RDiv, t[k], msg, StatementText(k), "Remove the division by 0", variant, null, null);
                if (d != null && literal && !mod) d.CompilerCatches = "yes";
            }

            private string StatementText(int k)
            {
                int s = k, e = k;
                while (s > 0 && !t[s - 1].IsOp(";") && !t[s - 1].IsOp(":") && !IsStmtKeyword(t[s - 1])) s--;
                while (e < t.Count - 1 && !t[e].IsOp(";") && !IsStmtKeyword(t[e])) e++;
                return Text(s, e);
            }

            private static bool IsStmtKeyword(Token x)
            {
                if (x.Kind != TokKind.Ident) return false;
                switch (x.Upper)
                {
                    case "THEN": case "ELSE": case "ELSIF": case "DO": case "REPEAT": case "UNTIL": case "END_IF": case "END_FOR": case "END_WHILE": case "END_CASE": case "END_REPEAT": case "OF": return true;
                }
                return false;
            }

            private bool AssignedFromTested(Br r, int k, List<string> seq)
            {
                for (int q = r.BodyFrom; q + seq.Count < k; q++)
                {
                    bool ok = true;
                    for (int z = 0; z < seq.Count && ok; z++) ok = (t[q + z].Kind == TokKind.Ident ? t[q + z].Upper : t[q + z].Text) == seq[z];
                    if (!ok || !t[q + seq.Count].IsOp(":=") || (q > 0 && t[q - 1].IsOp("."))) continue;
                    HashSet<string> rhs = new HashSet<string>(StringComparer.Ordinal);
                    for (int z = q + seq.Count + 1; z < k && !t[z].IsOp(";"); z++)
                        if (t[z].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[z].Upper)) rhs.Add(t[z].Upper);
                    if (rhs.Count > 0 && Mentions(r.CondFrom, r.CondTo, rhs)) return true;
                }
                return false;
            }

            private bool SeqIn(int from, int to, List<string> seq)
            {
                for (int k = Math.Max(0, from); k + seq.Count <= to; k++)
                {
                    bool ok = true;
                    for (int q = 0; q < seq.Count && ok; q++)
                    {
                        Token x = t[k + q];
                        ok = (x.Kind == TokKind.Ident ? x.Upper : x.Text) == seq[q];
                    }
                    if (ok && !(k > 0 && t[k - 1].IsOp("."))) return true;
                }
                return false;
            }

            // the divisor is tested on this path: an enclosing IF / ELSIF / CASE / WHILE condition, an earlier IF whose
            // branch leaves (RETURN / EXIT) or rewrites the divisor, or the same expression before the division (AND_THEN, SEL)
            private bool DivisorChecked(int k, List<string> seq)
            {
                foreach (Blk b in Enclosing(k, -1))
                {
                    if (b.Kind == "IF")
                    {
                        for (int j = 0; j < b.Branches.Count; j++)
                        {
                            Br r = b.Branches[j];
                            bool inCond = r.CondFrom >= 0 && k >= r.CondFrom && k < r.CondTo;
                            bool inBody = k >= r.BodyFrom && k < r.BodyTo;
                            if (r.CondFrom >= 0 && (inCond ? GuardBefore(r.CondFrom, k, seq) : SeqIn(r.CondFrom, r.CondTo, seq))) return true;
                            // divisor computed in this branch from what the branch condition tests (corpus: fSpan := full - zero
                            // under IF full <> zero; velocity := product of values tested > 0)
                            if (inBody && r.CondFrom >= 0 && AssignedFromTested(r, k, seq)) return true;
                            if (inCond || inBody) break;
                        }
                    }
                    else if (b.Kind == "CASE" || b.Kind == "WHILE")
                    {
                        Br r0 = b.Branches[0];
                        if (k < r0.CondTo ? GuardBefore(r0.CondFrom, k, seq) : SeqIn(r0.CondFrom, r0.CondTo, seq)) return true;
                    }
                }
                foreach (Blk b in blocks)
                {
                    if (b.Kind != "IF" || b.End >= k) continue;
                    foreach (Br r in b.Branches)
                    {
                        if (r.CondFrom < 0 || !SeqIn(r.CondFrom, r.CondTo, seq)) continue;
                        Writes w = WritesIn(r.BodyFrom, r.BodyTo);
                        if (w.ExitLike == "RETURN" || w.ExitLike == "EXIT" || w.ExitLike == "JMP") return true;
                        if (seq.Count > 0 && w.Names.Contains(seq[0])) return true;
                    }
                }
                int s = k;
                while (s > 0 && !t[s - 1].IsOp(";") && !IsStmtKeyword(t[s - 1])) s--;
                int assign = -1;
                for (int q = s; q < k; q++) if (t[q].IsOp(":=")) { assign = q; break; }
                return GuardBefore(assign < 0 ? s : assign + 1, k, seq);
            }

            // second review S5: a test in the same expression as the division protects it only through short-circuit
            // evaluation. InfoSys AND_THEN tc3_plc_intro/2528923787.html: 'TwinCAT always evaluates all operands if the IEC
            // operator AND is used' (OR likewise; OR_ELSE short-circuits). SEL tc3_plc_intro/2528956043.html: 'TwinCAT does not
            // compute an expression that precedes IN0 if G = TRUE' / '... IN1 if G = FALSE': a test in G guards IN0 / IN1.
            private int Polarity(int after, int limit)
            {
                if (after + 1 >= limit) return 0;
                Token op = t[after], v = t[after + 1];
                bool zero = v.Kind == TokKind.Number && (v.Text == "0" || v.Text == "0.0");
                if (!zero) return 0;
                if (op.IsOp("<>") || op.IsOp(">")) return 1;
                if (op.IsOp("=")) return -1;
                return 0;
            }

            private bool GuardBefore(int from, int k, List<string> seq)
            {
                for (int p = Math.Max(0, from); p + seq.Count <= k; p++)
                {
                    bool ok = true;
                    for (int q = 0; q < seq.Count && ok; q++) ok = (t[p + q].Kind == TokKind.Ident ? t[p + q].Upper : t[p + q].Text) == seq[q];
                    if (!ok || (p > 0 && t[p - 1].IsOp("."))) continue;
                    // review 3 S5e / S5f: the direction of the test matters. 'd <> 0' / 'd > 0' is TRUE when d is not 0, 'd = 0'
                    // is TRUE when it is 0; anything else is not judged (counted as a guard, as before)
                    int pol = Polarity(p + seq.Count, k);   // 1 = TRUE means non-zero, -1 = TRUE means zero, 0 = unknown
                    for (int q = p + seq.Count; q < k; q++)
                    {
                        if (t[q].Is("AND_THEN")) { if (pol != -1) return true; break; }   // right side runs only when the test is TRUE
                        if (t[q].Is("OR_ELSE")) { if (pol != 1) return true; break; }    // right side runs only when the test is FALSE
                    }
                    for (int q = Math.Max(0, from); q < p; q++)
                    {
                        if (!t[q].Is("SEL") || q + 1 >= t.Count || !t[q + 1].IsOp("(")) continue;
                        int c = MatchForward(q + 1, "(", ")", t.Count);
                        if (c < k) continue;
                        List<int[]> args = SplitTop(t, q + 2, c);
                        if (args.Count != 3 || p < args[0][0] || p >= args[0][1]) continue;
                        // IN0 (args[1]) is computed when G = FALSE, IN1 (args[2]) when G = TRUE (InfoSys SEL 2528956043)
                        if (k >= args[2][0] && pol != -1) return true;
                        if (k >= args[1][0] && k < args[1][1] && pol != 1) return true;
                    }
                }
                return false;
            }
        }
    }
}
