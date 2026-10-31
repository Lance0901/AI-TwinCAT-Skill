function Add-TcPlcTask {
    <#
    .SYNOPSIS
        Adds a PLC task: a real-time task TIRT^<Name> with CycleTimeUs / Priority plus the PLC task object '<Plc> Project^<Name>' linked to it. Dry-run by default; rolls back what it created when a step fails.
    .DESCRIPTION
        Two objects, created in this order (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built
        client, openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.5):
          1. TIRT^<Name>: New-TcTreeItem -Path TIRT -SubType 1 (task without process image, TE1000
             Automation Interface manual v1.7.0 6.3.1 p.196).
          2. CycleTime / Priority: Set-TcTreeItemXml -Path TIRT^<Name> with
             <TreeItem><TaskDef><CycleTime>..</CycleTime><Priority>..</Priority></TaskDef></TreeItem>;
             CycleTime is in 100 ns units, so CycleTimeUs * 10 (20000 = 2 ms; measured 2026-10-30
             4026 VS2022 XAE 3.1.4026.18, self-built client, task 2.1). Priority only when given.
          3. '<Plc> Project^<Name>': New-TcTreeItem -Path '<Plc> Project' -SubType 621. XAE links it to
             the TIRT task of the same name by itself (LinkedTask = TIRT^<Name>) and writes <Name>.TcTTO;
             without that TIRT task XAE refuses: "No task '<Name>' found in Realtime-Settings!"
             (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client).
          4. Readback: TIRT^<Name> exists with TaskDef/CycleTime (and Priority) as requested,
             '<Plc> Project^<Name>' exists with ItemType 621 and PlcTaskDef/LinkedTask = TIRT^<Name>.
          5. Save (as Add-TcPou, #76): without it the .tsproj / .plcproj kept no trace of the task and
             ResetSolution dropped it (measured 2026-10-31 4026 VS2022, registered tcauto,
             verification/phase2-3.8.md P4). Invoke-TcPlcObjectSave (DTE Project.Save), then the project file
             (.plcproj) read back from disk must list <Compile Include="<Name>.TcTTO"> (else
             PROJECT_SAVE_FAILED / IDE_MODAL_DIALOG / PROJECT_SAVE_TIMEOUT, objects kept in XAE memory
             as with Add-TcPou) and the .tsproj a <Task><Name><Name></Name> (else TASK_VERIFY_FAILED
             step save-verify, rolled back, then saved again: the .plcproj read back must no longer
             list <Name>.TcTTO, else data.rolledBack = false and data.diskState). A <Task File=...>
             entry is read back from that file (not measured). data.projectSaved.
             Add-TcTaskProgram / Remove-TcTaskProgram need no save: CreateChild / DeleteChild 650
             rewrite <task>.TcTTO on disk at once (measured 2026-10-31, phase2-probe.md 3.5).
        Each step uses the generic tree cmdlets with their backup, modal dialog check and readback.
        Checks before anything is created: -Name non-empty without '^'; CycleTimeUs > 0 and at most
        214748364 (INVALID_PARAMS; XAE itself stores 0 and negative values, measured 2026-10-30 4026
        VS2022 XAE 3.1.4026.18, self-built client, task 2.1);
        no TIRT task and no object below '<Plc> Project' with that name (case-insensitive), else
        TASK_ALREADY_EXISTS (data.existingIn; the hint differs when only TIRT has the name).
        A failed step: what this call created is deleted again (Remove-TcTreeItem on the path the
        generic cmdlet reported as created (data.createdPath), PLC task first, -AllowNoExport because
        it is the object just created); when the PLC task cannot be deleted the TIRT task it is linked
        to is left alone (rollback code SKIPPED_DEPENDENT: delete the PLC task first). data.step,
        data.stepError, data.steps, data.rollback[] (path, removed, code, message), data.rolledBack;
        also on an exception. Code TASK_CREATE_FAILED
        (step tirt-create / cycle-time / plc-create) or TASK_VERIFY_FAILED (step verify);
        IDE_MODAL_DIALOG / IDE_BUSY / IDE_CRASHED / PLC_LOGGED_IN keep their code.
        DryRun (default true): nothing is created; data.plannedSteps, data.xml, data.cycleTime.
        BUILD_REQUIRED: recorded (code-changed) as soon as a CreateChild / ConsumeXml was called
        (data.writeCalled of the generic cmdlet); a request refused before (modal dialog, checks)
        records nothing.
        CycleCount is only visible online, so it is not checked here: after Enable-TcConfig -Force,
        read 'TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName' to find n, then
        'TwinCAT_SystemInfoVarList._TaskInfo[n].CycleCount' twice with Read-TcVariable; it must
        increase. n is the task index inside the PLC (1-based), not the order below TIRT; CycleCount
        counts the cycles of the underlying system task (InfoSys PlcTaskSystemInfo,
        https://infosys.beckhoff.com/content/1033/tc3_plc_intro/714821259.html). data.verifyHint says
        the same in one sentence. Whether a cycle time that is no multiple of the base time is adjusted
        is not measured. Link a program with Add-TcTaskProgram.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Name
        Task name, used for the TIRT task and the PLC task object (e.g. FastTask).
    .PARAMETER CycleTimeUs
        Cycle time in microseconds (> 0), e.g. 1000 = 1 ms.
    .PARAMETER Priority
        Optional task priority (TaskDef/Priority); XAE's default is kept when omitted.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER DryRun
        Default true: only check and report the plan. false: create, set, read back.
    .EXAMPLE
        Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -Priority 10
    .EXAMPLE
        Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$CycleTimeUs,

        [Parameter()]
        [int]$Priority,

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $hasPriority = $PSBoundParameters.ContainsKey('Priority')
    $data = [PSCustomObject]@{ name = $Name; cycleTimeUs = $CycleTimeUs; priority = $(if ($hasPriority) { $Priority } else { $null }); dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must be a non-empty name without '^' (got '$Name'); nothing was created."
    }
    if ($CycleTimeUs -le 0 -or $CycleTimeUs -gt $script:TcTaskMaxCycleTimeUs) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-CycleTimeUs must be between 1 and $($script:TcTaskMaxCycleTimeUs) (got $CycleTimeUs); nothing was created."
    }
    $cycleTime = ConvertTo-TcTaskCycleTime -CycleTimeUs $CycleTimeUs
    $data | Add-Member -NotePropertyName cycleTime -NotePropertyValue $cycleTime
    $xml = "<TreeItem><TaskDef><CycleTime>$cycleTime</CycleTime>$(if ($hasPriority) { "<Priority>$Priority</Priority>" })</TaskDef></TreeItem>"
    $data | Add-Member -NotePropertyName xml -NotePropertyValue $xml

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $change = "Add-TcPlcTask $Name"
    $called = $false
    $created = [System.Collections.Generic.List[string]]::new()
    $steps = [System.Collections.Generic.List[object]]::new()
    # Rollback: delete what this call created, PLC task first (-AllowNoExport: the object was created
    # by this call a moment ago, there is nothing of the user's to keep). Never throws.
    $doRollback = {
        $rb = [System.Collections.Generic.List[object]]::new()
        $plcLeft = $false
        for ($i = $created.Count - 1; $i -ge 0; $i--) {
            $p = $created[$i]
            # the TIRT task is still linked from a PLC task that could not be deleted: leave it
            if ($plcLeft -and $p -like 'TIRT^*') {
                $rb.Add([PSCustomObject]@{ path = $p; removed = $false; code = 'SKIPPED_DEPENDENT'
                        message = 'not deleted: the PLC task linked to it is still there; delete the PLC task first, then this TIRT task' })
                continue
            }
            $rr = $null
            try { $rr = Remove-TcTreeItem -Path $p -ConfirmName (Get-TcTreePathLeaf -Path $p) -DryRun $false -AllowNoExport }
            catch { $rr = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'TREEITEM_DELETE_FAILED'; message = $_.Exception.Message } } }
            $rb.Add([PSCustomObject]@{
                    path    = $p
                    removed = [bool]$rr.success
                    code    = $(if ($rr.success) { $null } else { [string]$rr.error.code })
                    message = $(if ($rr.success) { $null } else { [string]$rr.error.message })
                })
            if (-not $rr.success -and $p -notlike 'TIRT^*') { $plcLeft = $true }
        }
        , $rb.ToArray()
    }
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $tirtPath = "TIRT^$Name"
        $plcPath = "$prjPath^$Name"
        $data | Add-Member -NotePropertyName plcProjectPath -NotePropertyValue $prjPath
        $data | Add-Member -NotePropertyName tirtTaskPath -NotePropertyValue $tirtPath
        $data | Add-Member -NotePropertyName plcTaskPath -NotePropertyValue $plcPath

        $existingIn = @()
        $tirt = Find-TcTreeItemNoThrow -SysManager $sm -Path 'TIRT'
        $tirtKids = if ($null -ne $tirt) { @(Get-TcTreeItemChildNames -Item $tirt) } else { @() }
        if ($null -ne (Find-TcTreeItemNoThrow -SysManager $sm -Path $tirtPath) -or @($tirtKids | Where-Object { $_ -ieq $Name }).Count -gt 0) { $existingIn += 'TIRT' }
        $prj = Find-TcTreeItemNoThrow -SysManager $sm -Path $prjPath
        $prjKids = if ($null -ne $prj) { @(Get-TcTreeItemChildNames -Item $prj) } else { @() }
        if ($null -ne (Find-TcTreeItemNoThrow -SysManager $sm -Path $plcPath) -or @($prjKids | Where-Object { $_ -ieq $Name }).Count -gt 0) { $existingIn += 'plc' }
        if ($existingIn.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingIn -NotePropertyValue $existingIn
            $where = (@($existingIn | ForEach-Object { if ($_ -eq 'TIRT') { "'TIRT'" } else { "'$prjPath'" } })) -join ' and '
            # Only TIRT: there is no PLC task of that name to reuse, so the hint is "pick another name".
            $hintKey = if (@($existingIn) -contains 'plc') { 'TASK_ALREADY_EXISTS' } else { 'TASK_ALREADY_EXISTS_TIRT' }
            return New-TcResult -Success $false -ErrorCode 'TASK_ALREADY_EXISTS' -Data $data `
                -ErrorMessage "A task or object named '$Name' already exists below $where; nothing was created." -Hint (Get-TcErrorHint -Code $hintKey)
        }
        $data | Add-Member -NotePropertyName plannedSteps -NotePropertyValue @(
            "CreateChild TIRT '$Name' SubType 1",
            "ConsumeXml $tirtPath $xml",
            "CreateChild '$prjPath' '$Name' SubType 621 (LinkedTask TIRT^$Name)",
            'readback',
            'Project.Save, read back .plcproj <Compile Include="$Name.TcTTO"> and .tsproj <Task><Name>')
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $failure = $null
        # path a generic cmdlet created: its data.createdPath when it exists, else the planned path
        $trackCreated = {
            param($Res, [string]$Planned)
            $cp = $null
            if ($null -ne $Res.PSObject.Properties['data'] -and $null -ne $Res.data -and $null -ne $Res.data.PSObject.Properties['createdPath']) { $cp = [string]$Res.data.createdPath }
            if (-not [string]::IsNullOrWhiteSpace($cp) -and $null -ne (Find-TcTreeItemNoThrow -SysManager $sm -Path $cp)) { $created.Add($cp) }
            elseif ($null -ne (Find-TcTreeItemNoThrow -SysManager $sm -Path $Planned)) { $created.Add($Planned) }
        }
        $record = {
            param([string]$Step, $Res)
            $steps.Add([PSCustomObject]@{ step = $Step; success = [bool]$Res.success; code = $(if ($Res.success) { $null } else { [string]$Res.error.code }) })
        }

        # 1. TIRT task
        $r1 = New-TcTreeItem -Path 'TIRT' -Name $Name -SubType 1 -DryRun $false
        & $record 'tirt-create' $r1
        $called = $called -or (Test-TcWriteCalled -Result $r1)
        & $trackCreated $r1 $tirtPath
        if ($r1.success) {
            if ([string]$r1.data.createdName -cne $Name) {
                $failure = @{ Step = 'tirt-create'; Code = 'TASK_CREATE_FAILED'; Message = "XAE named the TIRT task '$($r1.data.createdName)', not '$Name'"; Inner = $r1 }
            }
        }
        else {
            $failure = @{ Step = 'tirt-create'; Code = $null; Message = [string]$r1.error.message; Inner = $r1 }
        }

        # 2. CycleTime / Priority
        if ($null -eq $failure) {
            $r2 = Set-TcTreeItemXml -Path $tirtPath -Xml $xml -DryRun $false
            & $record 'cycle-time' $r2
            $called = $called -or (Test-TcWriteCalled -Result $r2)
            if (-not $r2.success) { $failure = @{ Step = 'cycle-time'; Code = $null; Message = [string]$r2.error.message; Inner = $r2 } }
        }

        # 3. PLC task object (XAE links it to TIRT^<Name>)
        if ($null -eq $failure) {
            $r3 = New-TcTreeItem -Path $prjPath -Name $Name -SubType $script:TcPlcTaskItemType -DryRun $false
            & $record 'plc-create' $r3
            $called = $called -or (Test-TcWriteCalled -Result $r3)
            & $trackCreated $r3 $plcPath
            if ($r3.success) {
                if ([string]$r3.data.createdName -cne $Name) {
                    $failure = @{ Step = 'plc-create'; Code = 'TASK_CREATE_FAILED'; Message = "XAE named the PLC task '$($r3.data.createdName)', not '$Name'"; Inner = $r3 }
                }
            }
            else {
                $failure = @{ Step = 'plc-create'; Code = $null; Message = [string]$r3.error.message; Inner = $r3 }
            }
        }

        # 4. readback
        if ($null -eq $failure) {
            $mism = [System.Collections.Generic.List[object]]::new()
            $tItem = Find-TcTreeItemNoThrow -SysManager $sm -Path $tirtPath
            if ($null -eq $tItem) { $mism.Add([PSCustomObject]@{ field = 'TIRT task'; expected = $tirtPath; actual = '(not found)' }) }
            else {
                $ct = Get-TcTreeItemXmlValue -Item $tItem -XPath 'TreeItem/TaskDef/CycleTime' -Path $tirtPath
                $data | Add-Member -NotePropertyName readCycleTime -NotePropertyValue $ct
                if ([string]$ct -ne [string]$cycleTime) { $mism.Add([PSCustomObject]@{ field = 'TaskDef/CycleTime'; expected = [string]$cycleTime; actual = [string]$ct }) }
                if ($hasPriority) {
                    $pr = Get-TcTreeItemXmlValue -Item $tItem -XPath 'TreeItem/TaskDef/Priority' -Path $tirtPath
                    $data | Add-Member -NotePropertyName readPriority -NotePropertyValue $pr
                    if ([string]$pr -ne [string]$Priority) { $mism.Add([PSCustomObject]@{ field = 'TaskDef/Priority'; expected = [string]$Priority; actual = [string]$pr }) }
                }
            }
            $pItem = Find-TcTreeItemNoThrow -SysManager $sm -Path $plcPath
            if ($null -eq $pItem) { $mism.Add([PSCustomObject]@{ field = 'PLC task'; expected = $plcPath; actual = '(not found)' }) }
            else {
                $pt = try { [int]$pItem.ItemType } catch { -1 }
                if ($pt -ne $script:TcPlcTaskItemType) { $mism.Add([PSCustomObject]@{ field = 'PLC task ItemType'; expected = '621'; actual = [string]$pt }) }
                $lt = Get-TcTreeItemXmlValue -Item $pItem -XPath 'TreeItem/PlcTaskDef/LinkedTask' -Path $plcPath
                if ([string]::IsNullOrEmpty($lt)) { $lt = try { [string]$pItem.LinkedTask } catch { $null } }
                $data | Add-Member -NotePropertyName linkedTask -NotePropertyValue $lt
                if (-not [string]::Equals([string]$lt, $tirtPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mism.Add([PSCustomObject]@{ field = 'PlcTaskDef/LinkedTask'; expected = $tirtPath; actual = [string]$lt })
                }
            }
            & $record 'verify' ([PSCustomObject]@{ success = ($mism.Count -eq 0); error = [PSCustomObject]@{ code = 'TASK_VERIFY_FAILED' } })
            if ($mism.Count -gt 0) {
                $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism.ToArray()
                $failure = @{ Step = 'verify'; Code = 'TASK_VERIFY_FAILED'; Inner = $null
                    Message = 'the readback differs: ' + (($mism | ForEach-Object { "$($_.field) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; ') }
            }
        }

        # 5. save (phase2-3.8.md P4, as #76 for Add-TcPou): CreateChild 621 writes <Name>.TcTTO at
        # once, but the TIRT task in the .tsproj and <Compile Include="<Name>.TcTTO"> in the .plcproj
        # only live in XAE memory until the project is saved (measured 2026-10-31 4026 VS2022,
        # registered tcauto: ResetSolution dropped the tasks). Save, then read both files back.
        if ($null -eq $failure) {
            $save = Invoke-TcPlcObjectSave -ObjectPath $plcPath -ExpectFile "$Name.TcTTO" -What "PLC task '$Name'"
            & $record 'save' ([PSCustomObject]@{ success = ($null -eq $save.Error); error = $(if ($null -ne $save.Error) { $save.Error.error } else { $null }) })
            if ($null -ne $save.Error) {
                # as Add-TcPou: the objects stay in XAE memory, the error says how to save them
                $res = $save.Error
                Copy-TcDataFields -From $data -To $res.data -Names @('name', 'cycleTimeUs', 'priority', 'tirtTaskPath', 'plcTaskPath', 'plcProjectPath')
                $res.data | Add-Member -NotePropertyName steps -NotePropertyValue $steps.ToArray() -Force
                return Register-TcCodeChange -Result $res -Change "$change [created, project file not saved]"
            }
            $data | Add-Member -NotePropertyName projectSaved -NotePropertyValue $save.Saved
            $ts = Test-TcTsProjHasTask -Path ([string]$save.Saved.tsproj) -Name $Name
            if ($ts.Separate -and $ts.Found) {
                $old = if ($null -ne $data.PSObject.Properties['warnings']) { @($data.warnings) } else { @() }
                $data | Add-Member -NotePropertyName warnings -NotePropertyValue @($old + @("the .tsproj stores task '$Name' in its own file '$($ts.File)' (<Task File=...>, not measured); read back from there")) -Force
            }
            elseif (-not $ts.Found) {
                $why = if ($ts.Error) { "could not be read ($($ts.Error))" } else { 'has no <Task><Name>' + $Name + '</Name>' }
                $data | Add-Member -NotePropertyName mismatches -NotePropertyValue @([PSCustomObject]@{ field = '.tsproj TIRT task'; expected = $Name; actual = "'$($save.Saved.tsproj)' $why" }) -Force
                $failure = @{ Step = 'save-verify'; Code = 'TASK_VERIFY_FAILED'; Inner = $null
                    Message = "the project was saved, but '$($save.Saved.tsproj)' read back from disk $why" }
            }
        }
        $data | Add-Member -NotePropertyName steps -NotePropertyValue $steps.ToArray()

        if ($null -eq $failure) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $data | Add-Member -NotePropertyName verifyHint -NotePropertyValue "After Enable-TcConfig -Force, find n with Read-TcVariable -Path 'TwinCAT_SystemInfoVarList._TaskInfo[n].TaskName' (n = task index inside the PLC, not the TIRT order) and read 'TwinCAT_SystemInfoVarList._TaskInfo[n].CycleCount' twice: it must increase."
            return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
        }

        $rollback = & $doRollback
        $rolledBack = (@($rollback | Where-Object { -not $_.removed }).Count -eq 0)
        # review S1: after save-verify the project file on disk already lists <Name>.TcTTO. Save again
        # after the rollback and read the .plcproj back; when that cannot be confirmed the rollback
        # is not complete (data.diskState).
        $diskHint = $null
        if ($failure.Step -eq 'save-verify') {
            $ds = [ordered]@{ plcproj = $null; tcttoListed = $null; saved = $false; saveError = $null }
            $s2 = Invoke-TcPlcObjectSave -ObjectPath $prjPath -What "rollback of PLC task '$Name'" -Done 'removed'
            if ($null -ne $s2.Error) { $ds.saveError = [string]$s2.Error.error.message }
            else {
                $ds.saved = $true
                $ds.plcproj = [string]$s2.Saved.plcproj
                try { $ds.tcttoListed = [bool](Test-TcPlcProjectHasFile -Content (Get-TcPlcProjectContent -Path $ds.plcproj) -File "$Name.TcTTO") }
                catch { $ds.tcttoListed = $null; $ds.saveError = "readback: $($_.Exception.Message)" }
            }
            $data | Add-Member -NotePropertyName diskState -NotePropertyValue ([PSCustomObject]$ds)
            if (-not $ds.saved -or $ds.tcttoListed -ne $false) {
                $rolledBack = $false
                $diskHint = Get-TcErrorHint -Code 'TASK_VERIFY_FAILED_DISK'
            }
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $false -Force
        $data | Add-Member -NotePropertyName step -NotePropertyValue $failure.Step
        $stepError = $null
        if ($null -ne $failure.Inner -and -not $failure.Inner.success) { $stepError = $failure.Inner.error }
        $data | Add-Member -NotePropertyName stepError -NotePropertyValue $stepError
        $data | Add-Member -NotePropertyName rollback -NotePropertyValue $rollback
        $data | Add-Member -NotePropertyName rolledBack -NotePropertyValue $rolledBack
        $code = $failure.Code
        if ($null -eq $code) {
            $innerCode = if ($null -ne $stepError) { [string]$stepError.code } else { '' }
            $code = if ($script:TcTreeItemPassThroughCodes -contains $innerCode) { $innerCode } else { 'TASK_CREATE_FAILED' }
        }
        $rbText = Format-TcPlcTaskRollback -Rollback $rollback
        if ($null -ne $diskHint) { $rbText += "; the .plcproj on disk may still list '$Name.TcTTO' (data.diskState)" }
        $res = New-TcResult -Success $false -ErrorCode $code -Data $data `
            -ErrorMessage "Add-TcPlcTask stopped at step $($failure.Step): $($failure.Message); $rbText." -Hint $(if ($null -ne $diskHint) { $diskHint } else { Get-TcErrorHint -Code $code })
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed at $($failure.Step)]" }
        return $res
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TASK_CREATE_FAILED' -Data $data -Operation 'Add-TcPlcTask'
        $res.data | Add-Member -NotePropertyName steps -NotePropertyValue $steps.ToArray() -Force
        if ($created.Count -gt 0) {
            $rb = & $doRollback
            $res.data | Add-Member -NotePropertyName rollback -NotePropertyValue $rb -Force
            $res.data | Add-Member -NotePropertyName rolledBack -NotePropertyValue (@($rb | Where-Object { -not $_.removed }).Count -eq 0) -Force
            $res.error.message = "$($res.error.message); $(Format-TcPlcTaskRollback -Rollback $rb)"
        }
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
        return $res
    }
}
