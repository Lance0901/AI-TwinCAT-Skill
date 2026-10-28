function Get-TcAssertionOutcome {
    <#
    .SYNOPSIS
        Reads one assertion's variable and evaluates it (shared by Invoke-TcTest assertions and -WaitUntil polling).
    .PARAMETER Assertion
        Hashtable / object with Path, Operator (default Equal) and Expected; Operator is one of the Test-TcAssertion set.
    .OUTPUTS
        { path, actual, expected (display text), operator, pass }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Assertion
    )

    $readResult = Read-TcVariable -Path $Assertion.Path
    $actual = if ($readResult.success) { $readResult.data.value } else { $null }
    $operator = if ($Assertion.Operator) { $Assertion.Operator } else { 'Equal' }
    $expected = $Assertion.Expected

    $compared = $actual
    $cmpExpected = $expected
    if ($readResult.success) {
        # TIME/DATE types: value is the IEC literal, so compare on the raw integer (ms/ns/unix);
        # an Expected written as a literal ("T#6s") is converted to the same unit first.
        $timeType = Get-TcIecTimeType -TypeName $readResult.data.type
        if ($null -ne $timeType) {
            $compared = Get-TcVariableRawValue -Data $readResult.data
            if ($expected -is [string] -and $expected.Trim() -notmatch '^[+-]?\d+$') {
                try { $cmpExpected = ConvertFrom-TcIecLiteral -Value $expected -TypeInfo $timeType } catch { }
            }
        }
    }

    $passed = Test-TcAssertion -Actual $compared -Operator $operator -Expected $cmpExpected

    $expectedStr = switch ($operator) {
        'GreaterThan' { ">$expected" }
        'LessThan' { "<$expected" }
        'IsTrue' { 'TRUE' }
        'IsFalse' { 'FALSE' }
        default { "$expected" }
    }

    [PSCustomObject]@{
        path     = $Assertion.Path
        actual   = $actual
        expected = $expectedStr
        operator = $operator
        pass     = [bool]$passed
    }
}
