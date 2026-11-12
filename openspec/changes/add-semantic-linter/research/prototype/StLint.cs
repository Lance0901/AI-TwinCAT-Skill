// Throwaway prototype for #252 design research. NOT product code.
// C# 5 only (Windows PowerShell 5.1 Add-Type uses the .NET Framework csc, C# 5).
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Xml;

namespace StLintProto
{
    public enum TokKind { Ident, Keyword, Number, TypedLiteral, String, WString, Op, Pragma, Address, Comment, EOF }

    public class Token
    {
        public TokKind Kind; public string Text; public int Line; public int Col;
        public override string ToString() { return Kind + ":" + Text + "@" + Line + ":" + Col; }
    }

    public class LexError : Exception
    {
        public int Line; public int Col;
        public LexError(string m, int l, int c) : base(m) { Line = l; Col = c; }
    }

    public static class Lexer
    {
        static readonly HashSet<string> Kw = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "PROGRAM","END_PROGRAM","FUNCTION_BLOCK","END_FUNCTION_BLOCK","FUNCTION","END_FUNCTION","METHOD","END_METHOD",
            "PROPERTY","END_PROPERTY","INTERFACE","END_INTERFACE","TYPE","END_TYPE","STRUCT","END_STRUCT","UNION","END_UNION",
            "VAR","VAR_INPUT","VAR_OUTPUT","VAR_IN_OUT","VAR_GLOBAL","VAR_TEMP","VAR_STAT","VAR_INST","VAR_EXTERNAL","VAR_CONFIG","END_VAR",
            "CONSTANT","RETAIN","PERSISTENT","AT","EXTENDS","IMPLEMENTS","ABSTRACT","FINAL","PUBLIC","PRIVATE","PROTECTED","INTERNAL",
            "IF","THEN","ELSIF","ELSE","END_IF","CASE","OF","END_CASE","FOR","TO","BY","DO","END_FOR","WHILE","END_WHILE",
            "REPEAT","UNTIL","END_REPEAT","RETURN","EXIT","CONTINUE","JMP","ARRAY","POINTER","REFERENCE","AND","OR","XOR","NOT","MOD",
            "AND_THEN","OR_ELSE","TRUE","FALSE","SUPER","THIS","ACTION","END_ACTION"
        };
        static readonly string[] Ops = { "**", ":=", "=>", "<>", "<=", ">=", "..", "^", "+", "-", "*", "/", "=", "<", ">", "(", ")", "[", "]", ",", ";", ":", ".", "#", "&" };

