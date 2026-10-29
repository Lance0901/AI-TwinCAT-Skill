function Invoke-TcTest {
    <#
    .SYNOPSIS
        Executes a single test case: setup -> wait (poll WaitUntil, or legacy fixed WaitMs) -> assert -> teardown.
        With WaitUntil the assertions run as soon as the conditions hold; on timeout the test case is Fail
        with waitTimedOut=true, lastValues and waitMs (time actually waited).
        A test case that waits with the deprecated WaitMs (no WaitUntil, waitMs > 0) gets
        data.warning (the test case's own warning from New-TcTestCase, or the same text).
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

    # Validate WaitUntil before any write (a hand-built test case may skip New-TcTestCase)
    $wuProp = $TestCase.PSObject.Properties['waitUntil']
    if ($null -ne $wuProp -and $null -ne $wuProp.Value) {
        $wtp = $TestCase.PSObject.Properties['waitTimeoutMs']
        $wtv = if ($null -ne $wtp) { $wtp.Value } else { $null }
        $wuErr = Test-TcWaitUntilSpec -WaitUntil $wuProp.Value -WaitTimeoutMs $wtv
        if ($null -ne $wuErr) {
            return New-TcResult -Success $false -ErrorMessage $wuErr -ErrorCode 'INVALID_PARAMS' `
                -Hint 'Example: -WaitUntil @{Path="MAIN.bDone";Operator="IsTrue"} -WaitTimeoutMs 5000'
        }
    }

    $startTime = [DateTime]::Now
    $testName = $TestCase.name
    # WaitMs deprecation (task 1.8): data.warning on every result of a WaitMs test case
    $waitWarning = Get-TcWaitMsWarning -TestCase $TestCase

    try {
        # Setup: write initial values
        if ($TestCase.setup) {
            foreach ($action in $TestCase.setup) {
                $writeResult = Write-TcVariable -Path $action.Path -Value $action.Value
                if (-not $writeResult.success) {
                    $err = [ordered]@{
                        name   = $testName
                        result = 'Error'
                        reason = "Setup failed: $($writeResult.error.message)"
                    }
                    if ($null -ne $waitWarning) { $err['warning'] = $waitWarning }
                    return New-TcResult -Success $true -Data ([PSCustomObject]$err)
                }
            }
        }

        # Wait: poll the WaitUntil conditions (no blind sleep); legacy waitMs is a fixed sleep
        $waitUntilProp = $TestCase.PSObject.Properties['waitUntil']
        $waitUntil = if ($null -ne $waitUntilProp) { $waitUntilProp.Value } else { $null }
        $hasWaitUntil = $null -ne $waitUntil -and @($waitUntil).Count -gt 0
        $waitInfo = $null
        $waitTimeout = 5000
        if ($hasWaitUntil) {
            $wtProp = $TestCase.PSObject.Properties['waitTimeoutMs']
            if ($null -ne $wtProp -and $null -ne $wtProp.Value) { $waitTimeout = [int]$wtProp.Value }
            $waitInfo = Wait-TcTestCondition -WaitUntil $waitUntil -TimeoutMs $waitTimeout
        }
        elseif ($TestCase.waitMs -gt 0) {
            Start-Sleep -Milliseconds $TestCase.waitMs
        }

        # Assertions
        $assertionResults = @()
        $allPassed = $true

        if ($null -ne $waitInfo -and -not $waitInfo.met) {
            # Condition never held: the test case fails; assertions are not evaluated
            $allPassed = $false
        }
        else {
            foreach ($assertion in $TestCase.assertions) {
                $outcome = Get-TcAssertionOutcome -Assertion $assertion
                if (-not $outcome.pass) { $allPassed = $false }
                $assertionResults += $outcome
            }
        }

        # Teardown
        if ($TestCase.teardown) {
            foreach ($action in $TestCase.teardown) {
                Write-TcVariable -Path $action.Path -Value $action.Value | Out-Null
            }
        }

        $elapsed = ([DateTime]::Now - $startTime).TotalMilliseconds

        $data = [ordered]@{
            name       = $testName
            result     = if ($allPassed) { 'Pass' } else { 'Fail' }
            durationMs = [math]::Round($elapsed)
            assertions = $assertionResults
        }
        if ($null -ne $waitInfo) {
            $data['waitMs'] = $waitInfo.waitMs
            $data['waitTimedOut'] = (-not $waitInfo.met)
            if (-not $waitInfo.met) {
                $data['lastValues'] = $waitInfo.lastValues
                $data['reason'] = "WaitUntil not met within $waitTimeout ms"
            }
        }
        if ($null -ne $waitWarning) { $data['warning'] = $waitWarning }
        New-TcResult -Success $true -Data ([PSCustomObject]$data)
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
