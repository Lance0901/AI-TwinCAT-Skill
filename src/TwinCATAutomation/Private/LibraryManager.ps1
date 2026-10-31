# Library Manager helpers (complete-automation-interface phase 2, task 3.1).
# ITcPlcLibraryManager on the References node TIPC^<Plc>^<Plc> Project^References (TE1000 v1.7.0
# 6.5.14 p.241-244, 5.25.1 p.113-119). Behaviour measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18
# (self-built client): openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1.

# RPC errors that must reach Invoke-TcComRetry (busy / server gone) instead of being read as "no value".
$script:TcComRethrowPattern = '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER|0x800706BA|0x800706BE'

function Resolve-TcLibraryManager {
    <#
    .SYNOPSIS
        PLC project -> References node (ITcPlcLibraryManager): @{ Result = $null | <failed result>; Refs; RefsPath; PlcProjectPath }.
    .DESCRIPTION
        -PlcProjectPath empty: the single PLC project (Resolve-TcPlcProjectPath -RequireSingle), else
        PLC_PROJECT_NOT_FOUND / PLC_PROJECT_AMBIGUOUS (data.plcProjects). A name or tree path is looked
        up with Find-TcPlcProject. The References node is looked up directly, not through
        Invoke-TcComRetry: a tree item is enumerable and the pipeline would unroll it. Missing node ->
        REFS_NOT_FOUND. Other errors are thrown (the caller's catch maps them).
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project'); empty = the only PLC project.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SysManager,
        [Parameter()][string]$PlcProjectPath
    )
    $sm = $SysManager
    $plcList = @(Get-TcPlcProjectList -SysManager $sm)
    if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
        try { $PlcProjectPath = Resolve-TcPlcProjectPath -SysManager $sm -RequireSingle }
        catch {
            if ($_.Exception.Message -match '^(PLC_PROJECT_NOT_FOUND|PLC_PROJECT_AMBIGUOUS)') {
                $code = $Matches[1]
                return @{ Result = (New-TcResult -Success $false -ErrorMessage ($_.Exception.Message -replace '^PLC_PROJECT_[A-Z_]+:\s*', '') `
                            -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) -Data ([PSCustomObject]@{ plcProjects = $plcList })) }
            }
            throw
        }
    }
    else {
        $plcEntry = Find-TcPlcProject -List $plcList -Spec $PlcProjectPath
        if ($null -eq $plcEntry) {
            return @{ Result = (New-TcResult -Success $false `
                        -ErrorMessage "PLC project '$PlcProjectPath' not found. PLC projects: $(($plcList | ForEach-Object { $_.projectPath }) -join ', ')" `
                        -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND') `
                        -Data ([PSCustomObject]@{ plcProjects = $plcList })) }
        }
        $PlcProjectPath = $plcEntry.projectPath
    }
    $refsPath = "$PlcProjectPath^References"
    $refs = $null
    try { $refs = $sm.LookupTreeItem($refsPath) }
    catch {
        if ((ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'OTHER') -ne 'TREEITEM_NOT_FOUND') { throw }
        $refs = $null
    }
    if ($null -eq $refs) {
        return @{ Result = (New-TcResult -Success $false -ErrorMessage "Cannot find References node '$refsPath' in PLC project." -ErrorCode 'REFS_NOT_FOUND') }
    }
    return @{ Result = $null; Refs = $refs; RefsPath = $refsPath; PlcProjectPath = $PlcProjectPath }
}

function Get-TcComValue {
    <#
    .SYNOPSIS
        Property -Name of a COM object, or $null when it cannot be read; RPC busy / disconnected is rethrown.
    .PARAMETER Object
        COM object (or $null).
    .PARAMETER Name
        Property name.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    try { $v = $Object.$Name }
    catch {
        if ($_.Exception.ToString() -match $script:TcComRethrowPattern) { throw }
        return $null
    }
    Write-Output -NoEnumerate $v
}

