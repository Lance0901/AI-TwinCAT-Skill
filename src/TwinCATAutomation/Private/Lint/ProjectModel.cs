// TwinCAT Semantic Linter (#252) - reading project files from disk. C# 5.
// XML is read with XmlReader only: DtdProcessing = Prohibit, XmlResolver = null (no DTD, no
// external entity is ever resolved; design.md D1). Structure facts: research/tc-xml-schema-observed.md.
namespace TcLintEngine
{
    using System;
    using System.Collections.Generic;
    using System.IO;
    using System.Text;
    using System.Text.RegularExpressions;
    using System.Xml;

    public sealed class XText
    {
        public XmlNodeType Kind;   // Text / CDATA / Whitespace / SignificantWhitespace
        public string Value;
        public int Line;
    }

    public sealed class XElem
    {
        public string Name;        // local name
        public List<KeyValuePair<string, string>> Attrs = new List<KeyValuePair<string, string>>();
        public List<XElem> Children = new List<XElem>();
        public List<XText> Texts = new List<XText>();
        public int Line;
        public int Col;
        public XElem Parent;
        public bool Synthetic;     // created by the LintCandidate overlay (not in any file): no Id is expected

        public string Attr(string name)
        {
            foreach (KeyValuePair<string, string> a in Attrs) if (a.Key == name) return a.Value;
            return null;
        }

        public bool HasAttr(string name) { return Attr(name) != null; }

        public XElem Child(string name)
        {
            foreach (XElem c in Children) if (c.Name == name) return c;
            return null;
        }

        public List<XElem> All(string name)
        {
            List<XElem> l = new List<XElem>();
            foreach (XElem c in Children) if (c.Name == name) l.Add(c);
            return l;
        }

        public string InnerText()
        {
            StringBuilder sb = new StringBuilder();
            foreach (XText t in Texts) sb.Append(t.Value);
            return sb.ToString();
        }

        public int CDataCount()
        {
            int n = 0;
            foreach (XText t in Texts) if (t.Kind == XmlNodeType.CDATA) n++;
            return n;
        }

        // non-white-space text outside CDATA
        public XText StrayText()
        {
            foreach (XText t in Texts) if (t.Kind == XmlNodeType.Text && t.Value.Trim().Length > 0) return t;
            return null;
        }
    }

    public sealed class FileBytesInfo
    {
        public bool Exists;
        public bool ReadFailed;
        public string ReadError;      // engineDetail only (localised .NET text)
        public byte[] Bytes;
        public string Bom;            // utf-8 / utf-16le / utf-16be / null
        public string DeclaredEncoding;
        public bool HasDeclaration;
        public int CrLf;
        public int BareLf;
        public int BareCr;
        public bool NonAscii;
        public bool InvalidUtf8;
        public int InvalidUtf8Offset;
        public bool TooLarge;
        public long Length;
        public bool EncodingMismatch;   // BOM and encoding declaration disagree: the file is not parsed
    }

    public sealed class XmlLoad
    {
        public FileBytesInfo Info;
        public XElem Root;
        public bool WellFormed;
        public string ErrorDetail;    // engineDetail only
        public int ErrorLine;
        public int ErrorCol;
        public bool ExtraRoot;
    }

    public static class XmlLoader
    {
        // Elements whose content is serialized data, not structure the rules look at (CFC / Visu
        // XmlArchive, plcproj ProjectExtensions): read through (well-formedness is still checked)
        // without building nodes.
        private static readonly HashSet<string> SkipContent = new HashSet<string>(StringComparer.Ordinal) { "XmlArchive" };

        private static readonly Regex DeclRx = new Regex("^<\\?xml[^>]*?encoding\\s*=\\s*[\"']([^\"']+)[\"']", RegexOptions.CultureInvariant);

        public static FileBytesInfo ReadBytes(string path) { return ReadBytes(path, long.MaxValue); }

        // maxBytes: larger files are not read (TooLarge); a 50 MB file cost 3.3 GB of memory (second review should-fix 5).
        // Only I/O errors are caught: anything else (OutOfMemoryException ...) is an engine error.
        public static FileBytesInfo ReadBytes(string path, long maxBytes)
        {
            FileBytesInfo fi = new FileBytesInfo();
            if (!File.Exists(path)) return fi;
            fi.Exists = true;
            try
            {
                fi.Length = new FileInfo(path).Length;
                if (fi.Length > maxBytes) { fi.TooLarge = true; return fi; }
                fi.Bytes = File.ReadAllBytes(path);
            }
            catch (IOException e) { fi.ReadFailed = true; fi.ReadError = e.GetType().Name + ": " + e.Message; return fi; }
            catch (UnauthorizedAccessException e) { fi.ReadFailed = true; fi.ReadError = e.GetType().Name + ": " + e.Message; return fi; }
            return Analyze(fi);
        }

