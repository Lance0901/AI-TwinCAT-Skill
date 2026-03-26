function Invoke-TcTestCycle {
    <#
    .SYNOPSIS
        Full test cycle: Build -> Activate -> Login -> Run -> Execute Tests -> Report -> Stop.
    .PARAMETER TestCases
        Array of test case objects from New-TcTestCase.
    .PARAMETER SkipBuild
        Skip the build step (if already built).
    .PARAMETER KeepRunning
        Don't stop the PLC after tests complete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject[]]$TestCases,

        [Parameter()]
        [switch]$SkipBuild,

        [Parameter()]
        [switch]$KeepRunning
    )

    $cycleStart = [DateTime]::Now
    $steps = @()

    # Step 1: Build
    if (-not $SkipBuild) {
        $buildResult = Build-TcProject
        $steps += [PSCustomObject]@{ step = 'Build'; success = $buildResult.success }

        if (-not $buildResult.success) {
            return New-TcResult -Success $false `
                -ErrorMessage "Build failed: $($buildResult.error.message)" `
                -ErrorCode 'BUILD_FAILED' `
                -Data ([PSCustomObject]@{
                    steps      = $steps
                    buildErrors = $buildResult.data
                })
        }
    }

    # Step 2: Activate Configuration
    $activateResult = Enable-TcConfig -Force
    $steps += [PSCustomObject]@{ step = 'Activate'; success = $activateResult.success }
    if (-not $activateResult.success) {
        return New-TcResult -Success $false `
            -ErrorMessage "Activation failed: $($activateResult.error.message)" `
            -ErrorCode 'ACTIVATION_FAILED' -Data ([PSCustomObject]@{ steps = $steps })
    }

    # Step 3: Connect ADS (if not already)
    if (-not $script:TcAdsConnected) {
        $adsResult = Connect-TcAds
        $steps += [PSCustomObject]@{ step = 'ConnectAds'; success = $adsResult.success }
        if (-not $adsResult.success) {
            return New-TcResult -Success $false `
                -ErrorMessage "ADS connection failed: $($adsResult.error.message)" `
                -ErrorCode 'ADS_CONNECT_FAILED' -Data ([PSCustomObject]@{ steps = $steps })
        }
    }

    # Step 4: Login
    $loginResult = Enter-TcPlcOnline
    $steps += [PSCustomObject]@{ step = 'Login'; success = $loginResult.success }

    # Step 5: Start PLC
    $runResult = Set-TcPlcState -State Run
    $steps += [PSCustomObject]@{ step = 'Run'; success = $runResult.success }
    Start-Sleep -Milliseconds 500  # Let PLC initialize

    # Step 6: Execute tests
    $testResults = @()
    $passed = 0
    $failed = 0

    foreach ($tc in $TestCases) {
        $result = Invoke-TcTest -TestCase $tc
        if ($result.success) {
            $testResults += $result.data
            if ($result.data.result -eq 'Pass') { $passed++ } else { $failed++ }
        }
        else {
            $testResults += [PSCustomObject]@{
                name   = $tc.name
                result = 'Error'
                reason = $result.error.message
            }
            $failed++
        }
    }

    # Step 7: Stop PLC (unless KeepRunning)
    if (-not $KeepRunning) {
        Set-TcPlcState -State Stop | Out-Null
        $steps += [PSCustomObject]@{ step = 'Stop'; success = $true }
    }

    $cycleElapsed = ([DateTime]::Now - $cycleStart).TotalMilliseconds

    # Generate report
    $report = [PSCustomObject]@{
        timestamp  = $cycleStart.ToString('o')
        durationMs = [math]::Round($cycleElapsed)
        total      = $TestCases.Count
        passed     = $passed
        failed     = $failed
        steps      = $steps
        results    = $testResults
    }

    New-TcResult -Success ($failed -eq 0) -Data $report
}
