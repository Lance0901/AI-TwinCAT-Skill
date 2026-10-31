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
        to change, element values only (no attributes), e.g.
        <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>.
        Checks before anything is sent (nothing written on failure):
          - XML_MERGE_FAILED, data.reason: syntax, root (not <TreeItem>), empty,
            paths-not-in-current-xml (data.missingPaths; XAE ignores unknown elements silently, S_OK,
            measured 2026-10-30), and - refused because XAE's merge is not measured -
            attributes-not-supported (data.attributePaths), structure-mismatch (a fragment leaf is an
            element with child elements in the current XML, or text next to child elements;
            data.structurePaths), repeated-count-mismatch (a different number of same-name repeated
            elements than now; data.repeatedCountMismatches), derived-only (every changed leaf is a
            derived TcModuleInstance Context / ParameterValues field; data.derivedPaths).
          - TREEITEM_INVALID_VALUE: a known field with an invalid value (data.invalidFields), e.g.
            TaskDef/CycleTime must be an integer > 0 (XAE stores 0, negative numbers and text; measured).
        DryRun (default true): ConsumeXml is NOT called; data.dryRun=true, data.changes[] (path, current,
        planned, changed, derived), data.changedCount, data.currentXml.
        DryRun=false: (1) ProduceXml backup to <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\ plus the
        node's disk file (e.g. <task>.TcTTO, which XAE rewrites at once) -> data.backupPath,
        data.backupFiles, data.warnings; (2) IDE_MODAL_DIALOG when a dialog is open (nothing sent);
        (3) ConsumeXml; (4) ProduceXml read back: every fragment leaf must have its planned value
        (derived fields excluded, data.mismatches) AND every other non-derived leaf / attribute of the
        whole XML must be unchanged (data.unexpectedChanges: path, kind changed / removed / added,
        before, after). Both hold: data.verified=true; else TREEITEM_VERIFY_FAILED.
        Nothing to change (all values equal): success, data.written=false, no backup.
        A path below TIPC records BUILD_REQUIRED code-changed (data.buildRequired).
    .PARAMETER Path
        Full tree path of the item to change, e.g. "TIRT^PlcTask". No wildcards.
    .PARAMETER Xml
        The fragment: root <TreeItem>, only the elements to change, no attributes.
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

    # Checks that need no IDE: syntax, root, attributes, mixed content, value rules.
    $frag = ConvertFrom-TcTreeItemFragment -Xml $Xml
    if ($null -ne $frag.Error) {
        if ($frag.Reason -eq 'attributes-not-supported') { $data | Add-Member -NotePropertyName attributePaths -NotePropertyValue @($frag.Paths) }
        if ($frag.Reason -eq 'structure-mismatch') { $data | Add-Member -NotePropertyName structurePaths -NotePropertyValue @($frag.Paths) }
        return New-TcXmlMergeFailedResult -Reason $frag.Reason -Message $frag.Error -Data $data
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
        if (@($cmp.RepeatedCountMismatch).Count -gt 0) {
            $rc = @($cmp.RepeatedCountMismatch)
            $data | Add-Member -NotePropertyName repeatedCountMismatches -NotePropertyValue $rc
            return New-TcXmlMergeFailedResult -Reason 'repeated-count-mismatch' -Data $data `
                -Message ("The fragment repeats elements a different number of times than the current XML of '$Path' (how XAE merges that is not measured): " + (($rc | ForEach-Object { "$($_.path) fragment $($_.fragmentCount) / current $($_.currentCount)" }) -join '; '))
        }
        if (@($cmp.StructureMismatch).Count -gt 0) {
            $data | Add-Member -NotePropertyName structurePaths -NotePropertyValue @($cmp.StructureMismatch)
            return New-TcXmlMergeFailedResult -Reason 'structure-mismatch' -Data $data `
                -Message ("The fragment gives a value to elements that have child elements in the current XML of '$Path': " + (@($cmp.StructureMismatch) -join ', '))
        }
        if (@($cmp.Missing).Count -gt 0) {
            $data | Add-Member -NotePropertyName missingPaths -NotePropertyValue @($cmp.Missing)
            return New-TcXmlMergeFailedResult -Reason 'paths-not-in-current-xml' -Data $data `
                -Message ("The fragment has element paths that do not exist in the current XML of '$Path' (XAE would ignore them silently): " + (@($cmp.Missing) -join ', '))
        }
        $changes = @($cmp.Changes)
        $changed = @($changes | Where-Object { $_.changed })
        $changedDerived = @($changed | Where-Object { $_.derived })
        if ($changed.Count -gt 0 -and $changedDerived.Count -eq $changed.Count) {
            $data | Add-Member -NotePropertyName derivedPaths -NotePropertyValue @($changedDerived | ForEach-Object { $_.path })
            return New-TcXmlMergeFailedResult -Reason 'derived-only' -Data $data `
                -Message ("Every changed element of the fragment is a derived field that XAE recomputes and that cannot be read back: " + (@($changedDerived | ForEach-Object { $_.path }) -join ', '))
        }
        $data | Add-Member -NotePropertyName changes -NotePropertyValue $changes
        $data | Add-Member -NotePropertyName changedCount -NotePropertyValue $changed.Count
        $warnings = @()
        if ($changedDerived.Count -gt 0) { $warnings += "derived fields in the fragment ($(@($changedDerived | ForEach-Object { $_.path }) -join ', ')) are recomputed by XAE and are not read back" }

        if ($DryRun) {
            $data | Add-Member -NotePropertyName currentXml -NotePropertyValue $currentXml
            if ($changed.Count -eq 0) { $warnings += 'every value in the fragment already equals the current value; nothing would change' }
            if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings }
            return New-TcResult -Success $true -Data $data
        }

        if ($changed.Count -eq 0) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue @('every value in the fragment already equals the current value; ConsumeXml was not called and no backup was written')
            return New-TcResult -Success $true -Data $data
        }

        $stage = 'backup'
        if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings }
        $bk = Invoke-TcTreeItemBackup -Item $item -Path $Path -Data $data -Xml $currentXml
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $stage = 'consume'
        $data | Add-Member -NotePropertyName written -NotePropertyValue $false
        $dlg = Get-TcTreeItemDialogResult -Operation "ConsumeXml '$Path'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        try {
            # No deadline (CODING_STANDARDS.md section 1), same as CreateChild in New-TcPlcObject: an open
            # dialog was ruled out just above, and Connect-TcIde turns on ITcAutomationSettings.SilentMode
            # so XAE answers its own prompts with the default instead of blocking. Every ConsumeXml call
            # of task 2.1 returned (2026-10-30, 4026 VS2022, TIRT^PlcTask; duration not recorded, to be
            # timed in task 2.8).
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
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $result = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "ConsumeXml returned, but ProduceXml could not be read back: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
        }
        if ($null -eq $result) {
            $after = Compare-TcTreeItemFragment -Leaves $frag.Leaves -CurrentXml $afterXml
            $mism = @($after.Mismatches)
            foreach ($m in @(@($after.Missing) + @($after.StructureMismatch))) { $mism += [PSCustomObject]@{ path = $m; expected = '(leaf element present)'; actual = '(missing or changed structure after write)' } }
            foreach ($m in @($after.RepeatedCountMismatch)) { $mism += [PSCustomObject]@{ path = $m.path; expected = "$($m.fragmentCount) element(s)"; actual = "$($m.currentCount) element(s)" } }
            # Everything outside the fragment (derived fields aside) must be exactly as before.
            $unexpected = @(Compare-TcTreeItemXmlFull -BeforeXml $currentXml -AfterXml $afterXml -ExcludePaths @($frag.Leaves | ForEach-Object { $_.path }))
            $ok = ($mism.Count -eq 0 -and $unexpected.Count -eq 0)
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $ok
            $skipped = @($frag.Leaves | Where-Object { $_.derived } | ForEach-Object { $_.path })
            if ($skipped.Count -gt 0) { $data | Add-Member -NotePropertyName skippedDerived -NotePropertyValue $skipped }
            if ($mism.Count -gt 0) { $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism }
            if ($unexpected.Count -gt 0) { $data | Add-Member -NotePropertyName unexpectedChanges -NotePropertyValue $unexpected }
            if (-not $ok) {
                $parts = @()
                if ($mism.Count -gt 0) { $parts += 'the read-back values differ: ' + (($mism | ForEach-Object { "$($_.path) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; ') }
                if ($unexpected.Count -gt 0) { $parts += 'fields outside the fragment changed: ' + (($unexpected | ForEach-Object { "$($_.path) $($_.kind) '$($_.before)' -> '$($_.after)'" }) -join '; ') }
                $result = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                    -ErrorMessage ("ConsumeXml returned S_OK, but " + ($parts -join '; and ')) -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
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
