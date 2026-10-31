function Remove-TcLibraryReference {
    <#
    .SYNOPSIS
        Removes a library reference or placeholder from the PLC project (ITcPlcLibraryManager.RemoveReference). Dry-run by default; backs up the .plcproj and reads back.
    .DESCRIPTION
        ITcPlcLibraryManager.RemoveReference(name) on the References node TIPC^<Plc>^<Plc>
        Project^References (TE1000 Automation Interface manual v1.7.0, 6.5.14 p.243 sample
        RemoveReference("Placeholder_NC"); 5.25.1 p.113-119). Measured 2026-10-31 4026 VS2022 XAE
        3.1.4026.18 (self-built client, openspec/changes/complete-automation-interface/verification/
        phase2-probe.md 3.1): a placeholder is removed with or without the leading '#'; not found ->
        COMException 0x98510001 "Specified library '...' not found!". The module passes '#<name>' for a
        placeholder (so a library of the same name can never be hit) and '<name>' for a library.
        Target: -Name '#<Name>' or -Kind Placeholder = the placeholder '#<Name>'; -Kind Library = the
        library reference '<Name>'; neither = whichever of the two exists.
        Checks before anything is changed: -Name not empty, '#' together with -Kind Library
        (LIBRARY_INVALID_ARGUMENT reason name / kind-conflict); the target must be in References
        (case-insensitive), else LIBRARY_NOT_FOUND with data.references. A library '<Name>' and a
        placeholder '#<Name>' at the same time: without '#' / -Kind -> LIBRARY_INVALID_ARGUMENT reason
        ambiguous (pass '#<Name>' for the placeholder); -Kind Library -> reason
        ambiguous-library-not-measured: which of the two XAE removes for RemoveReference('<Name>') then
        is not measured, so the module does not call it.
        DryRun (default true): RemoveReference is NOT called; data.dryRun, data.reference (the entry
        that would be removed), data.projectFile.
        DryRun=false: backup of the .plcproj on disk into <solution dir>\.tcauto-backup\<timestamp>\
        (data.backupPath, data.backupFiles; LIBRARY_BACKUP_FAILED = nothing removed), modal dialog check
        (IDE_MODAL_DIALOG), RemoveReference, then readback: References must no longer list it, the
        project file is saved (Invoke-TcPlcObjectSave) and the .plcproj read from disk must have no
        entry of the target's kind for it (placeholder: PlaceholderReference / PlaceholderResolution;
        library: LibraryReference). Otherwise
        LIBRARY_VERIFY_FAILED (data.step references / project-file). XAE refusing the call ->
        LIBRARY_REMOVE_FAILED (or LIBRARY_NOT_FOUND for "Specified library '...' not found!").
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Name
        Library or placeholder name, with or without the leading '#' (e.g. Tc2_Math or #Tc2_Math).
    .PARAMETER Kind
        Library or Placeholder: which reference -Name means. Optional; needed only when a library and a
        placeholder share the name (Placeholder; Library is refused then, see above).
    .PARAMETER DryRun
        Default true: only report what would be removed. false: back up, remove, read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: name, kind, dryRun, referencesPath, reference, removeArgument, projectFile, backupPath, backupFiles, warnings,
        verified, projectSaved.
    .NOTES
        BUILD_REQUIRED (#65): as soon as RemoveReference was called (success or any failure, also
        "not found" from XAE) the solution is recorded as code-changed (Register-TcCodeChange).
    .EXAMPLE
        Remove-TcLibraryReference -Name Tc2_Math
    .EXAMPLE
        Remove-TcLibraryReference -Name '#Tc2_Math' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [ValidateSet('Library', 'Placeholder')]
        [string]$Kind,

        [Parameter()]
        [bool]$DryRun = $true,

        [Parameter()]
        [string]$PlcProjectPath
    )

    $given = ([string]$Name).Trim()
    $placeholderOnly = $given.StartsWith('#')
    $n = $given.TrimStart('#').Trim()
    $data = [PSCustomObject]@{ name = $n; kind = $(if ($Kind) { $Kind } else { $null }); dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($n)) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'name' -Data $data -Message '-Name is empty; nothing was removed.'
    }
    if ($placeholderOnly -and $Kind -eq 'Library') {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'kind-conflict' -Data $data -Message "-Name '$given' names a placeholder ('#'), -Kind says Library; nothing was removed."
    }
    if ($placeholderOnly) { $Kind = 'Placeholder' }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = "Remove-TcLibraryReference $n"
    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $refs = $mgr.Refs
        $refsPath = $mgr.RefsPath
        $data | Add-Member -NotePropertyName referencesPath -NotePropertyValue $refsPath

        $list = @(Get-TcLibraryReferenceList -Refs $refs)
        $isPh = { param($e) $e.isPlaceholder -and [string]$e.placeholderName -ieq $n }
        $isLib = { param($e) (-not $e.isPlaceholder) -and [string]$e.name -ieq $n }
        $phHits = @($list | Where-Object { & $isPh $_ })
        $libHits = @($list | Where-Object { & $isLib $_ })
        $both = $phHits.Count -gt 0 -and $libHits.Count -gt 0
        if ($both -and $Kind -eq 'Library') {
            $data | Add-Member -NotePropertyName candidates -NotePropertyValue @(@($phHits) + @($libHits) | ForEach-Object { $_.name })
            return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'ambiguous-library-not-measured' -Data $data `
                -Message "A library '$n' and a placeholder '#$n' both exist; which one XAE removes for RemoveReference('$n') is not measured, so it is not called. Nothing was removed."
        }
        if ($both -and -not $Kind) {
            $data | Add-Member -NotePropertyName candidates -NotePropertyValue @(@($phHits) + @($libHits) | ForEach-Object { $_.name })
            return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'ambiguous' -Data $data `
                -Message "'$given' matches the placeholder '#$n' and the library '$n'; pass '#$n' (or -Kind Placeholder) for the placeholder. Nothing was removed."
        }
        if ($Kind -eq 'Placeholder') { $hits = $phHits }
        elseif ($Kind -eq 'Library') { $hits = $libHits }
        else { $hits = @(@($phHits) + @($libHits)) }
        if ($hits.Count -eq 0) {
            $data | Add-Member -NotePropertyName references -NotePropertyValue @($list | ForEach-Object { $_.name })
            $what = if ($Kind -eq 'Placeholder') { "placeholder '#$n'" } elseif ($Kind -eq 'Library') { "library '$n'" } else { "library or placeholder '$given'" }
            return New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data `
                -Message "References of '$($mgr.PlcProjectPath)' list no $what; nothing was removed."
        }
        $target = $hits[0]
        $targetIsPh = [bool]$target.isPlaceholder
        $isMatch = if ($targetIsPh) { $isPh } else { $isLib }
        # '#<name>' for a placeholder (measured): never hits a library of the same name
        $arg = if ($targetIsPh) { "#$n" } else { $n }
        $data.kind = $(if ($targetIsPh) { 'Placeholder' } else { 'Library' })
        $data | Add-Member -NotePropertyName reference -NotePropertyValue $target
        $data | Add-Member -NotePropertyName removeArgument -NotePropertyValue $arg

        $projectFile = $null
        $locateError = $null
        try { $projectFile = Get-TcLibraryPlcProjFile -RefsPath $refsPath }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $locateError = $_.Exception.Message
        }
        $data | Add-Member -NotePropertyName projectFile -NotePropertyValue $projectFile

        if ($DryRun) {
            if ($null -ne $locateError) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("the .plcproj could not be located ($locateError); DryRun=false would return LIBRARY_BACKUP_FAILED") }
            return New-TcResult -Success $true -Data $data
        }

        $bk = Invoke-TcLibraryProjectBackup -PlcProjFile ([string]$projectFile) -RefsPath $refsPath -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $dlg = Get-TcTreeItemDialogResult -Operation "RemoveReference '$arg'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 245-909 ms measured.
            Invoke-TcComRetry -OperationName "RemoveReference $arg" -ScriptBlock { $null = $refs.RemoveReference($arg) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $text -match "Specified library '[^']*' not found!") {
                $res = New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data -Message "RemoveReference '$arg': XAE did not find it ($text); nothing was removed."
                return Register-TcCodeChange -Result $res -Change "$change [RemoveReference called, not found]"
            }
            throw
        }

        # --- readback: References, then the .plcproj on disk after saving
        $still = @(@(Get-TcLibraryReferenceList -Refs $refs) | Where-Object { & $isMatch $_ })
        if ($still.Count -gt 0) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'references'
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data -Message "RemoveReference '$arg' returned, but References still lists '$($still[0].name)'."
            return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
        }
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What "Library reference '$n'" -Done 'removed'
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "$change [removed, project file not saved]" }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        $entries = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)
        if (Test-TcPlcProjectHasLibraryEntry -Entries $entries -Name $n -Kind $data.kind) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'project-file'
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data `
                -Message "The project was saved, but '$($save.Saved.plcproj)' read back from disk still has a $($data.kind.ToLowerInvariant()) entry '$n'."
            return Register-TcCodeChange -Result $res -Change "$change [project file readback failed]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
    }
    catch {
        $res = New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_REMOVE_FAILED' -Data $data -Operation 'Remove-TcLibraryReference'
        if ($called) { return Register-TcCodeChange -Result $res -Change "$change [failed after RemoveReference]" }
        $res
    }
}
