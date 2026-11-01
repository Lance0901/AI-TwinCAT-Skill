# TcCOM module helpers (complete-automation-interface phase 3, task 4.2): Add-TcComModule,
# Get-TcComModuleParameter, Set-TcComModuleParameter, Set-TcComModuleContext.
# Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 (4024 XAE Shell 3.1.4024.71 for CreateChild), self-built
# client (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 8-14):
#   - 'TIRC^TcCOM Objects' (type 49) CreateChild(name, 0 | 1, '', <GUID | type name>) creates a module
#     instance (type 48) named '<name> (<ModuleTypeName>)'; a taken name becomes '<name>_ObjN (...)'
#     without an error (4024 adds _ObjN even the first time); unknown GUID -> 0x98510009 "TCOM Module /
#     TCOM Configuration with GUID '%s' not found!" (question 9; TE1000 v1.7.0 6.7.1 p.274-275).
#   - module ProduceXml: TreeItem/ObjectId (#x01010010), TcModuleInstance/Module/@GUID, Module/Name,
#     Module/Contexts/Context/Id, Module/Parameters/Parameter {Name, BitSize, BaseType, PTCID},
#     Module/ParameterValues/Value {Name, Value | EnumText | String} (question 10).
#   - ITcModuleManager: Modules.Item(i) (0-based) enumerates, foreach does not, LookupModule (v2) cannot
#     be called through late binding, ClassID is empty (question 11; TE1000 5.31-5.32).
#   - GetModulePara(pid) -> byte[] little endian; SetModulePara(pid, byte[]) -> size mismatch
#     0x98110705 (ADS_E_INVALIDSIZE), unknown pid on Get -> E_FAIL; offline Set writes no file (question 11).
#   - Set/GetModuleContext(index, oid): index = the TMC Context Id (1 for the NTP module), not 0;
#     0x80070057 for a wrong index, E_FAIL for an oid that is no task (question 12; TE1000 5.33.2 p.140-141).
#   - Get/SetOnlineModulePara(oid, pid, ...): 0x98110703 unknown pid, 0x98110705 wrong size, 0x9811071D
#     unknown oid; an online write does not change the project (question 13; TE1000 5.31.1.1 p.130).

$script:TcComFolderPath = 'TIRC^TcCOM Objects'
$script:TcComModuleItemType = 48
$script:TcHrAdsInvalidSize = [int]0x98110705
$script:TcHrAdsInvalidOffset = [int]0x98110703
$script:TcHrAdsObjectNotFound = [int]0x9811071D
$script:TcHrInvalidArg = [int]0x80070057
$script:TcHrFail = [int]0x80004005

# Elementary types: name -> @{ Bytes; Kind (bool | uint | int | float | time) }
# TIME: 32 bit, resolution 1 ms, stored as UDINT (InfoSys TIME/LTIME,
# https://infosys.beckhoff.com/content/1033/tc3_plc_intro/12189021579.html); phase3-4.6 N2: the
# TcNtpExternalTimeProvider parameter PollInterval is TIME (registered tcauto 2026-11-01, 4026.22
# VS2022, rawHex E8030000 = 1000).
$script:TcComElementaryTypes = @{
    'BOOL' = @{ Bytes = 1; Kind = 'bool' }
    'BYTE' = @{ Bytes = 1; Kind = 'uint' }; 'USINT' = @{ Bytes = 1; Kind = 'uint' }; 'SINT' = @{ Bytes = 1; Kind = 'int' }
    'WORD' = @{ Bytes = 2; Kind = 'uint' }; 'UINT' = @{ Bytes = 2; Kind = 'uint' }; 'INT' = @{ Bytes = 2; Kind = 'int' }
    'DWORD' = @{ Bytes = 4; Kind = 'uint' }; 'UDINT' = @{ Bytes = 4; Kind = 'uint' }; 'DINT' = @{ Bytes = 4; Kind = 'int' }
    'LWORD' = @{ Bytes = 8; Kind = 'uint' }; 'ULINT' = @{ Bytes = 8; Kind = 'uint' }; 'LINT' = @{ Bytes = 8; Kind = 'int' }
    'REAL' = @{ Bytes = 4; Kind = 'float' }; 'LREAL' = @{ Bytes = 8; Kind = 'float' }
    'TIME' = @{ Bytes = 4; Kind = 'time' }
}
$script:TcComWritableTypesText = 'BOOL, the integer types, REAL / LREAL, STRING(n), TIME and enums confirmed by the module DataTypes'