function ConvertTo-TcLibraryInfo {
    <#
    .SYNOPSIS
        ITcPlcLibrary (TE1000 5.19) -> @{ libraryName; version; distributor; displayName }, or $null.
    .DESCRIPTION
        LibraryName, else Name (ScanLibraries entries: Name = LibraryName, measured 2026-10-31).
        $null when the object is $null or every field is empty (a visu placeholder has no
        EffectiveResolution, measured 2026-10-31 4026 VS2022).
    .PARAMETER Library
        ITcPlcLibrary or $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Library)
    if ($null -eq $Library) { return $null }
    $lib = [string](Get-TcComValue -Object $Library -Name 'LibraryName')
    if ([string]::IsNullOrWhiteSpace($lib)) { $lib = [string](Get-TcComValue -Object $Library -Name 'Name') }
    $ver = [string](Get-TcComValue -Object $Library -Name 'Version')
    $dist = [string](Get-TcComValue -Object $Library -Name 'Distributor')
    $disp = [string](Get-TcComValue -Object $Library -Name 'DisplayName')
    if ([string]::IsNullOrWhiteSpace($lib) -and [string]::IsNullOrWhiteSpace($ver) -and [string]::IsNullOrWhiteSpace($dist)) { return $null }
    [PSCustomObject]@{
        libraryName = $lib
        version     = $(if ([string]::IsNullOrWhiteSpace($ver)) { $null } else { $ver })
        distributor = $(if ([string]::IsNullOrWhiteSpace($dist)) { $null } else { $dist })
        displayName = $(if ([string]::IsNullOrWhiteSpace($disp)) { $null } else { $disp })
    }
}

function ConvertTo-TcLibraryReference {
    <#
    .SYNOPSIS
        One entry of ITcPlcLibraryManager.References -> PSCustomObject (name, isPlaceholder, placeholderName,
        libraryName, version, distributor, displayName, effectiveResolution, defaultResolution, resolvedFrom).
    .DESCRIPTION
        A placeholder is listed as '#<name>' (ITcPlcLibRef.Name, TE1000 5.24 p.112; measured). On a
        placeholder LibraryName / Version / Distributor / DisplayName read as empty strings (measured
        2026-10-31 4026 VS2022), so libraryName / version / distributor come from EffectiveResolution,
        else DefaultResolution (ITcPlcPlaceholderRef / ITcPlcPlaceholderRef2, TE1000 5.26 p.120-121);
        resolvedFrom says which ('effective' | 'default' | $null).
    .PARAMETER Reference
        ITcPlcLibRef.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Reference)
    $name = [string](Get-TcComValue -Object $Reference -Name 'Name')
    $isPh = $name.StartsWith('#')
    if ($isPh) {
        $phName = [string](Get-TcComValue -Object $Reference -Name 'PlaceholderName')
        if ([string]::IsNullOrWhiteSpace($phName)) { $phName = $name.Substring(1) }
        $eff = ConvertTo-TcLibraryInfo -Library (Get-TcComValue -Object $Reference -Name 'EffectiveResolution')
        $def = ConvertTo-TcLibraryInfo -Library (Get-TcComValue -Object $Reference -Name 'DefaultResolution')
        $src = if ($null -ne $eff) { $eff } elseif ($null -ne $def) { $def } else { $null }
        return [PSCustomObject]@{
            name                = $name
            isPlaceholder       = $true
            placeholderName     = $phName
            libraryName         = $(if ($null -ne $src) { $src.libraryName } else { $null })
            version             = $(if ($null -ne $src) { $src.version } else { $null })
            distributor         = $(if ($null -ne $src) { $src.distributor } else { $null })
            displayName         = $(if ($null -ne $src) { $src.displayName } else { $null })
            effectiveResolution = $eff
            defaultResolution   = $def
            resolvedFrom        = $(if ($null -ne $eff) { 'effective' } elseif ($null -ne $def) { 'default' } else { $null })
        }
    }
    $own = ConvertTo-TcLibraryInfo -Library $Reference
    [PSCustomObject]@{
        name                = $name
        isPlaceholder       = $false
        placeholderName     = $null
        libraryName         = $(if ($null -ne $own -and -not [string]::IsNullOrWhiteSpace($own.libraryName)) { $own.libraryName } else { $name })
        version             = $(if ($null -ne $own) { $own.version } else { $null })
        distributor         = $(if ($null -ne $own) { $own.distributor } else { $null })
        displayName         = $(if ($null -ne $own) { $own.displayName } else { $null })
        effectiveResolution = $null
        defaultResolution   = $null
        resolvedFrom        = $null
    }
}

