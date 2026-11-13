// TwinCAT Semantic Linter (#252) - declaration parser and statement-structure scanner. C# 5.
// No full expression AST (design.md D3): headers, VAR sections, TYPE definitions, block pairing,
// call sites and identifier references. Unknown-but-maybe-legal input -> Status "not-analyzed";
// "parse-failed" only for certainly illegal input in a section without any unknown construct.
namespace TcLintEngine
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Text;

    public sealed class SectionStatus
    {
        public string Status = "ok";      // ok / not-analyzed (listed legal construct) / unsupported (not understood) / parse-failed
        public string Reason;             // not-analyzed reason, e.g. conditional-pragma
        public string ErrorRule;          // LINT-PARSE-00x for parse-failed
        public string ErrorMessage;
        public int ErrorLine;
        public int ErrorCol;
        public int ReasonLine;
        public int ReasonCol;

        // "unsupported-syntax:*" = something the parser does not understand -> status unsupported (the verdict
        // can never be pass); the listed constructs that may be legal (conditional pragma, unverified-syntax:*)
        // -> not-analyzed. unsupported wins over not-analyzed; both win over a later structure error (D3).
        public void NotAnalyzed(string reason, int line, int col)
        {
            bool unsupported = reason.StartsWith("unsupported-syntax:", StringComparison.Ordinal);
            if (Status == "unsupported") return;
            if (Status == "not-analyzed" && !unsupported) return;
            Status = unsupported ? "unsupported" : "not-analyzed"; Reason = reason; ReasonLine = line; ReasonCol = col;
            ErrorRule = null; ErrorMessage = null;
        }

        public void Fail(string rule, string message, int line, int col)
        {
            if (Status != "ok") return;
            Status = "parse-failed"; ErrorRule = rule; ErrorMessage = message; ErrorLine = line; ErrorCol = col;
        }

        public void AddTo(OrderedDictionary d)
        {
            d["status"] = Status;
            if (Reason != null) { d["reason"] = Reason; d["reasonLine"] = ReasonLine; }
            if (ErrorRule != null) { d["errorRule"] = ErrorRule; d["error"] = ErrorMessage; d["errorLine"] = ErrorLine; d["errorColumn"] = ErrorCol; }
        }
    }

    public sealed class VarDecl
    {
        public List<string> Names = new List<string>();
        public string Address;
        public string TypeText;
        public string InitText;
        public int Line;
        public int Col;
        public List<string> Attributes = new List<string>();
    }

    public sealed class VarBlock
    {
        public string Kind;
        public List<string> Qualifiers = new List<string>();
        public List<VarDecl> Vars = new List<VarDecl>();
        public int Line;
    }

    public sealed class EnumMember
    {
        public string Name;
        public string ValueText;
        public int Line;
    }

    public sealed class TypeDef
    {
        public string Kind;      // STRUCT / UNION / ENUM / ALIAS
        public string Name;
        public string Extends;
        public string BaseType;  // ENUM base type, ALIAS target
        public string DefaultText;
        public List<VarDecl> Members = new List<VarDecl>();
        public List<EnumMember> EnumMembers = new List<EnumMember>();
    }

    public sealed class DeclInfo
    {
        public SectionStatus State = new SectionStatus();
        public string HeaderKeyword = "";   // PROGRAM, FUNCTION_BLOCK, FUNCTION, METHOD, PROPERTY, INTERFACE, TYPE, VAR_GLOBAL, VAR..., "" = empty
        public bool HeaderKnown;
        public string Name;
        public int NameLine;
        public int NameCol;
        public List<string> Modifiers = new List<string>();
        public List<string> Extends = new List<string>();
        public List<string> Implements = new List<string>();
        public string ReturnType;
        public List<string> Attributes = new List<string>();
        public List<VarBlock> VarBlocks = new List<VarBlock>();
        public TypeDef Type;
        public LexResult Lex;

        public OrderedDictionary ToDictionary()
        {
            OrderedDictionary d = new OrderedDictionary();
            State.AddTo(d);
            d["headerKeyword"] = HeaderKeyword; d["headerKnown"] = HeaderKnown; d["name"] = Name;
            d["modifiers"] = new ArrayList(Modifiers); d["extends"] = new ArrayList(Extends); d["implements"] = new ArrayList(Implements);
            d["returnType"] = ReturnType; d["attributes"] = new ArrayList(Attributes);
            ArrayList blocks = new ArrayList();
            foreach (VarBlock b in VarBlocks)
            {
                OrderedDictionary bd = new OrderedDictionary();
                bd["kind"] = b.Kind; bd["qualifiers"] = new ArrayList(b.Qualifiers); bd["vars"] = VarsToList(b.Vars);
                blocks.Add(bd);
            }
            d["varBlocks"] = blocks;
            if (Type != null)
            {
                OrderedDictionary td = new OrderedDictionary();
                td["kind"] = Type.Kind; td["name"] = Type.Name; td["extends"] = Type.Extends; td["baseType"] = Type.BaseType; td["default"] = Type.DefaultText;
                td["members"] = VarsToList(Type.Members);
                ArrayList em = new ArrayList();
                foreach (EnumMember m in Type.EnumMembers) { OrderedDictionary md = new OrderedDictionary(); md["name"] = m.Name; md["value"] = m.ValueText; em.Add(md); }
                td["enumMembers"] = em;
                d["type"] = td;
            }
            return d;
        }

        private static ArrayList VarsToList(List<VarDecl> vars)
        {
            ArrayList list = new ArrayList();
            foreach (VarDecl v in vars)
            {
                OrderedDictionary vd = new OrderedDictionary();
                vd["names"] = new ArrayList(v.Names); vd["address"] = v.Address; vd["type"] = v.TypeText; vd["init"] = v.InitText;
                vd["line"] = v.Line; vd["attributes"] = new ArrayList(v.Attributes);
                list.Add(vd);
            }
            return list;
        }
    }

    public sealed class CallSite
    {
        public string Target;
        public int Line;
        public int Col;
        public bool StatementStart;
        public string Blocks;       // enclosing blocks, outermost first, e.g. "IF:then>CASE:label"
        public string FramePath;    // same with block identity, e.g. "IF@3:1|elsif#2>CASE@5:5|label#1" (not in the output; mutual exclusion)
        public bool Conditional;    // inside IF / CASE / loop / __CATCH / __FINALLY
        public bool InPragma;       // inside a {IF ...} ... {END_IF} conditional-compilation region (may not be compiled)

        // tasks 2.3 (design.md D3): "body" = name( ... ) - an FB instance body, a function, a PROGRAM or SUPER^( ) (which one
        // needs the type index, not the scanner); "member" = x.M( ... ) - a method, an action or a property-like member.
        public string Form { get { return Target != null && Target.IndexOf('.') >= 0 ? "member" : "body"; } }
        // a call that starts a statement discards a return value; one inside an expression (x := f(), IF fb.M() THEN) uses it
        public bool ReturnValueUsed { get { return !StatementStart; } }
        // inherited-use: the call goes to the base FB explicitly (SUPER^( ) / SUPER^.M( )); an inherited member called without
        // SUPER^ is only known with the EXTENDS chain of the type index (rules of tasks 2.5)
        public bool ViaSuper { get { return Target != null && Target.StartsWith("SUPER^", StringComparison.OrdinalIgnoreCase); } }
    }

    public sealed class ScanResult
    {
        public SectionStatus State = new SectionStatus();
        public List<CallSite> Calls = new List<CallSite>();
        public List<string> IdentifierRefs = new List<string>();
        public List<string> MemberAccesses = new List<string>();
        public int LineCount;
        public LexResult Lex;

        public OrderedDictionary ToDictionary()
        {
            OrderedDictionary d = new OrderedDictionary();
            State.AddTo(d);
            ArrayList calls = new ArrayList();
            foreach (CallSite c in Calls)
            {
                OrderedDictionary cd = new OrderedDictionary();
                cd["target"] = c.Target; cd["line"] = c.Line; cd["column"] = c.Col; cd["statementStart"] = c.StatementStart;
                cd["inExpression"] = !c.StatementStart; cd["blocks"] = c.Blocks; cd["conditional"] = c.Conditional;
                cd["form"] = c.Form; cd["returnValueUsed"] = c.ReturnValueUsed; cd["viaSuper"] = c.ViaSuper;
                calls.Add(cd);
            }
            d["calls"] = calls;
            d["identifierRefs"] = new ArrayList(IdentifierRefs);
            d["memberAccesses"] = new ArrayList(MemberAccesses);
            return d;
        }
    }

    public static class StAnalyzer
    {
        private static readonly HashSet<string> VarKeywords = new HashSet<string>(StringComparer.Ordinal) {
            "VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR_GLOBAL", "VAR_TEMP", "VAR_STAT", "VAR_INST", "VAR_EXTERNAL", "VAR_CONFIG", "VAR_GENERIC" };
        private static readonly HashSet<string> VarQualifiers = new HashSet<string>(StringComparer.Ordinal) { "CONSTANT", "RETAIN", "PERSISTENT" };
        private static readonly HashSet<string> HeaderKeywords = new HashSet<string>(StringComparer.Ordinal) {
            "PROGRAM", "FUNCTION_BLOCK", "FUNCTION", "METHOD", "PROPERTY", "INTERFACE" };
        private static readonly HashSet<string> Modifiers = new HashSet<string>(StringComparer.Ordinal) {
            "PUBLIC", "PRIVATE", "PROTECTED", "INTERNAL", "ABSTRACT", "FINAL" };

        // ================================================================ declaration
        public static DeclInfo ParseDeclaration(string text)
        {
            DeclInfo d = new DeclInfo();
            LexResult lx = StLexer.Lex(text);
            d.Lex = lx;
            if (lx.Error != null)
            {
                ApplyLexError(d.State, lx);
                return d;
            }
            Cursor c = new Cursor(lx.Tokens);
            int firstConditional = FirstConditionalPragma(lx.Tokens);
            try
            {
                ParseDeclTokens(c, d, firstConditional);
            }
            catch (StopParse) { }
            // unknown constructs anywhere: the declaration is not analysed and structural errors are ours (D3)
            ApplyLexIssues(d.State, lx);
            foreach (List<LexIssue> issues in new List<LexIssue>[] { lx.Unverified, lx.Unknown })
            {
                if (!d.HeaderKnown || issues.Count == 0 || d.Name == null) continue;
                LexIssue u = issues[0];
                if (u.Line < d.NameLine || (u.Line == d.NameLine && u.Col <= d.NameCol)) d.HeaderKnown = false;
            }
            return d;
        }

        private sealed class StopParse : Exception { }

        private sealed class Cursor
        {
            private readonly List<Token> t;
            public int Pos;
            public Cursor(List<Token> tokens) { t = tokens; }
            public Token Peek() { return t[Pos]; }
            public Token PeekAt(int k) { int p = Pos + k; return p < t.Count ? t[p] : t[t.Count - 1]; }
            public Token Next() { Token x = t[Pos]; if (Pos < t.Count - 1) Pos++; return x; }
            public bool AtEnd { get { return t[Pos].Kind == TokKind.EOF; } }
            public int Index(Token x) { return t.IndexOf(x); }
        }

        private static int FirstConditionalPragma(List<Token> tokens)
        {
            for (int i = 0; i < tokens.Count; i++)
            {
                Token x = tokens[i];
                if (x.Kind == TokKind.Pragma && IsConditional(x.Text)) return i;
            }
            return int.MaxValue;
        }

        public static bool IsConditional(string pragma)
        {
            string inner = pragma.Substring(1).TrimStart();
            string up = inner.ToUpperInvariant();
            return StartsWord(up, "IF") || StartsWord(up, "ELSIF") || StartsWord(up, "ELSE") || StartsWord(up, "END_IF");
        }

        private static bool StartsWord(string s, string w)
        {
            if (!s.StartsWith(w, StringComparison.Ordinal)) return false;
            return s.Length == w.Length || !(char.IsLetterOrDigit(s[w.Length]) || s[w.Length] == '_');
        }

        private static void SkipPragmas(Cursor c, List<string> into)
        {
            while (c.Peek().Kind == TokKind.Pragma) { Token p = c.Next(); if (into != null) into.Add(p.Text); }
        }

        private static void ParseDeclTokens(Cursor c, DeclInfo d, int firstConditional)
        {
            SkipPragmas(c, d.Attributes);
            Token t = c.Peek();
            if (t.Kind == TokKind.EOF) { d.HeaderKeyword = ""; d.HeaderKnown = true; return; }
            if (t.Kind != TokKind.Ident) { d.State.NotAnalyzed("unsupported-syntax:declaration-start", t.Line, t.Col); return; }
            bool headerBeforeConditional = c.Pos < firstConditional;
            if (HeaderKeywords.Contains(t.Upper))
            {
                c.Next();
                d.HeaderKeyword = t.Upper;
                while (c.Peek().Kind == TokKind.Ident && Modifiers.Contains(c.Peek().Upper)) d.Modifiers.Add(c.Next().Upper);
                SkipPragmas(c, d.Attributes);
                Token name = c.Peek();
                if (name.Kind != TokKind.Ident || StLexer.Keywords.Contains(name.Upper))
                {
                    d.State.NotAnalyzed("unsupported-syntax:header-name", name.Line, name.Col);
                    return;
                }
                c.Next();
                d.Name = name.Text; d.NameLine = name.Line; d.NameCol = name.Col;
                d.HeaderKnown = headerBeforeConditional;
                // EXTENDS / IMPLEMENTS / return type, in any order, until the first VAR section
                while (!c.AtEnd)
                {
                    Token x = c.Peek();
                    if (x.Kind == TokKind.Pragma) { c.Next(); continue; }
                    if (x.Kind == TokKind.Ident && VarKeywords.Contains(x.Upper)) break;
                    if (x.Is("EXTENDS")) { c.Next(); ReadNameList(c, d.Extends); continue; }
                    if (x.Is("IMPLEMENTS")) { c.Next(); ReadNameList(c, d.Implements); continue; }
                    if (x.IsOp(":"))
                    {
                        c.Next();
                        d.ReturnType = ReadUntil(c, delegate (Token y) { return y.Kind == TokKind.EOF || y.IsOp(";") || (y.Kind == TokKind.Ident && VarKeywords.Contains(y.Upper)); });
                        continue;
                    }
                    if (x.IsOp(";")) { c.Next(); continue; }
                    d.State.NotAnalyzed("unsupported-syntax:header", x.Line, x.Col);
                    return;
                }
                ParseVarBlocks(c, d);
                return;
            }
            if (t.Is("TYPE"))
            {
                c.Next();
                d.HeaderKeyword = "TYPE";
                ParseType(c, d, headerBeforeConditional);
                if (d.State.Status != "ok") return;
                // anything after END_TYPE except pragmas / ';'
                while (!c.AtEnd)
                {
                    Token x = c.Peek();
                    if (x.Kind == TokKind.Pragma || x.IsOp(";")) { c.Next(); continue; }
                    d.State.NotAnalyzed("unsupported-syntax:after-end-type", x.Line, x.Col);
                    return;
                }
                return;
            }
            if (Modifiers.Contains(t.Upper))
            {
                // Property accessor (Get / Set): access modifier, then only VAR sections (XAE 4024 / 4026,
                // verification/xae-generated-xml.md)
                int save = c.Pos;
                List<string> mods = new List<string>();
                while (c.Peek().Kind == TokKind.Ident && Modifiers.Contains(c.Peek().Upper)) mods.Add(c.Next().Upper);
                SkipPragmas(c, d.Attributes);
                if (c.AtEnd || (c.Peek().Kind == TokKind.Ident && VarKeywords.Contains(c.Peek().Upper)))
                {
                    d.HeaderKeyword = "ACCESSOR"; d.Modifiers.AddRange(mods); d.HeaderKnown = headerBeforeConditional;
                    ParseVarBlocks(c, d);
                    return;
                }
                c.Pos = save;
            }
            if (VarKeywords.Contains(t.Upper))
            {
                d.HeaderKeyword = t.Upper;
                d.HeaderKnown = headerBeforeConditional;
                ParseVarBlocks(c, d);
                return;
            }
            d.State.NotAnalyzed("unsupported-syntax:declaration-start", t.Line, t.Col);
        }

        private static void ReadNameList(Cursor c, List<string> into)
        {
            while (true)
            {
                SkipPragmas(c, null);
                Token x = c.Peek();
                if (x.Kind != TokKind.Ident || StLexer.Keywords.Contains(x.Upper)) return;
                StringBuilder sb = new StringBuilder(c.Next().Text);
                while (c.Peek().IsOp(".") && c.PeekAt(1).Kind == TokKind.Ident) { c.Next(); sb.Append('.').Append(c.Next().Text); }
                into.Add(sb.ToString());
                if (c.Peek().IsOp(",")) { c.Next(); continue; }
                return;
            }
        }

        private delegate bool TokPred(Token t);

        private static readonly HashSet<string> TypeJoiners = new HashSet<string>(StringComparer.Ordinal) { "OF", "TO", "POINTER", "REFERENCE", "ARRAY" };

        private static bool IsOperand(Token t)
        {
            if (t.Kind == TokKind.Number || t.Kind == TokKind.TypedLiteral || t.Kind == TokKind.String || t.Kind == TokKind.WString) return true;
            if (t.Kind != TokKind.Ident) return false;
            string u = t.Upper;
            return u != "AND" && u != "OR" && u != "XOR" && u != "NOT" && u != "MOD" && u != "AND_THEN" && u != "OR_ELSE";
        }

        private static string ReadUntil(Cursor c, TokPred stop)
        {
            StringBuilder sb = new StringBuilder();
            while (!stop(c.Peek()))
            {
                Token x = c.Next();
                if (x.Kind == TokKind.Pragma) continue;
                if (sb.Length > 0 && NeedsSpace(sb[sb.Length - 1], x.Text)) sb.Append(' ');
                sb.Append(x.Text);
                if (x.Kind == TokKind.EOF) break;
            }
            return sb.ToString();
        }

        private static bool NeedsSpace(char prev, string next)
        {
            if (next.Length == 0) return false;
            bool a = char.IsLetterOrDigit(prev) || prev == '_' || prev == '\'' || prev == '"';
            bool b = char.IsLetterOrDigit(next[0]) || next[0] == '_' || next[0] == '\'' || next[0] == '"' || next[0] == '%';
            return a && b;
        }

        private static void ParseVarBlocks(Cursor c, DeclInfo d)
        {
            while (true)
            {
                List<string> attrs = new List<string>();
                SkipPragmas(c, attrs);
                Token t = c.Peek();
                if (t.Kind == TokKind.EOF) return;
                if (t.IsOp(";")) { c.Next(); continue; }
                if (t.Kind == TokKind.Ident && VarKeywords.Contains(t.Upper))
                {
                    c.Next();
                    VarBlock b = new VarBlock(); b.Kind = t.Upper; b.Line = t.Line;
                    while (c.Peek().Kind == TokKind.Ident && VarQualifiers.Contains(c.Peek().Upper)) b.Qualifiers.Add(c.Next().Upper);
                    d.VarBlocks.Add(b);
                    if (!ParseVarList(c, d.State, b.Vars, "END_VAR", t)) return;
                    continue;
                }
                if (t.Is("END_VAR"))
                {
                    d.State.Fail("LINT-PARSE-003", "END_VAR without a VAR section", t.Line, t.Col);
                    return;
                }
                d.State.NotAnalyzed("unsupported-syntax:declaration", t.Line, t.Col);
                return;
            }
        }

        // Reads variable lines until 'endKeyword'. false = stop parsing (state already set).
        private static bool ParseVarList(Cursor c, SectionStatus st, List<VarDecl> into, string endKeyword, Token opener)
        {
            while (true)
            {
                List<string> attrs = new List<string>();
                SkipPragmas(c, attrs);
                Token t = c.Peek();
                if (t.Kind == TokKind.EOF)
                {
                    st.Fail("LINT-PARSE-003", opener.Upper + " section without " + endKeyword, opener.Line, opener.Col);
                    return false;
                }
                if (t.Is(endKeyword)) { c.Next(); return true; }
                if (t.Kind == TokKind.Ident && (VarKeywords.Contains(t.Upper) || t.Is("END_VAR") || t.Is("END_STRUCT") || t.Is("END_UNION") || t.Is("END_TYPE")))
                {
                    st.Fail("LINT-PARSE-003", opener.Upper + " section without " + endKeyword, opener.Line, opener.Col);
                    return false;
                }
                if (t.IsOp(";")) { c.Next(); continue; }
                if (t.Kind != TokKind.Ident || StLexer.Keywords.Contains(t.Upper))
                {
                    st.NotAnalyzed("unsupported-syntax:var-declaration", t.Line, t.Col);
                    return false;
                }
                VarDecl v = new VarDecl(); v.Line = t.Line; v.Col = t.Col; v.Attributes = attrs;
                // names (VAR_CONFIG uses dotted instance paths)
                while (true)
                {
                    Token n = c.Next();
                    StringBuilder sb = new StringBuilder(n.Text);
                    while (c.Peek().IsOp(".") && c.PeekAt(1).Kind == TokKind.Ident) { c.Next(); sb.Append('.').Append(c.Next().Text); }
                    v.Names.Add(sb.ToString());
                    if (c.Peek().IsOp(",") && c.PeekAt(1).Kind == TokKind.Ident) { c.Next(); continue; }
                    break;
                }
                if (c.Peek().Is("AT"))
                {
                    c.Next();
                    Token a = c.Peek();
                    if (a.Kind == TokKind.Address) { c.Next(); v.Address = a.Text; }
                    else { st.NotAnalyzed("unsupported-syntax:at-address", a.Line, a.Col); return false; }
                }
                if (!c.Peek().IsOp(":"))
                {
                    Token x = c.Peek();
                    st.NotAnalyzed("unsupported-syntax:var-declaration", x.Line, x.Col);
                    return false;
                }
                c.Next();
                // type [:= init] ; at depth 0
                StringBuilder type = new StringBuilder(), init = null;
                int depth = 0;
                Token prevType = null;
                while (true)
                {
                    Token x = c.Peek();
                    if (x.Kind == TokKind.EOF || (depth == 0 && x.Kind == TokKind.Ident && (x.Is(endKeyword) || VarKeywords.Contains(x.Upper) || x.Is("END_VAR"))))
                    {
                        // missing ';' before END_VAR: not certainly illegal for us -> not analysed
                        st.NotAnalyzed("unsupported-syntax:missing-semicolon", x.Line, x.Col);
                        return false;
                    }
                    c.Next();
                    if (x.Kind == TokKind.Pragma) continue;
                    if (x.IsOp("(") || x.IsOp("[")) depth++;
                    else if (x.IsOp(")") || x.IsOp("]")) depth--;
                    if (depth == 0 && x.IsOp(";")) break;
                    if (depth == 0 && init == null && x.IsOp(":=")) { init = new StringBuilder(); continue; }
                    if (init == null && depth == 0)
                    {
                        // 'INT b BOOL' (missing ';' and ':'): two names in a row are only legal after OF / TO /
                        // POINTER / REFERENCE (ARRAY[..] OF T, POINTER TO T, REFERENCE TO T)
                        if (prevType != null && IsOperand(prevType) && IsOperand(x) && !TypeJoiners.Contains(prevType.Upper) && !TypeJoiners.Contains(x.Upper))
                        {
                            st.NotAnalyzed("unsupported-syntax:var-type", x.Line, x.Col);
                            return false;
                        }
                        prevType = x;
                    }
                    StringBuilder target = init ?? type;
                    if (target.Length > 0 && NeedsSpace(target[target.Length - 1], x.Text)) target.Append(' ');
                    target.Append(x.Text);
                }
                v.TypeText = type.ToString();
                v.InitText = init == null ? null : init.ToString();
                into.Add(v);
            }
        }

        private static void ParseType(Cursor c, DeclInfo d, bool headerBeforeConditional)
        {
            SkipPragmas(c, d.Attributes);
            Token name = c.Peek();
            if (name.Kind != TokKind.Ident || StLexer.Keywords.Contains(name.Upper)) { d.State.NotAnalyzed("unsupported-syntax:type-name", name.Line, name.Col); return; }
            c.Next();
            TypeDef td = new TypeDef(); td.Name = name.Text; d.Type = td;
            d.Name = name.Text; d.NameLine = name.Line; d.NameCol = name.Col; d.HeaderKnown = headerBeforeConditional;
            if (c.Peek().Is("EXTENDS")) { c.Next(); List<string> ex = new List<string>(); ReadNameList(c, ex); td.Extends = ex.Count > 0 ? ex[0] : null; d.Extends.AddRange(ex); }
            SkipPragmas(c, null);
            if (!c.Peek().IsOp(":")) { Token x = c.Peek(); d.State.NotAnalyzed("unsupported-syntax:type", x.Line, x.Col); return; }
            c.Next();
            SkipPragmas(c, null);
            Token k = c.Peek();
            if (k.Is("STRUCT") || k.Is("UNION"))
            {
                c.Next();
                td.Kind = k.Upper;
                if (!ParseVarList(c, d.State, td.Members, "END_" + k.Upper, k)) return;
                while (c.Peek().IsOp(";") || c.Peek().Kind == TokKind.Pragma) c.Next();
            }
            else if (k.IsOp("("))
            {
                c.Next();
                td.Kind = "ENUM";
                while (true)
                {
                    SkipPragmas(c, null);
                    Token m = c.Peek();
                    if (m.IsOp(")")) { c.Next(); break; }
                    if (m.Kind != TokKind.Ident) { d.State.NotAnalyzed("unsupported-syntax:enum-member", m.Line, m.Col); return; }
                    c.Next();
                    EnumMember em = new EnumMember(); em.Name = m.Text; em.Line = m.Line;
                    if (c.Peek().IsOp(":="))
                    {
                        c.Next();
                        int depth = 0; StringBuilder sb = new StringBuilder(); Token prevVal = null;
                        while (true)
                        {
                            Token x = c.Peek();
                            if (x.Kind == TokKind.EOF) { d.State.Fail("LINT-PARSE-003", "enumeration without ')'", k.Line, k.Col); return; }
                            if (depth == 0 && (x.IsOp(",") || x.IsOp(")"))) break;
                            if (prevVal != null && IsOperand(prevVal) && IsOperand(x)) { d.State.NotAnalyzed("unsupported-syntax:enum-value", x.Line, x.Col); return; }
                            if (x.Kind != TokKind.Pragma) prevVal = x;
                            c.Next();
                            if (x.IsOp("(")) depth++; else if (x.IsOp(")")) depth--;
                            if (sb.Length > 0 && NeedsSpace(sb[sb.Length - 1], x.Text)) sb.Append(' ');
                            sb.Append(x.Text);
                        }
                        em.ValueText = sb.ToString();
                    }
                    td.EnumMembers.Add(em);
                    SkipPragmas(c, null);
                    if (c.Peek().IsOp(",")) { c.Next(); continue; }
                    if (c.Peek().IsOp(")")) { c.Next(); break; }
                    Token y = c.Peek();
                    if (y.Kind == TokKind.EOF) { d.State.Fail("LINT-PARSE-003", "enumeration without ')'", k.Line, k.Col); return; }
                    d.State.NotAnalyzed("unsupported-syntax:enum", y.Line, y.Col);
                    return;
                }
                if (c.Peek().Kind == TokKind.Ident && !c.Peek().Is("END_TYPE")) td.BaseType = c.Next().Text;
                if (c.Peek().IsOp(":="))
                {
                    c.Next();
                    td.DefaultText = ReadUntil(c, delegate (Token y) { return y.Kind == TokKind.EOF || y.IsOp(";") || y.Is("END_TYPE"); });
                }
                while (c.Peek().IsOp(";") || c.Peek().Kind == TokKind.Pragma) c.Next();
            }
            else
            {
                td.Kind = "ALIAS";
                td.BaseType = ReadUntil(c, delegate (Token y) { return y.Kind == TokKind.EOF || y.IsOp(";") || y.Is("END_TYPE"); });
                while (c.Peek().IsOp(";") || c.Peek().Kind == TokKind.Pragma) c.Next();
            }
            Token e = c.Peek();
            if (e.Is("END_TYPE")) { c.Next(); return; }
            if (e.Kind == TokKind.EOF) { d.State.Fail("LINT-PARSE-003", "TYPE without END_TYPE", k.Line, k.Col); return; }
            d.State.NotAnalyzed("unsupported-syntax:type", e.Line, e.Col);
        }

        // ================================================================ implementation
        private sealed class Frame
        {
            public string Kind;    // IF CASE FOR WHILE REPEAT TRY
            public string Branch;  // then elsif else label case-else body until try catch finally
            public Token Opener;
            public int Index;      // ELSIF / CASE label number inside this block
        }

        private static readonly Dictionary<string, string> Closers = new Dictionary<string, string>(StringComparer.Ordinal) {
            { "END_IF", "IF" }, { "END_CASE", "CASE" }, { "END_FOR", "FOR" }, { "END_WHILE", "WHILE" }, { "END_REPEAT", "REPEAT" }, { "__ENDTRY", "TRY" } };

        public static ScanResult ScanImplementation(string text)
        {
            ScanResult r = new ScanResult();
            r.LineCount = CountLines(text);
            LexResult lx = StLexer.Lex(text);
            r.Lex = lx;
            if (lx.Error != null)
            {
                ApplyLexError(r.State, lx);
                return r;
            }
            ApplyLexIssues(r.State, lx);

            List<Token> t = lx.Tokens;
            List<Frame> stack = new List<Frame>();
            HashSet<string> refs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            HashSet<string> members = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            bool stmtStart = true;
            int i = 0;
            int pragmaDepth = 0;
            while (i < t.Count && t[i].Kind != TokKind.EOF)
            {
                Token x = t[i];
                if (x.Kind == TokKind.Pragma) { pragmaDepth = PragmaDepth(x.Text, pragmaDepth); i++; continue; }
                if (x.Kind == TokKind.Ident)
                {
                    string u = x.Upper;
                    switch (u)
                    {
                        case "IF": Push(stack, "IF", "then", x); stmtStart = false; i++; continue;
                        case "THEN": stmtStart = true; i++; continue;
                        case "ELSIF":
                            if (Top(stack) != "IF") { r.State.Fail("LINT-PARSE-002", "ELSIF outside an IF block", x.Line, x.Col); }
                            else { stack[stack.Count - 1].Branch = "elsif"; stack[stack.Count - 1].Index++; }
                            stmtStart = false; i++; continue;
                        case "ELSE":
                            if (Top(stack) == "IF") stack[stack.Count - 1].Branch = "else";
                            else if (Top(stack) == "CASE") stack[stack.Count - 1].Branch = "case-else";
                            else r.State.Fail("LINT-PARSE-002", "ELSE outside an IF or CASE block", x.Line, x.Col);
                            stmtStart = true; i++; continue;
                        case "CASE": Push(stack, "CASE", "selector", x); stmtStart = false; i++; continue;
                        case "OF":
                            if (Top(stack) == "CASE") stack[stack.Count - 1].Branch = "label";
                            stmtStart = true; i++; continue;
                        case "FOR": Push(stack, "FOR", "header", x); stmtStart = false; i++; continue;
                        case "WHILE": Push(stack, "WHILE", "header", x); stmtStart = false; i++; continue;
                        case "DO":
                            if (Top(stack) == "FOR" || Top(stack) == "WHILE") stack[stack.Count - 1].Branch = "body";
                            stmtStart = true; i++; continue;
                        case "REPEAT": Push(stack, "REPEAT", "body", x); stmtStart = true; i++; continue;
                        case "UNTIL":
                            if (Top(stack) != "REPEAT") r.State.Fail("LINT-PARSE-002", "UNTIL outside a REPEAT block", x.Line, x.Col);
                            else stack[stack.Count - 1].Branch = "until";
                            stmtStart = false; i++; continue;
                        case "__TRY": Push(stack, "TRY", "try", x); stmtStart = true; i++; continue;
                        case "__CATCH":
                            if (Top(stack) != "TRY") r.State.Fail("LINT-PARSE-002", "__CATCH outside a __TRY block", x.Line, x.Col);
                            else stack[stack.Count - 1].Branch = "catch";
                            i++;
                            if (i < t.Count && t[i].IsOp("("))
                            {
                                int depth = 0;
                                while (i < t.Count && t[i].Kind != TokKind.EOF)
                                {
                                    if (t[i].IsOp("(")) depth++;
                                    else if (t[i].IsOp(")")) { depth--; if (depth == 0) { i++; break; } }
                                    i++;
                                }
                            }
                            stmtStart = true; continue;
                        case "__FINALLY":
                            if (Top(stack) != "TRY") r.State.Fail("LINT-PARSE-002", "__FINALLY outside a __TRY block", x.Line, x.Col);
                            else stack[stack.Count - 1].Branch = "finally";
                            stmtStart = true; i++; continue;
                    }
                    string opener;
                    if (Closers.TryGetValue(u, out opener))
                    {
                        if (Top(stack) != opener)
                        {
                            string msg = stack.Count == 0 ? u + " without an open " + opener + " block"
                                : u + " closes a " + Top(stack) + " block opened at line " + Inv.S(stack[stack.Count - 1].Opener.Line);
                            r.State.Fail("LINT-PARSE-002", msg, x.Line, x.Col);
                        }
                        else stack.RemoveAt(stack.Count - 1);
                        stmtStart = true; i++; continue;
                    }
                    if (StLexer.Keywords.Contains(u) && u != "THIS" && u != "SUPER")
                    {
                        // RETURN / EXIT / CONTINUE / JMP / operators / literals
                        stmtStart = false; i++; continue;
                    }
                    // designator: ident ( . ident | ^ | [ ... ] )*
                    int start = i;
                    StringBuilder target = new StringBuilder(x.Text);
                    refs.Add(x.Text);
                    i++;
                    while (i < t.Count)
                    {
                        if (t[i].IsOp("^")) { target.Append('^'); i++; continue; }
                        if (t[i].IsOp(".") && i + 1 < t.Count && t[i + 1].Kind == TokKind.Ident)
                        {
                            members.Add(target.ToString() + "." + t[i + 1].Text);
                            target.Append('.').Append(t[i + 1].Text);
                            i += 2; continue;
                        }
                        if (t[i].IsOp("["))
                        {
                            // the index expression is consumed here (the designator continues after ']'):
                            // identifiers inside it are references, 'name(' / 'a.b(' inside it are calls in an expression
                            int depth = 0, k = i;
                            while (k < t.Count && t[k].Kind != TokKind.EOF)
                            {
                                if (t[k].IsOp("[")) depth++;
                                else if (t[k].IsOp("]")) { depth--; if (depth == 0) break; }
                                else if (t[k].Kind == TokKind.Ident && !StLexer.Keywords.Contains(t[k].Upper))
                                {
                                    refs.Add(t[k].Text);
                                    int m = k; StringBuilder inner = new StringBuilder(t[k].Text);
                                    while (m + 2 < t.Count && t[m + 1].IsOp(".") && t[m + 2].Kind == TokKind.Ident) { inner.Append('.').Append(t[m + 2].Text); members.Add(inner.ToString()); m += 2; }
                                    if (m + 1 < t.Count && t[m + 1].IsOp("("))
                                    {
                                        CallSite ic = new CallSite();
                                        ic.Target = inner.ToString(); ic.Line = t[k].Line; ic.Col = t[k].Col; ic.StatementStart = false;
                                        ic.Blocks = BlockPath(stack); ic.Conditional = IsConditional(stack); ic.FramePath = FramePathOf(stack); ic.InPragma = pragmaDepth > 0;
                                        r.Calls.Add(ic);
                                    }
                                    k = m;
                                }
                                k++;
                            }
                            if (k >= t.Count || t[k].Kind == TokKind.EOF) { i = k; break; }
                            target.Append("[]");
                            i = k + 1; continue;
                        }
                        break;
                    }
                    if (i < t.Count && t[i].IsOp("("))
                    {
                        CallSite cs = new CallSite();
                        cs.Target = target.ToString(); cs.Line = x.Line; cs.Col = x.Col; cs.StatementStart = stmtStart;
                        cs.Blocks = BlockPath(stack); cs.Conditional = IsConditional(stack); cs.FramePath = FramePathOf(stack); cs.InPragma = pragmaDepth > 0;
                        r.Calls.Add(cs);
                    }
                    stmtStart = false;
                    if (start == i) i++;
                    continue;
                }
                if (x.Kind == TokKind.Op)
                {
                    // ':' inside CASE ends a label list: the next statements belong to a new label
                    if (x.Text == ":" && Top(stack) == "CASE") stack[stack.Count - 1].Index++;
                    if (x.Text == ";" || x.Text == ":") stmtStart = true;
                    else stmtStart = false;
                    i++; continue;
                }
                stmtStart = false;
                i++;
            }
            if (stack.Count > 0)
            {
                Frame f = stack[stack.Count - 1];
                r.State.Fail("LINT-PARSE-002", f.Opener.Upper + " block is never closed", f.Opener.Line, f.Opener.Col);
            }
            List<string> refList = new List<string>(refs); refList.Sort(StringComparer.OrdinalIgnoreCase);
            List<string> memList = new List<string>(members); memList.Sort(StringComparer.OrdinalIgnoreCase);
            r.IdentifierRefs = refList; r.MemberAccesses = memList;
            return r;
        }

        // A tokenizer error is a parse failure unless a listed construct (conditional pragma, unverified syntax) or
        // an unknown construct before it can explain it; Certain errors (backtick, typographic quote) never are.
        private static void ApplyLexError(SectionStatus st, LexResult lx)
        {
            LexIssue e = lx.Error;
            if (!e.Certain)
            {
                if (lx.Unknown.Count > 0 && Before(lx.Unknown[0], e)) { st.NotAnalyzed(lx.Unknown[0].Reason, lx.Unknown[0].Line, lx.Unknown[0].Col); return; }
                if (lx.ConditionalPragma && lx.ConditionalPragmaLine <= e.Line) { st.NotAnalyzed("conditional-pragma", lx.ConditionalPragmaLine, 1); return; }
                if (lx.Unverified.Count > 0 && Before(lx.Unverified[0], e)) { st.NotAnalyzed(lx.Unverified[0].Reason, lx.Unverified[0].Line, lx.Unverified[0].Col); return; }
            }
            st.Fail("LINT-PARSE-001", e.Reason, e.Line, e.Col);
        }

        private static void ApplyLexIssues(SectionStatus st, LexResult lx)
        {
            if (lx.Unknown.Count > 0) st.NotAnalyzed(lx.Unknown[0].Reason, lx.Unknown[0].Line, lx.Unknown[0].Col);
            else if (lx.ConditionalPragma) st.NotAnalyzed("conditional-pragma", lx.ConditionalPragmaLine, 1);
            else if (lx.Unverified.Count > 0) st.NotAnalyzed(lx.Unverified[0].Reason, lx.Unverified[0].Line, lx.Unverified[0].Col);
        }

        private static bool Before(LexIssue a, LexIssue b)
        {
            return a.Line < b.Line || (a.Line == b.Line && a.Col <= b.Col);
        }

        public static int CountLines(string text)
        {
            if (string.IsNullOrEmpty(text)) return 1;
            int n = 1;
            for (int i = 0; i < text.Length; i++)
            {
                if (text[i] == '\n') n++;
                else if (text[i] == '\r') { n++; if (i + 1 < text.Length && text[i + 1] == '\n') i++; }
            }
            return n;
        }

        private static void Push(List<Frame> stack, string kind, string branch, Token opener)
        {
            Frame f = new Frame(); f.Kind = kind; f.Branch = branch; f.Opener = opener; stack.Add(f);
        }

        private static string Top(List<Frame> stack) { return stack.Count == 0 ? null : stack[stack.Count - 1].Kind; }

        private static string BlockPath(List<Frame> stack)
        {
            StringBuilder sb = new StringBuilder();
            foreach (Frame f in stack) { if (sb.Length > 0) sb.Append('>'); sb.Append(f.Kind).Append(':').Append(f.Branch); }
            return sb.ToString();
        }

        // nesting depth of conditional-compilation pragmas ({IF} opens, {END_IF} closes; {ELSIF} / {ELSE} keep the depth)
        public static int PragmaDepth(string pragma, int depth)
        {
            if (!IsConditional(pragma)) return depth;
            string up = pragma.Substring(1).TrimStart().ToUpperInvariant();
            if (StartsWord(up, "END_IF")) return Math.Max(0, depth - 1);
            if (StartsWord(up, "IF")) return depth + 1;
            return depth;
        }

        // [line, col] ranges of conditional-compilation regions in a token list (pairs: start, end; end = int.MaxValue when not closed)
        public static List<int[]> PragmaRegions(List<Token> tokens)
        {
            List<int[]> r = new List<int[]>();
            int depth = 0; int[] open = null;
            foreach (Token x in tokens)
            {
                if (x.Kind != TokKind.Pragma) continue;
                int d = PragmaDepth(x.Text, depth);
                if (depth == 0 && d > 0) open = new int[] { x.Line, x.Col, int.MaxValue, int.MaxValue };
                if (depth > 0 && d == 0 && open != null) { open[2] = x.Line; open[3] = x.Col; r.Add(open); open = null; }
                depth = d;
            }
            if (open != null) r.Add(open);
            return r;
        }

        public static bool InRegion(List<int[]> regions, int line, int col)
        {
            foreach (int[] g in regions)
            {
                bool afterStart = line > g[0] || (line == g[0] && col >= g[1]);
                bool beforeEnd = line < g[2] || (line == g[2] && col <= g[3]);
                if (afterStart && beforeEnd) return true;
            }
            return false;
        }

        private static string FramePathOf(List<Frame> stack)
        {
            StringBuilder sb = new StringBuilder();
            foreach (Frame f in stack)
            {
                if (sb.Length > 0) sb.Append('>');
                sb.Append(f.Kind).Append('@').Append(Inv.S(f.Opener.Line)).Append(':').Append(Inv.S(f.Opener.Col)).Append('|').Append(f.Branch);
                if (f.Branch == "elsif" || f.Branch == "label") sb.Append('#').Append(Inv.S(f.Index));
            }
            return sb.ToString();
        }

        // two calls of one section are mutually exclusive when they sit in different branches of the same IF / CASE
        public static bool Exclusive(string a, string b)
        {
            string[] pa = (a ?? "").Split('>'), pb = (b ?? "").Split('>');
            if ((a ?? "").Length == 0 || (b ?? "").Length == 0) return false;
            int n = Math.Min(pa.Length, pb.Length);
            for (int i = 0; i < n; i++)
            {
                if (pa[i] == pb[i]) continue;
                int ka = pa[i].IndexOf('|'), kb = pb[i].IndexOf('|');
                if (ka < 0 || kb < 0 || pa[i].Substring(0, ka) != pb[i].Substring(0, kb)) return false;
                return pa[i].StartsWith("IF@", StringComparison.Ordinal) || pa[i].StartsWith("CASE@", StringComparison.Ordinal);
            }
            return false;
        }

        public static bool InLoop(string framePath)
        {
            foreach (string p in (framePath ?? "").Split('>'))
                if (p.StartsWith("FOR@", StringComparison.Ordinal) || p.StartsWith("WHILE@", StringComparison.Ordinal) || p.StartsWith("REPEAT@", StringComparison.Ordinal)) return true;
            return false;
        }

        private static bool IsConditional(List<Frame> stack)
        {
            foreach (Frame f in stack)
            {
                if (f.Kind == "TRY" && (f.Branch == "try" || f.Branch == "finally")) continue;   // __FINALLY always runs
                return true;
            }
            return false;
        }

        // ---------------------------------------------------------------- test entry points
        public static OrderedDictionary DescribeDeclaration(string text) { return ParseDeclaration(text).ToDictionary(); }
        public static OrderedDictionary DescribeImplementation(string text) { return ScanImplementation(text).ToDictionary(); }

        public static ArrayList DescribeTokens(string text)
        {
            LexResult lx = StLexer.Lex(text);
            ArrayList list = new ArrayList();
            foreach (Token x in lx.Tokens)
            {
                if (x.Kind == TokKind.EOF) continue;
                list.Add(x.Kind.ToString() + ":" + x.Text);
            }
            if (lx.Error != null) list.Add("ERROR:" + lx.Error.Reason);
            foreach (LexIssue u in lx.Unverified) list.Add("UNVERIFIED:" + u.Reason);
            foreach (LexIssue u in lx.Unknown) list.Add("UNKNOWN:" + u.Reason);
            foreach (LexIssue u in lx.Entities) list.Add("ENTITY:" + u.Reason);
            if (lx.ConditionalPragma) list.Add("CONDITIONAL");
            return list;
        }
    }
}
