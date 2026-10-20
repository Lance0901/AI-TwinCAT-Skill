function Set-TcTarget {
    <#
    .SYNOPSIS
        Sets the target system AMS Net ID for deployment and makes the active solution
        platform follow the target platform (read from the target, or -Platform).
    .DESCRIPTION
        Calls ITcSysManager.SetTargetNetId() first (always; data.targetSet = $true from
        then on, also in a PLATFORM_UNKNOWN / PLATFORM_NOT_FOUND result). Then the platform
        of the target is read with Get-TcTargetPlatform: InfoSys "Runtime type (ADS)",
        port 200 IG 0x700 SYSTEMSERVICE_TARGETINFO, IO 4 platform / IO 2 target type,
        https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html
        (TC1700/TC170x Usermode Runtime manual v1.6.1, 2026-08; the minimum runtime build
        that implements it is not confirmed - TcSystemServiceUm.exe 3.1.0.2649 /
        TwinCAT 3.1.4026.21-22 and the Windows XAR answer ADS error 0x702).
        Platform decision (data.platformCheck):
          'parameter'  -Platform given: that platform is activated for -Configuration
                       (default 'Release'), as before; data.targetPlatform is informational.
          'target'     no -Platform, the target reported a platform: the solution
                       configuration '<Configuration>|<target platform>' is activated
                       (-Configuration not given = the active configuration, fallback
                       'Release'). Not in the solution -> PLATFORM_NOT_FOUND (hint lists
                       the available platforms and says the platform came from the target).
          'unknown'    no -Platform and the target platform is not readable: nothing is
                       guessed, PLATFORM_UNKNOWN is returned (the NetId IS set: data.amsNetId,
                       data.targetSet = $true). Pass -Platform, or -NoPlatformSwitch when only
                       the NetId should be set.
          'disabled'   -NoPlatformSwitch: only the NetId is set, the solution platform is not
                       touched (data.targetPlatform still reported).
        Shared switch code: Private Set-TcSolutionPlatform (also used by Enable-TcConfig).
        In TwinCAT 4026 XAE the active solution platform must match the target platform,
        otherwise ActivateConfiguration() silently fails ('Check config failed!' in the
        Output window, nothing written to the target): a Usermode Runtime (UmRT, TcOsSys
        in user mode) is 'TwinCAT OS (x64)', a Windows RT target 'TwinCAT RT (x64)'.
    .PARAMETER AmsNetId
        Target AMS Net ID (e.g., "127.0.0.1.1.1" for local).
    .PARAMETER Platform
        Solution platform to activate, e.g. 'TwinCAT OS (x64)' or 'TwinCAT RT (x64)'.
        Omitted: the platform reported by the target (TARGETINFO) is used; not readable ->
        PLATFORM_UNKNOWN unless -NoPlatformSwitch.
    .PARAMETER Configuration
        Solution configuration name. With -Platform default 'Release'; for the automatic
        switch default = the active configuration.
    .PARAMETER NoPlatformSwitch
        Only set the NetId; never touch the solution platform and never return
        PLATFORM_UNKNOWN (ignored together with -Platform).
    .OUTPUTS
        data.amsNetId, data.targetSet ($true once SetTargetNetId succeeded),
        data.platformCheck ('parameter' | 'target' | 'unknown' | 'disabled'),
        data.targetPlatform ($null when not readable), data.targetPlatformSource
        ('adsTargetInfo' | 'unavailable'), data.adsError (e.g. '0x702'),
        data.platform (active solution platform afterwards), data.platformChanged (bool).
        When a platform was activated also data.configuration, data.previousPlatform,
        data.availablePlatforms (distinct platforms of that configuration).
        Errors: PLATFORM_UNKNOWN, PLATFORM_NOT_FOUND (data.availablePlatforms,
        data.availableConfigurations), PLATFORM_SET_FAILED.
    .EXAMPLE
        Set-TcTarget -AmsNetId 199.5.42.250.1.1 -Platform 'TwinCAT OS (x64)'
        Local UmRT, platform given explicitly (works on runtimes without TARGETINFO).
    .EXAMPLE
        Set-TcTarget -AmsNetId 199.5.42.250.1.1 -NoPlatformSwitch
        Only change the target NetId.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter()]
        [string]$Platform,

        [Parameter()]
        [string]$Configuration = 'Release',

        [Parameter()]
        [switch]$NoPlatformSwitch
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

    # Platform of the target (TARGETINFO only; never throws, never guesses)
    $tp = Get-TcTargetPlatform -AmsNetId $AmsNetId
    $explicit = -not [string]::IsNullOrWhiteSpace($Platform)
    $readable = -not [string]::IsNullOrWhiteSpace($tp.targetPlatform)
    $check = if ($explicit) { 'parameter' } elseif ($NoPlatformSwitch) { 'disabled' } elseif ($readable) { 'target' } else { 'unknown' }

    $data = [PSCustomObject]@{
        amsNetId             = $AmsNetId
        targetSet            = $true
        platformCheck        = $check
        targetPlatform       = $tp.targetPlatform
        targetPlatformSource = $tp.source
        adsError             = $tp.adsError
    }

    if ($check -eq 'disabled' -or $check -eq 'unknown') {
        # Solution platform untouched.
        $data | Add-Member -NotePropertyName 'platform' -NotePropertyValue (Get-TcSolutionPlatform).platform
        $data | Add-Member -NotePropertyName 'platformChanged' -NotePropertyValue $false
        if ($check -eq 'disabled') { return New-TcResult -Success $true -Data $data }
        $hint = Get-TcErrorHint -Code 'PLATFORM_UNKNOWN'
        if ($null -ne $hint -and -not [string]::IsNullOrWhiteSpace($tp.adsError)) { $hint = $hint.Replace('ADS 0x702', "ADS $($tp.adsError)") }
        return New-TcResult -Success $false -ErrorCode 'PLATFORM_UNKNOWN' -Hint $hint -Data $data `
            -ErrorMessage "Target set to $AmsNetId, but its platform could not be read ($($tp.detail)); the solution platform was not changed. Pass -Platform, or -NoPlatformSwitch to only set the NetId."
    }

    $wanted = $Platform
    $source = $null
    $config = $Configuration
    if ($check -eq 'target') {
        $wanted = [string]$tp.targetPlatform
        $source = "target ($($tp.source))"
        if (-not $PSBoundParameters.ContainsKey('Configuration')) {
            $active = Get-TcSolutionPlatform
            $config = if ([string]::IsNullOrWhiteSpace($active.configuration)) { 'Release' } else { [string]$active.configuration }
        }
    }

    # --- solution platform (shared with Enable-TcConfig) ---
    $sw = Set-TcSolutionPlatform -Platform $wanted -Configuration $config -PlatformSource $source
    $data | Add-Member -NotePropertyName 'configuration' -NotePropertyValue $sw.configuration
    $data | Add-Member -NotePropertyName 'previousPlatform' -NotePropertyValue $sw.previousPlatform
    $data | Add-Member -NotePropertyName 'availablePlatforms' -NotePropertyValue $sw.availablePlatforms
    $data | Add-Member -NotePropertyName 'platform' -NotePropertyValue $sw.platform
    $data | Add-Member -NotePropertyName 'platformChanged' -NotePropertyValue $sw.platformChanged
    if (-not $sw.success) {
        $err = $sw.error
        if ([string]$err.code -eq 'PLATFORM_NOT_FOUND') {
            $data | Add-Member -NotePropertyName 'availableConfigurations' -NotePropertyValue $sw.availableConfigurations
        }
        $params = @{ Success = $false; ErrorMessage = [string]$err.message; ErrorCode = [string]$err.code; Data = $data }
        $hp = $err.PSObject.Properties['hint']
        if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { $params['Hint'] = [string]$hp.Value }
        return New-TcResult @params
    }

    New-TcResult -Success $true -Data $data
}
