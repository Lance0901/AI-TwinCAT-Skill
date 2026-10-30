# ConsumeXml fragment handling (complete-automation-interface phase 1, task 2.2; design D3).
# Measured 2026-10-30 (4026 VS2022, XAE 3.1.4026.18, TIRT^PlcTask, offline, self-built client;
# openspec/changes/complete-automation-interface/verification/phase1-2.1-consumexml.md):
#   - ConsumeXml merges a fragment (TE1000 v1.7.0 5.2.1.1: "XML document or XML snippet"); fields not in
#     the fragment keep their value, so the fragment is sent as-is (no merge on our side).
#   - the root must be <TreeItem> (else E_FAIL "No TreeItem found."), syntax errors give E_FAIL;
#   - unknown elements / wrong paths are IGNORED SILENTLY (S_OK, nothing changed) -> every leaf path of
#     the fragment must exist in the current ProduceXml before sending (XML_MERGE_FAILED otherwise);
#   - values are not validated (CycleTime 0 / negative / text accepted) -> $script:TcTreeItemFieldRules;
#   - derived fields change with the target field (TcModuleInstance ... Context, ParameterValues) ->
#     excluded from the readback comparison.
# NOT measured, therefore refused before anything is sent (XML_MERGE_FAILED, data.reason):
#   - attributes in the fragment (attributes-not-supported): only element values are sent;
#   - a fragment leaf that is an element with child elements in the current XML, or text next to
#     child elements in the fragment (structure-mismatch);
#   - repeated sibling elements (same name) whose number differs from the current XML
#     (repeated-count-mismatch): how XAE merges fewer / more repeated elements is unknown;
#   - a fragment whose changed leaves are all derived fields (derived-only): nothing could be read back.
# After a write every leaf of the whole ProduceXml (attributes included) outside the fragment and not
# derived must be unchanged (Compare-TcTreeItemXmlFull; TREEITEM_VERIFY_FAILED data.unexpectedChanges).
# XmlNode members are read through get_Name() / get_ChildNodes() / ...: the PowerShell XML adapter lets a
# child element shadow a property ($el.Name is the text of a child <Name>, $el.Value of a child <Value>).

# Known-field value rules. Extend by adding an entry: Path = leaf path without position indexes
# (case-insensitive), Validate = scriptblock param($value) returning $null (ok) or the reason.
$script:TcTreeItemFieldRules = @(
    @{
        Path     = 'TreeItem/TaskDef/CycleTime'
        Rule     = 'positive integer (unit 100 ns; 20000 = 2 ms)'
        # XAE accepts 0, negative numbers and text (stored as 0): measured 2026-10-30, task 2.1.
        Validate = {
            param([string]$Value)
            $v = $Value.Trim()
            $n = [long]0
            if (-not [long]::TryParse($v, [System.Globalization.NumberStyles]::Integer, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return "'$Value' is not an integer" }
            if ($n -le 0) { return "$n is not > 0" }
            if ($n -gt [uint32]::MaxValue) { return "$n is larger than UDINT max" }
            return $null
        }
    }
)

function Test-TcXmlPathDerived {
    <#
    .SYNOPSIS
        True when the element names (root excluded) lie below a TcModuleInstance element inside
        Context or ParameterValues (fields XAE recomputes, measured 2026-10-30 task 2.1).
    .PARAMETER Names
        Element names from below the root down to the leaf.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][string[]]$Names)
    $list = @($Names)
    $mi = [array]::IndexOf([string[]]$list, 'TcModuleInstance')
    if ($mi -lt 0) { return $false }
    for ($k = $mi + 1; $k -lt $list.Count; $k++) { if ($list[$k] -eq 'Context' -or $list[$k] -eq 'ParameterValues') { return $true } }
    return $false
}