function ConvertFrom-TcTimeLiteral {
    <#
    .SYNOPSIS
        TIME value text -> milliseconds ([decimal]) or $null: an integer (ms) or an IEC literal T#/TIME# with d / h / m / s / ms parts (e.g. T#5S, T#1m30s, TIME#250ms; '_' allowed, the last part may have a fraction).
    .PARAMETER Text
        Value text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $t = ([string]$Text).Trim()
    $n = [decimal]0
    if ([decimal]::TryParse($t, [System.Globalization.NumberStyles]::Integer, $inv, [ref]$n)) { return $n }
    $m = [regex]::Match($t, '^(?i)(?:T|TIME)#(-?)([0-9_.a-z]+)$')
    if (-not $m.Success) { return $null }
    $body = $m.Groups[2].Value.Replace('_', '')
    $parts = [regex]::Matches($body, '(?i)(\d+(?:\.\d+)?)(ms|d|h|m|s)')
    if ($parts.Count -eq 0 -or (($parts | ForEach-Object { $_.Value }) -join '') -ne $body) { return $null }
    $scale = @{ 'd' = [decimal]86400000; 'h' = [decimal]3600000; 'm' = [decimal]60000; 's' = [decimal]1000; 'ms' = [decimal]1 }
    $total = [decimal]0
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $num = $parts[$i].Groups[1].Value
        if ($num.Contains('.') -and $i -ne $parts.Count - 1) { return $null }
        $total += [decimal]::Parse($num, $inv) * $scale[$parts[$i].Groups[2].Value.ToLowerInvariant()]
    }
    if ($m.Groups[1].Value -eq '-') { $total = -$total }
    return $total
}

function ConvertTo-TcGuidText {
    <#
    .SYNOPSIS
        GUID text (with or without braces) -> '{xxxxxxxx-...}' lower case, or $null when it is no GUID.
    .PARAMETER Value
        Text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Value)
    $g = [guid]::Empty
    if ([string]::IsNullOrWhiteSpace($Value) -or -not [guid]::TryParse($Value.Trim(), [ref]$g)) { return $null }
    return ('{' + $g.ToString('D').ToLowerInvariant() + '}')
}