        // LintCandidate: an object file that exists only in memory (overlay of a new object)
        public static FileBytesInfo FromBytes(byte[] bytes)
        {
            FileBytesInfo fi = new FileBytesInfo();
            fi.Exists = true; fi.Bytes = bytes; fi.Length = bytes.Length;
            return Analyze(fi);
        }

        private static FileBytesInfo Analyze(FileBytesInfo fi)
        {
            byte[] b = fi.Bytes;
            int start = 0;
            if (b.Length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) { fi.Bom = "utf-8"; start = 3; }
            else if (b.Length >= 2 && b[0] == 0xFF && b[1] == 0xFE) { fi.Bom = "utf-16le"; start = 2; }
            else if (b.Length >= 2 && b[0] == 0xFE && b[1] == 0xFF) { fi.Bom = "utf-16be"; start = 2; }
            if (fi.Bom == null || fi.Bom == "utf-8")
            {
                for (int i = start; i < b.Length; i++)
                {
                    byte x = b[i];
                    if (x == 0x0D) { if (i + 1 < b.Length && b[i + 1] == 0x0A) { fi.CrLf++; i++; } else fi.BareCr++; }
                    else if (x == 0x0A) fi.BareLf++;
                    else if (x > 0x7F) fi.NonAscii = true;
                }
                int head = Math.Min(b.Length - start, 400);
                string prolog = Encoding.ASCII.GetString(b, start, Math.Max(0, head));
                if (prolog.StartsWith("<?xml", StringComparison.Ordinal))
                {
                    fi.HasDeclaration = true;
                    Match m = DeclRx.Match(prolog);
                    if (m.Success) fi.DeclaredEncoding = m.Groups[1].Value;
                }
                try { new UTF8Encoding(false, true).GetString(b, start, b.Length - start); }
                catch (DecoderFallbackException e) { fi.InvalidUtf8 = true; fi.InvalidUtf8Offset = e.Index; }
            }
            else
            {
                // UTF-16: read the declaration from the decoded start
                int head = Math.Min(b.Length - start, 800);
                string prolog = (fi.Bom == "utf-16le" ? Encoding.Unicode : Encoding.BigEndianUnicode).GetString(b, start, head - head % 2);
                if (prolog.StartsWith("<?xml", StringComparison.Ordinal))
                {
                    fi.HasDeclaration = true;
                    Match m = DeclRx.Match(prolog);
                    if (m.Success) fi.DeclaredEncoding = m.Groups[1].Value;
                }
            }
            string d = fi.DeclaredEncoding == null ? null : fi.DeclaredEncoding.ToLowerInvariant();
            if (d != null)
            {
                bool utf8 = d == "utf-8" || d == "utf8";
                bool utf16 = d.StartsWith("utf-16", StringComparison.Ordinal) || d == "unicode";
                if ((fi.Bom == "utf-8" && !utf8) || ((fi.Bom == "utf-16le" || fi.Bom == "utf-16be") && !utf16)) fi.EncodingMismatch = true;
            }
            return fi;
        }