function Get-TcXmlLeafList {
    <#
    .SYNOPSIS
        Leaf elements below an XML element: { path; key; segments; value; derived; isAttribute }.
    .DESCRIPTION
        A leaf is an element without child elements. path is the element path from the root
        ('TreeItem/TaskDef/CycleTime'); a segment gets a 1-based [n] when its parent has more than one
        child element with that name ('CPU[2]'). key is path without indexes (used for
        $script:TcTreeItemFieldRules). segments = @(@{ name; index; count }) without the root (count =
        number of sibling elements with that name in the parent). derived = the leaf lies below a
        TcModuleInstance element inside Context or ParameterValues (recomputed by XAE, excluded from
        the readback comparison). With -IncludeAttributes every attribute of every element (root
        included) is listed too, as '<element path>/@<name>' (isAttribute = $true); used by the
        whole-XML comparison after a write.
    .PARAMETER Root
        Root XmlElement (the fragment's TreeItem).
    .PARAMETER IncludeAttributes
        Also list attributes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root, [switch]$IncludeAttributes)
    $list = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Node = $Root; Path = $Root.get_Name(); Key = $Root.get_Name(); Segments = @() })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $names = @($cur.Segments | ForEach-Object { $_.name })
        $derived = Test-TcXmlPathDerived -Names $names
        if ($IncludeAttributes -and $null -ne $cur.Node.get_Attributes()) {
            foreach ($a in $cur.Node.get_Attributes()) {
                $list.Add([PSCustomObject]@{ path = "$($cur.Path)/@$($a.get_Name())"; key = "$($cur.Key)/@$($a.get_Name())"; segments = $cur.Segments; value = [string]$a.get_Value(); derived = $derived; isAttribute = $true })
            }
        }
        $kids = @($cur.Node.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element })
        if ($kids.Count -eq 0) {
            if ($cur.Segments.Count -eq 0) { continue }   # the root itself
            $list.Add([PSCustomObject]@{ path = $cur.Path; key = $cur.Key; segments = $cur.Segments; value = [string]$cur.Node.get_InnerText(); derived = $derived; isAttribute = $false })
            continue
        }
        $counts = @{}
        foreach ($k in $kids) { if ($counts.ContainsKey($k.get_Name())) { $counts[$k.get_Name()]++ } else { $counts[$k.get_Name()] = 1 } }
        $seen = @{}
        $ordered = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $kids) {
            if ($seen.ContainsKey($k.get_Name())) { $seen[$k.get_Name()]++ } else { $seen[$k.get_Name()] = 1 }
            $idx = $seen[$k.get_Name()]
            $seg = if ($counts[$k.get_Name()] -gt 1) { "$($k.get_Name())[$idx]" } else { $k.get_Name() }
            $ordered.Add(@{ Node = $k; Path = "$($cur.Path)/$seg"; Key = "$($cur.Key)/$($k.get_Name())"; Segments = @($cur.Segments + @(@{ name = $k.get_Name(); index = $idx; count = $counts[$k.get_Name()] })) })
        }
        # Stack: push in reverse so leaves come out in document order.
        for ($j = $ordered.Count - 1; $j -ge 0; $j--) { $stack.Push($ordered[$j]) }
    }
    return $list.ToArray()
}

function Find-TcXmlElementBySegments {
    <#
    .SYNOPSIS
        Element below -Root reached through -Segments (@{ name; index }), or $null.
    .PARAMETER Root
        Root XmlElement of the current ProduceXml.
    .PARAMETER Segments
        Segments from Get-TcXmlLeafList (root excluded).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root, [Parameter()][AllowEmptyCollection()][object[]]$Segments)
    $node = $Root
    foreach ($s in @($Segments)) {
        $n = 0
        $next = $null
        foreach ($c in $node.get_ChildNodes()) {
            if ($c.get_NodeType() -ne [System.Xml.XmlNodeType]::Element -or $c.get_Name() -ne $s.name) { continue }
            $n++
            if ($n -eq [int]$s.index) { $next = $c; break }
        }
        if ($null -eq $next) { return $null }
        $node = $next
    }
    return $node
}

function Get-TcXmlMixedContentPathList {
    <#
    .SYNOPSIS
        Paths of elements below -Root that have child elements AND non-blank text (e.g.
        <TaskDef>123<CycleTime>1</CycleTime></TaskDef>): such text cannot be matched to a leaf.
    .PARAMETER Root
        Root XmlElement.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    $out = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Node = $Root; Path = $Root.get_Name() })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $kids = @($cur.Node.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element })
        if ($kids.Count -eq 0) { continue }
        $text = @($cur.Node.get_ChildNodes() | Where-Object { ($_.get_NodeType() -eq [System.Xml.XmlNodeType]::Text -or $_.get_NodeType() -eq [System.Xml.XmlNodeType]::CDATA) -and -not [string]::IsNullOrWhiteSpace($_.get_Value()) })
        if ($text.Count -gt 0) { $out.Add([string]$cur.Path) }
        foreach ($k in $kids) { $stack.Push(@{ Node = $k; Path = "$($cur.Path)/$($k.get_Name())" }) }
    }
    return $out.ToArray()
}