function Get-TcLibraryReferenceList {
    <#
    .SYNOPSIS
        ITcPlcLibraryManager.References of a References node: PSCustomObject[] (ConvertTo-TcLibraryReference),
        or only the names with -NamesOnly.
    .PARAMETER Refs
        References node (Resolve-TcLibraryManager).
    .PARAMETER NamesOnly
        Return [string[]] of ITcPlcLibRef.Name (placeholders as '#<name>').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Refs, [Parameter()][switch]$NamesOnly)
    $r = $Refs
    $namesOnly = [bool]$NamesOnly
    $list = Invoke-TcComRetry -OperationName 'References' -ScriptBlock {
        $__out = [System.Collections.Generic.List[object]]::new()
        foreach ($__ref in $r.References) {
            if ($namesOnly) { $__out.Add([string]$__ref.Name) }
            else { $__out.Add((ConvertTo-TcLibraryReference -Reference $__ref)) }
        }
        Write-Output -NoEnumerate $__out.ToArray()
    }
    if ($namesOnly) { return [string[]]@($list) }
    @($list)
}

function Get-TcInstalledLibraryList {
    <#
    .SYNOPSIS
        ITcPlcLibraryManager.ScanLibraries(): every library installed in any repository, one entry per
        version: PSCustomObject[] @{ name; version; distributor; displayName }.
    .DESCRIPTION
        TE1000 5.25.1 (ScanLibraries, p.113-119). Measured 2026-10-31 4026 VS2022: 473 entries in
        372-747 ms, Name = LibraryName (no '#'), DisplayName '<name>, <version> (<distributor>)'.
        The repository of an entry is not reported (Repositories returned Count=0, not explained).
    .PARAMETER Refs
        References node (Resolve-TcLibraryManager).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Refs)
    $r = $Refs
    $list = Invoke-TcComRetry -OperationName 'ScanLibraries' -ScriptBlock {
        $__out = [System.Collections.Generic.List[object]]::new()
        $__scan = $r.ScanLibraries()
        foreach ($__l in $__scan) {
            $__i = ConvertTo-TcLibraryInfo -Library $__l
            if ($null -eq $__i) { continue }
            $__out.Add([PSCustomObject]@{ name = $__i.libraryName; version = $__i.version; distributor = $__i.distributor; displayName = $__i.displayName })
        }
        Write-Output -NoEnumerate $__out.ToArray()
    }
    @($list)
}

function Get-TcLibraryKey {
    <#
    .SYNOPSIS
        'name|version|distributor' (lower case) of a library entry, for set comparisons.
    .PARAMETER Library
        Entry with name, version, distributor.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Library)
    ('{0}|{1}|{2}' -f [string]$Library.name, [string]$Library.version, [string]$Library.distributor).ToLowerInvariant()
}

function ConvertFrom-TcLibraryResolution {
    <#
    .SYNOPSIS
        'Tc2_Math, 3.5.1.0 (Beckhoff Automation GmbH)' -> @{ libraryName; version; distributor }, or $null.
    .DESCRIPTION
        Format of <DefaultResolution> / <Resolution> in the .plcproj (measured 2026-10-31 4026 VS2022:
        'Tc2_Math, * (Beckhoff Automation GmbH)' before FreezePlaceholder, 'Tc2_Math, 3.5.1.0 (...)' after).
    .PARAMETER Text
        Resolution text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $m = [regex]::Match($Text, '^\s*(?<lib>[^,]+?)\s*,\s*(?<ver>[^\s(]+)\s*(?:\((?<dist>.*)\))?\s*$')
    if (-not $m.Success) { return $null }
    [PSCustomObject]@{
        libraryName = $m.Groups['lib'].Value
        version     = $m.Groups['ver'].Value
        distributor = $(if ($m.Groups['dist'].Success) { $m.Groups['dist'].Value.Trim() } else { $null })
    }
}

