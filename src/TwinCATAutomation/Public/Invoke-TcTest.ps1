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

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
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

            $passed = Test-TcAssertion -Actual $actual -Operator $operator -Expected $expected

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
