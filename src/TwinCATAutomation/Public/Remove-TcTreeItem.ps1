function Remove-TcTreeItem {
    <#
    .SYNOPSIS
        Deletes one tree item (parent ITcSmTreeItem.DeleteChild). Needs ConfirmName; dry-run by default; backs up and reads back.
    .DESCRIPTION
        Generic tree tool (MCP DeleteChild). Prefer a dedicated tool when one exists (RemoveVariableLink
        for links). ITcSmTreeItem::DeleteChild(bstrName) deletes a DIRECT child by name (TE1000 Automation
        Interface manual v1.7.0, 5.2.1.3, p.58); this cmdlet takes the full path of the item, looks up
        its parent and calls DeleteChild(<item name>) there.
        Guards (nothing deleted on failure): full path only, no wildcards (TREEITEM_PATH_INVALID), not a
        top-level node; ConfirmName must equal the item's name exactly (case-sensitive), else
        TREEITEM_DELETE_NAME_MISMATCH (data.nodeName).
        The item's own PathName must have the parent derived from Path (exact), else
        TREEITEM_DELETE_FAILED with data.reason parent-mismatch (data.itemParentPath), in dry-run too.
        DryRun (default true): DeleteChild is NOT called; data.dryRun=true, data.nodeName, data.itemType,
        data.childCount, data.children (direct children only, like LookupTreeItem), data.childrenTruncated,
        data.childrenUnreadable, data.rawChildCount (ChildCount as XAE reports it, -1 when unreadable, #187).
        DryRun=false: backup first - ProduceXml(recursive) of the item (data.backupPath), its disk file
        when known (data.backupFiles), and an ExportChild file of the item into the same folder
        (data.exportPath; restore with ImportChild): .zip for every node below TIPC (XAE refuses .xti
        for a PLC folder, measured 2026-10-30 4026 VS2022 on a PLC folder only; other TIPC nodes not
        measured, a failed export deletes nothing), else .xti. When ExportChild fails, its file does
        not exist or is empty (0 bytes) nothing is deleted: TREEITEM_BACKUP_FAILED, data.reason export-failed /
        export-missing / export-empty, unless AllowNoExport is set (then data.warnings says so; AllowNoExport
        only covers these three, never a dialog or an incomplete scan). IDE_MODAL_DIALOG when a dialog is open
        before ExportChild or DeleteChild; MODAL_SCAN_INCOMPLETE when that dialog scan did not finish within
        ModalScanTimeoutSec, could not look at every IDE window (strict scan) or the call deadline of 265 s
        left no time for it (reason no-budget), data.modalScan; never read as "no dialog", no dialog is
        answered. Refused at the backup gate: neither ExportChild nor DeleteChild is called; refused at the
        DeleteChild gate: the backup files already written stay (data.exportPath), DeleteChild is not
        called. Then DeleteChild, then LookupTreeItem must no longer find the path:
        data.verified=true, else TREEITEM_VERIFY_FAILED. XAE refusing the call -> TREEITEM_DELETE_FAILED.
        Below TIPC: BUILD_REQUIRED code-changed. data.writeCalled = true once DeleteChild is called.
    .PARAMETER Path
        Full tree path of the item to delete, e.g. "TIRT^Task 2". No wildcards.
    .PARAMETER ConfirmName
        Must equal the name of the item (the last path segment as XAE reports it), e.g. "Task 2".
    .PARAMETER DryRun
        Default true: only report what would be deleted. false: back up, delete, read back.
    .PARAMETER AllowNoExport
        Delete even when the ExportChild backup (.xti, or .zip below TIPC) failed, was not written or is
        empty (only the ProduceXml backup remains, which ImportChild cannot restore); the result keeps a
        warning. It never skips the dialog checks. Used by the rollbacks of AddPlcTask / AddNcTask /
        AddNcAxis (objects the same call just created). Default off: TREEITEM_BACKUP_FAILED and nothing deleted.
    .PARAMETER ModalScanTimeoutSec
        Upper bound in seconds (a whole number 1..60, default 30) of each UI Automation scan for a modal
        dialog: one right before the backup ExportChild, one right before DeleteChild (DryRun=false only; a
        dry run does not scan). #321: the 5 s of the other tree tools ran out before the backup ExportChild
        on a solution with several PLC projects (NB1 2026-11-12). Only a slow scan waits longer. The scan
        preparation (UIA load, first call in a process) has its own cap of 60 s on top; all of it stays
        within the call deadline of 265 s. A scan that does not finish -> MODAL_SCAN_INCOMPLETE, nothing
        deleted. Callers inside the module (UnlinkProgramFromTask, the rollbacks) pass 5.
    .EXAMPLE
        Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'Task 2'
    .EXAMPLE
        Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'Task 2' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$ConfirmName,

        [Parameter()]
        [bool]$DryRun = $true,

        [Parameter()]
        [switch]$AllowNoExport,

        # [double] + ValidateScript, not [int] + ValidateRange: [int] rounds 0.9 to 1 before it is validated
        # (#321 review m1); the MCP schema stays integer 1..60 (Export-ToolSchema.ps1 $schemaOverrides)
        [Parameter()]
        [ValidateScript({ Test-TcModalScanTimeoutArg -Value $_ })]
        [double]$ModalScanTimeoutSec = 30
    )
    $callWatch = [System.Diagnostics.Stopwatch]::StartNew()   # #321 review M1: call deadline
    $scanSec = [int]$ModalScanTimeoutSec

    $data = [PSCustomObject]@{ path = $Path; confirmName = $ConfirmName; dryRun = $DryRun; allowNoExport = [bool]$AllowNoExport }
    $bad = Test-TcTreePath -Path $Path
    if ($null -ne $bad) {
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_PATH_INVALID' -Data $data -ErrorMessage "-Path $bad" -Hint (Get-TcErrorHint -Code 'TREEITEM_PATH_INVALID')
    }
    $parentPath = Get-TcTreePathParent -Path $Path
    if ($null -eq $parentPath) {
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_PATH_INVALID' -Data $data `
            -ErrorMessage "-Path '$Path' is a top-level node; DeleteChild needs a parent. Nothing was deleted." -Hint (Get-TcErrorHint -Code 'TREEITEM_PATH_INVALID')
    }
    if ([string]::IsNullOrEmpty($ConfirmName)) {
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_DELETE_NAME_MISMATCH' -Data $data `
            -ErrorMessage '-ConfirmName is empty; nothing was deleted.' -Hint (Get-TcErrorHint -Code 'TREEITEM_DELETE_NAME_MISMATCH')
    }
    $data | Add-Member -NotePropertyName parentPath -NotePropertyValue $parentPath

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $stage = 'lookup'
    # #321 review r2 (M1): no COM call of this cmdlet starts after the call deadline (Invoke-TcComRetry)
    $prevComDeadline = Set-TcComCallDeadline -Command 'Remove-TcTreeItem'
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $item = $r.Item
        $s = Get-TcTreeItemSummary -Item $item
        $nodeName = if ([string]::IsNullOrEmpty($s.name)) { Get-TcTreePathLeaf -Path $Path } else { $s.name }
        $data | Add-Member -NotePropertyName nodeName -NotePropertyValue $nodeName
        $data | Add-Member -NotePropertyName itemType -NotePropertyValue $s.itemType
        # childCount / children: direct children only, counted like LookupTreeItem; rawChildCount = ChildCount
        # as XAE reports it (-1 unreadable). An EtherCAT device also counts the terminals below a coupler
        # (measured 2026-11-08, 4024 TcXaeShell 32-bit, BFH-1650: Device 1 ChildCount 9, 1 direct child) (#187).
        $info = Get-TcTreeItemDirectChildInfo -Item $item -Path $Path
        $directChildren = @($info.Names)
        $data | Add-Member -NotePropertyName childCount -NotePropertyValue $info.Count
        $data | Add-Member -NotePropertyName rawChildCount -NotePropertyValue $info.RawChildCount
        if (-not [string]::Equals($ConfirmName, $nodeName, [System.StringComparison]::Ordinal)) {
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_DELETE_NAME_MISMATCH' -Data $data `
                -ErrorMessage "-ConfirmName '$ConfirmName' does not equal the name of '$Path' ('$nodeName'); nothing was deleted." `
                -Hint (Get-TcErrorHint -Code 'TREEITEM_DELETE_NAME_MISMATCH')
        }
        $data | Add-Member -NotePropertyName children -NotePropertyValue $directChildren
        $data | Add-Member -NotePropertyName childrenTruncated -NotePropertyValue $info.Truncated
        $data | Add-Member -NotePropertyName childrenUnreadable -NotePropertyValue $info.Unreadable
        # DeleteChild(name) acts on the parent; the parent is derived from -Path. The item must report
        # that same parent (exact, case-sensitive), else the name could hit a child of another node.
        $itemParentPath = if ([string]::IsNullOrEmpty($s.path)) { $null } else { Get-TcTreePathParent -Path $s.path }
        $data | Add-Member -NotePropertyName itemParentPath -NotePropertyValue $itemParentPath
        if (-not [string]::Equals([string]$itemParentPath, $parentPath, [System.StringComparison]::Ordinal)) {
            $data | Add-Member -NotePropertyName reason -NotePropertyValue 'parent-mismatch'
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_DELETE_FAILED' -Data $data `
                -ErrorMessage "The item reports PathName '$($s.path)' (parent '$itemParentPath'), but the parent derived from -Path is '$parentPath'; DeleteChild was not called, nothing was deleted." `
                -Hint (Get-TcErrorHint -Code 'TREEITEM_DELETE_FAILED')
        }
        $rp = Resolve-TcTreeItem -SysManager $sm -Path $parentPath -Data $data -ParameterName 'Path (parent)'
        if ($null -ne $rp.Result) { return $rp.Result }
        $parent = $rp.Item

        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $stage = 'backup'
        # ProduceXml(true): the fallback backup holds the whole subtree that DeleteChild removes.
        $bk = Invoke-TcTreeItemBackup -Item $item -Path $Path -Data $data -Recursive
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        # Restorable copy of the whole subtree: ExportChild into the backup folder (5.2.1.4: the folder
        # must exist, the file must not). Required: without it nothing is deleted unless -AllowNoExport.
        # Below TIPC XAE only accepts a .zip file name (Get-TcTreeItemExportExtension, measured 2026-10-30).
        $exportFile = [System.IO.Path]::ChangeExtension($bk.Backup.backupPath, (Get-TcTreeItemExportExtension -Path $Path))
        $exportProblem = $null
        $exportReason = $null
        # #321: both gates of this call use -ModalScanTimeoutSec (default 30 s, not the 5 s of the other tree tools),
        # scan strict (review B1) and get only the time left until the call deadline (review M1)
        $scanHint = Get-TcTreeItemScanTimeoutHint -Command 'Remove-TcTreeItem' -TimeoutSec $scanSec
        $dlg = Get-TcTreeItemDialogResult -Operation "ExportChild '$Path' (backup before DeleteChild)" -Data $data -TimeoutSec $scanSec -Strict `
            -BudgetSec (Get-TcTreeItemCallBudgetSec -Command 'Remove-TcTreeItem' -Watch $callWatch) -ScanIncompleteHint $scanHint
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), same as CreateChild in New-TcPlcObject: an open
            # dialog was ruled out just above and Connect-TcIde turns on ITcAutomationSettings.SilentMode
            # (XAE answers prompts with the default). Not timed yet (task 2.8).
            Invoke-TcComRetry -OperationName "ExportChild $Path (backup)" -ScriptBlock { $parent.ExportChild($nodeName, $exportFile) } | Out-Null
            # #321 review B2: the file must exist AND not be empty (same check as Export-TcTreeItem)
            $chk = Test-TcTreeItemExportFile -FilePath $exportFile
            if ($chk.Ok) { $data | Add-Member -NotePropertyName exportPath -NotePropertyValue $exportFile }
            else { $exportReason = "export-$($chk.Reason)"; $exportProblem = $chk.Message }
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $exportReason = 'export-failed'
            $exportProblem = "ExportChild backup failed ($($_.Exception.Message))"
        }
        if ($null -ne $exportProblem) {
            if (-not $AllowNoExport) {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue $exportReason
                return New-TcResult -Success $false -ErrorCode 'TREEITEM_BACKUP_FAILED' -Data $data `
                    -ErrorMessage "$exportProblem; DeleteChild was not called, nothing was deleted (-AllowNoExport deletes with only the ProduceXml backup)." `
                    -Hint (Get-TcErrorHint -Code 'TREEITEM_BACKUP_FAILED')
            }
            $data.warnings = @(@($data.warnings) + @("$exportProblem; -AllowNoExport: deleting with only the ProduceXml (recursive) backup, which ImportChild cannot restore"))
        }

        $stage = 'delete'
        $isPlc = Test-TcTreePathIsPlc -Path $Path
        $dlg = Get-TcTreeItemDialogResult -Operation "DeleteChild '$Path'" -Data $data -TimeoutSec $scanSec -Strict `
            -BudgetSec (Get-TcTreeItemCallBudgetSec -Command 'Remove-TcTreeItem' -Watch $callWatch) -ScanIncompleteHint $scanHint
        if ($null -ne $dlg) { return $dlg }
        # #321 review r2 (M1): the gate may have used the time up - DeleteChild does not start after the deadline
        # (thrown before writeCalled: nothing was sent; the backups stay in data)
        if (Test-TcComCallDeadlinePassed) { throw "CALL_DEADLINE_EXCEEDED: 'DeleteChild $Path' not started - the call deadline passed after the dialog check" }
        # data.writeCalled: DeleteChild is about to be called (wrapping cmdlets record BUILD_REQUIRED by it)
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        try {
            # No deadline (CODING_STANDARDS.md section 1), same as CreateChild in New-TcPlcObject: an open
            # dialog was ruled out just above and Connect-TcIde turns on ITcAutomationSettings.SilentMode
            # (XAE answers a confirmation prompt with the default). Not timed yet (task 2.8).
            Invoke-TcComRetry -OperationName "DeleteChild $Path" -ScriptBlock { $parent.DeleteChild($nodeName) } | Out-Null
        }
        catch {
            $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_DELETE_FAILED' -Data $data -Operation "DeleteChild '$Path'"
            if ($isPlc -and $_.Exception.Message -match '^IDE_') { $res = Register-TcCodeChange -Result $res -Change "Remove-TcTreeItem $Path [failed]" }
            return $res
        }

        $stage = 'verify'
        # #321 review r2 (M1): no readback after the call deadline - DeleteChild was sent, the result is reported
        # as not verified (backups in data), never as verified
        $still = $null
        $readbackSkipped = Test-TcComCallDeadlinePassed
        if (-not $readbackSkipped) {
            try { $still = Find-TcTreeItemNoThrow -SysManager $sm -Path $Path }
            catch { if ([string]$_.Exception.Message -match '^CALL_DEADLINE_EXCEEDED:') { $readbackSkipped = $true } else { throw } }
        }
        if ($readbackSkipped) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false -Force
            $data | Add-Member -NotePropertyName verificationSkipped -NotePropertyValue $true -Force
            $res = New-TcResult -Success $false -ErrorCode 'CALL_DEADLINE_EXCEEDED' -Data $data `
                -ErrorMessage "CALL_DEADLINE_EXCEEDED: DeleteChild '$Path' was sent, but the call deadline passed before the readback: the deletion is not verified (backups: data.backupPath, data.exportPath)." `
                -Hint (Get-TcErrorHint -Code 'CALL_DEADLINE_EXCEEDED')
            if ($isPlc) { $res = Register-TcCodeChange -Result $res -Change "Remove-TcTreeItem $Path [not verified]" }
            return $res
        }
        if ($null -ne $still) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "DeleteChild returned, but '$Path' still exists." -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
        }
        else {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $res = New-TcResult -Success $true -Data $data
        }
        if ($isPlc) { $res = Register-TcCodeChange -Result $res -Change "Remove-TcTreeItem $Path" }
        return $res
    }
    catch {
        $code = if ($stage -eq 'delete') { 'TREEITEM_DELETE_FAILED' } elseif ($stage -eq 'verify') { 'TREEITEM_VERIFY_FAILED' } else { 'TREEITEM_READ_FAILED' }
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode $code -Data $data -Operation "DeleteChild '$Path' ($stage)"
    }
    finally { $script:TcComCallDeadline = $prevComDeadline }
}
