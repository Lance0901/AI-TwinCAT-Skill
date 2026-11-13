﻿// TwinCAT Semantic Linter (#252) - Phase 3a rule SCAN-REF-001 (rule-catalog.md Phase 3, tasks 3.1). C# 5.
// A REFERENCE TO / POINTER TO variable that is dereferenced while nothing in the project can have assigned it: TwinCAT
// initialises references with 0 (InfoSys 2529458827) and reading through an invalid reference / a 0 pointer is a page fault
// that puts the TwinCAT system into Exception; on the local UmRT the runtime process crashed afterwards even after a new
// Activate (measured 2026-11-13, XAE 4026.22 / UmRT, verification/runtime-semantics-measured.md sections 7.2 / 8). The
// compiler reports nothing (same measurement).
// Principle (PR #284 / #289 reviews): what cannot be proven -> coverage.rulesSkipped with a reason; never a silent pass, never a guess.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;

    public static partial class RuleRegistry
    {
        private static void Register3Ref()
        {
            Add("SCAN-REF-001", "REFERENCE / POINTER may be dereferenced before it is assigned", "warning", "false", "crash", "measured:2026-11-13 no",
                "Candidates: REFERENCE TO without REF= initial value, POINTER TO without initial value or := 0, declared in VAR / VAR_STAT / VAR_OUTPUT of a FUNCTION_BLOCK / PROGRAM, or VAR / VAR_TEMP of a FUNCTION / METHOD / accessor (re-initialised on every call). " +
                "Dereference: any use of a reference other than __ISVALIDREF(r) and r REF= ...; p^ and p[i] for a pointer (p := 0 is no assignment; only p := ADR(...) earlier at top level proves the use safe, any other p := value -> assigned-elsewhere). Reported (variant reference-unassigned / pointer-unassigned, first unguarded use) when the object assigns it nowhere (no REF= / p := / => p in the body, actions, methods, accessors, FB_init) and the use is not guarded. " +
                "Guards: inside IF / ELSIF whose condition has __ISVALIDREF(r) / p <> 0 as an AND-ed term (no OR / XOR), ELSE / later ELSIF after a condition NOT __ISVALIDREF(r) / p = 0 (OR-ed terms only), after a top-level IF NOT __ISVALIDREF(r) [OR ...] THEN ... RETURN, " +
                "after __ISVALIDREF(r) AND_THEN / p <> 0 AND_THEN or NOT __ISVALIDREF(r) OR_ELSE / p = 0 OR_ELSE in the same expression (an OR at the same parenthesis level breaks it); __ISVALIDREF(r) compared with = / <> (= FALSE) is not a recognised guard; AND is no guard ('TwinCAT always evaluates all operands if the IEC operator AND is used', InfoSys AND_THEN 2528923787). An unconditional top-level assignment earlier in the same section also makes the use safe. " +
                "rulesSkipped <reason>:<name> (never a finding): caller-provided (VAR_INPUT / VAR_IN_OUT), assigned-elsewhere (assigned only in another section, FB_init, a method / property, or conditionally), qualified-access (x.r anywhere in the project that may be the owner), " +
                "inherited-use (the FB is EXTENDS-ed), passed-or-aliased (a call argument, ADR, the source of REF=, a declaration initialiser), guard-not-understood (__ISVALIDREF(r) / p compared in another form, e.g. stored in a BOOL), unanalysed-part / implementation-not-analyzed. " +
                "Known misses: early-return guards that are not top-level IFs, guards in a calling POU, a valid reference that becomes invalid later. " +
                "Impact measured 2026-11-13 (XAE 4026.22 / UmRT, verification/runtime-semantics-measured.md section 8): reading an unassigned REFERENCE TO INT and a POINTER := 0 gave Page Fault 0xc0000005, TwinCAT system Exception, and the UmRT process crashed seconds later even after a successful re-Activate (section 7.2).", "medium", null);
            RuleRegistry.Get("SCAN-REF-001").Phase = "3";
            RuleRegistry.Get("SCAN-REF-001").Te1200 = "SA0039 / SA0145 (Full)";
        }
    }

    internal sealed partial class LintRun
    {
        private const string RRef = "SCAN-REF-001";

        private sealed class Ref3Var
        {
            public DeclUnit Du;          // declaration that holds it
            public DeclUnit Owner;       // top object
            public VarDecl V;
            public string Name;
            public bool Ptr;
            public bool OwnerLevel;      // FB / PROGRAM instance variable (visible in every section of the object)
            public bool Caller;          // VAR_INPUT / VAR_IN_OUT
        }

        private sealed class Ref3Frame
        {
            public string Kind;
            public string Branch;        // IF: cond / then / else
            public int CondFrom, CondTo;
            public List<int[]> Prev = new List<int[]>();
        }

        private void RunPhase3Ref()
        {
            if (!Enabled(RRef)) return;
            Ensure3Index();
            foreach (DeclUnit du in declUnits)
            {
                if (du.Di == null || du.O == null) continue;
                bool top = du.Path == du.O.ObjectPath;
                string h = du.Di.HeaderKeyword ?? "";
                DeclUnit owner = du;
                if (!top) { owner = null; foreach (DeclUnit d in declUnits) if (d.O == du.O && d.Path == d.O.ObjectPath) owner = d; if (owner == null) continue; }
                string oh = owner.Di.HeaderKeyword ?? "";
                bool fbOwner = oh == "FUNCTION_BLOCK" || oh == "PROGRAM";
                if (top && !fbOwner && h != "FUNCTION") continue;
                if (!top && h != "METHOD" && h != "PROPERTY" && h != "FUNCTION") { if (du.Di.VarBlocks.Count == 0) continue; }
                foreach (VarBlock b in du.Di.VarBlocks)
                {
                    foreach (VarDecl v in b.Vars)
                    {
                        string tt = (v.TypeText ?? "").Trim();
                        string up = tt.ToUpperInvariant();
                        bool isRef = up.StartsWith("REFERENCE TO ", StringComparison.Ordinal);
                        bool isPtr = up.StartsWith("POINTER TO ", StringComparison.Ordinal);
                        if (!isRef && !isPtr) continue;
                        if (isRef && up.IndexOf("REF=", StringComparison.Ordinal) >= 0) continue;   // r : REFERENCE TO T REF= x;
                        if (isRef && !string.IsNullOrEmpty(v.InitText)) continue;
                        if (isPtr && !string.IsNullOrEmpty(v.InitText) && v.InitText.Trim() != "0") continue;
                        bool caller = b.Kind == "VAR_INPUT" || b.Kind == "VAR_IN_OUT";
                        bool ownerLevel;
                        if (top && fbOwner && (b.Kind == "VAR" || b.Kind == "VAR_STAT" || b.Kind == "VAR_OUTPUT")) ownerLevel = true;
                        else if (caller || b.Kind == "VAR" || b.Kind == "VAR_TEMP" || b.Kind == "VAR_INST") ownerLevel = false;
                        else continue;   // VAR_GLOBAL / VAR_EXTERNAL / CONSTANT blocks: not a candidate
                        if (b.Kind == "VAR_INST") ownerLevel = false;
                        foreach (string n in v.Names)
                        {
                            Ref3Var x = new Ref3Var(); x.Du = du; x.Owner = owner; x.V = v; x.Name = n; x.Ptr = isPtr; x.OwnerLevel = ownerLevel; x.Caller = caller;
                            Ref3Evaluate(x);
                        }
                    }
                }
            }
        }

        private void Ref3Skip(Ref3Var x, string reason)
        {
            rulesSkipped.Add(Cov(RRef, x.Owner.O.Rel, x.Du.Path, null, reason + ":" + x.Name));
        }

        private void Ref3Evaluate(Ref3Var x)
        {
            // sections where the name means this variable
            List<ImplUnit> secs = new List<ImplUnit>();
            string problem = null;
            foreach (ImplUnit u in implUnits)
            {
                if (u.O != x.Owner.O) continue;
                if (!x.OwnerLevel && u.Path != x.Du.Path) continue;
                if (u.Scan == null || u.Scan.State.Status != "ok" || u.Scan.Lex == null) { if (Ref3Mentions(u, x.Name)) problem = "implementation-not-analyzed"; continue; }
                if (x.OwnerLevel && u.Path != x.Owner.Path)
                {
                    Scope sc = ScopeOf(u);
                    if (sc.LocalUnknown) { if (Ref3Mentions(u, x.Name)) problem = "unanalysed-part"; continue; }
                    if (sc.Local != null && sc.Local != x.Owner.Di && FindIn(sc.Local, x.Name, null) != null) continue;   // shadowed by a local
                }
                secs.Add(u);
            }

            bool passed = false, unrecognized = false;
            bool anyAssign = false;
            List<object[]> unguarded = new List<object[]>();   // { ImplUnit, Token }
            foreach (ImplUnit u in secs)
            {
                List<Token> t = NoPragmas(u.Scan.Lex.Tokens);
                List<int> topAssign = new List<int>();
                for (int i = 0; i < t.Count; i++)
                {
                    if (t[i].Kind != TokKind.Ident || !string.Equals(t[i].Text, x.Name, StringComparison.OrdinalIgnoreCase)) continue;
                    int start = i;
                    if (i > 0 && t[i - 1].IsOp("."))
                    {
                        if (i >= 3 && t[i - 2].IsOp("^") && t[i - 3].Is("THIS")) start = i - 3;
                        else continue;
                    }
                    Token prev = start > 0 ? t[start - 1] : null;
                    Token nx = i + 1 < t.Count ? t[i + 1] : null;
                    bool inCall = Sm3InCall(t, start);
                    if (nx != null && (nx.IsOp(":=") || nx.IsOp("=>")) && prev != null && (prev.IsOp("(") || prev.IsOp(",")) && inCall) continue;   // formal parameter name
                    // assignments of the reference / pointer itself
                    bool assign = (!x.Ptr && nx != null && nx.IsOp("REF=")) || (x.Ptr && nx != null && nx.IsOp(":=")) || (x.Ptr && prev != null && prev.IsOp("=>"));
                    if (assign)
                    {
                        bool proof = true;
                        if (x.Ptr && prev != null && prev.IsOp("=>")) proof = false;
                        else if (x.Ptr)
                        {
                            // review B2: p := 0 leaves it 0 (not an assignment); only p := ADR(...) proves a valid address
                            int e = StatementEnd(t, i + 2);
                            if (e == i + 3 && Ref3IsZero(t[i + 2])) continue;
                            proof = e > i + 4 && t[i + 2].Is("ADR") && t[i + 3].IsOp("(") && t[e - 1].IsOp(")") && Ref3Closes(t, i + 3, e - 1);
                        }
                        anyAssign = true;
                        if (proof && Ref3Frames(t, start).Count == 0) topAssign.Add(start);
                        continue;
                    }
                    // __ISVALIDREF(r) / p compared: a guard mention
                    bool mention = !x.Ptr ? (prev != null && prev.IsOp("(") && start >= 2 && t[start - 2].Upper == "__ISVALIDREF" && nx != null && nx.IsOp(")"))
                                          : ((nx != null && (nx.IsOp("=") || nx.IsOp("<>"))) || (prev != null && (prev.IsOp("=") || prev.IsOp("<>"))));
                    if (mention) { if (!Ref3MentionRecognized(t, start, i, x)) unrecognized = true; continue; }
                    if (!x.Ptr && prev != null && prev.IsOp("REF=")) { passed = true; unguarded.Add(new object[] { u, t[start] }); continue; }     // y REF= r
                    bool deref = x.Ptr ? (nx != null && (nx.IsOp("^") || nx.IsOp("["))) : true;   // review B3: p[i] is an index access through p
                    if (prev != null && (prev.IsOp("(") || prev.IsOp(",") || prev.IsOp(":=")) && nx != null && (nx.IsOp(")") || nx.IsOp(",")) && inCall)
                    {
                        // F(r) / F(x := r) / ADR(r): may be VAR_IN_OUT / an address - an unguarded hand-over is a possible use that
                        // cannot be judged here (rulesSkipped passed-or-aliased, never a silent pass)
                        passed = true;   // a VAR_IN_OUT pointer parameter may also assign it
                        if (!Ref3Guarded(t, start, x)) unguarded.Add(new object[] { u, t[start] });
                        continue;
                    }
                    if (!deref) continue;           // q := p, p + 4: the pointer value only
                    // a dereference
                    bool safe = Ref3Guarded(t, start, x);
                    if (!safe) foreach (int a in topAssign) if (a < start) safe = true;
                    if (!safe) unguarded.Add(new object[] { u, t[start] });
                }
            }
            if (unguarded.Count == 0 && problem == null) return;   // review S1: a use in a section that is not analysed is never a silent pass
            if (x.Caller) { Ref3Skip(x, "caller-provided"); return; }
            if (problem != null) { Ref3Skip(x, problem); return; }
            foreach (DeclUnit d in declUnits) if (d.O == x.Owner.O && (d.Di == null || d.Di.State.Status != "ok")) { Ref3Skip(x, "member-declaration-not-analyzed"); return; }
            if (x.OwnerLevel)
            {
                if (derivedBases.Contains(x.Owner.O.Name)) { Ref3Skip(x, "inherited-use"); return; }
                HashSet<string> dn;
                if (dotNames.TryGetValue(x.Name, out dn) && QualifiedMayBeOwn(x.Name, x.Owner.O.Name)) { Ref3Skip(x, "qualified-access"); return; }
                foreach (Uncertain un in uncertain)
                    if ((un.Idents == null && string.Equals(un.Owner, x.Owner.O.Name, StringComparison.OrdinalIgnoreCase)) || (un.Idents != null && un.Idents.Contains(x.Name))) { Ref3Skip(x, "unanalysed-part"); return; }
            }
            // the name in another declaration initialiser (ADR(r), y : REFERENCE TO INT REF= r, FB_init argument)
            foreach (DeclUnit d in declUnits)
            {
                if (d.O != x.Owner.O || (!x.OwnerLevel && d != x.Du)) continue;
                if (d.Di.Lex == null) { Ref3Skip(x, "declaration-not-analyzed"); return; }
                List<Token> dt = d.Di.Lex.Tokens;
                for (int i = 0; i < dt.Count; i++)
                {
                    if (dt[i].Kind != TokKind.Ident || !string.Equals(dt[i].Text, x.Name, StringComparison.OrdinalIgnoreCase)) continue;
                    if (i > 0 && dt[i - 1].IsOp(".")) continue;
                    bool declares = i + 1 < dt.Count && (dt[i + 1].IsOp(":") || dt[i + 1].IsOp(",") || dt[i + 1].Is("AT"));
                    if (declares) continue;
                    Ref3Skip(x, "passed-or-aliased"); return;
                }
            }
            if (passed) { Ref3Skip(x, "passed-or-aliased"); return; }
            if (anyAssign) { Ref3Skip(x, "assigned-elsewhere"); return; }
            if (unrecognized) { Ref3Skip(x, "guard-not-understood"); return; }
            ImplUnit fu = (ImplUnit)unguarded[0][0];
            Token ft = (Token)unguarded[0][1];
            string decl = x.Name + " : " + (x.V.TypeText ?? "").Trim() + (string.IsNullOrEmpty(x.V.InitText) ? "" : " := " + x.V.InitText.Trim());
            Diagnostic dg = Emit(RRef, x.Owner.O.Rel, fu.Path, "implementation", ft.Line, ft.Col,
                (x.Ptr ? "Pointer '" : "Reference '") + decl + "' (declared in " + x.Du.Path + " line " + Inv.S(x.V.Line) + ") is dereferenced here but nothing in the object assigns it " +
                (x.Ptr ? "(no p := ADR(...))" : "(no REF=)") + " and the use is not guarded by " + (x.Ptr ? "p <> 0" : "__ISVALIDREF") + ": it is 0, and reading it is a page fault that stops the TwinCAT system " +
                "(measured 2026-11-13, XAE 4026.22 / UmRT: Exception, the UmRT process crashed afterwards even after a new Activate)",
                decl, x.Ptr ? "Assign the pointer (p := ADR(x)) before the first p^, or guard it: IF p <> 0 THEN ... END_IF"
                            : "Assign the reference (r REF= x, e.g. in FB_init or as initial value) or guard every use: IF __ISVALIDREF(r) THEN ... END_IF",
                x.Ptr ? "pointer-unassigned" : "reference-unassigned", null, null, false);
        }

        private static bool Ref3Mentions(ImplUnit u, string name)
        {
            if (u.Scan == null || u.Scan.Lex == null) return true;
            foreach (Token x in u.Scan.Lex.Tokens) if (x.Kind == TokKind.Ident && string.Equals(x.Text, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        // enclosing blocks of index upto (tokens before it)
        private static List<Ref3Frame> Ref3Frames(List<Token> t, int upto)
        {
            List<Ref3Frame> st = new List<Ref3Frame>();
            for (int k = 0; k < upto && k < t.Count; k++)
            {
                Token x = t[k];
                if (x.Kind != TokKind.Ident) continue;
                Ref3Frame top = st.Count > 0 ? st[st.Count - 1] : null;
                if (x.Is("IF")) { Ref3Frame f = new Ref3Frame(); f.Kind = "IF"; f.Branch = "cond"; f.CondFrom = k + 1; st.Add(f); }
                else if (x.Is("THEN") && top != null && top.Kind == "IF" && top.Branch == "cond") { top.CondTo = k; top.Branch = "then"; }
                else if (x.Is("ELSIF") && top != null && top.Kind == "IF") { top.Prev.Add(new int[] { top.CondFrom, top.CondTo }); top.Branch = "cond"; top.CondFrom = k + 1; }
                else if (x.Is("ELSE") && top != null && top.Kind == "IF") { top.Prev.Add(new int[] { top.CondFrom, top.CondTo }); top.Branch = "else"; }
                else if (x.Is("CASE") || x.Is("FOR") || x.Is("WHILE") || x.Is("REPEAT")) { Ref3Frame f = new Ref3Frame(); f.Kind = x.Upper; st.Add(f); }
                else if (x.Is("END_IF") || x.Is("END_CASE") || x.Is("END_FOR") || x.Is("END_WHILE") || x.Is("END_REPEAT")) { if (st.Count > 0) st.RemoveAt(st.Count - 1); }
            }
            return st;
        }

        private static bool Ref3IsName(List<Token> t, int k, string name)
        {
            return k >= 0 && k < t.Count && t[k].Kind == TokKind.Ident && string.Equals(t[k].Text, name, StringComparison.OrdinalIgnoreCase) && !(k > 0 && t[k - 1].IsOp("."));
        }

        private static bool Ref3IsZero(Token x) { return x != null && x.Kind == TokKind.Number && x.Text == "0"; }

        // __ISVALIDREF ( name ) starting at k
        private static bool Ref3ValidAt(List<Token> t, int k, string name)
        {
            if (!(k + 3 < t.Count && t[k].Upper == "__ISVALIDREF" && t[k + 1].IsOp("(") && Ref3IsName(t, k + 2, name) && t[k + 3].IsOp(")"))) return false;
            // review B1: '__ISVALIDREF(r) = FALSE' / '<> TRUE' inverts the meaning -> not a recognised guard term (guard-not-understood)
            if (k + 4 < t.Count && t[k + 4].Kind == TokKind.Op && (t[k + 4].Text == "=" || t[k + 4].Text == "<>" || t[k + 4].Text == "<" || t[k + 4].Text == ">" || t[k + 4].Text == "<=" || t[k + 4].Text == ">=")) return false;
            if (k > 0 && t[k - 1].Kind == TokKind.Op && (t[k - 1].Text == "=" || t[k - 1].Text == "<>")) return false;
            return true;
        }

        // condition t[from..to) proves the variable valid when TRUE: an AND-ed term __ISVALIDREF(r) / p <> 0, no OR / XOR / NOT (
        private static bool Ref3Positive(List<Token> t, int from, int to, Ref3Var x)
        {
            bool hit = false;
            for (int k = from; k < to && k < t.Count; k++)
            {
                if (t[k].Is("OR") || t[k].Is("OR_ELSE") || t[k].Is("XOR")) return false;
                if (t[k].Is("NOT") && k + 1 < t.Count && t[k + 1].IsOp("(")) return false;
                bool notBefore = k > 0 && t[k - 1].Is("NOT");
                if (!x.Ptr && Ref3ValidAt(t, k, x.Name) && !notBefore) hit = true;
                if (x.Ptr && Ref3IsName(t, k, x.Name) && k + 2 < to && t[k + 1].IsOp("<>") && Ref3IsZero(t[k + 2]) && !notBefore) hit = true;
                if (x.Ptr && Ref3IsZero(t[k]) && k + 2 < to && t[k + 1].IsOp("<>") && Ref3IsName(t, k + 2, x.Name) && !notBefore) hit = true;
            }
            return hit;
        }

        // condition proves the variable valid when FALSE: an OR-ed term NOT __ISVALIDREF(r) / p = 0, no AND / XOR / NOT (
        private static bool Ref3Negative(List<Token> t, int from, int to, Ref3Var x)
        {
            bool hit = false;
            for (int k = from; k < to && k < t.Count; k++)
            {
                if (t[k].Is("AND") || t[k].Is("AND_THEN") || t[k].Is("XOR")) return false;
                if (t[k].Is("NOT") && k + 1 < t.Count && t[k + 1].IsOp("(")) return false;
                if (!x.Ptr && t[k].Is("NOT") && Ref3ValidAt(t, k + 1, x.Name)) hit = true;
                if (x.Ptr && Ref3IsName(t, k, x.Name) && k + 2 < to && t[k + 1].IsOp("=") && Ref3IsZero(t[k + 2]) && !(k > 0 && t[k - 1].Is("NOT"))) hit = true;
                if (x.Ptr && Ref3IsZero(t[k]) && k + 2 < to && t[k + 1].IsOp("=") && Ref3IsName(t, k + 2, x.Name) && !(k > 0 && t[k - 1].Is("NOT"))) hit = true;
            }
            return hit;
        }

        private static int Ref3ThenOf(List<Token> t, int ifIdx)
        {
            for (int k = ifIdx + 1; k < t.Count; k++) { if (t[k].Is("THEN")) return k; if (t[k].IsOp(";")) return -1; }
            return -1;
        }

        // the guard term ends right before index k (t[k] is AND_THEN / AND): __ISVALIDREF(r) / p <> 0 / 0 <> p
        private static bool Ref3GuardBefore(List<Token> t, int k, Ref3Var x)
        {
            if (!x.Ptr) return k >= 4 && Ref3ValidAt(t, k - 4, x.Name) && !(k >= 5 && t[k - 5].Is("NOT"));
            if (k >= 3 && Ref3IsName(t, k - 3, x.Name) && t[k - 2].IsOp("<>") && Ref3IsZero(t[k - 1])) return true;
            if (k >= 3 && Ref3IsZero(t[k - 3]) && t[k - 2].IsOp("<>") && Ref3IsName(t, k - 1, x.Name)) return true;
            return false;
        }

        // the negated guard term ends right before index k (t[k] is OR_ELSE): NOT __ISVALIDREF(r) / p = 0 / 0 = p
        private static bool Ref3NegGuardBefore(List<Token> t, int k, Ref3Var x)
        {
            if (!x.Ptr) return k >= 5 && t[k - 5].Is("NOT") && Ref3ValidAt(t, k - 4, x.Name);
            if (k >= 3 && Ref3IsName(t, k - 3, x.Name) && t[k - 2].IsOp("=") && Ref3IsZero(t[k - 1]) && !(k >= 4 && t[k - 4].Is("NOT"))) return true;
            if (k >= 3 && Ref3IsZero(t[k - 3]) && t[k - 2].IsOp("=") && Ref3IsName(t, k - 1, x.Name) && !(k >= 4 && t[k - 4].Is("NOT"))) return true;
            return false;
        }

        private static bool Ref3Closes(List<Token> t, int open, int close)
        {
            int d = 0;
            for (int q = open; q <= close; q++)
            {
                if (t[q].IsOp("(")) d++;
                else if (t[q].IsOp(")")) { d--; if (d == 0) return q == close; }
            }
            return false;
        }

        private bool Ref3MentionRecognized(List<Token> t, int start, int i, Ref3Var x)
        {
            // the term followed by AND_THEN / AND
            int after = !x.Ptr ? i + 2 : (t[i + 1].IsOp("=") || t[i + 1].IsOp("<>") ? i + 3 : i + 1);
            if (after < t.Count && (t[after].Is("AND_THEN") || t[after].Is("AND")) && Ref3GuardBefore(t, after, x)) return true;
            if (after < t.Count && t[after].Is("OR_ELSE") && Ref3NegGuardBefore(t, after, x)) return true;
            // the term in an IF / ELSIF condition that is a recognised guard
            List<Ref3Frame> fr = Ref3Frames(t, start);
            if (fr.Count == 0) return false;
            Ref3Frame top = fr[fr.Count - 1];
            if (top.Kind != "IF" || top.Branch != "cond") return false;
            int th = -1;
            for (int k = start; k < t.Count; k++) { if (t[k].Is("THEN")) { th = k; break; } if (t[k].IsOp(";")) break; }
            if (th < 0) return false;
            return Ref3Positive(t, top.CondFrom, th, x) || Ref3Negative(t, top.CondFrom, th, x);
        }

        private bool Ref3Guarded(List<Token> t, int at, Ref3Var x)
        {
            // 1. enclosing IF branches
            foreach (Ref3Frame f in Ref3Frames(t, at))
            {
                if (f.Kind != "IF") continue;
                if (f.Branch == "then" && Ref3Positive(t, f.CondFrom, f.CondTo, x)) return true;
                if (f.Branch == "then" || f.Branch == "else")
                    foreach (int[] p in f.Prev) if (Ref3Negative(t, p[0], p[1], x)) return true;
            }
            // 2. guard AND_THEN earlier in the same expression
            int depth = 0;
            HashSet<int> orDepths = new HashSet<int>();   // review S3: A AND_THEN (b OR r) is guarded, A AND_THEN b OR r is not
            for (int k = at - 1; k >= 0; k--)
            {
                Token p = t[k];
                if (p.IsOp(";") || p.Is("THEN") || p.Is("DO") || p.Is("ELSE") || p.Is("IF") || p.Is("ELSIF") || p.Is("WHILE") || p.Is("UNTIL") || p.Is("OF")) break;
                if (p.IsOp(")")) depth++;
                else if (p.IsOp("(")) depth--;
                if (p.Is("OR_ELSE") && depth <= 0 && !orDepths.Contains(depth) && Ref3NegGuardBefore(t, k, x)) return true;   // review S2
                if (p.Is("OR") || p.Is("OR_ELSE") || p.Is("XOR")) { orDepths.Add(depth); continue; }
                if (p.Is("AND_THEN") && depth <= 0 && !orDepths.Contains(depth) && Ref3GuardBefore(t, k, x)) return true;
            }
            // 3. top-level IF NOT __ISVALIDREF(r) [OR ...] THEN ... RETURN ... END_IF before the use
            int d = 0;
            for (int k = 0; k < at; k++)
            {
                Token x0 = t[k];
                if (x0.Kind != TokKind.Ident) continue;
                if (d == 0 && x0.Is("IF"))
                {
                    int th = Ref3ThenOf(t, k);
                    if (th > 0 && Ref3Negative(t, k + 1, th, x))
                    {
                        int dd = 0; bool ret = false, branchOpen = true; int end = -1;
                        for (int q = th + 1; q < t.Count; q++)
                        {
                            Token y = t[q];
                            if (y.Is("IF") || y.Is("CASE") || y.Is("FOR") || y.Is("WHILE") || y.Is("REPEAT")) dd++;
                            else if (y.Is("END_IF") || y.Is("END_CASE") || y.Is("END_FOR") || y.Is("END_WHILE") || y.Is("END_REPEAT")) { if (dd == 0) { end = q; break; } dd--; }
                            else if (dd == 0 && (y.Is("ELSIF") || y.Is("ELSE"))) branchOpen = false;
                            else if (dd == 0 && branchOpen && y.Is("RETURN")) ret = true;
                        }
                        if (ret && end >= 0 && end < at) return true;
                    }
                }
                if (x0.Is("IF") || x0.Is("CASE") || x0.Is("FOR") || x0.Is("WHILE") || x0.Is("REPEAT")) d++;
                else if (x0.Is("END_IF") || x0.Is("END_CASE") || x0.Is("END_FOR") || x0.Is("END_WHILE") || x0.Is("END_REPEAT")) d--;
            }
            return false;
        }
    }
}
