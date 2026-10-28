function New-TcTestCase {
    <#
    .SYNOPSIS
        Defines a test case for PLC automated testing.
    .PARAMETER Name
        Test case name.
    .PARAMETER Setup
        Array of hashtables with Path and Value for setup writes.
    .PARAMETER Teardown
        Array of hashtables with Path and Value for teardown writes.
    .PARAMETER WaitUntil
        Condition(s) to poll for before the assertions: one hashtable or an array of
        @{ Path = 'MAIN.bDone'; Operator = 'IsTrue'; Expected = ... }. Operator is one of the assertion
        operators (Equal default, NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual,
        Contains, IsTrue, IsFalse); Expected is omitted for IsTrue/IsFalse. All conditions must hold in the
        same sampling round. The assertions run as soon as they do; on timeout Invoke-TcTest reports the
        test case as Fail with waitTimedOut=true, lastValues and waitMs. Replaces -WaitMs.
    .PARAMETER WaitTimeoutMs
        Maximum time to poll -WaitUntil in milliseconds (1..600000). Default 5000.
    .PARAMETER WaitMs
        DEPRECATED, do not use. A fixed blind wait in milliseconds before the assertions (default 1000):
        it always waits the full time and cannot tell a slow PLC from a failure. Use -WaitUntil. Ignored
        when -WaitUntil is given.
    .PARAMETER Assertions
        Array of hashtables with Path, Operator, and Expected.
    .OUTPUTS
        The test case object; invalid -WaitUntil / -WaitTimeoutMs returns an INVALID_PARAMS error result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [hashtable[]]$Setup,

        [Parameter()]
        [hashtable[]]$Teardown,

        [Parameter()]
        [hashtable[]]$WaitUntil,

        [Parameter()]
        [int]$WaitTimeoutMs = 5000,

        [Parameter()]
        [int]$WaitMs = 1000,

        [Parameter(Mandatory)]
        [hashtable[]]$Assertions
    )

    if ($PSBoundParameters.ContainsKey('WaitUntil') -or $PSBoundParameters.ContainsKey('WaitTimeoutMs')) {
        $wuErr = if ($PSBoundParameters.ContainsKey('WaitUntil')) {
            Test-TcWaitUntilSpec -WaitUntil $WaitUntil -WaitTimeoutMs $WaitTimeoutMs
        } else { '-WaitTimeoutMs is only used together with -WaitUntil.' }
        if ($null -ne $wuErr) {
            return New-TcResult -Success $false -ErrorMessage $wuErr -ErrorCode 'INVALID_PARAMS' `
                -Hint 'Example: -WaitUntil @{Path="MAIN.bDone";Operator="IsTrue"} -WaitTimeoutMs 5000'
        }
    }

    $tc = [ordered]@{
        PSTypeName = 'TcTestCase'
        name       = $Name
        setup      = $Setup
        teardown   = $Teardown
        waitMs     = $WaitMs
    }
    if ($PSBoundParameters.ContainsKey('WaitUntil')) {
        $tc['waitUntil'] = $WaitUntil
        $tc['waitTimeoutMs'] = $WaitTimeoutMs
    }
    $tc['assertions'] = $Assertions
    [PSCustomObject]$tc
}