function Get-TcPlcProjectLibraryEntries {
    <#
    .SYNOPSIS
        Library entries of a .plcproj on disk: @{ Placeholders = @{ <name> = entry }; Libraries = @(entries) }.
    .DESCRIPTION
        Placeholders (case-insensitive keys, no '#'): <PlaceholderReference Include> with DefaultResolution /
        Namespace, merged with <PlaceholderResolution Include><Resolution>. AddPlaceholder writes both
        elements, FreezePlaceholder only changes <Resolution> from '<lib>, * (...)' to the fixed version
        (measured 2026-10-31 4026 VS2022 through SaveAsArchive; the References objects look the same before
        and after). Entry: placeholder, defaultResolution, namespace, resolution, resolutionVersion,
        frozen (true when <Resolution> names a version other than '*'). Libraries: <LibraryReference
        Include> (e.g. 'Tc2_Math,newest,Beckhoff Automation GmbH', measured 2026-10-28): include, name
        (part before the first comma).
    .PARAMETER Path
        .plcproj path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Path)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('m', [string]$xml.DocumentElement.NamespaceURI)
    $pre = if ([string]::IsNullOrEmpty([string]$xml.DocumentElement.NamespaceURI)) { '' } else { 'm:' }
    $child = {
        param($node, [string]$localName)
        foreach ($c in @($node.ChildNodes)) { if ($c.LocalName -eq $localName) { return ([string]$c.InnerText).Trim() } }
        $null
    }
    $ph = @{}
    foreach ($n in @($xml.SelectNodes("//${pre}PlaceholderReference[@Include]", $ns))) {
        $inc = ([string]$n.GetAttribute('Include')).Trim()
        if ([string]::IsNullOrWhiteSpace($inc)) { continue }
        $ph[$inc] = [PSCustomObject]@{
            placeholder = $inc; defaultResolution = (& $child $n 'DefaultResolution'); namespace = (& $child $n 'Namespace')
            resolution = $null; resolutionVersion = $null; frozen = $false
        }
    }
    foreach ($n in @($xml.SelectNodes("//${pre}PlaceholderResolution[@Include]", $ns))) {
        $inc = ([string]$n.GetAttribute('Include')).Trim()
        if ([string]::IsNullOrWhiteSpace($inc)) { continue }
        if (-not $ph.ContainsKey($inc)) {
            $ph[$inc] = [PSCustomObject]@{ placeholder = $inc; defaultResolution = $null; namespace = $null; resolution = $null; resolutionVersion = $null; frozen = $false }
        }
        $res = & $child $n 'Resolution'
        $parsed = ConvertFrom-TcLibraryResolution -Text $res
        $ver = if ($null -ne $parsed) { $parsed.version } else { $null }
        $ph[$inc].resolution = $res
        $ph[$inc].resolutionVersion = $ver
        $ph[$inc].frozen = (-not [string]::IsNullOrWhiteSpace($ver) -and $ver -ne '*')
    }
    $libs = [System.Collections.Generic.List[object]]::new()
    foreach ($n in @($xml.SelectNodes("//${pre}LibraryReference[@Include]", $ns))) {
        $inc = ([string]$n.GetAttribute('Include')).Trim()
        if ([string]::IsNullOrWhiteSpace($inc)) { continue }
        $libs.Add([PSCustomObject]@{ include = $inc; name = $inc.Split(',')[0].Trim() })
    }
    @{ Placeholders = $ph; Libraries = $libs.ToArray() }
}

