function Install-TcLibrary {
    <#
    .SYNOPSIS
        Installs a .library / .compiled-library file into a library repository of this machine (ITcPlcLibraryManager.InstallLibrary). Dry-run by default; reads back with ScanLibraries.
    .DESCRIPTION
        Changes the library repository of the whole machine, not the project
        (C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\Managed Libraries\<Distributor>\<Library>\<Version>
        on the measured machine). ITcPlcLibraryManager.InstallLibrary(repositoryName, libPath,
        bOverwrite) on the References node of a PLC project (TE1000 Automation Interface manual v1.7.0,
        5.25.1 p.113-119; 6.5.12 p.239: repository "System", .library or .compiled-library). The module
        never overwrites (bOverwrite = false).
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1): install into
        'System' OK in 3.6 s (no UAC prompt as a normal user); the same library again with
        bOverwrite = false -> IOException 0x80131620 "Library already exists." (the manual says the
        install is cancelled); unknown repository -> COMException 0x98510001 "Could not find
        repository '...'".
        Already installed: the name and version of the library are not readable from the file
        through the Automation Interface, so the pre-check uses the file name: '<name>_<version>.library'
        (the name XAE SaveAsLibrary wrote, measured 2026-10-31) is looked up in ScanLibraries (name and
        version, any distributor, any repository) -> LIBRARY_ALREADY_INSTALLED with data.installed,
        InstallLibrary is not called (data.preCheck = file-name). A file name without that pattern
        cannot be pre-checked (data.identityFromFileName = $null); "Library already exists." from XAE is
        then mapped to LIBRARY_ALREADY_INSTALLED (data.preCheck = xae).
        Checks before anything is changed: -LibraryPath absolute, an existing file, extension .library
        or .compiled-library; -Repository not empty (LIBRARY_INVALID_ARGUMENT, data.reason).
        DryRun (default true): InstallLibrary is NOT called; data.dryRun, data.identityFromFileName,
        data.alreadyInstalled ($null when the file name gives no identity), data.installedCount.
        DryRun=false: modal dialog check (IDE_MODAL_DIALOG), InstallLibrary, then ScanLibraries again:
        at least one entry must be new (data.installed), else LIBRARY_VERIFY_FAILED. XAE refusing the
        call -> LIBRARY_INSTALL_FAILED (data.reason repository-not-found for an unknown repository).
        No backup (nothing is overwritten) and no BUILD_REQUIRED (the project is not changed).
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER LibraryPath
        Absolute path of the .library or .compiled-library file.
    .PARAMETER Repository
        Repository name. Default 'System' (TE1000 6.5.12).
    .PARAMETER DryRun
        Default true: only check and report. false: install and read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (the Library Manager lives on its References node).
    .OUTPUTS
        data: libraryPath, repository, dryRun, identityFromFileName, preCheck, alreadyInstalled,
        installedCount, installed[], warnings.
    .EXAMPLE
        Install-TcLibrary -LibraryPath 'C:\Libs\MyLib_1.0.0.0.library'
    .EXAMPLE
        Install-TcLibrary -LibraryPath 'C:\Libs\MyLib_1.0.0.0.library' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$LibraryPath,

        [Parameter()]
        [string]$Repository = 'System',

        [Parameter()]
        [bool]$DryRun = $true,

        [Parameter()]
        [string]$PlcProjectPath
    )

    $data = [PSCustomObject]@{ libraryPath = $LibraryPath; repository = $Repository; dryRun = $DryRun }
    $bad = $null
    if ([string]::IsNullOrWhiteSpace($LibraryPath) -or -not [System.IO.Path]::IsPathRooted($LibraryPath)) { $bad = @('path', "-LibraryPath must be an absolute path (got '$LibraryPath')") }
    elseif ($LibraryPath -notmatch '(?i)\.(compiled-)?library$') { $bad = @('extension', "-LibraryPath '$LibraryPath' is not a .library / .compiled-library file (TE1000 6.5.12)") }
    elseif (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) { $bad = @('missing', "-LibraryPath '$LibraryPath' does not exist") }
    elseif ([string]::IsNullOrWhiteSpace($Repository)) { $bad = @('repository', '-Repository is empty') }
    if ($null -ne $bad) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason $bad[0] -Data $data -Message "$($bad[1]); nothing was installed."
    }
    $LibraryPath = [System.IO.Path]::GetFullPath($LibraryPath)
    $data.libraryPath = $LibraryPath

    $stem = [System.IO.Path]::GetFileName($LibraryPath) -replace '(?i)\.(compiled-)?library$', ''
    $idm = [regex]::Match($stem, '^(?<name>.+?)_(?<ver>\d+(?:\.\d+){1,3})$')
    $identity = if ($idm.Success) { [PSCustomObject]@{ name = $idm.Groups['name'].Value; version = $idm.Groups['ver'].Value } } else { $null }
    $data | Add-Member -NotePropertyName identityFromFileName -NotePropertyValue $identity

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $refs = $mgr.Refs

        $before = @(Get-TcInstalledLibraryList -Refs $refs)
        $data | Add-Member -NotePropertyName installedCount -NotePropertyValue $before.Count
        $already = $null
        if ($null -ne $identity) {
            $already = @($before | Where-Object { [string]$_.name -ieq $identity.name -and [string]$_.version -eq $identity.version })
            if ($already.Count -gt 0) {
                $data | Add-Member -NotePropertyName preCheck -NotePropertyValue 'file-name'
                $data | Add-Member -NotePropertyName alreadyInstalled -NotePropertyValue $true
                $data | Add-Member -NotePropertyName installed -NotePropertyValue $already
                return New-TcLibraryFailure -Code 'LIBRARY_ALREADY_INSTALLED' -Data $data `
                    -Message "$($identity.name) $($identity.version) (from the file name) is already installed ($(@($already | ForEach-Object { $_.displayName }) -join '; ')); nothing was installed."
            }
        }
        $data | Add-Member -NotePropertyName alreadyInstalled -NotePropertyValue $(if ($null -ne $identity) { $false } else { $null })
        if ($DryRun) {
            if ($null -eq $identity) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("the file name is not '<name>_<version>.library'; whether it is already installed is only known when XAE installs it") }
            return New-TcResult -Success $true -Data $data
        }

        $dlg = Get-TcTreeItemDialogResult -Operation "InstallLibrary '$LibraryPath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 3.6 s measured.
            Invoke-TcComRetry -OperationName "InstallLibrary $Repository" -ScriptBlock { $null = $refs.InstallLibrary($Repository, $LibraryPath, $false) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_)) {
                if ($text -match 'Library already exists') {
                    $data | Add-Member -NotePropertyName preCheck -NotePropertyValue 'xae' -Force
                    $data.alreadyInstalled = $true
                    return New-TcLibraryFailure -Code 'LIBRARY_ALREADY_INSTALLED' -Data $data -Message "InstallLibrary: XAE reports the library is already installed ($text); nothing was installed."
                }
                if ($text -match 'Could not find repository') {
                    return New-TcLibraryFailure -Code 'LIBRARY_INSTALL_FAILED' -Reason 'repository-not-found' -Data $data -Message "InstallLibrary: repository '$Repository' does not exist ($text); nothing was installed."
                }
            }
            throw
        }

        $after = @(Get-TcInstalledLibraryList -Refs $refs)
        $known = @{}
        foreach ($l in $before) { $known[(Get-TcLibraryKey -Library $l)] = $true }
        $new = @($after | Where-Object { -not $known.ContainsKey((Get-TcLibraryKey -Library $_)) })
        $data | Add-Member -NotePropertyName installed -NotePropertyValue $new -Force
        if ($new.Count -eq 0) {
            return New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Reason 'not-listed' -Data $data `
                -Message "InstallLibrary returned, but ScanLibraries lists no new library ($($before.Count) before, $($after.Count) after)."
        }
        if ($null -ne $identity -and @($new | Where-Object { [string]$_.name -ieq $identity.name -and [string]$_.version -eq $identity.version }).Count -eq 0) {
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("the new library ($(@($new | ForEach-Object { $_.displayName }) -join '; ')) is not the name / version the file name suggests ($($identity.name) $($identity.version))") -Force
        }
        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_INSTALL_FAILED' -Data $data -Operation 'Install-TcLibrary'
    }
}
