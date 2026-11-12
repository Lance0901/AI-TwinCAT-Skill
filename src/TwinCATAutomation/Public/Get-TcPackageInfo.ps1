function Get-TcPackageInfo {
    <#
    .SYNOPSIS
        Read-only: installed and feed versions of the TwinCAT XAE / XAR / Remote Manager packages, through the TwinCAT Package Manager CLI tcpkg (#229).
    .DESCRIPTION
        Runs only read-only tcpkg commands (InfoSys "tcpkg list",
        https://infosys.beckhoff.com/content/1033/tc3_installation/21007205899.html):
          tcpkg list -i --as-json            (installed packages, ~1.7 MB, filtered here by Id)
          tcpkg list <PackageId> -a --as-json (every version on the configured feeds, one call per id,
                                              network; skipped with -NoAvailable)
        Nothing is installed, downloaded or configured; feeds and the myBeckhoff account are set up by
        the user in the Package Manager (this cmdlet never handles credentials).

        data: tcpkg { path }, packageIds, installed[] { id, version, installDate, workload },
        available[] { id, version, source (feed name, e.g. 'Beckhoff Outdated Feed'), isPreview,
        installed }, and for every TwinCAT.StandardRM.XAE entry (Remote Manager) buildFolder
        (Build_<a>.<b> of version <a>.<b>.<c>; measured 2026-11-12: 4024.71.2 <-> Build_4024.71),
        buildFolderPath and buildFolderExists (the folder with at least one .dll below
        <TwinCATDir>\3.1\Components\Base, the same check Connect-TcIde uses); remoteManagerRoot,
        remoteManagerBuilds, runs[] (command line, exit code, seconds of every tcpkg call).

        Errors: TCPKG_NOT_FOUND (tcpkg is neither on PATH nor in %ProgramData%\Beckhoff\TcPkg),
        TCPKG_TIMEOUT (one tcpkg call did not finish within -TimeoutSec and was stopped),
        TCPKG_LIST_FAILED (tcpkg exit code not 0, e.g. unknown package id or feed not reachable /
        not signed in, or output that is not JSON; data.runs[].stderrTail). Each carries error.hint.
    .PARAMETER PackageId
        Package ids to report (exact, case-insensitive). Default: TwinCAT.Standard.XAE,
        TwinCAT.Standard.XAR, TwinCAT.StandardRM.XAE.
    .PARAMETER NoAvailable
        Only the installed packages: no feed query (offline, about 2 s).
    .PARAMETER TimeoutSec
        Upper bound in seconds for EACH tcpkg call (default 60); the call is stopped after it.
    .EXAMPLE
        Get-TcPackageInfo -PackageId TwinCAT.StandardRM.XAE
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string[]]$PackageId,

        [Parameter()]
        [switch]$NoAvailable,

        [Parameter()]
        [ValidateRange(5, 1800)]
        [int]$TimeoutSec = 60
    )

    $ids = @($PackageId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($ids.Count -eq 0) { $ids = @($script:TcPkgDefaultPackageIds) }
    $exe = Get-TcPkgExecutable
    if ($null -eq $exe) {
        return New-TcResult -Success $false -ErrorCode 'TCPKG_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'TCPKG_NOT_FOUND') `
            -ErrorMessage 'TwinCAT Package Manager CLI tcpkg not found (not on PATH, no %ProgramData%\Beckhoff\TcPkg\TcPkg.exe).' `
            -Data ([ordered]@{ tcpkg = $null; packageIds = $ids })
    }
    $st = Get-TcPkgState -Exe $exe -PackageId $ids -TimeoutSec $TimeoutSec -NoAvailable:$NoAvailable
    $data = [ordered]@{
        tcpkg               = [ordered]@{ path = $exe }
        packageIds          = $ids
        installed           = @($st.installed)
        available           = $(if ($NoAvailable) { $null } else { @($st.available) })
        remoteManagerRoot   = $st.remoteManagerRoot
        remoteManagerBuilds = @($st.remoteManagerBuilds)
        runs                = @($st.runs)
    }
    if ($null -ne $st.errorCode) {
        return New-TcResult -Success $false -ErrorCode $st.errorCode -Hint (Get-TcErrorHint -Code $st.errorCode) -ErrorMessage $st.message -Data $data
    }
    New-TcResult -Success $true -Data $data
}