function Get-TcComModuleInfo {
    <#
    .SYNOPSIS
        Parsed ProduceXml of a TcCOM module instance: @{ name; path; oid; oidHex; classId; typeName; contextIds; contexts; parameters; values }.
    .DESCRIPTION
        parameters[]: name, id ([uint32] from PTCID), idHex, bitSize, baseType, group. values: name -> text
        of <Value> / <EnumText> / <String>. contexts[]: id, otcid (ManualConfig/OTCID as uint32 or $null).
        IDE_* errors of ProduceXml are thrown; an unreadable XML gives $null.
    .PARAMETER Item
        Module tree item.
    .PARAMETER Path
        Its tree path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Path)
    $xml = Get-TcTreeItemXmlText -Item $Item -Path $Path
    $doc = ConvertFrom-TcTreeItemXmlString -Xml $xml
    if ($null -eq $doc) { return $null }
    $mod = $doc.SelectSingleNode('TreeItem/TcModuleInstance/Module')
    $oidNode = $doc.SelectSingleNode('TreeItem/ObjectId')
    $oid = if ($null -ne $oidNode) { ConvertFrom-TcHexId -Value $oidNode.InnerText } else { $null }
    $params = [System.Collections.Generic.List[object]]::new()
    $values = @{}
    # review S10: the data types of the module (TcModuleInstance/DataTypes/DataType): an enum has
    # <EnumInfo> children; only a confirmed enum is treated as an integer
    $dataTypes = @{}
    foreach ($dt in @($doc.SelectNodes('TreeItem/TcModuleInstance/DataTypes/DataType'))) {
        $dn = $dt.SelectSingleNode('Name')
        if ($null -eq $dn -or [string]::IsNullOrWhiteSpace($dn.InnerText)) { continue }
        $bt = $dt.SelectSingleNode('BaseType'); $bs = $dt.SelectSingleNode('BitSize')
        $dataTypes[[string]$dn.InnerText] = [PSCustomObject]@{
            isEnum   = ($null -ne $dt.SelectSingleNode('EnumInfo'))
            baseType = $(if ($null -ne $bt) { [string]$bt.InnerText } else { $null })
            bitSize  = $(if ($null -ne $bs -and $bs.InnerText -match '^\d+$') { [int]$bs.InnerText } else { 0 })
        }
    }
    $contexts = [System.Collections.Generic.List[object]]::new()
    $classId = $null
    $typeName = $null
    if ($null -ne $mod) {
        $classId = ConvertTo-TcGuidText -Value $mod.GetAttribute('GUID')
        $tn = $mod.SelectSingleNode('Name')
        if ($null -ne $tn) { $typeName = [string]$tn.InnerText }
        foreach ($c in $mod.SelectNodes('Contexts/Context')) {
            $idn = $c.SelectSingleNode('Id')
            if ($null -eq $idn -or $idn.InnerText -notmatch '^\d+$') { continue }
            $ot = $c.SelectSingleNode('ManualConfig/OTCID')
            $contexts.Add([PSCustomObject]@{ id = [int]$idn.InnerText; otcid = $(if ($null -ne $ot) { ConvertFrom-TcHexId -Value $ot.InnerText } else { $null }) })
        }
        foreach ($p in $mod.SelectNodes('Parameters/Parameter')) {
            $nm = $p.SelectSingleNode('Name'); $pt = $p.SelectSingleNode('PTCID')
            if ($null -eq $nm -or $null -eq $pt) { continue }
            $id = ConvertFrom-TcHexId -Value $pt.InnerText
            if ($null -eq $id) { continue }
            $bs = $p.SelectSingleNode('BitSize'); $bt = $p.SelectSingleNode('BaseType')
            $params.Add([PSCustomObject]@{
                    name     = [string]$nm.InnerText
                    id       = [uint32]$id
                    idHex    = (Format-TcHexId -Value $id)
                    bitSize  = $(if ($null -ne $bs -and $bs.InnerText -match '^\d+$') { [int]$bs.InnerText } else { 0 })
                    baseType = $(if ($null -ne $bt) { [string]$bt.InnerText } else { $null })
                    group    = [string]$p.GetAttribute('Group')
                })
        }
        foreach ($v in $mod.SelectNodes('ParameterValues/Value')) {
            $nm = $v.SelectSingleNode('Name')
            if ($null -eq $nm) { continue }
            $val = $v.SelectSingleNode('Value'); if ($null -eq $val) { $val = $v.SelectSingleNode('EnumText') }; if ($null -eq $val) { $val = $v.SelectSingleNode('String') }
            $values[[string]$nm.InnerText] = $(if ($null -ne $val) { [string]$val.InnerText } else { $null })
        }
    }
    [PSCustomObject]@{
        name       = [string](Get-TcTreeItemPropertyNoThrow -Item $Item -Name 'Name' -Default (Get-TcTreePathLeaf -Path $Path))
        path       = $Path
        oid        = $oid
        oidHex     = $(if ($null -ne $oid) { Format-TcHexId -Value $oid } else { $null })
        classId    = $classId
        typeName   = $typeName
        isModule   = ($null -ne $mod)
        contextIds = @($contexts | ForEach-Object { $_.id })
        contexts   = $contexts.ToArray()
        parameters = $params.ToArray()
        values     = $values
        dataTypes  = $dataTypes
    }
}

