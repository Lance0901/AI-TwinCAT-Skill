function Set-TcNcAxisParameter {
    <#
    .SYNOPSIS
        Sets measured NC axis fields (max velocity, acceleration, deceleration, jerk, encoder / drive / controller type) with ConsumeXml and reads every field back. Dry-run by default.
    .DESCRIPTION
        The axis ProduceXml holds the whole <NcAxisDef> and ConsumeXml changes only the sent fields
        (measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client,
        openspec/changes/complete-automation-interface/verification/phase3-probe.md question 3;
        TE1000 v1.7.0 6.10.1 p.294 only says "ProduceXml as template, ConsumeXml back"). Fields:
          MaxVelocity    NcAxisDef/AxisParam/Velo/Maximum         (written + read back in the probe)
          Acceleration   NcAxisDef/AxisParam/Dynamic/Acceleration (written + read back in the probe)
          Deceleration   NcAxisDef/AxisParam/Dynamic/Deceleration (same element, not written there)
          Jerk           NcAxisDef/AxisParam/Dynamic/Jerk          (same element, not written there)
          EncoderType    NcAxisDef/Encoder/EncType      DriveType  NcAxisDef/Drive/DrvType
          ControllerType NcAxisDef/Controller/CtrType   (question 4: ChangeChildSubType is E_NOTIMPL)
        XAE answers S_OK for everything ('abc' becomes 0, unknown type numbers are stored with an
        empty ItemSubTypeName), so the module checks before sending: numbers finite, > 0 (Jerk >= 0)
        and <= 1e12 (INVALID_PARAMS); type numbers only those XAE names (drive 1-17, 20-24; encoder
        0-8, 10-21, 24-29; controller 1-3, 5-14; else NC_INVALID_SUBTYPE). A field that is not in this
        axis' ProduceXml -> NC_AXIS_PARAM_NOT_FOUND.
        DryRun (default true): data.changes[] (parameter, xpath, current, planned, changed), data.xml.
        DryRun=false: ProduceXml backup (data.backupPath), IDE_MODAL_DIALOG check, ConsumeXml, then
        ProduceXml again: every field must have its planned value (numbers compared with a relative
        tolerance of 1e-9) else NC_AXIS_PARAM_VERIFY_FAILED (data.mismatches); a changed type must
        give a non-empty ItemSubTypeName on the Enc / Drive / Ctrl child, else the old type numbers
        are sent back (data.reverted) and NC_INVALID_SUBTYPE. Nothing to change: success,
        data.written = false. BUILD_REQUIRED (code-changed) is recorded once ConsumeXml was called.
        The axis type (Continuous / Discrete ...) is fixed at creation (Add-TcNcAxis -AxisType).
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Axis
        Axis name or tree path (TINC^NC-Task 1 SAF^Axes^Axis 1).
    .PARAMETER MaxVelocity
        AxisParam/Velo/Maximum (axis unit per s, > 0).
    .PARAMETER Acceleration
        AxisParam/Dynamic/Acceleration (> 0).
    .PARAMETER Deceleration
        AxisParam/Dynamic/Deceleration (> 0).
    .PARAMETER Jerk
        AxisParam/Dynamic/Jerk (>= 0).
    .PARAMETER EncoderType
        Encoder/EncType number (0 / 1 = Simulation encoder).
    .PARAMETER DriveType
        Drive/DrvType number (5 = KL4XXX, the default).
    .PARAMETER ControllerType
        Controller/CtrType number (1 = Position controller P, the default).
    .PARAMETER DryRun
        Default true: only report the planned change. false: back up, write, read back.
    .EXAMPLE
        Set-TcNcAxisParameter -Axis 'Axis 1' -MaxVelocity 1500 -Acceleration 500
    .EXAMPLE
        Set-TcNcAxisParameter -Axis 'TINC^NC-Task 1 SAF^Axes^Axis 1' -MaxVelocity 1500 -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Axis,

        [Parameter()]
        [double]$MaxVelocity,

        [Parameter()]
        [double]$Acceleration,

        [Parameter()]
        [double]$Deceleration,

        [Parameter()]
        [double]$Jerk,

        [Parameter()]
        [int]$EncoderType,

        [Parameter()]
        [int]$DriveType,

        [Parameter()]
        [int]$ControllerType,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ axis = $Axis; dryRun = $DryRun }
    $given = [ordered]@{}
    foreach ($k in $script:TcNcAxisFields.Keys) { if ($PSBoundParameters.ContainsKey($k)) { $given[$k] = $PSBoundParameters[$k] } }
    if ($given.Count -eq 0) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data `
            -ErrorMessage "Give at least one of $(@($script:TcNcAxisFields.Keys) -join ', '); nothing was written."
    }
    # checks before anything else (XAE stores wrong values silently)
    foreach ($k in @($given.Keys)) {
        $f = $script:TcNcAxisFields[$k]
        $v = $given[$k]
        if ($f.Kind -eq 'number') {
            $d = [double]$v
            $bad = [double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -gt $script:TcNcAxisNumberMax -or ($f.MinExclusive -and $d -le $f.Min) -or (-not $f.MinExclusive -and $d -lt $f.Min)
            if ($bad) {
                $rule = if ($f.MinExclusive) { "> $($f.Min)" } else { ">= $($f.Min)" }
                return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data `
                    -ErrorMessage "-$k must be a finite number $rule and <= $($script:TcNcAxisNumberMax) (got $d); nothing was written (XAE would store it without an error)."
            }
        }
        else {
            $allowed = switch ($k) { 'EncoderType' { $script:TcNcEncoderTypes } 'DriveType' { $script:TcNcDriveTypes } default { $script:TcNcControllerTypes } }
            if (@($allowed) -notcontains [int]$v) {
                $data | Add-Member -NotePropertyName allowedTypes -NotePropertyValue @($allowed) -Force
                return New-TcResult -Success $false -ErrorCode 'NC_INVALID_SUBTYPE' -Data $data `
                    -ErrorMessage "-$k $v is not a type number XAE names (allowed: $(@($allowed) -join ', ')); nothing was written." -Hint (Get-TcErrorHint -Code 'NC_INVALID_SUBTYPE')
            }
        }
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $called = $false
    try {
        $ax = Resolve-TcNcAxis -SysManager $sm -Axis $Axis -Data $data
        if ($null -ne $ax.Result) { return $ax.Result }
        $axisPath = $ax.Path
        $item = $ax.Item
        $data | Add-Member -NotePropertyName axisPath -NotePropertyValue $axisPath
        $before = Get-TcTreeItemXmlText -Item $item -Path $axisPath
        $doc = ConvertFrom-TcTreeItemXmlString -Xml $before
        if ($null -eq $doc) {
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_READ_FAILED' -Data $data -ErrorMessage "ProduceXml('$axisPath') returned no readable XML; nothing was written." -Hint (Get-TcErrorHint -Code 'TREEITEM_READ_FAILED')
        }
        $changes = [System.Collections.Generic.List[object]]::new()
        $planned = [ordered]@{}
        $missing = [System.Collections.Generic.List[string]]::new()
        foreach ($k in @($given.Keys)) {
            $f = $script:TcNcAxisFields[$k]
            $node = $doc.SelectSingleNode("TreeItem/$($f.XPath)")
            if ($null -eq $node) { $missing.Add("$k ($($f.XPath))"); continue }
            $cur = [string]$node.InnerText
            if ($f.Kind -eq 'number') {
                $text = ConvertTo-TcInvariantNumberText -Value ([double]$given[$k])
                $cd = ConvertFrom-TcInvariantNumberText -Text $cur
                $same = ($null -ne $cd -and [Math]::Abs($cd - [double]$given[$k]) -le 1e-9 * [Math]::Max(1.0, [Math]::Abs([double]$given[$k])))
            }
            else {
                $text = [string][int]$given[$k]
                $same = ($cur.Trim() -eq $text)
            }
            $changes.Add([PSCustomObject]@{ parameter = $k; xpath = $f.XPath; current = $cur; planned = $text; changed = (-not $same) })
            if (-not $same) { $planned[$f.XPath] = $text }
        }
        $data | Add-Member -NotePropertyName changes -NotePropertyValue $changes.ToArray()
        if ($missing.Count -gt 0) {
            $data | Add-Member -NotePropertyName missingFields -NotePropertyValue $missing.ToArray()
            return New-TcResult -Success $false -ErrorCode 'NC_AXIS_PARAM_NOT_FOUND' -Data $data `
                -ErrorMessage "The ProduceXml of '$axisPath' has no $($missing -join ', '); nothing was written (XAE ignores unknown elements with S_OK)." -Hint (Get-TcErrorHint -Code 'NC_AXIS_PARAM_NOT_FOUND')
        }
        if ($planned.Count -eq 0) {
            $data | Add-Member -NotePropertyName written -NotePropertyValue $false
            return New-TcResult -Success $true -Data $data
        }
        $xml = New-TcNcAxisFragment -Values $planned
        $data | Add-Member -NotePropertyName xml -NotePropertyValue $xml
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $bk = Invoke-TcTreeItemBackup -Item $item -Path $axisPath -Data $data -Xml $before
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup
        $dlg = Get-TcTreeItemDialogResult -Operation "ConsumeXml '$axisPath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $called = $true
        $data | Add-Member -NotePropertyName writeCalled -NotePropertyValue $true -Force
        # No deadline (CODING_STANDARDS.md 1): a dialog was ruled out just above, SilentMode is on and
        # the axis ConsumeXml returned in 54 ms (phase3-probe.md question 3).
        try { Invoke-TcComRetry -OperationName "ConsumeXml $axisPath" -ScriptBlock { $item.ConsumeXml($xml) } | Out-Null }
        catch {
            $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'NC_AXIS_PARAM_WRITE_FAILED' -Data $data -Operation "ConsumeXml '$axisPath'"
            return Register-TcCodeChange -Result $res -Change "Set-TcNcAxisParameter $axisPath [failed]"
        }
        $data | Add-Member -NotePropertyName written -NotePropertyValue $true

        # readback
        $afterDoc = ConvertFrom-TcTreeItemXmlString -Xml (Get-TcTreeItemXmlText -Item $item -Path $axisPath)
        $mism = [System.Collections.Generic.List[object]]::new()
        foreach ($ch in @($changes | Where-Object { $_.changed })) {
            $n = if ($null -ne $afterDoc) { $afterDoc.SelectSingleNode("TreeItem/$($ch.xpath)") } else { $null }
            $act = if ($null -ne $n) { [string]$n.InnerText } else { $null }
            $f = $script:TcNcAxisFields[$ch.parameter]
            $ok = $false
            if ($null -ne $act) {
                if ($f.Kind -eq 'number') {
                    $ad = ConvertFrom-TcInvariantNumberText -Text $act
                    $pd = [double]$given[$ch.parameter]
                    $ok = ($null -ne $ad -and [Math]::Abs($ad - $pd) -le 1e-9 * [Math]::Max(1.0, [Math]::Abs($pd)))
                }
                else { $ok = ($act.Trim() -eq $ch.planned) }
            }
            if (-not $ok) { $mism.Add([PSCustomObject]@{ parameter = $ch.parameter; xpath = $ch.xpath; expected = $ch.planned; actual = $act }) }
        }
        # a changed type must have a name (an unknown number is stored with an empty ItemSubTypeName)
        $unnamed = [System.Collections.Generic.List[object]]::new()
        foreach ($ch in @($changes | Where-Object { $_.changed -and $script:TcNcAxisFields[$_.parameter].Kind -eq 'type' })) {
            $childPath = "$axisPath^$($script:TcNcAxisFields[$ch.parameter].Child)"
            $cItem = Find-TcTreeItemNoThrow -SysManager $sm -Path $childPath
            $nm = [string](Get-TcTreeItemPropertyNoThrow -Item $cItem -Name 'ItemSubTypeName' -Default '')
            if ([string]::IsNullOrWhiteSpace($nm)) { $unnamed.Add([PSCustomObject]@{ parameter = $ch.parameter; child = $childPath; planned = $ch.planned; previous = $ch.current }) }
        }
        if ($unnamed.Count -gt 0) {
            $restore = [ordered]@{}
            foreach ($u in $unnamed) { $restore[$script:TcNcAxisFields[$u.parameter].XPath] = $u.previous }
            $reverted = $false
            $revertError = $null
            $dlg2 = Get-TcTreeItemDialogResult -Operation "ConsumeXml '$axisPath' (revert type)" -Data $data
            if ($null -eq $dlg2) {
                $rx = New-TcNcAxisFragment -Values $restore
                try { Invoke-TcComRetry -OperationName "ConsumeXml $axisPath (revert)" -ScriptBlock { $item.ConsumeXml($rx) } | Out-Null; $reverted = $true }
                catch { $revertError = $_.Exception.Message }
            }
            else { $revertError = 'a modal dialog is open in XAE' }
            $data | Add-Member -NotePropertyName unnamedTypes -NotePropertyValue $unnamed.ToArray()
            $data | Add-Member -NotePropertyName reverted -NotePropertyValue $reverted
            if ($null -ne $revertError) { $data | Add-Member -NotePropertyName revertError -NotePropertyValue $revertError }
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'NC_INVALID_SUBTYPE' -Data $data `
                -ErrorMessage "XAE accepted $(($unnamed | ForEach-Object { "$($_.parameter) $($_.planned)" }) -join ', ') but has no name for it (empty ItemSubTypeName); $(if ($reverted) { 'the previous type numbers were sent back' } else { "the previous type numbers could NOT be sent back ($revertError)" })." -Hint (Get-TcErrorHint -Code 'NC_INVALID_SUBTYPE')
            return Register-TcCodeChange -Result $res -Change "Set-TcNcAxisParameter $axisPath [failed]"
        }
        if ($mism.Count -gt 0) {
            $data | Add-Member -NotePropertyName mismatches -NotePropertyValue $mism.ToArray()
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'NC_AXIS_PARAM_VERIFY_FAILED' -Data $data `
                -ErrorMessage ('ConsumeXml returned, but the readback differs: ' + (($mism | ForEach-Object { "$($_.parameter) expected '$($_.expected)' actual '$($_.actual)'" }) -join '; ')) -Hint (Get-TcErrorHint -Code 'NC_AXIS_PARAM_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "Set-TcNcAxisParameter $axisPath [failed at verify]"
        }
        $types = Get-TcNcAxisChildTypes -SysManager $sm -AxisPath $axisPath
        $data | Add-Member -NotePropertyName encoder -NotePropertyValue $types.encoder
        $data | Add-Member -NotePropertyName drive -NotePropertyValue $types.drive
        $data | Add-Member -NotePropertyName controller -NotePropertyValue $types.controller
        $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Set-TcNcAxisParameter $axisPath"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'NC_AXIS_PARAM_WRITE_FAILED' -Data $data -Operation 'Set-TcNcAxisParameter'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Set-TcNcAxisParameter $Axis [failed]" }
        return $res
    }
}
