# PLCopen XML helpers (complete-automation-interface phase 2, task 3.3): Export-TcPlcOpen, Import-TcPlcOpen.
# API: ITcPlcOpenImportExport.PlcOpenExport(file, selection) / PlcOpenImport(file, options, selection,
# bSubTree) on the '<Plc> Project' node (TE1000 Automation Interface manual v1.7.0, 5.20 p.105-108,
# sample 6.5.4 p.228-229; PLCIMPORTOPTIONS 5.46.7 p.161).
# Behaviour measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
# openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.3):
#   - selection: '.' between folder levels, ';' between objects; '^' -> COMException 0x98510008
#     "Selection '...' not found!"; a method / accessor alone -> ArgumentException "Couldn't create
#     ExportObjects"; PlcOpenExport always includes the subtree (methods, properties, actions).
#   - import options: NONE = exception on a conflict and nothing imported; SKIP = conflicts skipped
#     silently; REPLACE = the whole object replaced, children the file does not have are deleted
#     (an ITF lost its properties); RENAME = '_1' appended to the imported object.
#   - PlcOpenExport includes the subtree of an object, except the properties of an INTERFACE that
#     have no Get / Set: they are not exported (only the methods are).

$script:TcPlcOpenImportOptions = [ordered]@{ None = 0; Replace = 1; Rename = 2; Skip = 3 }
# selection that XAE refused with "Selection '...' not found!" (measured, phase2-probe.md 3.3)
$script:TcPlcOpenSelectionNotFoundHResult = [int]0x98510008
# children of a POU / interface: a selection pointing at one of them is refused before the call
$script:TcPlcOpenMemberItemTypes = @(608, 609, 610, 611, 612, 613, 614, 616, 654, 655)
# top-level PLC objects (InfoSys "ITcSmTreeItem Item Types",
# https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html): POU, DUT, GVL, ITF
$script:TcPlcTopLevelItemTypes = @(602, 603, 604, 605, 606, 607, 615, 618, 623)

function Test-TcPlcOpenSelection {
    <#
    .SYNOPSIS
        Checks the -Selection elements of Export-TcPlcOpen: $null when usable, else @{ Reason = 'invalid-selection'; Message; Element }.
    .DESCRIPTION
        Each element is one object or folder, '.' between the folder levels (POUs.FB_A,
        LIB.AxisControl.FB_AxisControl). Refused: an empty element, '^' (XAE answers 0x98510008
        "Selection 'A^B' not found!", measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built
        client), ';' inside an element (the module joins the elements with ';'), an empty level
        ('.' at the start / end, '..').
    .PARAMETER Selection
        Selection elements.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Selection = @())
    foreach ($s in @($Selection)) {
        $why = $null
        if ([string]::IsNullOrWhiteSpace($s)) { $why = 'an element is empty' }
        elseif ($s.Contains('^')) { $why = "'$s' uses '^': PLCopen selections use '.' between folder levels (XAE answers 0x98510008 'not found' for '^')" }
        elseif ($s.Contains(';')) { $why = "'$s' contains ';': pass each object as its own -Selection element, the module joins them with ';'" }
        elseif ($s.Trim().StartsWith('.') -or $s.Trim().EndsWith('.') -or $s.Contains('..')) { $why = "'$s' has an empty level ('.' at the start or end, or '..')" }
        if ($null -ne $why) { return @{ Reason = 'invalid-selection'; Message = "-Selection $why"; Element = $s } }
    }
    return $null
}