function Get-TcComModuleManagerList {
    <#
    .SYNOPSIS
        Module instances of ITcModuleManager: @(@{ instanceName; typeName; oid; parentOid; pathName }).
    .DESCRIPTION
        Modules.Item(i) with i from 0 (foreach enumerates nothing, LookupModule v2 is not callable
        through late binding; phase3-probe.md question 11). Unreadable fields are $null. IDE_* errors
        are thrown; a missing GetModuleManager gives an empty list.
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $out = [System.Collections.Generic.List[object]]::new()
    $mm = Invoke-TcComRetry -OperationName 'GetModuleManager' -ScriptBlock { Write-Output -NoEnumerate $SysManager.GetModuleManager() }
    if ($null -eq $mm) { return $out.ToArray() }
    $mods = Get-TcTreeItemPropertyNoThrow -Item $mm -Name 'Modules'
    $count = [int](Get-TcTreeItemPropertyNoThrow -Item $mods -Name 'Count' -Default 0)
    for ($i = 0; $i -lt $count; $i++) {
        $mi = $null
        try { $mi = $mods.Item($i) } catch { continue }
        if ($null -eq $mi) { continue }
        $oidRaw = Get-TcTreeItemPropertyNoThrow -Item $mi -Name 'oid'
        $out.Add([PSCustomObject]@{
                instanceName = [string](Get-TcTreeItemPropertyNoThrow -Item $mi -Name 'ModuleInstanceName' -Default '')
                typeName     = [string](Get-TcTreeItemPropertyNoThrow -Item $mi -Name 'ModuleTypeName' -Default '')
                oid          = $(if ($null -ne $oidRaw) { ConvertFrom-TcHexId -Value ([long]$oidRaw) } else { $null })
                pathName     = [string](Get-TcTreeItemPropertyNoThrow -Item $mi -Name 'PathName' -Default '')
            })
    }
    return $out.ToArray()
}

function Resolve-TcComModule {
    <#
    .SYNOPSIS
        -Module (tree path or instance name) -> @{ Result = $null | <failed result>; Path; Item; Info }.
    .DESCRIPTION
        A tree path is looked up. A name is matched against the ModuleManager instances
        (ModuleInstanceName, case-insensitive) and the children of 'TIRC^TcCOM Objects' (the full
        child name, or '<name> (<type>)', because XAE renames every instance that way; question 9).
        The item must carry a TcModuleInstance in its ProduceXml, else TCCOM_MODULE_NOT_FOUND
        (data.modules lists the instances).
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Module
        Tree path or instance name.
    .PARAMETER Data
        Data of the cmdlet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][AllowEmptyString()][string]$Module, [Parameter(Mandatory)][object]$Data)
    $fail = {
        param([string]$Msg)
        @{ Path = $null; Item = $null; Info = $null; Result = (New-TcResult -Success $false -ErrorCode 'TCCOM_MODULE_NOT_FOUND' -Data $Data -ErrorMessage $Msg -Hint (Get-TcErrorHint -Code 'TCCOM_MODULE_NOT_FOUND')) }
    }
    if ([string]::IsNullOrWhiteSpace($Module)) { return (& $fail '-Module must be the instance name or its tree path (TIRC^TcCOM Objects^<name> (<type>)); nothing was changed.') }
    $path = $null
    $item = $null
    if ($Module.Contains('^')) {
        $r = Resolve-TcTreeItem -SysManager $SysManager -Path $Module -Data $Data -ParameterName 'Module'
        if ($null -ne $r.Result) { return @{ Path = $null; Item = $null; Info = $null; Result = $r.Result } }
        $path = $Module; $item = $r.Item
    }
    else {
        $cands = [System.Collections.Generic.List[string]]::new()
        $mmList = @()
        try { $mmList = @(Get-TcComModuleManagerList -SysManager $SysManager) }
        catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $mmList = @() }
        $Data | Add-Member -NotePropertyName modules -NotePropertyValue @($mmList | ForEach-Object { $_.instanceName }) -Force
        foreach ($m in @($mmList | Where-Object { $_.instanceName -ieq $Module })) {
            if (-not [string]::IsNullOrWhiteSpace($m.pathName)) { $cands.Add($m.pathName) }
        }
        $folder = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $script:TcComFolderPath
        if ($null -ne $folder) {
            foreach ($c in @(Get-TcTreeItemChildList -Item $folder)) {
                if ($c.name -ieq $Module -or $c.name -ilike "$([System.Management.Automation.WildcardPattern]::Escape($Module)) (*)") { $cands.Add("$($script:TcComFolderPath)^$($c.name)") }
            }
        }
        $uniq = @($cands | Sort-Object -Unique)
        if ($uniq.Count -eq 0) { return (& $fail "No TcCOM module instance named '$Module'; instances: $(if (@($Data.modules).Count) { (@($Data.modules) | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' }). Nothing was changed.") }
        if ($uniq.Count -gt 1) { return (& $fail "'$Module' matches several instances ($(($uniq | ForEach-Object { "'$_'" }) -join ', ')); give the tree path. Nothing was changed.") }
        $path = $uniq[0]
        $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $path
        if ($null -eq $item) { return (& $fail "TcCOM module '$path' could not be looked up; nothing was changed.") }
    }
    $info = Get-TcComModuleInfo -Item $item -Path $path
    if ($null -eq $info -or -not $info.isModule) { return (& $fail "'$path' is not a TcCOM module instance (no TcModuleInstance/Module in its ProduceXml); nothing was changed.") }
    $Data | Add-Member -NotePropertyName modulePath -NotePropertyValue $path -Force
    return @{ Path = $path; Item = $item; Info = $info; Result = $null }
}