function ConvertFrom-TcTreeItemFragment {
    <#
    .SYNOPSIS
        Parses a ConsumeXml fragment: @{ Doc; Leaves; Error; Reason; Paths }.
    .DESCRIPTION
        Error / Reason are set (Doc / Leaves $null) when the XML does not parse ('syntax'), the root is
        not <TreeItem> ('root'; XAE would return E_FAIL "No TreeItem found.", task 2.1), it has no
        leaf element ('empty'), any element carries an attribute ('attributes-not-supported', Paths =
        the attribute paths; how XAE merges attributes is not measured) or an element has text next to
        child elements ('structure-mismatch', Paths = those elements).
    .PARAMETER Xml
        The fragment, e.g. <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return @{ Doc = $null; Leaves = $null; Reason = 'empty'; Error = 'the XML fragment is empty'; Paths = @() } }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml) }
    catch { return @{ Doc = $null; Leaves = $null; Reason = 'syntax'; Error = "the XML fragment does not parse: $($_.Exception.Message)"; Paths = @() } }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.get_Name() -ne 'TreeItem') {
        $rootName = if ($null -ne $doc.DocumentElement) { $doc.DocumentElement.get_Name() } else { '' }
        return @{ Doc = $null; Leaves = $null; Reason = 'root'; Error = "the root element must be <TreeItem> (as in ProduceXml), got <$rootName>"; Paths = @() }
    }
    $attrs = @(Get-TcXmlLeafList -Root $doc.DocumentElement -IncludeAttributes | Where-Object { $_.isAttribute } | ForEach-Object { $_.path })
    if ($attrs.Count -gt 0) {
        return @{ Doc = $null; Leaves = $null; Reason = 'attributes-not-supported'; Paths = $attrs
            Error = "the fragment has XML attributes ($($attrs -join ', ')); only element values are supported (how XAE merges attributes is not measured)" }
    }
    $mixed = @(Get-TcXmlMixedContentPathList -Root $doc.DocumentElement)
    if ($mixed.Count -gt 0) {
        return @{ Doc = $null; Leaves = $null; Reason = 'structure-mismatch'; Paths = $mixed
            Error = "the fragment has text next to child elements in $($mixed -join ', '); a value belongs in a leaf element only" }
    }
    $leaves = @(Get-TcXmlLeafList -Root $doc.DocumentElement)
    if ($leaves.Count -eq 0) { return @{ Doc = $null; Leaves = $null; Reason = 'empty'; Error = 'the fragment has no element below <TreeItem>; nothing to write'; Paths = @() } }
    return @{ Doc = $doc; Leaves = $leaves; Reason = $null; Error = $null; Paths = @() }
}

function Test-TcTreeItemFieldValues {
    <#
    .SYNOPSIS
        Checks fragment leaves against $script:TcTreeItemFieldRules; returns the violations
        @(@{ path; value; rule; reason }) (empty when all are valid).
    .PARAMETER Leaves
        Output of Get-TcXmlLeafList.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Leaves)
    $bad = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $Leaves) {
        foreach ($r in $script:TcTreeItemFieldRules) {
            if ($l.key -ine $r.Path) { continue }
            $why = & $r.Validate ([string]$l.value)
            if ($null -ne $why) { $bad.Add([PSCustomObject]@{ path = $l.path; value = $l.value; rule = $r.Rule; reason = [string]$why }) }
        }
    }
    return $bad.ToArray()
}