function Find-TcPlcOpenSelectionItem {
    <#
    .SYNOPSIS
        Tree item a selection element points at: @{ Path; ItemType; Item } or $null when it is not found.
    .DESCRIPTION
        First '<ProjectPath>^' + the element with '.' -> '^' (LookupTreeItem), then Resolve-TcPouPath
        -Name <element> -ProjectPath (a bare name such as 'FB_A' or 'FB_A.M_Run', which XAE also
        accepts: 'FB_P2Probe' exported the FB below POUs, measured 2026-10-31 4026 VS2022, self-built
        client). Ambiguous or not found -> $null (XAE decides). IDE_* errors are rethrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER ProjectPath
        '<Plc> Project' tree path.
    .PARAMETER Element
        One selection element.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SysManager, [Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][string]$Element)
    $direct = "$ProjectPath^" + ($Element.Trim() -replace '\.', '^')
    $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $direct
    $path = $direct
    if ($null -eq $item) {
        $res = Resolve-TcPouPath -SysManager $SysManager -Name $Element.Trim() -ProjectPath $ProjectPath
        if (-not $res.Found) { return $null }
        $item = $res.Item
        $path = [string]$res.Path
    }
    $t = try { [int]$item.ItemType } catch { -1 }
    return @{ Path = $path; ItemType = $t; Item = $item }
}

