# Project variant helpers (complete-automation-interface phase 3, task 4.3): Get-TcProjectVariants,
# Set-TcProjectVariantConfig, Set-TcCurrentVariant, the VARIANT_GROUP_ACTIVE check of Enable-TcConfig
# and the variant boot folder of Enable-TcConfig / New-TcBootProject (#89).
# API: ITcSysManager14 CurrentProjectVariant / ProjectVariantConfig / ProjectVariantItems (TE1000
# Automation Interface manual v1.7.0 5.1.13 p.52, 6.12.1 p.296; InfoSys
# https://infosys.beckhoff.com/content/1033/tc3_automationinterface/8204600715.html). Variant
# management exists from build 4024 (VM manual v1.4 p.7, InfoSys
# https://infosys.beckhoff.com/content/1033/variant_management/6325752587.html); a selected group cannot
# be activated (VM p.7).
# Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client
# (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 15-18):
#   - 4024.71 late-binds all three properties; without variants 4026 returns '' for all, 4024 $null
#     for ProjectVariantConfig / ProjectVariantItems.
#   - writing ProjectVariantConfig REPLACES the whole document (no merge, no automatic [All] group,
#     CurrentProjectVariant is not cleared when its variant disappears); invalid XML -> E_FAIL.
#   - CurrentProjectVariant: case-sensitive; unknown name, wrong case and '[All]' -> E_FAIL;
#     '[Group1]' is accepted; '' clears it.
#   - with a variant XAE writes the boot package to _Boot\<Variant>\<Platform> (a group:
#     _Boot\[Group1]\<Platform>) when the .tsproj has <Variants SpecificLocalBootFolder="true">;
#     XAE does not refuse Build / Activate with a group selected.

$script:TcVariantNamePattern = '^[A-Za-z_][A-Za-z0-9_]*$'

function ConvertFrom-TcVariantConfig {
    <#
    .SYNOPSIS
        ProjectVariantConfig XML -> @{ Ok; Error; Variants = @(names); Groups = @(@{ name; members }) }.
    .DESCRIPTION
        $null and '' (no variant: 4024 / 4026, phase3-probe.md question 16) are an empty config.
        Parsed without DTD and resolver (ConvertFrom-TcTreeItemXmlString). A text that does not parse
        or has another root than <ProjectVariants> gives Ok = $false.
    .PARAMETER Xml
        ProjectVariantConfig value.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    $out = @{ Ok = $true; Error = $null; Variants = @(); Groups = @() }
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $out }
    $doc = ConvertFrom-TcTreeItemXmlString -Xml $Xml
    if ($null -eq $doc -or $null -eq $doc.DocumentElement -or $doc.DocumentElement.Name -ne 'ProjectVariants') {
        $out.Ok = $false; $out.Error = 'ProjectVariantConfig is not a <ProjectVariants> document'
        return $out
    }
    $out.Variants = @($doc.DocumentElement.SelectNodes('Variant/Name') | ForEach-Object { [string]$_.InnerText })
    $out.Groups = @($doc.DocumentElement.SelectNodes('Group') | ForEach-Object {
            $n = $_.SelectSingleNode('Name')
            [PSCustomObject]@{ name = $(if ($null -ne $n) { [string]$n.InnerText } else { '' }); members = @($_.SelectNodes('Member') | ForEach-Object { [string]$_.InnerText }) }
        })
    return $out
}

function ConvertTo-TcVariantConfigDocument {
    <#
    .SYNOPSIS
        ProjectVariantConfig text -> XmlDocument (DTD prohibited, no resolver, whitespace kept), or a new '<?xml version="1.0"?><ProjectVariants/>' for '' / $null; $null when it does not parse.
    .DESCRIPTION
        Review S6: the variants are added / removed on this DOM, so elements and attributes the
        module does not know (build settings, future fields) are written back unchanged.
    .PARAMETER Xml
        ProjectVariantConfig value.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.PreserveWhitespace = $true
    if ([string]::IsNullOrWhiteSpace($Xml)) {
        $null = $doc.AppendChild($doc.CreateXmlDeclaration('1.0', $null, $null))
        $null = $doc.AppendChild($doc.CreateElement('ProjectVariants'))
        Write-Output -NoEnumerate $doc
        return
    }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $sr = $null; $reader = $null
    try {
        $sr = New-Object System.IO.StringReader($Xml)
        $reader = [System.Xml.XmlReader]::Create($sr, $settings)
        $doc.Load($reader)
    }
    catch { return $null }
    finally { if ($null -ne $reader) { $reader.Dispose() }; if ($null -ne $sr) { $sr.Dispose() } }
    if ($null -eq $doc.DocumentElement -or $doc.DocumentElement.get_Name() -ne 'ProjectVariants') { return $null }
    Write-Output -NoEnumerate $doc
}

