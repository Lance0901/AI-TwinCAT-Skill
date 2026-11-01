function Set-TcComModuleContext {
    <#
    .SYNOPSIS
        Assigns a task to a context of a TcCOM module (SetModuleContext with the TMC Context Id, not 0) and reads it back. Dry-run by default.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.7.1 p.277-278, 5.33.2 p.140-141:
        ITcModuleInstance2.SetModuleContext(index, taskOid) / GetModuleContext(index, out oid). Measured
        2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md question 12): the
        index is the TMC Context Id (Module/Contexts/Context/Id of the ProduceXml; 1 for
        TcNtpExternalTimeProvider), index 0 there gives 0x80070057 "Context ObjectId not found"; an oid
        that is no task (an axis, a made-up number) gives E_FAIL; a PLC task and the NC SAF task both
        worked. The task oid is TreeItem/ObjectId of the task ProduceXml (#x02010030).
        So the module reads the legal ids first: no context -> TCCOM_CONTEXT_INVALID (the module has no
        context, e.g. TcJobPool); -ContextId not one of them -> TCCOM_CONTEXT_INVALID (data.contextIds);
        no -ContextId and more than one -> TCCOM_CONTEXT_INVALID (give one). XAE errors 0x80070057 /
        E_FAIL -> TCCOM_CONTEXT_INVALID as well (data.xaeError).
        DryRun (default true): data.contextId, data.taskOidHex, data.currentOidHex.
        DryRun=false: module ProduceXml backup, IDE_MODAL_DIALOG check, SetModuleContext, then
        GetModuleContext(id) must return the task oid (TCCOM_CONTEXT_VERIFY_FAILED). Already assigned:
        success, data.written = false. BUILD_REQUIRED (code-changed) is recorded once SetModuleContext
        was called.
        Verified with registered tcauto on 4026 and 4024 (openspec/changes/complete-automation-interface/verification/phase3-4.6.md).
    .PARAMETER Module
        Instance name or tree path (TIRC^TcCOM Objects^<name> (<type>)).
    .PARAMETER Task
        Tree path of the task, e.g. TIRT^PlcTask or TINC^NC-Task 1 SAF.
    .PARAMETER ContextId
        TMC Context Id; default (-1): the only context of the module.
    .PARAMETER DryRun
        Default true: only report the plan. false: back up, set, read back.
    .EXAMPLE
        Set-TcComModuleContext -Module NtpTest -Task 'TIRT^PlcTask'
    .EXAMPLE
        Set-TcComModuleContext -Module NtpTest -Task 'TIRT^PlcTask' -ContextId 1 -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Module,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Task,

        [Parameter()]
        [int]$ContextId = -1,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ module = $Module; task = $Task; dryRun = $DryRun }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $m = Resolve-TcComModule -SysManager $sm -Module $Module -Data $data
        if ($null -ne $m.Result) { return $m.Result }
        $info = $m.Info
        $item = $m.Item
        $ids = @($info.contextIds)
        $data | Add-Member -NotePropertyName contextIds -NotePropertyValue $ids
        $bad = $null
        if ($ids.Count -eq 0) { $bad = "module '$($m.Path)' has no context (Module/Contexts/Context is empty), so no task can be assigned" }
        elseif ($ContextId -ge 0 -and $ids -notcontains $ContextId) { $bad = "-ContextId $ContextId is not a context of '$($m.Path)' (TMC Context Ids: $($ids -join ', '); index 0 is not a default)" }
        elseif ($ContextId -lt 0 -and $ids.Count -gt 1) { $bad = "module '$($m.Path)' has several contexts ($($ids -join ', ')); give -ContextId" }
        if ($null -ne $bad) {
            return New-TcResult -Success $false -ErrorCode 'TCCOM_CONTEXT_INVALID' -Data $data -ErrorMessage "$bad; nothing was changed." -Hint (Get-TcErrorHint -Code 'TCCOM_CONTEXT_INVALID')
        }
        $cid = if ($ContextId -ge 0) { $ContextId } else { [int]$ids[0] }
        $data | Add-Member -NotePropertyName contextId -NotePropertyValue $cid

        $t = Resolve-TcTreeItem -SysManager $sm -Path $Task -Data $data -ParameterName 'Task'
        if ($null -ne $t.Result) { return $t.Result }
        $oidText = Get-TcTreeItemXmlValue -Item $t.Item -XPath 'TreeItem/ObjectId' -Path $Task
        $taskOid = ConvertFrom-TcHexId -Value $oidText
        if ($null -eq $taskOid) {
            return New-TcResult -Success $false -ErrorCode 'TCCOM_CONTEXT_INVALID' -Data $data `
                -ErrorMessage "-Task '$Task' has no TreeItem/ObjectId in its ProduceXml (got '$oidText'); it is not a task. Nothing was changed." -Hint (Get-TcErrorHint -Code 'TCCOM_CONTEXT_INVALID')
        }
        $data | Add-Member -NotePropertyName taskOid -NotePropertyValue $taskOid
        $data | Add-Member -NotePropertyName taskOidHex -NotePropertyValue (Format-TcHexId -Value $taskOid)

        $readCtx = {
            $o = [uint32]0
            Invoke-TcComRetry -OperationName "GetModuleContext $cid" -ScriptBlock { $item.GetModuleContext($cid, [ref]$o) } | Out-Null
            [uint32]$o
        }
        $cur = $null
        try { $cur = & $readCtx } catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $cur = $null }
        $data | Add-Member -NotePropertyName currentOidHex -NotePropertyValue $(if ($null -ne $cur) { Format-TcHexId -Value $cur } else { $null })
        if ($null -ne $cur -and $cur -eq $taskOid) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            return New-TcResult -Success $true -Data $data
        }
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $bk = Invoke-TcTreeItemBackup -Item $item -Path $m.Path -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "SetModuleContext $cid '$($m.Path)'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): dialog ruled out just above; 39 ms in the probe (question 12).
        try { Invoke-TcComRetry -OperationName "SetModuleContext $cid" -ScriptBlock { $item.SetModuleContext([uint32]$cid, [uint32]$taskOid) } | Out-Null }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $code = ConvertTo-TcComErrorCode -ErrorRecord $_ -Operation 'context' -DefaultCode 'TCCOM_CONTEXT_WRITE_FAILED'
            $data | Add-Member -NotePropertyName xaeError -NotePropertyValue $_.Exception.Message
            $res = New-TcResult -Success $false -ErrorCode $code -Data $data `
                -ErrorMessage "SetModuleContext($cid, $($data.taskOidHex)) on '$($m.Path)' failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code $code)
            return Register-TcCodeChange -Result $res -Change "Set-TcComModuleContext $($m.Path) [failed]"
        }
        $data | Add-Member -NotePropertyName written -NotePropertyValue $true
        $after = $null
        try { $after = & $readCtx } catch { if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }; $after = $null }
        $data | Add-Member -NotePropertyName readbackOidHex -NotePropertyValue $(if ($null -ne $after) { Format-TcHexId -Value $after } else { $null })
        if ($null -eq $after -or $after -ne $taskOid) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TCCOM_CONTEXT_VERIFY_FAILED' -Data $data `
                -ErrorMessage "SetModuleContext returned, but GetModuleContext($cid) reads $($data.readbackOidHex) instead of $($data.taskOidHex)." -Hint (Get-TcErrorHint -Code 'TCCOM_CONTEXT_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "Set-TcComModuleContext $($m.Path) [failed at verify]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Set-TcComModuleContext $($m.Path) $Task"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TCCOM_CONTEXT_WRITE_FAILED' -Data $data -Operation 'Set-TcComModuleContext'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Set-TcComModuleContext $Module [failed]" }
        return $res
    }
}
