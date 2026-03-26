function Set-TcTarget {
    <#
    .SYNOPSIS
        Sets the target system AMS Net ID for deployment.
    .PARAMETER AmsNetId
        Target AMS Net ID (e.g., "127.0.0.1.1.1" for local).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        # Set target via ITcSysManager
        $sm.SetTargetNetId($AmsNetId)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            amsNetId = $AmsNetId
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to set target: $_" -ErrorCode 'TARGET_SET_FAILED'
    }
}
