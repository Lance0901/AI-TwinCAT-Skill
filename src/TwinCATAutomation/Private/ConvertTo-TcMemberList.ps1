function ConvertTo-TcMemberList {
    <#
    .SYNOPSIS
        Normalizes the member input of Add-TcDut (-Fields) / Add-TcGvl (-Variables) into an
        ordered list (#47).
    .DESCRIPTION
        Accepted, in input order:
          * an array of entries: hashtable / PSCustomObject with keys
              Var  (Struct / Union / GVL): name, type, init (optional), comment (optional)
              Enum                       : name, value (optional), comment (optional)
            (this is the MCP format: a JSON array keeps its order through the bridge)
          * an [ordered]@{} (OrderedDictionary) or a single PSCustomObject: name = type
            (Enum: name = value); both keep their insertion order
          * a plain [hashtable] with at most one member (order cannot matter)
        A plain [hashtable] with more than one member is refused: its enumeration order is the
        hash order, not the input order (#47: STRUCT / GVL / ENUM members came out reordered
        while the call returned success). Nothing is guessed.
        Returns @{ Members = List[object] of [PSCustomObject]@{ Name; Type; Init; Value; Comment };
        Error = $null or the INVALID_PARAMS message }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [ValidateSet('Var', 'Enum')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ParameterName
    )

    $members = [System.Collections.Generic.List[object]]::new()
    $result = @{ Members = $members; Error = $null }
    if ($null -eq $InputObject) { return $result }

    $identRx = '^[A-Za-z_][A-Za-z0-9_]*$'
    $allowedKeys = if ($Kind -eq 'Var') { @('name', 'type', 'init', 'comment') } else { @('name', 'value', 'comment') }
    $example = if ($Kind -eq 'Var') { '[{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0"}]' } else { '[{"name":"eIdle","value":0},{"name":"eRun","value":1}]' }

    # (name, second) pairs in input order: second = type (Var) or value (Enum)
    $entries = [System.Collections.Generic.List[object]]::new()

    $addPair = {
        param($n, $v)
        if ($Kind -eq 'Var') { $entries.Add([PSCustomObject]@{ Name = $n; Type = $v; Init = $null; Value = $null; Comment = $null }) }
        else { $entries.Add([PSCustomObject]@{ Name = $n; Type = $null; Init = $null; Value = $v; Comment = $null }) }
    }

    if ($InputObject -is [System.Collections.Specialized.OrderedDictionary]) {
        foreach ($k in $InputObject.Keys) { & $addPair ([string]$k) $InputObject[$k] }
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -gt 1) {
            $result.Error = "-$ParameterName is a hashtable with $($InputObject.Count) members: a hashtable does not keep the input order, so the declaration order would be the hash order (#47). Pass an array ($example) or an [ordered]@{} instead."
            return $result
        }
        foreach ($k in $InputObject.Keys) { & $addPair ([string]$k) $InputObject[$k] }
    }
    elseif ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $InputObject.PSObject.Properties) { & $addPair $p.Name $p.Value }
    }
    elseif (($InputObject -is [System.Collections.IList]) -and -not ($InputObject -is [string])) {
        $i = 0
        foreach ($e in $InputObject) {
            $map = @{}
            if ($e -is [System.Collections.IDictionary]) {
                foreach ($k in $e.Keys) { $map[([string]$k).ToLowerInvariant()] = $e[$k] }
            }
            elseif ($e -is [System.Management.Automation.PSCustomObject]) {
                foreach ($p in $e.PSObject.Properties) { $map[$p.Name.ToLowerInvariant()] = $p.Value }
            }
            else {
                $result.Error = "-$ParameterName[$i] is not an object. Each entry is an object, e.g. $example."
                return $result
            }
            foreach ($k in $map.Keys) {
                if ($allowedKeys -notcontains $k) {
                    $result.Error = "-$ParameterName[$i] has the unknown key '$k' (allowed: $($allowedKeys -join ', '))."
                    return $result
                }
            }
            $entries.Add([PSCustomObject]@{
                Name    = $map['name']
                Type    = $map['type']
                Init    = $map['init']
                Value   = $map['value']
                Comment = $map['comment']
            })
            $i++
        }
    }
    else {
        $result.Error = "-$ParameterName must be an array of entries ($example) or an [ordered]@{}; got $($InputObject.GetType().FullName)."
        return $result
    }

    $seen = @{}
    $i = 0
    foreach ($e in $entries) {
        $label = "-$ParameterName[$i]"
        $name = if ($null -eq $e.Name) { '' } else { [string]$e.Name }
        if ($name -notmatch $identRx) {
            $result.Error = "$label name '$name' is not an IEC 61131-3 identifier (letters, digits, underscore; not starting with a digit)."
            return $result
        }
        $key = $name.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $result.Error = "$label name '$name' is given twice (names are case-insensitive)."
            return $result
        }
        $seen[$key] = $true

        $type = $null; $init = $null; $value = $null; $comment = $null
        if ($Kind -eq 'Var') {
            $type = if ($null -eq $e.Type) { '' } else { ([string]$e.Type).Trim() }
            if ($type -eq '' -or $type -match '[;\r\n]') {
                $result.Error = "$label ('$name') needs a type without ';' or line breaks, e.g. INT or STRING(20)."
                return $result
            }
            if ($null -ne $e.Init -and ([string]$e.Init).Trim() -ne '') {
                $init = ([string]$e.Init).Trim()
                if ($init -match '[;\r\n]') {
                    $result.Error = "$label ('$name') init must not contain ';' or line breaks."
                    return $result
                }
            }
        }
        else {
            if ($null -ne $e.Value -and ([string]$e.Value).Trim() -ne '') {
                $value = ([string]$e.Value).Trim()
                if ($value -match '[;,()\r\n]') {
                    $result.Error = "$label ('$name') value must not contain ';', ',', parentheses or line breaks."
                    return $result
                }
            }
        }
        if ($null -ne $e.Comment -and ([string]$e.Comment).Trim() -ne '') {
            $comment = ([string]$e.Comment).Trim()
            if ($comment -match '[\r\n]') {
                $result.Error = "$label ('$name') comment must be one line."
                return $result
            }
        }
        $members.Add([PSCustomObject]@{ Name = $name; Type = $type; Init = $init; Value = $value; Comment = $comment })
        $i++
    }
    return $result
}