function ConvertTo-TcXmlNumber {
    <#
    .SYNOPSIS
        A trimmed XML value as [decimal], or $null.
    .DESCRIPTION
        Accepted: a decimal number (invariant culture; sign, decimal point and exponent allowed) or
        '#x' + hexadecimal digits (prefix case-insensitive; XAE writes ParameterValues that way, e.g.
        #x1e8480, measured 2026-10-30 task 2.1).
    .PARAMETER Value
        Trimmed value.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value.Length -gt 2 -and $Value.StartsWith('#x', [System.StringComparison]::OrdinalIgnoreCase)) {
        $h = [uint64]0
        if ([uint64]::TryParse($Value.Substring(2), [System.Globalization.NumberStyles]::AllowHexSpecifier, $inv, [ref]$h)) { return [decimal]$h }
        return $null
    }
    $d = [decimal]0
    if ([decimal]::TryParse($Value, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d }
    return $null
}

function Test-TcXmlValueEqual {
    <#
    .SYNOPSIS
        Compares an expected and a read-back leaf value.
    .DESCRIPTION
        Both trimmed, then compared ordinally (case-sensitive). Only when that differs and BOTH sides
        parse as numbers (ConvertTo-TcXmlNumber: decimal, or '#x' hex with a case-insensitive prefix
        and hex digits) are the numbers compared (40000 == 40000.0, #x1E == #X1e == 30). Any other
        text is case-sensitive ('abc' != 'ABC', 'TRUE' != 'true').
    .PARAMETER Expected
        Value from the fragment.
    .PARAMETER Actual
        Value read back.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Expected, [AllowNull()][AllowEmptyString()][string]$Actual)
    $e = ([string]$Expected).Trim()
    $a = ([string]$Actual).Trim()
    if ([string]::Equals($e, $a, [System.StringComparison]::Ordinal)) { return $true }
    $ne = ConvertTo-TcXmlNumber -Value $e
    if ($null -eq $ne) { return $false }
    $na = ConvertTo-TcXmlNumber -Value $a
    if ($null -eq $na) { return $false }
    return ($ne -eq $na)
}

function Compare-TcTreeItemFragment {
    <#
    .SYNOPSIS
        Compares every fragment leaf with an XML of the tree item:
        @{ Missing; StructureMismatch; RepeatedCountMismatch; Changes; Mismatches }.
    .DESCRIPTION
        Missing: leaf paths that do not exist in -CurrentXml (ConsumeXml would ignore them silently).
        StructureMismatch: fragment leaves whose element has child elements in -CurrentXml (e.g.
        <TreeItem><TaskDef/></TreeItem> or <TaskDef>123</TaskDef>); comparing InnerText there is
        meaningless and how XAE merges it is not measured.
        RepeatedCountMismatch: @{ path; fragmentCount; currentCount } for elements whose number of
        same-name siblings differs between the fragment and -CurrentXml (one CPU in the fragment, two
        now); how XAE merges that is not measured.
        Changes: one entry per matched leaf, current = value in -CurrentXml, planned = fragment value,
        changed = they differ (Test-TcXmlValueEqual). Mismatches: entries with changed = $true that
        are not derived; used for the readback check (compared against the read-back XML a mismatch
        means the write did not take effect).
    .PARAMETER Leaves
        Output of Get-TcXmlLeafList for the fragment.
    .PARAMETER CurrentXml
        ProduceXml of the tree item (before or after the write).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Leaves, [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentXml)
    if ([string]::IsNullOrWhiteSpace($CurrentXml)) { throw 'ProduceXml returned no XML' }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($CurrentXml)
    $missing = [System.Collections.Generic.List[string]]::new()
    $structure = [System.Collections.Generic.List[string]]::new()
    $repeated = [System.Collections.Generic.List[object]]::new()
    $repeatedSeen = @{}
    $changes = [System.Collections.Generic.List[object]]::new()
    $mismatches = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $Leaves) {
        # Walk segment by segment: the number of same-name siblings must match at every level.
        $node = $doc.DocumentElement
        $prefix = $node.get_Name()
        $broken = $false
        foreach ($s in @($l.segments)) {
            $same = @($node.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element -and $_.get_Name() -eq $s.name })
            $fc = if ($null -ne $s.count) { [int]$s.count } else { 1 }
            if ($same.Count -gt 0 -and $same.Count -ne $fc) {
                $rp = "$prefix/$($s.name)"
                if (-not $repeatedSeen.ContainsKey($rp)) {
                    $repeatedSeen[$rp] = $true
                    $repeated.Add([PSCustomObject]@{ path = $rp; fragmentCount = $fc; currentCount = $same.Count })
                }
                $broken = $true
                break
            }
            if ($same.Count -eq 0 -or [int]$s.index -gt $same.Count) { $missing.Add([string]$l.path); $broken = $true; break }
            $node = $same[[int]$s.index - 1]
            $prefix = if ($fc -gt 1) { "$prefix/$($s.name)[$($s.index)]" } else { "$prefix/$($s.name)" }
        }
        if ($broken) { continue }
        $hasKids = @($node.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element }).Count -gt 0
        if ($hasKids) { $structure.Add([string]$l.path); continue }
        $cur = [string]$node.get_InnerText()
        $changed = -not (Test-TcXmlValueEqual -Expected $l.value -Actual $cur)
        $entry = [PSCustomObject]@{ path = $l.path; current = $cur; planned = $l.value; changed = $changed; derived = [bool]$l.derived }
        $changes.Add($entry)
        if ($changed -and -not $l.derived) { $mismatches.Add([PSCustomObject]@{ path = $l.path; expected = $l.value; actual = $cur }) }
    }
    return @{
        Missing               = $missing.ToArray()
        StructureMismatch     = $structure.ToArray()
        RepeatedCountMismatch = $repeated.ToArray()
        Changes               = $changes.ToArray()
        Mismatches            = $mismatches.ToArray()
    }
}