function Get-TcPlcOpenParentSelection {
    <#
    .SYNOPSIS
        Selection of the object that contains a member: walks up from -Path while the ItemType is a
        member type ($script:TcPlcOpenMemberItemTypes) and returns that path relative to -ProjectPath
        with '.' ('...^POUs^FB_A^M_Run' -> 'POUs.FB_A'), or $null.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER ProjectPath
        '<Plc> Project' tree path.
    .PARAMETER Path
        Tree path of the member.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SysManager, [Parameter(Mandatory)][string]$ProjectPath, [Parameter(Mandatory)][string]$Path)
    $p = Get-TcTreePathParent -Path $Path
    while ($null -ne $p -and $p.Length -gt $ProjectPath.Length) {
        $it = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $p
        $t = if ($null -eq $it) { -1 } else { try { [int]$it.ItemType } catch { -1 } }
        if ($script:TcPlcOpenMemberItemTypes -notcontains $t) {
            if (-not $p.StartsWith("$ProjectPath^", [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            return ($p.Substring($ProjectPath.Length + 1) -replace '\^', '.')
        }
        $p = Get-TcTreePathParent -Path $p
    }
    return $null
}

function Read-TcPlcOpenFile {
    <#
    .SYNOPSIS
        Objects of a PLCopen XML file: @{ Objects = @({ name; kind; pouType; folder; members = @({ name; kind }) }); Folders = @(names) }.
    .DESCRIPTION
        Loaded with Read-TcXmlFile (no DTD, no resolver: no XXE). Elements are matched by local name,
        any namespace (TC6 XML, http://www.plcopen.org/xml/tc6_0200):
          POU   project/types/pous/pou[@name] and every addData/data/pou[@name]
                (pouType = @pouType: program / functionBlock / function)
          DUT   project/types/dataTypes/dataType[@name] and every addData/data/dataType[@name]
          ITF   every addData/data/Interface[@name]
          GVL   every globalVars[@name], one object per name (a GVL with several sections, e.g. a
                persistent one, is written as several globalVars of the same name)
        A whole-project export puts the objects below
        project/addData/data/resource/addData/data/(pou | dataType | Interface) and the GVLs in
        project/addData/data/resource/globalVars (measured 2026-10-31 4026 VS2022, registered tcauto,
        verification/phase2-3.8.md P5: 21 pou, 48 dataType, GVL_Motion as 3 globalVars).
        Members: <object>/addData/data/(Method | Property | Action | Transition)[@name], the
        PLCopen pou/actions/action, pou/transitions/transition, and for an INTERFACE
        Interface/Methods/Method (measured 2026-10-31, P5 / P6: I_P38Base had
        <Methods><Method name="M_Do">) and Interface/Properties/Property (NOT measured: the measured
        file had an empty <Properties />, its property without accessors was not exported; left out
        with -ExcludeInterfaceProperties, which Import-TcPlcOpen uses so a property is never assumed
        to survive a Replace). folder: the Folder names around the object in addData/data/ProjectStructure ('.'
        joined), $null when not listed there (a whole-project export wraps the folders in an
        <Object> for the project itself, measured). Folders: every ProjectStructure Folder name.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client (phase2-probe.md 3.3): an
        exported FB lists <Method name=...>; an ITF lists its methods, its properties without
        accessors only in the ProjectStructure. The other element paths follow the PLCopen TC6 schema
        and are not measured.
        Throws when the file cannot be parsed or its root element is not 'project'.
    .PARAMETER Path
        PLCopen XML file.
    .PARAMETER ExcludeInterfaceProperties
        Do not list Interface/Properties/Property as members (not measured).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter()][switch]$ExcludeInterfaceProperties)
    $doc = Read-TcXmlFile -Path $Path
    $root = $doc.DocumentElement
    if ($null -eq $root -or $root.LocalName -ne 'project') {
        $rn = if ($null -eq $root) { '(none)' } else { $root.LocalName }
        throw "not a PLCopen XML file: the root element is <$rn>, not <project>"
    }
    $ln = { param([string]$n) "*[local-name()='$n']" }
    # folder per object name from the ProjectStructure
    $folderOf = @{}
    $folders = [System.Collections.Generic.List[string]]::new()
    foreach ($ps in @($doc.SelectNodes("//$(& $ln 'ProjectStructure')"))) {
        foreach ($f in @($ps.SelectNodes(".//$(& $ln 'Folder')"))) { $fn = $f.GetAttribute('Name'); if (-not [string]::IsNullOrEmpty($fn)) { $folders.Add($fn) } }
        foreach ($o in @($ps.SelectNodes(".//$(& $ln 'Object')"))) {
            if ($o.ParentNode.LocalName -eq 'Object') { continue }
            $chain = @()
            $q = $o.ParentNode
            while ($null -ne $q -and $q.LocalName -eq 'Folder') { $chain = @($q.GetAttribute('Name')) + $chain; $q = $q.ParentNode }
            $on = $o.GetAttribute('Name')
            if (-not [string]::IsNullOrEmpty($on) -and -not $folderOf.ContainsKey($on)) { $folderOf[$on] = $(if ($chain.Count -gt 0) { $chain -join '.' } else { $null }) }
        }
    }
    $members = {
        param($node)
        $list = [System.Collections.Generic.List[object]]::new()
        $xp = "./$(& $ln 'addData')/$(& $ln 'data')/*[local-name()='Method' or local-name()='Property' or local-name()='Action' or local-name()='Transition']" +
            " | ./$(& $ln 'actions')/$(& $ln 'action') | ./$(& $ln 'transitions')/$(& $ln 'transition')" +
            " | ./$(& $ln 'Methods')/$(& $ln 'Method')" +
            $(if ($ExcludeInterfaceProperties) { '' } else { " | ./$(& $ln 'Properties')/$(& $ln 'Property')" })
        foreach ($m in @($node.SelectNodes($xp))) {
            $mn = $m.GetAttribute('name')
            if ([string]::IsNullOrEmpty($mn)) { continue }
            $list.Add([PSCustomObject]@{ name = $mn; kind = $m.LocalName.ToUpperInvariant() })
        }
        , $list.ToArray()
    }
    $objects = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($node, [string]$kind, [string]$pouType)
        $n = $node.GetAttribute('name')
        if ([string]::IsNullOrEmpty($n)) { return }
        $key = "$kind|$($n.ToUpperInvariant())"
        if ($seen.ContainsKey($key)) {
            # same object again (a GVL section, or the same object in types and addData): merge its members
            $o = $seen[$key]
            $more = @(& $members $node | Where-Object { $mn = $_.name; @($o.members | Where-Object { $_.name -ieq $mn }).Count -eq 0 })
            if ($more.Count -gt 0) { $o.members = @(@($o.members) + $more) }
            return
        }
        $seen[$key] = [PSCustomObject]@{
                name    = $n
                kind    = $kind
                pouType = $(if ([string]::IsNullOrEmpty($pouType)) { $null } else { $pouType })
                folder  = $(if ($folderOf.ContainsKey($n)) { $folderOf[$n] } else { $null })
                members = (& $members $node)
            }
        $objects.Add($seen[$key])
    }
    $seen = @{}
    $p = "/$(& $ln 'project')"
    $inData = "//$(& $ln 'addData')/$(& $ln 'data')"
    foreach ($n in @($doc.SelectNodes("$p/$(& $ln 'types')/$(& $ln 'pous')/$(& $ln 'pou') | $inData/$(& $ln 'pou')"))) { & $add $n 'POU' $n.GetAttribute('pouType') }
    foreach ($n in @($doc.SelectNodes("$p/$(& $ln 'types')/$(& $ln 'dataTypes')/$(& $ln 'dataType') | $inData/$(& $ln 'dataType')"))) { & $add $n 'DUT' $null }
    foreach ($n in @($doc.SelectNodes("$inData/$(& $ln 'Interface')"))) { & $add $n 'ITF' $null }
    foreach ($n in @($doc.SelectNodes("//$(& $ln 'globalVars')[@name]"))) { & $add $n 'GVL' $null }
    return @{ Objects = $objects.ToArray(); Folders = @($folders.ToArray() | Select-Object -Unique) }
}