function Format-TcMemberDeclaration {
    <#
    .SYNOPSIS
        Renders the members of ConvertTo-TcMemberList as declaration lines, in list order.
    .DESCRIPTION
        Var : "    <name> : <type>[ := <init>];[ // <comment>]"
        Enum: "    <name>[ := <value>][,][ // <comment>]" (comma on every member but the last)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Members,

        [Parameter(Mandatory)]
        [ValidateSet('Var', 'Enum')]
        [string]$Kind
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $Members.Count; $i++) {
        $m = $Members[$i]
        if ($Kind -eq 'Var') {
            $line = "    $($m.Name) : $($m.Type)"
            if ($null -ne $m.Init) { $line += " := $($m.Init)" }
            $line += ';'
        }
        else {
            $line = "    $($m.Name)"
            if ($null -ne $m.Value) { $line += " := $($m.Value)" }
            if ($i -lt $Members.Count - 1) { $line += ',' }
        }
        if ($null -ne $m.Comment) { $line += " // $($m.Comment)" }
        $lines.Add($line)
    }
    return , $lines.ToArray()
}

function Get-TcDeclarationMemberOrder {
    <#
    .SYNOPSIS
        Parses the member names of a DUT / GVL declaration in declaration order (#47 readback).
    .DESCRIPTION
        Comments ((* *), //) and pragmas ({ }) are removed first.
        Var : the body between STRUCT / UNION / VAR_GLOBAL and END_STRUCT / END_UNION / END_VAR,
              split at ';'; each statement contributes the names before its ':'
              ("a, b : INT" gives a, b).
        Enum: the body between the first '(' after "TYPE <name> :" and the last ')', split at ','.
        Returns a string[] (empty when nothing is found).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Declaration,

        [Parameter(Mandatory)]
        [ValidateSet('Var', 'Enum')]
        [string]$Kind
    )
    $names = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Declaration)) { return , $names.ToArray() }

    $text = [regex]::Replace($Declaration, '\(\*.*?\*\)', ' ', 'Singleline')
    $text = [regex]::Replace($text, '//[^\r\n]*', ' ')
    $text = [regex]::Replace($text, '\{[^}]*\}', ' ', 'Singleline')

    if ($Kind -eq 'Var') {
        $m = [regex]::Match($text, '(?is)\b(?:STRUCT|UNION|VAR_GLOBAL(?:[ \t]+(?:CONSTANT|PERSISTENT|RETAIN))*)\b(?<body>.*?)\bEND_(?:STRUCT|UNION|VAR)\b')
        if (-not $m.Success) { return , $names.ToArray() }
        foreach ($stmt in ($m.Groups['body'].Value -split ';')) {
            $s = $stmt.Trim()
            $d = [regex]::Match($s, '^(?<ids>[A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*(?:AT\s+%\S+\s*)?:(?!=)')
            if ($d.Success) {
                foreach ($id in ($d.Groups['ids'].Value -split ',')) { $names.Add($id.Trim()) }
            }
        }
    }
    else {
        $m = [regex]::Match($text, '(?is)\bTYPE\b[^:]*:\s*\((?<body>.*)\)')
        if (-not $m.Success) { return , $names.ToArray() }
        foreach ($part in ($m.Groups['body'].Value -split ',')) {
            $d = [regex]::Match($part.Trim(), '^(?<id>[A-Za-z_][A-Za-z0-9_]*)')
            if ($d.Success) { $names.Add($d.Groups['id'].Value) }
        }
    }
    return , $names.ToArray()
}

function Test-TcMemberOrder {
    <#
    .SYNOPSIS
        Compares the members read back from the declaration with the input order (#47).
        Returns @{ Ok = bool; Expected = string[]; Actual = string[] }; names compare
        case-insensitively. An empty input list is not checked (Ok = $true).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Members,

        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Declaration,

        [Parameter(Mandatory)]
        [ValidateSet('Var', 'Enum')]
        [string]$Kind
    )
    $expected = @($Members | ForEach-Object { [string]$_.Name })
    # the parser returns its string[] as ONE object (return , $arr): no @() around it
    $actual = Get-TcDeclarationMemberOrder -Declaration $Declaration -Kind $Kind
    if ($null -eq $actual) { $actual = [string[]]@() }
    if ($expected.Count -eq 0) { return @{ Ok = $true; Expected = $expected; Actual = $actual } }
    $ok = ($expected.Count -eq $actual.Count)
    if ($ok) {
        for ($i = 0; $i -lt $expected.Count; $i++) {
            if ($expected[$i] -ine $actual[$i]) { $ok = $false; break }
        }
    }
    return @{ Ok = $ok; Expected = $expected; Actual = $actual }
}