function Test-TcPlcProjectHasLibraryEntry {
    <#
    .SYNOPSIS
        True when the .plcproj entries (Get-TcPlcProjectLibraryEntries) still name -Name: a placeholder
        (PlaceholderReference / PlaceholderResolution Include) or a LibraryReference (name before the comma).
    .PARAMETER Entries
        Result of Get-TcPlcProjectLibraryEntries.
    .PARAMETER Name
        Placeholder or library name without '#'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entries, [Parameter(Mandatory)][string]$Name)
    if ($Entries.Placeholders.ContainsKey($Name)) { return $true }
    @($Entries.Libraries | Where-Object { $_.name -ieq $Name }).Count -gt 0
}

function Get-TcLibraryPlcProjFile {
    <#
    .SYNOPSIS
        .plcproj path of the PLC that owns a References path (Get-TcPlcProjectFile); throws 'save: locate: ...'.
    .PARAMETER RefsPath
        TIPC^<Plc>^<Plc> Project^References.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RefsPath)
    $plc = Get-TcPlcNameFromPath -TreePath $RefsPath
    if ($null -eq $plc) { throw "save: locate: '$RefsPath' is not below TIPC^<Plc>." }
    [string](Get-TcPlcProjectFile -PlcName $plc).PlcProjFile
}

function Invoke-TcLibraryProjectBackup {
    <#
    .SYNOPSIS
        Copies the .plcproj into <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\ before a Library Manager
        write: @{ Result = $null | <LIBRARY_BACKUP_FAILED>; Backup = @{ backupPath; backupDir; backupFiles; warnings } }.
    .DESCRIPTION
        New-TcTreeItemBackup (same folder layout as the tree tools, design D2): backupPath holds the
        .plcproj text, backupFiles[0] is a byte-exact copy of the file (restore it while the solution is
        closed). The backup is the file ON DISK: changes that only live in XAE memory are not in it.
        Unknown solution directory, missing or unreadable .plcproj -> LIBRARY_BACKUP_FAILED, the caller
        must not write.
    .PARAMETER PlcProjFile
        .plcproj path.
    .PARAMETER RefsPath
        References tree path (backup file name).
    .PARAMETER Data
        Data attached to a failed result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlcProjFile,
        [Parameter(Mandatory)][string]$RefsPath,
        [Parameter()][object]$Data
    )
    $fail = {
        param([string]$why)
        @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'LIBRARY_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage "Backup of the .plcproj failed, nothing was changed: $why" -Hint (Get-TcErrorHint -Code 'LIBRARY_BACKUP_FAILED')) }
    }
    $solutionDir = Get-TcTreeItemSolutionDir
    if ($null -eq $solutionDir) { return (& $fail 'no solution path is known (Connect-TcIde -SolutionPath / Open-TcProject)') }
    if ([string]::IsNullOrWhiteSpace($PlcProjFile) -or -not (Test-Path -LiteralPath $PlcProjFile -PathType Leaf)) {
        return (& $fail "the .plcproj '$PlcProjFile' does not exist")
    }
    try {
        $text = [System.IO.File]::ReadAllText($PlcProjFile)
        $b = New-TcTreeItemBackup -SolutionDir $solutionDir -Path $RefsPath -Xml $text -DiskFiles @($PlcProjFile) -Tag 'plcproj'
        if (@($b.backupFiles).Count -eq 0) { return (& $fail "the copy of '$PlcProjFile' was not written ($(@($b.warnings) -join '; '))") }
        return @{ Backup = $b; Result = $null }
    }
    catch { return (& $fail $_.Exception.Message) }
}

