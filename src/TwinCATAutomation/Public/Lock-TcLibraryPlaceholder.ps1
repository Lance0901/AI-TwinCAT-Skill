function Lock-TcLibraryPlaceholder {
    <#
    .SYNOPSIS
        Freezes one library placeholder (or all with -All) to its current version (ITcPlcLibraryManager.FreezePlaceholder). Dry-run by default; backs up the .plcproj and reads it back.
    .DESCRIPTION
        ITcPlcLibraryManager.FreezePlaceholder(placeholderName) on the References node
        TIPC^<Plc>^<Plc> Project^References (TE1000 Automation Interface manual v1.7.0, 5.25.1
        p.113-119, p.244): the version is fixed at the current EffectiveResolution (the newest
        installed one when it is '*'); an empty name freezes every placeholder; E_FAIL when a
        placeholder has no EffectiveResolution or is not found.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1), one
        placeholder only: OK in 668 ms; the in-memory .plcproj changed in one place,
        <PlaceholderResolution Include=name><Resolution> from 'Tc2_Math, * (...)' to
        'Tc2_Math, 3.5.1.0 (...)'; DefaultResolution and the other placeholders unchanged; the
        References objects look the same before and after. Not found -> COMException 0x80004005
        "Placeholder '...' not found. Cannot freeze!". -All (empty name) is NOT measured.
        Exactly one of -Placeholder / -All (LIBRARY_INVALID_ARGUMENT reason target). -Placeholder must
        be a placeholder in References ('#<name>'), else LIBRARY_NOT_FOUND (data.placeholders), a
        library reference of that name -> LIBRARY_INVALID_ARGUMENT reason not-placeholder.
        DryRun (default true): FreezePlaceholder is NOT called; with -All, targets without an
        EffectiveResolution get a warning first (DryRun=false does not check them); data.targets[] with placeholder,
        effectiveResolution and the current projectResolution / frozen read from the .plcproj on disk.
        DryRun=false: backup of the .plcproj on disk into <solution dir>\.tcauto-backup\<timestamp>\
        (LIBRARY_BACKUP_FAILED = nothing changed), modal dialog check (IDE_MODAL_DIALOG),
        FreezePlaceholder(name) or FreezePlaceholder('') for -All, then the project file is saved
        (Invoke-TcPlcObjectSave) and the .plcproj read back from disk: every target that has an
        EffectiveResolution must now have a <Resolution> with a version other than '*'
        (data.targets[].frozen); otherwise LIBRARY_VERIFY_FAILED (data.notFrozen). With -All, a
        placeholder without EffectiveResolution (a visu placeholder, measured) is not checked and is
        listed in data.skippedUnresolved / data.warnings. XAE refusing the call ->
        PLACEHOLDER_FREEZE_FAILED (LIBRARY_NOT_FOUND for "not found").
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Placeholder
        Placeholder to freeze, with or without the leading '#'. Not together with -All.
    .PARAMETER All
        Freeze every placeholder (FreezePlaceholder with an empty name; not measured). Not together with -Placeholder.
    .PARAMETER DryRun
        Default true: only report. false: back up, freeze, save and read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: placeholder, all, dryRun, referencesPath, projectFile, targets[], notFrozen,
        skippedUnresolved, backupPath, backupFiles, warnings, projectSaved.
    .NOTES
        BUILD_REQUIRED (#65): as soon as FreezePlaceholder was called (success or any failure, also
        "not found" from XAE) the solution is recorded as code-changed (Register-TcCodeChange).
    .EXAMPLE
        Lock-TcLibraryPlaceholder -Placeholder Tc2_Math
    .EXAMPLE
        Lock-TcLibraryPlaceholder -All -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Placeholder,

        [Parameter()]
        [switch]$All,

        [Parameter()]
        [bool]$DryRun = $true,

        [Parameter()]
        [string]$PlcProjectPath
    )

    $ph = ([string]$Placeholder).Trim().TrimStart('#').Trim()
    $data = [PSCustomObject]@{ placeholder = $(if ($ph) { $ph } else { $null }); all = [bool]$All; dryRun = $DryRun }
    if ($All -and $ph) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'target' -Data $data -Message 'Give either -Placeholder or -All, not both; nothing was frozen.'
    }
    if (-not $All -and -not $ph) {
        return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'target' -Data $data -Message 'Give -Placeholder <name> or -All; nothing was frozen.'
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = if ($All) { 'Lock-TcLibraryPlaceholder -All' } else { "Lock-TcLibraryPlaceholder $ph" }
    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $refs = $mgr.Refs
        $refsPath = $mgr.RefsPath
        $data | Add-Member -NotePropertyName referencesPath -NotePropertyValue $refsPath

        $list = @(Get-TcLibraryReferenceList -Refs $refs)
        $placeholders = @($list | Where-Object { $_.isPlaceholder })
        if ($All) { $targets = $placeholders }
        else {
            $targets = @($placeholders | Where-Object { [string]$_.placeholderName -ieq $ph })
            if ($targets.Count -eq 0) {
                if (@($list | Where-Object { -not $_.isPlaceholder -and [string]$_.name -ieq $ph }).Count -gt 0) {
                    return New-TcLibraryFailure -Code 'LIBRARY_INVALID_ARGUMENT' -Reason 'not-placeholder' -Data $data `
                        -Message "'$ph' is a library reference, not a placeholder; only placeholders can be frozen. Nothing was frozen."
                }
                $data | Add-Member -NotePropertyName placeholders -NotePropertyValue @($placeholders | ForEach-Object { $_.placeholderName })
                return New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data -Message "References list no placeholder '#$ph'; nothing was frozen."
            }
            $targets = @($targets[0])
        }

        $projectFile = $null
        $entries = $null
        $locateError = $null
        try {
            $projectFile = Get-TcLibraryPlcProjFile -RefsPath $refsPath
            $entries = Get-TcPlcProjectLibraryEntries -Path $projectFile
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $locateError = $_.Exception.Message
        }
        $data | Add-Member -NotePropertyName projectFile -NotePropertyValue $projectFile
        $describe = {
            param($t, $ent)
            $pe = if ($null -ne $ent) { $ent.Placeholders[[string]$t.placeholderName] } else { $null }
            [PSCustomObject]@{
                placeholder         = $t.placeholderName
                effectiveResolution = $t.effectiveResolution
                projectResolution   = $(if ($null -ne $pe) { $pe.resolution } else { $null })
                frozen              = $(if ($null -eq $ent) { $null } elseif ($null -ne $pe) { [bool]$pe.frozen } else { $false })
            }
        }
        $data | Add-Member -NotePropertyName targets -NotePropertyValue @($targets | ForEach-Object { & $describe $_ $entries })

        if ($DryRun) {
            $w = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $locateError) { $w.Add("the .plcproj could not be read ($locateError); DryRun=false would return LIBRARY_BACKUP_FAILED") }
            $unresolved = @($targets | Where-Object { $null -eq $_.effectiveResolution } | ForEach-Object { $_.placeholderName })
            if ($unresolved.Count -gt 0) {
                $w.Add("no EffectiveResolution (FreezePlaceholder cannot freeze such a placeholder, TE1000 p.244; not measured with -All): $($unresolved -join ', '); DryRun=false does not check them and XAE may refuse the whole call")
                $data | Add-Member -NotePropertyName skippedUnresolved -NotePropertyValue $unresolved
            }
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue $w.ToArray()
            return New-TcResult -Success $true -Data $data
        }
        if ($targets.Count -eq 0) {
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue @('the project has no placeholder; FreezePlaceholder was not called')
            return New-TcResult -Success $true -Data $data
        }

        $bk = Invoke-TcLibraryProjectBackup -PlcProjFile ([string]$projectFile) -RefsPath $refsPath -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $arg = if ($All) { '' } else { [string]$targets[0].placeholderName }
        $dlg = Get-TcTreeItemDialogResult -Operation "FreezePlaceholder '$arg'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        try {
            # No deadline (CODING_STANDARDS.md section 1), as AddLibrary in Add-TcLibrary: an open
            # dialog was ruled out just above and Connect-TcIde turns on SilentMode. 668 ms measured (one placeholder).
            Invoke-TcComRetry -OperationName "FreezePlaceholder '$arg'" -ScriptBlock { $null = $refs.FreezePlaceholder($arg) }
        }
        catch {
            $text = Get-TcLibraryErrorText -ErrorRecord $_
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_) -and $text -match "Placeholder '[^']*' not found\. Cannot freeze!") {
                $res = New-TcLibraryFailure -Code 'LIBRARY_NOT_FOUND' -Data $data -Message "FreezePlaceholder '$arg': XAE did not find it ($text); nothing was frozen."
                return Register-TcCodeChange -Result $res -Change "$change [FreezePlaceholder called, not found]"
            }
            if ($null -eq (Get-TcTreeItemPassThroughError -ErrorRecord $_)) {
                $unres = @($targets | Where-Object { $null -eq $_.effectiveResolution } | ForEach-Object { $_.placeholderName })
                $why = if ($unres.Count -gt 0) { " Placeholders without EffectiveResolution: $($unres -join ', ') (TE1000 p.244: FreezePlaceholder returns E_FAIL for such a placeholder; not measured)." } else { '' }
                $res = New-TcLibraryFailure -Code 'PLACEHOLDER_FREEZE_FAILED' -Data $data -Message "FreezePlaceholder '$arg' failed: $text.$why"
                return Register-TcCodeChange -Result $res -Change "$change [failed after FreezePlaceholder]"
            }
            throw
        }

        # --- readback: FreezePlaceholder changes only the .plcproj, so save it and read it from disk
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What "Frozen placeholder '$(if ($All) { '<all>' } else { $arg })'" -Done 'changed'
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "$change [frozen, project file not saved]" }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        $after = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)
        $checked = @($targets | Where-Object { $null -ne $_.effectiveResolution -or -not $All })
        $skipped = @($targets | Where-Object { $null -eq $_.effectiveResolution -and $All } | ForEach-Object { $_.placeholderName })
        $data.targets = @($targets | ForEach-Object { & $describe $_ $after })
        $notFrozen = @($checked | ForEach-Object { & $describe $_ $after } | Where-Object { -not $_.frozen } | ForEach-Object { $_.placeholder })
        $data | Add-Member -NotePropertyName notFrozen -NotePropertyValue $notFrozen
        $data | Add-Member -NotePropertyName skippedUnresolved -NotePropertyValue $skipped
        if ($skipped.Count -gt 0) {
            $data.warnings = @(@($data.warnings) + @("not checked, no EffectiveResolution (FreezePlaceholder cannot freeze such a placeholder, TE1000 p.244): $($skipped -join ', ')"))
        }
        if ($notFrozen.Count -gt 0) {
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Reason 'not-frozen' -Data $data `
                -Message "FreezePlaceholder returned, but '$($save.Saved.plcproj)' read back from disk has no fixed version for: $($notFrozen -join ', ')."
            return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
        }
        Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
    }
    catch {
        $res = New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'PLACEHOLDER_FREEZE_FAILED' -Data $data -Operation 'Lock-TcLibraryPlaceholder'
        if ($called) { return Register-TcCodeChange -Result $res -Change "$change [failed after FreezePlaceholder]" }
        $res
    }
}
