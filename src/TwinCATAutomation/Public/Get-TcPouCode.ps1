function Get-TcPouCode {
    <#
    .SYNOPSIS
        Reads declaration and implementation code from an existing POU.
    .PARAMETER PouName
        Name of the POU to read.
    .PARAMETER PouPath
        Full tree path to the POU, e.g. TIPC^<Plc>^<Plc> Project^POUs^<name> (same format on
        4024 and 4026; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>). If omitted (or not found),
        the POU is looked up by PouName: POUs folder -> project root -> tree search (depth 4).
        data.pouPath / data.resolvedBy report which path was used.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PouName,

        [Parameter()]
        [string]$PouPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    try {
        $r = Resolve-TcPouPath -SysManager $sm -Name $PouName -PouPath $PouPath
        if (-not $r.Found) {
            return New-TcPouNotFoundResult -Name $PouName -Resolution $r
        }
        $pouItem = $r.Item

        $declText = try { Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $pouItem.DeclarationText } } catch { '' }
        $implText = try { Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText } } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou            = $PouName
            pouPath        = $r.Path
            resolvedBy     = $r.ResolvedBy
            declaration    = $declText
            implementation = $implText
        })
    }
    catch {
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_READ_FAILED' -MessagePrefix 'Failed to read POU code'
    }
}
