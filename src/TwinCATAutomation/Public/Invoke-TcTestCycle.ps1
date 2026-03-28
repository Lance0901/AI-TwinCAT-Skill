function Invoke-TcTestCycle {
    <#
    .SYNOPSIS
        Full test cycle: Build -> Activate -> Login -> Start -> Connect ADS -> Execute Tests -> Report -> Stop.
    .DESCRIPTION
        Correct order: Build → Activate (Config→Run) → Login(3)+Download → Start PLC → Connect ADS → Tests.
        ADS port 851 only becomes available AFTER Login+Download, so Connect ADS must come after Login.
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

    # Cache AmsNetId before Activate (which restarts TwinCAT and may invalidate COM references)
    $cachedAmsNetId = $null
    if ($null -ne $script:TcSysManager) {
        try { $cachedAmsNetId = $script:TcSysManager.GetTargetNetId() } catch { }
    }

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

    # Step 2: Activate Configuration (Config → Activate → Run via ADS, no dialogs)
    $activateResult = Enable-TcConfig -Force
    $steps += [PSCustomObject]@{ step = 'Activate'; success = $activateResult.success }
    if (-not $activateResult.success) {
        return New-TcResult -Success $false `
            -ErrorMessage "Activation failed: $($activateResult.error.message)" `
            -ErrorCode 'ACTIVATION_FAILED' -Data ([PSCustomObject]@{ steps = $steps })
    }

    # Step 2.5: Reconnect IDE (Activate restarts TwinCAT, COM references become stale)
    Start-Sleep -Seconds 3  # Wait for TwinCAT restart to settle
    $reconnResult = Connect-TcIde
    if (-not $reconnResult.success) {
        Write-Verbose "IDE reconnect warning: $($reconnResult.error.message)"
    }

    # Step 3: Login + Download (Login(3) suppresses dialogs, auto-downloads program)
    # This makes PLC port 851 available with symbols
    $loginResult = Enter-TcPlcOnline
    $steps += [PSCustomObject]@{ step = 'Login'; success = $loginResult.success }
    if (-not $loginResult.success) {
        return New-TcResult -Success $false `
            -ErrorMessage "Login failed: $($loginResult.error.message)" `
            -ErrorCode 'LOGIN_FAILED' -Data ([PSCustomObject]@{ steps = $steps })
    }

    # Step 4: Start PLC
    # After Login(3), PLC may be in Stop or Invalid state — start it
    # Use ADS on port 851 directly with cached AmsNetId
    Start-Sleep -Seconds 1  # Allow Login to complete

    # Step 5: Connect ADS (AFTER Login+Download — port 851 now has symbols)
    $adsParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($cachedAmsNetId)) {
        $adsParams['AmsNetId'] = $cachedAmsNetId
    }
    $adsResult = Connect-TcAds @adsParams
    $steps += [PSCustomObject]@{ step = 'ConnectAds'; success = $adsResult.success }
    if (-not $adsResult.success) {
        return New-TcResult -Success $false `
            -ErrorMessage "ADS connection failed: $($adsResult.error.message)" `
            -ErrorCode 'ADS_CONNECT_FAILED' -Data ([PSCustomObject]@{ steps = $steps })
    }

    # Step 6: Start PLC via ADS
    $runResult = Set-TcPlcState -State Run
    $steps += [PSCustomObject]@{ step = 'Run'; success = $runResult.success }
    Start-Sleep -Milliseconds 500  # Let PLC initialize

    # Step 7: Execute tests
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

    # Step 8: Stop PLC (unless KeepRunning)
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