function Get-TcPlcProjectObjectIndex {
    <#
    .SYNOPSIS
        Top-level objects (POU, DUT, GVL, ITF) of a PLC project: @{ Objects = @({ name; path; itemType }); Complete; Note }.
    .DESCRIPTION
        One walk over '<Plc> Project' and every PLC folder (ItemType 601) below it, the same walk as
        Find-TcPlcNameConflict but for all names at once (an import file can hold hundreds of objects).
        Children of POUs (methods, actions ...) are not visited. Stops after -MaxNodes nodes
        (Complete = $false, Note says so). A node that cannot be read is skipped (counted in the Note).
        IDE_* errors are rethrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER ProjectPath
        '<Plc> Project' tree path.
    .PARAMETER MaxNodes
        Upper bound of visited nodes (default 3000).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SysManager, [Parameter(Mandatory)][string]$ProjectPath, [Parameter()][int]$MaxNodes = 3000)
    $sm = $SysManager
    $topLevel = $script:TcPlcTopLevelItemTypes
    # RPC busy / IDE_* inside the walk: rethrown so Invoke-TcComRetry retries (or reports) the walk,
    # as in Find-TcPlcNameConflict
    $retryPattern = '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER|IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $walk = Invoke-TcComRetry -OperationName "Object index of $ProjectPath" -ScriptBlock {
        $__list = [System.Collections.Generic.List[object]]::new()
        $__visited = 0; $__skipped = 0; $__over = $false
        $__queue = New-Object System.Collections.Queue
        $__queue.Enqueue([PSCustomObject]@{ Item = $sm.LookupTreeItem($ProjectPath); Path = $ProjectPath })
        while ($__queue.Count -gt 0 -and -not $__over) {
            $__e = $__queue.Dequeue()
            $__cnt = 0
            try { $__cnt = [int]$__e.Item.ChildCount } catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++; continue }
            for ($__j = 1; $__j -le $__cnt; $__j++) {
                $__visited++
                if ($__visited -gt $MaxNodes) { $__over = $true; break }
                try {
                    $__c = $__e.Item.Child($__j)
                    $__t = [int]$__c.ItemType
                    $__n = [string]$__c.Name
                    $__p = "$($__e.Path)^$__n"
                    if ($__t -eq 601) { $__queue.Enqueue([PSCustomObject]@{ Item = $__c; Path = $__p }); continue }
                    if ($topLevel -contains $__t) { $__list.Add([PSCustomObject]@{ name = $__n; path = $__p; itemType = $__t }) }
                }
                catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++ }
            }
        }
        @{ Objects = $__list.ToArray(); Visited = $__visited; Skipped = $__skipped; Over = $__over }
    }
    $note = $null
    if ($walk.Over) { $note = "more than $MaxNodes nodes below '$ProjectPath': objects further on were not checked" }
    elseif ($walk.Skipped -gt 0) { $note = "$($walk.Skipped) node(s) below '$ProjectPath' could not be read and were not checked" }
    return @{ Objects = @($walk.Objects); Complete = ($null -eq $note); Note = $note }
}

