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
        data.childCount, data.children.
        DryRun=false: backup first - ProduceXml(recursive) of the item (data.backupPath), its disk file
        when known (data.backupFiles), and an ExportChild file of the item into the same folder
        (data.exportPath; restore with ImportChild): .zip for every node below TIPC (XAE refuses .xti
        for a PLC folder, measured 2026-10-30 4026 VS2022 on a PLC folder only; other TIPC nodes not
        measured, a failed export deletes nothing), else .xti. When ExportChild fails or its file does
        not exist nothing is deleted: TREEITEM_BACKUP_FAILED, data.reason export-failed / export-missing, unless
        AllowNoExport is set (then data.warnings says so). IDE_MODAL_DIALOG when a dialog is open before
        ExportChild or DeleteChild. Then DeleteChild, then LookupTreeItem must no longer find the path:
        data.verified=true, else TREEITEM_VERIFY_FAILED. XAE refusing the call -> TREEITEM_DELETE_FAILED.
        Below TIPC: BUILD_REQUIRED code-changed.
    .PARAMETER Path
        Full tree path of the item to delete, e.g. "TIRT^Task 2". No wildcards.
    .PARAMETER ConfirmName
        Must equal the name of the item (the last path segment as XAE reports it), e.g. "Task 2".
    .PARAMETER DryRun
        Default true: only report what would be deleted. false: back up, delete, read back.
    .PARAMETER AllowNoExport
        Delete even when the ExportChild backup (.xti, or .zip below TIPC) failed or was not written
        (only the ProduceXml backup remains, which ImportChild cannot restore); the result keeps a warning. Default off:
        TREEITEM_BACKUP_FAILED and nothing deleted.
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
        [switch]$AllowNoExport
    )

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
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $item = $r.Item
        $s = Get-TcTreeItemSummary -Item $item
        $nodeName = if ([string]::IsNullOrEmpty($s.name)) { Get-TcTreePathLeaf -Path $Path } else { $s.name }
        $data | Add-Member -NotePropertyName nodeName -NotePropertyValue $nodeName
        $data | Add-Member -NotePropertyName itemType -NotePropertyValue $s.itemType
        $data | Add-Member -NotePropertyName childCount -NotePropertyValue $s.childCount
        if (-not [string]::Equals($ConfirmName, $nodeName, [System.StringComparison]::Ordinal)) {
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_DELETE_NAME_MISMATCH' -Data $data `
                -ErrorMessage "-ConfirmName '$ConfirmName' does not equal the name of '$Path' ('$nodeName'); nothing was deleted." `
                -Hint (Get-TcErrorHint -Code 'TREEITEM_DELETE_NAME_MISMATCH')
        }
        $data | Add-Member -NotePropertyName children -NotePropertyValue @(Get-TcTreeItemChildNames -Item $item)
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
        $dlg = Get-TcTreeItemDialogResult -Operation "ExportChild '$Path' (backup before DeleteChild)" -Data $data
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), same as CreateChild in New-TcPlcObject: an open
            # dialog was ruled out just above and Connect-TcIde turns on ITcAutomationSettings.SilentMode
            # (XAE answers prompts with the default). Not timed yet (task 2.8).
            Invoke-TcComRetry -OperationName "ExportChild $Path (backup)" -ScriptBlock { $parent.ExportChild($nodeName, $exportFile) } | Out-Null
            if (Test-Path -LiteralPath $exportFile -PathType Leaf) { $data | Add-Member -NotePropertyName exportPath -NotePropertyValue $exportFile }
            else { $exportReason = 'export-missing'; $exportProblem = "ExportChild returned but '$exportFile' does not exist" }
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
        $dlg = Get-TcTreeItemDialogResult -Operation "DeleteChild '$Path'" -Data $data
        if ($null -ne $dlg) { return $dlg }
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
        $still = Find-TcTreeItemNoThrow -SysManager $sm -Path $Path
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
}
