function Connect-TcNcAxisToPlc {
    <#
    .SYNOPSIS
        Links an NC axis to a PLC AXIS_REF (two struct links: NcToPlc <-> Outputs^ToPlc, PlcToNc <-> Inputs^FromPlc) and reads the mapping back. Dry-run by default.
    .DESCRIPTION
        Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22, self-built client
        (openspec/changes/complete-automation-interface/verification/phase3-probe.md question 5):
        ITcSysManager.LinkVariables (TE1000 v1.7.0 5.1.1.2 p.38; NC axes in mappings 6.3.14 p.217)
        links the whole struct in one call, in either order:
          PLC '<Plc> Instance^<task> Inputs^<var>.NcToPlc'  <->  NC '<axis>^Outputs^ToPlc'
          PLC '<Plc> Instance^<task> Outputs^<var>.PlcToNc' <->  NC '<axis>^Inputs^FromPlc'
        The PLC instance is the child of TIPC^<Plc> that has process images (read from the tree,
        not assumed to be '<Plc> Instance'). The process image names ('PlcTask Inputs' ...) are found below the PLC instance (every
        '* Inputs' / '* Outputs' child is tried), not hard-coded. The AXIS_REF only shows up there
        after a build: not found -> NC_PLC_VARIABLE_NOT_FOUND (hint: Build-TcProject).
        Links already in the mapping (ProduceMappingInfo, Get-TcMappingLinks, the same readback as
        Set-TcVariableLink): both pairs already linked to each other -> success,
        data.alreadyLinked = true, nothing written; any of the four ends linked to something else ->
        NC_AXIS_ALREADY_LINKED (also when only a member such as '<var>.NcToPlc.ActPos' is linked;
        data.existingLinks; what LinkVariables does with an end that is
        already linked was not measured, so the module refuses: remove the old link with
        Remove-TcVariableLink first).
        DryRun (default true): data.links[] (plc, nc, state). DryRun=false: the mapping is backed up
        (ProduceMappingInfo text, data.backupPath), IDE_MODAL_DIALOG check, LinkVariables for each
        missing pair; when the second one fails - or a modal dialog appears before it - the first is unlinked
        again and the mapping read back (data.partialLinks, data.rolledBack = true only when the
        link is gone from ProduceMappingInfo).
        Readback: both pairs must be in ProduceMappingInfo, else LINK_VERIFY_FAILED.
        XAE errors: TSM_E_MISMATCHINGITEMS -> LINK_TYPE_MISMATCH (e.g. input to input, 0x98510004),
        others LINK_FAILED. BUILD_REQUIRED (code-changed) is recorded once LinkVariables was called.
        Only unit tests so far; registered tcauto verification is task 4.6.
    .PARAMETER Axis
        Axis name or tree path (TINC^NC-Task 1 SAF^Axes^Axis 1).
    .PARAMETER PlcVariable
        Symbol of the PLC AXIS_REF (AT %I* / %Q* members NcToPlc / PlcToNc), e.g. MAIN.axis or GVL_Motion.arAxis[1].
    .PARAMETER PlcProjectPath
        PLC name or tree path when the solution has more than one PLC project.
    .PARAMETER DryRun
        Default true: only report the planned links. false: back up, link, read back.
    .EXAMPLE
        Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis'
    .EXAMPLE
        Connect-TcNcAxisToPlc -Axis 'Axis 1' -PlcVariable 'MAIN.axis' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Axis,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PlcVariable,

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ axis = $Axis; plcVariable = $PlcVariable; dryRun = $DryRun }
    if ([string]::IsNullOrWhiteSpace($PlcVariable) -or $PlcVariable.Contains('^') -or $PlcVariable -match '\.(NcToPlc|PlcToNc)$') {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data `
            -ErrorMessage "-PlcVariable must be the AXIS_REF symbol itself (e.g. MAIN.axis), without '^' and without .NcToPlc / .PlcToNc (got '$PlcVariable'); nothing was linked."
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
        $data | Add-Member -NotePropertyName axisPath -NotePropertyValue $axisPath
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prj = [string]$spec.PlcProjectPath
        $seg = @($prj -split '\^')
        $plcName = if ($seg.Count -ge 2) { $seg[1] } else { $seg[-1] }
        # review N6: the instance node is read from the tree (the child of TIPC^<Plc> with process images)
        $inst = Resolve-TcPlcInstancePath -SysManager $sm -PlcNodePath "TIPC^$plcName" -ProjectPath $prj
        $instancePath = $inst.Path
        $data | Add-Member -NotePropertyName instancePath -NotePropertyValue $instancePath
        if ($null -ne $inst.Note) { Add-TcDataWarning -Data $data -Warning $inst.Note }

        $img = Find-TcPlcAxisRefImage -SysManager $sm -InstancePath $instancePath -PlcVariable $PlcVariable
        if ($null -eq $img.NcToPlc -or $null -eq $img.PlcToNc) {
            $data | Add-Member -NotePropertyName instanceChildren -NotePropertyValue @($img.Images)
            $miss = @(); if ($null -eq $img.NcToPlc) { $miss += "$PlcVariable.NcToPlc (below '* Inputs')" }; if ($null -eq $img.PlcToNc) { $miss += "$PlcVariable.PlcToNc (below '* Outputs')" }
            $why = if ($null -eq $img.Instance) { "the PLC instance '$instancePath' is not found" } else { "not found below '$instancePath': $($miss -join ', ')" }
            return New-TcResult -Success $false -ErrorCode 'NC_PLC_VARIABLE_NOT_FOUND' -Data $data `
                -ErrorMessage "AXIS_REF '$PlcVariable': $why; nothing was linked." -Hint (Get-TcErrorHint -Code 'NC_PLC_VARIABLE_NOT_FOUND')
        }
        $ncOut = "$axisPath^Outputs^ToPlc"
        $ncIn = "$axisPath^Inputs^FromPlc"
        foreach ($p in @($ncOut, $ncIn)) {
            if ($null -eq (Find-TcTreeItemNoThrow -SysManager $sm -Path $p)) {
                return New-TcTreeItemNotFoundResult -SysManager $sm -Path $p -Data $data -ParameterName 'Axis'
            }
        }
        $pairs = @(
            [PSCustomObject]@{ plc = $img.NcToPlc; nc = $ncOut; state = $null },
            [PSCustomObject]@{ plc = $img.PlcToNc; nc = $ncIn; state = $null }
        )
        $links = @(Get-TcMappingLinks -SysManager $sm)
        $foreign = [System.Collections.Generic.List[object]]::new()
        foreach ($pr in $pairs) {
            if (Test-TcMappingHasLink -Links $links -PathA $pr.plc -PathB $pr.nc) { $pr.state = 'linked'; continue }
            $pr.state = 'missing'
            foreach ($l in $links) {
                foreach ($end in @($pr.plc, $pr.nc)) {
                    # review N5: a member of the struct linked on its own ('...NcToPlc.ActPos',
                    # '...^ToPlc^...') counts as linked elsewhere too
                    $hit = $false
                    foreach ($x in @($l.a, $l.b)) {
                        if ($x -ieq $end -or $x.StartsWith("$end.", [System.StringComparison]::OrdinalIgnoreCase) -or $x.StartsWith("$end^", [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $true }
                    }
                    if ($hit) { $foreign.Add([PSCustomObject]@{ a = $l.a; b = $l.b }) }
                }
            }
        }
        $data | Add-Member -NotePropertyName links -NotePropertyValue $pairs
        if ($foreign.Count -gt 0) {
            $data | Add-Member -NotePropertyName existingLinks -NotePropertyValue $foreign.ToArray()
            return New-TcResult -Success $false -ErrorCode 'NC_AXIS_ALREADY_LINKED' -Data $data `
                -ErrorMessage "An end is already linked elsewhere: $(($foreign | ForEach-Object { "'$($_.a)' <-> '$($_.b)'" }) -join '; '); nothing was linked." -Hint (Get-TcErrorHint -Code 'NC_AXIS_ALREADY_LINKED')
        }
        $todo = @($pairs | Where-Object { $_.state -eq 'missing' })
        if ($todo.Count -eq 0) {
            $data | Add-Member -NotePropertyName alreadyLinked -NotePropertyValue $true
            $data | Add-Member -NotePropertyName linked -NotePropertyValue $true
            return New-TcResult -Success $true -Data $data
        }
        $data | Add-Member -NotePropertyName alreadyLinked -NotePropertyValue $false
        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $mapXml = [string](Invoke-TcComRetry -OperationName 'ProduceMappingInfo' -ScriptBlock { $sm.ProduceMappingInfo() })
        $bk = New-TcConfigBackup -Label 'MappingInfo' -Text $mapXml -Data $data
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $done = [System.Collections.Generic.List[object]]::new()
        # review S7: undo the links this call made and read the mapping back; rolledBack is true
        # only when ProduceMappingInfo no longer has any of them. data.partialLinks lists them.
        $undo = {
            $data | Add-Member -NotePropertyName partialLinks -NotePropertyValue @($done | ForEach-Object { [PSCustomObject]@{ plc = $_.plc; nc = $_.nc } }) -Force
            $unlinkErrors = [System.Collections.Generic.List[string]]::new()
            foreach ($d in $done) {
                try { Invoke-TcComRetry -OperationName 'UnlinkVariables' -ScriptBlock { $sm.UnlinkVariables($d.plc, $d.nc) } | Out-Null }
                catch { $unlinkErrors.Add($_.Exception.Message) }
            }
            $ok = $true
            if ($done.Count -gt 0) {
                try {
                    $now = @(Get-TcMappingLinks -SysManager $sm)
                    $left = @($done | Where-Object { Test-TcMappingHasLink -Links $now -PathA $_.plc -PathB $_.nc })
                    if ($left.Count -gt 0) { $ok = $false }
                }
                catch { $ok = $false; $unlinkErrors.Add("mapping readback: $($_.Exception.Message)") }
            }
            if ($unlinkErrors.Count -gt 0) { $data | Add-Member -NotePropertyName unlinkErrors -NotePropertyValue $unlinkErrors.ToArray() -Force }
            $data | Add-Member -NotePropertyName rolledBack -NotePropertyValue $ok -Force
            $ok
        }
        foreach ($pr in $todo) {
            $dlg = Get-TcTreeItemDialogResult -Operation "LinkVariables '$($pr.plc)'" -Data $data
            if ($null -ne $dlg) {
                if ($called) {
                    $rb = & $undo
                    $dlg.error.message = "$($dlg.error.message); $(if ($rb) { 'the link made before was removed again (mapping read back)' } else { 'the link made before could NOT be removed (data.partialLinks)' })"
                    $dlg = Register-TcCodeChange -Result $dlg -Change "Connect-TcNcAxisToPlc $axisPath [failed]"
                }
                return $dlg
            }
            $called = $true
            try { Invoke-TcComRetry -OperationName 'LinkVariables' -ScriptBlock { $sm.LinkVariables($pr.plc, $pr.nc) } | Out-Null; $done.Add($pr) }
            catch {
                $err = $_
                $rolledBack = & $undo
                $pass = Get-TcTreeItemPassThroughError -ErrorRecord $err
                $code = if ($null -ne $pass) { $pass.Code } else { ConvertTo-TcTsmErrorCode -InputObject $err -DefaultCode 'LINK_FAILED' }
                if ($code -eq 'TREEITEM_NOT_FOUND') { $code = 'LINK_FAILED' }
                $res = New-TcResult -Success $false -ErrorCode $code -Data $data `
                    -ErrorMessage "LinkVariables('$($pr.plc)', '$($pr.nc)') failed: $($err.Exception.Message); $(if ($done.Count -eq 0) { 'nothing was linked' } elseif ($rolledBack) { 'the link made before was removed again' } else { 'the link made before could NOT be removed' })." `
                    -Hint $(if ($null -ne $pass) { $pass.Hint } else { Get-TcErrorHint -Code $code })
                return Register-TcCodeChange -Result $res -Change "Connect-TcNcAxisToPlc $axisPath [failed]"
            }
        }
        $after = @(Get-TcMappingLinks -SysManager $sm)
        $data | Add-Member -NotePropertyName mappingLinkCount -NotePropertyValue $after.Count
        $notIn = @($pairs | Where-Object { -not (Test-TcMappingHasLink -Links $after -PathA $_.plc -PathB $_.nc) })
        if ($notIn.Count -gt 0) {
            $data | Add-Member -NotePropertyName linked -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'LINK_VERIFY_FAILED' -Data $data `
                -ErrorMessage "LinkVariables returned, but ProduceMappingInfo has no link $(($notIn | ForEach-Object { "'$($_.plc)' <-> '$($_.nc)'" }) -join ', ')." -Hint (Get-TcErrorHint -Code 'LINK_VERIFY_FAILED')
            return Register-TcCodeChange -Result $res -Change "Connect-TcNcAxisToPlc $axisPath [failed at verify]"
        }
        foreach ($pr in $pairs) { $pr.state = 'linked' }
        $data | Add-Member -NotePropertyName linked -NotePropertyValue $true
        return Register-TcCodeChange -Result (New-TcResult -Success $true -Data $data) -Change "Connect-TcNcAxisToPlc $axisPath $PlcVariable"
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'LINK_FAILED' -Data $data -Operation 'Connect-TcNcAxisToPlc'
        if ($called) { $res = Register-TcCodeChange -Result $res -Change "Connect-TcNcAxisToPlc $Axis [failed]" }
        return $res
    }
}
