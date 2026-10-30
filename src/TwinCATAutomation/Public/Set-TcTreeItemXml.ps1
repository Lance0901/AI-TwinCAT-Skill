function Set-TcTreeItemXml {
    <#
    .SYNOPSIS
        Writes an XML fragment into one tree item (ITcSmTreeItem.ConsumeXml). Dry-run by default; backs up and reads back.
    .DESCRIPTION
        Generic tree tool (MCP ConsumeXml). Prefer a dedicated tool when one exists. ConsumeXml (TE1000
        Automation Interface manual v1.7.0, 5.2.1.1, p.57) takes "XML document or XML snippet"; the
        fragment is sent as-is: XAE merges it, fields that are not in the fragment keep their value
        (measured 2026-10-30, 4026 VS2022, TIRT^PlcTask, task 2.1).
        Fragment: root <TreeItem>, element paths as in ProduceXml (Get-TcTreeItemXml), only the fields
        to change, e.g. <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>.
        Checks before anything is sent (nothing written on failure):
          - XML_MERGE_FAILED: does not parse, root is not <TreeItem>, no element, or a leaf element path
            that does not exist in the current ProduceXml (data.missingPaths). XAE itself ignores unknown
            elements silently (S_OK, nothing changed; measured 2026-10-30).
          - TREEITEM_INVALID_VALUE: a known field with an invalid value (data.invalidFields), e.g.
            TaskDef/CycleTime must be an integer > 0 (XAE stores 0, negative numbers and text; measured).
        DryRun (default true): ConsumeXml is NOT called; data.dryRun=true, data.changes[] (path, current,
        planned, changed, derived), data.changedCount, data.currentXml.
        DryRun=false: (1) ProduceXml backup to <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\ plus the
        node's disk file (e.g. <task>.TcTTO, which XAE rewrites at once) -> data.backupPath,
        data.backupFiles, data.warnings; (2) ConsumeXml; (3) ProduceXml read back and every leaf of the
        fragment compared (derived TcModuleInstance Context / ParameterValues excluded):
        data.verified=true, else TREEITEM_VERIFY_FAILED with data.mismatches (expected, actual).
        Nothing to change (all values equal): success, data.written=false, no backup.
        A path below TIPC records BUILD_REQUIRED code-changed (data.buildRequired).
    .PARAMETER Path
        Full tree path of the item to change, e.g. "TIRT^PlcTask". No wildcards.
    .PARAMETER Xml
        The fragment: root <TreeItem>, only the elements to change.
    .PARAMETER DryRun
        Default true: only report the planned change. false: back up, write, read back.
    .EXAMPLE
        Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>'
    .EXAMPLE
        Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><Priority>21</Priority></TaskDef></TreeItem>' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Xml,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ path = $Path; dryRun = $DryRun }

    # Checks that need no IDE: syntax, root, value rules.
    $frag = ConvertFrom-TcTreeItemFragment -Xml $Xml
    if ($null -ne $frag.Error) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $frag.Reason
        return New-TcResult -Success $false -ErrorCode 'XML_MERGE_FAILED' -Data $data -ErrorMessage $frag.Error -Hint (Get-TcErrorHint -Code 'XML_MERGE_FAILED')
    }
    $invalid = @(Test-TcTreeItemFieldValues -Leaves $frag.Leaves)
    if ($invalid.Count -gt 0) {
        $data | Add-Member -NotePropertyName invalidFields -NotePropertyValue $invalid
        $first = $invalid[0]
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_INVALID_VALUE' -Data $data `
            -ErrorMessage "Invalid value for $($first.path): $($first.reason) (rule: $($first.rule)); nothing was written." `
            -Hint (Get-TcErrorHint -Code 'TREEITEM_INVALID_VALUE')
    }

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

        $stage = 'read'
        $currentXml = Get-TcTreeItemXmlText -Item $item -Path $Path
        $cmp = Compare-TcTreeItemFragment -Leaves $frag.Leaves -CurrentXml $currentXml
        if (@($cmp.Missing).Count -gt 0) {
            $data | Add-Member -NotePropertyName reason -NotePropertyValue 'paths-not-in-current-xml'
            $data | Add-Member -NotePropertyName missingPaths -NotePropertyValue @($cmp.Missing)
            return New-TcResult -Success $false -ErrorCode 'XML_MERGE_FAILED' -Data $data `
                -ErrorMessage ("The fragment has element paths that do not exist in the current XML of '$Path' (XAE would ignore them silently): " + (@($cmp.Missing) -join ', ')) `
                -Hint (Get-TcErrorHint -Code 'XML_MERGE_FAILED')
        }
        $changes = @($cmp.Changes)
        $changed = @($changes | Where-Object { $_.changed })
        $data | Add-Member -NotePropertyName changes -NotePropertyValue $changes
        $data | Add-Member -NotePropertyName changedCount -NotePropertyValue $changed.Count

        if ($DryRun) {
            $data | Add-Member -NotePropertyName currentXml -NotePropertyValue $currentXml
            if ($changed.Count -eq 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue @('every value in the fragment already equals the current value; nothing would change') }
            return New-TcResult -Success $true -Data $data
        }

        if ($changed.Count -eq 0) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue @('every value in the fragment already equals the current value; ConsumeXml was not called and no backup was written')
            return New-TcResult -Success $true -Data $data
        }

        $stage = 'backup'
        $bk = Invoke-TcTreeItemBackup -Item $item -Path $Path -Data $data -Xml $currentXml
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $stage = 'consume'
        $data | Add-Member -NotePropertyName written -NotePropertyValue $false
        try {
            Invoke-TcComRetry -OperationName "ConsumeXml $Path" -ScriptBlock { $item.ConsumeXml($Xml) } | Out-Null
        }
        catch {
            $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'XML_MERGE_FAILED' -Data $data -Operation "ConsumeXml '$Path'"
            if (Test-TcTreePathIsPlc -Path $Path) { $res = Register-TcCodeChange -Result $res -Change "Set-TcTreeItemXml $Path [ConsumeXml failed]" }
            return $res
        }
        $data.written = $true

        $stage = 'verify'
        $result = $null
        $afterXml = $null
        try { $afterXml = Get-TcTreeItemXmlText -Item $item -Path $Path }
        catch {
            if ($_.Exception.Message -match '^IDE_(MODAL_DIALOG|CRASHED|TIMEOUT|BUSY)') { throw }
            $result = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "ConsumeXml returned, but ProduceXml could not be read back: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
        }
        if ($null -eq $result) {
            $after = Compare-TcTreeItemFragment -Leaves $frag.Leaves -CurrentXml $afterXml
            $mism = @($after.Mismatches)
            foreach ($m in @($after.Missing)) { $mism += [PSCustomObject]@{ path = $m; expected = '(element present)'; actual = '(element missing after write)' } }
            $data | Add-Member -NotePropertyName verified -NotePropertyValue ($mism.Count -eq 0)
            $skipped = @($frag.Leaves | Where-Object { $_.derived } | ForEach-Object { $_.path })
            if ($skipped.Count -gt 0) { $data | Add-Member -NotePropertyName skippedDerived -NotePropertyValue $skipped }
            if ($mism.Count -gt 0) {
                $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism
                $result = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                    -ErrorMessage ("ConsumeXml returned S_OK, but the read-back values differ: " + (($mism | ForEach-Object { "$($_.path) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; ')) `
                    -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
            }
            else {
                $result = New-TcResult -Success $true -Data $data
            }
        }
        if (Test-TcTreePathIsPlc -Path $Path) { $result = Register-TcCodeChange -Result $result -Change "Set-TcTreeItemXml $Path" }
        return $result
    }
    catch {
        $code = if ($stage -eq 'verify') { 'TREEITEM_VERIFY_FAILED' } elseif ($stage -eq 'consume') { 'XML_MERGE_FAILED' } else { 'TREEITEM_READ_FAILED' }
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode $code -Data $data -Operation "ConsumeXml '$Path' ($stage)"
    }
}
