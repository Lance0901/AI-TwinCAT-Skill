function Enable-TcConfig {
    <#
    .SYNOPSIS
        Activates the TwinCAT configuration and optionally starts TwinCAT into Run mode.
    .DESCRIPTION
        Uses ITcSysManager::ActivateConfiguration() to activate, then ADS WriteControl
        to switch to Run mode (no dialog popups).
    .PARAMETER Force
        If set, switches to Config mode first, activates, then starts Run mode.
        Full cycle: Config → Activate → Run.
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
        $restarted = $false

        if ($Force) {
            # Switch to Config mode first via ADS (no dialog)
            $result = Set-TcSystemState -State Config
            if (-not $result.success) {
                return New-TcResult -Success $false -ErrorMessage "Failed to switch to Config: $($result.error.message)" -ErrorCode 'CONFIG_SWITCH_FAILED'
            }
            Start-Sleep -Seconds 2
        }

        # ActivateConfiguration — saves config to registry
        $sm.ActivateConfiguration()

        if ($Force) {
            # Start TwinCAT into Run mode via ADS (no dialog)
            $result = Set-TcSystemState -State Run
            if (-not $result.success) {
                return New-TcResult -Success $false -ErrorMessage "Failed to switch to Run: $($result.error.message)" -ErrorCode 'RUN_SWITCH_FAILED'
            }
            $restarted = $true
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            activated = $true
            restarted = $restarted
            message   = if ($restarted) { 'Configuration activated and TwinCAT started (no dialogs).' } else { 'Configuration activated. Call with -Force to restart TwinCAT.' }
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Activation failed: $_" -ErrorCode 'ACTIVATION_FAILED'
    }
}