function ConvertTo-TcNormalizedXml {
    <#
    .SYNOPSIS
        XML text -> canonical form for comparisons: parsed without whitespace, XML declaration and comments dropped, re-serialized; $null when it does not parse.
    .PARAMETER Xml
        XML text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return '' }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.IgnoreWhitespace = $true
    $settings.IgnoreComments = $true
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $sr = $null; $reader = $null
    try {
        $sr = New-Object System.IO.StringReader($Xml)
        $reader = [System.Xml.XmlReader]::Create($sr, $settings)
        $doc.Load($reader)
    }
    catch { return $null }
    finally { if ($null -ne $reader) { $reader.Dispose() }; if ($null -ne $sr) { $sr.Dispose() } }
    foreach ($n in @($doc.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::XmlDeclaration })) { $null = $doc.RemoveChild($n) }
    return $doc.DocumentElement.OuterXml
}

function Compare-TcVariantConfig {
    <#
    .SYNOPSIS
        Readback check of Set-TcProjectVariantConfig: @{ Same = $true | $false; Differences = @('variants' | 'groups' | 'document' | 'readback does not parse') }.
    .DESCRIPTION
        Compared by meaning, not by text: the variant list (order and case kept), the group list
        (name and members), then the rest of the document (review S6: unknown elements and
        attributes must come back; normalized with ConvertTo-TcNormalizedXml).
        4.6 N6: '' / $null and an empty <ProjectVariants/> (no attribute, no child) are the same
        document, "no variant, no group". After writing '<?xml version="1.0"?><ProjectVariants></ProjectVariants>'
        (the last variant removed) XAE reads back the empty string '' (實測 2026-11-01 4026 VS2022
        XAE 3.1.4026.22, phase3-4.6.md Retest, N6); comparing the text reported VARIANT_VERIFY_FAILED
        although the variant was gone.
    .PARAMETER Expected
        Document written.
    .PARAMETER Actual
        Document read back.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Expected, [Parameter()][AllowNull()][AllowEmptyString()][string]$Actual)
    $diff = [System.Collections.Generic.List[string]]::new()
    $exp = ConvertFrom-TcVariantConfig -Xml $Expected
    $got = ConvertFrom-TcVariantConfig -Xml $Actual
    if (-not $got.Ok -or -not $exp.Ok) {
        $diff.Add('readback does not parse')
        return @{ Same = $false; Differences = $diff.ToArray() }
    }
    if (-not [string]::Equals((@($exp.Variants) -join "`n"), (@($got.Variants) -join "`n"), [System.StringComparison]::Ordinal)) { $diff.Add('variants') }
    $groupText = { param($gs) (@($gs | ForEach-Object { "$($_.name)=$(@($_.members) -join ',')" }) -join "`n") }
    if (-not [string]::Equals((& $groupText $exp.Groups), (& $groupText $got.Groups), [System.StringComparison]::Ordinal)) { $diff.Add('groups') }
    $norm = {
        param($x)
        $n = ConvertTo-TcNormalizedXml -Xml $x
        if ($n -ceq '<ProjectVariants />' -or $n -ceq '<ProjectVariants></ProjectVariants>') { $n = '' }
        $n
    }
    $expN = & $norm $Expected
    $gotN = & $norm $Actual
    if ($null -eq $gotN -or -not [string]::Equals([string]$expN, [string]$gotN, [System.StringComparison]::Ordinal)) { $diff.Add('document') }
    return @{ Same = ($diff.Count -eq 0); Differences = $diff.ToArray() }
}

function Get-TcVariantState {
    <#
    .SYNOPSIS
        Variant properties of the ITcSysManager: @{ Supported; Error; Current; ConfigXml; ItemsXml; Config }.
    .DESCRIPTION
        Supported = $false with Error when reading a property throws, or when CurrentProjectVariant
        reads $null and the object has no such member (late binding returns $null for an unknown
        name instead of failing; XAE 4024.71 / 4026.22 return '' for it, phase3-probe.md
        questions 15-16). Other $null values are turned into '' (4024 without variants returns
        $null for ProjectVariantConfig / ProjectVariantItems). IDE_* errors are thrown.
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $st = @{ Supported = $true; Error = $null; Current = ''; ConfigXml = ''; ItemsXml = ''; Config = $null }
    try {
        $raw = Invoke-TcComRetry -OperationName 'CurrentProjectVariant' -ScriptBlock { Read-TcComPropertyValue -Object $SysManager -Name 'CurrentProjectVariant' }
        if ($null -eq $raw -and $null -eq $SysManager.PSObject.Properties['CurrentProjectVariant']) { throw 'ITcSysManager has no CurrentProjectVariant (ITcSysManager14, TCatSysManagerLib 3.3.0.0)' }
        $st.Current = [string]$raw
        $st.ConfigXml = [string](Invoke-TcComRetry -OperationName 'ProjectVariantConfig' -ScriptBlock { Read-TcComPropertyValue -Object $SysManager -Name 'ProjectVariantConfig' })
        $st.ItemsXml = [string](Invoke-TcComRetry -OperationName 'ProjectVariantItems' -ScriptBlock { Read-TcComPropertyValue -Object $SysManager -Name 'ProjectVariantItems' })
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        $st.Supported = $false
        $st.Error = $_.Exception.Message
    }
    $st.Config = ConvertFrom-TcVariantConfig -Xml $st.ConfigXml
    return $st
}

