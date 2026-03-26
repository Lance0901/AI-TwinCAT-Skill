function Enable-TcConfig {
    <#
    .SYNOPSIS
        Activates the TwinCAT configuration on the target system.
    .PARAMETER Force
        If set, forces a TwinCAT restart if required.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        # ActivateConfiguration params: force restart mode
        # 0 = normal, 1 = force restart
        $restartMode = if ($Force) { 1 } else { 0 }
        $sm.ActivateConfiguration($restartMode)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            activated    = $true
            forceRestart = $Force.IsPresent
        })
    }
    catch {
        if ($_.Exception.Message -match 'restart') {
            New-TcResult -Success $false `
                -ErrorMessage 'Configuration activation requires TwinCAT restart. Use -Force to auto-restart.' `
                -ErrorCode 'RESTART_REQUIRED'
        }
        else {
            New-TcResult -Success $false -ErrorMessage "Activation failed: $_" -ErrorCode 'ACTIVATION_FAILED'
        }
    }
}