        public static XmlLoad Load(string path, FileBytesInfo fi)
        {
            XmlLoad r = new XmlLoad();
            r.Info = fi;
            if (!fi.Exists || fi.ReadFailed) return r;
            XmlReaderSettings s = new XmlReaderSettings();
            s.DtdProcessing = DtdProcessing.Prohibit;
            s.XmlResolver = null;
            s.IgnoreComments = true;
            s.IgnoreProcessingInstructions = true;
            s.IgnoreWhitespace = false;
            s.CloseInput = true;
            try
            {
                using (MemoryStream ms = new MemoryStream(fi.Bytes, false))
                using (XmlReader xr = XmlReader.Create(ms, s))
                {
                    IXmlLineInfo li = (IXmlLineInfo)xr;
                    XElem cur = null;
                    int skipDepth = -1;
                    while (xr.Read())
                    {
                        if (skipDepth >= 0)
                        {
                            if (xr.NodeType == XmlNodeType.EndElement && xr.Depth == skipDepth) skipDepth = -1;
                            continue;
                        }
                        switch (xr.NodeType)
                        {
                            case XmlNodeType.Element:
                                {
                                    XElem e = new XElem();
                                    e.Name = xr.LocalName; e.Line = li.LineNumber; e.Col = li.LinePosition; e.Parent = cur;
                                    bool empty = xr.IsEmptyElement;
                                    int depth = xr.Depth;
                                    if (xr.MoveToFirstAttribute())
                                    {
                                        do
                                        {
                                            if (xr.Prefix == "xmlns" || xr.LocalName == "xmlns") continue;
                                            e.Attrs.Add(new KeyValuePair<string, string>(xr.LocalName, xr.Value));
                                        } while (xr.MoveToNextAttribute());
                                        xr.MoveToElement();
                                    }
                                    if (cur == null) { if (r.Root == null) r.Root = e; else r.ExtraRoot = true; }
                                    else cur.Children.Add(e);
                                    if (empty) break;
                                    if (SkipContent.Contains(e.Name)) { skipDepth = depth; break; }
                                    cur = e;
                                    break;
                                }
                            case XmlNodeType.EndElement:
                                if (cur != null) cur = cur.Parent;
                                break;
                            case XmlNodeType.Text:
                            case XmlNodeType.CDATA:
                            case XmlNodeType.Whitespace:
                            case XmlNodeType.SignificantWhitespace:
                                if (cur != null) { XText t = new XText(); t.Kind = xr.NodeType; t.Value = xr.Value; t.Line = li.LineNumber; cur.Texts.Add(t); }
                                break;
                        }
                    }
                }
                r.WellFormed = r.Root != null;
                if (r.Root == null) { r.ErrorDetail = "no root element"; r.ErrorLine = 1; r.ErrorCol = 1; }
            }
            catch (XmlException e)
            {
                r.WellFormed = false; r.ErrorDetail = "XmlException: " + e.Message; r.ErrorLine = e.LineNumber; r.ErrorCol = e.LinePosition;
            }
            catch (ArgumentException e)
            {
                // unknown encoding name in the XML declaration
                r.WellFormed = false; r.ErrorDetail = e.GetType().Name + ": " + e.Message; r.ErrorLine = 1; r.ErrorCol = 1;
            }
            // anything else (OutOfMemoryException ...) is an engine error, never reported as PROJECT-XML-001
            return r;
        }

    }

    // ---------------------------------------------------------------- MSBuild paths
    public static class MsPath
    {
        // MSBuild escaping: %XX (two hex digits). Returns null when a '%' is not followed by two hex digits.
        public static string Unescape(string s, out bool badEscape)
        {
            badEscape = false;
            if (s.IndexOf('%') < 0) return s;
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < s.Length; i++)
            {
                if (s[i] == '%')
                {
                    if (i + 2 < s.Length && IsHex(s[i + 1]) && IsHex(s[i + 2]))
                    {
                        sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 2), 16));
                        i += 2;
                        continue;
                    }
                    badEscape = true;
                }
                sb.Append(s[i]);
            }
            return sb.ToString();
        }

        private static bool IsHex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

        public static string Full(string baseDir, string rel)
        {
            try { return Path.GetFullPath(Path.Combine(baseDir, rel.Replace('/', '\\'))); }
            catch (Exception) { return null; }
        }

        public static string Relative(string baseDir, string full)
        {
            string b = baseDir.TrimEnd('\\') + "\\";
            if (full.StartsWith(b, StringComparison.OrdinalIgnoreCase)) return full.Substring(b.Length).Replace('\\', '/');
            try
            {
                Uri bu = new Uri(b), fu = new Uri(full);
                return Uri.UnescapeDataString(bu.MakeRelativeUri(fu).ToString()).Replace('\\', '/');
            }
            catch (Exception) { return full.Replace('\\', '/'); }
        }

        // Exact on-disk spelling of each segment of 'rel' below baseDir; null when a segment does not exist.
        public static string DiskSpelling(string baseDir, string rel)
        {
            string[] parts = rel.Replace('/', '\\').Split(new char[] { '\\' }, StringSplitOptions.RemoveEmptyEntries);
            string cur = baseDir;
            List<string> outParts = new List<string>();
            foreach (string p in parts)
            {
                if (p == ".") continue;
                if (p == "..") { cur = Path.GetDirectoryName(cur); outParts.Add(".."); continue; }
                string found = null;
                try
                {
                    foreach (string e in Directory.GetFileSystemEntries(cur, p))
                    {
                        string name = Path.GetFileName(e);
                        if (string.Equals(name, p, StringComparison.OrdinalIgnoreCase)) { found = name; break; }
                    }
                }
                catch (Exception) { return null; }
                if (found == null) return null;
                outParts.Add(found);
                cur = Path.Combine(cur, found);
            }
            return string.Join("\\", outParts.ToArray());
        }
    }
}
