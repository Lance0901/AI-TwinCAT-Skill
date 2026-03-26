function Watch-TcVariable {
    <#
    .SYNOPSIS
        Polls a PLC variable at intervals. Supports duration-based and condition-based monitoring.
    .PARAMETER Path
        Variable path to monitor.
    .PARAMETER IntervalMs
        Polling interval in milliseconds. Default: 100.
    .PARAMETER DurationMs
        Total monitoring duration in milliseconds.
    .PARAMETER Until
        ScriptBlock condition to stop monitoring (receives $_ with .Value property).
    .PARAMETER TimeoutMs
        Max wait time for condition. Default: 5000.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [int]$IntervalMs = 100,

        [Parameter()]
        [int]$DurationMs,

        [Parameter()]
        [scriptblock]$Until,

        [Parameter()]
        [int]$TimeoutMs = 5000
    )

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    try {
        $samples = @()
        $startTime = [DateTime]::Now

        if ($Until) {
            # Condition-based monitoring
            $deadline = $startTime.AddMilliseconds($TimeoutMs)
            $conditionMet = $false

            while ([DateTime]::Now -lt $deadline) {
                $readResult = Read-TcVariable -Path $Path
                if ($readResult.success) {
                    $sample = [PSCustomObject]@{
                        timestamp = [DateTime]::Now.ToString('o')
                        value     = $readResult.data.value
                    }
                    $samples += $sample

                    # Test condition
                    $testObj = [PSCustomObject]@{ Value = $readResult.data.value }
                    if ($Until.InvokeWithContext($null, [psvariable]::new('_', $testObj))) {
                        $conditionMet = $true
                        break
                    }
                }
                Start-Sleep -Milliseconds $IntervalMs
            }

            $elapsed = ([DateTime]::Now - $startTime).TotalMilliseconds
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                path         = $Path
                conditionMet = $conditionMet
                elapsedMs    = [math]::Round($elapsed)
                finalValue   = if ($samples.Count -gt 0) { $samples[-1].value } else { $null }
                sampleCount  = $samples.Count
                samples      = $samples
            })
        }
        else {
            # Duration-based monitoring
            $duration = if ($DurationMs -gt 0) { $DurationMs } else { 2000 }
            $deadline = $startTime.AddMilliseconds($duration)

            while ([DateTime]::Now -lt $deadline) {
                $readResult = Read-TcVariable -Path $Path
                if ($readResult.success) {
                    $samples += [PSCustomObject]@{
                        timestamp = [DateTime]::Now.ToString('o')
                        value     = $readResult.data.value
                    }
                }
                Start-Sleep -Milliseconds $IntervalMs
            }

            New-TcResult -Success $true -Data ([PSCustomObject]@{
                path        = $Path
                sampleCount = $samples.Count
                durationMs  = $duration
                samples     = $samples
            })
        }
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Watch failed: $_" -ErrorCode 'WATCH_FAILED'
    }
}
