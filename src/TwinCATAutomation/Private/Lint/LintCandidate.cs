// TwinCAT Semantic Linter (#252) - LintCandidate (tasks 2.1, design.md D2): an object that is not written yet,
// laid over the project on disk in memory (same name replaced, new object added) or checked alone (text-only).
// Nothing is written: the overlay changes only the in-memory XML tree of this run. C# 5.
namespace TcLintEngine
{
    using System;
    using System.Collections;
    using System.Collections.Generic;
    using System.Collections.Specialized;
    using System.Text;
    using System.Text.RegularExpressions;
    using System.Xml;

    internal sealed partial class LintRun
    {
        private readonly HashSet<string> overlayPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);   // candidate sections (no LineIds check)
        private readonly List<string> contextRequired = new List<string>();   // text-only: why the project is needed
        private string candOverlay;     // replaced / added / text-only
        private string candFile;
        private string candPath;

        private static readonly Regex IdentOnly = new Regex("^[A-Za-z_][A-Za-z0-9_]*$", RegexOptions.CultureInvariant);

        private sealed class CandKind
        {
            public string Element;      // XML element of the candidate itself
            public string Header;       // declaration keyword ("" = not checked)
            public string Ext;          // file extension of a new top-level object
            public bool Member;         // Method / Property / Action: Parent.Member
            public bool HasImpl;        // takes an implementation
        }

        private static CandKind KindOf(string kind, int segments)
        {
            CandKind k = new CandKind();
            switch (kind)
            {
                case "Program": k.Element = "POU"; k.Header = "PROGRAM"; k.Ext = ".TcPOU"; k.HasImpl = true; break;
                case "FunctionBlock": k.Element = "POU"; k.Header = "FUNCTION_BLOCK"; k.Ext = ".TcPOU"; k.HasImpl = true; break;
                case "Function": k.Element = "POU"; k.Header = "FUNCTION"; k.Ext = ".TcPOU"; k.HasImpl = true; break;
                case "DUT": k.Element = "DUT"; k.Header = "TYPE"; k.Ext = ".TcDUT"; break;
                case "GVL": k.Element = "GVL"; k.Header = "VAR_GLOBAL"; k.Ext = ".TcGVL"; break;
                case "Interface": k.Element = "Itf"; k.Header = "INTERFACE"; k.Ext = ".TcIO"; break;
                case "Method": k.Element = "Method"; k.Header = "METHOD"; k.Member = true; k.HasImpl = true; break;
                case "Action": k.Element = "Action"; k.Header = ""; k.Member = true; k.HasImpl = true; break;
                case "Property":
                    k.Member = true;
                    if (segments == 3) { k.Element = "Accessor"; k.Header = ""; k.HasImpl = true; }
                    else { k.Element = "Property"; k.Header = "PROPERTY"; }
                    break;
                default: return null;
            }
            return k;
        }

        private static void Invalid(string message) { throw new ArgumentException("LINT_INPUT_INVALID:" + message); }

        // ---------------------------------------------------------------- input checks (both modes)
        private string[] CandidateSegments(out CandKind k)
        {
            string kind = opt.CandidateKind ?? "";
            string name = (opt.CandidateName ?? "").Trim();
            if (kind == "Transition")
                Invalid("ObjectKind Transition is not supported: the XML structure of a Transition was never observed (verification/xae-generated-xml.md); lint the project after writing it");
            string[] seg = name.Split('.');
            k = KindOf(kind, seg.Length);
            if (k == null) Invalid("Unknown ObjectKind '" + kind + "' (Program, FunctionBlock, Function, DUT, GVL, Interface, Method, Property, Action)");
            foreach (string s in seg) if (!IdentOnly.IsMatch(s)) Invalid("ObjectName '" + name + "' is not a name or Parent.Member");
            int want = k.Member ? 2 : 1;
            bool ok = seg.Length == want || (kind == "Property" && seg.Length == 3 && (seg[2] == "Get" || seg[2] == "Set"));
            if (!ok)
                Invalid(k.Member ? "ObjectName of a " + kind + " is Parent." + kind + (kind == "Property" ? " (or Parent.Property.Get / .Set for an accessor)" : "") + ", got '" + name + "'"
                    : "ObjectName of a " + kind + " is a plain name, got '" + name + "'");
            string decl = opt.CandidateDeclaration ?? "", impl = opt.CandidateImplementation ?? "";
            if (impl.TrimStart().StartsWith("<", StringComparison.Ordinal))
                Invalid("Implementation must be Structured Text; other languages (or XML) are not analysed");
            if (!k.HasImpl && impl.Trim().Length > 0)
                Invalid(kind + (k.Element == "Property" ? " (the property declaration)" : "") + " has no implementation" + (k.Element == "Property" ? ": give the accessor as ObjectName Parent.Property.Get / .Set" : ""));
            if (kind == "Action" && decl.Trim().Length > 0) Invalid("An Action has no declaration (it uses the variables of its POU)");
            if (k.Element != "Accessor" && kind != "Action" && decl.Trim().Length == 0) Invalid("Declaration is empty");
            return seg;
        }

