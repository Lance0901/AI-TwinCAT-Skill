function Add-TcNcTask {
    <#
    .SYNOPSIS
        Adds the NC task below TINC (CreateChild SubType 1); a TINC holds only one, so an existing task returns NC_TASK_ALREADY_EXISTS. Dry-run by default.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.10.1 p.293: TINC.CreateChild("NC-Task", 1). Measured
        2026-11-01 4026 VS2022 XAE 3.1.4026.22 and 4024 XAE Shell 3.1.4024.71, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md question 1):
        TINC accepts ONE NC task; a second CreateChild(<any name>, 1) fails with 0x98510002 "Item
        already exists!". So the module looks at TINC first: a child with ItemType 1 there ->
        NC_TASK_ALREADY_EXISTS (data.existingTasks), CreateChild is not called. A 0x98510002 from XAE
        gives the same code.
        XAE appends ' SAF' to the name (manual comment p.293; the probe projects had
        'NC-Task 1 SAF'): data.taskPath / data.createdName are read back from the created item, a
        different name is a warning, not a failure. Building a task from scratch was not measured
        (both probe projects already had one).
        Uses New-TcTreeItem (backup of TINC, modal dialog check, readback of the parent and the child
        names). Afterwards '<task>^Axes' must exist (data.axesPath), else NC_TASK_VERIFY_FAILED and
        the created task is deleted again (data.rollback).
        BUILD_REQUIRED (code-changed) is recorded once CreateChild was called.
        DryRun (default true): nothing is created; data.plannedSteps.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Name
        Requested task name (default 'NC-Task 1'; XAE may append ' SAF').
    .PARAMETER DryRun
        Default true: only check and report the plan. false: create and read back.
    .EXAMPLE
        Add-TcNcTask
    .EXAMPLE
        Add-TcNcTask -Name 'NC-Task 1' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Name = 'NC-Task 1',

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ name = $Name; dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must be a non-empty name without '^' (got '$Name'); nothing was created."
    }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path 'TINC' -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $list = Get-TcNcTaskList -SysManager $sm
        if (@($list.Tasks).Count -gt 0) {
            $data | Add-Member -NotePropertyName existingTasks -NotePropertyValue @($list.Tasks | ForEach-Object { $_.path })
            return New-TcResult -Success $false -ErrorCode 'NC_TASK_ALREADY_EXISTS' -Data $data `
                -ErrorMessage "TINC already has an NC task ($((@($list.Tasks) | ForEach-Object { "'$($_.path)'" }) -join ', ')); XAE allows only one (0x98510002 'Item already exists!'). Nothing was created." `
                -Hint (Get-TcErrorHint -Code 'NC_TASK_ALREADY_EXISTS')
        }
        $data | Add-Member -NotePropertyName plannedSteps -NotePropertyValue @("CreateChild TINC '$Name' SubType 1", "readback: the task and '<task>^Axes' exist")
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $c = New-TcTreeItem -Path 'TINC' -Name $Name -SubType 1 -DryRun $false
        $called = Test-TcWriteCalled -Result $c
        Copy-TcDataFields -From $c.data -To $data -Names @('backupPath', 'backupFiles', 'warnings')
        if (-not $c.success) {
            $msg = [string]$c.error.message
            $code = [string]$c.error.code
            $hint = [string]$c.error.hint
            if ($code -eq 'TREEITEM_CREATE_FAILED' -and $msg -match 'Item already exists') { $code = 'NC_TASK_ALREADY_EXISTS'; $hint = Get-TcErrorHint -Code $code }
            $res = New-TcResult -Success $false -ErrorCode $code -Data $data -ErrorMessage "Add-TcNcTask: $msg" -Hint $hint
            if ($called) { $res = Register-TcCodeChange -Result $res -Change "Add-TcNcTask $Name [failed]" }
            return $res
        }
        $taskPath = [string]$c.data.createdPath
        $data | Add-Member -NotePropertyName taskPath -NotePropertyValue $taskPath
        $data | Add-Member -NotePropertyName createdName -NotePropertyValue ([string]$c.data.createdName)
        $axesPath = "$taskPath^Axes"
        $task = Find-TcTreeItemNoThrow -SysManager $sm -Path $taskPath
        $axes = Find-TcTreeItemNoThrow -SysManager $sm -Path $axesPath
        $t = if ($null -ne $task) { try { [int]$task.ItemType } catch { -1 } } else { -1 }
        if ($null -eq $task -or $t -ne $script:TcNcTaskItemType -or $null -eq $axes) {
            $why = if ($null -eq $task) { "'$taskPath' is not found" } elseif ($t -ne $script:TcNcTaskItemType) { "'$taskPath' has ItemType $t, not 1" } else { "'$axesPath' is not found" }
            $rb = Invoke-TcNcAxisRollback -Path $taskPath
            $data | Add-Member -NotePropertyName rollback -NotePropertyValue @($rb)
            $data | Add-Member -NotePropertyName rolledBack -NotePropertyValue $rb.removed
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'NC_TASK_VERIFY_FAILED' -Data $data `
                -ErrorMessage "CreateChild returned, but $why; $(if ($rb.removed) { 'the task was deleted again' } else { "the task could NOT be deleted ($($rb.message))" })." -Hint (Get-TcErrorHint -Code 'NC_TASK_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "Add-TcNcTask $Name [failed at verify]"
        }
        $data | Add-Member -NotePropertyName axesPath -NotePropertyValue $axesPath
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Add-TcNcTask $taskPath"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_CREATE_FAILED' -Data $data -Operation 'Add-TcNcTask'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Add-TcNcTask $Name [failed]" }
        return $res
    }
}
