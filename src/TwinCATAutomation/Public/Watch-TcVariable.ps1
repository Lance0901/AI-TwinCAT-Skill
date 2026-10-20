function Test-TcWatchCondition {
    <#
    .SYNOPSIS
        Evaluates one Watch-TcVariable -Until condition against a sampled value.
    .DESCRIPTION
        Numeric comparison when both sides parse as double (InvariantCulture; bool True/False
        counts as 1/0). Otherwise boolean comparison when the value is [bool] or the expected
        text is TRUE/FALSE (only == and != can hold). Otherwise case-insensitive string
        comparison. A $null value (failed read) never satisfies the condition.
    #>
    param(
        [object]$Value,
        [string]$Operator,
        [string]$Expected
    )

    if ($null -eq $Value) { return $false }

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $numStyle = [System.Globalization.NumberStyles]::Float

    # Numeric
    $valueText = if ($Value -is [bool]) { if ($Value) { '1' } else { '0' } } else { [string]$Value }
    $expectedText = $Expected
    if ($expectedText -match '^(?i:true|false)$' -and ($Value -is [bool] -or $valueText -match '^[01]$')) {
        # TRUE/FALSE in the condition against a numeric/bool value: treat as 1/0
        $expectedText = if ($expectedText -match '^(?i:true)$') { '1' } else { '0' }
    }
    $a = 0.0; $b = 0.0
    if ([double]::TryParse($valueText, $numStyle, $inv, [ref]$a) -and
        [double]::TryParse($expectedText, $numStyle, $inv, [ref]$b)) {
        switch ($Operator) {
            '==' { return ($a -eq $b) }
            '!=' { return ($a -ne $b) }
            '>'  { return ($a -gt $b) }
            '<'  { return ($a -lt $b) }
            '>=' { return ($a -ge $b) }
            '<=' { return ($a -le $b) }
        }
        return $false
    }

    # Boolean
    if ($Value -is [bool] -or $Expected -match '^(?i:true|false)$') {
        $vText = ([string]$Value).Trim()
        if ($vText -notmatch '^(?i:true|false)$') { return $false }
        $vBool = $vText -match '^(?i:true)$'
        $eBool = $Expected -match '^(?i:true)$'
        switch ($Operator) {
            '==' { return ($vBool -eq $eBool) }
            '!=' { return ($vBool -ne $eBool) }
        }
        return $false
    }

    # String (case-insensitive)
    $cmp = [string]::Compare([string]$Value, $Expected, [System.StringComparison]::OrdinalIgnoreCase)
    switch ($Operator) {
        '==' { return ($cmp -eq 0) }
        '!=' { return ($cmp -ne 0) }
        '>'  { return ($cmp -gt 0) }
        '<'  { return ($cmp -lt 0) }
        '>=' { return ($cmp -ge 0) }
        '<=' { return ($cmp -le 0) }
    }
    return $false
}

