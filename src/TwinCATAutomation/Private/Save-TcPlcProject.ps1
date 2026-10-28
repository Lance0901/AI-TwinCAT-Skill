function Get-TcPlcNameFromPath {
    <#
    .SYNOPSIS
        PLC name of a tree path: 'TIPC^<Plc>^...' -> '<Plc>' ($null when the path is not below TIPC).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreePath)
    $seg = $TreePath -split '\^'
    if ($seg.Count -ge 2 -and $seg[0] -ieq 'TIPC' -and -not [string]::IsNullOrWhiteSpace($seg[1])) { return $seg[1] }
    $null
}

function Get-TcPlcObjectFileExtension {
    <#
    .SYNOPSIS
        File extension XAE stores a top-level PLC object in, by ItemType ($null for other types).
    .DESCRIPTION
        602-604 POU -> .TcPOU, 605-607 / 623 DUT -> .TcDUT, 615 GVL -> .TcGVL, 618 ITF -> .TcIO.
        ItemType values: InfoSys "ITcSmTreeItem Item Types"
        (https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html); the
        extensions are the file names XAE writes into <Compile Include> (measured 2026-10-28,
        4026 VisualStudio.DTE.17.0 and 4024 TcXaeShell.DTE.15.0).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ItemType)
    switch ($ItemType) {
        { $_ -in 602, 603, 604 } { return '.TcPOU' }
        { $_ -in 605, 606, 607, 623 } { return '.TcDUT' }
        615 { return '.TcGVL' }
        618 { return '.TcIO' }
    }
    $null
}

function Get-TcPlcProjectFile {
    <#
    .SYNOPSIS
        Finds the DTE project (.tsproj) that holds PLC -PlcName and the .plcproj file of that PLC.
    .DESCRIPTION
        Walks DTE Solution.Projects for projects whose FullName ends in .tsproj and reads each
        such file from disk: the PLC is the <Project Name="<Plc>" PrjFilePath="<rel>.plcproj">
        element (present in the .tsproj of 4024 and 4026, measured 2026-10-28), the path is
        relative to the .tsproj folder. Throws "save: ..." when nothing matches.
        Returns @{ DteProject; TsProjFile; PlcProjFile; UniqueName }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlcName)

    $dte = $script:TcDte
    $projects = Invoke-TcComRetry -OperationName 'Solution.Projects (.tsproj)' -ScriptBlock {
        $__list = [System.Collections.Generic.List[object]]::new()
        $__all = $dte.Solution.Projects
        for ($__i = 1; $__i -le [int]$__all.Count; $__i++) {
            $__p = $__all.Item($__i)
            $__full = $null
            try { $__full = [string]$__p.FullName } catch {
                if ($_.Exception.ToString() -match '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER') { throw }
                $__full = $null
            }
            if (-not [string]::IsNullOrWhiteSpace($__full) -and $__full -match '(?i)\.tsproj$') {
                $__uniq = $null; try { $__uniq = [string]$__p.UniqueName } catch { $__uniq = $null }
                $__list.Add(@{ Project = $__p; FullName = $__full; UniqueName = $__uniq })
            }
        }
        Write-Output -NoEnumerate $__list.ToArray()
    }
    foreach ($p in @($projects)) {
        if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
        $xml = New-Object System.Xml.XmlDocument
        try { $xml.Load($p.FullName) } catch { continue }
        foreach ($node in @($xml.SelectNodes('//Project[@PrjFilePath]'))) {
            if ([string]$node.GetAttribute('Name') -ine $PlcName) { continue }
            $rel = [string]$node.GetAttribute('PrjFilePath')
            if ($rel -notmatch '(?i)\.plcproj$') { continue }
            $plcproj = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($p.FullName)) $rel))
            return @{ DteProject = $p.Project; TsProjFile = $p.FullName; PlcProjFile = $plcproj; UniqueName = $p.UniqueName }
        }
    }
    throw "save: no .tsproj of the open solution lists PLC '$PlcName' with a .plcproj (<Project Name=""$PlcName"" PrjFilePath=...>); the project file could not be located."
}

