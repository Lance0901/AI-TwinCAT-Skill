function Uninstall-TcLibrary {
    <#
    .SYNOPSIS
        Removes one library version from a library repository of this machine (ITcPlcLibraryManager.UninstallLibrary). Dry-run by default; exact name / version / distributor; backs up the version folder; reads back with ScanLibraries.
    .DESCRIPTION
        Changes the library repository of the whole machine, not the project. Every PLC project on
        this machine that uses this version loses it. ITcPlcLibraryManager.UninstallLibrary(
        repositoryName, libraryName, version, distributor) on the References node of a PLC project
        (TE1000 Automation Interface manual v1.7.0, 5.25.1 p.113-119).
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1): an installed
        library is removed in 171 ms and its version folder below
        C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries disappears; a library /
        version that is not installed throws NullReferenceException 0x80004003 (nothing removed), so
        XAE's error cannot tell "not installed" apart from other failures.
        Therefore the module checks first: -LibraryName, -Version and -Distributor must equal (ordinal,
        case-sensitive) one entry of ScanLibraries; wildcards (* ? [ ]) are refused
        (LIBRARY_INVALID_ARGUMENT reason wildcard). No exact entry -> LIBRARY_NOT_INSTALLED with
        data.candidates (installed entries of the same name, ignoring case). The repository of an
        entry is not reported by ScanLibraries, so the check does not prove that it is in -Repository.
        DryRun (default true): UninstallLibrary is NOT called; data.dryRun, data.library (the entry),
        data.repositoryFolder (the version folder that would be backed up, $null + data.warnings when it
        cannot be derived).
        Backup (DryRun=false, before anything is uninstalled): the version folder
        <repository root>\<Distributor>\<LibraryName>\<Version> is copied as a whole to
        <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\library-repo\<name>\<version>\ (data.backupPath,
        data.repositoryFolder). Repository root: the Folder of -Repository in
        ITcPlcLibraryManager.Repositories (TE1000 5.22 / 5.23 p.111-112; it returned Count=0 in the probe),
        else for 'System' C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries (layout
        measured 2026-10-31 4026 VS2022: InstallLibrary created and UninstallLibrary removed
        <Distributor>\<Library>\<Version> there). Folder not derivable, no solution path, copy failed or
        incomplete -> LIBRARY_BACKUP_FAILED, nothing is uninstalled.
        Restore: copy the backed-up folder back to data.repositoryFolder (close XAE first; whether XAE
        picks it up without a rescan is not measured), or install the original .library file again
        with Install-TcLibrary.
        Then modal dialog check (IDE_MODAL_DIALOG), UninstallLibrary, then ScanLibraries again: the
        number of exactly matching entries must have dropped (data.matchesBefore / data.matchesAfter,
        data.verified), else LIBRARY_VERIFY_FAILED. The same version can be installed in several
        repositories (ScanLibraries lists every repository): entries left over are a warning, not a
        failure. When the backed-up folder still exists afterwards, a warning says that the backup may
        not be the copy that was removed. XAE refusing the call ->
        LIBRARY_UNINSTALL_FAILED (data.reason repository-not-found for an unknown repository; a
        NullReferenceException is reported as it is).
        No BUILD_REQUIRED (the project is not changed).
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER LibraryName
        Library name exactly as ScanLibraries lists it (Get-TcLibraries -Repository), e.g. Tc2_Math.
    .PARAMETER Version
        Exact version, e.g. 3.5.1.0. No '*'.
    .PARAMETER Distributor
        Exact distributor, e.g. Beckhoff Automation GmbH.
    .PARAMETER Repository
        Repository name. Default 'System' (TE1000 6.5.12).
    .PARAMETER DryRun
        Default true: only check and report. false: uninstall and read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (the Library Manager lives on its References node).
    .OUTPUTS
        data: libraryName, version, distributor, repository, dryRun, library, candidates,
        repositoryFolder, repositoryFolderSource, backupPath, backupFileCount, matchesBefore,
        matchesAfter, verified, warnings.
    .EXAMPLE
        Uninstall-TcLibrary -LibraryName MyLib -Version 1.0.0.0 -Distributor 'My Company'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LibraryName,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Distributor,

        [Parameter()]
        [string]$Repository = 'System',

        [Parameter()]
        [bool]$DryRun = $true,

        [Parameter()]
        [string]$PlcProjectPath
    )

    $data = [PSCustomObject]@{ libraryName = $LibraryName; version = $Version; distributor = $Distributor; repository = $Repository; dryRun = $DryRun }
    foreach ($pair in @(@('LibraryName', $LibraryName), @('Version', $Version), @('Distributor', $Distributor), @('Repository', $Repository))) {
        if ([string]::IsNullOrWhiteSpace([string]$pair[1])) {
            return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'empty' -Data $data -Message "-$($pair[0]) is empty; nothing was uninstalled."
        }
        if ([string]$pair[1] -match '[\*\?\[\]]') {
            return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'wildcard' -Data $data `
                -Message "-$($pair[0]) '$($pair[1])' contains a wildcard; Uninstall-TcLibrary removes exactly one installed version. Nothing was uninstalled."
        }
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $refs = $mgr.Refs

        $isTarget = { param($l) [string]::Equals([string]$l.name, $LibraryName, [System.StringComparison]::Ordinal) -and
            [string]::Equals([string]$l.version, $Version, [System.StringComparison]::Ordinal) -and
            [string]::Equals([string]$l.distributor, $Distributor, [System.StringComparison]::Ordinal) }
        $before = @(Get-TcInstalledLibraryList -Refs $refs)
        $matchesBefore = @($before | Where-Object { & $isTarget $_ }).Count
        $hit = @($before | Where-Object { & $isTarget $_ }) | Select-Object -First 1
        if ($null -eq $hit) {
            $data | Add-Member -NotePropertyName candidates -NotePropertyValue @($before | Where-Object { [string]$_.name -ieq $LibraryName } | Sort-Object version)
            return New-TcLibraryFailure -Code 'LIBRARY_NOT_INSTALLED' -Data $data `
                -Message "ScanLibraries lists no '$LibraryName, $Version ($Distributor)' (exact match); nothing was uninstalled."
        }
        $data | Add-Member -NotePropertyName library -NotePropertyValue $hit
        $folder = Get-TcLibraryRepositoryVersionFolder -Refs $refs -Repository $Repository -Library $hit
        $data | Add-Member -NotePropertyName repositoryFolder -NotePropertyValue $folder.Path
        $data | Add-Member -NotePropertyName repositoryFolderSource -NotePropertyValue $folder.Source
        if ($DryRun) {
            if ($null -eq $folder.Path) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("the repository folder could not be derived (tried: $(@($folder.Tried) -join '; ')); DryRun=false would return LIBRARY_BACKUP_FAILED") }
            return New-TcResult -Success $true -Data $data
        }

        $bk = Invoke-TcLibraryRepositoryBackup -SourcePath $folder.Path -Library $hit -Data $data -Tried @($folder.Tried)
        if ($null -ne $bk.Result) { return $bk.Result }
        $data | Add-Member -NotePropertyName backupPath -NotePropertyValue $bk.Backup.backupPath
        $data | Add-Member -NotePropertyName backupFileCount -NotePropertyValue $bk.Backup.fileCount

        $dlg = Get-TcTreeItemDialogResult -Operation "UninstallLibrary '$LibraryName, $Version ($Distributor)'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 171 ms measured.
            Invoke-TcComRetry -OperationName "UninstallLibrary $LibraryName" -ScriptBlock { $null = $refs.UninstallLibrary($Repository, $LibraryName, $Version, $Distributor) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $text -match "Could not find repository '[^']*'") {
                return New-TcLibraryFailure -Code 'LIBRARY_UNINSTALL_FAILED' -Reason 'repository-not-found' -Data $data -Message "UninstallLibrary: repository '$Repository' does not exist ($text); nothing was uninstalled."
            }
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $_.Exception.ToString() -match 'NullReferenceException') {
                return New-TcLibraryFailure -Code 'LIBRARY_UNINSTALL_FAILED' -Reason 'null-reference' -Data $data `
                    -Message "UninstallLibrary threw NullReferenceException ($text). XAE throws it when the library / version is not in that repository (measured 2026-10-31 4026 VS2022, self-built client); ScanLibraries listed it, so it is probably installed in another repository than '$Repository'."
            }
            throw
        }

        $after = @(Get-TcInstalledLibraryList -Refs $refs)
        $matchesAfter = @($after | Where-Object { & $isTarget $_ }).Count
        $data | Add-Member -NotePropertyName matchesBefore -NotePropertyValue $matchesBefore
        $data | Add-Member -NotePropertyName matchesAfter -NotePropertyValue $matchesAfter
        if ($matchesAfter -ge $matchesBefore) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            return New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Reason 'still-installed' -Data $data `
                -Message "UninstallLibrary returned, but ScanLibraries still lists '$LibraryName, $Version ($Distributor)' $matchesAfter time(s) ($matchesBefore before)."
        }
        $warnings = [System.Collections.Generic.List[string]]::new()
        if ($matchesAfter -gt 0) { $warnings.Add("ScanLibraries still lists '$LibraryName, $Version ($Distributor)' $matchesAfter time(s) (installed in another repository too); only one copy was removed") }
        if (Test-Path -LiteralPath ([string]$folder.Path)) {
            $warnings.Add("the backed-up folder '$($folder.Path)' still exists after UninstallLibrary: the backup in data.backupPath may not be the copy that was removed")
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_UNINSTALL_FAILED' -Data $data -Operation 'Uninstall-TcLibrary'
    }
}