function Invoke-TcPlcObjectExportZip {
    <#
    .SYNOPSIS
        ExportChild of one PLC object into -ExportFile (.zip): @{ ExportPath = <path> | $null; Error = $null | message }.
    .DESCRIPTION
        <parent>.ExportChild(<name>, <file>) as Remove-TcTreeItem does before DeleteChild; a node below
        TIPC is exported to .zip (Get-TcTreeItemExportExtension, measured 2026-10-30 on a PLC folder).
        ExportChild of a POU / DUT / GVL / ITF node is NOT measured, so the caller treats a failure as
        a warning only. A modal dialog before the call is reported as an Error (nothing exported).
        IDE_* errors are rethrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        Tree path of the object.
    .PARAMETER ExportFile
        File to write (must not exist).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SysManager, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$ExportFile)
    $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $Path
    if ($null -eq $item) { return @{ ExportPath = $null; Error = "'$Path' is not found" } }
    $parentPath = Get-TcTreePathParent -Path $Path
    $parent = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $parentPath
    if ($null -eq $parent) { return @{ ExportPath = $null; Error = "the parent '$parentPath' is not found" } }
    $name = try { [string]$item.Name } catch { Get-TcTreePathLeaf -Path $Path }
    if ([string]::IsNullOrEmpty($name)) { $name = Get-TcTreePathLeaf -Path $Path }
    $dlg = Get-TcTreeItemDialogResult -Operation "ExportChild '$Path' (backup)" -Data ([PSCustomObject]@{})
    if ($null -ne $dlg) { return @{ ExportPath = $null; Error = [string]$dlg.error.message } }
    try {
        # No deadline (CODING_STANDARDS.md section 1), same as the ExportChild backup of Remove-TcTreeItem:
        # a dialog was ruled out just above and Connect-TcIde turns on ITcAutomationSettings.SilentMode.
        # ExportChild of a POU node: not measured.
        Invoke-TcComRetry -OperationName "ExportChild $Path (backup)" -ScriptBlock { $parent.ExportChild($name, $ExportFile) } | Out-Null
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        return @{ ExportPath = $null; Error = "ExportChild failed ($($_.Exception.Message))" }
    }
    if (-not (Test-Path -LiteralPath $ExportFile -PathType Leaf)) { return @{ ExportPath = $null; Error = "ExportChild returned, but '$ExportFile' does not exist" } }
    return @{ ExportPath = $ExportFile; Error = $null }
}

function Get-TcFileSha256 {
    <#
    .SYNOPSIS
        SHA-256 (hex) of a file, or $null when it cannot be read. Never throws.
    .PARAMETER Path
        File path.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    try { return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash } catch { return $null }
}

