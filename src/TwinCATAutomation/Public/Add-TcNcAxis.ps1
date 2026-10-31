function Add-TcNcAxis {
    <#
    .SYNOPSIS
        Adds an NC axis below '<NC task>^Axes' (CreateChild) and reads back that it is a simulation axis (encoder = Simulation encoder). Dry-run by default.
    .DESCRIPTION
        TE1000 Automation Interface manual v1.7.0 6.10.1 p.293: '<task>^Axes'.CreateChild(name, 1).
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built
        client (openspec/changes/complete-automation-interface/verification/phase3-probe.md
        question 2): a new axis (ItemType 22) has Enc = Simulation encoder (subType 1), Drive =
        KL4XXX (subType 5), Ctrl = Position controller P (subType 1) - a simulation axis is the
        default, nothing has to be switched. Axis subType: Continuous 1, Discrete 2, Stepper 3,
        Encoder 5 (0 and 8 are refused by XAE); only Continuous was activated in the probe.
        XAE creates a second axis with the same name without complaint, so the module checks the
        names below Axes first (case-insensitive): NC_AXIS_ALREADY_EXISTS, nothing created.
        No NC task -> NC_TASK_NOT_FOUND (hint: Add-TcNcTask). -Task is only needed when there is
        more than one (NC_TASK_AMBIGUOUS; XAE allows one per TINC, so not reproducible).
        Uses New-TcTreeItem (backup of Axes, modal dialog check, parent / child readback). Readback:
        the axis exists with ItemType 22 and the requested subType, the encoder is the simulation
        encoder (EncType 0 / 1); otherwise NC_AXIS_VERIFY_FAILED and the axis is deleted again
        (data.rollback). data: axisPath, axisId (ProduceXml ItemId; the NC uses it in ADS index group
        0x4100 + id, InfoSys https://infosys.beckhoff.com/content/1033/tc3_ads_intro/713094155.html),
        encoder / drive / controller (subType, subTypeName), simulation.
        Set velocity / dynamics with Set-TcNcAxisParameter, link the PLC AXIS_REF with
        Connect-TcNcAxisToPlc. BUILD_REQUIRED (code-changed) is recorded once CreateChild was called.
        DryRun (default true): nothing is created; data.plannedSteps.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Name
        Axis name (no '^').
    .PARAMETER Task
        NC task name or tree path (TINC^NC-Task 1 SAF); default: the only NC task.
    .PARAMETER AxisType
        Continuous (default), Discrete, Stepper or Encoder; fixed at creation (ConsumeXml AxisType does not change it, measured).
    .PARAMETER DryRun
        Default true: only check and report the plan. false: create and read back.
    .EXAMPLE
        Add-TcNcAxis -Name 'Axis 5'
    .EXAMPLE
        Add-TcNcAxis -Name 'Axis 5' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter()]
        [string]$Task,

        [Parameter()]
        [ValidateSet('Continuous', 'Discrete', 'Stepper', 'Encoder')]
        [string]$AxisType = 'Continuous',

        [Parameter()]
        [bool]$DryRun = $true
    )

    $subType = [int]$script:TcNcAxisSubTypes[$AxisType]
    $data = [PSCustomObject]@{ name = $Name; axisType = $AxisType; subType = $subType; dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must be a non-empty name without '^' (got '$Name'); nothing was created."
    }
    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    $change = "Add-TcNcAxis $Name"
    try {
        $t = Resolve-TcNcTask -SysManager $sm -Task $Task -Data $data
        if ($null -ne $t.Result) { return $t.Result }
        $axesPath = "$($t.Path)^Axes"
        $data | Add-Member -NotePropertyName taskPath -NotePropertyValue $t.Path
        $data | Add-Member -NotePropertyName axesPath -NotePropertyValue $axesPath
        $axes = Find-TcTreeItemNoThrow -SysManager $sm -Path $axesPath
        if ($null -eq $axes) {
            return New-TcResult -Success $false -ErrorCode 'NC_TASK_NOT_FOUND' -Data $data `
                -ErrorMessage "NC task '$($t.Path)' has no 'Axes' node; nothing was created." -Hint (Get-TcErrorHint -Code 'NC_TASK_NOT_FOUND')
        }
        $existing = @(Get-TcTreeItemChildList -Item $axes | Where-Object { $_.name -ieq $Name } | ForEach-Object { $_.name })
        if ($existing.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingAxes -NotePropertyValue $existing
            return New-TcResult -Success $false -ErrorCode 'NC_AXIS_ALREADY_EXISTS' -Data $data `
                -ErrorMessage "An axis named '$($existing[0])' already exists below '$axesPath' (XAE would create a duplicate); nothing was created." -Hint (Get-TcErrorHint -Code 'NC_AXIS_ALREADY_EXISTS')
        }
        $data | Add-Member -NotePropertyName plannedSteps -NotePropertyValue @("CreateChild '$axesPath' '$Name' SubType $subType ($AxisType)", 'readback: ItemType 22, subType, Enc = Simulation encoder')
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $c = New-TcTreeItem -Path $axesPath -Name $Name -SubType $subType -DryRun $false
        $called = Test-TcWriteCalled -Result $c
        Copy-TcDataFields -From $c.data -To $data -Names @('backupPath', 'backupFiles', 'warnings')
        if (-not $c.success) {
            $res = New-TcResult -Success $false -ErrorCode ([string]$c.error.code) -Data $data -ErrorMessage "Add-TcNcAxis: $($c.error.message)" -Hint ([string]$c.error.hint)
            if ($null -ne $c.data -and $null -ne $c.data.PSObject.Properties['createdPath']) { $data | Add-Member -NotePropertyName createdPath -NotePropertyValue $c.data.createdPath -Force }
            if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
            return $res
        }
        $axisPath = [string]$c.data.createdPath
        $data | Add-Member -NotePropertyName axisPath -NotePropertyValue $axisPath
        $item = Find-TcTreeItemNoThrow -SysManager $sm -Path $axisPath
        $mism = [System.Collections.Generic.List[object]]::new()
        if ($null -eq $item) { $mism.Add([PSCustomObject]@{ field = 'axis'; expected = $axisPath; actual = '(not found)' }) }
        else {
            $it = try { [int]$item.ItemType } catch { -1 }
            $st = try { [int]$item.ItemSubType } catch { -1 }
            if ($it -ne $script:TcNcAxisItemType) { $mism.Add([PSCustomObject]@{ field = 'ItemType'; expected = '22'; actual = [string]$it }) }
            if ($st -ne $subType) { $mism.Add([PSCustomObject]@{ field = 'ItemSubType'; expected = [string]$subType; actual = [string]$st }) }
            $types = Get-TcNcAxisChildTypes -SysManager $sm -AxisPath $axisPath
            $data | Add-Member -NotePropertyName encoder -NotePropertyValue $types.encoder
            $data | Add-Member -NotePropertyName drive -NotePropertyValue $types.drive
            $data | Add-Member -NotePropertyName controller -NotePropertyValue $types.controller
            $sim = Test-TcNcSimulationEncoder -Encoder $types.encoder
            $data | Add-Member -NotePropertyName simulation -NotePropertyValue $sim
            if (-not $sim) { $mism.Add([PSCustomObject]@{ field = 'Enc'; expected = 'Simulation encoder (EncType 0/1)'; actual = $(if ($null -eq $types.encoder) { '(no Enc child)' } else { "$($types.encoder.subType) $($types.encoder.subTypeName)" }) }) }
            $id = Get-TcTreeItemXmlValue -Item $item -XPath 'TreeItem/ItemId' -Path $axisPath
            $data | Add-Member -NotePropertyName axisId -NotePropertyValue $(if ($id -match '^\d+$') { [int]$id } else { $null })
        }
        if ($mism.Count -gt 0) {
            $rb = Invoke-TcNcAxisRollback -Path $axisPath
            $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism.ToArray()
            $data | Add-Member -NotePropertyName rollback -NotePropertyValue @($rb)
            $data | Add-Member -NotePropertyName rolledBack -NotePropertyValue $rb.removed
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $txt = ($mism | ForEach-Object { "$($_.field) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; '
            $res = New-TcResult -Success $false -ErrorCode 'NC_AXIS_VERIFY_FAILED' -Data $data `
                -ErrorMessage "CreateChild returned, but the readback differs: $txt; $(if ($rb.removed) { 'the axis was deleted again' } else { "the axis could NOT be deleted ($($rb.message))" })." -Hint (Get-TcErrorHint -Code 'NC_AXIS_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "$change [failed at verify]"
        }
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Add-TcNcAxis $axisPath"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_CREATE_FAILED' -Data $data -Operation 'Add-TcNcAxis'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "$change [failed]" }
        return $res
    }
}
