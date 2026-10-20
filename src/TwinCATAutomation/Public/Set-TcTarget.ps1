function Set-TcTarget {
    <#
    .SYNOPSIS
        Sets the target system AMS Net ID for deployment and, optionally, the active
        solution platform.
    .DESCRIPTION
        Calls ITcSysManager.SetTargetNetId(). With -Platform the solution configuration
        whose Name is -Configuration and whose platform is -Platform is activated
        (SolutionConfiguration.Activate()) and verified through
        SolutionBuild.ActiveConfiguration.SolutionContexts.
        In TwinCAT 4026 the active solution platform must match the target platform,
        otherwise ActivateConfiguration() silently fails ('Check config failed!' in the
        Output window, nothing written to the target): a local UmRT (TcOsSys in user
        mode) is 'TwinCAT OS (x64)', a Windows RT target 'TwinCAT RT (x64)'.
        The platform of a configuration is read from its first SolutionContexts item
        (.PlatformName): SolutionConfiguration.PlatformName itself comes back empty
        through the PowerShell COM binder.
    .PARAMETER AmsNetId
        Target AMS Net ID (e.g., "127.0.0.1.1.1" for local).
    .PARAMETER Platform
        Solution platform to activate, e.g. 'TwinCAT OS (x64)' or 'TwinCAT RT (x64)'.
        Omitted: the solution platform is not touched.
    .PARAMETER Configuration
        Solution configuration name used with -Platform. Default 'Release'.
    .OUTPUTS
        data.amsNetId; with -Platform also data.platform, data.configuration,
        data.platformChanged (bool), data.previousPlatform, data.availablePlatforms
        (distinct platforms of the -Configuration configurations).
        Unknown platform: PLATFORM_NOT_FOUND (data.availablePlatforms,
        data.availableConfigurations). Activation not visible afterwards: PLATFORM_SET_FAILED.
    .EXAMPLE
        Set-TcTarget -AmsNetId 199.5.42.250.1.1 -Platform 'TwinCAT OS (x64)'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter()]
        [string]$Platform,

        [Parameter()]
        [string]$Configuration = 'Release'
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    try {
        # Set target via ITcSysManager
        $sm.SetTargetNetId($AmsNetId)
    }
    catch {
        return New-TcResult -Success $false -ErrorMessage "Failed to set target: $_" -ErrorCode 'TARGET_SET_FAILED'
    }

    $data = [PSCustomObject]@{
        amsNetId = $AmsNetId
    }
    if ([string]::IsNullOrWhiteSpace($Platform)) {
        return New-TcResult -Success $true -Data $data
    }

    # --- solution platform ---
    $before = Get-TcSolutionPlatform
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
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix 'Reading the solution configurations failed' -Data $data
    }

    $sameConfig = @($configs | Where-Object { $_.Name -ieq $Configuration })
    $available = @($sameConfig | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Platform) } | ForEach-Object { [string]$_.Platform } | Select-Object -Unique)
    $availableConfigs = @($configs | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { [string]$_.Name } | Select-Object -Unique)
    $data | Add-Member -NotePropertyName 'configuration' -NotePropertyValue $Configuration
    $data | Add-Member -NotePropertyName 'previousPlatform' -NotePropertyValue $before.platform
    $data | Add-Member -NotePropertyName 'availablePlatforms' -NotePropertyValue $available

    $match = $null
    foreach ($c in $sameConfig) {
        if ([string]$c.Platform -ieq $Platform) { $match = $c; break }
    }
    if ($null -eq $match) {
        $data | Add-Member -NotePropertyName 'platform' -NotePropertyValue $before.platform
        $data | Add-Member -NotePropertyName 'platformChanged' -NotePropertyValue $false
        $data | Add-Member -NotePropertyName 'availableConfigurations' -NotePropertyValue $availableConfigs
        $availText = if ($available.Count -gt 0) { "'" + ($available -join "', '") + "'" } else { '(none)' }
        $msg = "Solution platform '$Platform' not found for configuration '$Configuration'. Available platforms: $availText."
        if ($sameConfig.Count -eq 0) { $msg += " No configuration named '$Configuration'; available configurations: '" + ($availableConfigs -join "', '") + "'." }
        $hint = Get-TcErrorHint -Code 'PLATFORM_NOT_FOUND'
        $hint = "$hint Available: $availText."
        return New-TcResult -Success $false -ErrorMessage $msg -ErrorCode 'PLATFORM_NOT_FOUND' -Hint $hint -Data $data
    }

    $resolvedPlatform = [string]$match.Platform
    $alreadyActive = ([string]$before.platform -ieq $resolvedPlatform) -and ([string]$before.configuration -ieq [string]$match.Name)
    if (-not $alreadyActive) {
        try {
            Invoke-TcComRetry -OperationName 'SolutionConfiguration.Activate' -ScriptBlock { $match.Com.Activate() } | Out-Null
        }
        catch {
            return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix "Activating '$Configuration|$resolvedPlatform' failed" -Data $data
        }
        # The IDE applies the new active configuration asynchronously.
        Start-Sleep -Seconds 1
    }

    $after = Get-TcSolutionPlatform
    $data | Add-Member -NotePropertyName 'platform' -NotePropertyValue $after.platform
    $data | Add-Member -NotePropertyName 'platformChanged' -NotePropertyValue (-not ([string]$before.platform -ieq [string]$after.platform))
    if (-not ([string]$after.platform -ieq $resolvedPlatform)) {
        return New-TcResult -Success $false `
            -ErrorMessage "Solution platform '$resolvedPlatform' was activated but the active solution platform reads '$($after.platform)' (configuration '$($after.configuration)')." `
            -ErrorCode 'PLATFORM_SET_FAILED' -Hint (Get-TcErrorHint -Code 'PLATFORM_SET_FAILED') -Data $data
    }
    if (-not [string]::IsNullOrWhiteSpace($after.configuration)) { $data.configuration = $after.configuration }

    New-TcResult -Success $true -Data $data
}
