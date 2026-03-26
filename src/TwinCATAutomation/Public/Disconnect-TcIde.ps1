function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Disconnects from the TwinCAT IDE and releases COM references.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    if ($null -ne $script:TcDte) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcDte) | Out-Null } catch { }
        $script:TcDte = $null
    }

    $script:TcIdeConnected = $false
    $script:TcProgId = $null

    New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'Disconnected from TwinCAT IDE.' })
}
