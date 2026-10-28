function Test-TcWaitUntilSpec {
    <#
    .SYNOPSIS
        Validates a -WaitUntil list (Path / Operator / Expected, assertion operator set). Returns an error text or $null.
    #>
    [CmdletBinding()]
    param([AllowNull()]$WaitUntil, $WaitTimeoutMs)

    $validOps = @('Equal', 'NotEqual', 'GreaterThan', 'LessThan', 'GreaterThanOrEqual', 'LessThanOrEqual', 'Contains', 'IsTrue', 'IsFalse')
    if ($null -ne $WaitTimeoutMs -and ([int]$WaitTimeoutMs -lt 1 -or [int]$WaitTimeoutMs -gt 600000)) {
        return "WaitTimeoutMs must be 1..600000, got $WaitTimeoutMs."
    }
    $items = @($WaitUntil)
    if ($items.Count -eq 0) { return 'WaitUntil is empty; give at least one {Path, Operator, Expected} condition.' }
    $i = 0
    foreach ($c in $items) {
        $i++
        if ($null -eq $c -or $c -is [string] -or $c -is [ValueType]) {
            return "WaitUntil[$i] must be an object {Path, Operator, Expected}."
        }
        $keys = if ($c -is [System.Collections.IDictionary]) { @($c.Keys) } else { @($c.PSObject.Properties.Name) }
        foreach ($k in $keys) {
            if ($k -notin @('Path', 'Operator', 'Expected')) {
                return "WaitUntil[$i] has unknown key '$k'; allowed keys: Path, Operator, Expected."
            }
        }
        if ([string]::IsNullOrWhiteSpace([string]$c.Path)) { return "WaitUntil[$i].Path is required." }
        $op = if ($c.Operator) { [string]$c.Operator } else { 'Equal' }
        if ($op -notin $validOps) {
            return "WaitUntil[$i].Operator '$op' is not valid; use one of: $($validOps -join ', ')."
        }
        if ($op -notin @('IsTrue', 'IsFalse') -and $null -eq $c.Expected) {
            return "WaitUntil[$i].Expected is required for operator $op."
        }
    }
    return $null
}

function Wait-TcTestCondition {
    <#
    .SYNOPSIS
        Polls until every WaitUntil condition holds in the same sampling round, or the timeout passes.
    .DESCRIPTION
        Replaces the fixed Start-Sleep of a test case. At least one round is always sampled.
        Returns { met, waitMs (actual time waited), lastValues (path -> last read value) }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $WaitUntil,
        [int]$TimeoutMs = 5000,
        [int]$IntervalMs = 100
    )

    $conds = @($WaitUntil)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $last = [ordered]@{}
    $met = $false
    while ($true) {
        $all = $true
        foreach ($c in $conds) {
            $o = Get-TcAssertionOutcome -Assertion $c
            $last[[string]$c.Path] = $o.actual
            if (-not $o.pass) { $all = $false }
        }
        if ($all) { $met = $true; break }
        $remaining = $TimeoutMs - $sw.ElapsedMilliseconds
        if ($remaining -le 0) { break }
        Start-Sleep -Milliseconds ([math]::Min($IntervalMs, $remaining))
    }
    $sw.Stop()
    [PSCustomObject]@{
        met        = $met
        waitMs     = [int][math]::Round($sw.Elapsed.TotalMilliseconds)
        lastValues = [PSCustomObject]$last
    }
}