function Read-TcCurrentVariant {
    <#
    .SYNOPSIS
        CurrentProjectVariant of the solution: @{ Value = '' | name; Error = $null | message; Supported }.
    .DESCRIPTION
        Review S2: read through Invoke-TcComRetry; IDE_* errors (busy, crashed, modal dialog) are
        thrown so that the caller keeps their code. A read that fails otherwise is an Error, not "no
        variant" (Enable-TcConfig returns VARIANT_READ_FAILED then). $null with no such member (an
        XAE without ITcSysManager14, or a mock) is Value '' and Supported $false: late binding answers
        $null for an unknown name; XAE 4024.71 / 4026.22 return '' (phase3-probe.md questions 15-16).
    .PARAMETER SysManager
        ITcSysManager (or $null).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$SysManager)
    if ($null -eq $SysManager) { return @{ Value = ''; Error = $null; Supported = $false } }
    $v = $null
    try { $v = Invoke-TcComRetry -OperationName 'CurrentProjectVariant' -ScriptBlock { Read-TcComPropertyValue -Object $SysManager -Name 'CurrentProjectVariant' } }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        return @{ Value = $null; Error = $_.Exception.Message; Supported = $true }
    }
    if ($null -eq $v) {
        $has = $false
        try { $has = $null -ne $SysManager.PSObject.Properties['CurrentProjectVariant'] } catch { $has = $false }
        return @{ Value = ''; Error = $null; Supported = $has }
    }
    return @{ Value = [string]$v; Error = $null; Supported = $true }
}

function Test-TcVariantGroupActive {
    <#
    .SYNOPSIS
        VARIANT_GROUP_ACTIVE result when -Current is a group ('[Group1]'), else $null.
    .DESCRIPTION
        "If a group is selected it is not possible to activate the configurations" (VM manual v1.4
        p.7); XAE itself does not refuse Build or Activate in that state (measured, phase3-probe.md
        question 18), so Enable-TcConfig checks before anything is activated.
    .PARAMETER Current
        CurrentProjectVariant (Read-TcCurrentVariant).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Current)
    if ([string]$Current -notmatch '^\[.*\]$') { return $null }
    New-TcResult -Success $false -ErrorCode 'VARIANT_GROUP_ACTIVE' -Data ([PSCustomObject]@{ currentVariant = $Current; activated = $false }) `
        -ErrorMessage "The current project variant is the group '$Current'; a group cannot be activated (variant-specific values would be undefined). Nothing was activated." `
        -Hint (Get-TcErrorHint -Code 'VARIANT_GROUP_ACTIVE')
}

function Get-TcVariantBootFolder {
    <#
    .SYNOPSIS
        Folder below _Boot that holds the boot package of the current variant: '<Variant>' or $null (= _Boot\<Platform> directly).
    .DESCRIPTION
        #89: with a current variant XAE writes _Boot\<Variant>\<Platform> (measured, phase3-probe.md
        question 18; the .tsproj had <Variants SpecificLocalBootFolder="true">). A .tsproj that says
        SpecificLocalBootFolder="false" explicitly gives $null; otherwise (attribute true, missing,
        or the .tsproj not readable) the variant name is returned and the caller also looks at
        _Boot\<Platform> (the newer package wins).
    .PARAMETER Variant
        CurrentProjectVariant ('' = none).
    .PARAMETER TsProjFile
        .tsproj whose <Variants> attribute is read (optional).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Variant, [Parameter()][AllowNull()][AllowEmptyString()][string]$TsProjFile)
    if ([string]::IsNullOrWhiteSpace($Variant)) { return $null }
    if ($Variant.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    if (-not [string]::IsNullOrWhiteSpace($TsProjFile) -and (Test-Path -LiteralPath $TsProjFile -PathType Leaf)) {
        try {
            $doc = Read-TcXmlFile -Path $TsProjFile
            $v = $doc.SelectSingleNode('//Variants')
            if ($null -ne $v -and [string]$v.GetAttribute('SpecificLocalBootFolder') -ieq 'false') { return $null }
        }
        catch { Write-Verbose "Get-TcVariantBootFolder: '$TsProjFile' not readable ($($_.Exception.Message))" }
    }
    return $Variant
}

function Get-TcVariantDiskFiles {
    <#
    .SYNOPSIS
        Files that hold the variant configuration for the backup: the .tsproj of the open TwinCAT project (Get-TcTsProjBackupFiles; phase3-4.6 B2, not every .tsproj of the solution folder).
    #>
    [CmdletBinding()]
    param()
    return @(Get-TcTsProjBackupFiles)
}
