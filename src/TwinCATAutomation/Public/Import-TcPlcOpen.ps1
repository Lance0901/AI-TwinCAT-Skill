function Import-TcPlcOpen {
    <#
    .SYNOPSIS
        Imports a PLCopen XML file into the PLC project (PlcOpenImport on '<Plc> Project'). Dry-run by default: lists the objects of the file, the conflicts with the project and what -Option will do with them.
    .DESCRIPTION
        API: ITcPlcOpenImportExport.PlcOpenImport(bstrFile, options, bstrSelection, bSubTree), called
        as PlcOpenImport(<file>, <option>, '', $true) on the '<Plc> Project' node (TE1000 Automation
        Interface manual v1.7.0, 5.20 p.105-108; PLCIMPORTOPTIONS 5.46.7 p.161: NONE 0, REPLACE 1,
        RENAME 2, SKIP 3; bSubTree = true keeps the folder structure of the file).
        Behaviour of -Option, measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client
        (openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.3; a file
        exported from the same project imported back):
          None     a conflict throws ("Creation of object 'X' failed. Reason: Import conflict!" per
                   object) and nothing is imported (no partial import).
          Skip     conflicting objects are skipped silently; XAE does not say which.
          Replace  the whole object is replaced: children the file does not have are DELETED (an
                   interface lost its two properties because the file had only its method).
          Rename   the imported object gets '_1' appended (FB_X -> FB_X_1), the old one stays.
        XAE writes the object files (.TcPOU / .TcIO ...) to disk at once; the .plcproj only when the
        project is saved (same probe; GenerateBootProject saved it later, phase2-probe.md 3.2).
        No dialog appeared in the probe.
        Steps:
          1. FilePath absolute and existing (PLCOPEN_FAILED reason not-absolute / invalid-path /
             file-missing); the file is parsed with Read-TcXmlFile (no DTD: no XXE); not PLCopen
             XML or no object -> PLCOPEN_FAILED reason invalid-file / no-objects. data.objects:
             name, kind (POU / DUT / ITF / GVL), pouType, folder, members.
          2. The top-level objects of the PLC project are indexed (one walk over the project and
             its folders, Get-TcPlcProjectObjectIndex) and compared by name (case-insensitive,
             project-wide; whether XAE also reports a conflict for the same name in another folder
             is not measured). data.conflicts: name, kind, existingPath, existingItemType.
             data.indexComplete = $false (more than 3000 nodes, or a node that could not be
             read) is listed in data.warnings; with -Option Replace a real run is then refused
             (PLCOPEN_BACKUP_FAILED reason index-incomplete, PlcOpenImport not called), because the
             objects to back up may not all be known.
          3. Preview per option: None with a conflict -> PLCOPEN_CONFLICT (also in dry-run; real
             run: XAE is not called). Skip -> data.willSkip. Rename -> data.willRename
             (expectedName '<name>_1'; nameTaken when that name exists in the project or in the
             same file, the actual name is then not known: not measured). Replace -> data.willReplace with deletedChildren = children
             of the existing object that the file does not list (direct children only, names
             compared case-insensitively) and data.replaceWarning.
        DryRun (default true): stops after step 3; nothing is written.
        DryRun = false:
          - Replace: the objects that will be replaced are backed up first
            (Invoke-TcPlcOpenReplaceBackup). Required: one PlcOpenExport XML of all of them in
            <solution dir>\.tcauto-backup\<time>\plcopen-replace.xml; PlcOpenExport includes the
            subtree (measured 2026-10-31, phase2-probe.md 3.3) EXCEPT the properties of an
            INTERFACE that have no Get / Set (not exported, same probe), so
            Import-TcPlcOpen -FilePath <data.backup.xmlPath> -Option Replace -DryRun $false
            (data.backup.restore) restores what the XML holds. Not written, not readable or an
            object missing -> PLCOPEN_BACKUP_FAILED and PlcOpenImport is not called.
            An object whose children are not all in the XML (data.backup.diskOnly) needs its
            ProduceXml + disk file backup (.TcIO / .TcPOU ...); missing -> PLCOPEN_BACKUP_FAILED
            reason disk-backup-failed. Those children are restored by copying the disk file copy
            back and running Reset-TcSolution (not measured; data.backup.restoreNote says how).
            Best effort: the ProduceXml / disk file backup of the other objects and an
            ExportChild .zip per object (ExportChild of a POU node is not measured;
            data.backup.objectBackups); a failure there is only a warning.
          - Skip / Replace: the disk file of each conflicting object is hashed before and after.
            Skip: a changed file (data.skipped[].unchanged = $false) -> PLCOPEN_VERIFY_FAILED
            reason skip-changed. Replace: data.replaced[].diskFileChanged; an unchanged file is a
            warning (the object may not have been replaced).
          - IDE_MODAL_DIALOG when a dialog is open; then PlcOpenImport. An exception whose message
            names "Reason: Import conflict!" (XAE text, measured) -> PLCOPEN_CONFLICT
            (data.xaeConflicts); any other -> PLCOPEN_FAILED reason import-failed (data.xaeMessage,
            data.hresult).
          - Readback (index again): every object of the file must exist; for Rename the new name of
            each conflicting object is the one object '<name>_<n>' that was not there before
            (data.renamed); Replace reports the children that are really gone
            (data.replaced[].deletedChildren). Missing -> PLCOPEN_VERIFY_FAILED (data.missing).
            data.added = objects that were not there before; one of them with the name of a
            conflicting object (another folder, not the '<name>_<n>' of Rename) is listed in
            data.conflictsAdded with a warning.
          - Save: XAE writes the object files at once but the .plcproj only when the project is
            saved (measured, phase2-probe.md 3.3), so the project file is saved as Add-TcPou does
            (Invoke-TcPlcObjectSave: DTE Project.Save of the .tsproj, then the .plcproj read back
            from disk must list a <Compile Include> for every added object; data.projectSaved).
            A failed save returns its own code (PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT /
            IDE_MODAL_DIALOG; data.projectSave) and BUILD_REQUIRED stays recorded.
        BUILD_REQUIRED: recorded (code-changed) as soon as PlcOpenImport was called, also when it
        failed; a request refused before (checks, backup, dialog) records nothing.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER FilePath
        Absolute path of the PLCopen XML file to import (e.g. written by Export-TcPlcOpen).
    .PARAMETER Option
        What happens with an object that already exists: None (default; a conflict fails, nothing
        is imported), Replace (the existing object is replaced, children the file lacks are deleted;
        backed up first), Rename (the imported object gets '_1'), Skip (the existing object is kept).
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER DryRun
        Default true: only parse, compare and report. false: back up (Replace), import, read back.
    .EXAMPLE
        Import-TcPlcOpen -FilePath 'C:\Temp\motor.xml'
    .EXAMPLE
        Import-TcPlcOpen -FilePath 'C:\Temp\motor.xml' -Option Rename -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [ValidateSet('None', 'Replace', 'Rename', 'Skip')]
        [string]$Option = 'None',

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $opt = [string]@($script:TcPlcOpenImportOptions.Keys | Where-Object { $_ -ieq $Option })[0]
    $optValue = [int]$script:TcPlcOpenImportOptions[$opt]
    $data = [PSCustomObject]@{ filePath = $FilePath; option = $opt; optionValue = $optValue; dryRun = $DryRun }
    $warnings = [System.Collections.Generic.List[string]]::new()
    $failData = {
        param([string]$Code, [string]$Reason, [string]$Message)
        if (-not [string]::IsNullOrEmpty($Reason)) { $data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force }
        if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force }
        New-TcResult -Success $false -ErrorCode $Code -Data $data -ErrorMessage $Message -Hint (Get-TcErrorHint -Code $Code)
    }

    $bad = $null
    try {
        $bad = Test-TcTreeItemFilePath -FilePath $FilePath
        if ($null -eq $bad -and -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { $bad = @{ Reason = 'file-missing'; Message = "'$FilePath' does not exist" } }
    }
    catch { $bad = @{ Reason = 'invalid-path'; Message = "-FilePath '$FilePath' cannot be checked: $($_.Exception.Message)" } }
    if ($null -ne $bad) { return (& $failData 'PLCOPEN_FAILED' $bad.Reason "$($bad.Message); nothing was imported.") }
    $parsed = $null
    try { $parsed = Read-TcPlcOpenFile -Path $FilePath }
    catch { return (& $failData 'PLCOPEN_FAILED' 'invalid-file' "'$FilePath' cannot be read as PLCopen XML: $($_.Exception.Message); nothing was imported.") }
    $objects = @($parsed.Objects)
    $data | Add-Member -NotePropertyName objects -NotePropertyValue $objects
    if ($objects.Count -eq 0) { return (& $failData 'PLCOPEN_FAILED' 'no-objects' "'$FilePath' holds no POU, DUT, GVL or interface; nothing was imported.") }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED_IDE')
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = "Import-TcPlcOpen $([System.IO.Path]::GetFileName($FilePath)) [$opt]"
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $data | Add-Member -NotePropertyName plcProjectPath -NotePropertyValue $prjPath
        $r = Resolve-TcTreeItem -SysManager $sm -Path $prjPath -Data $data -ParameterName 'PlcProjectPath'
        if ($null -ne $r.Result) { return $r.Result }
        $prj = $r.Item

        # 2. conflicts
        $before = Get-TcPlcProjectObjectIndex -SysManager $sm -ProjectPath $prjPath
        $data | Add-Member -NotePropertyName indexComplete -NotePropertyValue ([bool]$before.Complete)
        if (-not $before.Complete) {
            $warnings.Add("the conflict check is incomplete: $($before.Note)")
            if ($opt -eq 'Replace') { $warnings.Add('-Option Replace with DryRun $false is refused while the object index is incomplete (PLCOPEN_BACKUP_FAILED reason index-incomplete): objects to back up may be missing') }
        }
        $byName = @{}
        foreach ($o in @($before.Objects)) { $k = $o.name.ToUpperInvariant(); if (-not $byName.ContainsKey($k)) { $byName[$k] = $o } }
        $conflicts = [System.Collections.Generic.List[object]]::new()
        $free = [System.Collections.Generic.List[string]]::new()
        foreach ($o in $objects) {
            $hit = $byName[$o.name.ToUpperInvariant()]
            if ($null -ne $hit) { $conflicts.Add([PSCustomObject]@{ name = $o.name; kind = $o.kind; existingPath = $hit.path; existingItemType = $hit.itemType }) }
            else { $free.Add($o.name) }
        }
        $data | Add-Member -NotePropertyName conflicts -NotePropertyValue $conflicts.ToArray()
        $data | Add-Member -NotePropertyName willImport -NotePropertyValue $free.ToArray()

        # 3. preview
        if ($opt -eq 'None' -and $conflicts.Count -gt 0) {
            return (& $failData 'PLCOPEN_CONFLICT' 'conflict' "$($conflicts.Count) object(s) of '$FilePath' already exist in '$prjPath': $(($conflicts | ForEach-Object { "'$($_.name)' ($($_.existingPath))" }) -join ', '); with -Option None XAE would refuse the whole file (measured 2026-10-31), so PlcOpenImport was not called and nothing was imported.")
        }
        $willReplace = @()
        if ($opt -eq 'Skip') { $data | Add-Member -NotePropertyName willSkip -NotePropertyValue @($conflicts | ForEach-Object { $_.name }) }
        elseif ($opt -eq 'Rename') {
            $data | Add-Member -NotePropertyName willRename -NotePropertyValue @($conflicts | ForEach-Object {
                    $exp = "$($_.name)_1"
                    $e = $exp
                    $taken = $byName.ContainsKey($exp.ToUpperInvariant()) -or @($objects | Where-Object { $_.name -ieq $e }).Count -gt 0
                    if ($taken) { $warnings.Add("'$exp' already exists too: the name XAE gives the imported '$($_.name)' is not known (only '_1' was measured)") }
                    [PSCustomObject]@{ name = $_.name; existingPath = $_.existingPath; expectedName = $exp; nameTaken = $taken }
                })
        }
        elseif ($opt -eq 'Replace') {
            $willReplace = @($conflicts | ForEach-Object {
                    $c = $_
                    $fileObj = @($objects | Where-Object { $_.name -ieq $c.name })[0]
                    $fileMembers = @($fileObj.members | ForEach-Object { $_.name })
                    $item = Find-TcTreeItemNoThrow -SysManager $sm -Path $c.existingPath
                    $kids = if ($null -ne $item) { @(Get-TcTreeItemChildList -Item $item) } else { @() }
                    $gone = @($kids | Where-Object { $n = $_.name; @($fileMembers | Where-Object { $_ -ieq $n }).Count -eq 0 } | ForEach-Object { $_.name })
                    [PSCustomObject]@{ name = $c.name; existingPath = $c.existingPath; existingChildren = @($kids | ForEach-Object { $_.name }); fileMembers = $fileMembers; deletedChildren = $gone }
                })
            $data | Add-Member -NotePropertyName willReplace -NotePropertyValue $willReplace
            if ($willReplace.Count -gt 0) {
                $data | Add-Member -NotePropertyName replaceWarning -NotePropertyValue ('Replace overwrites each object as a whole: children the file does not have are deleted (measured 2026-10-31: an interface lost its properties). Deleted here: ' +
                    (($willReplace | ForEach-Object { "'$($_.name)': " + $(if (@($_.deletedChildren).Count -gt 0) { (@($_.deletedChildren) -join ', ') } else { '(none)' }) }) -join '; '))
            }
        }
        $planned = [System.Collections.Generic.List[string]]::new()
        if ($opt -eq 'Replace' -and $willReplace.Count -gt 0) {
            $planned.Add("PlcOpenExport XML backup (required) of $(($willReplace | ForEach-Object { "'$($_.existingPath)'" }) -join ', ')")
            $planned.Add('ProduceXml + disk file backup (required for an object with children the XML lacks) and ExportChild .zip (best effort)')
        }
        $planned.Add("PlcOpenImport '$FilePath' option $opt ($optValue), bSubTree true")
        $planned.Add('readback (object index)')
        $planned.Add('save the project and read the .plcproj back')
        $data | Add-Member -NotePropertyName plannedSteps -NotePropertyValue $planned.ToArray()
        if ($DryRun) {
            if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force }
            return New-TcResult -Success $true -Data $data
        }

        # backup (Replace) / fingerprints (Skip, Replace)
        if ($willReplace.Count -gt 0 -and -not $before.Complete) {
            return (& $failData 'PLCOPEN_BACKUP_FAILED' 'index-incomplete' "the object index of '$prjPath' is incomplete ($($before.Note)), so not every object -Option Replace overwrites is known for the backup; PlcOpenImport was not called, nothing was imported.")
        }
        if ($willReplace.Count -gt 0) {
            $bk = Invoke-TcPlcOpenReplaceBackup -SysManager $sm -Project $prj -ProjectPath $prjPath -Paths @($willReplace | ForEach-Object { [string]$_.existingPath }) -Data $data
            if ($null -ne $bk.Result) { return $bk.Result }
            $data | Add-Member -NotePropertyName backup -NotePropertyValue $bk.Backup
            foreach ($x in @($bk.Backup.warnings)) { $warnings.Add($x) }
        }
        $solutionDir = Get-TcTreeItemSolutionDir
        $fingerprint = {
            param($c)
            if ($null -eq $solutionDir) { return @{ File = $null; Hash = $null } }
            $d = Find-TcTreeItemDiskFile -SolutionDir $solutionDir -Path $c.existingPath -Name (Get-TcTreePathLeaf -Path $c.existingPath) -ItemType $c.existingItemType
            $f = @($d.Files)[0]
            @{ File = $f; Hash = (Get-TcFileSha256 -Path $f) }
        }
        $skipBefore = @{}
        if ($opt -eq 'Skip' -or $opt -eq 'Replace') { foreach ($c in $conflicts) { $skipBefore[$c.name] = & $fingerprint $c } }

        $dlg = Get-TcTreeItemDialogResult -Operation "PlcOpenImport '$FilePath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        $called = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline (CODING_STANDARDS.md section 1): a dialog was ruled out just above,
            # Connect-TcIde turns on ITcAutomationSettings.SilentMode, and PlcOpenImport returned in
            # 6-242 ms without a dialog in every probe call (measured 2026-10-31 4026 VS2022, self-built
            # client). The MCP tool timeout bounds it from outside.
            Invoke-TcComRetry -OperationName 'PlcOpenImport' -ScriptBlock { $prj.PlcOpenImport($FilePath, $optValue, '', $true) } | Out-Null
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $info = Get-TcComErrorInfo -ErrorRecord $_
            $data | Add-Member -NotePropertyName xaeMessage -NotePropertyValue $info.message
            $data | Add-Member -NotePropertyName hresult -NotePropertyValue $info.hresultHex
            # XAE's own English text (measured 2026-10-31): "Creation of object 'X' failed. Reason: Import conflict!"
            $xc = @([regex]::Matches([string]$info.message, "Creation of object '([^']+)' failed\. Reason: Import conflict!") | ForEach-Object { $_.Groups[1].Value })
            $res = if ($xc.Count -gt 0) {
                $data | Add-Member -NotePropertyName xaeConflicts -NotePropertyValue $xc
                & $failData 'PLCOPEN_CONFLICT' 'xae-conflict' "PlcOpenImport refused '$FilePath' with an import conflict for $(($xc | ForEach-Object { "'$_'" }) -join ', '): $($info.message)"
            }
            else { & $failData 'PLCOPEN_FAILED' 'import-failed' "PlcOpenImport '$FilePath' (option $opt) failed: $($info.message)" }
            return (Register-TcCodeChange -Result $res -Change "$change [failed]")
        }
        $sw.Stop()
        $data | Add-Member -NotePropertyName importSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))

        # readback
        $after = Get-TcPlcProjectObjectIndex -SysManager $sm -ProjectPath $prjPath
        if (-not $after.Complete) { $warnings.Add("the readback is incomplete: $($after.Note)") }
        $beforePaths = @{}
        foreach ($o in @($before.Objects)) { $beforePaths[$o.path.ToUpperInvariant()] = $true }
        $added = @($after.Objects | Where-Object { -not $beforePaths.ContainsKey($_.path.ToUpperInvariant()) })
        $data | Add-Member -NotePropertyName added -NotePropertyValue @($added | ForEach-Object { [PSCustomObject]@{ name = $_.name; path = $_.path; itemType = $_.itemType } })
        $conflictsAdded = @($added | Where-Object { $n = $_.name; @($conflicts | Where-Object { $_.name -ieq $n }).Count -gt 0 })
        if ($conflictsAdded.Count -gt 0) {
            $data | Add-Member -NotePropertyName conflictsAdded -NotePropertyValue @($conflictsAdded | ForEach-Object { [PSCustomObject]@{ name = $_.name; path = $_.path; itemType = $_.itemType } })
            $warnings.Add("the import added object(s) with the name of a conflicting object: $(($conflictsAdded | ForEach-Object { "'$($_.path)'" }) -join ', '); the project may now hold the name twice")
        }
        $afterNames = @($after.Objects | ForEach-Object { $_.name })
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($o in $objects) { if (@($afterNames | Where-Object { $_ -ieq $o.name }).Count -eq 0) { $missing.Add($o.name) } }
        $skipChanged = [System.Collections.Generic.List[string]]::new()
        if ($opt -eq 'Rename') {
            $renamed = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $conflicts) {
                $pat = '^' + [regex]::Escape($c.name) + '_\d+$'
                $cand = @($added | Where-Object { $_.name -imatch $pat })
                if ($cand.Count -eq 1) { $renamed.Add([PSCustomObject]@{ name = $c.name; newName = $cand[0].name; path = $cand[0].path }) }
                else {
                    $missing.Add("$($c.name) (renamed copy)")
                    if ($cand.Count -gt 1) { $warnings.Add("several new objects could be the renamed '$($c.name)': $(($cand | ForEach-Object { $_.name }) -join ', ')") }
                }
            }
            $data | Add-Member -NotePropertyName renamed -NotePropertyValue $renamed.ToArray()
        }
        elseif ($opt -eq 'Skip') {
            $data | Add-Member -NotePropertyName skipped -NotePropertyValue @($conflicts | ForEach-Object {
                    $b = $skipBefore[$_.name]
                    $hashAfter = Get-TcFileSha256 -Path $b.File
                    $unchanged = if ($null -eq $b.Hash -or $null -eq $hashAfter) { $null } else { $b.Hash -eq $hashAfter }
                    if ($unchanged -eq $false) { $skipChanged.Add($_.name) }
                    [PSCustomObject]@{ name = $_.name; path = $_.existingPath; diskFile = $b.File; unchanged = $unchanged }
                })
        }
        elseif ($opt -eq 'Replace') {
            $data | Add-Member -NotePropertyName replaced -NotePropertyValue @($willReplace | ForEach-Object {
                    $item = Find-TcTreeItemNoThrow -SysManager $sm -Path $_.existingPath
                    $kidsAfter = if ($null -ne $item) { @(Get-TcTreeItemChildNames -Item $item) } else { @() }
                    $gone = @(@($_.existingChildren) | Where-Object { $n = $_; @($kidsAfter | Where-Object { $_ -ieq $n }).Count -eq 0 })
                    $b = $skipBefore[$_.name]
                    $hashAfter = Get-TcFileSha256 -Path $b.File
                    $changed = if ($null -eq $b.Hash -or $null -eq $hashAfter) { $null } else { $b.Hash -ne $hashAfter }
                    if ($changed -eq $false) { $warnings.Add("the disk file of replaced '$($_.name)' ($($b.File)) did not change during the import: it may not have been replaced") }
                    [PSCustomObject]@{ name = $_.name; path = $_.existingPath; childrenAfter = $kidsAfter; deletedChildren = $gone; diskFile = $b.File; diskFileChanged = $changed }
                })
        }
        if ($skipChanged.Count -gt 0) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = & $failData 'PLCOPEN_VERIFY_FAILED' 'skip-changed' "-Option Skip, but the disk file of $(($skipChanged | ForEach-Object { "'$_'" }) -join ', ') changed during the import (data.skipped): the object was not left alone."
            return (Register-TcCodeChange -Result $res -Change "$change [verify failed]")
        }
        if ($missing.Count -gt 0) {
            $data | Add-Member -NotePropertyName missing -NotePropertyValue $missing.ToArray()
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = & $failData 'PLCOPEN_VERIFY_FAILED' 'missing' "PlcOpenImport returned, but $(($missing | ForEach-Object { "'$_'" }) -join ', ') is not found in '$prjPath' afterwards."
            return (Register-TcCodeChange -Result $res -Change "$change [verify failed]")
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true

        # save: the .plcproj lists the new objects only after the project is saved (measured)
        $expect = @($added | ForEach-Object {
                $ext = Get-TcPlcObjectFileExtension -ItemType ([int]$_.itemType)
                if ($null -ne $ext) { Get-TcPlcObjectRelativeFile -TreePath $_.path -Extension $ext }
            })
        $data | Add-Member -NotePropertyName expectedProjectFiles -NotePropertyValue $expect
        $save = Invoke-TcPlcObjectSave -ObjectPath $prjPath -ExpectFiles $expect -What "PLCopen import of '$([System.IO.Path]::GetFileName($FilePath))'" -Done 'imported'
        if ($null -ne $save.Error) {
            $data | Add-Member -NotePropertyName projectSave -NotePropertyValue $save.Error.data -Force
            if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force }
            $res = New-TcResult -Success $false -ErrorCode ([string]$save.Error.error.code) -ErrorMessage ([string]$save.Error.error.message) -Hint ([string]$save.Error.error.hint) -Data $data
            return (Register-TcCodeChange -Result $res -Change "$change [project not saved]")
        }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        if (-not [string]::IsNullOrWhiteSpace([string]$save.Saved.warning)) { $warnings.Add([string]$save.Saved.warning) }
        if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force }
        return (Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change)
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'PLCOPEN_FAILED' -Data $data -Operation 'Import-TcPlcOpen'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
        return $res
    }
}