        public static List<Token> Lex(string s, bool keepComments)
        {
            var list = new List<Token>(s.Length / 4);
            int i = 0, line = 1, col = 1, n = s.Length;
            while (i < n)
            {
                char c = s[i];
                if (c == '\n') { i++; line++; col = 1; continue; }
                if (c == ' ' || c == '\t' || c == '\r' || c == '\f' || c == '﻿') { i++; col++; continue; }
                int sl = line, sc = col, st = i;
                // comments
                if (c == '/' && i + 1 < n && s[i + 1] == '/')
                {
                    while (i < n && s[i] != '\n') { i++; col++; }
                    if (keepComments) list.Add(new Token { Kind = TokKind.Comment, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                    continue;
                }
                if ((c == '(' && i + 1 < n && s[i + 1] == '*') || (c == '/' && i + 1 < n && s[i + 1] == '*'))
                {
                    bool paren = c == '(';
                    int depth = 1; i += 2; col += 2;
                    while (i < n && depth > 0)
                    {
                        if (paren && s[i] == '(' && i + 1 < n && s[i + 1] == '*') { depth++; i += 2; col += 2; continue; }
                        if (paren && s[i] == '*' && i + 1 < n && s[i + 1] == ')') { depth--; i += 2; col += 2; continue; }
                        if (!paren && s[i] == '*' && i + 1 < n && s[i + 1] == '/') { depth--; i += 2; col += 2; continue; }
                        if (s[i] == '\n') { line++; col = 1; i++; continue; }
                        i++; col++;
                    }
                    if (depth > 0) throw new LexError("unterminated block comment", sl, sc);
                    if (keepComments) list.Add(new Token { Kind = TokKind.Comment, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                    continue;
                }
                if (c == '{')
                {
                    int j = s.IndexOf('}', i);
                    if (j < 0) throw new LexError("unterminated pragma", sl, sc);
                    for (int k = i; k <= j; k++) { if (s[k] == '\n') { line++; col = 1; } else col++; }
                    list.Add(new Token { Kind = TokKind.Pragma, Text = s.Substring(i, j - i + 1), Line = sl, Col = sc });
                    i = j + 1; continue;
                }
                if (c == '\'' || c == '"')
                {
                    char q = c; i++; col++;
                    while (i < n && s[i] != q)
                    {
                        if (s[i] == '$' && i + 1 < n) { i += 2; col += 2; continue; }
                        if (s[i] == '\n') throw new LexError("newline in string", sl, sc);
                        i++; col++;
                    }
                    if (i >= n) throw new LexError("unterminated string", sl, sc);
                    i++; col++;
                    list.Add(new Token { Kind = q == '\'' ? TokKind.String : TokKind.WString, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                    continue;
                }
                if (c == '%')
                {
                    i++; col++;
                    while (i < n && (char.IsLetterOrDigit(s[i]) || s[i] == '.' || s[i] == '*')) { i++; col++; }
                    list.Add(new Token { Kind = TokKind.Address, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                    continue;
                }
                if (char.IsDigit(c))
                {
                    while (i < n && (char.IsLetterOrDigit(s[i]) || s[i] == '_' || s[i] == '#' ||
                        (s[i] == '.' && i + 1 < n && char.IsDigit(s[i + 1])) ||
                        ((s[i] == '+' || s[i] == '-') && (s[i - 1] == 'E' || s[i - 1] == 'e') && !s.Substring(st, i - st).Contains("#"))))
                    { i++; col++; }
                    list.Add(new Token { Kind = TokKind.Number, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                    continue;
                }
                if (char.IsLetter(c) || c == '_')
                {
                    while (i < n && (char.IsLetterOrDigit(s[i]) || s[i] == '_')) { i++; col++; }
                    string w = s.Substring(st, i - st);
                    // typed literal: T#1s, TIME#.., INT#5, 16#.. handled in number, DT#2020-01-01-00:00:00, TOD#12:00
                    if (i < n && s[i] == '#')
                    {
                        i++; col++;
                        if (i < n && (s[i] == '\'' || s[i] == '"')) { char q = s[i]; i++; col++; while (i < n && s[i] != q) { i++; col++; } i++; col++; }
                        else while (i < n && (char.IsLetterOrDigit(s[i]) || s[i] == '_' || s[i] == '.' || s[i] == ':' || s[i] == '-' || s[i] == '+' || s[i] == '#')) { i++; col++; }
                        list.Add(new Token { Kind = TokKind.TypedLiteral, Text = s.Substring(st, i - st), Line = sl, Col = sc });
                        continue;
                    }
                    list.Add(new Token { Kind = Kw.Contains(w) ? TokKind.Keyword : TokKind.Ident, Text = w, Line = sl, Col = sc });
                    continue;
                }
                bool matched = false;
                foreach (var op in Ops)
                {
                    if (string.CompareOrdinal(s, i, op, 0, op.Length) == 0)
                    {
                        list.Add(new Token { Kind = TokKind.Op, Text = op, Line = sl, Col = sc });
                        i += op.Length; col += op.Length; matched = true; break;
                    }
                }
                if (!matched) throw new LexError("unexpected char '" + c + "'", sl, sc);
            }
            list.Add(new Token { Kind = TokKind.EOF, Text = "", Line = line, Col = col });
            return list;
        }
    }

    public class VarDecl
    {
        public string Name; public string Section; public string TypeText; public string BaseType; public bool IsArray;
        public bool IsPointerOrRef; public string Init; public string At; public int Line; public List<string> Attributes = new List<string>();
    }

    public class DeclInfo
    {
        public string Kind; public string Name; public string Extends; public List<string> Implements = new List<string>();
        public string ReturnType; public List<VarDecl> Vars = new List<VarDecl>(); public bool IsTypeDecl;
        public List<string> EnumMembers = new List<string>(); public List<string> Attributes = new List<string>();
    }

    public class ParseError : Exception
    {
        public int Line; public int Col;
        public ParseError(string m, Token t) : base(m) { Line = t.Line; Col = t.Col; }
    }

    public class DeclParser
    {
        List<Token> t; int p;
        public DeclParser(List<Token> toks) { t = toks; p = 0; }
        Token Cur { get { return t[p]; } }
        bool Is(string text) { return string.Equals(Cur.Text, text, StringComparison.OrdinalIgnoreCase) && (Cur.Kind == TokKind.Keyword || Cur.Kind == TokKind.Op || Cur.Kind == TokKind.Ident); }
        void Expect(string text) { if (!Is(text)) throw new ParseError("expected '" + text + "' got '" + Cur.Text + "'", Cur); p++; }
        List<string> Pragmas() { var l = new List<string>(); while (Cur.Kind == TokKind.Pragma) { l.Add(Cur.Text); p++; } return l; }
        string Ident() { if (Cur.Kind != TokKind.Ident && Cur.Kind != TokKind.Keyword) throw new ParseError("expected identifier got '" + Cur.Text + "'", Cur); return t[p++].Text; }
        string QualIdent() { var sb = new StringBuilder(Ident()); while (Is(".")) { p++; sb.Append('.').Append(Ident()); } return sb.ToString(); }

        static readonly string[] Headers = { "PROGRAM", "FUNCTION_BLOCK", "FUNCTION", "METHOD", "PROPERTY", "INTERFACE", "TYPE", "ACTION" };
        static readonly string[] VarSections = { "VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR_GLOBAL", "VAR_TEMP", "VAR_STAT", "VAR_INST", "VAR_EXTERNAL", "VAR_CONFIG" };

        public DeclInfo Parse()
        {
            var d = new DeclInfo();
            d.Attributes = Pragmas();
            if (Cur.Kind == TokKind.EOF) { d.Kind = "EMPTY"; return d; }
            string h = Headers.FirstOrDefault(x => Is(x));
            if (h == null)
            {
                // GVL declaration starts directly with VAR_GLOBAL; transitions/actions may be empty.
                if (VarSections.Any(x => Is(x))) { d.Kind = "GVL"; ParseVarSections(d); Done(); return d; }
                throw new ParseError("unknown header '" + Cur.Text + "'", Cur);
            }
            p++; d.Kind = h.ToUpperInvariant();
            while (Is("PUBLIC") || Is("PRIVATE") || Is("PROTECTED") || Is("INTERNAL") || Is("ABSTRACT") || Is("FINAL")) p++;
            if (d.Kind == "TYPE") { ParseType(d); Done(); return d; }
            d.Name = Ident();
            if (Is("EXTENDS")) { p++; d.Extends = QualIdent(); while (Is(",")) { p++; QualIdent(); } }
            if (Is("IMPLEMENTS")) { p++; d.Implements.Add(QualIdent()); while (Is(",")) { p++; d.Implements.Add(QualIdent()); } }
            if (Is(":")) { p++; d.ReturnType = TypeSpec(); }
            ParseVarSections(d);
            Done();
            return d;
        }
        void Done()
        {
            Pragmas();
            if (Cur.Kind != TokKind.EOF) throw new ParseError("trailing tokens at '" + Cur.Text + "'", Cur);
        }
        void ParseVarSections(DeclInfo d)
        {
            while (true)
            {
                Pragmas();
                string sec = VarSections.FirstOrDefault(x => Is(x));
                if (sec == null) return;
                p++;
                while (Is("CONSTANT") || Is("RETAIN") || Is("PERSISTENT")) { sec += " " + Cur.Text.ToUpperInvariant(); p++; }
                while (true)
                {
                    var attrs = Pragmas();
                    if (Is("END_VAR")) { p++; break; }
                    ParseVarLine(d, sec, attrs);
                }
            }
        }
        void ParseVarLine(DeclInfo d, string sec, List<string> attrs)
        {
            int line = Cur.Line;
            var names = new List<string> { Ident() };
            while (Is(",")) { p++; names.Add(Ident()); }
            string at = null;
            if (Is("AT")) { p++; if (Cur.Kind != TokKind.Address) throw new ParseError("expected address", Cur); at = Cur.Text; p++; }
            Expect(":");
            int tstart = p;
            string type = TypeSpec();
            string init = null;
            if (Is(":=")) { p++; int s0 = p; SkipExpr(); init = Join(s0, p); }
            Expect(";");
            foreach (var nm in names)
            {
                var v = new VarDecl { Name = nm, Section = sec, TypeText = type, Init = init, At = at, Line = line, Attributes = attrs };
                v.IsArray = type.StartsWith("ARRAY", StringComparison.OrdinalIgnoreCase);
                v.IsPointerOrRef = type.StartsWith("POINTER", StringComparison.OrdinalIgnoreCase) || type.StartsWith("REFERENCE", StringComparison.OrdinalIgnoreCase);
                v.BaseType = BaseOf(type);
                d.Vars.Add(v);
            }
        }
        static string BaseOf(string type)
        {
            string s = type;
            int ofi = s.LastIndexOf(" OF ", StringComparison.OrdinalIgnoreCase);
            if (ofi >= 0) s = s.Substring(ofi + 4);
            int toi = s.LastIndexOf(" TO ", StringComparison.OrdinalIgnoreCase);
            if (toi >= 0 && (s.StartsWith("POINTER", StringComparison.OrdinalIgnoreCase) || s.StartsWith("REFERENCE", StringComparison.OrdinalIgnoreCase))) s = s.Substring(toi + 4);
            int paren = s.IndexOf('('); if (paren >= 0) s = s.Substring(0, paren);
            int br = s.IndexOf('['); if (br >= 0) s = s.Substring(0, br);
            return s.Trim();
        }
        string TypeSpec()
        {
            int s0 = p;
            if (Is("ARRAY"))
            {
                p++; Expect("["); int depth = 1;
                while (depth > 0) { if (Cur.Kind == TokKind.EOF) throw new ParseError("eof in array bounds", Cur); if (Is("[")) depth++; if (Is("]")) depth--; p++; }
                Expect("OF"); TypeSpec(); return Join(s0, p);
            }
            if (Is("POINTER") || Is("REFERENCE")) { p++; Expect("TO"); TypeSpec(); return Join(s0, p); }
            if (Is("(")) { // inline enum in var
                SkipParen(); if (Cur.Kind == TokKind.Ident) p++; return Join(s0, p);
            }
            QualIdent();
            if (Is("(") || Is("[")) { if (Is("(")) SkipParen(); else { int depth = 0; do { if (Is("[")) depth++; if (Is("]")) depth--; p++; } while (depth > 0); } }
            return Join(s0, p);
        }
        void SkipParen() { int depth = 0; do { if (Cur.Kind == TokKind.EOF) throw new ParseError("eof in parens", Cur); if (Is("(") || Is("[")) depth++; if (Is(")") || Is("]")) depth--; p++; } while (depth > 0); }
        void SkipExpr()
        {
            int depth = 0;
            while (true)
            {
                if (Cur.Kind == TokKind.EOF) throw new ParseError("eof in initializer", Cur);
                if (depth == 0 && Is(";")) return;
                if (Is("(") || Is("[")) depth++;
                if (Is(")") || Is("]")) depth--;
                if (Cur.Kind == TokKind.Keyword && (Is("END_VAR") || Is("END_STRUCT") || Is("END_TYPE"))) throw new ParseError("missing ';' before " + Cur.Text, Cur);
                p++;
            }
        }
        string Join(int a, int b) { var sb = new StringBuilder(); for (int k = a; k < b; k++) { if (k > a && NeedSpace(t[k - 1], t[k])) sb.Append(' '); sb.Append(t[k].Text); } return sb.ToString(); }
        static bool NeedSpace(Token a, Token b) { return (a.Kind == TokKind.Ident || a.Kind == TokKind.Keyword || a.Kind == TokKind.Number) && (b.Kind == TokKind.Ident || b.Kind == TokKind.Keyword || b.Kind == TokKind.Number); }
        void ParseType(DeclInfo d)
        {
            d.IsTypeDecl = true;
            d.Name = Ident();
            if (Is("EXTENDS")) { p++; d.Extends = QualIdent(); }
            Expect(":");
            if (Is("STRUCT") || Is("UNION"))
            {
                string endKw = Is("STRUCT") ? "END_STRUCT" : "END_UNION"; p++;
                d.Kind = endKw == "END_STRUCT" ? "STRUCT" : "UNION";
                while (true) { var a = Pragmas(); if (Is(endKw)) { p++; break; } ParseVarLine(d, "STRUCT", a); }
                if (Is(";")) p++;
            }
            else if (Is("("))
            {
                d.Kind = "ENUM"; p++;
                while (!Is(")"))
                {
                    Pragmas(); d.EnumMembers.Add(Ident());
                    if (Is(":=")) { p++; int s0 = p; while (!Is(",") && !Is(")")) { if (Cur.Kind == TokKind.EOF) throw new ParseError("eof in enum", Cur); p++; } d.EnumMembers[d.EnumMembers.Count - 1] += "=" + Join(s0, p); }
                    Pragmas(); if (Is(",")) p++;
                }
                p++;
                if (Cur.Kind == TokKind.Ident) p++; // base type
                if (Is(":=")) { p++; Ident(); }
                Expect(";");
            }
            else { d.Kind = "ALIAS"; d.ReturnType = TypeSpec(); if (Is(":=")) { p++; SkipExpr(); } Expect(";"); }
            Expect("END_TYPE");
        }
    }

    // Statement-level structure: block balance + call sites with conditional context.
    public class CallSite { public string Instance; public string Member; public int Line; public int Col; public int CondDepth; public int LoopDepth; public string Context; public int TopIfId = -1; public int TopBranch = -1; }
    public class IfBlock { public int Id; public int Branches = 1; public bool HasElse; }
    public class StmtInfo { public Dictionary<int, IfBlock> Ifs = new Dictionary<int, IfBlock>(); public List<CallSite> Calls = new List<CallSite>(); public HashSet<string> MemberRefs = new HashSet<string>(StringComparer.OrdinalIgnoreCase); public HashSet<string> IdentRefs = new HashSet<string>(StringComparer.OrdinalIgnoreCase); }

    public static class StmtScanner
    {
        static readonly Dictionary<string, string> Closers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
            {"IF","END_IF"},{"CASE","END_CASE"},{"FOR","END_FOR"},{"WHILE","END_WHILE"},{"REPEAT","END_REPEAT"} };

        public static StmtInfo Scan(List<Token> t)
        {
            var info = new StmtInfo();
            var stack = new Stack<Token>(); var ifStack = new Stack<IfBlock>();
            bool stmtStart = true;
            for (int i = 0; i < t.Count; i++)
            {
                var k = t[i];
                if (k.Kind == TokKind.EOF) break;
                if (k.Kind == TokKind.Pragma) continue;
                if (k.Kind == TokKind.Keyword)
                {
                    string u = k.Text.ToUpperInvariant();
                    if (Closers.ContainsKey(u)) { stack.Push(k); if (u == "IF") { var ib = new IfBlock { Id = info.Ifs.Count }; info.Ifs[ib.Id] = ib; ifStack.Push(ib); } stmtStart = u == "REPEAT"; continue; }
                    if ((u == "ELSIF" || u == "ELSE") && stack.Count > 0 && string.Equals(stack.Peek().Text, "IF", StringComparison.OrdinalIgnoreCase)) { var ib = ifStack.Peek(); ib.Branches++; if (u == "ELSE") ib.HasElse = true; }
                    if (u.StartsWith("END_") && Closers.ContainsValue(u))
                    {
                        if (stack.Count == 0) throw new ParseError("unbalanced " + u, k);
                        var open = stack.Pop(); if (string.Equals(open.Text, "IF", StringComparison.OrdinalIgnoreCase)) ifStack.Pop();
                        if (!string.Equals(Closers[open.Text.ToUpperInvariant()], u, StringComparison.OrdinalIgnoreCase)) throw new ParseError(u + " closes " + open.Text + "@" + open.Line, k);
                        // END_IF / END_CASE ... may be followed by the next statement without ';' (seen in corpus)
                        stmtStart = true; continue;
                    }
                    if (u == "THEN" || u == "ELSE" || u == "DO") { stmtStart = true; continue; }
                    if (u == "OF") { stmtStart = false; continue; }
                }
                if (k.Kind == TokKind.Op && k.Text == ";") { stmtStart = true; continue; }
                // CASE label "x:" or "1,2:" or "a..b:" -> after ':' (not ':=') at statement start inside CASE we begin a statement
                if (k.Kind == TokKind.Op && k.Text == ":" && stack.Count > 0 && string.Equals(stack.Peek().Text, "CASE", StringComparison.OrdinalIgnoreCase)) { stmtStart = true; continue; }
                if (k.Kind == TokKind.Ident || (k.Kind == TokKind.Keyword && (k.Text.Equals("THIS", StringComparison.OrdinalIgnoreCase) || k.Text.Equals("SUPER", StringComparison.OrdinalIgnoreCase))))
                {
                    if (k.Kind == TokKind.Ident) info.IdentRefs.Add(k.Text);
                    // collect designator a[...].b^.c
                    int j = i; var parts = new List<string> { k.Text };
                    j++;
                    while (j < t.Count)
                    {
                        if (t[j].Kind == TokKind.Op && t[j].Text == "[") { int d = 1; j++; while (j < t.Count && d > 0) { if (t[j].Text == "[") d++; else if (t[j].Text == "]") d--; else if (t[j].Kind == TokKind.Ident) info.IdentRefs.Add(t[j].Text); j++; } continue; }
                        if (t[j].Kind == TokKind.Op && t[j].Text == "^") { j++; continue; }
                        if (t[j].Kind == TokKind.Op && t[j].Text == "." && j + 1 < t.Count && (t[j + 1].Kind == TokKind.Ident || t[j + 1].Kind == TokKind.Keyword)) { parts.Add(t[j + 1].Text); j += 2; continue; }
                        break;
                    }
                    string root = parts[0];
                    if ((root.Equals("THIS", StringComparison.OrdinalIgnoreCase) || root.Equals("SUPER", StringComparison.OrdinalIgnoreCase)) && parts.Count > 1) { parts.RemoveAt(0); root = parts[0]; info.IdentRefs.Add(root); }
                    if (parts.Count > 1) info.MemberRefs.Add(root + "." + parts[1]);
                    bool isCall = j < t.Count && t[j].Kind == TokKind.Op && t[j].Text == "(" && stmtStart;
                    if (isCall)
                    {
                        int cond = 0, loop = 0; string ctx = "top";
                        foreach (var o in stack) { string u = o.Text.ToUpperInvariant(); if (u == "IF" || u == "CASE") cond++; else loop++; }
                        if (stack.Count > 0) ctx = string.Join(">", stack.Reverse().Select(x => x.Text.ToUpperInvariant() + "@" + x.Line).ToArray());
                        info.Calls.Add(new CallSite { Instance = root, Member = parts.Count > 1 ? parts[parts.Count - 1] : null, Line = k.Line, Col = k.Col, CondDepth = cond, LoopDepth = loop, Context = ctx, TopIfId = (stack.Count == 1 && ifStack.Count == 1) ? ifStack.Peek().Id : -1, TopBranch = (stack.Count == 1 && ifStack.Count == 1) ? ifStack.Peek().Branches - 1 : -1 });
                    }
                    stmtStart = false;
                    i = j - 1; continue;
                }
                stmtStart = false;
            }
            if (stack.Count > 0) throw new ParseError("unclosed " + stack.Peek().Text, stack.Peek());
            return info;
        }
    }

    // TwinCAT object extraction from XML
    public class Section { public string Owner; public string Kind; public string Name; public string Decl; public string Impl; public string ImplLang; public string Id; }
    public class TcObject
    {
        public string File; public string XmlKind; public string Name; public string Id; public List<Section> Sections = new List<Section>(); public string LoadError;
    }

    public static class TcXml
    {
        static readonly string[] Langs = { "ST", "NWL", "SFC", "CFC", "LD", "FBD", "IL" };
        public static TcObject Load(string path)
        {
            var o = new TcObject { File = path };
            try
            {
                var doc = new XmlDocument(); doc.XmlResolver = null;
                var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
                using (var r = XmlReader.Create(path, settings)) doc.Load(r);
                var root = doc.DocumentElement;
                XmlElement obj = null;
                foreach (XmlNode n in root.ChildNodes) if (n is XmlElement) { obj = (XmlElement)n; break; }
                if (obj == null) { o.LoadError = "no object element"; return o; }
                o.XmlKind = obj.Name; o.Name = obj.GetAttribute("Name"); o.Id = obj.GetAttribute("Id");
                Walk(o, obj, o.Name, obj.Name);
            }
            catch (Exception e) { o.LoadError = e.GetType().Name + ": " + e.Message; }
            return o;
        }
        static void Walk(TcObject o, XmlElement el, string owner, string kind)
        {
            var s = new Section { Owner = owner, Kind = kind, Name = el.GetAttribute("Name"), Id = el.GetAttribute("Id") };
            var decl = el["Declaration"]; if (decl != null) s.Decl = decl.InnerText;
            var impl = el["Implementation"];
            if (impl != null)
            {
                foreach (XmlNode n in impl.ChildNodes)
                {
                    var e = n as XmlElement; if (e == null) continue;
                    s.ImplLang = e.Name; if (e.Name == "ST") s.Impl = e.InnerText;
                }
            }
            if (s.Decl != null || impl != null) o.Sections.Add(s);
            foreach (XmlNode n in el.ChildNodes)
            {
                var e = n as XmlElement; if (e == null) continue;
                if (e.Name == "Method" || e.Name == "Action" || e.Name == "Transition" || e.Name == "Property" || e.Name == "Get" || e.Name == "Set")
                    Walk(o, e, owner + "." + (e.HasAttribute("Name") ? e.GetAttribute("Name") : e.Name), e.Name);
            }
        }
    }
}