function New-TcLibraryErrorResult {
    <#
    .SYNOPSIS
        Failed result for an exception inside a Library Manager cmdlet.
    .DESCRIPTION
        $script:TcTreeItemPassThroughCodes keep their code (IDE_MODAL_DIALOG with the watchdog record,
        IDE_CRASHED / IDE_TIMEOUT / IDE_BUSY, PLC_LOGGED_IN with the hint to rerun -Operation after
        Exit-TcPlcOnline); everything else -DefaultCode with its hint. The message carries HRESULT and
        text of the exception chain (Get-TcLibraryErrorText).
    .PARAMETER ErrorRecord
        The caught ErrorRecord.
    .PARAMETER DefaultCode
        Code when no pass-through code matches.
    .PARAMETER Data
        Data attached to the result.
    .PARAMETER Operation
        Cmdlet / call name for the message and the PLC_LOGGED_IN hint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ErrorRecord,
        [Parameter(Mandatory)][string]$DefaultCode,
        [Parameter()][object]$Data,
        [Parameter(Mandatory)][string]$Operation
    )
    $text = Get-TcLibraryErrorText -ErrorRecord $ErrorRecord
    $mapped = Get-TcTreeItemPassThroughError -ErrorRecord $ErrorRecord
    $code = $DefaultCode
    $hint = Get-TcErrorHint -Code $DefaultCode
    if ($null -ne $mapped) {
        $code = $mapped.Code
        if ($code -eq 'IDE_MODAL_DIALOG' -and $null -ne $script:TcLastModalDialog) {
            $p = @{ Dialog = $script:TcLastModalDialog; Operation = $Operation }
            if ($null -ne $Data) { $p['Data'] = $Data }
            return New-TcModalDialogResult @p
        }
        $hint = $mapped.Hint
        if ($code -eq 'PLC_LOGGED_IN') { $hint = ([string]$script:TcTreeItemPlcLoggedInHint).Replace('{operation}', $Operation) }
    }
    $p = @{ Success = $false; ErrorCode = $code; ErrorMessage = "$Operation failed: $text" }
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $p['Hint'] = $hint }
    if ($null -ne $Data) { $p['Data'] = $Data }
    New-TcResult @p
}

function New-TcLibraryFailure {
    <#
    .SYNOPSIS
        Failed result with -Code, its central hint and data.reason (when given).
    .PARAMETER Code
        Error code.
    .PARAMETER Message
        error.message.
    .PARAMETER Data
        PSCustomObject; reason is added to it.
    .PARAMETER Reason
        data.reason (optional).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [Parameter()][object]$Data,
        [Parameter()][string]$Reason
    )
    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $Data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force }
    New-TcResult -Success $false -ErrorCode $Code -ErrorMessage $Message -Hint (Get-TcErrorHint -Code $Code) -Data $Data
}

# Root folder of the 'System' library repository. Measured 2026-10-31 4026 VS2022 (phase2-probe.md 3.1):
# InstallLibrary('System', ...) created <root>\<Distributor>\<Library>\<Version> and UninstallLibrary removed it.
# Overridable for tests. ITcPlcLibraryManager.Repositories (Name / Folder, TE1000 5.22 / 5.23 p.111-112) is
# tried first, but returned Count=0 in the probe.
$script:TcSystemLibraryRepositoryRoot = Join-Path ([string]$env:ProgramData) 'Beckhoff\TwinCAT\PlcEngineering\Managed Libraries'

