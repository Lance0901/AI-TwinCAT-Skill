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

# WaitMs deprecation text (task 1.8, phase0-1.7 finding 3): shown at run time, not only in the help.
$script:TcWaitMsDeprecatedWarning = 'WaitMs is deprecated (a fixed blind wait that cannot tell a slow PLC from a failure): use WaitUntil (New-TcTestCase -WaitUntil @{ Path = ''MAIN.bDone''; Operator = ''IsTrue'' } -WaitTimeoutMs 5000; MCP NewTestCase WaitUntil=[{"Path":"MAIN.bDone","Operator":"IsTrue"}]).'

function Get-TcWaitMsWarning {
    <#
    .SYNOPSIS
        The WaitMs deprecation warning for a test case that waits with WaitMs, else $null.
    .DESCRIPTION
        A test case without WaitUntil (null or empty) and with waitMs > 0 uses the deprecated fixed
        wait. The test case's own 'warning' (New-TcTestCase) is returned when present, so a hand-built
        test case gets the same text. waitMs 0 (no wait at all): $null. A WaitUntil test case: only
        its own 'warning' (New-TcTestCase with an explicit -WaitMs that is ignored), else $null.
    .PARAMETER TestCase
        Test case object (New-TcTestCase or hand-built / from JSON).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$TestCase)
    if ($null -eq $TestCase) { return $null }
    $own = $TestCase.PSObject.Properties['warning']
    $ownText = if ($null -ne $own -and -not [string]::IsNullOrWhiteSpace([string]$own.Value)) { [string]$own.Value } else { $null }
    $wu = $TestCase.PSObject.Properties['waitUntil']
    # WaitUntil test case: only its own warning (New-TcTestCase: "-WaitMs ... is ignored")
    if ($null -ne $wu -and $null -ne $wu.Value -and @($wu.Value).Count -gt 0) { return $ownText }
    $wm = $TestCase.PSObject.Properties['waitMs']
    $waitMs = 0
    if ($null -ne $wm -and $null -ne $wm.Value) { try { $waitMs = [int]$wm.Value } catch { $waitMs = 0 } }
    if ($waitMs -le 0) { return $null }
    if ($null -ne $ownText) { return $ownText }
    return $script:TcWaitMsDeprecatedWarning
}
