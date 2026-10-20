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
        ScriptBlock condition to stop monitoring. $_ has .Value (as Read-TcVariable reports it: the IEC
        literal for TIME/DATE types), .Raw (the ms/ns/unix integer of a time type, else same as Value) and
        .Name (enum member name or $null). Compare time types with .Raw: { $_.Raw -ge 5000 }.
    .PARAMETER TimeoutMs
        Max wait time for condition. Default: 5000.
    .NOTES
        Samples use the Read-TcVariable conversion: {timestamp, value} plus ms/ns/unix (raw integer)
        for TIME/DATE types (value is the IEC literal) and name (member name) for enums.
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

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
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
                    $sample = New-TcWatchSample -Data $readResult.data
                    $samples += $sample

                    # Test condition
                    $testObj = [PSCustomObject]@{
                        Value = $readResult.data.value
                        Raw   = Get-TcVariableRawValue -Data $readResult.data
                        Name  = if ($null -ne $readResult.data.PSObject.Properties['name']) { $readResult.data.name } else { $null }
                    }
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
                reconnected  = $reconnected
            })
        }
        else {
            # Duration-based monitoring
            $duration = if ($DurationMs -gt 0) { $DurationMs } else { 2000 }
            $deadline = $startTime.AddMilliseconds($duration)

            while ([DateTime]::Now -lt $deadline) {
                $readResult = Read-TcVariable -Path $Path
                if ($readResult.success) {
                    $samples += New-TcWatchSample -Data $readResult.data
                }
                Start-Sleep -Milliseconds $IntervalMs
            }

            New-TcResult -Success $true -Data ([PSCustomObject]@{
                path        = $Path
                sampleCount = $samples.Count
                durationMs  = $duration
                samples     = $samples
                reconnected = $reconnected
            })
        }
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'WATCH_FAILED' -MessagePrefix 'Watch failed'
    }
}