function Get-TcLibraryRepositoryVersionFolder {
    <#
    .SYNOPSIS
        Folder of one installed library version in a repository: @{ Path = <existing folder> | $null; Root; Source; Tried = @() }.
    .DESCRIPTION
        Repository root: the Folder of the entry named -Repository in ITcPlcLibraryManager.Repositories
        (Source 'repositories'), else for 'System' $script:TcSystemLibraryRepositoryRoot (Source
        'measured-default'). The version folder is <root>\<Distributor>\<LibraryName>\<Version> (layout
        measured 2026-10-31 4026 VS2022). Path is $null when no root is known or the folder does not exist.
    .PARAMETER Refs
        References node.
    .PARAMETER Repository
        Repository name.
    .PARAMETER Library
        ScanLibraries entry (name, version, distributor).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Refs, [Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)]$Library)
    $r = $Refs
    $roots = [System.Collections.Generic.List[object]]::new()
    $repoFolder = $null
    try {
        $repoFolder = Invoke-TcComRetry -OperationName 'Repositories' -ScriptBlock {
            $__f = $null
            $__all = Get-TcComValue -Object $r -Name 'Repositories'
            if ($null -ne $__all) {
                foreach ($__rep in $__all) {
                    if ([string](Get-TcComValue -Object $__rep -Name 'Name') -ieq $Repository) { $__f = [string](Get-TcComValue -Object $__rep -Name 'Folder'); break }
                }
            }
            $__f
        }
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        $repoFolder = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($repoFolder)) { $roots.Add(@{ Root = $repoFolder; Source = 'repositories' }) }
    if ($Repository -ieq 'System' -and -not [string]::IsNullOrWhiteSpace($script:TcSystemLibraryRepositoryRoot)) {
        $roots.Add(@{ Root = $script:TcSystemLibraryRepositoryRoot; Source = 'measured-default' })
    }
    $tried = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $roots) {
        $p = Join-Path (Join-Path (Join-Path $c.Root ([string]$Library.distributor)) ([string]$Library.name)) ([string]$Library.version)
        $tried.Add($p)
        if (Test-Path -LiteralPath $p -PathType Container) { return @{ Path = $p; Root = $c.Root; Source = $c.Source; Tried = $tried.ToArray() } }
    }
    @{ Path = $null; Root = $null; Source = $null; Tried = $tried.ToArray() }
}

function Invoke-TcLibraryRepositoryBackup {
    <#
    .SYNOPSIS
        Copies a repository version folder to <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\library-repo\<name>\<version>\
        before UninstallLibrary: @{ Result = $null | <LIBRARY_BACKUP_FAILED>; Backup = @{ backupPath; sourcePath; fileCount } }.
    .DESCRIPTION
        Unknown solution directory, no source folder, a failed copy or a copy with a different file count
        -> LIBRARY_BACKUP_FAILED (the caller must not uninstall).
    .PARAMETER SourcePath
        Version folder in the repository ($null when it could not be derived).
    .PARAMETER Library
        ScanLibraries entry (name, version).
    .PARAMETER Data
        Data attached to a failed result.
    .PARAMETER Tried
        Paths that were tried (message).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SourcePath,
        [Parameter(Mandatory)]$Library,
        [Parameter()][object]$Data,
        [Parameter()][string[]]$Tried = @()
    )
    $fail = {
        param([string]$why)
        @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'LIBRARY_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage "Backup of the repository folder failed, nothing was uninstalled: $why" -Hint (Get-TcErrorHint -Code 'LIBRARY_BACKUP_FAILED')) }
    }
    if ([string]::IsNullOrWhiteSpace($SourcePath)) { return (& $fail "the version folder of '$($Library.name) $($Library.version)' could not be derived (tried: $(@($Tried) -join '; '))") }
    $solutionDir = Get-TcTreeItemSolutionDir
    if ($null -eq $solutionDir) { return (& $fail 'no solution path is known (Connect-TcIde -SolutionPath / Open-TcProject)') }
    try {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $base = Join-Path (Join-Path (Join-Path $solutionDir $script:TcTreeItemBackupFolder) $ts) 'library-repo'
        $dest = Join-Path (Join-Path $base (ConvertTo-TcSafeFileName -Name ([string]$Library.name))) (ConvertTo-TcSafeFileName -Name ([string]$Library.version))
        if (Test-Path -LiteralPath $dest) { return (& $fail "'$dest' already exists") }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction Stop
        Copy-Item -LiteralPath $SourcePath -Destination $dest -Recurse -Force -ErrorAction Stop
        $srcCount = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -File -Force -ErrorAction Stop).Count
        $dstCount = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction Stop).Count
        if ($srcCount -ne $dstCount) { return (& $fail "the copy in '$dest' has $dstCount files, the source '$SourcePath' $srcCount") }
        return @{ Result = $null; Backup = @{ backupPath = $dest; sourcePath = $SourcePath; fileCount = $dstCount } }
    }
    catch { return (& $fail $_.Exception.Message) }
}
