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
    # Poll port 10000 until TwinCAT is back in Run instead of a blind sleep.
    if (-not [string]::IsNullOrWhiteSpace($cachedAmsNetId)) {
        $waitSys = Wait-TcAdsState -AmsNetId $cachedAmsNetId -Port 10000 -TargetState Run -TimeoutSec 60
        Write-Verbose "TwinCAT system Run wait: reached=$($waitSys.Reached) state=$($waitSys.State) elapsed=$($waitSys.ElapsedMs)ms"
    }
    else {
        Start-Sleep -Seconds 3  # No AmsNetId known: fall back to settle delay
    }
    $reconnResult = Connect-TcIde
    if (-not $reconnResult.success) {
        Write-Verbose "IDE reconnect warning: $($reconnResult.error.message)"
    }
    if ([string]::IsNullOrWhiteSpace($cachedAmsNetId) -and $reconnResult.success -and $reconnResult.data.PSObject.Properties['amsNetId']) {
        $cachedAmsNetId = $reconnResult.data.amsNetId
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

    # Step 4: Wait for PLC runtime port 851 to become reachable after Login+Download
    # (replaces blind sleep; port 851 only exists once the program is loaded)
    if (-not [string]::IsNullOrWhiteSpace($cachedAmsNetId)) {
        $waitPort = Wait-TcAdsState -AmsNetId $cachedAmsNetId -Port 851 -TargetState Any -TimeoutSec 30
        Write-Verbose "PLC port 851 wait: reached=$($waitPort.Reached) state=$($waitPort.State) elapsed=$($waitPort.ElapsedMs)ms"
    }
    else {
        Start-Sleep -Seconds 1  # No AmsNetId known: fall back to settle delay
    }

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

    # Step 6: Start PLC via ADS, then poll port 851 until it reports Run
    $runResult = Set-TcPlcState -State Run
    $steps += [PSCustomObject]@{ step = 'Run'; success = $runResult.success }
    $runNetId = if (-not [string]::IsNullOrWhiteSpace($cachedAmsNetId)) { $cachedAmsNetId } else { $script:TcAdsAmsNetId }
    if (-not $runResult.success) {
        # Run was refused (e.g. PLC_NOT_LOADED / PLC_RUN_TIMEOUT): do not wait another 30 s for it
        Write-Verbose "PLC Run failed ($($runResult.error.code)): $($runResult.error.message) - skipping Run wait"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($runNetId)) {
        $waitRun = Wait-TcAdsState -AmsNetId $runNetId -Port 851 -TargetState Run -TimeoutSec 30
        Write-Verbose "PLC Run wait: reached=$($waitRun.Reached) state=$($waitRun.State) elapsed=$($waitRun.ElapsedMs)ms"
    }
    else {
        Start-Sleep -Milliseconds 500  # Let PLC initialize
    }

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