function Watch-TcVariable {
    <#
    .SYNOPSIS
        Polls one or more PLC variables at intervals. Supports duration-based monitoring and waiting for a condition.
    .DESCRIPTION
        Every sampling round reads each -Path in order through Read-TcVariable.
        Without -Until it samples for -DurationMs (default 2000). With -Until it stops as soon as
        the condition holds (no extra sleep) or after -UntilTimeoutMs.
    .PARAMETER Path
        One or more variable paths to monitor, e.g. "MAIN.nCounter" or "MAIN.fActual","MAIN.bDone".
    .PARAMETER IntervalMs
        Delay between sampling rounds in milliseconds. Default: 100.
    .PARAMETER DurationMs
        Total monitoring duration in milliseconds when -Until is not given. Default: 2000.
    .PARAMETER Until
        Stop condition as text: "<Path> <op> <value>", op is one of == != > < >= <=,
        e.g. "MAIN.fTarget == 123.5" or "MAIN.bDone == TRUE". <Path> must be one of -Path
        (case-insensitive). Numbers compare numerically (TRUE/FALSE = 1/0), TRUE/FALSE compare
        as booleans (== / != only), anything else compares as case-insensitive text.
        A failed read never satisfies the condition.
    .PARAMETER UntilTimeoutMs
        Maximum time to wait for -Until in milliseconds. Default: 5000 (or -TimeoutMs if only that is given).
    .PARAMETER TimeoutMs
        Legacy alias for -UntilTimeoutMs; used only when -UntilTimeoutMs is not given. Default: 5000.
    .PARAMETER KeepLast
        Number of most recent samples returned in data.samples. 0 = auto (20 with -Until, 50 without).
        data.sampleCount is still the total number of sampling rounds; data.truncated tells whether older samples were dropped.
    .OUTPUTS
        JSON result. Sample shape: single path { timestamp, value }; multiple paths
        { timestamp, values = { <path> = <value>, ... } }.
        With -Until: data = { path, until, untilMet, untilSample, elapsedMs, finalValue (single path) |
        finalValues (multiple paths), sampleCount, samples, truncated, keepLast, reconnected }.
        Without -Until: data = { path, sampleCount, durationMs, elapsedMs, samples, truncated, keepLast, reconnected }.
        Invalid -Until returns error code INVALID_PARAMS.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path,

        [Parameter()]
        [int]$IntervalMs = 100,

        [Parameter()]
        [int]$DurationMs,

        [Parameter()]
        [string]$Until,

        [Parameter()]
        [int]$UntilTimeoutMs = 5000,

        [Parameter()]
        [int]$TimeoutMs = 5000,

        [Parameter()]
        [int]$KeepLast = 0
    )

    $multi = $Path.Count -gt 1
    $hasUntil = -not [string]::IsNullOrWhiteSpace($Until)

    # Parse -Until before touching ADS
    $untilPath = $null; $untilOp = $null; $untilValue = $null
    if ($hasUntil) {
        $m = [regex]::Match($Until, '^\s*(\S+)\s*(==|!=|>=|<=|>|<)\s*(.+?)\s*$')
        $pathList = $Path -join ', '
        if (-not $m.Success) {
            return New-TcResult -Success $false `
                -ErrorMessage "Cannot parse -Until '$Until'. Expected '<Path> <op> <value>' with op one of == != > < >= <=, where <Path> is one of: $pathList" `
                -ErrorCode 'INVALID_PARAMS' -Hint 'Example: -Until "MAIN.fTarget == 123.5"'
        }
        $untilPath = $null
        foreach ($p in $Path) {
            if ([string]::Equals($p, $m.Groups[1].Value, [System.StringComparison]::OrdinalIgnoreCase)) { $untilPath = $p; break }
        }
        if ($null -eq $untilPath) {
            return New-TcResult -Success $false `
                -ErrorMessage "-Until path '$($m.Groups[1].Value)' is not in -Path. Expected '<Path> <op> <value>' where <Path> is one of: $pathList" `
                -ErrorCode 'INVALID_PARAMS' -Hint 'Example: -Until "MAIN.fTarget == 123.5" (add the variable to -Path)'
        }
        $untilOp = $m.Groups[2].Value
        $untilValue = $m.Groups[3].Value
    }

    if (-not $PSBoundParameters.ContainsKey('UntilTimeoutMs') -and $PSBoundParameters.ContainsKey('TimeoutMs')) {
        $UntilTimeoutMs = $TimeoutMs
    }
    $keep = $KeepLast
    if ($keep -le 0) { $keep = if ($hasUntil) { 20 } else { 50 } }

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    try {
        $samples = New-Object 'System.Collections.Generic.List[object]'
        $sampleCount = 0
        $truncated = $false
        $untilMet = $false
        $untilSample = $null
        $lastValues = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $limitMs = if ($hasUntil) { $UntilTimeoutMs } elseif ($DurationMs -gt 0) { $DurationMs } else { 2000 }

        while ($sw.ElapsedMilliseconds -lt $limitMs) {
            $values = [ordered]@{}
            foreach ($p in $Path) {
                $v = $null
                $readResult = Read-TcVariable -Path $p
                if ($readResult -and $readResult.success) { $v = $readResult.data.value }
                $values[$p] = $v
            }
            $lastValues = $values
            $ts = [DateTime]::Now.ToString('o')
            $sample = if ($multi) {
                [PSCustomObject]@{ timestamp = $ts; values = [PSCustomObject]$values }
            } else {
                [PSCustomObject]@{ timestamp = $ts; value = $values[$Path[0]] }
            }
            $sampleCount++
            $samples.Add($sample)
            if ($samples.Count -gt $keep) { $samples.RemoveAt(0); $truncated = $true }

            if ($hasUntil -and (Test-TcWatchCondition -Value $values[$untilPath] -Operator $untilOp -Expected $untilValue)) {
                $untilMet = $true
                $untilSample = $sample
                break
            }
            Start-Sleep -Milliseconds $IntervalMs
        }
        $sw.Stop()
        $elapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
        $pathOut = if ($multi) { $Path } else { $Path[0] }

        if ($hasUntil) {
            $data = [ordered]@{
                path        = $pathOut
                until       = $Until
                untilMet    = $untilMet
                untilSample = $untilSample
                elapsedMs   = $elapsedMs
            }
            if ($multi) {
                $data['finalValues'] = if ($lastValues) { [PSCustomObject]$lastValues } else { $null }
            } else {
                $data['finalValue'] = if ($lastValues) { $lastValues[$Path[0]] } else { $null }
            }
            $data['sampleCount'] = $sampleCount
            $data['samples']     = $samples.ToArray()
            $data['truncated']   = $truncated
            $data['keepLast']    = $keep
            $data['reconnected'] = $reconnected
            New-TcResult -Success $true -Data ([PSCustomObject]$data)
        }
        else {
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                path        = $pathOut
                sampleCount = $sampleCount
                durationMs  = $limitMs
                elapsedMs   = $elapsedMs
                samples     = $samples.ToArray()
                truncated   = $truncated
                keepLast    = $keep
                reconnected = $reconnected
            })
        }
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'WATCH_FAILED' -MessagePrefix 'Watch failed'
    }
}
