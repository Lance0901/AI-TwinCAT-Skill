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
# Repeated sibling elements (same name) are matched by position ([n], 1-based); how XAE merges a
# fragment with fewer repeated elements than the current XML is NOT measured.

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

function Get-TcXmlLeafList {
    <#
    .SYNOPSIS
        Leaf elements below an XML element: { path; key; segments; value; derived }.
    .DESCRIPTION
        A leaf is an element without child elements (attributes are not compared). path is the
        element path from the root ('TreeItem/TaskDef/CycleTime'); a segment gets a 1-based [n] when
        its parent has more than one child element with that name ('CPU[2]'). key is path without
        indexes (used for $script:TcTreeItemFieldRules). segments = @(@{ name; index }) without the
        root. derived = the leaf lies below a TcModuleInstance element inside Context or
        ParameterValues (recomputed by XAE, excluded from the readback comparison).
    .PARAMETER Root
        Root XmlElement (the fragment's TreeItem).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlElement]$Root)
    $list = [System.Collections.Generic.List[object]]::new()
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push(@{ Node = $Root; Path = $Root.Name; Key = $Root.Name; Segments = @() })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $kids = @($cur.Node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
        if ($kids.Count -eq 0) {
            if ($cur.Segments.Count -eq 0) { continue }   # the root itself
            $names = @($cur.Segments | ForEach-Object { $_.name })
            $derived = $false
            $mi = [array]::IndexOf([string[]]$names, 'TcModuleInstance')
            if ($mi -ge 0) {
                for ($k = $mi + 1; $k -lt $names.Count; $k++) { if ($names[$k] -eq 'Context' -or $names[$k] -eq 'ParameterValues') { $derived = $true } }
            }
            $list.Add([PSCustomObject]@{ path = $cur.Path; key = $cur.Key; segments = $cur.Segments; value = [string]$cur.Node.InnerText; derived = $derived })
            continue
        }
        $counts = @{}
        foreach ($k in $kids) { if ($counts.ContainsKey($k.Name)) { $counts[$k.Name]++ } else { $counts[$k.Name] = 1 } }
        $seen = @{}
        $ordered = [System.Collections.Generic.List[object]]::new()
        foreach ($k in $kids) {
            if ($seen.ContainsKey($k.Name)) { $seen[$k.Name]++ } else { $seen[$k.Name] = 1 }
            $idx = $seen[$k.Name]
            $seg = if ($counts[$k.Name] -gt 1) { "$($k.Name)[$idx]" } else { $k.Name }
            $ordered.Add(@{ Node = $k; Path = "$($cur.Path)/$seg"; Key = "$($cur.Key)/$($k.Name)"; Segments = @($cur.Segments + @(@{ name = $k.Name; index = $idx })) })
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
        foreach ($c in $node.ChildNodes) {
            if ($c.NodeType -ne [System.Xml.XmlNodeType]::Element -or $c.Name -ne $s.name) { continue }
            $n++
            if ($n -eq [int]$s.index) { $next = $c; break }
        }
        if ($null -eq $next) { return $null }
        $node = $next
    }
    return $node
}

function ConvertFrom-TcTreeItemFragment {
    <#
    .SYNOPSIS
        Parses a ConsumeXml fragment: @{ Doc; Leaves; Error; Reason }.
    .DESCRIPTION
        Error / Reason are set (Doc / Leaves $null) when the XML does not parse ('syntax'), the root is
        not <TreeItem> ('root'; XAE would return E_FAIL "No TreeItem found.", task 2.1) or it has no
        leaf element ('empty').
    .PARAMETER Xml
        The fragment, e.g. <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return @{ Doc = $null; Leaves = $null; Reason = 'empty'; Error = 'the XML fragment is empty' } }
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml) }
    catch { return @{ Doc = $null; Leaves = $null; Reason = 'syntax'; Error = "the XML fragment does not parse: $($_.Exception.Message)" } }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -ne 'TreeItem') {
        $rootName = if ($null -ne $doc.DocumentElement) { $doc.DocumentElement.Name } else { '' }
        return @{ Doc = $null; Leaves = $null; Reason = 'root'; Error = "the root element must be <TreeItem> (as in ProduceXml), got <$rootName>" }
    }
    $leaves = @(Get-TcXmlLeafList -Root $doc.DocumentElement)
    if ($leaves.Count -eq 0) { return @{ Doc = $null; Leaves = $null; Reason = 'empty'; Error = 'the fragment has no element below <TreeItem>; nothing to write' } }
    return @{ Doc = $doc; Leaves = $leaves; Reason = $null; Error = $null }
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

function Test-TcXmlValueEqual {
    <#
    .SYNOPSIS
        Compares an expected and a read-back leaf value: trimmed, case-insensitive, and numerically when
        both parse as decimal numbers (40000 == 40000.0).
    .PARAMETER Expected
        Value from the fragment.
    .PARAMETER Actual
        Value read back.
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Expected, [AllowNull()][AllowEmptyString()][string]$Actual)
    $e = ([string]$Expected).Trim()
    $a = ([string]$Actual).Trim()
    if ([string]::Equals($e, $a, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $de = [decimal]0; $da = [decimal]0
    if ([decimal]::TryParse($e, [System.Globalization.NumberStyles]::Float, $inv, [ref]$de) -and
        [decimal]::TryParse($a, [System.Globalization.NumberStyles]::Float, $inv, [ref]$da)) { return ($de -eq $da) }
    return $false
}

function Compare-TcTreeItemFragment {
    <#
    .SYNOPSIS
        Compares every fragment leaf with an XML of the tree item:
        @{ Missing = @(paths); Changes = @(@{ path; current; planned; changed; derived }) ; Mismatches = @(...) }.
    .DESCRIPTION
        Missing: leaf paths that do not exist in -CurrentXml (ConsumeXml would ignore them silently).
        Changes: one entry per existing leaf, current = value in -CurrentXml, planned = fragment value,
        changed = they differ (Test-TcXmlValueEqual). Mismatches: entries with changed = $true that
        are not derived; used for the readback check (compare against the read-back XML: a mismatch
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
    $changes = [System.Collections.Generic.List[object]]::new()
    $mismatches = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $Leaves) {
        $node = Find-TcXmlElementBySegments -Root $doc.DocumentElement -Segments @($l.segments)
        if ($null -eq $node) { $missing.Add([string]$l.path); continue }
        $cur = [string]$node.InnerText
        $changed = -not (Test-TcXmlValueEqual -Expected $l.value -Actual $cur)
        $entry = [PSCustomObject]@{ path = $l.path; current = $cur; planned = $l.value; changed = $changed; derived = [bool]$l.derived }
        $changes.Add($entry)
        if ($changed -and -not $l.derived) { $mismatches.Add([PSCustomObject]@{ path = $l.path; expected = $l.value; actual = $cur }) }
    }
    return @{ Missing = $missing.ToArray(); Changes = $changes.ToArray(); Mismatches = $mismatches.ToArray() }
}