function Invoke-TcPlcOpenReplaceBackup {
    <#
    .SYNOPSIS
        Backup before PlcOpenImport REPLACE: @{ Result = $null | failed result; Backup }.
    .DESCRIPTION
        1. Required: one PLCopen XML file of every object that will be replaced, written with
           PlcOpenExport on '<Plc> Project' into <solution dir>\.tcauto-backup\<time>\plcopen-replace.xml
           (-2, -3 ... when taken). It must exist, parse (Read-TcPlcOpenFile) and list every object;
           else PLCOPEN_BACKUP_FAILED reason plcopen-backup-failed. PlcOpenExport includes the
           subtree of each object, EXCEPT the properties of an INTERFACE that have no Get / Set:
           they are not exported (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built
           client, phase2-probe.md 3.3).
        2. Per object the direct children of the project are compared with the members the XML
           lists (names, case-insensitive). An object with children missing from the XML
           (childrenNotInXml) cannot be restored from the XML alone, so for it the ProduceXml
           (recursive) and disk file backup (Invoke-TcTreeItemBackup; .TcIO / .TcPOU / .TcDUT /
           .TcGVL) is REQUIRED: no backup or no disk file copied -> PLCOPEN_BACKUP_FAILED reason
           disk-backup-failed.
        3. Best effort for every object: that ProduceXml / disk file backup (objects without a gap)
           and an ExportChild .zip (Invoke-TcPlcObjectExportZip; ExportChild of a POU node is not
           measured); a failure is only a warning.
        Restore: Import-TcPlcOpen -FilePath <xmlPath> -Option Replace -DryRun $false (Backup.restore)
        brings back what the XML holds; Backup.diskOnly lists per object the children that are only
        in the disk file copy / .zip, with the way back: copy the disk file copy over the original
        file, then Reset-TcSolution (not measured), or Import-TcTreeItem of the .zip (not measured).
        Solution folder unknown -> PLCOPEN_BACKUP_FAILED reason backup-failed. IDE_MODAL_DIALOG when
        a dialog is open before the export. IDE_* errors are rethrown.
        Backup = { xmlPath; objects; restore; restoreNote; diskOnly[]; objectBackups[]; warnings[] }.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Project
        The '<Plc> Project' tree item.
    .PARAMETER ProjectPath
        Its tree path.
    .PARAMETER Paths
        Tree paths of the objects that will be replaced.
    .PARAMETER Data
        Data object of the cmdlet (reason / backupObject are added on failure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SysManager,
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][object]$Data
    )
    $fail = {
        param([string]$Reason, [string]$Message, $Objects)
        $Data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force
        $Data | Add-Member -NotePropertyName backupObject -NotePropertyValue @($Objects) -Force
        @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'PLCOPEN_BACKUP_FAILED' -Data $Data -ErrorMessage "$Message; PlcOpenImport was not called, nothing was imported." -Hint (Get-TcErrorHint -Code 'PLCOPEN_BACKUP_FAILED')) }
    }
    $solutionDir = Get-TcTreeItemSolutionDir
    if ($null -eq $solutionDir) { return (& $fail 'backup-failed' 'No solution path is known (Connect-TcIde -SolutionPath / Open-TcProject), the PLCopen backup cannot be written' $Paths) }
    $sel = @($Paths | ForEach-Object {
            if (-not $_.StartsWith("$ProjectPath^", [System.StringComparison]::OrdinalIgnoreCase)) { $_ } else { $_.Substring($ProjectPath.Length + 1) -replace '\^', '.' }
        })
    $xml = $null
    try {
        $dir = Join-Path (Join-Path $solutionDir $script:TcTreeItemBackupFolder) ((Get-Date).ToString('yyyyMMdd-HHmmss'))
        if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
        $xml = Join-Path $dir 'plcopen-replace.xml'
        $n = 1
        while (Test-Path -LiteralPath $xml) { $n++; $xml = Join-Path $dir "plcopen-replace-$n.xml" }
    }
    catch { return (& $fail 'backup-failed' "the backup folder below '$solutionDir' cannot be written ($($_.Exception.Message))" $Paths) }
    $dlg = Get-TcTreeItemDialogResult -Operation 'PlcOpenExport backup before PlcOpenImport REPLACE' -Data $Data
    if ($null -ne $dlg) { return @{ Backup = $null; Result = $dlg } }
    $selString = $sel -join ';'
    try {
        # No deadline: same call and reasons as Export-TcPlcOpen (dialog ruled out above, SilentMode,
        # 145-231 ms measured).
        Invoke-TcComRetry -OperationName 'PlcOpenExport (backup)' -ScriptBlock { $Project.PlcOpenExport($xml, $selString) } | Out-Null
    }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        return (& $fail 'plcopen-backup-failed' "PlcOpenExport backup of $selString failed ($((Get-TcComErrorInfo -ErrorRecord $_).message))" $Paths)
    }
    $parsed = $null
    try { $parsed = Read-TcPlcOpenFile -Path $xml }
    catch { return (& $fail 'plcopen-backup-failed' "the PLCopen backup '$xml' was not written or cannot be read ($($_.Exception.Message))" $Paths) }
    $xmlObjects = @($parsed.Objects)
    $missing = @($Paths | Where-Object { $leaf = Get-TcTreePathLeaf -Path $_; @($xmlObjects | Where-Object { $_.name -ieq $leaf }).Count -eq 0 })
    if ($missing.Count -gt 0) { return (& $fail 'plcopen-backup-failed' "the PLCopen backup '$xml' lacks $(($missing | ForEach-Object { "'$_'" }) -join ', ')" $missing) }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $objectBackups = [System.Collections.Generic.List[object]]::new()
    $diskOnly = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $Paths) {
        $leaf = Get-TcTreePathLeaf -Path $p
        $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $p
        $kids = if ($null -ne $item) { @(Get-TcTreeItemChildNames -Item $item) } else { @() }
        $xo = @($xmlObjects | Where-Object { $_.name -ieq $leaf })[0]
        $xmlMembers = @($xo.members | ForEach-Object { $_.name })
        $gap = @($kids | Where-Object { $k = $_; @($xmlMembers | Where-Object { $_ -ieq $k }).Count -eq 0 })
        $itemType = if ($null -ne $item) { try { [int]$item.ItemType } catch { -1 } } else { -1 }
        $disk = Find-TcTreeItemDiskFile -SolutionDir $solutionDir -Path $p -Name $leaf -ItemType $itemType
        $original = @($disk.Files)[0]
        $bk = $null
        if ($null -ne $item) { $bk = Invoke-TcTreeItemBackup -Item $item -Path $p -Data ([PSCustomObject]@{}) -Recursive }
        $copy = if ($null -ne $bk -and $null -eq $bk.Result) { @($bk.Backup.backupFiles)[0] } else { $null }
        if ($gap.Count -gt 0 -and ([string]::IsNullOrEmpty($copy) -or [string]::IsNullOrEmpty($original))) {
            $why = if ($null -eq $item) { 'the object is not found' } elseif ($null -ne $bk -and $null -ne $bk.Result) { [string]$bk.Result.error.message } else { "no disk file of '$p' was found or copied ($(@($disk.Warnings) -join '; '))" }
            return (& $fail 'disk-backup-failed' "'$p' has children the PLCopen backup does not hold ($($gap -join ', '); the properties of an interface without Get / Set are not exported, measured 2026-10-31), so its disk file backup is required, but it failed: $why" @($p))
        }
        if ($null -ne $bk -and $null -ne $bk.Result) { $warnings.Add("the ProduceXml / disk file backup of '$p' failed: $([string]$bk.Result.error.message); the PLCopen backup '$xml' holds it") }
        if ($null -ne $bk -and $null -eq $bk.Result) { foreach ($w in @($bk.Backup.warnings)) { $warnings.Add($w) } }
        $zip = $null
        if ($null -ne $bk -and $null -eq $bk.Result) {
            $z = Invoke-TcPlcObjectExportZip -SysManager $SysManager -Path $p -ExportFile ([System.IO.Path]::ChangeExtension($bk.Backup.backupPath, (Get-TcTreeItemExportExtension -Path $p)))
            if ($null -ne $z.Error) { $warnings.Add("the extra ExportChild .zip backup of '$p' was not made: $($z.Error)") } else { $zip = $z.ExportPath }
        }
        $objectBackups.Add([PSCustomObject]@{
                path = $p; produceXmlPath = $(if ($null -ne $bk -and $null -eq $bk.Result) { $bk.Backup.backupPath } else { $null })
                diskFile = $original; diskFileCopy = $copy; exportPath = $zip; childrenNotInXml = $gap
            })
        if ($gap.Count -gt 0) {
            $diskOnly.Add([PSCustomObject]@{
                    path = $p; children = $gap; diskFile = $original; diskFileCopy = $copy; exportPath = $zip
                    how = "after the XML restore, copy '$copy' over '$original' and run Reset-TcSolution (not measured)$(if ($zip) { "; or Import-TcTreeItem of '$zip' (not measured)" } else { '' })"
                })
        }
    }
    $restore = "Import-TcPlcOpen -FilePath '$($xml.Replace("'", "''"))' -Option Replace -DryRun `$false"
    $note = "restore the replaced objects: $restore"
    if ($diskOnly.Count -gt 0) {
        $note += '. NOT in the XML (properties of an interface without Get / Set are not exported, measured 2026-10-31), only in the disk file copy / .zip: ' +
            (($diskOnly | ForEach-Object { "'$($_.path)': $($_.children -join ', ') -> $($_.how)" }) -join '; ')
    }
    return @{ Result = $null; Backup = [PSCustomObject]@{ xmlPath = $xml; objects = @($Paths); restore = $restore; restoreNote = $note
            diskOnly = $diskOnly.ToArray(); objectBackups = $objectBackups.ToArray(); warnings = $warnings.ToArray() } }
}
