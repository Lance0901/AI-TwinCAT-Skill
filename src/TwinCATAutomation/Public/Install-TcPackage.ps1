function Install-TcPackage {
    <#
    .SYNOPSIS
        Plans (default) or, only with -Approved, runs 'tcpkg install <PackageId>=<Version> -y' for the TwinCAT XAE or a Remote Manager version, then reads the installed list back (#229).
    .DESCRIPTION
        Without -Approved NOTHING is installed: the result is the plan (success true,
        data.executed = false): data.command (the complete tcpkg command line that -Approved would
        run), requiresAdministrator, isAdministrator, idesToClose, runningIdes[] { processId, name,
        path, title }, alreadyInstalled, versionInFeed, feedSources (feeds that offer the version),
        availableVersions (all feed versions of the package), buildFolder / buildFolderExists
        (Remote Manager only), blockers[] (what would stop -Approved: not-elevated, ide-running,
        version-not-in-feed), dependencyNote and data.hint. Show the plan to the user and ask; run
        again with -Approved only after the user agreed to exactly this command. The plan names the
        target package only: -y also confirms whatever tcpkg resolves as dependencies (not listed
        here; data.changedPackages after the install shows what really changed).

        InfoSys "tcpkg install" (https://infosys.beckhoff.com/content/1033/tc3_installation/21007208203.html):
        'ID=version' pins the version, -y suppresses the confirmation prompt, most actions need
        administrator rights and the XAE Shell / Visual Studio may have to be closed.

        With -Approved, in this order (nothing is installed when one fails):
          alreadyInstalled  -> success, data.executed = false (nothing to do)
          not elevated      -> TCPKG_ELEVATION_REQUIRED (never elevates itself: no UAC prompt is opened)
          TcXaeShell / devenv running -> TCPKG_IDE_RUNNING (data.runningIdes lists the pids; close them yourself)
          version not on a configured feed -> TCPKG_VERSION_NOT_FOUND (data.availableVersions)
        then runs the install (-TimeoutSec) and reads 'tcpkg list -i' back: success only when the
        package is listed with exactly -Version (fail closed). Install exit code not 0 ->
        TCPKG_INSTALL_FAILED; install did not finish in time -> TCPKG_TIMEOUT (tcpkg is NOT stopped:
        it may still be installing, data.installProcessId; nothing is read back while it runs);
        exit code 0 but not listed afterwards -> TCPKG_INSTALL_UNVERIFIED. data.changedPackages =
        every package whose installed versions differ before / after (data.unexpectedChanges = the
        ones other than -PackageId, also listed in data.warnings), data.steps[] every step.
        Feeds and the myBeckhoff account are the user's business: no credentials are read, stored
        or passed.

        -PackageId accepts only TwinCAT.Standard.XAE and TwinCAT.StandardRM.XAE (the runtime package
        TwinCAT.Standard.XAR is refused); which dependencies tcpkg installs with them is decided by
        tcpkg, not by this cmdlet.
    .PARAMETER PackageId
        TwinCAT.StandardRM.XAE (a Remote Manager version, e.g. for a 4024 project) or TwinCAT.Standard.XAE.
    .PARAMETER Version
        Exact package version as listed by Get-TcPackageInfo data.available[].version, e.g. 4024.71.5.
    .PARAMETER Approved
        The user saw the plan and agreed: really run the install. Without it only the plan is returned.
    .PARAMETER TimeoutSec
        Upper bound in seconds for the install call (default 1800, max 6600); each read-only tcpkg list call is bounded by 120 s.
    .EXAMPLE
        Install-TcPackage -PackageId TwinCAT.StandardRM.XAE -Version 4024.71.5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('TwinCAT.Standard.XAE', 'TwinCAT.StandardRM.XAE')]
        [string]$PackageId,

        [Parameter(Mandatory)]
        [ValidatePattern('\A\d+\.\d+\.\d+(\.\d+)?\z')]
        [string]$Version,

        [Parameter()]
        [switch]$Approved,

        [Parameter()]
        [ValidateRange(60, 6600)]
        [int]$TimeoutSec = 1800
    )

    # ValidateSet is case-insensitive: use the canonical spelling
    $PackageId = @($script:TcPkgInstallablePackageIds | Where-Object { $_ -eq $PackageId })[0]
    $listTimeout = 120
    $exe = Get-TcPkgExecutable
    if ($null -eq $exe) {
        return New-TcResult -Success $false -ErrorCode 'TCPKG_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'TCPKG_NOT_FOUND') `
            -ErrorMessage 'TwinCAT Package Manager CLI tcpkg not found (not on PATH, no %ProgramData%\Beckhoff\TcPkg\TcPkg.exe); nothing was installed.' `
            -Data ([ordered]@{ executed = $false; packageId = $PackageId; version = $Version })
    }
    $installArgs = @('install', "$PackageId=$Version", '-y')
    $command = ("$(ConvertTo-TcPkgArgument $exe) $($installArgs -join ' ')")
    $steps = [System.Collections.Generic.List[object]]::new()

    $st = Get-TcPkgState -Exe $exe -PackageId @($PackageId) -TimeoutSec $listTimeout
    $steps.Add([ordered]@{ step = 'query'; ok = ($null -eq $st.errorCode); runs = @($st.runs) })
    $data = [ordered]@{
        executed              = $false
        approved              = [bool]$Approved
        packageId             = $PackageId
        version               = $Version
        command               = $command
        requiresAdministrator = $true
        isAdministrator       = $null
        idesToClose           = @('TcXaeShell (TwinCAT XAE Shell, 32-bit and 64-bit)', 'devenv (Visual Studio with the TwinCAT XAE)')
        runningIdes           = @()
        alreadyInstalled      = $null
        versionInFeed         = $null
        feedSources           = @()
        availableVersions     = @()
        installedVersions     = @()
        buildFolder           = $null
        buildFolderExists     = $null
        blockers              = @()
        dependencyNote        = 'tcpkg resolves dependencies itself and -y confirms them too; this plan lists only the target package (tcpkg install --dry-run was not used: its effect is not verified)'
        changedPackages       = $null
        unexpectedChanges     = $null
        installProcessId      = $null
        warnings              = @()
        steps                 = $steps
        hint                  = $null
    }
    if ($null -ne $st.errorCode) {
        return New-TcResult -Success $false -ErrorCode $st.errorCode -Hint (Get-TcErrorHint -Code $st.errorCode) -ErrorMessage "$($st.message); nothing was installed." -Data $data
    }
    $data.installedVersions = @($st.installed | ForEach-Object { $_.version })
    $data.alreadyInstalled = (@($st.installed | Where-Object { $_.version -eq $Version }).Count -gt 0)
    $hits = @($st.available | Where-Object { $_.version -eq $Version })
    $data.versionInFeed = ($hits.Count -gt 0)
    $data.feedSources = @($hits | ForEach-Object { $_.source } | Where-Object { $null -ne $_ } | Select-Object -Unique)
    $data.availableVersions = @($st.available | ForEach-Object { $_.version } | Select-Object -Unique)
    if ($PackageId -eq $script:TcPkgRemoteManagerId) {
        $data.buildFolder = ConvertTo-TcPkgBuildFolderName $Version
        $b = if ($null -ne $data.buildFolder) { $data.buildFolder.Substring(6) } else { $null }
        $data.buildFolderExists = ($null -ne $b -and @($st.remoteManagerBuilds | Where-Object { [string]$_ -eq $b }).Count -gt 0)
    }
    $data.isAdministrator = [bool](Test-TcIsElevated)
    $data.runningIdes = @(Get-TcPkgRunningIde)
    $blockers = @()
    if (-not $data.isAdministrator) { $blockers += 'not-elevated' }
    if ($data.runningIdes.Count -gt 0) { $blockers += 'ide-running' }
    if (-not $data.versionInFeed) { $blockers += 'version-not-in-feed' }
    $data.blockers = $blockers

    if (-not $Approved) {
        $data.hint = ([string]$script:TcPkgPlanHint).Replace('<PackageId>', $PackageId).Replace('<Version>', $Version)
        return New-TcResult -Success $true -Data $data
    }

    if ($data.alreadyInstalled) {
        $steps.Add([ordered]@{ step = 'install'; ok = $true; skipped = 'already-installed' })
        return New-TcResult -Success $true -Data $data
    }
    $fail = {
        param($code, $msg)
        New-TcResult -Success $false -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) -ErrorMessage $msg -Data $data
    }
    if (-not $data.isAdministrator) {
        return (& $fail 'TCPKG_ELEVATION_REQUIRED' "tcpkg install needs administrator rights and this PowerShell is not elevated; nothing was installed (no elevation was attempted). Command: $command")
    }
    if ($data.runningIdes.Count -gt 0) {
        return (& $fail 'TCPKG_IDE_RUNNING' "IDE(s) that host the TwinCAT XAE are running (pid $(@($data.runningIdes | ForEach-Object { "$($_.processId) $($_.name)" }) -join ', ')); nothing was installed.")
    }
    if (-not $data.versionInFeed) {
        return (& $fail 'TCPKG_VERSION_NOT_FOUND' "$PackageId $Version is not offered by any configured feed; nothing was installed. Feed versions: $(if ($data.availableVersions.Count) { $data.availableVersions -join ', ' } else { 'none' })")
    }

    $r = Invoke-TcPkgProcess -Exe $exe -Arguments $installArgs -TimeoutSec $TimeoutSec -NoKillOnTimeout
    $data.executed = ($null -eq $r.startError)
    $data.installProcessId = $r.processId
    $steps.Add([ordered]@{ step = 'install'; ok = ($r.exitCode -eq 0 -and -not $r.timedOut -and $null -eq $r.startError); commandLine = $r.commandLine; processId = $r.processId; exitCode = $r.exitCode; timedOut = $r.timedOut; elapsedSec = $r.elapsedSec; stdoutTail = @(Get-TcPkgTextTail $r.stdout 20); stderrTail = @(Get-TcPkgTextTail $r.stderr 20); startError = $r.startError })
    if ($null -ne $r.startError) { return (& $fail 'TCPKG_INSTALL_FAILED' "tcpkg could not be started ($($r.startError)); nothing was installed.") }
    # review M1: tcpkg was not stopped; reading back now would show a half-done install
    if ($r.timedOut) { return (& $fail 'TCPKG_TIMEOUT' "tcpkg install did not finish within $TimeoutSec s; it was NOT stopped and may still be installing (pid $($r.processId)). The install state is unknown; nothing was read back.") }

    # read back after tcpkg ended (also after a non-zero exit: report what is installed now)
    $rb = Invoke-TcPkgList -Exe $exe -Arguments @('list', '-i', '--as-json') -TimeoutSec $listTimeout
    $now = @($rb.items | Where-Object { [string]$_.Id -eq $PackageId } | ForEach-Object { [string]$_.Version })
    $verified = ($rb.ok -and @($now | Where-Object { $_ -eq $Version }).Count -gt 0)
    $steps.Add([ordered]@{ step = 'readback'; ok = $verified; listed = $rb.ok; installedVersions = @($now); run = $rb.run })
    $data.installedVersions = @($now)
    if ($rb.ok) {
        # review M3: what really changed (dependencies included), not only the target
        $data.changedPackages = @(Compare-TcPkgInstalled -Before @($st.installedItems) -After @($rb.items))
        $data.unexpectedChanges = @($data.changedPackages | Where-Object { $_.id -ne $PackageId })
        foreach ($c in $data.unexpectedChanges) { $data.warnings += "also changed: $($c.id) $(@($c.before) -join '/') -> $(@($c.after) -join '/')" }
    }
    if ($PackageId -eq $script:TcPkgRemoteManagerId -and $null -ne $data.buildFolder) {
        $xi = Get-TcXaeInstallInfo
        $data.buildFolderExists = (@($xi.remoteManagerBuilds | Where-Object { "Build_$_" -eq $data.buildFolder }).Count -gt 0)
        # review m6: the version -> folder mapping is measured once only; Connect-TcIde needs the folder
        if ($verified -and -not $data.buildFolderExists) { $data.warnings += "$($data.buildFolder) (with a .dll) was not found after the install: Connect-TcIde will still not pick the 32-bit TcXaeShell for that project version" }
    }
    if ($r.exitCode -ne 0) { return (& $fail 'TCPKG_INSTALL_FAILED' "tcpkg install exited with code $($r.exitCode) (data.steps install stdoutTail / stderrTail).") }
    if (-not $verified) { return (& $fail 'TCPKG_INSTALL_UNVERIFIED' "tcpkg install exited with 0, but 'tcpkg list -i' does not list $PackageId $Version afterwards; not counted as installed.") }
    New-TcResult -Success $true -Data $data
}
