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

function Get-TcWatchCompareValue {
    <#
    .SYNOPSIS
        Picks the scalar of a Read-TcVariable data object that a -Until <value> is compared with.
    .DESCRIPTION
        Numeric <value>: the raw ms/ns/unix integer of a time type (Get-TcVariableRawValue), else value.
        Other text: the enum member name when the data has one, else value (the IEC literal for time types).
    #>
    param($Data, [string]$Expected)
    $d = 0.0
    if ([double]::TryParse($Expected, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) {
        return (Get-TcVariableRawValue -Data $Data)
    }
    if ($null -ne $Data.PSObject.Properties['name'] -and -not [string]::IsNullOrEmpty([string]$Data.name)) { return $Data.name }
    return $Data.value
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
        TIME/DATE types: a numeric <value> is compared with the raw ms/ns/unix integer
        (e.g. "MAIN.tDelay > 5000"), any other text with the IEC literal ("MAIN.tDelay == T#6s").
        Enums: a numeric <value> compares with the integer, text with the member name.
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
        Fail closed (#139): a read that failed in any round (one path or several) makes the result
        success = false with WATCH_READ_FAILED; data is still complete and also has failedReads
        (path -> rounds whose read failed) and lastErrors (path -> last {error, code, hint}). A failed
        read is null in the sample plus sample.errors.<path> (several paths) or sample.error / code
        (one path); the hint is only in data.lastErrors. Every result has the top-level fields partial
        and failedPaths (-Path order): partial = false, failedPaths = [] when every read worked.
        A path given more than once (case-insensitive) is read once per round.
    .NOTES
        Samples use the Read-TcVariable conversion: value plus ms/ns/unix (raw integer) for
        TIME/DATE types (value is the IEC literal) and name (member name) for enums.
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

    # #145 review: a path given twice (case-insensitive, like -Until) is read once per round, so
    # failedReads never counts more than one failure per path and round
    $seenPath = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $Path = [string[]]@($Path | Where-Object { $seenPath.Add($_) })

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
        $samples = [System.Collections.Generic.List[object]]::new()
        $sampleCount = 0
        $truncated = $false
        $untilMet = $false
        $untilSample = $null
        $lastValues = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $limitMs = if ($hasUntil) { $UntilTimeoutMs } elseif ($DurationMs -gt 0) { $DurationMs } else { 2000 }

        # #139: failed reads per path (count of rounds) and the last error of each, in -Path order
        $failedCount = [ordered]@{}
        $lastError = @{}

        while ($sw.ElapsedMilliseconds -lt $limitMs) {
            $values = [ordered]@{}
            $readData = @{}
            $errors = [ordered]@{}
            foreach ($p in $Path) {
                $v = $null
                $readResult = Read-TcVariable -Path $p
                if ($readResult -and $readResult.success) { $v = $readResult.data.value; $readData[$p] = $readResult.data }
                else {
                    $e = [ordered]@{
                        error = if ($readResult -and $readResult.error) { [string]$readResult.error.message } else { 'Read-TcVariable returned no result' }
                        code  = if ($readResult -and $readResult.error) { [string]$readResult.error.code } else { $null }
                    }
                    if ($readResult -and $readResult.error -and $null -ne $readResult.error.PSObject.Properties['hint']) { $e.hint = [string]$readResult.error.hint }
                    # the sample keeps {error, code}; the hint only in data.lastErrors (not KeepLast times, #145)
                    $errors[$p] = [PSCustomObject]@{ error = $e.error; code = $e.code }
                    $lastError[$p] = [PSCustomObject]$e
                    if (-not $failedCount.Contains($p)) { $failedCount[$p] = 0 }
                    $failedCount[$p]++
                }
                $values[$p] = $v
            }
            $lastValues = $values
            $ts = [DateTime]::Now.ToString('o')
            # Single path: the Read-TcVariable conversion (value + ms/ns/unix for time types, name for enums).
            # A failed read is null plus the error (#139): sample.errors (multi) / error, code (single).
            $sample = if ($multi) {
                $s = [PSCustomObject]@{ timestamp = $ts; values = [PSCustomObject]$values }
                if ($errors.Count -gt 0) { $s | Add-Member -NotePropertyName 'errors' -NotePropertyValue ([PSCustomObject]$errors) }
                $s
            } elseif ($readData.ContainsKey($Path[0])) {
                New-TcWatchSample -Data $readData[$Path[0]]
            } else {
                $s = [ordered]@{ timestamp = $ts; value = $null }
                foreach ($k in $errors[$Path[0]].PSObject.Properties.Name) { $s[$k] = $errors[$Path[0]].$k }
                [PSCustomObject]$s
            }
            $sampleCount++
            $samples.Add($sample)
            if ($samples.Count -gt $keep) { $samples.RemoveAt(0); $truncated = $true }

            if ($hasUntil) {
                $cmpValue = $values[$untilPath]
                if ($readData.ContainsKey($untilPath)) { $cmpValue = Get-TcWatchCompareValue -Data $readData[$untilPath] -Expected $untilValue }
                if (Test-TcWatchCondition -Value $cmpValue -Operator $untilOp -Expected $untilValue) {
                    $untilMet = $true
                    $untilSample = $sample
                    break
                }
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
        }
        else {
            $data = [ordered]@{
                path        = $pathOut
                sampleCount = $sampleCount
                durationMs  = $limitMs
                elapsedMs   = $elapsedMs
                samples     = $samples.ToArray()
                truncated   = $truncated
                keepLast    = $keep
                reconnected = $reconnected
            }
        }

        # #139, fail closed like Read-TcVariable (#60): a read that failed in any round makes the
        # result success = false with WATCH_READ_FAILED. data stays complete (samples, untilMet, ...)
        # and gets failedReads (path -> number of rounds whose read failed) and lastErrors (path ->
        # the last {error, code, hint}); the top level has partial / failedPaths (in -Path order),
        # partial = false and failedPaths = [] when every read worked.
        $failed = @($Path | Where-Object { $failedCount.Contains($_) })
        if ($failed.Count -gt 0) {
            $fr = [ordered]@{}; $le = [ordered]@{}
            foreach ($p in $failed) { $fr[$p] = $failedCount[$p]; $le[$p] = $lastError[$p] }
            $data['failedReads'] = [PSCustomObject]$fr
            $data['lastErrors'] = [PSCustomObject]$le
            $detail = (@($failed | ForEach-Object {
                $c = if ([string]::IsNullOrEmpty([string]$lastError[$_].code)) { 'unmapped' } else { [string]$lastError[$_].code }
                "$_ ($c, $($failedCount[$_]) of $sampleCount rounds)"
            })) -join ', '
            $msg = "$($failed.Count) of $($Path.Count) watched paths could not be read: $detail."
            if ($hasUntil -and -not $untilMet -and $failed -contains $untilPath) {
                # untilMet = true always comes from a successful read (untilSample); false may not
                $msg += " The -Until path $untilPath is among them: untilMet=false does not mean the condition was false on the PLC."
            }
            $msg += ' Failed reads are null in samples; the error is in sample.errors (several paths) or sample.error / code (one path) and in data.lastErrors.'
            $res = New-TcResult -Success $false -ErrorMessage $msg -ErrorCode 'WATCH_READ_FAILED' `
                -Hint (Get-TcErrorHint -Code 'WATCH_READ_FAILED') -Data ([PSCustomObject]$data)
        }
        else {
            $res = New-TcResult -Success $true -Data ([PSCustomObject]$data)
        }
        $res | Add-Member -NotePropertyName 'partial' -NotePropertyValue ($failed.Count -gt 0) -Force
        $res | Add-Member -NotePropertyName 'failedPaths' -NotePropertyValue ([string[]]$failed) -Force
        $res
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'WATCH_FAILED' -MessagePrefix 'Watch failed'
    }
}
