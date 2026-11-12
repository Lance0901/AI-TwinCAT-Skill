// TwinCAT Semantic Linter (#252) - Structured Text tokenizer. C# 5 (see LintCore.cs).
// Syntax and sources: openspec/changes/add-semantic-linter/research/st-syntax-inventory.md.
// Outcomes (design.md D3, second review B2):
// - supported;
// - Unverified: only the listed constructs that may be legal (conditional pragma, ?=, **, /* */,
//   E#Member, non-ASCII identifier) -> the section is notAnalyzed, the verdict can still pass;
// - Unknown: anything else the lexer does not know -> the section is unsupported, verdict incomplete;
// - Entities: XML escapes (&lt; ...) inside CDATA code -> PROJECT-XML-003 escaped-entity-in-cdata;
// - Error: certainly illegal (unterminated string / comment, backtick, typographic quote) -> LINT-PARSE-001.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;
    using System.Text;
    using System.Text.RegularExpressions;

    public enum TokKind { Ident, Number, TypedLiteral, String, WString, Op, Pragma, Address, EOF }

    public sealed class Token
    {
        public TokKind Kind;
        public string Text;
        public int Line;
        public int Col;
        public string Upper;   // Ident: upper-case invariant text (keywords are not case-sensitive)

        public bool Is(string upperKeyword) { return Kind == TokKind.Ident && Upper == upperKeyword; }
        public bool IsOp(string op) { return Kind == TokKind.Op && Text == op; }
        public override string ToString() { return Kind + ":" + Text + "@" + Inv.S(Line) + ":" + Inv.S(Col); }
    }

    public sealed class LexIssue
    {
        public bool Certain;    // Error that no surrounding construct can explain (backtick, typographic quote)
        public string Reason;   // for Unverified: notAnalyzed reason; for Error: fixed English text
        public int Line;
        public int Col;
    }

    public sealed class Comment
    {
        public string Text;
        public int Line;
        public int Col;
        public bool OwnLine;   // nothing but white space before it on its line
    }

    public sealed class LexResult
    {
        public List<Token> Tokens = new List<Token>();
        public List<Comment> Comments = new List<Comment>();
        public LexIssue Error;                                   // first certain error (tokenizing stops)
        public List<LexIssue> Unverified = new List<LexIssue>(); // listed constructs that may be legal (notAnalyzed, may pass)
        public List<LexIssue> Unknown = new List<LexIssue>();    // anything else not understood (unsupported -> incomplete)
        public List<LexIssue> Entities = new List<LexIssue>();   // &lt; &gt; &amp; &quot; &apos; &#..; in code (Reason = the entity text)
        public bool ConditionalPragma;                           // {IF ...} seen
        public int ConditionalPragmaLine;
    }

    public static class StLexer
    {
        private static readonly string[] Ops2 = { ":=", "=>", "<>", "<=", ">=", "..", "**", "?=" };
        private const string Ops1 = "^+-*/=<>()[],;:.";
        private static readonly Regex EntityRx = new Regex("\\G&(lt|gt|amp|quot|apos|#[0-9]+|#x[0-9A-Fa-f]+);", RegexOptions.CultureInvariant);

        private static readonly HashSet<string> TimePrefixes = Set("T", "TIME", "LTIME");
        private static readonly HashSet<string> DatePrefixes = Set("D", "DATE", "LD", "LDATE");
        private static readonly HashSet<string> DtPrefixes = Set("DT", "DATE_AND_TIME", "LDT", "LDATE_AND_TIME");
        private static readonly HashSet<string> TodPrefixes = Set("TOD", "TIME_OF_DAY", "LTOD", "LTIME_OF_DAY");
        private static readonly HashSet<string> TypePrefixes = Set("BOOL", "SINT", "USINT", "BYTE", "INT", "UINT", "WORD", "DINT", "UDINT",
            "DWORD", "LINT", "ULINT", "LWORD", "REAL", "LREAL");

        // Words that cannot end a designator: "IF S= x" is not a set-assignment.
        public static readonly HashSet<string> Keywords = Set(
            "PROGRAM", "END_PROGRAM", "FUNCTION_BLOCK", "END_FUNCTION_BLOCK", "FUNCTION", "END_FUNCTION", "METHOD", "END_METHOD",
            "PROPERTY", "END_PROPERTY", "INTERFACE", "END_INTERFACE", "TYPE", "END_TYPE", "STRUCT", "END_STRUCT", "UNION", "END_UNION",
            "VAR", "VAR_INPUT", "VAR_OUTPUT", "VAR_IN_OUT", "VAR_GLOBAL", "VAR_TEMP", "VAR_STAT", "VAR_INST", "VAR_EXTERNAL", "VAR_CONFIG",
            "VAR_GENERIC", "END_VAR", "CONSTANT", "RETAIN", "PERSISTENT", "AT", "EXTENDS", "IMPLEMENTS", "ABSTRACT", "FINAL", "PUBLIC",
            "PRIVATE", "PROTECTED", "INTERNAL", "IF", "THEN", "ELSIF", "ELSE", "END_IF", "CASE", "OF", "END_CASE", "FOR", "TO", "BY", "DO",
            "END_FOR", "WHILE", "END_WHILE", "REPEAT", "UNTIL", "END_REPEAT", "RETURN", "EXIT", "CONTINUE", "JMP", "ARRAY", "POINTER",
            "REFERENCE", "AND", "OR", "XOR", "NOT", "MOD", "AND_THEN", "OR_ELSE", "TRUE", "FALSE", "ACTION", "END_ACTION",
            "__TRY", "__CATCH", "__FINALLY", "__ENDTRY");

        private static HashSet<string> Set(params string[] items)
        {
            return new HashSet<string>(items, StringComparer.Ordinal);
        }

        public static LexResult Lex(string s)
        {
            LexResult r = new LexResult();
            if (s == null) s = "";
            int i = 0, line = 1, col = 1, n = s.Length;
            bool lineHasCode = false;
            while (i < n)
            {
                char c = s[i];
                if (c == '\n') { i++; line++; col = 1; lineHasCode = false; continue; }
                if (c == '\r') { i++; if (i < n && s[i] == '\n') { i++; } line++; col = 1; lineHasCode = false; continue; }
                if (c == ' ' || c == '\t' || c == '\f' || c == '\v' || c == '\uFEFF') { i++; col++; continue; }
                int sl = line, sc = col, st = i;

                // ---- comments
                if (c == '/' && i + 1 < n && s[i + 1] == '/')
                {
                    while (i < n && s[i] != '\n' && s[i] != '\r') { i++; col++; }
                    AddComment(r, s.Substring(st, i - st), sl, sc, !lineHasCode);
                    continue;
                }
                if (c == '(' && i + 1 < n && s[i + 1] == '*')
                {
                    // (* *) nests without a depth limit (InfoSys PI/2528329355.html)
                    int depth = 1; i += 2; col += 2;
                    while (i < n && depth > 0)
                    {
                        if (s[i] == '(' && i + 1 < n && s[i + 1] == '*') { depth++; i += 2; col += 2; continue; }
                        if (s[i] == '*' && i + 1 < n && s[i + 1] == ')') { depth--; i += 2; col += 2; continue; }
                        Advance(s, ref i, ref line, ref col);
                    }
                    if (depth > 0) { r.Error = Issue("unterminated (* comment", sl, sc); return r; }
                    AddComment(r, s.Substring(st, i - st), sl, sc, !lineHasCode);
                    continue;
                }
                if (c == '/' && i + 1 < n && s[i + 1] == '*')
                {
                    // /* */ is not in the PLC manual (only TF5100 NC I): recognised, section not analysed
                    r.Unverified.Add(Issue("unverified-syntax:slash-star-comment", sl, sc));
                    int end = s.IndexOf("*/", i + 2, StringComparison.Ordinal);
                    int stop = end < 0 ? n : end + 2;
                    while (i < stop) Advance(s, ref i, ref line, ref col);
                    continue;
                }

                lineHasCode = true;

                // ---- pragma { ... } (quoted text inside may contain '}')
                if (c == '{')
                {
                    int j = i + 1; bool inQ = false; char q = '\0';
                    int pl = line, pc = col;
                    while (j < n)
                    {
                        char d = s[j];
                        if (inQ) { if (d == '$') { j += 2; continue; } if (d == q) inQ = false; }
                        else if (d == '\'' || d == '"') { inQ = true; q = d; }
                        else if (d == '}') break;
                        j++;
                    }
                    if (j >= n)
                    {
                        // quote handling inside pragmas is not documented ($ escape?): not certainly illegal -> not analysed
                        r.Unknown.Add(Issue("unsupported-syntax:unterminated-pragma", sl, sc));
                        while (i < n) Advance(s, ref i, ref line, ref col);
                        break;
                    }
                    string text = s.Substring(i, j - i + 1);
                    while (i <= j) Advance(s, ref i, ref line, ref col);
                    Token pt = new Token(); pt.Kind = TokKind.Pragma; pt.Text = text; pt.Line = pl; pt.Col = pc;
                    r.Tokens.Add(pt);
                    string inner = text.Substring(1).TrimStart();
                    if (StartsWord(inner, "IF") || StartsWord(inner, "ELSIF") || StartsWord(inner, "ELSE") || StartsWord(inner, "END_IF"))
                    {
                        if (!r.ConditionalPragma) { r.ConditionalPragma = true; r.ConditionalPragmaLine = pl; }
                    }
                    continue;
                }

                // ---- string literals ('...' STRING, "..." WSTRING); $ escapes the next character
                if (c == '\'' || c == '"')
                {
                    char q = c; int j = i + 1;
                    bool closed = false;
                    while (j < n)
                    {
                        char d = s[j];
                        if (d == '\r' || d == '\n') break;
                        if (d == '$') { if (j + 1 < n && (s[j + 1] == '\r' || s[j + 1] == '\n')) break; j += 2; continue; }
                        if (d == q) { closed = true; break; }
                        j++;
                    }
                    if (!closed)
                    {
                        r.Error = Issue(j < n ? "line break inside a string literal" : "unterminated string literal", sl, sc);
                        return r;
                    }
                    AddTok(r, q == '\'' ? TokKind.String : TokKind.WString, s.Substring(i, j - i + 1), sl, sc);
                    col += j + 1 - i; i = j + 1;
                    continue;
                }

                // ---- direct address %IX0.0, %QW2, %I*
                if (c == '%')
                {
                    int j = i + 1;
                    if (j < n && "IQMiqm".IndexOf(s[j]) >= 0)
                    {
                        j++;
                        if (j < n && "XBWDLxbwdl".IndexOf(s[j]) >= 0) j++;
                        if (j < n && s[j] == '*') j++;
                        else
                        {
                            int digits = j;
                            while (j < n && (char.IsDigit(s[j]) || (s[j] == '.' && j + 1 < n && char.IsDigit(s[j + 1])))) j++;
                            if (j == digits) j = i + 1;
                        }
                    }
                    if (j == i + 1)
                    {
                        r.Unknown.Add(Issue("unsupported-syntax:direct-address", sl, sc));
                        i++; col++;
                        continue;
                    }
                    AddTok(r, TokKind.Address, s.Substring(i, j - i), sl, sc);
                    col += j - i; i = j;
                    continue;
                }

                // ---- identifiers, keywords, typed literals
                if (IsIdentStart(c))
                {
                    int j = i;
                    bool nonAscii = false;
                    while (j < n && IsIdentPart(s[j])) { if (s[j] > 127) nonAscii = true; j++; }
                    string word = s.Substring(i, j - i);
                    string up = word.ToUpperInvariant();
                    if (nonAscii) r.Unverified.Add(Issue("unverified-syntax:non-ascii-identifier", sl, sc));
                    if (j < n && s[j] == '#')
                    {
                        int end = TypedLiteralEnd(s, j + 1, up, r, sl, sc);
                        AddTok(r, TokKind.TypedLiteral, s.Substring(i, end - i), sl, sc);
                        col += end - i; i = end;
                        continue;
                    }
                    // S= / R= / REF= after a designator end (ExST, InfoSys PI/2528254091, 2528259467, 4978163979)
                    if ((up == "S" || up == "R" || up == "REF") && j < n && s[j] == '=' && !(j + 1 < n && s[j + 1] == '=') && EndsDesignator(r))
                    {
                        AddTok(r, TokKind.Op, up + "=", sl, sc);
                        col += j + 1 - i; i = j + 1;
                        continue;
                    }
                    Token t = AddTok(r, TokKind.Ident, word, sl, sc);
                    t.Upper = up;
                    col += j - i; i = j;
                    continue;
                }

                // ---- numbers
                if (char.IsDigit(c))
                {
                    int end = NumberEnd(s, i);
                    if (end < n && s[end] == '#')
                    {
                        string b = s.Substring(i, end - i).Replace("_", "");
                        int k = end + 1;
                        string allowed = b == "2" ? "01_" : b == "8" ? "01234567_" : b == "16" ? "0123456789ABCDEFabcdef_" : null;
                        if (allowed == null)
                        {
                            r.Unknown.Add(Issue("unsupported-syntax:number-base", sl, sc));
                            allowed = "0123456789ABCDEFabcdef_";
                        }
                        while (k < n && allowed.IndexOf(s[k]) >= 0) k++;
                        end = k;
                    }
                    AddTok(r, TokKind.Number, s.Substring(i, end - i), sl, sc);
                    col += end - i; i = end;
                    continue;
                }

                // ---- operators
                bool matched = false;
                foreach (string op in Ops2)
                {
                    if (string.CompareOrdinal(s, i, op, 0, 2) == 0)
                    {
                        AddTok(r, TokKind.Op, op, sl, sc);
                        if (op == "?=") r.Unverified.Add(Issue("unverified-syntax:assignment-attempt", sl, sc));
                        if (op == "**") r.Unverified.Add(Issue("unverified-syntax:power-operator", sl, sc));
                        i += 2; col += 2; matched = true; break;
                    }
                }
                if (matched) continue;
                if (Ops1.IndexOf(c) >= 0)
                {
                    AddTok(r, TokKind.Op, c.ToString(), sl, sc);
                    i++; col++;
                    continue;
                }

                // XML escape written into CDATA by an XML tool (the compiler sees '&lt;', not '<')
                if (c == '&')
                {
                    Match em = EntityRx.Match(s, i);
                    if (em.Success && em.Index == i)
                    {
                        r.Entities.Add(Issue(em.Value, sl, sc));
                        i += em.Length; col += em.Length;
                        continue;
                    }
                }
                // characters that are certainly not ST (typical copy / paste from text or Markdown)
                if (c == '`' || c == '\u2018' || c == '\u2019' || c == '\u201C' || c == '\u201D')
                {
                    r.Error = Issue("character U+" + ((int)c).ToString("X4", System.Globalization.CultureInfo.InvariantCulture) + " is not ST", sl, sc);
                    r.Error.Certain = true;
                    return r;
                }
                // anything else: not known -> the section is unsupported (verdict incomplete, never pass)
                r.Unknown.Add(Issue("unsupported-syntax:char-U+" + ((int)c).ToString("X4", System.Globalization.CultureInfo.InvariantCulture), sl, sc));
                Advance(s, ref i, ref line, ref col);
            }
            Token eof = new Token(); eof.Kind = TokKind.EOF; eof.Text = ""; eof.Line = line; eof.Col = col; eof.Upper = "";
            r.Tokens.Add(eof);
            return r;
        }

        private static void Advance(string s, ref int i, ref int line, ref int col)
        {
            char c = s[i];
            if (c == '\n') { line++; col = 1; i++; return; }
            if (c == '\r') { i++; if (i < s.Length && s[i] == '\n') i++; line++; col = 1; return; }
            i++; col++;
        }

        private static bool StartsWord(string s, string w)
        {
            if (!s.StartsWith(w, StringComparison.OrdinalIgnoreCase)) return false;
            return s.Length == w.Length || !IsIdentPart(s[w.Length]);
        }

        private static bool IsIdentStart(char c) { return c == '_' || (c < 128 ? char.IsLetter(c) : char.IsLetter(c)); }
        private static bool IsIdentPart(char c) { return c == '_' || char.IsLetterOrDigit(c); }

        private static bool EndsDesignator(LexResult r)
        {
            if (r.Tokens.Count == 0) return false;
            Token p = r.Tokens[r.Tokens.Count - 1];
            if (p.Kind == TokKind.Ident) return !Keywords.Contains(p.Upper) || p.Upper == "THIS" || p.Upper == "SUPER";
            return p.IsOp("]") || p.IsOp(")") || p.IsOp("^");
        }

        private static Token AddTok(LexResult r, TokKind k, string text, int line, int col)
        {
            Token t = new Token(); t.Kind = k; t.Text = text; t.Line = line; t.Col = col; t.Upper = k == TokKind.Ident ? text.ToUpperInvariant() : "";
            r.Tokens.Add(t);
            return t;
        }

        private static void AddComment(LexResult r, string text, int line, int col, bool ownLine)
        {
            Comment c = new Comment(); c.Text = text; c.Line = line; c.Col = col; c.OwnLine = ownLine;
            r.Comments.Add(c);
        }

        private static LexIssue Issue(string reason, int line, int col)
        {
            LexIssue x = new LexIssue(); x.Reason = reason; x.Line = line; x.Col = col;
            return x;
        }

        // decimal digits with '_' ; optional fraction (not "1..10") ; optional exponent
        private static int NumberEnd(string s, int i)
        {
            int n = s.Length, j = i;
            while (j < n && (char.IsDigit(s[j]) || s[j] == '_')) j++;
            if (j < n && s[j] == '#') return j;
            if (j + 1 < n && s[j] == '.' && char.IsDigit(s[j + 1]))
            {
                j++;
                while (j < n && (char.IsDigit(s[j]) || s[j] == '_')) j++;
            }
            if (j < n && (s[j] == 'e' || s[j] == 'E'))
            {
                int k = j + 1;
                if (k < n && (s[k] == '+' || s[k] == '-')) k++;
                if (k < n && char.IsDigit(s[k]))
                {
                    j = k;
                    while (j < n && char.IsDigit(s[j])) j++;
                }
            }
            return j;
        }

        private static int Digits(string s, int i, string extra)
        {
            int n = s.Length;
            while (i < n && (char.IsDigit(s[i]) || (extra != null && extra.IndexOf(s[i]) >= 0))) i++;
            return i;
        }

        // i = first character after '#'. Each prefix has its own grammar (st-syntax-inventory 1.5):
        // the literal never swallows a following "-tonB.ET".
        private static int TypedLiteralEnd(string s, int i, string prefix, LexResult r, int line, int col)
        {
            int n = s.Length;
            if (TimePrefixes.Contains(prefix))
            {
                int j = i;
                if (j < n && s[j] == '-') j++;   // defensive: T#-1s
                int groups = 0;
                while (true)
                {
                    int d = Digits(s, j, "_.");
                    if (d == j) break;
                    int u = Unit(s, d);
                    if (u == d) { if (groups == 0) { j = d; } break; }
                    j = u; groups++;
                }
                if (groups == 0 && j == i) r.Unknown.Add(Issue("unsupported-syntax:time-literal", line, col));
                return j;
            }
            if (DatePrefixes.Contains(prefix))
            {
                return DashGroups(s, i, 3);
            }
            if (DtPrefixes.Contains(prefix))
            {
                int j = DashGroups(s, i, 3);
                return ColonGroups(s, j);   // '-' then hh:mm:ss[.f]
            }
            if (TodPrefixes.Contains(prefix))
            {
                return ColonGroups(s, i);
            }
            if (TypePrefixes.Contains(prefix))
            {
                int j = i;
                if (j < n && (s[j] == '-' || s[j] == '+')) j++;
                if (j < n && char.IsDigit(s[j]))
                {
                    int end = NumberEnd(s, j);
                    if (end < n && s[end] == '#')
                    {
                        end++;
                        while (end < n && "0123456789ABCDEFabcdef_".IndexOf(s[end]) >= 0) end++;
                    }
                    return end;
                }
                if (j < n && IsIdentStart(s[j]))
                {
                    int k = j;
                    while (k < n && IsIdentPart(s[k])) k++;
                    string w = s.Substring(j, k - j).ToUpperInvariant();
                    if (w == "TRUE" || w == "FALSE") return k;
                }
                r.Unknown.Add(Issue("unsupported-syntax:typed-literal", line, col));
                return j;
            }
            // <Enum>#<Member>: no InfoSys page found -> recognised, section not analysed
            if (i < n && IsIdentStart(s[i]))
            {
                int k = i;
                while (k < n && IsIdentPart(s[k])) k++;
                r.Unverified.Add(Issue("unverified-syntax:enum-hash-literal", line, col));
                return k;
            }
            r.Unknown.Add(Issue("unsupported-syntax:typed-literal", line, col));
            return i;
        }

        private static int Unit(string s, int i)
        {
            int n = s.Length;
            string[] units = { "ms", "us", "ns", "d", "h", "m", "s" };
            foreach (string u in units)
            {
                if (i + u.Length <= n && string.Compare(s, i, u, 0, u.Length, StringComparison.OrdinalIgnoreCase) == 0)
                {
                    int k = i + u.Length;
                    // units are tried longest first ("ms" before "m"); a letter right after the unit = no unit
                    if (k < n && char.IsLetter(s[k])) return i;
                    return k;
                }
            }
            return i;
        }

        private static int DashGroups(string s, int i, int groups)
        {
            int j = i, n = s.Length;
            for (int g = 0; g < groups; g++)
            {
                if (g > 0) { if (j < n && s[j] == '-' && j + 1 < n && char.IsDigit(s[j + 1])) j++; else return j; }
                int d = Digits(s, j, null);
                if (d == j) return j;
                j = d;
            }
            return j;
        }

        private static int ColonGroups(string s, int i)
        {
            int j = i, n = s.Length;
            if (j < n && s[j] == '-' && j + 1 < n && char.IsDigit(s[j + 1])) j++;
            for (int g = 0; g < 3; g++)
            {
                if (g > 0) { if (j < n && s[j] == ':' && j + 1 < n && char.IsDigit(s[j + 1])) j++; else return j; }
                int d = Digits(s, j, null);
                if (d == j) return j;
                j = d;
            }
            if (j + 1 < n && s[j] == '.' && char.IsDigit(s[j + 1])) j = Digits(s, j + 1, null);
            return j;
        }
    }
}