function Compare-TcTreeItemXmlFull {
    <#
    .SYNOPSIS
        Whole-XML comparison of a tree item before and after a write: @(@{ path; kind; before; after }).
    .DESCRIPTION
        Both XMLs are flattened (Get-TcXmlLeafList -IncludeAttributes: element leaves and attributes).
        Leaves whose path is in -ExcludePaths (the fragment) and derived leaves (TcModuleInstance
        Context / ParameterValues) are skipped. Every other difference is returned:
          default (Set-TcTreeItemXml): by indexed path; kind 'changed' (value differs,
            Test-TcXmlValueEqual), 'removed' (only before), 'added' (only after). A different number of
            repeated elements shows up as removed / added paths.
          -AdditionsOnly (parent of CreateChild / ImportChild): by index-free key, as multisets; every
            value before must still be there after; extra values after are allowed (the new child may
            be listed in the parent, and an insert with -Before shifts the [n] indexes). A value before
            that is gone is kind 'changed' when the key still has other values after (after = those
            values, e.g. ChildCount '1' -> '3'), 'removed' when nothing is left under the key.
            -AllowedIncrements: a key listed there may instead have grown by exactly that number
            (both values numeric, ConvertTo-TcXmlNumber); any other change of it is still reported.
        Throws when either XML is empty or does not parse.
    .PARAMETER BeforeXml
        ProduceXml before the write.
    .PARAMETER AfterXml
        ProduceXml after the write.
    .PARAMETER ExcludePaths
        Leaf paths not compared (the fragment's leaves).
    .PARAMETER AdditionsOnly
        Allow additions only (parent check).
    .PARAMETER AllowedIncrements
        With -AdditionsOnly: index-free key -> the exact numeric increase allowed for it, e.g.
        @{ 'TreeItem/ChildCount' = 1 } (Test-TcTreeItemParentUnchanged).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$BeforeXml,
        [Parameter(Mandatory)][AllowEmptyString()][string]$AfterXml,
        [Parameter()][AllowEmptyCollection()][string[]]$ExcludePaths = @(),
        [switch]$AdditionsOnly,
        [Parameter()][hashtable]$AllowedIncrements = @{}
    )
    if ([string]::IsNullOrWhiteSpace($BeforeXml) -or [string]::IsNullOrWhiteSpace($AfterXml)) { throw 'ProduceXml returned no XML' }
    $db = New-Object System.Xml.XmlDocument
    $db.LoadXml($BeforeXml)
    $da = New-Object System.Xml.XmlDocument
    $da.LoadXml($AfterXml)
    $skip = @{}
    foreach ($p in @($ExcludePaths)) { if (-not [string]::IsNullOrEmpty($p)) { $skip[$p] = $true } }
    $lb = @(Get-TcXmlLeafList -Root $db.DocumentElement -IncludeAttributes | Where-Object { -not $_.derived -and -not $skip.ContainsKey($_.path) })
    $la = @(Get-TcXmlLeafList -Root $da.DocumentElement -IncludeAttributes | Where-Object { -not $_.derived -and -not $skip.ContainsKey($_.path) })
    $out = [System.Collections.Generic.List[object]]::new()
    if ($AdditionsOnly) {
        $after = @{}
        foreach ($l in $la) {
            if (-not $after.ContainsKey($l.key)) { $after[$l.key] = [System.Collections.Generic.List[string]]::new() }
            $after[$l.key].Add([string]$l.value)
        }
        foreach ($l in $lb) {
            # plain assignment: an if-expression would unroll the List
            $vals = $null
            if ($after.ContainsKey($l.key)) { $vals = $after[$l.key] }
            $hit = -1
            if ($null -ne $vals) { for ($i = 0; $i -lt $vals.Count; $i++) { if (Test-TcXmlValueEqual -Expected $l.value -Actual $vals[$i]) { $hit = $i; break } } }
            if ($hit -ge 0) { $vals.RemoveAt($hit); continue }
            if ($null -ne $vals -and $null -ne $AllowedIncrements -and $AllowedIncrements.ContainsKey($l.key)) {
                $nb = ConvertTo-TcXmlNumber -Value ([string]$l.value).Trim()
                if ($null -ne $nb) {
                    for ($i = 0; $i -lt $vals.Count; $i++) {
                        $na = ConvertTo-TcXmlNumber -Value ([string]$vals[$i]).Trim()
                        if ($null -ne $na -and ($na - $nb) -eq [decimal]$AllowedIncrements[$l.key]) { $hit = $i; break }
                    }
                }
                if ($hit -ge 0) { $vals.RemoveAt($hit); continue }
            }
            # The key still has values after: the value changed; nothing left under the key: removed.
            if ($null -ne $vals -and $vals.Count -gt 0) {
                $out.Add([PSCustomObject]@{ path = $l.path; kind = 'changed'; before = $l.value; after = (($vals.ToArray()) -join ' | ') })
            }
            else { $out.Add([PSCustomObject]@{ path = $l.path; kind = 'removed'; before = $l.value; after = $null }) }
        }
        return $out.ToArray()
    }
    $mb = [ordered]@{}
    foreach ($l in $lb) { $mb[$l.path] = [string]$l.value }
    $ma = [ordered]@{}
    foreach ($l in $la) { $ma[$l.path] = [string]$l.value }
    foreach ($k in $mb.Keys) {
        if (-not $ma.Contains($k)) { $out.Add([PSCustomObject]@{ path = $k; kind = 'removed'; before = $mb[$k]; after = $null }); continue }
        if (-not (Test-TcXmlValueEqual -Expected $mb[$k] -Actual $ma[$k])) { $out.Add([PSCustomObject]@{ path = $k; kind = 'changed'; before = $mb[$k]; after = $ma[$k] }) }
    }
    foreach ($k in $ma.Keys) {
        if (-not $mb.Contains($k)) { $out.Add([PSCustomObject]@{ path = $k; kind = 'added'; before = $null; after = $ma[$k] }) }
    }
    return $out.ToArray()
}

