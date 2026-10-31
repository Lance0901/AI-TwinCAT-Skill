function Remove-TcTaskProgram {
    <#
    .SYNOPSIS
        Removes a program call from a PLC task (DeleteChild of the 650 child of '<Plc> Project^<PlcTask>'). Dry-run by default; backs up the task's .TcTTO and the call (ExportChild .zip) first and reads back.
    .DESCRIPTION
        The program call is the child '<Plc> Project^<PlcTask>^<ProgramName>' (ItemType 650); XAE removes
        one per DeleteChild('<name>'), also when the same name is linked twice, and rewrites <task>.TcTTO
        at once (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client,
        openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.5). The program
        itself is not touched.
        Checks (nothing removed on failure): the PLC task exists and is ItemType 621 (TASK_NOT_FOUND);
        a call named exactly -ProgramName (case-sensitive) is below it, else TASK_PROGRAM_NOT_LINKED
        (data.linkedPrograms; data.caseMatches lists calls whose name differs only in case).
        DryRun (default true): Remove-TcTreeItem -DryRun $true on the call; nothing is removed.
        DryRun=false: (1) ProduceXml backup of the task plus a copy of its <task>.TcTTO
        (data.taskBackupPath / data.taskBackupFiles); (2) Remove-TcTreeItem -DryRun $false on the call:
        recursive ProduceXml backup of the call and an ExportChild .zip of it (data.exportPath;
        TE1000 v1.7.0 5.2.1.4; XAE refuses other file names below TIPC, measured 2026-10-30 on a PLC
        folder; for a 650 node not measured yet). When that export fails and the .TcTTO copy exists,
        the call is still removed (data.warnings says so; restore by copying the .TcTTO back with the
        solution closed); without the .TcTTO copy nothing is removed (TREEITEM_BACKUP_FAILED).
        IDE_MODAL_DIALOG before each COM write, DeleteChild, then readback: the task must list one
        exact '<ProgramName>' call less (data.linkedPrograms, data.remainingCalls).
        BUILD_REQUIRED: recorded (code-changed) as soon as DeleteChild was called.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER ProgramName
        Name of the program call to remove, exactly as listed below the task.
    .PARAMETER PlcTask
        Name of the PLC task below '<Plc> Project' (default PlcTask).
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER DryRun
        Default true: only report what would be removed. false: back up, remove, read back.
    .EXAMPLE
        Remove-TcTaskProgram -ProgramName PRG_Old
    .EXAMPLE
        Remove-TcTaskProgram -ProgramName PRG_Old -PlcTask FastTask -DryRun $false
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
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-$($pair[0]) must be a non-empty name without '^' (got '$($pair[1])'); nothing was removed."
        }
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $change = "Remove-TcTaskProgram $ProgramName <- $PlcTask"
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
        $exactBefore = @($linked | Where-Object { $_ -ceq $ProgramName }).Count
        if ($exactBefore -eq 0) {
            $case = @($linked | Where-Object { $_ -ieq $ProgramName })
            if ($case.Count -gt 0) { $data | Add-Member -NotePropertyName caseMatches -NotePropertyValue $case }
            return New-TcResult -Success $false -ErrorCode 'TASK_PROGRAM_NOT_LINKED' -Data $data `
                -ErrorMessage "'$($task.Path)' has no program call named exactly '$ProgramName'; nothing was removed. Calls: $(if ($linked.Count -gt 0) { ($linked | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' })" `
                -Hint (Get-TcErrorHint -Code 'TASK_PROGRAM_NOT_LINKED')
        }
        $data | Add-Member -NotePropertyName callCount -NotePropertyValue $exactBefore
        $callPath = "$($task.Path)^$ProgramName"
        $data | Add-Member -NotePropertyName callPath -NotePropertyValue $callPath

        if ($DryRun) {
            $inner = Remove-TcTreeItem -Path $callPath -ConfirmName $ProgramName -DryRun $true
            Copy-TcDataFields -From $(if ($null -ne $inner.PSObject.Properties['data']) { $inner.data } else { $null }) -To $data -Names @('nodeName', 'itemType', 'reason', 'itemParentPath')
            if (-not $inner.success) { return New-TcResult -Success $false -ErrorCode ([string]$inner.error.code) -ErrorMessage "Remove-TcTaskProgram: $($inner.error.message)" -Hint ([string]$inner.error.hint) -Data $data }
            if ($exactBefore -gt 1) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue @("'$ProgramName' is linked $exactBefore times; one call per run is removed") -Force }
            return New-TcResult -Success $true -Data $data
        }

        # (1) the task's own backup: ProduceXml + <task>.TcTTO (the file XAE rewrites on DeleteChild)
        $bk = Invoke-TcTreeItemBackup -Item $task.Item -Path $task.Path -Data $data -Tag 'task'
        if ($null -ne $bk.Result) { return $bk.Result }
        $data | Add-Member -NotePropertyName taskBackupPath -NotePropertyValue $bk.Backup.backupPath
        $data | Add-Member -NotePropertyName taskBackupFiles -NotePropertyValue @($bk.Backup.backupFiles)
        $haveTto = @($bk.Backup.backupFiles | Where-Object { [string]$_ -like '*.TcTTO' }).Count -gt 0
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue @($bk.Backup.warnings) -Force

        # (2) backup of the call (ExportChild .zip) + DeleteChild + lookup: Remove-TcTreeItem
        $inner = Remove-TcTreeItem -Path $callPath -ConfirmName $ProgramName -DryRun $false -AllowNoExport:$haveTto
        $innerData = if ($null -ne $inner.PSObject.Properties['data']) { $inner.data } else { $null }
        Copy-TcDataFields -From $innerData -To $data -Names @('backupPath', 'backupFiles', 'exportPath', 'warnings', 'nodeName', 'itemType')
        $code = if ($inner.success) { $null } else { [string]$inner.error.code }
        $called = $inner.success -or @('TREEITEM_DELETE_FAILED', 'TREEITEM_VERIFY_FAILED') -contains $code -or ($null -ne $innerData -and $null -ne $innerData.PSObject.Properties['buildRequired'])
        $after = @(Get-TcTreeItemChildNames -Item $task.Item)
        $exactAfter = @($after | Where-Object { $_ -ceq $ProgramName }).Count
        $data.linkedPrograms = $after
        $data | Add-Member -NotePropertyName remainingCalls -NotePropertyValue $exactAfter
        # Remove-TcTreeItem's own readback (path no longer found) cannot hold when the name was linked
        # twice: one call less is the expected result then.
        $removedOne = ($exactAfter -eq $exactBefore - 1)
        if ($inner.success -or ($code -eq 'TREEITEM_VERIFY_FAILED' -and $exactBefore -gt 1 -and $removedOne)) {
            if (-not $removedOne) {
                $data | Add-Member -NotePropertyName verified -NotePropertyValue $false -Force
                $res = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                    -ErrorMessage "DeleteChild returned, but '$($task.Path)' lists '$ProgramName' $exactAfter time(s) (before: $exactBefore)." -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
                return Register-TcCodeChange -Result $res -Change "$change [readback failed]"
            }
            if ($exactAfter -gt 0) { $data.warnings = @(@($data.warnings) + @("'$ProgramName' was linked $exactBefore times; one call was removed, $exactAfter left")) }
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true -Force
            return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change $change
        }
        $data | Add-Member -NotePropertyName step -NotePropertyValue 'delete' -Force
        $p = @{ Success = $false; ErrorCode = $code; ErrorMessage = "Remove-TcTaskProgram: $($inner.error.message)"; Data = $data }
        if (-not [string]::IsNullOrWhiteSpace([string]$inner.error.hint)) { $p['Hint'] = [string]$inner.error.hint }
        $res = New-TcResult @p
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
        return $res
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_READ_FAILED' -Data $data -Operation 'Remove-TcTaskProgram'
    }
}