function Find-TcComParameter {
    <#
    .SYNOPSIS
        One parameter of a module info (Get-TcComModuleInfo) by -Name (case-insensitive) or -ParameterId: @{ Result; Parameter }.
    .DESCRIPTION
        TCCOM_PARAM_NOT_FOUND when neither matches (data.parameters = names and ids). -ParameterId
        that is not in the XML is still accepted when -AllowUnlisted (the module may know more ids).
    .PARAMETER Info
        Module info.
    .PARAMETER Name
        Parameter name.
    .PARAMETER ParameterId
        '#x05093009', '0x05093009' or a decimal number.
    .PARAMETER Data
        Data of the cmdlet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Info, [Parameter()][string]$Name, [Parameter()][string]$ParameterId, [Parameter(Mandatory)][object]$Data)
    $list = @($Info.parameters)
    $hit = $null
    if (-not [string]::IsNullOrWhiteSpace($ParameterId)) {
        $id = ConvertFrom-TcHexId -Value $ParameterId
        if ($null -eq $id) {
            return @{ Parameter = $null; Result = (New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $Data -ErrorMessage "-ParameterId '$ParameterId' is not a number ('#x05093009', '0x05093009' or decimal); nothing was changed.") }
        }
        $hit = @($list | Where-Object { $_.id -eq $id })[0]
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Name)) {
        $hit = @($list | Where-Object { $_.name -ieq $Name })[0]
    }
    if ($null -eq $hit) {
        $Data | Add-Member -NotePropertyName parameters -NotePropertyValue @($list | ForEach-Object { "$($_.name) $($_.idHex)" }) -Force
        $what = if (-not [string]::IsNullOrWhiteSpace($ParameterId)) { "id $ParameterId" } else { "'$Name'" }
        return @{ Parameter = $null; Result = (New-TcResult -Success $false -ErrorCode 'TCCOM_PARAM_NOT_FOUND' -Data $Data `
                    -ErrorMessage "Module '$($Info.path)' has no parameter $what in its ProduceXml (Parameters/Parameter); nothing was changed." -Hint (Get-TcErrorHint -Code 'TCCOM_PARAM_NOT_FOUND')) }
    }
    return @{ Parameter = $hit; Result = $null }
}

function Get-TcComParamType {
    <#
    .SYNOPSIS
        Codec of a parameter: @{ name; bytes; kind (bool | uint | int | float | string | raw) }.
    .DESCRIPTION
        Order: the BaseType of the XML when it is elementary; then -TypeName (GetTypeOfModulePara.Name)
        when elementary; STRING(n) / a STRING base type -> string of BitSize/8 bytes; a type that
        -DataTypes confirms as an enum (<EnumInfo>; an enum's GetTypeOfModulePara name is the enum
        name, e.g. 'TimeType', measured question 11) -> integer of its BitSize (signedness from its
        elementary BaseType, else signed); every other named type -> raw (read as hex only, not
        writable; review S10: no guessing from the bit size).
    .PARAMETER Parameter
        Parameter of Get-TcComModuleInfo.
    .PARAMETER TypeName
        GetTypeOfModulePara(pid).Name, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Parameter, [Parameter()][AllowNull()][AllowEmptyString()][string]$TypeName, [Parameter()][AllowNull()][hashtable]$DataTypes)
    $bits = [int]$Parameter.bitSize
    foreach ($t in @([string]$Parameter.baseType, $TypeName)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $u = $t.Trim().ToUpperInvariant()
        if ($script:TcComElementaryTypes.ContainsKey($u)) {
            $e = $script:TcComElementaryTypes[$u]
            return @{ name = $u; bytes = [int]$e.Bytes; kind = $e.Kind }
        }
        if ($u -match '^STRING(\(\d+\))?$' -and $bits -ge 8) { return @{ name = $u; bytes = [int]($bits / 8); kind = 'string' } }
    }
    $nm = if (-not [string]::IsNullOrWhiteSpace($TypeName)) { $TypeName } else { [string]$Parameter.baseType }
    if ($null -ne $DataTypes) {
        foreach ($t in @([string]$Parameter.baseType, $TypeName)) {
            if ([string]::IsNullOrWhiteSpace($t) -or -not $DataTypes.ContainsKey($t)) { continue }
            $d = $DataTypes[$t]
            if (-not $d.isEnum) { continue }
            $eb = if ($d.bitSize -gt 0) { $d.bitSize } else { $bits }
            if (@(8, 16, 32, 64) -notcontains $eb) { continue }
            $kind = 'int'
            $ub = ([string]$d.baseType).Trim().ToUpperInvariant()
            if ($script:TcComElementaryTypes.ContainsKey($ub) -and $script:TcComElementaryTypes[$ub].Kind -eq 'uint') { $kind = 'uint' }
            return @{ name = $nm; bytes = [int]($eb / 8); kind = $kind; enum = $true }
        }
    }
    return @{ name = $nm; bytes = $(if ($bits -gt 0) { [int][Math]::Ceiling($bits / 8) } else { 0 }); kind = 'raw' }
}

function ConvertFrom-TcComParamBytes {
    <#
    .SYNOPSIS
        Little-endian bytes -> value of the codec (Get-TcComParamType); $null for raw.
    .PARAMETER Type
        Codec.
    .PARAMETER Bytes
        Raw bytes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Type, [Parameter()][AllowEmptyCollection()][byte[]]$Bytes = @())
    $b = [byte[]]$Bytes
    switch ($Type.kind) {
        'bool' { if ($b.Length -ge 1) { return ($b[0] -ne 0) } }
        'string' { $n = [Array]::IndexOf($b, [byte]0); if ($n -lt 0) { $n = $b.Length }; return [System.Text.Encoding]::ASCII.GetString($b, 0, $n) }
        'float' {
            if ($Type.bytes -eq 4 -and $b.Length -ge 4) { return [double][BitConverter]::ToSingle($b, 0) }
            if ($Type.bytes -eq 8 -and $b.Length -ge 8) { return [BitConverter]::ToDouble($b, 0) }
        }
        'time' { if ($b.Length -ge 4) { return [uint64][BitConverter]::ToUInt32($b, 0) } }
        'uint' {
            switch ($Type.bytes) { 1 { if ($b.Length -ge 1) { return [uint64]$b[0] } } 2 { if ($b.Length -ge 2) { return [uint64][BitConverter]::ToUInt16($b, 0) } } 4 { if ($b.Length -ge 4) { return [uint64][BitConverter]::ToUInt32($b, 0) } } 8 { if ($b.Length -ge 8) { return [BitConverter]::ToUInt64($b, 0) } } }
        }
        'int' {
            switch ($Type.bytes) { 1 { if ($b.Length -ge 1) { return [int64][sbyte]$(if ($b[0] -gt 127) { $b[0] - 256 } else { $b[0] }) } } 2 { if ($b.Length -ge 2) { return [int64][BitConverter]::ToInt16($b, 0) } } 4 { if ($b.Length -ge 4) { return [int64][BitConverter]::ToInt32($b, 0) } } 8 { if ($b.Length -ge 8) { return [BitConverter]::ToInt64($b, 0) } } }
        }
    }
    return $null
}

function ConvertTo-TcComParamBytes {
    <#
    .SYNOPSIS
        Value -> little-endian bytes of the codec; throws 'TCCOM_PARAM_INVALID_VALUE: ...' / 'TCCOM_PARAM_UNSUPPORTED_TYPE: ...'.
    .DESCRIPTION
        Numbers are parsed with the invariant culture and range checked (no silent wrap: XAE would
        store whatever arrives). BOOL accepts true / false / 1 / 0. A string must fit bytes - 1 ASCII
        characters (null terminated, padded with 0). TIME: milliseconds as an integer or an IEC
        literal (T#5S, T#1m30s, TIME#250ms; ConvertFrom-TcTimeLiteral), 0..4294967295 ms, a whole
        number of ms. Raw types are refused.
    .PARAMETER Type
        Codec.
    .PARAMETER Value
        Value (string or number).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Type, [Parameter()][AllowNull()][object]$Value)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $text = if ($null -eq $Value) { '' } elseif ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) { ([double]$Value).ToString('R', $inv) } else { ([string]$Value).Trim() }
    switch ($Type.kind) {
        'bool' {
            if ($text -ieq 'true' -or $text -eq '1') { return , [byte[]]@(1) }
            if ($text -ieq 'false' -or $text -eq '0') { return , [byte[]]@(0) }
            throw "TCCOM_PARAM_INVALID_VALUE: '$text' is no BOOL (true / false / 1 / 0)"
        }
        'string' {
            if ($text -match '[^\x20-\x7E]') { throw "TCCOM_PARAM_INVALID_VALUE: only printable ASCII is accepted for $($Type.name)" }
            if ($text.Length -gt $Type.bytes - 1) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' is longer than $($Type.bytes - 1) characters ($($Type.name))" }
            $b = New-Object byte[] $Type.bytes
            $src = [System.Text.Encoding]::ASCII.GetBytes($text)
            [Array]::Copy($src, $b, $src.Length)
            return , $b
        }
        'float' {
            $d = 0.0
            if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $inv, [ref]$d) -or [double]::IsNaN($d) -or [double]::IsInfinity($d)) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' is no finite number ($($Type.name))" }
            if ($Type.bytes -eq 4) {
                if ([Math]::Abs($d) -gt [single]::MaxValue) { throw "TCCOM_PARAM_INVALID_VALUE: $text is out of the REAL range" }
                return , [byte[]][BitConverter]::GetBytes([single]$d)
            }
            return , [byte[]][BitConverter]::GetBytes([double]$d)
        }
        'time' {
            $ms = ConvertFrom-TcTimeLiteral -Text $text
            if ($null -eq $ms) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' is no TIME (milliseconds as an integer, or a literal such as T#5S / T#1m30s / TIME#250ms)" }
            if ($ms -ne [decimal]::Truncate($ms)) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' is not a whole number of milliseconds (TIME has a resolution of 1 ms)" }
            if ($ms -lt 0 -or $ms -gt [decimal][uint32]::MaxValue) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' ($ms ms) is out of the TIME range 0..4294967295 ms" }
            return , [byte[]][BitConverter]::GetBytes([uint32]$ms)
        }
        { $_ -eq 'uint' -or $_ -eq 'int' } {
            $n = [decimal]0
            if (-not [decimal]::TryParse($text, [System.Globalization.NumberStyles]::Integer, $inv, [ref]$n)) { throw "TCCOM_PARAM_INVALID_VALUE: '$text' is no integer ($($Type.name))" }
            $bits = 8 * [int]$Type.bytes
            if ($Type.kind -eq 'uint') { $min = [decimal]0; $max = [decimal]([Math]::Pow(2, $bits)) - 1 }
            else { $min = -[decimal]([Math]::Pow(2, $bits - 1)); $max = [decimal]([Math]::Pow(2, $bits - 1)) - 1 }
            if ($bits -eq 64) { if ($Type.kind -eq 'uint') { $max = [decimal][uint64]::MaxValue } else { $min = [decimal][int64]::MinValue; $max = [decimal][int64]::MaxValue } }
            if ($n -lt $min -or $n -gt $max) { throw "TCCOM_PARAM_INVALID_VALUE: $text is out of the range $min..$max ($($Type.name))" }
            $all = if ($Type.kind -eq 'uint') { [BitConverter]::GetBytes([uint64]$n) } else { [BitConverter]::GetBytes([int64]$n) }
            $b = New-Object byte[] $Type.bytes
            [Array]::Copy($all, $b, $Type.bytes)
            return , $b
        }
    }
    throw "TCCOM_PARAM_UNSUPPORTED_TYPE: $($Type.name) ($($Type.bytes) bytes) is not a type this tool can write (writable: $script:TcComWritableTypesText); it can only be read as rawHex"
}

function ConvertTo-TcByteArray {
    <#
    .SYNOPSIS
        A COM VT_ARRAY|VT_UI1 (object[] / byte[]) or a scalar -> [byte[]].
    .PARAMETER Value
        Value of GetModulePara / GetOnlineModulePara.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return , [byte[]]@() }
    if ($Value -is [byte[]]) { return , $Value }
    if ($Value -is [System.Array]) { return , [byte[]]@($Value | ForEach-Object { [byte]$_ }) }
    if ($Value -is [byte]) { return , [byte[]]@($Value) }
    return , [byte[]]@()
}

function Format-TcHexBytes {
    <#
    .SYNOPSIS
        byte[] -> 'A1B2...' (upper case, no separator).
    .PARAMETER Bytes
        Bytes.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][byte[]]$Bytes = @())
    return (-join (@($Bytes) | ForEach-Object { $_.ToString('X2') }))
}

function Test-TcOnlineConfigMatch {
    <#
    .SYNOPSIS
        Is the configuration running on the IDE target the one of this project? @{ Match; Reason; BootPackage }.
    .DESCRIPTION
        Review S11: Get-TcBootPackageDiff (project _Boot package incl. the variant folder vs the
        target's Boot folder; only a runtime on this PC can be compared). Match only for status
        'match'; 'mismatch' and 'unavailable' (remote target, unknown platform ...) are no match.
        IDE_* errors are thrown.
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $netId = $null
    try { $netId = [string](Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $SysManager.GetTargetNetId() }) }
    catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $netId = $null }
    if ([string]::IsNullOrWhiteSpace($netId)) { return @{ Match = $false; Reason = 'the target AmsNetId is not known'; BootPackage = $null } }
    $plat = $null
    try { $cur = Get-TcSolutionPlatform; $plat = if ([string]::IsNullOrWhiteSpace($cur.projectPlatform)) { $cur.platform } else { $cur.projectPlatform } } catch { $plat = $null }
    $cv = Read-TcCurrentVariant -SysManager $SysManager
    if ($null -ne $cv.Error) { return @{ Match = $false; Reason = "CurrentProjectVariant could not be read ($($cv.Error))"; BootPackage = $null } }
    $ports = @()
    try { $ports = @(Get-TcPlcProjectList -SysManager $SysManager | Where-Object { $null -ne $_.adsPort } | ForEach-Object { [int]$_.adsPort }) } catch { $ports = @() }
    $bp = $null
    try { $bp = Get-TcBootPackageDiff -SolutionPath $script:TcSolutionPath -Platform $plat -AmsNetId $netId -AdsPorts $ports -Variant $cv.Value }
    catch { return @{ Match = $false; Reason = "the boot package could not be compared ($($_.Exception.Message))"; BootPackage = $null } }
    if ($null -eq $bp) { return @{ Match = $false; Reason = 'the boot package could not be compared'; BootPackage = $null } }
    if ($bp.status -eq 'match') { return @{ Match = $true; Reason = $null; BootPackage = $bp } }
    $why = if ($bp.status -eq 'mismatch') { "boot package differs: $(@($bp.mismatches) -join ', ')" } else { "not comparable: $($bp.reason)" }
    return @{ Match = $false; Reason = $why; BootPackage = $bp }
}

function ConvertTo-TcComErrorCode {
    <#
    .SYNOPSIS
        HRESULT of a Get/Set(Online)ModulePara / module context error -> module code.
    .PARAMETER ErrorRecord
        Caught error.
    .PARAMETER Operation
        'param-get' | 'param-set' | 'online' | 'context'.
    .PARAMETER DefaultCode
        Code when nothing matches.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$ErrorRecord, [Parameter(Mandatory)][string]$Operation, [Parameter(Mandatory)][string]$DefaultCode)
    $hr = Get-TcExceptionHResult -InputObject $ErrorRecord
    if ($hr -eq $script:TcHrAdsInvalidSize) { return 'TCCOM_PARAM_SIZE_MISMATCH' }
    if ($Operation -eq 'context' -and ($hr -eq $script:TcHrInvalidArg -or $hr -eq $script:TcHrFail)) { return 'TCCOM_CONTEXT_INVALID' }
    if ($hr -eq $script:TcHrAdsInvalidOffset) { return 'TCCOM_PARAM_NOT_FOUND' }
    if ($hr -eq $script:TcHrAdsObjectNotFound) { return 'TCCOM_OBJECT_NOT_FOUND' }
    if ($Operation -eq 'param-get' -and $hr -eq $script:TcHrFail) { return 'TCCOM_PARAM_NOT_FOUND' }
    return $DefaultCode
}
