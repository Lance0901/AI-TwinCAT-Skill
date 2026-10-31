function New-TcTreeItem {
    <#
    .SYNOPSIS
        Creates a child below a tree item (ITcSmTreeItem.CreateChild). Dry-run by default; backs up the parent and reads back.
    .DESCRIPTION
        Generic tree tool (MCP CreateChild). Prefer the dedicated tools (AddPou, AddDut, AddGvl,
        AddLibrary, IoScan) when they cover the object. ITcSmTreeItem::CreateChild(bstrName, nSubType,
        bstrBefore, vInfo) (TE1000 Automation Interface manual v1.7.0, 5.2.1.2, p.57): not every item
        supports it (E_NOTIMPL). The meaning of SubType and VInfo depends on the parent; there is no
        complete public list, only use values documented in the manual or InfoSys.
        Checks first (nothing created on failure): Path exists (TREEITEM_NOT_FOUND with the nearest
        parent in error.hint), no child with Name exists (TREEITEM_ALREADY_EXISTS), Before is an
        existing child (LookupTreeItem Path^Before; TREEITEM_NOT_FOUND).
        DryRun (default true): CreateChild is NOT called; data.dryRun=true, data.plannedPath,
        data.currentChildren.
        data.writeCalled = true once CreateChild is called (absent when the call was never made).
        DryRun=false: ProduceXml backup of the PARENT (data.backupPath), IDE_MODAL_DIALOG when a dialog
        is open (nothing created), CreateChild, then the new item is looked up again and the parent's
        ProduceXml read back: it may only have gained entries (data.parentUnchanged; ChildCount +1 is
        expected), and the child names must be the old ones plus exactly one (data.childrenAfter;
        skipped with a warning when the list is cut).
        data.verified=true, data.createdPath / createdName / itemType / subType.
        XAE refusing the call -> TREEITEM_CREATE_FAILED; returned but not found afterwards, or a
        parent field changed (data.unexpectedChanges) -> TREEITEM_VERIFY_FAILED. XAE may give the child another name than requested: data.createdName
        and data.warnings say so. Below TIPC: BUILD_REQUIRED code-changed is recorded.
    .PARAMETER Path
        Full tree path of the PARENT, e.g. "TIRT". No wildcards.
    .PARAMETER Name
        Name of the new child (no '^').
    .PARAMETER SubType
        nSubType of CreateChild (default 0). Depends on the parent; see the examples.
    .PARAMETER Before
        Optional name of an existing child before which the new one is inserted (bstrBefore).
    .PARAMETER VInfo
        Optional vInfo of CreateChild (string or array, depends on the parent), e.g. "BOOL" for a
        process image variable, or "EK1100-0000-0017" for an EtherCAT box.
    .PARAMETER DryRun
        Default true: only report the plan. false: back up the parent, create, read back.
    .EXAMPLE
        New-TcTreeItem -Path 'TIRT' -Name 'Task 2' -SubType 1 -DryRun $false
        Task without process image (TE1000 v1.7.0 6.3.1 "Creating and handling Tasks", p.196: SubType 0 =
        with image, 1 = without image).
    .EXAMPLE
        New-TcTreeItem -Path 'TIID' -Name 'EtherCAT Master' -SubType 111
        Dry-run of an EtherCAT master (TE1000 v1.7.0 6.6.1 "Adding EtherCAT devices", p.244: master 111;
        a box below it uses SubType 9099 with the product revision as VInfo, e.g. "EK1100-0000-0017").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [int]$SubType = 0,

        [Parameter()]
        [string]$Before = '',

        [Parameter()]
        [object]$VInfo,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ path = $Path; name = $Name; subType = $SubType; before = $Before; dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must be a non-empty name without '^' (got '$Name')."
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $plannedPath = "$Path^$Name"
    $data | Add-Member -NotePropertyName plannedPath -NotePropertyValue $plannedPath
    $stage = 'lookup'
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $parent = $r.Item
        $children = @(Get-TcTreeItemChildNames -Item $parent)
        $data | Add-Member -NotePropertyName currentChildren -NotePropertyValue $children

        $existing = Find-TcTreeItemNoThrow -SysManager $sm -Path $plannedPath
        if ($null -ne $existing) {
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_ALREADY_EXISTS' -Data $data `
                -ErrorMessage "'$plannedPath' already exists; nothing was created." -Hint (Get-TcErrorHint -Code 'TREEITEM_ALREADY_EXISTS')
        }
        # -Before is looked up directly: currentChildren is cut at $script:TcTreeItemMaxChildNames.
        if (-not [string]::IsNullOrEmpty($Before) -and $null -eq (Find-TcTreeItemNoThrow -SysManager $sm -Path "$Path^$Before")) {
            $list = if ($children.Count -gt 0) { ($children | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' }
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_NOT_FOUND' -Data $data `
                -ErrorMessage "-Before '$Before' is not a child of '$Path'; nothing was created." `
                -Hint "-Before must be the name of an existing child of '$Path': $list. Leave it empty to append."
        }

        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $stage = 'backup'
        $parentBefore = Get-TcTreeItemXmlText -Item $parent -Path $Path
        $bk = Invoke-TcTreeItemBackup -Item $parent -Path $Path -Data $data -Tag 'parent' -Xml $parentBefore
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $stage = 'create'
        $isPlc = Test-TcTreePathIsPlc -Path $Path
        $created = $null
        $dlg = Get-TcTreeItemDialogResult -Operation "CreateChild '$plannedPath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        # data.writeCalled: CreateChild is about to be called (wrapping cmdlets record BUILD_REQUIRED by it)
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        try {
            # No deadline (CODING_STANDARDS.md section 1), same as New-TcPlcObject: an open dialog was
            # ruled out just above, Connect-TcIde turns on ITcAutomationSettings.SilentMode, and
            # CreateChild returned within 1 s on 4024 and 4026 (measured 2026-10-25 for PLC objects;
            # other parents (TIRT, TIID) are not timed yet, task 2.8).
            $created = Invoke-TcComRetry -OperationName "CreateChild $plannedPath" -ScriptBlock {
                Write-Output -NoEnumerate $parent.CreateChild($Name, $SubType, $Before, $VInfo)
            }
        }
        catch {
            # An error from CreateChild itself: nothing was created (same rule as Add-TcPou, #65); a
            # wrapped IDE_* error may have happened after XAE created it, so that one is recorded.
            $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_CREATE_FAILED' -Data $data -Operation "CreateChild '$plannedPath'"
            if ($isPlc -and $_.Exception.Message -match '^IDE_') { $res = Register-TcCodeChange -Result $res -Change "New-TcTreeItem $plannedPath [failed]" }
            return $res
        }

        $stage = 'verify'
        $createdName = $Name
        $createdPath = $plannedPath
        if ($null -ne $created) {
            $cn = try { [string]$created.Name } catch { '' }
            $cp = try { [string]$created.PathName } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($cn)) { $createdName = $cn }
            if (-not [string]::IsNullOrWhiteSpace($cp)) { $createdPath = $cp } else { $createdPath = "$Path^$createdName" }
        }
        $check = Find-TcTreeItemNoThrow -SysManager $sm -Path $createdPath
        $data | Add-Member -NotePropertyName createdPath -NotePropertyValue $createdPath
        $data | Add-Member -NotePropertyName createdName -NotePropertyValue $createdName
        if ($null -eq $check) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "CreateChild returned, but '$createdPath' is not found when looked up again." -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
        }
        else {
            $s = Get-TcTreeItemSummary -Item $check
            $data | Add-Member -NotePropertyName itemType -NotePropertyValue $s.itemType
            $data | Add-Member -NotePropertyName itemSubType -NotePropertyValue $s.subType
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            if ($createdName -cne $Name) {
                $data.warnings = @(@($data.warnings) + @("XAE named the new child '$createdName', not '$Name'"))
            }
            $res = Test-TcTreeItemParentUnchanged -Parent $parent -Path $Path -BeforeXml $parentBefore -Data $data -Operation 'CreateChild'
            if ($null -eq $res) { $res = Test-TcTreeItemChildrenAdded -Before $children -After @(Get-TcTreeItemChildNames -Item $parent) -Path $Path -Data $data -Operation 'CreateChild' }
            if ($null -eq $res) { $res = New-TcResult -Success $true -Data $data }
        }
        if ($isPlc) { $res = Register-TcCodeChange -Result $res -Change "New-TcTreeItem $createdPath" }
        return $res
    }
    catch {
        $code = if ($stage -eq 'create') { 'TREEITEM_CREATE_FAILED' } elseif ($stage -eq 'verify') { 'TREEITEM_VERIFY_FAILED' } else { 'TREEITEM_READ_FAILED' }
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode $code -Data $data -Operation "CreateChild '$plannedPath' ($stage)"
    }
}
