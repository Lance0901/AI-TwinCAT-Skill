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

function New-TcVariantConfigXml {
    <#
    .SYNOPSIS
        <?xml version="1.0"?><ProjectVariants><Group>...</Group><Variant>...</Variant></ProjectVariants> (XmlDocument, no string concatenation of names).
    .DESCRIPTION
        Same layout as the manual sample (6.12.1 p.296): groups first, then variants.
    .PARAMETER Variants
        Variant names in order.
    .PARAMETER Groups
        @{ name; members } objects.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][string[]]$Variants = @(), [Parameter()][AllowEmptyCollection()][object[]]$Groups = @())
    $doc = New-Object System.Xml.XmlDocument
    $null = $doc.AppendChild($doc.CreateXmlDeclaration('1.0', $null, $null))
    $root = $doc.AppendChild($doc.CreateElement('ProjectVariants'))
    foreach ($g in @($Groups)) {
        $ge = $root.AppendChild($doc.CreateElement('Group'))
        $ne = $ge.AppendChild($doc.CreateElement('Name')); $ne.InnerText = [string]$g.name
        foreach ($m in @($g.members)) { $me = $ge.AppendChild($doc.CreateElement('Member')); $me.InnerText = [string]$m }
    }
    foreach ($v in @($Variants)) {
        $ve = $root.AppendChild($doc.CreateElement('Variant'))
        $ne = $ve.AppendChild($doc.CreateElement('Name')); $ne.InnerText = [string]$v
    }
    return $doc.OuterXml
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
        $raw = Invoke-TcComRetry -OperationName 'CurrentProjectVariant' -ScriptBlock { $SysManager.CurrentProjectVariant }
        if ($null -eq $raw -and $null -eq $SysManager.PSObject.Properties['CurrentProjectVariant']) { throw 'ITcSysManager has no CurrentProjectVariant (ITcSysManager14, TCatSysManagerLib 3.3.0.0)' }
        $st.Current = [string]$raw
        $st.ConfigXml = [string](Invoke-TcComRetry -OperationName 'ProjectVariantConfig' -ScriptBlock { $SysManager.ProjectVariantConfig })
        $st.ItemsXml = [string](Invoke-TcComRetry -OperationName 'ProjectVariantItems' -ScriptBlock { $SysManager.ProjectVariantItems })
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        $st.Supported = $false
        $st.Error = $_.Exception.Message
    }
    $st.Config = ConvertFrom-TcVariantConfig -Xml $st.ConfigXml
    return $st
}

function Get-TcCurrentVariantName {
    <#
    .SYNOPSIS
        CurrentProjectVariant of the solution, '' when none / not readable. Never throws.
    .PARAMETER SysManager
        ITcSysManager (or $null).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$SysManager)
    if ($null -eq $SysManager) { return '' }
    try { return [string]$SysManager.CurrentProjectVariant } catch { return '' }
}

function Test-TcVariantGroupActive {
    <#
    .SYNOPSIS
        VARIANT_GROUP_ACTIVE result when the current project variant is a group ('[Group1]'), else $null.
    .DESCRIPTION
        "If a group is selected it is not possible to activate the configurations" (VM manual v1.4
        p.7); XAE itself does not refuse Build or Activate in that state (measured, phase3-probe.md
        question 18), so Enable-TcConfig checks before anything is activated.
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$SysManager)
    $cur = Get-TcCurrentVariantName -SysManager $SysManager
    if ($cur -notmatch '^\[.*\]$') { return $null }
    New-TcResult -Success $false -ErrorCode 'VARIANT_GROUP_ACTIVE' -Data ([PSCustomObject]@{ currentVariant = $cur; activated = $false }) `
        -ErrorMessage "The current project variant is the group '$cur'; a group cannot be activated (variant-specific values would be undefined). Nothing was activated." `
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
        Files that hold the variant configuration (the .tsproj below the solution folder) for the backup.
    #>
    [CmdletBinding()]
    param()
    return @((Find-TcSolutionTsProjFile).Files)
}
