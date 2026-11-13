﻿// TwinCAT Semantic Linter (#252) - Phase 3a rules SCAN-FBVAL-001, SCAN-FLOAT-001, SCAN-INTDIV-001 (rule-catalog.md Phase 3,
// tasks 3.1). C# 5. The engine has no general expression typing: operand types are only PROVEN for literals, typed literals
// and plain variables / VAR CONSTANTs that Resolve() finds with a basic type; anything else is unknown -> rulesSkipped.
// Principle (PR #284 / #289 reviews): what cannot be proven -> coverage.rulesSkipped with a reason; never a silent pass, never a guess.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    public static partial class RuleRegistry
    {
        private static void Register3Expr()
        {
            Add("SCAN-FBVAL-001", "Function block passed by value (VAR_INPUT) is called or changed in the callee", "warning", "false", "behavior", "no",
                "A VAR_INPUT whose type is a function block (project FUNCTION_BLOCK or TypeCatalog.json; ARRAY OF such an FB too) of a FUNCTION_BLOCK / FUNCTION / METHOD receives a copy ('input and output parameters ... are copied in most cases when the function/method is called', InfoSys 12081345291). " +
                "Reported at the declaration when the callee changes the copy: calls it (fbIn(...), variant copy-called), calls a method / action (fbIn.M()), or writes a member (fbIn.x := ..., variant copy-written): the caller's instance never sees it and the state is lost after the call. " +
                "Not reported: only outputs of the copy read (the copy shows the caller's state at call time), VAR_IN_OUT, REFERENCE TO / POINTER TO FB, interface types, STRUCT / basic types. " +
                "rulesSkipped <reason>:<input>: unknown-type (type outside the project and the catalog, only when it is called / written), implementation-not-analyzed. Basis of the consequence: inferred from the copy semantics, not measured.", "high", "inferred");
            Add("SCAN-FLOAT-001", "REAL / LREAL compared with = or <>", "warning", "false", "behavior", "no",
                "Variant constant: one operand proven REAL / LREAL (variable, VAR CONSTANT, literal with a fraction / exponent, REAL# / LREAL#) and the other a non-zero literal or constant, or one operand a non-zero REAL literal (the comparison is then a REAL comparison). " +
                "Not reported: a zero literal / constant on either side (0.0 / 0: initialisation check), two variables (rulesSkipped two-variables: change detection rOld <> rNew, a guard IF x1 = x2 before dividing by x2 - x1, a value clamped with y := in), < > <= >=, integer / other comparisons. " +
                "Operands: a literal, typed literal, plain variable or GVL.variable between expression boundaries; anything else (struct member, array element, call, sub-expression) is unknown. " +
                "rulesSkipped operand-type-unknown (one entry per object): a proven REAL variable compared with an unknown operand. Consequence (an exact REAL equality is rarely met, the machine waits) inferred, not measured; SA0054 (Full) checks the same.", "medium", "inferred");
            Add("SCAN-INTDIV-001", "Integer division assigned to REAL / LREAL (truncated before the conversion)", "warning", "false", "behavior", "no",
                "Reported (variant integer-division) for 'target := ...' with a proven REAL / LREAL target where a '/' has two proven integer operands (integer literals, typed integer literals, integer variables / constants), also inside parentheses. " +
                "Not reported: a REAL operand (INT_TO_REAL(a) / b, a / 2.0), an integer target, '/' in an array index, DIV / MOD, declaration initial values. " +
                "rulesSkipped (one entry per object and reason): explicit-conversion (TO_REAL(a / b): truncation written explicitly), in-function-call (the division is an argument of another call), operand-type-unknown, target-type-unknown. " +
                "Basis: IEC 61131-3 operator typing (the result type of a / b with integer operands is an integer type); no InfoSys page for the PLC '/' operator states it (TF5100 NC I DIV: 'If the return type is an integer type, the result is truncated towards zero' is the NC interpreter, not the PLC) - inferred, not measured.", "medium", "inferred");
            foreach (string id in new string[] { "SCAN-FBVAL-001", "SCAN-FLOAT-001", "SCAN-INTDIV-001" }) RuleRegistry.Get(id).Phase = "3";
            RuleRegistry.Get("SCAN-FBVAL-001").Requires = "type-catalog";
            RuleRegistry.Get("SCAN-FBVAL-001").Te1200 = "SA0014 (Full, related: assignment of instances)";
            RuleRegistry.Get("SCAN-FLOAT-001").Te1200 = "SA0054 (Full)";
            RuleRegistry.Get("SCAN-INTDIV-001").Te1200 = "SA0020 / SA0057 (Full)";
        }
    }

    internal sealed partial class LintRun
    {
        private const string RFbVal = "SCAN-FBVAL-001";
        private const string RFloat = "SCAN-FLOAT-001";
        private const string RIntDiv = "SCAN-INTDIV-001";

        private static readonly HashSet<string> Expr3Int = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "SINT", "INT", "DINT", "LINT", "USINT", "UINT", "UDINT", "ULINT", "BYTE", "WORD", "DWORD", "LWORD"
        };
        private static readonly HashSet<string> Expr3Basic = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "BOOL", "BIT", "SINT", "INT", "DINT", "LINT", "USINT", "UINT", "UDINT", "ULINT", "BYTE", "WORD", "DWORD", "LWORD", "REAL", "LREAL",
            "TIME", "LTIME", "DATE", "LDATE", "TOD", "LTOD", "TIME_OF_DAY", "LTIME_OF_DAY", "DT", "LDT", "DATE_AND_TIME", "LDATE_AND_TIME",
            "STRING", "WSTRING", "PVOID", "XINT", "UXINT", "XWORD", "__XINT", "__UXINT", "__XWORD"
        };

        private sealed class Expr3Op
        {
            public string Kind = "unknown";   // real / int / other / unknown
            public bool Var;                  // a plain (non-constant) variable
            public bool Constant;             // literal or VAR CONSTANT with a known value
            public bool RealLiteral;
            public decimal? Value;
        }

        private readonly HashSet<string> expr3Skipped = new HashSet<string>(StringComparer.Ordinal);

        private void Expr3Skip(string id, ImplUnit u, string reason)
        {
            if (!Enabled(id)) return;
            if (!expr3Skipped.Add(id + "|" + u.Path + "|" + reason)) return;
            rulesSkipped.Add(Cov(id, u.O.Rel, u.Path, null, reason));
        }

        private void RunPhase3Expr()
        {
            bool fv = Enabled(RFbVal), fl = Enabled(RFloat), id = Enabled(RIntDiv);
            if (!fv && !fl && !id) return;
            Ensure3Index();
            if (fv) Expr3FbVal();
            if (!fl && !id) return;
            foreach (ImplUnit u in implUnits)
            {
                if (u.Scan == null || u.Scan.State.Status != "ok" || u.Scan.Lex == null)
                {
                    bool eq = true, div = true;
                    if (u.Scan != null && u.Scan.Lex != null && u.Scan.Lex.Error == null)
                    {
                        eq = false; div = false;
                        foreach (Token x in u.Scan.Lex.Tokens) { if (x.IsOp("=") || x.IsOp("<>")) eq = true; if (x.IsOp("/")) div = true; }
                    }
                    if (fl && eq) Expr3Skip(RFloat, u, "implementation-not-analyzed");
                    if (id && div) Expr3Skip(RIntDiv, u, "implementation-not-analyzed");
                    continue;
                }
                Scope sc = ScopeOf(u);
                List<Token> t = NoPragmas(u.Scan.Lex.Tokens);
                for (int k = 1; k + 1 < t.Count; k++)
                {
                    if (fl && (t[k].IsOp("=") || t[k].IsOp("<>"))) Expr3Float(u, sc, t, k);
                    else if (id && t[k].IsOp("/")) Expr3Div(u, sc, t, k);
                }
            }
        }

        // ================================================================ operands
        private static bool Expr3Boundary(Token x)
        {
            if (x == null || x.Kind == TokKind.EOF) return true;
            if (x.Kind == TokKind.Op) return x.Text == "(" || x.Text == ")" || x.Text == "," || x.Text == ":=" || x.Text == ";" || x.Text == "=>";
            return x.Is("IF") || x.Is("ELSIF") || x.Is("THEN") || x.Is("WHILE") || x.Is("DO") || x.Is("UNTIL") || x.Is("AND") || x.Is("OR") || x.Is("XOR") || x.Is("NOT")
                || x.Is("AND_THEN") || x.Is("OR_ELSE") || x.Is("RETURN") || x.Is("ELSE") || x.Is("END_IF") || x.Is("END_WHILE") || x.Is("END_REPEAT") || x.Is("TO") || x.Is("BY") || x.Is("OF");
        }

        // simple operand that ends at index e (literal, typed literal, name, G.name; optional unary minus); start = -1: complex
        private static int Expr3OperandStartBack(List<Token> t, int e)
        {
            if (e < 0) return -1;
            int s;
            if (t[e].Kind == TokKind.Number || t[e].Kind == TokKind.TypedLiteral) s = e;
            else if (t[e].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[e].Upper))
            {
                s = e;
                while (s >= 2 && t[s - 1].IsOp(".") && t[s - 2].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[s - 2].Upper)) s -= 2;
                if (s >= 1 && (t[s - 1].IsOp(".") || t[s - 1].IsOp("^") || t[s - 1].IsOp("]") || t[s - 1].IsOp(")"))) return -1;
            }
            else return -1;
            if (s >= 1 && (t[s - 1].IsOp("-") || t[s - 1].IsOp("+")) && (s < 2 || Expr3Boundary(t[s - 2]) || t[s - 2].IsOp("=") || t[s - 2].IsOp("<>"))) s--;
            return s;
        }

        // simple operand that starts at index s; returns the index after it, -1: complex
        private static int Expr3OperandEndFwd(List<Token> t, int s)
        {
            int k = s;
            if (k < t.Count && (t[k].IsOp("-") || t[k].IsOp("+"))) k++;
            if (k >= t.Count) return -1;
            if (t[k].Kind == TokKind.Number || t[k].Kind == TokKind.TypedLiteral) return k + 1;
            if (t[k].Kind != TokKind.Ident || StLexer.Keywords.Contains(t[k].Upper)) return -1;
            k++;
            while (k + 1 < t.Count && t[k].IsOp(".") && t[k + 1].Kind == TokKind.Ident) k += 2;
            if (k < t.Count && (t[k].IsOp("(") || t[k].IsOp("[") || t[k].IsOp("^") || t[k].IsOp("."))) return -1;
            return k;
        }

        private Expr3Op Expr3Classify(Scope sc, List<Token> t, int s, int e)
        {
            Expr3Op o = new Expr3Op();
            if (s < 0 || e <= s) return o;
            bool neg = false;
            if (t[s].IsOp("-") || t[s].IsOp("+")) { neg = t[s].IsOp("-"); s++; }
            if (e - s == 1 && (t[s].Kind == TokKind.Number || t[s].Kind == TokKind.TypedLiteral))
            {
                string txt = t[s].Text;
                bool real;
                decimal? v = ParseLiteral(txt, out real);
                int hash = txt.IndexOf('#');
                string prefix = hash > 0 ? txt.Substring(0, hash).ToUpperInvariant() : null;
                if (prefix != null && prefix != "REAL" && prefix != "LREAL" && !Expr3Int.Contains(prefix) && prefix != "2" && prefix != "8" && prefix != "16") { o.Kind = "other"; return o; }
                o.Kind = real ? "real" : "int"; o.Constant = v.HasValue; o.Value = v.HasValue ? (neg ? -v.Value : v.Value) : (decimal?)null; o.RealLiteral = real;
                if (!v.HasValue) o.Kind = "unknown";
                return o;
            }
            if (e - s == 1 && (t[s].Is("TRUE") || t[s].Is("FALSE"))) { o.Kind = "other"; return o; }
            string name = "";
            for (int k = s; k < e; k++) name += t[k].Text;
            if (name.IndexOf('.') >= 0 && name.Split('.').Length > 2) return o;
            VarRef r = Resolve(sc, name);
            if (r == null) return o;
            string tt = (r.TypeText ?? "").Trim();
            string up = tt.ToUpperInvariant();
            if (up == "REAL" || up == "LREAL") o.Kind = "real";
            else if (Expr3Int.Contains(up)) o.Kind = "int";
            else if (Expr3Basic.Contains(up) || up.StartsWith("STRING", StringComparison.Ordinal) || up.StartsWith("WSTRING", StringComparison.Ordinal)) o.Kind = "other";
            else return o;
            if (r.Constant)
            {
                o.Value = ConstValue(sc, name, 0, false);
                o.Constant = o.Value.HasValue;
                if (o.Value.HasValue && neg) o.Value = -o.Value.Value;
            }
            else o.Var = true;
            return o;
        }

        // ================================================================ SCAN-FLOAT-001
        private void Expr3Float(ImplUnit u, Scope sc, List<Token> t, int k)
        {
            int ls = Expr3OperandStartBack(t, k - 1);
            Expr3Op L = (ls >= 0 && (ls == 0 || Expr3Boundary(t[ls - 1]))) ? Expr3Classify(sc, t, ls, k) : new Expr3Op();
            int re = Expr3OperandEndFwd(t, k + 1);
            Expr3Op R = (re > 0 && (re >= t.Count || Expr3Boundary(t[re]))) ? Expr3Classify(sc, t, k + 1, re) : new Expr3Op();
            bool lz = L.Constant && L.Value.HasValue && L.Value.Value == 0, rz = R.Constant && R.Value.HasValue && R.Value.Value == 0;
            if (lz || rz) return;
            bool lnz = L.Constant && L.Value.HasValue, rnz = R.Constant && R.Value.HasValue;
            string variant = null;
            if ((L.Kind == "real" && rnz && R.Kind != "other") || (R.Kind == "real" && lnz && L.Kind != "other") || (L.RealLiteral && lnz && R.Kind != "other") || (R.RealLiteral && rnz && L.Kind != "other")) variant = "constant";
            if (variant == null)
            {
                // two variables: not proven wrong (corpus 2026-11-13: IF x1 = x2 guards a division by (x2 - x1), y = in after the ramp
                // clamps y := in, a parameter compared with its limit) -> recorded, not reported
                if (L.Var && R.Var && (L.Kind == "real" || R.Kind == "real") && (L.Kind == "real" || L.Kind == "int") && (R.Kind == "real" || R.Kind == "int")) { Expr3Skip(RFloat, u, "two-variables"); return; }
                if ((L.Kind == "real" && R.Kind == "unknown") || (R.Kind == "real" && L.Kind == "unknown")) Expr3Skip(RFloat, u, "operand-type-unknown");
                return;
            }
            string a = Expr3Text(t, ls >= 0 ? ls : k - 1, k), b = Expr3Text(t, k + 1, re > 0 ? re : k + 2);
            Emit(RFloat, u.O.Rel, u.Path, "implementation", t[k].Line, t[k].Col,
                "REAL / LREAL compared with '" + t[k].Text + "' (" + a + " " + t[k].Text + " " + b + "): an exact floating-point equality is rarely met after arithmetic, so the condition may never become TRUE (or never FALSE) and the machine waits",
                a + " " + t[k].Text + " " + b, "Compare with a tolerance: ABS(a - b) < eps, or use >= / <= for a position / limit", variant, null, null, false);
        }

        private static string Expr3Text(List<Token> t, int s, int e)
        {
            List<string> p = new List<string>();
            for (int k = Math.Max(0, s); k < e && k < t.Count; k++) if (t[k].Kind != TokKind.EOF) p.Add(t[k].Text);
            return string.Join(" ", p.ToArray());
        }

        // ================================================================ SCAN-INTDIV-001
        private void Expr3Div(ImplUnit u, Scope sc, List<Token> t, int k)
        {
            // statement start, enclosing call / index
            int depth = 0, bdepth = 0; bool conv = false, call = false; int st = -1;
            for (int q = k - 1; q >= 0; q--)
            {
                Token p = t[q];
                if (p.IsOp(")")) depth++;
                else if (p.IsOp("]")) bdepth++;
                else if (p.IsOp("["))
                {
                    if (bdepth == 0) return;   // '/' in an array index: an integer index computation
                    bdepth--;
                }
                else if (p.IsOp("("))
                {
                    if (depth > 0) { depth--; continue; }
                    if (q > 0 && t[q - 1].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[q - 1].Upper) || (q > 0 && (t[q - 1].Is("TRUNC") || t[q - 1].Upper.StartsWith("TO_", StringComparison.Ordinal))))
                    {
                        string f = q > 0 ? t[q - 1].Upper : "";
                        if (f.IndexOf("_TO_", StringComparison.Ordinal) >= 0 || f.StartsWith("TO_", StringComparison.Ordinal) || f == "TRUNC" || f == "TRUNC_INT") conv = true; else call = true;
                    }
                }
                else if (depth == 0 && bdepth == 0 && (p.IsOp(";") || p.Is("THEN") || p.Is("ELSE") || p.Is("DO") || p.Is("REPEAT") || p.Is("OF") || p.IsOp(":") || p.Is("END_IF") || p.Is("END_CASE") || p.Is("END_FOR") || p.Is("END_WHILE") || p.Is("END_REPEAT")))
                { st = q + 1; break; }
                if (q == 0) st = 0;
            }
            if (st < 0) return;
            int asg = -1;
            for (int q = st; q < k; q++) { if (t[q].IsOp(":=")) { asg = q; break; } if (t[q].IsOp("(") || t[q].IsOp("[")) break; }
            if (asg < 0) return;   // not 'target := ...' (a condition, a call statement)
            for (int q = asg + 1; q < k; q++) if (t[q].IsOp(":=") || t[q].IsOp("=>")) return;   // a call argument further in: not this target
            int le = Expr3OperandStartBack(t, k - 1);
            bool lOk = le >= 0 && le > asg && (le == 0 || Expr3Boundary(t[le - 1]) || t[le - 1].IsOp("+") || t[le - 1].IsOp("-"));
            Expr3Op L = lOk ? Expr3Classify(sc, t, le, k) : new Expr3Op();
            int re = Expr3OperandEndFwd(t, k + 1);
            Expr3Op R = re > 0 ? Expr3Classify(sc, t, k + 1, re) : new Expr3Op();
            if (Expr3RealCallBack(t, k - 1) || Expr3RealCallFwd(t, k + 1)) return;   // INT_TO_REAL(a) / b, a / TO_LREAL(b)
            if (L.Kind == "real" || R.Kind == "real" || L.Kind == "other" || R.Kind == "other") return;
            if (L.Kind != "int" || R.Kind != "int") { Expr3Skip(RIntDiv, u, "operand-type-unknown"); return; }
            Expr3Op T = Expr3OperandEndFwd(t, st) == asg ? Expr3Classify(sc, t, st, asg) : new Expr3Op();
            if (T.Kind == "unknown") { Expr3Skip(RIntDiv, u, "target-type-unknown"); return; }
            if (T.Kind != "real") return;
            if (conv) { Expr3Skip(RIntDiv, u, "explicit-conversion"); return; }
            if (call) { Expr3Skip(RIntDiv, u, "in-function-call"); return; }
            string a = Expr3Text(t, le, k), b = Expr3Text(t, k + 1, re), target = Expr3Text(t, st, asg);
            Emit(RIntDiv, u.O.Rel, u.Path, "implementation", t[k].Line, t[k].Col,
                "Integer division " + a + " / " + b + " assigned to the REAL / LREAL '" + target + "': both operands are integers, so the quotient is truncated to an integer before it is converted (e.g. 1 / 3 gives 0.0)",
                target + " := ... " + a + " / " + b, "Convert an operand first: INT_TO_REAL(" + a + ") / " + b + " (or TO_LREAL), or use DIV / TRUNC explicitly if truncation is intended", "integer-division", null, null, false);
        }

        private static bool Expr3RealConv(string upperName)
        {
            return upperName == "TO_REAL" || upperName == "TO_LREAL" || upperName.EndsWith("_TO_REAL", StringComparison.Ordinal) || upperName.EndsWith("_TO_LREAL", StringComparison.Ordinal);
        }

        // the operand ending at e is a call of a conversion to REAL / LREAL
        private static bool Expr3RealCallBack(List<Token> t, int e)
        {
            if (e < 0 || !t[e].IsOp(")")) return false;
            int d = 0;
            for (int q = e; q >= 0; q--)
            {
                if (t[q].IsOp(")")) d++;
                else if (t[q].IsOp("(")) { d--; if (d == 0) return q > 0 && t[q - 1].Kind == TokKind.Ident && Expr3RealConv(t[q - 1].Upper); }
            }
            return false;
        }

        private static bool Expr3RealCallFwd(List<Token> t, int s)
        {
            return s + 1 < t.Count && t[s].Kind == TokKind.Ident && t[s + 1].IsOp("(") && Expr3RealConv(t[s].Upper);
        }

        // ================================================================ SCAN-FBVAL-001
        private string Expr3FbClass(string typeText)
        {
            string tt = (typeText ?? "").Trim();
            string up = tt.ToUpperInvariant();
            if (up.StartsWith("REFERENCE", StringComparison.Ordinal) || up.StartsWith("POINTER", StringComparison.Ordinal)) return "no";
            if (up.StartsWith("ARRAY", StringComparison.Ordinal))
            {
                int of = up.LastIndexOf(" OF ", StringComparison.Ordinal);
                if (of < 0) return "unknown";
                tt = tt.Substring(of + 4).Trim(); up = tt.ToUpperInvariant();
                if (up.StartsWith("REFERENCE", StringComparison.Ordinal) || up.StartsWith("POINTER", StringComparison.Ordinal)) return "no";
            }
            int par = tt.IndexOf('('); if (par >= 0) tt = tt.Substring(0, par).Trim();
            int br = tt.IndexOf('['); if (br >= 0) tt = tt.Substring(0, br).Trim();
            if (tt.Length == 0 || tt.IndexOf(' ') >= 0) return "unknown";
            string bare = tt, ns = null;
            int dot = tt.LastIndexOf('.');
            if (dot >= 0) { bare = tt.Substring(dot + 1); ns = tt.Substring(0, dot); }
            if (Expr3Basic.Contains(bare) && ns == null) return "no";
            string k;
            if (ns == null && typeKinds.TryGetValue(bare, out k)) return k == "FB" ? "fb" : "no";
            if (FindCatalog(bare, ns) != null) return "fb";
            if (LibraryNotFb(tt)) return "no";
            return "unknown";
        }

        private void Expr3FbVal()
        {
            foreach (DeclUnit du in declUnits)
            {
                if (du.Di == null || du.O == null) continue;
                string h = du.Di.HeaderKeyword ?? "";
                if (h != "FUNCTION_BLOCK" && h != "FUNCTION" && h != "METHOD") continue;
                bool top = du.Path == du.O.ObjectPath;
                foreach (VarBlock b in du.Di.VarBlocks)
                {
                    if (b.Kind != "VAR_INPUT") continue;
                    foreach (VarDecl v in b.Vars)
                    {
                        string cls = Expr3FbClass(v.TypeText);
                        if (cls == "no") continue;
                        foreach (string n in v.Names) Expr3FbValOne(du, top, v, n, cls);
                    }
                }
            }
        }

        private void Expr3FbValOne(DeclUnit du, bool top, VarDecl v, string name, string cls)
        {
            string variant = null; Token first = null; ImplUnit firstU = null; string problem = null;
            foreach (ImplUnit u in implUnits)
            {
                if (u.O != du.O) continue;
                if (!(top && h3IsFb(du)) && u.Path != du.Path) continue;
                if (u.Scan == null || u.Scan.State.Status != "ok" || u.Scan.Lex == null) { problem = "implementation-not-analyzed"; continue; }
                if (u.Path != du.Path)
                {
                    Scope sc = ScopeOf(u);
                    if (sc.LocalUnknown) { if (Ref3Mentions(u, name)) problem = "unanalysed-part"; continue; }
                    if (sc.Local != null && sc.Local != du.Di && FindIn(sc.Local, name, null) != null) continue;
                }
                List<Token> t = NoPragmas(u.Scan.Lex.Tokens);
                for (int i = 0; i < t.Count; i++)
                {
                    if (t[i].Kind != TokKind.Ident || !string.Equals(t[i].Text, name, StringComparison.OrdinalIgnoreCase)) continue;
                    int start = i;
                    if (i > 0 && t[i - 1].IsOp("."))
                    {
                        if (i >= 3 && t[i - 2].IsOp("^") && t[i - 3].Is("THIS")) start = i - 3; else continue;
                    }
                    Token prev = start > 0 ? t[start - 1] : null;
                    Token nx = i + 1 < t.Count ? t[i + 1] : null;
                    if (nx != null && (nx.IsOp(":=") || nx.IsOp("=>")) && prev != null && (prev.IsOp("(") || prev.IsOp(",")) && Sm3InCall(t, start)) continue;   // formal parameter
                    string vr = null;
                    int j = i + 1;
                    if (j < t.Count && t[j].IsOp("[")) { int d = 0; for (; j < t.Count; j++) { if (t[j].IsOp("[")) d++; else if (t[j].IsOp("]")) { d--; if (d == 0) { j++; break; } } } }
                    if (j < t.Count && t[j].IsOp("(")) vr = "copy-called";
                    else if (j + 2 < t.Count && t[j].IsOp(".") && t[j + 1].Kind == TokKind.Ident && t[j + 2].IsOp("(")) vr = "copy-called";
                    else if (j + 2 < t.Count && t[j].IsOp(".") && t[j + 1].Kind == TokKind.Ident && t[j + 2].IsOp(":=")) vr = "copy-written";
                    if (vr != null && first == null) { variant = vr; first = t[start]; firstU = u; }
                }
            }
            if (first == null) return;   // only read (or never used): the copy is legal
            if (problem != null) { rulesSkipped.Add(Cov(RFbVal, du.O.Rel, du.Path, null, problem + ":" + name)); return; }
            if (cls == "unknown") { rulesSkipped.Add(Cov(RFbVal, du.O.Rel, du.Path, null, "unknown-type:" + name)); return; }
            Emit(RFbVal, du.O.Rel, du.Path, "declaration", v.Line, v.Col,
                "Function block '" + name + " : " + (v.TypeText ?? "").Trim() + "' is a VAR_INPUT, so the callee gets a copy, but " + firstU.Path + " line " + Inv.S(first.Line) +
                (variant == "copy-called" ? " calls it" : " writes a member of it") + ": the change only happens on the copy and is lost after the call; the caller's instance is not updated",
                name + " : " + (v.TypeText ?? "").Trim(), "Pass the instance as VAR_IN_OUT (or REFERENCE TO) so the callee works on the caller's instance", variant, null, null, false);
        }

        private static bool h3IsFb(DeclUnit du) { return (du.Di.HeaderKeyword ?? "") == "FUNCTION_BLOCK"; }
    }
}
