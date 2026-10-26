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
        The platform is decided by the target, not by the XAE version: a Usermode Runtime
        (UmRT, TcOsSys in user mode) or TwinCAT/BSD is 'TwinCAT OS (x64)', a Windows RT
        target 'TwinCAT RT (x64)', a CX ARM target the matching ARM platform. When the
        active solution platform does not match the target, ActivateConfiguration() fails
        ('Check config failed!' in the Output window, measured on 4026 XAE; ACTIVATE_FAILED).
        A solution platform name can map to a project platform with another name (solution
        'Release|TwinCAT OS (x64)' -> .tsproj 'TwinCAT OS (ARMT2)'): before switching, the
        project platform of the .tsproj under the chosen solution platform is checked; a
        mismatch switches nothing and returns PLATFORM_PROJECT_MISMATCH (data.platformMap).
        InfoSys "Setting the TwinCAT target platform":
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html
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
        data.platform (active solution platform afterwards), data.projectPlatform (project
        platform of the ACTIVE .tsproj afterwards; $null without .tsproj), data.platformChanged (bool).
        After a switch attempt also data.requestedProjectPlatform (project platform of the
        TwinCAT project (.tsproj) under the requested solution platform).
        When a platform was activated also data.configuration, data.previousPlatform,
        data.availablePlatforms (solution platform names of that configuration),
        data.projectCheck ('ok' | 'mismatch' | 'no-tsproj'), data.platformMatchedBy,
        data.platformMap (solution platform -> @{ solutionPlatform; projectPlatforms =
        @(@{ project; platform; shouldBuild }) }), data.restored (after PLATFORM_SET_FAILED).
        Errors: PLATFORM_UNKNOWN, PLATFORM_NOT_FOUND (data.availablePlatforms,
        data.availableConfigurations), PLATFORM_PROJECT_MISMATCH (data.platformMap,
        data.requestedProjectPlatform; nothing switched), PLATFORM_SET_FAILED (data.restored).
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
        $cur = Get-TcSolutionPlatform
        $data | Add-Member -NotePropertyName 'platform' -NotePropertyValue $cur.platform
        $data | Add-Member -NotePropertyName 'projectPlatform' -NotePropertyValue $cur.projectPlatform
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
    $data | Add-Member -NotePropertyName 'projectPlatform' -NotePropertyValue $sw.projectPlatform
    $data | Add-Member -NotePropertyName 'requestedProjectPlatform' -NotePropertyValue $sw.requestedProjectPlatform
    $data | Add-Member -NotePropertyName 'platformChanged' -NotePropertyValue $sw.platformChanged
    $data | Add-Member -NotePropertyName 'projectCheck' -NotePropertyValue $sw.projectCheck
    $data | Add-Member -NotePropertyName 'platformMatchedBy' -NotePropertyValue $sw.platformMatchedBy
    $data | Add-Member -NotePropertyName 'platformMap' -NotePropertyValue $sw.platformMap
    if ($null -ne $sw.restored) { $data | Add-Member -NotePropertyName 'restored' -NotePropertyValue $sw.restored }
    $swp = $sw.PSObject.Properties['stateWarning']
    if ($null -ne $swp -and -not [string]::IsNullOrWhiteSpace([string]$swp.Value)) {
        $prev = $data.PSObject.Properties['warning']
        $text = if ($null -ne $prev -and -not [string]::IsNullOrWhiteSpace([string]$prev.Value)) { "$([string]$prev.Value) $([string]$swp.Value)" } else { [string]$swp.Value }
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $text -Force
    }
    if (-not $sw.success) {
        $err = $sw.error
        if ([string]$err.code -eq 'PLATFORM_NOT_FOUND') {
            $data | Add-Member -NotePropertyName 'availableConfigurations' -NotePropertyValue $sw.availableConfigurations
        }
        $params = @{ Success = $false; ErrorMessage = [string]$err.message; ErrorCode = [string]$err.code; Data = $data }
        $hp = $err.PSObject.Properties['hint']
        if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { $params['Hint'] = ([string]$hp.Value).Replace('<id>', $AmsNetId) }
        return New-TcResult @params
    }

    New-TcResult -Success $true -Data $data
}