function Get-TcXtiItemName {
    <#
    .SYNOPSIS
        Name an ImportChild of -FilePath without bstrName is expected to give the item, or $null when
        it cannot be told.
    .DESCRIPTION
        An .xti written by ExportChild is <TcSmItem><Task ...><Name>...</Name>...: the <Name> child of
        the first element below the root. ExportChild writes <Name>__FILENAME__</Name> and XAE then
        names the imported item after the file name without extension (registered tcauto measured
        2026-10-30, 4026 VS2022 XAE 3.1.4026.22: Task28.xti -> Task28, renamed to Task28_1 because
        that name existed; phase1-2.8.md issue #4). A literal <Name> (the .xti of a DeleteChild
        backup) is returned as it is. $null for a .zip (PLC node: not XML), a file that does not parse
        or a file without that <Name>.
    .PARAMETER FilePath
        Absolute path of the file to import.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath)
    if ([System.IO.Path]::GetExtension($FilePath) -ieq '.zip') { return $null }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($FilePath)
    }
    catch { return $null }
    if ($null -eq $doc.DocumentElement) { return $null }
    $first = @($doc.DocumentElement.get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element } | Select-Object -First 1)
    if ($first.Count -eq 0) { return $null }
    $nameEl = @($first[0].get_ChildNodes() | Where-Object { $_.get_NodeType() -eq [System.Xml.XmlNodeType]::Element -and $_.get_Name() -eq 'Name' } | Select-Object -First 1)
    if ($nameEl.Count -eq 0) { return $null }
    $n = ([string]$nameEl[0].get_InnerText()).Trim()
    if ($n -eq '__FILENAME__') { $n = [System.IO.Path]::GetFileNameWithoutExtension($FilePath) }
    if ([string]::IsNullOrEmpty($n) -or $n.Contains('^')) { return $null }
    return $n
}