function Get-TcPlcProjectContent {
    <#
    .SYNOPSIS
        Reads a .plcproj from disk: Compile Include paths and library references.
    .DESCRIPTION
        Returns @{ Compile = [string[]] Include values; CompileLeaf = HashSet of file names
        (case-insensitive); Libraries = HashSet of PlaceholderReference / LibraryReference
        Include values, Namespace and the library name of DefaultResolution / Resolution
        ('Tc2_Standard, * (Beckhoff Automation GmbH)' -> 'Tc2_Standard') }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Path)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('m', [string]$xml.DocumentElement.NamespaceURI)
    $pre = if ([string]::IsNullOrEmpty([string]$xml.DocumentElement.NamespaceURI)) { '' } else { 'm:' }
    $compile = [System.Collections.Generic.List[string]]::new()
    $leaf = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($xml.SelectNodes("//${pre}Compile[@Include]", $ns))) {
        $inc = [string]$n.GetAttribute('Include')
        $compile.Add($inc)
        $null = $leaf.Add([IO.Path]::GetFileName($inc))
    }
    $libs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($xml.SelectNodes("//${pre}PlaceholderReference | //${pre}LibraryReference", $ns))) {
        $inc = [string]$n.GetAttribute('Include')
        if (-not [string]::IsNullOrWhiteSpace($inc)) { $null = $libs.Add($inc.Split(',')[0].Trim()) }
        foreach ($child in @($n.ChildNodes)) {
            if ($child.LocalName -in 'Namespace', 'DefaultResolution', 'Resolution') {
                $v = ([string]$child.InnerText).Split(',')[0].Trim()
                if (-not [string]::IsNullOrWhiteSpace($v)) { $null = $libs.Add($v) }
            }
        }
    }
    @{ Compile = [string[]]$compile.ToArray(); CompileLeaf = $leaf; Libraries = $libs }
}

function Save-TcPlcProject {
    <#
    .SYNOPSIS
        Saves only the project files (.tsproj + its .plcproj) of PLC -PlcName and reads
        the .plcproj back from disk (#76).
    .DESCRIPTION
        Objects created through the Automation Interface (CreateChild) are written to their
        own .TcPOU / .TcDUT / .TcGVL at once, but the .plcproj (<Compile Include>) only lives in XAE
        memory until the project is saved: Reset-TcSolution (Solution.Close without saving) then
        drops them (measured 2026-10-28, 4026 VisualStudio.DTE.17.0, issue #76).
        Save call: DTE Project.Save() on the .tsproj project, the call the InfoSys Automation
        Interface sample uses to persist a project ("Accessing TwinCAT configuration",
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html).
        Measured 2026-10-28 (4026 VisualStudio.DTE.17.0, C:\Temp\Verify-repro-axis): it writes
        the .tsproj and the nested .plcproj (with the new <Compile Include>) in ~0.2 s and leaves a
        dirty editor document (a text file open in the IDE) unsaved; DTE File.SaveAll also saved
        that document; ITcSysManager.SaveConfiguration throws "SaveConfiguration only supported
        in Automation Legacy Mode! Please use standard DTE.Solution features for Project
        persistance instead!". Whether it also writes an unsaved PLC editor buffer was not
        measured (no way to make one dirty without the GUI).
        No deadline: Project.Save is synchronous and returned within 0.3 s in every measurement;
        a modal dialog (the case that would block it) is checked right before the call.
        Steps (each failure throws a message starting with 'save:'):
          1. dialog   Get-TcIdeModalDialog: returns @{ ModalDialog = <dialog> } without saving
          2. locate   Get-TcPlcProjectFile
          3. save     Invoke-TcComRetry { Project.Save() }
          4. verify   the .plcproj read back from disk lists every -ExpectFile (file name of a
                      <Compile Include>) and every -ExpectLibrary (Get-TcPlcProjectContent)
        Returns @{ plc; tsproj; plcproj; dteProject; savedFiles; verifiedFiles; verifiedLibraries;
        saveSec } (or @{ ModalDialog }).
    .PARAMETER PlcName
        PLC name (TIPC^<Plc>).
    .PARAMETER ExpectFile
        File names that must appear as <Compile Include> after the save (e.g. FB_Motor.TcPOU).
    .PARAMETER ExpectLibrary
        Library names that must appear as a library reference after the save.
    .PARAMETER TimeoutSec
        Invoke-TcComRetry -TimeoutSec of the save call. Default 60.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlcName,

        [Parameter()]
        [string[]]$ExpectFile = @(),

        [Parameter()]
        [string[]]$ExpectLibrary = @(),

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 60
    )

    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) { return @{ ModalDialog = $dialog } }

    $info = Get-TcPlcProjectFile -PlcName $PlcName
    $proj = $info.DteProject
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName "Project.Save $([IO.Path]::GetFileName($info.TsProjFile))" -TimeoutSec $TimeoutSec -ScriptBlock { $proj.Save() } | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
        throw "save: Project.Save of '$($info.TsProjFile)' failed ($($_.Exception.Message))."
    }
    $saveSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)

    if (-not (Test-Path -LiteralPath $info.PlcProjFile)) { throw "save: Project.Save returned but '$($info.PlcProjFile)' does not exist." }
    $content = $null
    try { $content = Get-TcPlcProjectContent -Path $info.PlcProjFile }
    catch { throw "save: Project.Save returned but '$($info.PlcProjFile)' could not be read back ($($_.Exception.Message))." }
    $missing = @($ExpectFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $content.CompileLeaf.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "save: Project.Save returned but '$($info.PlcProjFile)' read back from disk has no <Compile Include> for $($missing -join ', ')."
    }
    $missingLib = @($ExpectLibrary | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $content.Libraries.Contains($_) })
    if ($missingLib.Count -gt 0) {
        throw "save: Project.Save returned but '$($info.PlcProjFile)' read back from disk has no library reference for $($missingLib -join ', ')."
    }
    [ordered]@{
        plc               = $PlcName
        tsproj            = $info.TsProjFile
        plcproj           = $info.PlcProjFile
        dteProject        = $info.UniqueName
        savedFiles        = @($info.TsProjFile, $info.PlcProjFile)
        verifiedFiles     = @($ExpectFile)
        verifiedLibraries = @($ExpectLibrary)
        saveSec           = $saveSec
    }
}

