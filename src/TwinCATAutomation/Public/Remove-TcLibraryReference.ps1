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
        COMException 0x98510001 "Specified library '...' not found!". The module always passes the name
        without '#'.
        Checks before anything is changed: -Name not empty (LIBRARY_INVALID_ARGUMENT); References must
        list it as '<Name>' or '#<Name>' (case-insensitive), else LIBRARY_NOT_FOUND with
        data.references; a library '<Name>' and a placeholder '#<Name>' at the same time ->
        LIBRARY_INVALID_ARGUMENT reason ambiguous (pass '#<Name>' for the placeholder).
        DryRun (default true): RemoveReference is NOT called; data.dryRun, data.reference (the entry
        that would be removed), data.projectFile.
        DryRun=false: backup of the .plcproj on disk into <solution dir>\.tcauto-backup\<timestamp>\
        (data.backupPath, data.backupFiles; LIBRARY_BACKUP_FAILED = nothing removed), modal dialog check
        (IDE_MODAL_DIALOG), RemoveReference, then readback: References must no longer list it, the
        project file is saved (Invoke-TcPlcObjectSave) and the .plcproj read from disk must have no
        PlaceholderReference / PlaceholderResolution / LibraryReference for it. Otherwise
        LIBRARY_VERIFY_FAILED (data.step references / project-file). XAE refusing the call ->
        LIBRARY_REMOVE_FAILED (or LIBRARY_NOT_FOUND for 0x98510001).
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Name
        Library or placeholder name, with or without the leading '#' (e.g. Tc2_Math or #Tc2_Math).
    .PARAMETER DryRun
        Default true: only report what would be removed. false: back up, remove, read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: name, dryRun, referencesPath, reference, projectFile, backupPath, backupFiles, warnings,
        verified, projectSaved.
    .NOTES
        BUILD_REQUIRED (#65): after RemoveReference was called (success, or a failure after the
        call) the solution is recorded as code-changed (Register-TcCodeChange).
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
        [bool]$DryRun = $true,

        [Parameter()]
        [string]$PlcProjectPath
    )

    $given = ([string]$Name).Trim()
    $placeholderOnly = $given.StartsWith('#')
    $n = $given.TrimStart('#').Trim()
    $data = [PSCustomObject]@{ name = $n; dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($n)) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'name' -Data $data -Message '-Name is empty; nothing was removed.'
    }

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
        $isMatch = { param($e) ($e.isPlaceholder -and [string]$e.placeholderName -ieq $n) -or ((-not $placeholderOnly) -and (-not $e.isPlaceholder) -and [string]$e.name -ieq $n) }
        $hits = @($list | Where-Object { & $isMatch $_ })
        if ($hits.Count -eq 0) {
            $data | Add-Member -NotePropertyName references -NotePropertyValue @($list | ForEach-Object { $_.name })
            return New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data `
                -Message "References of '$($mgr.PlcProjectPath)' list no library or placeholder '$given'; nothing was removed."
        }
        if ($hits.Count -gt 1) {
            $data | Add-Member -NotePropertyName candidates -NotePropertyValue @($hits | ForEach-Object { $_.name })
            return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'ambiguous' -Data $data `
                -Message "'$given' matches $($hits.Count) references ($(@($hits | ForEach-Object { $_.name }) -join ', ')); pass '#$n' for the placeholder. Nothing was removed."
        }
        $target = $hits[0]
        $data | Add-Member -NotePropertyName reference -NotePropertyValue $target

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

        $dlg = Get-TcTreeItemDialogResult -Operation "RemoveReference '$n'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 245-909 ms measured.
            Invoke-TcComRetry -OperationName "RemoveReference $n" -ScriptBlock { $null = $refs.RemoveReference($n) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $text -match '0x98510001|not found') {
                return New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data -Message "RemoveReference '$n': XAE did not find it ($text); nothing was removed."
            }
            throw
        }

        # --- readback: References, then the .plcproj on disk after saving
        $still = @(@(Get-TcLibraryReferenceList -Refs $refs) | Where-Object { & $isMatch $_ })
        if ($still.Count -gt 0) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'references'
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data -Message "RemoveReference '$n' returned, but References still lists '$($still[0].name)'."
            return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
        }
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What "Library reference '$n'" -Done 'removed'
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "$change [removed, project file not saved]" }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        $entries = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)
        if (Test-TcPlcProjectHasLibraryEntry -Entries $entries -Name $n) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'project-file'
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data `
                -Message "The project was saved, but '$($save.Saved.plcproj)' read back from disk still has a library / placeholder entry '$n'."
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