        // declaration keyword and name must match ObjectKind / ObjectName (design.md D2 overlay boundary)
        private void CheckCandidateHeader(CandKind k, string expectedName)
        {
            if (k.Header.Length == 0) return;
            DeclInfo di = StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? "");
            if (string.IsNullOrEmpty(di.HeaderKeyword)) return;   // unreadable header: reported as LINT-PARSE-* by the analysis
            if (di.HeaderKeyword != k.Header)
                Invalid("Declaration starts with " + di.HeaderKeyword + ", ObjectKind " + opt.CandidateKind + " needs " + k.Header);
            if (k.Header != "VAR_GLOBAL" && di.Name != null && !string.Equals(di.Name, expectedName, StringComparison.OrdinalIgnoreCase))
                Invalid("Declaration names '" + di.Name + "', ObjectName is '" + expectedName + "'");
        }

        // ---------------------------------------------------------------- overlay on the project
        private void ApplyOverlay()
        {
            CandKind k;
            string[] seg = CandidateSegments(out k);
            candPath = string.Join(".", seg);
            string topName = seg[0];
            CheckCandidateHeader(k, seg[seg.Length - 1 - (k.Element == "Accessor" ? 1 : 0)]);
            TcObjectFile top = null;
            foreach (TcObjectFile o in objects)
            {
                if (o.Obj != null && string.Equals(o.ObjectPath, topName, StringComparison.OrdinalIgnoreCase)) { top = o; break; }
            }
            if (top == null)
            {
                foreach (TcObjectFile o in objects)
                    if (o.Obj == null && string.Equals(System.IO.Path.GetFileNameWithoutExtension(o.FullPath), topName, StringComparison.OrdinalIgnoreCase))
                        Invalid("The disk version of '" + topName + "' (" + o.Rel + ") cannot be read; run LintProject and repair it first");
            }
            if (!k.Member)
            {
                if (top != null)
                {
                    if (top.Obj.Name != k.Element) Invalid("'" + topName + "' exists in the project as <" + top.Obj.Name + ">, ObjectKind " + opt.CandidateKind + " is <" + k.Element + ">");
                    if (k.Element == "POU")
                    {
                        XElem dd = top.Obj.Child("Declaration");
                        string diskHeader = dd == null ? "" : StAnalyzer.ParseDeclaration(dd.InnerText()).HeaderKeyword;
                        if (!string.IsNullOrEmpty(diskHeader) && diskHeader != k.Header)
                            Invalid("'" + topName + "' exists in the project as " + diskHeader + ", ObjectKind " + opt.CandidateKind + " is " + k.Header);
                    }
                    ReplaceSections(top.Obj, k);
                    candOverlay = "replaced"; candFile = top.Rel;
                }
                else
                {
                    TcObjectFile n = NewObjectFile(topName, k, null);
                    objects.Add(n);
                    candOverlay = "added"; candFile = n.Rel;
                    rulesSkipped.Add(Cov("PROJECT-COMPILE-001", n.Rel, topName, null, "candidate-not-in-project"));
                }
            }
            else
            {
                if (top == null) Invalid("Parent '" + topName + "' of the " + opt.CandidateKind + " does not exist in the project");
                bool itf = top.Obj.Name == "Itf";
                if (top.Obj.Name != "POU" && !(itf && (opt.CandidateKind == "Method" || opt.CandidateKind == "Property")))
                    Invalid("Parent '" + topName + "' is <" + top.Obj.Name + ">, a " + opt.CandidateKind + " needs a POU" + (opt.CandidateKind == "Action" ? "" : " or an interface"));
                if (itf && (opt.CandidateImplementation ?? "").Trim().Length > 0) Invalid("An interface member has no implementation");
                XElem owner = top.Obj;
                string memberName = seg[1];
                if (k.Element == "Accessor")
                {
                    XElem prop = FindMember(owner, memberName);
                    if (prop == null || prop.Name != "Property") Invalid("Property '" + topName + "." + memberName + "' does not exist in the project (write the property declaration first)");
                    XElem acc = prop.Child(seg[2]);
                    if (acc == null)
                    {
                        acc = NewElem(seg[2], prop);
                        acc.Attrs.Add(new KeyValuePair<string, string>("Name", seg[2]));
                        prop.Children.Add(acc);
                        candOverlay = "added";
                    }
                    else candOverlay = "replaced";
                    ReplaceSections(acc, k);
                }
                else
                {
                    XElem m = FindMember(owner, memberName);
                    if (m != null && m.Name != k.Element)
                        Invalid("'" + topName + "." + memberName + "' exists in the project as <" + m.Name + ">, ObjectKind " + opt.CandidateKind + " is <" + k.Element + ">");
                    if (m == null)
                    {
                        m = NewElem(k.Element, owner);
                        m.Attrs.Add(new KeyValuePair<string, string>("Name", memberName));
                        InsertMember(owner, m);
                        candOverlay = "added";
                    }
                    else candOverlay = "replaced";
                    if (itf) { k.HasImpl = false; }
                    ReplaceSections(m, k);
                }
                candFile = top.Rel;
            }
            overlayPaths.Add(candPath);
            // the candidate object is the scope (like LintProject -Scope Object): findings of other objects are not
            // the candidate's (data.scope.note says so); project-level rules still run
            if (opt.CandidateFullScope) return;   // cross-object run: the PowerShell side diffs it against the disk project
            opt.ScopeObjects = new List<string>();
            opt.ScopeObjects.Add(topName);
            foreach (TcObjectFile o in objects) o.InScope = InScope(o.ObjectPath);
        }

        private static XElem FindMember(XElem owner, string name)
        {
            foreach (XElem c in owner.Children)
            {
                if (c.Name != "Method" && c.Name != "Action" && c.Name != "Property" && c.Name != "Transition") continue;
                if (string.Equals(c.Attr("Name"), name, StringComparison.OrdinalIgnoreCase)) return c;
            }
            return null;
        }

        private static XElem NewElem(string name, XElem parent)
        {
            XElem e = new XElem(); e.Name = name; e.Parent = parent; e.Line = parent.Line; e.Col = 1; e.Synthetic = true;
            return e;
        }

        // XAE order inside a POU: Declaration, Implementation, Folder, Action, Method, Property, LineIds (PouOrder)
        private static void InsertMember(XElem owner, XElem m)
        {
            int rank = Array.IndexOf(PouOrder, m.Name);
            int at = owner.Children.Count;
            for (int i = 0; i < owner.Children.Count; i++)
            {
                int r = Array.IndexOf(PouOrder, owner.Children[i].Name);
                if (r > rank) { at = i; break; }
            }
            owner.Children.Insert(at, m);
        }

        private static void SetCData(XElem e, string text)
        {
            e.Texts.Clear();
            XText t = new XText(); t.Kind = XmlNodeType.CDATA; t.Value = text ?? ""; t.Line = e.Line;
            e.Texts.Add(t);
        }

        private void ReplaceSections(XElem owner, CandKind k)
        {
            if (opt.CandidateKind != "Action")
            {
                XElem d = owner.Child("Declaration");
                if (d == null) { d = NewElem("Declaration", owner); owner.Children.Insert(0, d); }
                SetCData(d, opt.CandidateDeclaration);
            }
            if (!k.HasImpl) return;
            XElem impl = owner.Child("Implementation");
            if (impl == null)
            {
                impl = NewElem("Implementation", owner);
                int at = owner.Child("Declaration") == null ? 0 : owner.Children.IndexOf(owner.Child("Declaration")) + 1;
                owner.Children.Insert(at, impl);
            }
            impl.Children.Clear(); impl.Texts.Clear();
            XElem st = NewElem("ST", impl);
            impl.Children.Add(st);
            SetCData(st, opt.CandidateImplementation);
        }

        // ---------------------------------------------------------------- a new object, as XAE writes it (UTF-8 BOM, CRLF)
        private TcObjectFile NewObjectFile(string name, CandKind k, string memberXml)
        {
            string pv = "3.1.4026.18";
            foreach (TcObjectFile o in objects)
            {
                if (o.Xml == null || o.Xml.Root == null) continue;
                string v = o.Xml.Root.Attr("ProductVersion");
                if (v != null && (v.StartsWith("3.1.4024.", StringComparison.Ordinal) || v.StartsWith("3.1.4026.", StringComparison.Ordinal))) { pv = v; break; }
            }
            StringBuilder sb = new StringBuilder();
            sb.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n");
            sb.Append("<TcPlcObject Version=\"1.1.0.1\" ProductVersion=\"").Append(pv).Append("\">\r\n");
            sb.Append("  <").Append(k.Element).Append(" Name=\"").Append(name).Append('"').Append(k.Element == "POU" ? " SpecialFunc=\"None\"" : "").Append(">\r\n");
            sb.Append("    <Declaration><![CDATA[").Append(CData(memberXml == null ? opt.CandidateDeclaration : "FUNCTION_BLOCK " + name + "\r\nVAR\r\nEND_VAR\r\n")).Append("]]></Declaration>\r\n");
            if (k.Element == "POU")
            {
                sb.Append("    <Implementation>\r\n      <ST><![CDATA[").Append(CData(memberXml == null ? opt.CandidateImplementation : "")).Append("]]></ST>\r\n    </Implementation>\r\n");
                if (memberXml != null) sb.Append(memberXml);
            }
            sb.Append("  </").Append(k.Element).Append(">\r\n</TcPlcObject>");
            byte[] body = new UTF8Encoding(false).GetBytes(sb.ToString());
            byte[] bytes = new byte[body.Length + 3];
            bytes[0] = 0xEF; bytes[1] = 0xBB; bytes[2] = 0xBF;
            Buffer.BlockCopy(body, 0, bytes, 3, body.Length);
            TcObjectFile f = new TcObjectFile();
            f.Ext = k.Element == "POU" || memberXml != null ? ".TcPOU" : k.Ext;
            f.Rel = name + f.Ext;
            f.FullPath = System.IO.Path.Combine(plcDir ?? "", f.Rel);
            f.Name = name; f.ObjectPath = name;
            f.Bytes = XmlLoader.FromBytes(bytes);
            f.Xml = XmlLoader.Load(f.FullPath, f.Bytes);
            if (f.Xml.WellFormed && f.Xml.Root != null) foreach (XElem c in f.Xml.Root.Children) { f.Obj = c; break; }
            if (f.Obj == null) throw new InvalidOperationException("candidate object XML not readable: " + f.Xml.ErrorDetail);
            f.Kind = f.Obj.Name;
            MarkSynthetic(f.Obj);
            return f;
        }

        // a ']]>' inside the code is written the way XAE writes it: split over two CDATA sections
        private static string CData(string s) { return (s ?? "").Replace("]]>", "]]]]><![CDATA[>"); }

        private static void MarkSynthetic(XElem e)
        {
            e.Synthetic = true;
            foreach (XElem c in e.Children) MarkSynthetic(c);
        }

        // ---------------------------------------------------------------- text-only (no project)
        private OrderedDictionary ExecuteTextOnly()
        {
            plcFull = null; plcDir = ""; plcRel = "";
            projectLoaded = true;
            CandKind k;
            string[] seg = CandidateSegments(out k);
            candPath = string.Join(".", seg);
            CheckCandidateHeader(k, seg[seg.Length - 1 - (k.Element == "Accessor" ? 1 : 0)]);
            candOverlay = "text-only";
            if (opt.CandidateKind == "Property")
            {
                // a property (or accessor) is checked with its POU only: nothing runs text-only
                contextRequired.Add("object-kind:Property");
                rulesNotRun.Add(Cov(null, seg[0] + ".TcPOU", candPath, null, "text-only-property"));
                return Finish();
            }
            TcObjectFile f;
            if (k.Member)
            {
                contextRequired.Add("object-kind:" + opt.CandidateKind);
                StringBuilder m = new StringBuilder();
                m.Append("    <").Append(k.Element).Append(" Name=\"").Append(seg[1]).Append("\">\r\n");
                if (opt.CandidateKind != "Action") m.Append("      <Declaration><![CDATA[").Append(CData(opt.CandidateDeclaration)).Append("]]></Declaration>\r\n");
                m.Append("      <Implementation>\r\n        <ST><![CDATA[").Append(CData(opt.CandidateImplementation)).Append("]]></ST>\r\n      </Implementation>\r\n");
                m.Append("    </").Append(k.Element).Append(">\r\n");
                CandKind pou = KindOf("FunctionBlock", 1);
                f = NewObjectFile(seg[0], pou, m.ToString());
            }
            else f = NewObjectFile(seg[0], k, null);
            candFile = f.Rel;
            overlayPaths.Add(candPath);
            f.InScope = true;
            objects.Add(f);
            CheckObject(f);
            RunPhase1b();
            if (!k.Member) FindContextNeeds(k);
            return Finish();
        }

        // Standard functions / operators usable without a project (IEC 61131-3 and TwinCAT built-ins); anything else
        // that is not declared in the candidate needs the project (design.md D2: text-only never passes silently)
        private static readonly HashSet<string> BuiltinNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
            "ABS", "SQRT", "LN", "LOG", "EXP", "EXPT", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ADD", "SUB", "MUL", "DIV", "MOVE",
            "SEL", "MAX", "MIN", "LIMIT", "MUX", "SHL", "SHR", "ROL", "ROR", "LEN", "LEFT", "RIGHT", "MID", "CONCAT", "INSERT", "DELETE",
            "REPLACE", "FIND", "SIZEOF", "ADR", "ADRINST", "BITADR", "INDEXOF", "TRUNC", "TRUNC_INT", "LOWER_BOUND", "UPPER_BOUND", "REF",
            "__NEW", "__DELETE", "__ISVALIDREF", "__QUERYINTERFACE", "__QUERYPOINTER", "__VARINFO", "__POSITION", "__POUNAME", "__CURRENTTASK" };
        private static readonly Regex ConversionRx = new Regex("^([A-Z_]+_)?TO_[A-Z_]+$", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

        private void FindContextNeeds(CandKind k)
        {
            DeclInfo di = StAnalyzer.ParseDeclaration(opt.CandidateDeclaration ?? "");
            foreach (string x in di.Extends) contextRequired.Add("extends:" + x);
            foreach (string x in di.Implements) contextRequired.Add("implements:" + x);
            HashSet<string> local = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            local.Add(candPath);
            if (di.Type != null)
            {
                foreach (VarDecl v in di.Type.Members) foreach (string n in v.Names) local.Add(n);
                foreach (EnumMember em in di.Type.EnumMembers) local.Add(em.Name);
                if (di.Type.Extends != null) contextRequired.Add("extends:" + di.Type.Extends);
                if (di.Type.Kind == "ALIAS" && di.Type.BaseType != null) CheckTypeNeeds(di.Type.BaseType, local);
                if (di.Type.Kind == "ENUM" && di.Type.BaseType != null) CheckTypeNeeds(di.Type.BaseType, local);
            }
            foreach (VarBlock b in di.VarBlocks)
            {
                if (b.Kind == "VAR_EXTERNAL") contextRequired.Add("var-external");
                foreach (VarDecl v in b.Vars) foreach (string n in v.Names) local.Add(n);
            }
            List<VarDecl> all = new List<VarDecl>();
            if (di.Type != null) all.AddRange(di.Type.Members);
            foreach (VarBlock b in di.VarBlocks) all.AddRange(b.Vars);
            if (di.ReturnType != null) CheckTypeNeeds(di.ReturnType, local);
            foreach (VarDecl v in all)
            {
                if (v.TypeText != null) CheckTypeNeeds(v.TypeText, local);
                if (v.InitText != null) CheckIdentNeeds(StLexer.Lex(v.InitText).Tokens, local);
            }
            if (k.HasImpl)
            {
                // every identifier that starts a designator, except a named call parameter (depth > 0 and followed by := / =>)
                List<Token> toks = StLexer.Lex(opt.CandidateImplementation ?? "").Tokens;
                // JMP labels ("lbl:" at a statement start, "JMP lbl") are declared by the code itself (review nit 2)
                for (int i = 0; i + 1 < toks.Count; i++)
                {
                    if (toks[i].Kind != TokKind.Ident) continue;
                    bool labelDef = toks[i + 1].IsOp(":") && (i == 0 || toks[i - 1].IsOp(";"));
                    bool jumpTarget = i > 0 && toks[i - 1].Is("JMP");
                    if (labelDef || jumpTarget) local.Add(toks[i].Text);
                }
                int depth = 0;
                for (int i = 0; i < toks.Count; i++)
                {
                    Token t = toks[i];
                    if (t.IsOp("(")) { depth++; continue; }
                    if (t.IsOp(")")) { if (depth > 0) depth--; continue; }
                    if (t.Kind != TokKind.Ident || StLexer.Keywords.Contains(t.Upper)) continue;
                    if (i > 0 && (toks[i - 1].IsOp(".") || toks[i - 1].IsOp("#"))) continue;
                    if (depth > 0 && i + 1 < toks.Count && (toks[i + 1].IsOp(":=") || toks[i + 1].IsOp("=>"))) continue;
                    if (!Known(t.Text, local)) AddNeed("identifier:" + t.Text);
                }
            }
        }

        private void AddNeed(string reason) { if (!contextRequired.Contains(reason)) contextRequired.Add(reason); }

        private bool Known(string name, HashSet<string> local)
        {
            if (local.Contains(name) || BuiltinNames.Contains(name) || ConversionRx.IsMatch(name) || Elementary.Contains(name)) return true;
            if (string.Equals(name, "THIS", StringComparison.OrdinalIgnoreCase)) return true;   // the candidate itself (SUPER needs EXTENDS: reported through extends:)
            foreach (CatalogType c in opt.CatalogTypes) if (string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        private void CheckIdentNeeds(List<Token> tokens, HashSet<string> local)
        {
            for (int i = 0; i < tokens.Count; i++)
            {
                Token t = tokens[i];
                if (t.Kind != TokKind.Ident || StLexer.Keywords.Contains(t.Upper)) continue;
                if (i > 0 && tokens[i - 1].IsOp(".")) continue;   // member of something already checked
                if (i + 1 < tokens.Count && tokens[i + 1].IsOp(":=")) continue;   // FB_init / structure initialiser parameter name
                if (!Known(t.Text, local)) AddNeed("identifier:" + t.Text);
            }
        }

        // ARRAY[..] OF / POINTER TO / REFERENCE TO / STRING(n) / FB_X(params) / FB_X<n>: the base type must be elementary or
        // in the type catalog, identifiers in bounds / lengths must be declared in the candidate
        private void CheckTypeNeeds(string typeText, HashSet<string> local)
        {
            List<Token> toks = StLexer.Lex(typeText).Tokens;
            int i = 0;
            while (i < toks.Count && toks[i].Kind != TokKind.EOF)
            {
                Token t = toks[i];
                if (t.Is("ARRAY"))
                {
                    int depth = 0; i++;
                    while (i < toks.Count && toks[i].Kind != TokKind.EOF)
                    {
                        if (toks[i].IsOp("[")) depth++;
                        else if (toks[i].IsOp("]")) { depth--; if (depth == 0) { i++; break; } }
                        else if (toks[i].Kind == TokKind.Ident && !StLexer.Keywords.Contains(toks[i].Upper) && !(i > 0 && toks[i - 1].IsOp(".")) && !Known(toks[i].Text, local))
                            AddNeed("identifier:" + toks[i].Text);
                        i++;
                    }
                    if (i < toks.Count && toks[i].Is("OF")) i++;
                    continue;
                }
                if (t.Is("POINTER") || t.Is("REFERENCE")) { i++; if (i < toks.Count && toks[i].Is("TO")) i++; continue; }
                if (t.Kind == TokKind.Ident)
                {
                    StringBuilder q = new StringBuilder(t.Text); i++;
                    while (i + 1 < toks.Count && toks[i].IsOp(".") && toks[i + 1].Kind == TokKind.Ident) { q.Append('.').Append(toks[i + 1].Text); i += 2; }
                    string name = q.ToString();
                    if (!Known(name, local)) AddNeed("type:" + name);
                    CheckIdentNeeds(toks.GetRange(i, toks.Count - i), local);   // STRING(cLen), FB_X(nParam := c)
                    return;
                }
                i++;
            }
        }

        private OrderedDictionary CandidateInfo()
        {
            OrderedDictionary c = new OrderedDictionary();
            c["objectKind"] = opt.CandidateKind;
            c["objectPath"] = candPath;
            c["file"] = candFile;
            c["overlay"] = candOverlay;
            List<string> need = new List<string>(contextRequired); need.Sort(StringComparer.Ordinal);
            c["contextRequired"] = new ArrayList(need);
            return c;
        }
    }
}
