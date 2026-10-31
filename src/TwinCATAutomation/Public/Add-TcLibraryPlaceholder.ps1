function Add-TcLibraryPlaceholder {
    <#
    .SYNOPSIS
        Adds a library placeholder to the PLC project (ITcPlcLibraryManager.AddPlaceholder), saves the project file and reads it back.
    .DESCRIPTION
        ITcPlcLibraryManager.AddPlaceholder(placeholderName, defaultLibName, defaultVersion,
        defaultDistributor) on the References node TIPC^<Plc>^<Plc> Project^References (TE1000
        Automation Interface manual v1.7.0, 6.5.14 p.241-244; 5.25.1 p.113-119). Without -LibraryName
        the one-argument form AddPlaceholder(name) is called: XAE takes the default library from the
        device placeholder (TE1000 5.25.1).
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1):
          - AddPlaceholder('PH','Tc2_Math','*','Beckhoff Automation GmbH') writes
            <PlaceholderReference Include="PH"> (DefaultResolution, Namespace) and
            <PlaceholderResolution Include="PH"> into the in-memory .plcproj.
          - same name again: ArgumentException 0x80070057 "Placeholder '...' already contained!"
          - default library not installed: COMException 0x98510001 "Default Library '...' not found!",
            no placeholder created.
          - one-argument form without a device placeholder: ArgumentException 0x80070057
            "Default Placeholder '...' could not be found!".
        Already present: References is read first; a placeholder '#<Placeholder>' -> success with
        data.alreadyPresent = true, AddPlaceholder is not called, the project file is still saved and
        read back, no BUILD_REQUIRED (same as Add-TcLibrary). data.libraryName / version / distributor
        are then the values read from the existing placeholder (its DefaultResolution, else
        EffectiveResolution) and data.requested holds the parameters; a default library other than
        -LibraryName adds a warning (nothing is changed). "Placeholder '...' already contained!" from
        XAE is mapped to the same result.
        Failures before AddPlaceholder (no BUILD_REQUIRED): LIBRARY_INVALID_ARGUMENT (empty name,
        -Version / -Distributor without -LibraryName), IDE_MODAL_DIALOG (dialog open before
        AddPlaceholder). Errors XAE returned for the call: PLACEHOLDER_ADD_FAILED with data.reason
        default-library-not-installed ("Default Library '...' not found!") or no-device-placeholder
        ("Default Placeholder '...' could not be found!").
        Readback after AddPlaceholder: References must list '#<Placeholder>' and, with -LibraryName,
        its effective / default resolution must name that library; then the project file is saved
        (Invoke-TcPlcObjectSave) and the .plcproj read from disk must have a PlaceholderReference /
        PlaceholderResolution for it. Otherwise LIBRARY_VERIFY_FAILED (data.step references /
        library / project-file) or PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Placeholder
        Placeholder name, with or without the leading '#'.
    .PARAMETER LibraryName
        Default library of the placeholder (e.g. Tc2_Math). Empty: one-argument form (device placeholder).
    .PARAMETER Version
        Default library version; '*' (default) = newest installed. Only with -LibraryName.
    .PARAMETER Distributor
        Distributor of the default library. Default 'Beckhoff Automation GmbH'. Only with -LibraryName.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: placeholder, libraryName, version, distributor, requested, referencesPath, alreadyPresent,
        reference (References entry read back), projectEntry (.plcproj entry read back), projectSaved.
    .NOTES
        BUILD_REQUIRED (#65): as soon as AddPlaceholder was called (success or any failure, also an
        error XAE returned, as Add-TcPouMember after CreateChild) the solution is recorded as
        code-changed (Register-TcCodeChange); only a placeholder found in References before the call
        and the failures before the call record nothing.
    .EXAMPLE
        Add-TcLibraryPlaceholder -Placeholder Tc2_Math_PH -LibraryName Tc2_Math
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Placeholder,

        [Parameter()]
        [string]$LibraryName,

        [Parameter()]
        [string]$Version = '*',

        [Parameter()]
        [string]$Distributor = 'Beckhoff Automation GmbH',

        [Parameter()]
        [string]$PlcProjectPath
    )

    $ph = ([string]$Placeholder).Trim().TrimStart('#').Trim()
    $lib = ([string]$LibraryName).Trim()
    $data = [PSCustomObject]@{
        placeholder = $ph; libraryName = $(if ($lib) { $lib } else { $null })
        version = $(if ($lib) { $Version } else { $null }); distributor = $(if ($lib) { $Distributor } else { $null })
    }
    if ([string]::IsNullOrWhiteSpace($ph)) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'name' -Data $data -Message '-Placeholder is empty; nothing was added.'
    }
    if ([string]::IsNullOrWhiteSpace($lib) -and ($PSBoundParameters.ContainsKey('Version') -or $PSBoundParameters.ContainsKey('Distributor'))) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'no-library-name' -Data $data `
            -Message '-Version / -Distributor need -LibraryName (without it XAE takes the default library of the device placeholder); nothing was added.'
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = "Add-TcLibraryPlaceholder $ph"
    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $refs = $mgr.Refs
        $refsPath = $mgr.RefsPath
        $data | Add-Member -NotePropertyName referencesPath -NotePropertyValue $refsPath

        $before = @(Get-TcLibraryReferenceList -Refs $refs)
        $existing = @($before | Where-Object { $_.isPlaceholder -and [string]$_.placeholderName -ieq $ph }) | Select-Object -First 1
        $alreadyPresent = $null -ne $existing

        if (-not $alreadyPresent) {
            $dlg = Get-TcTreeItemDialogResult -Operation "AddPlaceholder '$ph'" -Data $data
            if ($null -ne $dlg) { return $dlg }
            $called = $true
            try {
                # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
                # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 140-669 ms measured.
                if ($lib) { Invoke-TcComRetry -OperationName "AddPlaceholder $ph" -ScriptBlock { $null = $refs.AddPlaceholder($ph, $lib, $Version, $Distributor) } }
                else { Invoke-TcComRetry -OperationName "AddPlaceholder $ph" -ScriptBlock { $null = $refs.AddPlaceholder($ph) } }
            }
            catch {
                $text = Get-TcLibraryErrorText -ErrorRecord $_
                # complete messages measured 2026-10-31 4026 VS2022 (self-built client, phase2-probe.md 3.1)
                $own = $null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_)
                if ($own -and $text -match "Placeholder '[^']*' already contained!") { $alreadyPresent = $true }
                elseif ($own -and $text -match "Default Placeholder '[^']*' could not be found!") {
                    $res = New-TcLibraryFailure -Code 'PLACEHOLDER_ADD_FAILED' -Reason 'no-device-placeholder' -Data $data `
                        -Message "AddPlaceholder '$ph' without -LibraryName: XAE found no device placeholder with that name ($text); nothing was added."
                    return Register-TcCodeChange -Result $res -Change "$change [AddPlaceholder called, refused]"
                }
                elseif ($own -and $text -match "Default Library '[^']*' not found!") {
                    $res = New-TcLibraryFailure -Code 'PLACEHOLDER_ADD_FAILED' -Reason 'default-library-not-installed' -Data $data `
                        -Message "AddPlaceholder '$ph': the default library '$lib' ($Version, $Distributor) is not installed ($text); nothing was added."
                    return Register-TcCodeChange -Result $res -Change "$change [AddPlaceholder called, refused]"
                }
                else { throw }
            }
        }

        # --- readback: References
        $after = @(Get-TcLibraryReferenceList -Refs $refs)
        $ref = @($after | Where-Object { $_.isPlaceholder -and [string]$_.placeholderName -ieq $ph }) | Select-Object -First 1
        $data | Add-Member -NotePropertyName alreadyPresent -NotePropertyValue $alreadyPresent
        $data | Add-Member -NotePropertyName reference -NotePropertyValue $ref
        $data | Add-Member -NotePropertyName requested -NotePropertyValue ([PSCustomObject]@{ libraryName = $data.libraryName; version = $data.version; distributor = $data.distributor })
        if ($alreadyPresent -and $null -ne $ref) {
            # report what the existing placeholder really has, not what was asked for
            $actual = if ($null -ne $ref.defaultResolution) { $ref.defaultResolution } else { $ref.effectiveResolution }
            $data.libraryName = $(if ($null -ne $actual) { $actual.libraryName } else { $null })
            $data.version = $(if ($null -ne $actual) { $actual.version } else { $null })
            $data.distributor = $(if ($null -ne $actual) { $actual.distributor } else { $null })
            if ($lib -and [string]$data.libraryName -ine $lib) {
                $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("placeholder '#$ph' already exists with default library '$($data.libraryName)', not '$lib'; it was not changed (remove it with Remove-TcLibraryReference first to re-add it)")
            }
        }
        $verifyFail = $null
        if ($null -eq $ref) {
            $verifyFail = @{ Step = 'references'; Message = "AddPlaceholder returned, but References does not list '#$ph'." }
        }
        elseif ($lib -and -not $alreadyPresent) {
            $names = @($ref.effectiveResolution, $ref.defaultResolution) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.libraryName }
            if (@($names | Where-Object { $_ -ieq $lib }).Count -eq 0) {
                $verifyFail = @{ Step = 'library'; Message = "Placeholder '#$ph' was added, but it resolves to '$(@($names) -join ', ')', not '$lib'." }
            }
        }
        if ($null -ne $verifyFail) {
            $data | Add-Member -NotePropertyName step -NotePropertyValue $verifyFail.Step
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data -Message $verifyFail.Message
            if ($called) { return Register-TcCodeChange -Result $res -Change "$change [readback failed]" }
            return $res
        }

        # --- project file: save, then read the .plcproj back from disk
        $what = if ($alreadyPresent) { "Library placeholder '$ph' (already present)" } else { "Library placeholder '$ph'" }
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What $what -Done 'added'
        if ($null -ne $save.Error) {
            if ($called) { return Register-TcCodeChange -Result $save.Error -Change "$change [added, project file not saved]" }
            return $save.Error
        }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        $entries = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)
        $pe = $entries.Placeholders[$ph]
        $data | Add-Member -NotePropertyName projectEntry -NotePropertyValue $pe
        if ($null -eq $pe) {
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'project-file'
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Data $data `
                -Message "The project was saved, but '$($save.Saved.plcproj)' read back from disk has no PlaceholderReference / PlaceholderResolution '$ph'."
            if ($called) { return Register-TcCodeChange -Result $res -Change "$change [project file readback failed]" }
            return $res
        }

        $ok = New-TcResult -Success $true -Data $data
        if ($alreadyPresent -and -not $called) { return $ok }
        Register-TcCodeChange -Result $ok -Change $change
    }
    catch {
        $res = New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'PLACEHOLDER_ADD_FAILED' -Data $data -Operation 'Add-TcLibraryPlaceholder'
        # conservative (#65): AddPlaceholder was called, the placeholder may have been added
        if ($called) { return Register-TcCodeChange -Result $res -Change "$change [failed after AddPlaceholder]" }
        $res
    }
}
