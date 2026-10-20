function Invoke-TcTest {
    <#
    .SYNOPSIS
        Executes a single test case: setup -> wait -> assert -> teardown.
    .PARAMETER TestCase
        A test case object from New-TcTestCase.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$TestCase
    )

    try { $null = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    $startTime = [DateTime]::Now
    $testName = $TestCase.name

    try {
        # Setup: write initial values
        if ($TestCase.setup) {
            foreach ($action in $TestCase.setup) {
                $writeResult = Write-TcVariable -Path $action.Path -Value $action.Value
                if (-not $writeResult.success) {
                    return New-TcResult -Success $true -Data ([PSCustomObject]@{
                        name   = $testName
                        result = 'Error'
                        reason = "Setup failed: $($writeResult.error.message)"
                    })
                }
            }
        }

        # Wait
        if ($TestCase.waitMs -gt 0) {
            Start-Sleep -Milliseconds $TestCase.waitMs
        }

        # Assertions
        $assertionResults = @()
        $allPassed = $true

        foreach ($assertion in $TestCase.assertions) {
            $readResult = Read-TcVariable -Path $assertion.Path
            $actual = if ($readResult.success) { $readResult.data.value } else { $null }
            $operator = if ($assertion.Operator) { $assertion.Operator } else { 'Equal' }
            $expected = $assertion.Expected

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

            if (-not $passed) { $allPassed = $false }

            $expectedStr = switch ($operator) {
                'GreaterThan' { ">$expected" }
                'LessThan' { "<$expected" }
                'IsTrue' { 'TRUE' }
                'IsFalse' { 'FALSE' }
                default { "$expected" }
            }

            $assertionResults += [PSCustomObject]@{
                path     = $assertion.Path
                actual   = $actual
                expected = $expectedStr
                operator = $operator
                pass     = $passed
            }
        }

        # Teardown
        if ($TestCase.teardown) {
            foreach ($action in $TestCase.teardown) {
                Write-TcVariable -Path $action.Path -Value $action.Value | Out-Null
            }
        }

        $elapsed = ([DateTime]::Now - $startTime).TotalMilliseconds

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name       = $testName
            result     = if ($allPassed) { 'Pass' } else { 'Fail' }
            durationMs = [math]::Round($elapsed)
            assertions = $assertionResults
        })
    }
    catch {
        # Attempt teardown even on error
        if ($TestCase.teardown) {
            foreach ($action in $TestCase.teardown) {
                try { Write-TcVariable -Path $action.Path -Value $action.Value | Out-Null } catch { }
            }
        }

        New-TcResult -Success $false -ErrorMessage "Test execution failed: $_" -ErrorCode 'TEST_FAILED'
    }
}
