function Add-TcTaskProgram {
    <#
    .SYNOPSIS
        Links a PROGRAM to a PLC task (CreateChild 650 below '<Plc> Project^<PlcTask>'). Checks first that the name is an existing PROGRAM, exactly; dry-run by default; backs up the task's .TcTTO and reads back.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.5.3 p.227-228: CreateChild('<ProgramName>', 650) on
        the PLC task object 'TIPC^<Plc>^<Plc> Project^<PlcTask>' (ItemType 621); the child name must be
        the program name. XAE does NOT check it: the same name twice, another case, a missing name, a
        function block and a GVL were all accepted and written to <task>.TcTTO at once; only
        CheckAllObjects / the build then failed (C0046 / C0035 / C0080 / C0036 in PlcTask.TcTTO)
        (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.5).
        So the module checks before anything is created:
          - the PLC task exists and is a PLC task (ItemType 621), else TASK_NOT_FOUND (data.plcTasks);
          - the program is found in that PLC project (Resolve-TcPouPath) and is a PROGRAM (ItemType 602,
            Get-TcPlcObjectKind) with exactly that name, case included, else TASK_PROGRAM_INVALID with
            data.reason not-found / not-a-program / case-mismatch (data.actualName); several objects of
            that name -> POU_AMBIGUOUS;
          - no program call of that name (case-insensitive: IEC names are not case-sensitive) is below
            the task yet, else TASK_PROGRAM_ALREADY_LINKED (data.linkedPrograms).
        DryRun (default true): nothing is created; data.plannedPath, data.linkedPrograms.
        DryRun=false: New-TcTreeItem -Path <task> -Name <ProgramName> -SubType 650: ProduceXml backup of
        the task plus a copy of its <task>.TcTTO (data.backupPath / backupFiles), IDE_MODAL_DIALOG when a
        dialog is open (nothing created), CreateChild, then the new child is looked up again and the
        task's children must be the old ones plus this one (TREEITEM_VERIFY_FAILED otherwise); the child
        must be ItemType 650. data.verified = true, data.linkedPrograms = the children afterwards.
        BUILD_REQUIRED: recorded (code-changed) as soon as CreateChild was called, success or failure.
        Remove the link with Remove-TcTaskProgram. Run Test-TcPlcProject or Build-TcProject afterwards.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER ProgramName
        Name of the PROGRAM, exactly as declared (e.g. MAIN).
    .PARAMETER PlcTask
        Name of the PLC task below '<Plc> Project' (default PlcTask).
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER DryRun
        Default true: only check and report the plan. false: back up, create, read back.
    .EXAMPLE
        Add-TcTaskProgram -ProgramName MAIN
    .EXAMPLE
        Add-TcTaskProgram -ProgramName PRG_Fast -PlcTask FastTask -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ProgramName,

        [Parameter()]
        [string]$PlcTask = 'PlcTask',

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ programName = $ProgramName; plcTask = $PlcTask; dryRun = $DryRun }
    foreach ($pair in @(@('ProgramName', $ProgramName), @('PlcTask', $PlcTask))) {
        if ([string]::IsNullOrWhiteSpace($pair[1]) -or $pair[1].Contains('^')) {
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-$($pair[0]) must be a non-empty name without '^' (got '$($pair[1])'); nothing was linked."
        }
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $change = "Add-TcTaskProgram $ProgramName -> $PlcTask"
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $data | Add-Member -NotePropertyName plcProjectPath -NotePropertyValue $prjPath
        $task = Resolve-TcPlcTaskNode -SysManager $sm -PlcProjectPath $prjPath -PlcTask $PlcTask -Data $data
        if ($null -ne $task.Result) { return $task.Result }
        $data | Add-Member -NotePropertyName taskPath -NotePropertyValue $task.Path
        $linked = @(Get-TcTreeItemChildNames -Item $task.Item)
        $data | Add-Member -NotePropertyName linkedPrograms -NotePropertyValue $linked

        $target = Test-TcTaskProgramTarget -SysManager $sm -PlcProjectPath $prjPath -ProgramName $ProgramName -Data $data
        if ($null -ne $target.Result) { return $target.Result }

        $existing = @($linked | Where-Object { $_ -ieq $ProgramName })
        if ($existing.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingLink -NotePropertyValue $existing[0]
            return New-TcResult -Success $false -ErrorCode 'TASK_PROGRAM_ALREADY_LINKED' -Data $data `
                -ErrorMessage "'$($task.Path)' already calls '$($existing[0])'; nothing was linked (XAE would add a second call and the program would run twice per cycle)." `
                -Hint (Get-TcErrorHint -Code 'TASK_PROGRAM_ALREADY_LINKED')
        }
        $plannedPath = "$($task.Path)^$ProgramName"
        $data | Add-Member -NotePropertyName plannedPath -NotePropertyValue $plannedPath
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $inner = New-TcTreeItem -Path $task.Path -Name $ProgramName -SubType $script:TcPlcProgRefItemType -DryRun $false
        $innerData = if ($null -ne $inner.PSObject.Properties['data']) { $inner.data } else { $null }
        Copy-TcDataFields -From $innerData -To $data -Names @('backupPath', 'backupFiles', 'warnings', 'createdPath', 'itemType', 'parentUnchanged', 'unexpectedChanges', 'missingChildren', 'addedChildren')
        $code = if ($inner.success) { $null } else { [string]$inner.error.code }
        # CreateChild was called: success, or it failed in / after the call (New-TcTreeItem codes)
        $called = $inner.success -or @('TREEITEM_CREATE_FAILED', 'TREEITEM_VERIFY_FAILED') -contains $code -or ($null -ne $innerData -and $null -ne $innerData.PSObject.Properties['buildRequired'])
        if (-not $inner.success) {
            $data | Add-Member -NotePropertyName step -NotePropertyValue 'create' -Force
            $p = @{ Success = $false; ErrorCode = $code; ErrorMessage = "Add-TcTaskProgram: $($inner.error.message)"; Data = $data }
            if (-not [string]::IsNullOrWhiteSpace([string]$inner.error.hint)) { $p['Hint'] = [string]$inner.error.hint }
            $res = New-TcResult @p
            if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
            return $res
        }
        $after = @(Get-TcTreeItemChildNames -Item $task.Item)
        $data.linkedPrograms = $after
        $itemType = $innerData.itemType
        if ([int]$itemType -ne $script:TcPlcProgRefItemType -or @($after | Where-Object { $_ -ceq $ProgramName }).Count -ne 1) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false -Force
            $res = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "CreateChild 650 returned, but '$plannedPath' reads back as ItemType $itemType (expected 650) or the task does not list exactly one '$ProgramName'." `
                -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true -Force
        Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_READ_FAILED' -Data $data -Operation 'Add-TcTaskProgram'
    }
}
