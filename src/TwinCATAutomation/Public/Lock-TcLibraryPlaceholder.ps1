function Lock-TcLibraryPlaceholder {
    <#
    .SYNOPSIS
        Freezes one library placeholder (or all with -All) to its current version (ITcPlcLibraryManager.FreezePlaceholder). Dry-run by default; backs up the .plcproj, reads it back and checks the version did not change.
    .DESCRIPTION
        ITcPlcLibraryManager.FreezePlaceholder(placeholderName) on the References node
        TIPC^<Plc>^<Plc> Project^References (TE1000 Automation Interface manual v1.7.0, 5.25.1
        p.113-119, p.244; InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841158667.html):
        the manual says the version is fixed at the current EffectiveResolution (the newest
        installed one when it is '*'); an empty name freezes every placeholder.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1), one
        placeholder whose DefaultResolution is '*': <PlaceholderResolution Include=name><Resolution>
        from 'Tc2_Math, * (...)' to 'Tc2_Math, 3.5.1.0 (...)'. Not found -> COMException
        0x80004005 "Placeholder '...' not found. Cannot freeze!".
        Measured 2026-10-31 through the registered tcauto MCP server (verification/phase2-3.8.md
        P2 / P3; 4026 VS2022 and 4024 XAE): FreezePlaceholder('') fixed every placeholder at its
        DefaultResolution, NOT at the effective version (#Tc2_System 3.10.1.0 -> 3.9.1.0,
        #CBML 4.0.0.0 (CODESYS) -> 3.5.13.0 (3S - ...), VisuDialogs 3.5.12.0 -> 4.8.0.0 (System));
        a visu placeholder without EffectiveResolution was frozen too (at its DefaultResolution);
        a placeholder without <PlaceholderReference> in the .plcproj (#Tc3_GlobalTypes, added by
        XAE itself) got no <Resolution>.
        So the readback compares, per placeholder, the frozen <Resolution> (library, version,
        distributor) with the EffectiveResolution read BEFORE the call. A placeholder that moved is
        pinned back with ITcPlcLibraryManager.SetEffectiveResolution(placeholder, library, version,
        distributor) (InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841216267.html; NOT
        measured), the project saved and read back again; still different (or SetEffectiveResolution
        failing) -> LIBRARY_VERSION_CHANGED with data.versionChanges[] (before / after) and
        data.restore. Never success while a version differs.
        Exactly one of -Placeholder / -All (LIBRARY_INVALID_ARGUMENT reason target). -Placeholder must
        be a placeholder in References ('#<name>'), else LIBRARY_NOT_FOUND (data.placeholders), a
        library reference of that name -> LIBRARY_INVALID_ARGUMENT reason not-placeholder.
        DryRun (default true): FreezePlaceholder is NOT called; data.targets[] with placeholder,
        effectiveResolution, the current projectResolution / frozen read from the .plcproj on disk,
        willFreezeTo (DefaultResolution when it names a version, else the effective version) and
        versionWillChange; a warning for every target whose willFreezeTo differs from the effective
        version, and for the targets -All skips (data.skipped).
        -All skips (data.skipped[] { placeholder; reason; detail }, not counted as notFrozen):
        reason implicit = no <PlaceholderReference> in the .plcproj; reason
        no-effective-resolution = nothing to compare with (also in data.skippedUnresolved).
        DryRun=false: backup of the .plcproj on disk into <solution dir>\.tcauto-backup\<timestamp>\
        (LIBRARY_BACKUP_FAILED = nothing changed), modal dialog check (IDE_MODAL_DIALOG),
        FreezePlaceholder(name) or FreezePlaceholder('') for -All, save (Invoke-TcPlcObjectSave),
        read back from disk: every checked target must have a <Resolution> with a version other than
        '*' (else LIBRARY_VERIFY_FAILED, data.notFrozen) equal to its effective version (above).
        Every failure after the call lists data.changed[] (placeholder, before, after: the
        <Resolution> texts that differ from the backup) and data.restore. XAE refusing the call ->
        PLACEHOLDER_FREEZE_FAILED (LIBRARY_NOT_FOUND for "not found").
    .PARAMETER Placeholder
        Placeholder to freeze, with or without the leading '#'. Not together with -All.
    .PARAMETER All
        Freeze every placeholder (FreezePlaceholder with an empty name). Not together with -Placeholder.
    .PARAMETER DryRun
        Default true: only report. false: back up, freeze, save and read back.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .OUTPUTS
        data: placeholder, all, dryRun, referencesPath, projectFile, targets[], notFrozen, skipped[],
        skippedUnresolved, pinned[], versionChanges[], changed[], restore, backupPath, backupFiles,
        warnings, projectSaved.
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

        $fmt = {
            param($i)
            if ($null -eq $i) { return $null }
            if ([string]::IsNullOrWhiteSpace([string]$i.distributor)) { return "$($i.libraryName), $($i.version)" }
            "$($i.libraryName), $($i.version) ($($i.distributor))"
        }
        $same = {
            param($a, $b)
            $null -ne $a -and $null -ne $b -and ([string]$a.libraryName).Trim() -ieq ([string]$b.libraryName).Trim() -and
            ([string]$a.version).Trim() -ieq ([string]$b.version).Trim() -and ([string]$a.distributor).Trim() -ieq ([string]$b.distributor).Trim()
        }
        # What FreezePlaceholder will fix the placeholder at: its DefaultResolution when that names a
        # version (measured 2026-10-31 with FreezePlaceholder(''), phase2-3.8.md P2), else the
        # effective version (DefaultResolution '*', measured 2026-10-31 with one placeholder).
        $predict = {
            param($t, $ent)
            $def = $t.defaultResolution
            if ($null -eq $def -and $null -ne $ent) {
                $pe = $ent.Placeholders[[string]$t.placeholderName]
                if ($null -ne $pe) { $def = ConvertFrom-TcLibraryResolution -Text $pe.defaultResolution }
            }
            if ($null -ne $def -and -not [string]::IsNullOrWhiteSpace([string]$def.version) -and [string]$def.version -ne '*') { return $def }
            $t.effectiveResolution
        }
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
        # phase2-3.8.md P3: a placeholder without <PlaceholderReference> (XAE adds it by itself) gets no <Resolution>
        $isImplicit = {
            param($t)
            if ($null -eq $entries) { return $false }
            $pe = $entries.Placeholders[[string]$t.placeholderName]
            $null -eq $pe -or -not [bool]$pe.declared
        }
        $skipped = [System.Collections.Generic.List[object]]::new()
        $checked = [System.Collections.Generic.List[object]]::new()
        foreach ($t in $targets) {
            if ($All -and (& $isImplicit $t)) {
                $skipped.Add([PSCustomObject]@{ placeholder = $t.placeholderName; reason = 'implicit'
                    detail = 'no <PlaceholderReference> in the .plcproj (added by XAE itself); XAE does not write its <Resolution> (measured 2026-10-31 4026 VS2022, #Tc3_GlobalTypes)' })
            }
            elseif ($All -and $null -eq $t.effectiveResolution) {
                $skipped.Add([PSCustomObject]@{ placeholder = $t.placeholderName; reason = 'no-effective-resolution'
                    detail = 'no EffectiveResolution to compare with; XAE froze such a placeholder at its DefaultResolution (measured 2026-10-31 4026 VS2022, visu placeholder)' })
            }
            else { $checked.Add($t) }
        }
        $unresolvedNames = @($skipped | Where-Object { $_.reason -eq 'no-effective-resolution' } | ForEach-Object { $_.placeholder })
        $targetInfo = @($targets | ForEach-Object {
                $d = & $describe $_ $entries
                $will = & $predict $_ $entries
                $d | Add-Member -NotePropertyName willFreezeTo -NotePropertyValue (& $fmt $will)
                $d | Add-Member -NotePropertyName versionWillChange -NotePropertyValue $(if ($null -eq $_.effectiveResolution -or $null -eq $will) { $null } else { -not (& $same $will $_.effectiveResolution) })
                $d
            })
        $data | Add-Member -NotePropertyName targets -NotePropertyValue $targetInfo
        $data | Add-Member -NotePropertyName skipped -NotePropertyValue $skipped.ToArray()

        if ($DryRun) {
            $w = [System.Collections.Generic.List[string]]::new()
            if ($null -ne $locateError) { $w.Add("the .plcproj could not be read ($locateError); DryRun=false would return LIBRARY_BACKUP_FAILED") }
            foreach ($ti in @($targetInfo | Where-Object { $_.versionWillChange -eq $true })) {
                $w.Add("'$($ti.placeholder)': FreezePlaceholder is expected to fix it at its DefaultResolution '$($ti.willFreezeTo)', not at the effective '$(& $fmt $ti.effectiveResolution)' (measured 2026-10-31 with -All); DryRun=false pins it back with SetEffectiveResolution (not measured) and returns LIBRARY_VERSION_CHANGED when the version still differs")
            }
            if ($unresolvedNames.Count -gt 0) {
                $w.Add("no EffectiveResolution: $($unresolvedNames -join ', '). XAE froze such a placeholder at its DefaultResolution (measured 2026-10-31 4026 VS2022 with -All); DryRun=false does not version-check them (data.skipped)")
                $data | Add-Member -NotePropertyName skippedUnresolved -NotePropertyValue $unresolvedNames
            }
            $impl = @($skipped | Where-Object { $_.reason -eq 'implicit' } | ForEach-Object { $_.placeholder })
            if ($impl.Count -gt 0) { $w.Add("no <PlaceholderReference> in the .plcproj, skipped: $($impl -join ', ') (data.skipped)") }
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
        $backupFile = @($data.backupFiles)[0]
        $restore = "copy '$backupFile' over '$projectFile', then Reset-TcSolution (docs/troubleshooting.md, editing project files on disk; not measured for this case)"

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
                $data | Add-Member -NotePropertyName restore -NotePropertyValue $restore -Force
                $res = New-TcLibraryFailure -Code 'PLACEHOLDER_FREEZE_FAILED' -Data $data -Message "FreezePlaceholder '$arg' failed: $text.$why"
                return Register-TcCodeChange -Result $res -Change "$change [failed after FreezePlaceholder]"
            }
            throw
        }

        # --- readback: FreezePlaceholder changes only the .plcproj, so save it and read it from disk
        $what = "Frozen placeholder '$(if ($All) { '<all>' } else { $arg })'"
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What $what -Done 'changed'
        if ($null -ne $save.Error) {
            $data | Add-Member -NotePropertyName restore -NotePropertyValue $restore -Force
            return Register-TcCodeChange -Result $save.Error -Change "$change [frozen, project file not saved]"
        }
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        $after = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)

        # placeholders whose frozen version is not the effective version read before the call
        $versionCheck = {
            param($ent)
            foreach ($t in $checked) {
                if ($null -eq $t.effectiveResolution) { continue }
                $pe = $ent.Placeholders[[string]$t.placeholderName]
                if ($null -eq $pe -or -not $pe.frozen) { continue }
                $now = ConvertFrom-TcLibraryResolution -Text $pe.resolution
                if (-not (& $same $now $t.effectiveResolution)) {
                    [PSCustomObject]@{ placeholder = $t.placeholderName; before = (& $fmt $t.effectiveResolution); after = $pe.resolution; target = $t.effectiveResolution }
                }
            }
        }
        $moved = @(& $versionCheck $after)
        $pinned = [System.Collections.Generic.List[object]]::new()
        $pinErrors = @{}
        $notFrozenNow = @($checked | ForEach-Object { & $describe $_ $after } | Where-Object { -not $_.frozen })
        if ($moved.Count -gt 0 -and $notFrozenNow.Count -eq 0) {
            foreach ($mv in $moved) {
                $e = $mv.target
                $n = [string]$mv.placeholder
                try {
                    # SetEffectiveResolution(placeholderName, libName, version, distributor): InfoSys
                    # https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21841216267.html (not measured)
                    Invoke-TcComRetry -OperationName "SetEffectiveResolution '$n'" -ScriptBlock {
                        $null = $refs.SetEffectiveResolution($n, [string]$e.libraryName, [string]$e.version, [string]$e.distributor)
                    }
                    $pinned.Add($n)
                }
                catch {
                    if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
                    $pinErrors[$n] = Get-TcLibraryErrorText -ErrorRecord $_
                }
            }
            if ($pinned.Count -gt 0) {
                $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -What "$what, pinned back" -Done 'changed'
                if ($null -ne $save.Error) {
                    $data | Add-Member -NotePropertyName restore -NotePropertyValue $restore -Force
                    return Register-TcCodeChange -Result $save.Error -Change "$change [frozen and pinned, project file not saved]"
                }
                $data.projectSaved = $save.Saved
                $after = Get-TcPlcProjectLibraryEntries -Path ([string]$save.Saved.plcproj)
                $moved = @(& $versionCheck $after)
            }
        }
        $data | Add-Member -NotePropertyName pinned -NotePropertyValue $pinned.ToArray()

        $data.targets = @($targets | ForEach-Object { & $describe $_ $after })
        $notFrozen = @($checked | ForEach-Object { & $describe $_ $after } | Where-Object { -not $_.frozen } | ForEach-Object { $_.placeholder })
        $data | Add-Member -NotePropertyName notFrozen -NotePropertyValue $notFrozen
        $data | Add-Member -NotePropertyName skippedUnresolved -NotePropertyValue $unresolvedNames
        foreach ($s in @($skipped | Where-Object { $_.reason -eq 'no-effective-resolution' })) {
            $pe = $after.Placeholders[[string]$s.placeholder]
            $s | Add-Member -NotePropertyName projectResolution -NotePropertyValue $(if ($null -ne $pe) { $pe.resolution } else { $null })
        }
        if ($unresolvedNames.Count -gt 0) {
            $data.warnings = @(@($data.warnings) + @("not version-checked, no EffectiveResolution before the call: $($unresolvedNames -join ', '); data.skipped[].projectResolution is what XAE wrote"))
        }
        # what is now different from the backup (for every failure below)
        $changed = [System.Collections.Generic.List[object]]::new()
        foreach ($k in @($after.Placeholders.Keys)) {
            $old = if ($null -ne $entries) { $entries.Placeholders[$k] } else { $null }
            $oldRes = if ($null -ne $old) { $old.resolution } else { $null }
            if ([string]$oldRes -ne [string]$after.Placeholders[$k].resolution) {
                $changed.Add([PSCustomObject]@{ placeholder = $k; before = $oldRes; after = $after.Placeholders[$k].resolution })
            }
        }
        if ($notFrozen.Count -gt 0) {
            $data | Add-Member -NotePropertyName changed -NotePropertyValue $changed.ToArray()
            $data | Add-Member -NotePropertyName restore -NotePropertyValue $restore -Force
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERIFY_FAILED' -Reason 'not-frozen' -Data $data `
                -Message "FreezePlaceholder returned, but '$($save.Saved.plcproj)' read back from disk has no fixed version for: $($notFrozen -join ', '). The project WAS changed and saved for $($changed.Count) placeholder(s) (data.changed); the .plcproj before the call is '$backupFile'."
            return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
        }
        if ($moved.Count -gt 0) {
            $vc = @($moved | ForEach-Object {
                    [PSCustomObject]@{ placeholder = $_.placeholder; before = $_.before; after = $_.after
                        pinCalled = $pinned.Contains([string]$_.placeholder); pinError = $(if ($pinErrors.ContainsKey([string]$_.placeholder)) { $pinErrors[[string]$_.placeholder] } else { $null }) }
                })
            $data | Add-Member -NotePropertyName versionChanges -NotePropertyValue $vc
            $data | Add-Member -NotePropertyName changed -NotePropertyValue $changed.ToArray()
            $data | Add-Member -NotePropertyName restore -NotePropertyValue $restore -Force
            $res = New-TcLibraryFailure -Code 'LIBRARY_VERSION_CHANGED' -Data $data `
                -Message "FreezePlaceholder fixed $($vc.Count) placeholder(s) at another version than the one in effect before the call: $(($vc | ForEach-Object { "$($_.placeholder) '$($_.before)' -> '$($_.after)'" }) -join '; '). The project was saved with these versions; the .plcproj before the call is '$backupFile'."
            return Register-TcCodeChange -Result $res -Change "$change [version changed]"
        }
        Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
    }
    catch {
        $res = New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'PLACEHOLDER_FREEZE_FAILED' -Data $data -Operation 'Lock-TcLibraryPlaceholder'
        if ($called) { return Register-TcCodeChange -Result $res -Change "$change [failed after FreezePlaceholder]" }
        $res
    }
}
