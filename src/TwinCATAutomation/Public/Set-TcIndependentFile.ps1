function Set-TcIndependentFile {
    <#
    .SYNOPSIS
        Turns "Independent Project File" (ITcSmTreeItem6.SaveInOwnFile) of a tree item on or off, saves the project and checks the .xti on disk. Dry-run by default; backs up BEFORE the setter (it writes the .xti at once).
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 5.2.4 p.62-63 / 6.3.9 p.210 (InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html): for items
        that cannot be stored in their own file "the setters do nothing and return S_OK" (p.62).
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built
        client (openspec/changes/complete-automation-interface/verification/phase3-probe.md
        questions 20-21): PLC project, NC axis, NC task, TcCOM instance and (4024) I/O device read
        back True; PlcTask, Axes, TINC and TIRR answer S_OK and read back False. Setting True writes
        the .xti at once (before any save); False + Project.Save deletes it. The ProduceXml has no
        field for it.
        Steps: getter (already the requested value: success, data.written = false); .xti snapshot of
        the solution folder; the .tsproj to save afterwards (Find-TcSolutionTsProjFile, phase3-4.6 B2:
        DTE Solution.Projects FullName, else the .tsproj the .sln references, else the only .tsproj
        below the solution folder; data.tsproj, data.tsprojSource = dte / sln / folder); a source
        that names several -> INDEPENDENT_FILE_TSPROJ_AMBIGUOUS (data.tsprojFiles), nothing changed.
        DryRun stops here (data.expectedFile, data.existingFiles, data.tsproj).
        DryRun=false: backup (ProduceXml, the .tsproj and the item's existing .xti; data.backupPath /
        backupFiles) BEFORE the setter, IDE_MODAL_DIALOG check, setter, getter read back - unchanged
        -> INDEPENDENT_FILE_UNSUPPORTED (XAE ignored it; nothing changed); then Project.Save with a
        deadline (Invoke-TcProjectSaveWithDeadline, so the .tsproj references / embeds the item;
        failure -> INDEPENDENT_FILE_SAVE_FAILED, the change stays in XAE memory), then the disk:
        on: the expected '<name>.xti' ('NC.xti' for the NC task) below a _Config folder must be new or
        rewritten (size / LastWriteTime changed; data.writtenFiles); off: the expected .xti found before must be gone
        (data.removedFiles; XAE also deletes its .bak). Otherwise INDEPENDENT_FILE_VERIFY_FAILED.
        Not needed afterwards: Reset-TcSolution (XAE wrote the files itself). The PLC mappings move
        into the PLC .xti when the PLC project is independent (InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_userinterface/7738192779.html, measured).
        BUILD_REQUIRED (code-changed) is recorded once the setter was called.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Path
        Full tree path, e.g. 'TIPC^MyPlc', 'TINC^NC-Task 1 SAF^Axes^Axis 1', 'TIRC^TcCOM Objects^<name> (<type>)'.
    .PARAMETER Enabled
        true = store the item in its own .xti, false = back into the parent file.
    .PARAMETER DryRun
        Default true: only report the plan. false: back up, set, save, check the disk.
    .EXAMPLE
        Set-TcIndependentFile -Path 'TINC^NC-Task 1 SAF^Axes^Axis 1' -Enabled $true
    .EXAMPLE
        Set-TcIndependentFile -Path 'TIPC^MyPlc' -Enabled $false -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [bool]$Enabled,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ path = $Path; enabled = $Enabled; dryRun = $DryRun }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = "Set-TcIndependentFile $Path $Enabled"
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $item = $r.Item
        $name = [string](Get-TcTreeItemPropertyNoThrow -Item $item -Name 'Name' -Default (Get-TcTreePathLeaf -Path $Path))
        $itemType = try { [int]$item.ItemType } catch { -1 }
        $cur = $null
        try { $cur = Invoke-TcComRetry -OperationName "SaveInOwnFile $Path" -ScriptBlock { $item.SaveInOwnFile } }
        catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $cur = $null }
        if ($null -eq $cur) {
            return New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_UNSUPPORTED' -Data $data `
                -ErrorMessage "'$Path' has no readable SaveInOwnFile (ITcSmTreeItem6); nothing was changed." -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_UNSUPPORTED')
        }
        $data | Add-Member -NotePropertyName previous -NotePropertyValue ([bool]$cur)
        if ([bool]$cur -eq $Enabled) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            return New-TcResult -Success $true -Data $data
        }
        $solutionDir = Get-TcTreeItemSolutionDir
        $expected = Get-TcIndependentFileName -Path $Path -Name $name -ItemType $itemType
        $before = Get-TcXtiSnapshot -SolutionDir $solutionDir
        $existing = @($before.Keys | Where-Object { [System.IO.Path]::GetFileName($_) -ieq $expected } | Sort-Object)
        $data | Add-Member -NotePropertyName expectedFile -NotePropertyValue $expected
        $data | Add-Member -NotePropertyName existingFiles -NotePropertyValue $existing
        # review S12: the project is saved after the setter, so the .tsproj must be known BEFORE anything changes
        $tsList = Find-TcSolutionTsProjFile -SolutionDir $solutionDir
        $data | Add-Member -NotePropertyName tsproj -NotePropertyValue $tsList.Single
        $data | Add-Member -NotePropertyName tsprojSource -NotePropertyValue $tsList.Source
        if ($null -eq $tsList.Single) {
            $data | Add-Member -NotePropertyName tsprojFiles -NotePropertyValue @($tsList.Files)
            $where = switch ([string]$tsList.Source) {
                'dte' { 'the solution loads' }
                'sln' { 'the .sln references' }
                'folder' { 'are below the solution folder (neither DTE nor the .sln named one)' }
                default { 'were found (no DTE project, no .sln reference, none below the solution folder)' }
            }
            return New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS' -Data $data `
                -ErrorMessage "$(@($tsList.Files).Count) .tsproj files $where; the one to save after the change is not known. Nothing was changed." -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_TSPROJ_AMBIGUOUS')
        }
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        # backup BEFORE the setter: setting True writes the .xti at once (phase3-probe.md question 20)
        $xml = Get-TcTreeItemXmlText -Item $item -Path $Path
        $bk = New-TcConfigBackup -Label $Path -Text $xml -DiskFiles (@($tsList.Single) + $existing) -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "SaveInOwnFile = $Enabled '$Path'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): dialog ruled out just above; the setter returned at once
        # in the probe (question 20). The save below has its own deadline.
        try { Invoke-TcComRetry -OperationName "SaveInOwnFile $Path" -ScriptBlock { $item.SaveInOwnFile = $Enabled } | Out-Null }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $res = New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_WRITE_FAILED' -Data $data -ErrorMessage "SaveInOwnFile = $Enabled on '$Path' failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_WRITE_FAILED')
            return Register-TcCodeChange -Result $res -Change "$change [failed]"
        }
        $now = $null
        try { $now = Invoke-TcComRetry -OperationName "SaveInOwnFile $Path" -ScriptBlock { $item.SaveInOwnFile } } catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $now = $null }
        $data | Add-Member -NotePropertyName readback -NotePropertyValue $now
        if ($null -eq $now -or [bool]$now -ne $Enabled) {
            $res = New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_UNSUPPORTED' -Data $data `
                -ErrorMessage "XAE accepted SaveInOwnFile = $Enabled on '$Path' but reads back '$now': this item cannot be stored in its own file (TE1000 5.2.4: the setter does nothing and returns S_OK)." -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_UNSUPPORTED')
            return Register-TcCodeChange -Result $res -Change "$change [unsupported]"
        }
        $save = Invoke-TcIndependentFileSave -TsProjFile $tsList.Single
        $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
        if ($null -ne $save.Error) {
            $res = New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_SAVE_FAILED' -Data $data `
                -ErrorMessage "SaveInOwnFile is $Enabled in XAE, but the project could not be saved: $($save.Error)" -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_SAVE_FAILED')
            return Register-TcCodeChange -Result $res -Change "$change [not saved]"
        }
        $after = Get-TcXtiSnapshot -SolutionDir $solutionDir
        $created = @($after.Keys | Where-Object { -not $before.ContainsKey($_) } | Sort-Object)
        $removed = @($before.Keys | Where-Object { -not $after.ContainsKey($_) } | Sort-Object)
        $data | Add-Member -NotePropertyName createdFiles -NotePropertyValue $created
        $data | Add-Member -NotePropertyName removedFiles -NotePropertyValue $removed
        $bad = $null
        if ($Enabled) {
            # review S12: the expected file below _Config must be new or rewritten (size / LastWriteTime);
            # another new .xti or an old untouched one does not count
            $written = @($after.Keys | Where-Object { [System.IO.Path]::GetFileName($_) -ieq $expected -and $_ -match '\\_Config\\' -and (-not $before.ContainsKey($_) -or $before[$_] -ne $after[$_]) })
            $data | Add-Member -NotePropertyName writtenFiles -NotePropertyValue $written
            if ($written.Count -eq 0) { $bad = "no '$expected' below a _Config folder was written (new or changed LastWriteTime)" }
        }
        else {
            $left = @($existing | Where-Object { $after.ContainsKey($_) })
            if ($left.Count -gt 0) { $bad = "'$($left -join "', '")' still exists after the save" }
            elseif ($existing.Count -eq 0) { Add-TcDataWarning -Data $data -Warning "no '$expected' was found before the change, so its removal could not be checked (the getter reads back False)" }
        }
        if ($null -ne $bad) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'INDEPENDENT_FILE_VERIFY_FAILED' -Data $data `
                -ErrorMessage "SaveInOwnFile reads back $Enabled and the project was saved, but $bad." -Hint (Get-TcErrorHint -Code 'INDEPENDENT_FILE_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "$change [failed at verify]"
        }
        $data | Add-Member -NotePropertyName written -NotePropertyValue $true
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'INDEPENDENT_FILE_WRITE_FAILED' -Data $data -Operation 'Set-TcIndependentFile'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
        return $res
    }
}