function Get-TcUnsavedPlcObject {
    <#
    .SYNOPSIS
        Compares the PLC objects in XAE memory with the .plcproj on disk, per PLC project (#76).
    .DESCRIPTION
        DTE Project.Saved / IsDirty and Solution.Saved / IsDirty all stay True / False after a
        CreateChild that XAE has not saved (measured 2026-10-28, 4026 VisualStudio.DTE.17.0), so
        they cannot tell whether a project is dirty. Instead, for every PLC (Get-TcPlcProjectList)
        the tree below TIPC^<Plc>^<Plc> Project is walked like Find-TcPlcNameConflict (PLC
        folders, ItemType 601, are entered; POU children such as methods are not) and every
        top-level object (Get-TcPlcObjectFileExtension) gives an expected file name
        <Name><ext>. The .plcproj on disk (Get-TcPlcProjectContent) is compared with that list:
          MissingOnDisk  objects in XAE memory without a <Compile Include>: unsaved structure
          ExtraOnDisk    <Compile Include> .TcPOU/.TcDUT/.TcGVL/.TcIO files whose name (without
                         extension) is no node name of the walk, of any ItemType: the .plcproj on disk was changed by someone else (only meaningful
                         when Complete is true)
          Complete       the walk saw every node (no node skipped, not over -MaxNodes)
        Only object structure is compared: unsaved library references, tasks or I/O settings
        are not detected (known limit).
        IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT and file errors are thrown.
        Returns @{ Plcs = [ordered[]] @{ plc; projectPath; plcproj; tsproj; dteProject;
        missingOnDisk; extraOnDisk; complete; visited; skipped }; Visited; Sec }.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER MaxNodes
        Node limit per PLC project (default 5000).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter()]
        [int]$MaxNodes = 5000
    )

    $sm = $SysManager
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $retryPattern = '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER|IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $result = [System.Collections.Generic.List[object]]::new()
    $total = 0
    foreach ($plc in @(Get-TcPlcProjectList -SysManager $sm)) {
        $projPath = [string]$plc.projectPath
        $walk = Invoke-TcComRetry -OperationName "Object list below $projPath" -ScriptBlock {
            $__objs = [System.Collections.Generic.List[object]]::new()
            $__names = [System.Collections.Generic.List[string]]::new()
            $__visited = 0; $__skipped = 0; $__over = $false
            $__queue = New-Object System.Collections.Queue
            $__queue.Enqueue($sm.LookupTreeItem($projPath))
            while ($__queue.Count -gt 0 -and -not $__over) {
                $__node = $__queue.Dequeue()
                $__cnt = 0
                try { $__cnt = [int]$__node.ChildCount }
                catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++; continue }
                for ($__j = 1; $__j -le $__cnt; $__j++) {
                    $__visited++
                    if ($__visited -gt $MaxNodes) { $__over = $true; break }
                    try {
                        $__c = $__node.Child($__j)
                        $__t = [int]$__c.ItemType
                        $__names.Add([string]$__c.Name)
                        if ($__t -eq 601) { $__queue.Enqueue($__c); continue }
                        $__ext = Get-TcPlcObjectFileExtension -ItemType $__t
                        if ($null -ne $__ext) { $__objs.Add(@{ Name = [string]$__c.Name; Path = [string]$__c.PathName; File = ([string]$__c.Name + $__ext) }) }
                    }
                    catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++ }
                }
            }
            @{ Objects = $__objs.ToArray(); Names = $__names.ToArray(); Visited = $__visited; Skipped = $__skipped; Over = $__over }
        }
        $total += [int]$walk.Visited
        $file = Get-TcPlcProjectFile -PlcName ([string]$plc.name)
        $content = Get-TcPlcProjectContent -Path $file.PlcProjFile
        $modelNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($n in @($walk.Names)) { $null = $modelNames.Add($n) }
        $missing = [System.Collections.Generic.List[object]]::new()
        foreach ($o in @($walk.Objects)) {
            if (-not $content.CompileLeaf.Contains($o.File)) { $missing.Add([PSCustomObject]@{ name = $o.Name; path = $o.Path; file = $o.File }) }
        }
        $extra = @($content.Compile | Where-Object { $_ -match '(?i)\.(TcPOU|TcDUT|TcGVL|TcIO)$' -and -not $modelNames.Contains([IO.Path]::GetFileNameWithoutExtension($_)) })
        $result.Add([ordered]@{
            plc           = [string]$plc.name
            projectPath   = $projPath
            plcproj       = $file.PlcProjFile
            tsproj        = $file.TsProjFile
            dteProject    = $file.UniqueName
            missingOnDisk = $missing.ToArray()
            extraOnDisk   = [string[]]$extra
            complete      = (-not $walk.Over -and [int]$walk.Skipped -eq 0)
            visited       = [int]$walk.Visited
            skipped       = [int]$walk.Skipped
        })
    }
    @{ Plcs = $result.ToArray(); Visited = $total; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Invoke-TcPlcObjectSave {
    <#
    .SYNOPSIS
        Add-TcPou / Add-TcDut / Add-TcGvl / Add-TcLibrary: saves the project file of the PLC that
        contains -ObjectPath and verifies the new entry on disk (#76).
    .DESCRIPTION
        Wraps Save-TcPlcProject. Returns @{ Saved = <Save-TcPlcProject result>; Error = $null } or
        @{ Saved = $null; Error = <failed New-TcResult> }: IDE_MODAL_DIALOG (a dialog was up, nothing
        saved), PROJECT_SAVE_FAILED (save or readback failed), or the IDE_* code of the COM call.
        Error data: objectPath, plc, createdInMemory = $true, savedToDisk = $false.
    .PARAMETER ObjectPath
        Tree path of the new object (TIPC^<Plc>^...), or of the References node for a library.
    .PARAMETER ExpectFile
        File name that must appear as <Compile Include> (e.g. FB_Motor.TcPOU).
    .PARAMETER ExpectLibrary
        Library name that must appear as a library reference.
    .PARAMETER What
        Short text for the messages, e.g. "POU 'FB_Motor'".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectPath,

        [Parameter()]
        [string]$ExpectFile,

        [Parameter()]
        [string]$ExpectLibrary,

        [Parameter(Mandatory)]
        [string]$What
    )

    $plc = Get-TcPlcNameFromPath -TreePath $ObjectPath
    $errData = [PSCustomObject]@{ objectPath = $ObjectPath; plc = $plc; createdInMemory = $true; savedToDisk = $false }
    $prefix = "$What was created in XAE ('$ObjectPath') but the project file (.plcproj) was not saved, so closing the solution without saving would drop it"
    if ($null -eq $plc) {
        return @{ Saved = $null; Error = (New-TcResult -Success $false -ErrorMessage "${prefix}: '$ObjectPath' is not below TIPC^<Plc>, the PLC project cannot be located." `
            -ErrorCode 'PROJECT_SAVE_FAILED' -Hint (Get-TcErrorHint -Code 'PROJECT_SAVE_FAILED') -Data $errData) }
    }
    $saveParams = @{ PlcName = $plc }
    if (-not [string]::IsNullOrWhiteSpace($ExpectFile)) { $saveParams['ExpectFile'] = @($ExpectFile) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectLibrary)) { $saveParams['ExpectLibrary'] = @($ExpectLibrary) }
    try {
        $saved = Save-TcPlcProject @saveParams
        if ($saved.Contains('ModalDialog')) {
            return @{ Saved = $null; Error = (New-TcModalDialogResult -Dialog $saved.ModalDialog -Operation "Project.Save after creating $What (created in XAE, project file NOT saved)" -Data $errData) }
        }
        return @{ Saved = [PSCustomObject]$saved; Error = $null }
    }
    catch {
        return @{ Saved = $null; Error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_SAVE_FAILED' -MessagePrefix $prefix -Data $errData) }
    }
}