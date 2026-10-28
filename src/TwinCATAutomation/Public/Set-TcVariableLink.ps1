function Set-TcVariableLink {
    <#
    .SYNOPSIS
        Links a PLC variable to an I/O variable (ITcSysManager.LinkVariables) and reads the mapping back.
    .DESCRIPTION
        Uses ITcSysManager.LinkVariables(bstrV1, bstrV2) (TE1000 Automation Interface manual v1.7.0,
        5.1.1.2, p.38; sample in 6.3.14, p.217). Both ends must be FULL tree paths, separated by '^'
        (5.1.1.2: "The full path name is required"), and both must be variables:
          PLC: TIPC^<Plc>^<Plc> Instance^PlcTask Inputs^MAIN.bIn   (an AT %I* / %Q* variable, after a Build)
          I/O: TIID^<Device>^<Box>^<Term>^Channel 1^Input          (the variable, not the Channel node)
        Both paths are checked with LookupTreeItem first (TREEITEM_NOT_FOUND names the missing end).
        TSM_E_INVALIDITEMTYPE -> LINK_INVALID_ITEM_TYPE, TSM_E_MISMATCHINGITEMS -> LINK_TYPE_MISMATCH.
        After linking, ProduceMappingInfo() (5.1.3.4, p.45) is read: data.linked = true only when the
        link is in the mapping, otherwise LINK_VERIFY_FAILED. Remove a link with Remove-TcVariableLink.
    .PARAMETER PlcVariable
        Full tree path of the PLC variable, e.g. "TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.bIn".
    .PARAMETER IoChannel
        Full tree path of the I/O variable, e.g. "TIID^EtherCAT Master^Term 1 (EK1100)^Term 2 (EL1004)^Channel 1^Input".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlcVariable,

        [Parameter(Mandatory)]
        [string]$IoChannel
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $data = [PSCustomObject]@{ plcVariable = $PlcVariable; ioChannel = $IoChannel; linked = $false }
    try {
        foreach ($end in @(@{ Name = 'PlcVariable'; Path = $PlcVariable }, @{ Name = 'IoChannel'; Path = $IoChannel })) {
            $err = Test-TcTreeItemExists -SysManager $sm -Path $end.Path
            if ($null -ne $err) {
                $data | Add-Member -NotePropertyName missingEnd -NotePropertyValue $end.Name
                return New-TcResult -Success $false -ErrorCode 'TREEITEM_NOT_FOUND' -Data $data `
                    -ErrorMessage "$($end.Name) tree item not found: $($end.Path) ($err)" `
                    -Hint ("-$($end.Name) '$($end.Path)' 不存在。" + (Get-TcErrorHint -Code 'TREEITEM_NOT_FOUND'))
            }
        }

        # TE1000 5.1.1.2 (p.38): HRESULT LinkVariables(BSTR bstrV1, BSTR bstrV2, long offs1, long offs2, long size)
        Invoke-TcComRetry -OperationName 'LinkVariables' -ScriptBlock { $sm.LinkVariables($PlcVariable, $IoChannel) } | Out-Null
    }
    catch {
        $code = ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'LINK_FAILED'
        return New-TcResult -Success $false -ErrorCode $code -Data $data `
            -ErrorMessage "LinkVariables failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code $code)
    }

    try {
        $links = @(Get-TcMappingLinks -SysManager $sm)
    }
    catch {
        return New-TcResult -Success $false -ErrorCode 'LINK_VERIFY_FAILED' -Data $data `
            -ErrorMessage "LinkVariables returned, but ProduceMappingInfo could not be read: $($_.Exception.Message)" `
            -Hint (Get-TcErrorHint -Code 'LINK_VERIFY_FAILED')
    }
    $data | Add-Member -NotePropertyName mappingLinkCount -NotePropertyValue $links.Count
    if (-not (Test-TcMappingHasLink -Links $links -PathA $PlcVariable -PathB $IoChannel)) {
        return New-TcResult -Success $false -ErrorCode 'LINK_VERIFY_FAILED' -Data $data `
            -ErrorMessage 'LinkVariables returned, but ProduceMappingInfo has no link between the two paths.' `
            -Hint (Get-TcErrorHint -Code 'LINK_VERIFY_FAILED')
    }
    $data.linked = $true
    New-TcResult -Success $true -Data $data
}
