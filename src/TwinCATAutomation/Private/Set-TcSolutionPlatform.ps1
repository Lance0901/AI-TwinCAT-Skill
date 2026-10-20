function Set-TcSolutionPlatform {
    <#
    .SYNOPSIS
        Activates the solution configuration '<Configuration>|<Platform>' of the connected
        IDE (shared by Set-TcTarget and Enable-TcConfig). Never throws.
    .DESCRIPTION
        Lists DTE.Solution.SolutionBuild.SolutionConfigurations; the platform of a
        configuration is the PlatformName of its first SolutionContexts item
        (SolutionConfiguration.PlatformName itself comes back empty through the PowerShell
        COM binder). The configuration whose Name is -Configuration and whose platform is
        -Platform (case-insensitive) is activated with SolutionConfiguration.Activate()
        unless it is already the active one, then the active platform is read back with
        Get-TcSolutionPlatform.
        In TwinCAT 4026 XAE the active solution platform must match the target platform,
        otherwise ActivateConfiguration() silently fails ('Check config failed!'): a
        Usermode Runtime (UmRT) target is 'TwinCAT OS (x64)', a Windows RT target
        'TwinCAT RT (x64)'. Get-TcTargetPlatform reads it from the target.
    .PARAMETER Platform
        Solution platform to activate.
    .PARAMETER Configuration
        Solution configuration name. Default 'Release'.
    .PARAMETER PlatformSource
        Where -Platform came from (e.g. 'target (registryDeviceType)'); only used in the
        PLATFORM_NOT_FOUND message / hint.
    .OUTPUTS
        [PSCustomObject]@{
            success; error (@{ message; code; hint } or $null);
            configuration; previousPlatform; platform; platformChanged;
            availablePlatforms; availableConfigurations }
        error.code: PLATFORM_NOT_FOUND (no such configuration|platform), PLATFORM_SET_FAILED
        (activation failed or not visible afterwards), or a mapped COM code (IDE_BUSY,
        IDE_CRASHED, ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Platform,

        [Parameter()]
        [string]$Configuration = 'Release',

        [Parameter()]
        [string]$PlatformSource
    )

    $before = Get-TcSolutionPlatform
    $out = [PSCustomObject]@{
        success                 = $false
        error                   = $null
        configuration           = $Configuration
        previousPlatform        = $before.platform
        platform                = $before.platform
        platformChanged         = $false
        availablePlatforms      = @()
        availableConfigurations = @()
    }

    $configs = @()
    try {
        # Invoke-TcComRetry hands the array back as ONE object; @() around the call would nest it.
        $rawConfigs = Invoke-TcComRetry -OperationName 'SolutionConfigurations' -ScriptBlock {
                $list = New-Object System.Collections.ArrayList
                foreach ($cfg in $script:TcDte.Solution.SolutionBuild.SolutionConfigurations) {
                    $cfgName = $null
                    $cfgPlatform = $null
                    try { $cfgName = [string]$cfg.Name } catch { $cfgName = $null }
                    try {
                        foreach ($ctx in $cfg.SolutionContexts) {
                            $cfgPlatform = [string]$ctx.PlatformName
                            break
                        }
                    }
                    catch { $cfgPlatform = $null }
                    $null = $list.Add([PSCustomObject]@{ Name = $cfgName; Platform = $cfgPlatform; Com = $cfg })
                }
                Write-Output -NoEnumerate $list.ToArray()
            }
        foreach ($rc in $rawConfigs) { $configs += $rc }
    }
    catch {
        $out.error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix 'Reading the solution configurations failed').error
        return $out
    }

    $sameConfig = @($configs | Where-Object { $_.Name -ieq $Configuration })
    $available = @($sameConfig | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Platform) } | ForEach-Object { [string]$_.Platform } | Select-Object -Unique)
    $availableConfigs = @($configs | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
    $out.availablePlatforms = $available
    $out.availableConfigurations = $availableConfigs

    $match = $null
    foreach ($c in $sameConfig) {
        if ([string]$c.Platform -ieq $Platform) { $match = $c; break }
    }
    if ($null -eq $match) {
        $availText = if ($available.Count -gt 0) { "'" + ($available -join "', '") + "'" } else { '(none)' }
        $from = if ([string]::IsNullOrWhiteSpace($PlatformSource)) { '' } else { " (platform reported by the $PlatformSource)" }
        $msg = "Solution platform '$Platform'$from not found for configuration '$Configuration'. Available platforms: $availText."
        if ($sameConfig.Count -eq 0) { $msg += " No configuration named '$Configuration'; available configurations: '" + ($availableConfigs -join "', '") + "'." }
        $hint = Get-TcErrorHint -Code 'PLATFORM_NOT_FOUND'
        $hint = "$hint Available: $availText."
        if (-not [string]::IsNullOrWhiteSpace($PlatformSource)) {
            $hint += " '$Platform' was read from the target ($PlatformSource), not typed by you: the solution has no such platform (a 4024 solution maps 'TwinCAT OS (x64)' to project platform 'TwinCAT OS (ARMT2)'; add a real 'TwinCAT OS (x64)' project platform in the Configuration Manager), or pass -Platform / -NoPlatformSwitch (Set-TcTarget), -NoPlatformFix (Enable-TcConfig) to skip the automatic switch."
        }
        $out.error = [PSCustomObject]@{ message = $msg; code = 'PLATFORM_NOT_FOUND'; hint = $hint }
        return $out
    }

    $resolvedPlatform = [string]$match.Platform
    $alreadyActive = ([string]$before.platform -ieq $resolvedPlatform) -and ([string]$before.configuration -ieq [string]$match.Name)
    if (-not $alreadyActive) {
        try {
            Invoke-TcComRetry -OperationName 'SolutionConfiguration.Activate' -ScriptBlock { $match.Com.Activate() } | Out-Null
        }
        catch {
            $out.error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix "Activating '$Configuration|$resolvedPlatform' failed").error
            return $out
        }
        # The IDE applies the new active configuration asynchronously.
        Start-Sleep -Seconds 1
    }

    $after = Get-TcSolutionPlatform
    $out.platform = $after.platform
    $out.platformChanged = (-not ([string]$before.platform -ieq [string]$after.platform))
    if (-not ([string]$after.platform -ieq $resolvedPlatform)) {
        $out.error = [PSCustomObject]@{
            message = "Solution platform '$resolvedPlatform' was activated but the active solution platform reads '$($after.platform)' (configuration '$($after.configuration)')."
            code    = 'PLATFORM_SET_FAILED'
            hint    = (Get-TcErrorHint -Code 'PLATFORM_SET_FAILED')
        }
        return $out
    }
    if (-not [string]::IsNullOrWhiteSpace($after.configuration)) { $out.configuration = $after.configuration }
    $out.success = $true
    return $out
}
