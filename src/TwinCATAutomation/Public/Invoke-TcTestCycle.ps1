function Invoke-TcTestCycle {
    <#
    .SYNOPSIS
        Full test cycle: Build -> Activate -> Login -> Start -> Connect ADS -> Execute Tests -> Report -> Stop.
    .DESCRIPTION
        Correct order: Build → Activate (Config→Run) → Login(1)+Download → Start PLC → Connect ADS → Tests.
        ADS port 851 only becomes available AFTER Login+Download, so Connect ADS must come after Login.
    .PARAMETER TestCases
        Array of test case objects from New-TcTestCase.
    .PARAMETER SkipBuild
        Skip the build step (if already built).
    .PARAMETER KeepRunning
        Don't stop the PLC after tests complete.
    .NOTES
        No -AllowUnresolvedLibrary (#61): a build that does not prove the PLC code was compiled
        (codeVerified not true, e.g. unresolved libraries) is never activated, so the cycle
        stops at Build (LIBRARY_UNRESOLVED) or at Activate (BUILD_REQUIRED).
        A failing Activate returns ACTIVATION_FAILED (the Enable-TcConfig code is in the message),
        except RUNTIME_CRASHED (local UmRT process gone), which is returned as it is with
        data.runtimeCrash.
        Test cases that wait with the deprecated WaitMs: each result has data.warning (as
        Invoke-TcTest) and the report lists them in data.warnings ("<name>: <warning>").
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
            # keep the Build error code + hint (LIBRARY_UNRESOLVED, BUILD_TIMEOUT, ...)
            $code = if ([string]::IsNullOrWhiteSpace([string]$buildResult.error.code)) { 'BUILD_FAILED' } else { [string]$buildResult.error.code }
            $hp = $buildResult.error.PSObject.Properties['hint']
            $buildHint = if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { [string]$hp.Value } else { Get-TcErrorHint -Code $code }
            $params = @{
                Success      = $false
                ErrorMessage = "Build failed: $($buildResult.error.message)"
                ErrorCode    = $code
                Data         = ([PSCustomObject]@{
                    steps       = $steps
                    buildErrors = $buildResult.data
                })
            }
            if (-not [string]::IsNullOrWhiteSpace($buildHint)) { $params['Hint'] = $buildHint }
            return New-TcResult @params
        }
    }

    # Step 2: Activate Configuration (Config → Activate → Run via ADS, no dialogs)
    $activateResult = Enable-TcConfig -Force
    $steps += [PSCustomObject]@{ step = 'Activate'; success = $activateResult.success }
    if (-not $activateResult.success) {
        # code stays ACTIVATION_FAILED; the Enable-TcConfig code (e.g. BUILD_REQUIRED) is in the message, its hint is kept.
        # Exception RUNTIME_CRASHED (local UmRT gone, task 1.8): passed on as it is, with data.runtimeCrash.
        $ahp = $activateResult.error.PSObject.Properties['hint']
        $aCode = [string]$activateResult.error.code
        $aData = [PSCustomObject]@{ steps = $steps }
        if ($aCode -eq 'RUNTIME_CRASHED' -and $null -ne $activateResult.data -and $null -ne $activateResult.data.PSObject.Properties['runtimeCrash']) {
            $aData | Add-Member -NotePropertyName 'runtimeCrash' -NotePropertyValue $activateResult.data.runtimeCrash
        }
        $aParams = @{
            Success      = $false
            ErrorMessage = "Activation failed ($aCode): $($activateResult.error.message)"
            ErrorCode    = $(if ($aCode -eq 'RUNTIME_CRASHED') { 'RUNTIME_CRASHED' } else { 'ACTIVATION_FAILED' })
            Data         = $aData
        }
        if ($null -ne $ahp -and -not [string]::IsNullOrWhiteSpace([string]$ahp.Value)) { $aParams['Hint'] = [string]$ahp.Value }
        return New-TcResult @aParams
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

    # Step 3: Login + Download (Login(1) under SilentMode, auto-downloads program)
    # This makes PLC port 851 available with symbols
    $loginResult = Enter-TcPlcOnline
    $steps += [PSCustomObject]@{ step = 'Login'; success = $loginResult.success }
    if (-not $loginResult.success) {
        # keep the Enter-TcPlcOnline error code + hint (BUILD_REQUIRED, PLC_PROJECT_AMBIGUOUS, ...), like the Build step
        $lcode = if ([string]::IsNullOrWhiteSpace([string]$loginResult.error.code)) { 'LOGIN_FAILED' } else { [string]$loginResult.error.code }
        $lhp = $loginResult.error.PSObject.Properties['hint']
        $loginHint = if ($null -ne $lhp -and -not [string]::IsNullOrWhiteSpace([string]$lhp.Value)) { [string]$lhp.Value } else { Get-TcErrorHint -Code $lcode }
        $lParams = @{
            Success      = $false
            ErrorMessage = "Login failed: $($loginResult.error.message)"
            ErrorCode    = $lcode
            Data         = ([PSCustomObject]@{ steps = $steps })
        }
        if (-not [string]::IsNullOrWhiteSpace($loginHint)) { $lParams['Hint'] = $loginHint }
        return New-TcResult @lParams
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
            $errEntry = [PSCustomObject]@{
                name   = $tc.name
                result = 'Error'
                reason = $result.error.message
            }
            $tw = Get-TcWaitMsWarning -TestCase $tc
            if ($null -ne $tw) { $errEntry | Add-Member -NotePropertyName 'warning' -NotePropertyValue $tw }
            $testResults += $errEntry
            $failed++
        }
    }
    # WaitMs deprecation (task 1.8): each result carries its own warning; the report lists them once
    $warnings = @($testResults | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['warning'] -and -not [string]::IsNullOrWhiteSpace([string]$_.warning) } |
        ForEach-Object { "$($_.name): $($_.warning)" })

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
    if ($warnings.Count -gt 0) { $report | Add-Member -NotePropertyName 'warnings' -NotePropertyValue $warnings }

    New-TcResult -Success ($failed -eq 0) -Data $report
}
