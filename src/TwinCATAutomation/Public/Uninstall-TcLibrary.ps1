function Uninstall-TcLibrary {
    <#
    .SYNOPSIS
        Removes one library version from a library repository of this machine (ITcPlcLibraryManager.UninstallLibrary). Dry-run by default; exact name / version / distributor; reads back with ScanLibraries.
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
        DryRun (default true): UninstallLibrary is NOT called; data.dryRun, data.library (the entry).
        DryRun=false: modal dialog check (IDE_MODAL_DIALOG), UninstallLibrary, then ScanLibraries again:
        the entry must be gone (data.verified), else LIBRARY_VERIFY_FAILED. XAE refusing the call ->
        LIBRARY_UNINSTALL_FAILED (data.reason repository-not-found for an unknown repository; a
        NullReferenceException is reported as it is).
        No backup of the repository folder and no BUILD_REQUIRED (the project is not changed).
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
        data: libraryName, version, distributor, repository, dryRun, library, candidates, verified.
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
        $hit = @($before | Where-Object { & $isTarget $_ }) | Select-Object -First 1
        if ($null -eq $hit) {
            $data | Add-Member -NotePropertyName candidates -NotePropertyValue @($before | Where-Object { [string]$_.name -ieq $LibraryName } | Sort-Object version)
            return New-TcLibraryFailure -Code 'LIBRARY_NOT_INSTALLED' -Data $data `
                -Message "ScanLibraries lists no '$LibraryName, $Version ($Distributor)' (exact match); nothing was uninstalled."
        }
        $data | Add-Member -NotePropertyName library -NotePropertyValue $hit
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $dlg = Get-TcTreeItemDialogResult -Operation "UninstallLibrary '$LibraryName, $Version ($Distributor)'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 171 ms measured.
            Invoke-TcComRetry -OperationName "UninstallLibrary $LibraryName" -ScriptBlock { $null = $refs.UninstallLibrary($Repository, $LibraryName, $Version, $Distributor) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $text -match 'Could not find repository') {
                return New-TcLibraryFailure -Code 'LIBRARY_UNINSTALL_FAILED' -Reason 'repository-not-found' -Data $data -Message "UninstallLibrary: repository '$Repository' does not exist ($text); nothing was uninstalled."
            }
            throw
        }

        $after = @(Get-TcInstalledLibraryList -Refs $refs)
        if (@($after | Where-Object { & $isTarget $_ }).Count -gt 0) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            return New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Reason 'still-installed' -Data $data `
                -Message "UninstallLibrary returned, but ScanLibraries still lists '$LibraryName, $Version ($Distributor)'."
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_UNINSTALL_FAILED' -Data $data -Operation 'Uninstall-TcLibrary'
    }
}
