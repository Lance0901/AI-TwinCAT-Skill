function Remove-TcVariableLink {
    <#
    .SYNOPSIS
        Removes the link between a PLC variable and an I/O variable (ITcSysManager.UnlinkVariables) and reads the mapping back.
    .DESCRIPTION
        Uses ITcSysManager.UnlinkVariables(bstrV1, bstrV2) (TE1000 Automation Interface manual v1.7.0,
        5.1.1.8, p.41; sample in 6.3.14, p.217-218). Paths are full tree paths, as for
        Set-TcVariableLink. Without -IoChannel all links of -PlcVariable are removed
        (5.1.1.8: bstrV2 empty removes all links from bstrV1).
        Both paths are checked with LookupTreeItem first (TREEITEM_NOT_FOUND names the missing end).
        Afterwards ProduceMappingInfo() is read: data.removed = true only when no matching link is left,
        otherwise LINK_VERIFY_FAILED. data.wasLinked tells whether the link existed before.
    .PARAMETER PlcVariable
        Full tree path of the PLC variable, e.g. "TIPC^MyPlc^MyPlc Instance^PlcTask Inputs^MAIN.bIn".
    .PARAMETER IoChannel
        Full tree path of the I/O variable. Omit to remove all links of -PlcVariable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlcVariable,

        [Parameter()]
        [string]$IoChannel = ''
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $data = [PSCustomObject]@{ plcVariable = $PlcVariable; ioChannel = $IoChannel; wasLinked = $null; removed = $false }
    $ends = @(@{ Name = 'PlcVariable'; Path = $PlcVariable })
    if (-not [string]::IsNullOrEmpty($IoChannel)) { $ends += @{ Name = 'IoChannel'; Path = $IoChannel } }

    $matchesPlc = {
        param($links)
        @($links | Where-Object {
                if ([string]::IsNullOrEmpty($IoChannel)) { $_.a -ieq $PlcVariable -or $_.b -ieq $PlcVariable }
                else { Test-TcMappingHasLink -Links @($_) -PathA $PlcVariable -PathB $IoChannel }
            })
    }
    try {
        foreach ($end in $ends) {
            $err = Test-TcTreeItemExists -SysManager $sm -Path $end.Path
            if ($null -ne $err) {
                $data | Add-Member -NotePropertyName missingEnd -NotePropertyValue $end.Name
                return New-TcResult -Success $false -ErrorCode 'TREEITEM_NOT_FOUND' -Data $data `
                    -ErrorMessage "$($end.Name) tree item not found: $($end.Path) ($err)" `
                    -Hint ("-$($end.Name) '$($end.Path)' 不存在。" + (Get-TcErrorHint -Code 'TREEITEM_NOT_FOUND'))
            }
        }
        $before = @(Get-TcMappingLinks -SysManager $sm)
        $data.wasLinked = (@(& $matchesPlc $before).Count -gt 0)

        # TE1000 5.1.1.8 (p.41): HRESULT UnlinkVariables(BSTR bstrV1, BSTR bstrV2)
        Invoke-TcComRetry -OperationName 'UnlinkVariables' -ScriptBlock { $sm.UnlinkVariables($PlcVariable, $IoChannel) } | Out-Null
    }
    catch {
        $code = ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'UNLINK_FAILED'
        return New-TcResult -Success $false -ErrorCode $code -Data $data `
            -ErrorMessage "UnlinkVariables failed: $($_.Exception.Message)" -Hint (Get-TcErrorHint -Code $code)
    }

    try {
        $after = @(Get-TcMappingLinks -SysManager $sm)
    }
    catch {
        return New-TcResult -Success $false -ErrorCode 'LINK_VERIFY_FAILED' -Data $data `
            -ErrorMessage "UnlinkVariables returned, but ProduceMappingInfo could not be read: $($_.Exception.Message)" `
            -Hint (Get-TcErrorHint -Code 'LINK_VERIFY_FAILED')
    }
    $left = @(& $matchesPlc $after)
    if ($left.Count -gt 0) {
        $data | Add-Member -NotePropertyName remainingLinks -NotePropertyValue $left
        return New-TcResult -Success $false -ErrorCode 'LINK_VERIFY_FAILED' -Data $data `
            -ErrorMessage 'UnlinkVariables returned, but ProduceMappingInfo still has the link.' `
            -Hint (Get-TcErrorHint -Code 'LINK_VERIFY_FAILED')
    }
    $data.removed = $true
    New-TcResult -Success $true -Data $data
}