function New-TcXmlMergeFailedResult {
    <#
    .SYNOPSIS
        XML_MERGE_FAILED result with data.reason; the hint is $script:TcXmlMergeReasonHints[reason]
        when there is one, else the central XML_MERGE_FAILED hint.
    .PARAMETER Reason
        data.reason.
    .PARAMETER Message
        error.message (", nothing was written." is appended).
    .PARAMETER Data
        Data object (reason is added).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][string]$Message, [Parameter()][object]$Data)
    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    $Data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force
    $hint = $null
    if ($null -ne $script:TcXmlMergeReasonHints -and $script:TcXmlMergeReasonHints.ContainsKey($Reason)) { $hint = $script:TcXmlMergeReasonHints[$Reason] }
    if ([string]::IsNullOrWhiteSpace($hint)) { $hint = Get-TcErrorHint -Code 'XML_MERGE_FAILED' }
    New-TcResult -Success $false -ErrorCode 'XML_MERGE_FAILED' -Data $Data -ErrorMessage "$Message; nothing was written." -Hint $hint
}

# Parent fields that grow when CreateChild / ImportChild adds one child: index-free key -> increase.
# TreeItem/ChildCount +1: registered tcauto measured 2026-10-30, 4026 VS2022 XAE 3.1.4026.22
# (openspec/changes/complete-automation-interface/verification/phase1-2.8.md issue #1).
$script:TcTreeItemParentIncrements = @{ 'TreeItem/ChildCount' = 1 }

function Test-TcTreeItemParentUnchanged {
    <#
    .SYNOPSIS
        After CreateChild / ImportChild: the parent's ProduceXml may only have gained entries.
        Returns $null when that holds, else a TREEITEM_VERIFY_FAILED result.
    .DESCRIPTION
        Reads the parent's ProduceXml again and compares it with -BeforeXml
        (Compare-TcTreeItemXmlFull -AdditionsOnly: every non-derived leaf / attribute value before must
        still be there; extra values are allowed). TreeItem/ChildCount may grow by exactly 1: XAE counts
        the new child there (registered tcauto measured 2026-10-30, 4026 VS2022 XAE 3.1.4026.22, TIRT
        and TIPC parents, CreateChild and ImportChild; phase1-2.8.md issue #1). Sets data.parentUnchanged; on a difference
        data.verified = false and data.unexpectedChanges. A read-back error is TREEITEM_VERIFY_FAILED too
        (codes of $script:TcTreeItemPassThroughCodes are rethrown).
    .PARAMETER Parent
        Parent ITcSmTreeItem.
    .PARAMETER Path
        Parent path.
    .PARAMETER BeforeXml
        Parent ProduceXml read before the call.
    .PARAMETER Data
        Data object of the cmdlet.
    .PARAMETER Operation
        'CreateChild' / 'ImportChild' (message).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Parent,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$BeforeXml,
        [Parameter(Mandatory)][object]$Data,
        [Parameter(Mandatory)][string]$Operation
    )
    $unexpected = $null
    $why = $null
    try {
        $afterXml = Get-TcTreeItemXmlText -Item $Parent -Path $Path
        $unexpected = @(Compare-TcTreeItemXmlFull -BeforeXml $BeforeXml -AfterXml $afterXml -AdditionsOnly -AllowedIncrements $script:TcTreeItemParentIncrements)
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        $why = $_.Exception.Message
    }
    $ok = ($null -eq $why -and @($unexpected).Count -eq 0)
    $Data | Add-Member -NotePropertyName parentUnchanged -NotePropertyValue $ok -Force
    if ($ok) { return $null }
    $Data | Add-Member -NotePropertyName verified -NotePropertyValue $false -Force
    if ($null -ne $why) {
        $msg = "$Operation returned and the new item exists, but the ProduceXml of the parent '$Path' could not be read back: $why"
    }
    else {
        $Data | Add-Member -NotePropertyName unexpectedChanges -NotePropertyValue @($unexpected) -Force
        $msg = "$Operation returned and the new item exists, but fields of the parent '$Path' changed (only additions are expected): " + ((@($unexpected) | ForEach-Object { "$($_.path) '$($_.before)' -> '$($_.after)'" }) -join '; ')
    }
    New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $Data -ErrorMessage $msg -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
}
