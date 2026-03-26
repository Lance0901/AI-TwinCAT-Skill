function Set-TcVariableLink {
    <#
    .SYNOPSIS
        Links a PLC variable to an I/O channel.
    .PARAMETER PlcVariable
        PLC variable path (e.g., "MAIN.bInput1").
    .PARAMETER IoChannel
        I/O channel tree path (e.g., "TIID^Device 1^Term 1^Channel 1").
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
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        $ioItem = $sm.LookupTreeItem($IoChannel)

        # Use LinkTo method to create the variable link
        $ioItem.LinkTo($PlcVariable)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            plcVariable = $PlcVariable
            ioChannel   = $IoChannel
            linked      = $true
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to link variable: $_" -ErrorCode 'LINK_FAILED'
    }
}
