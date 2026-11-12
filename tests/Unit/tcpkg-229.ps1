# Unit (#229): Get-TcPackageInfo / Install-TcPackage around the tcpkg CLI, no tcpkg, IDE or runtime needed.
#   A  Invoke-TcPkgProcess with a real child process (powershell.exe, not tcpkg): large stdout + stderr
#      (no dead-lock), exit code, timeout kills the process
#   B  Get-TcPackageInfo with mocked seams (Get-TcPkgExecutable, Invoke-TcPkgProcess, Get-TcXaeInstallInfo):
#      JSON parsing / filtering, Remote Manager Build_ folder, TCPKG_NOT_FOUND, TCPKG_TIMEOUT,
#      TCPKG_LIST_FAILED (exit code, not JSON), -NoAvailable
#   C  Install-TcPackage: plan by default (nothing executed) with a one-time PlanToken; Approved
#      without / with an unknown, foreign, used or expired token or a changed state -> TCPKG_PLAN_REQUIRED;
#      preconditions (TCPKG_ELEVATION_REQUIRED, TCPKG_IDE_RUNNING, TCPKG_RUNNING, TCPKG_PRECHECK_FAILED,
#      TCPKG_VERSION_NOT_FOUND); TcPkg.exe only from %ProgramData% with a Beckhoff signature
#      (TCPKG_NOT_FOUND, TCPKG_SIGNATURE_INVALID, fail closed); already installed,
#      install + readback (success / TCPKG_INSTALL_UNVERIFIED / TCPKG_INSTALL_FAILED / TCPKG_TIMEOUT).
#      The real install path is only covered by these mocks (never run against tcpkg).
#   D  PROGID_REQUIRED hint of Resolve-TcLaunchProgId / Get-TcProjectVersion suggests Install-TcPackage
#      only when the Remote Manager folder of the project version is missing
#   powershell.exe -NoProfile -File tests/Unit/tcpkg-229.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-229-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

try {
    # --- A: real child process ---
    $big = Join-Path $root 'big.ps1'
    Set-Content -LiteralPath $big -Encoding ASCII -Value @(
        '$line = "x" * 1000'
        'for ($i = 0; $i -lt 2000; $i++) { [Console]::Out.WriteLine($line); if ($i % 10 -eq 0) { [Console]::Error.WriteLine("err $i") } }'
        'exit 3'
    )
    $r = & $mod { param($e, $a) Invoke-TcPkgProcess -Exe $e -Arguments $a -TimeoutSec 60 } $ps @('-NoProfile', '-File', $big)
    Check 'A1 ~2 MB stdout + stderr read without dead-lock, exit code kept' (-not $r.timedOut -and $r.exitCode -eq 3 -and $r.stdout.Length -ge 2000000 -and $r.stderr -match 'err 1990') "exit=$($r.exitCode) out=$($r.stdout.Length) timedOut=$($r.timedOut)"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($e) Invoke-TcPkgProcess -Exe $e -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSec 2 } $ps
    $sec = $sw.Elapsed.TotalSeconds
    Check 'A2 timeout: process stopped, timedOut, no exit code' ($r.timedOut -and $null -eq $r.exitCode -and $sec -lt 20) "timedOut=$($r.timedOut) sec=$sec"
    $r = & $mod { param($e) Invoke-TcPkgProcess -Exe $e -TimeoutSec 5 } (Join-Path $root 'missing.exe')
    Check 'A3 exe missing -> startError, no exception' ($null -ne $r.startError -and $null -eq $r.exitCode) "$($r.startError)"
    $q = & $mod { ConvertTo-TcPkgArgument 'C:\Program Files\x y\' }
    Check 'A4 argument with spaces quoted, trailing backslash doubled' ($q -eq '"C:\Program Files\x y\\"') $q
    $r = & $mod { param($e) Invoke-TcPkgProcess -Exe $e -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 60') -TimeoutSec 2 -NoKillOnTimeout } $ps
    $alive = $null -ne (Get-Process -Id $r.processId -ErrorAction SilentlyContinue)
    Check 'A6 -NoKillOnTimeout (install): timedOut, process left running, pid returned' ($r.timedOut -and -not $r.killed -and $alive) "pid=$($r.processId) alive=$alive"
    if ($alive) { Stop-Process -Id $r.processId -ErrorAction SilentlyContinue }   # the child this test started
    Check 'A5 Build folder name drops the third part' ((& $mod { ConvertTo-TcPkgBuildFolderName '4024.71.2' }) -eq 'Build_4024.71' -and $null -eq (& $mod { ConvertTo-TcPkgBuildFolderName 'abc' })) ''

    # the real signature check, captured before the mocks replace it (C34)
    $realSig = & $mod { ${function:Test-TcPkgSignature} }
    # --- mocks ---
    $global:Pkg229 = @{
        exe       = 'C:\fake\TcPkg.exe'
        calls     = [System.Collections.Generic.List[object]]::new()
        installed = @(
            @{ Id = 'TwinCAT.Standard.XAE'; Version = '4026.22.0'; Source = $null; Workload = $true; InstallDate = '2026-05-02T00:13:29+08:00' }
            @{ Id = 'TwinCAT.StandardRM.XAE'; Version = '4024.71.2'; Source = $null; Workload = $true; InstallDate = '2026-01-02T12:28:44+08:00' }
            @{ Id = 'TwinCAT.StandardRM.XAE'; Version = '4026.22.0'; Source = $null; Workload = $true; InstallDate = $null }
            @{ Id = 'Other.Package'; Version = '1.0.0'; Source = $null; Workload = $false; InstallDate = $null }
        )
        feed      = @{
            'TwinCAT.StandardRM.XAE' = @(
                @{ Id = 'TwinCAT.StandardRM.XAE'; Version = '4024.71.5'; Source = 'Beckhoff Outdated Feed'; IsPreview = $null }
                @{ Id = 'TwinCAT.StandardRM.XAE'; Version = '4024.7.37'; Source = 'Beckhoff Outdated Feed'; IsPreview = $null }
                @{ Id = 'TwinCAT.StandardRM.XAE'; Version = '4026.22.0'; Source = 'Beckhoff Stable Feed'; IsPreview = $null }
            )
            'TwinCAT.Standard.XAE'   = @(@{ Id = 'TwinCAT.Standard.XAE'; Version = '4026.22.0'; Source = 'Beckhoff Stable Feed'; IsPreview = $null }, @{ Id = 'TwinCAT.Standard.XAE'; Version = '4026.23.1'; Source = 'Beckhoff Stable Feed'; IsPreview = $null })
            'TwinCAT.Standard.XAR'   = @(@{ Id = 'TwinCAT.Standard.XAR'; Version = '4026.22.0'; Source = 'Beckhoff Stable Feed'; IsPreview = $null })
        }
        listMode    = 'ok'        # ok | timeout | exit | notjson
        listFailOn  = 'list'      # first arg pattern of the call that fails
        installMode = 'ok'        # ok | exit | timeout | noop
        elevated    = $true
        ides        = @()
        xaeBuilds   = @('4024.71', '4026.22')
    }
    & $mod {
        function script:Get-TcPkgExecutable { [CmdletBinding()] param() $global:Pkg229.exe }
        function script:Test-TcIsElevated { [CmdletBinding()] param() $global:Pkg229.elevated }
        function script:Get-TcPkgRunningIde { [CmdletBinding()] param() if ($global:Pkg229.ideThrow) { throw 'Access is denied' }; @($global:Pkg229.ides) }
        function script:Get-TcPkgRunningPackageManager { [CmdletBinding()] param() if ($global:Pkg229.pmThrow) { throw 'Access is denied' }; @($global:Pkg229.pkgProcs) }
        function script:Get-TcPkgDefaultExecutable { [CmdletBinding()] param() $global:Pkg229.defaultExe }
        function script:Test-TcPkgSignature { [CmdletBinding()] param([string]$Path) if ($global:Pkg229.sigThrow) { throw 'Get-AuthenticodeSignature is not available' }; [PSCustomObject]$global:Pkg229.sig }
        function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() [PSCustomObject]@{ installedBuild = 4026; remoteManagerRoot = 'C:\TwinCAT\3.1\Components\Base'; remoteManagerBuilds = @($global:Pkg229.xaeBuilds); remoteManagerReason = $null; remoteManagerSearched = @() } }
        function script:Invoke-TcPkgProcess {
            [CmdletBinding()] param([string]$Exe, [string[]]$Arguments = @(), [int]$TimeoutSec = 60, [switch]$NoKillOnTimeout)
            $m = $global:Pkg229; $m.calls.Add(($Arguments -join ' '))
            $res = [PSCustomObject]@{ exitCode = 0; stdout = ''; stderr = ''; timedOut = $false; killed = $false; processId = 9999; startError = $null; elapsedSec = 0.1; commandLine = "$Exe $($Arguments -join ' ')" }
            if ($Arguments[0] -eq 'install') {
                switch ($m.installMode) {
                    'exit' { $res.exitCode = 1; $res.stderr = 'Error: install failed' }
                    'timeout' { $res.exitCode = $null; $res.timedOut = $true; $global:Pkg229.noKill = [bool]$NoKillOnTimeout }
                    'okdep' { $id, $ver = $Arguments[1] -split '=', 2; $m.installed = @($m.installed) + @(@{ Id = $id; Version = $ver; Source = $null; Workload = $true; InstallDate = $null }, @{ Id = 'TwinCAT.Standard.XAR'; Version = '4026.23.1'; Source = $null; Workload = $true; InstallDate = $null }) }
                    'ok' { $id, $ver = $Arguments[1] -split '=', 2; $m.installed = @($m.installed) + @(@{ Id = $id; Version = $ver; Source = $null; Workload = $true; InstallDate = $null }) }
                    default { }
                }
                return $res
            }
            $isFailing = ($m.listMode -ne 'ok') -and (($Arguments -join ' ') -match $m.listFailOn)
            if ($isFailing) {
                switch ($m.listMode) {
                    'timeout' { $res.exitCode = $null; $res.timedOut = $true }
                    'exit' { $res.exitCode = 144; $res.stdout = "Error: The package 'x' was not found within the configured source(s)." }
                    'notjson' { $res.stdout = 'TcPkg 2.4.18 something else' }
                }
                return $res
            }
            $items = if ($Arguments -contains '-i') { @($m.installed) } else { @($m.feed[$Arguments[1]]) }
            $res.stdout = ConvertTo-Json -InputObject @($items | ForEach-Object { [PSCustomObject]$_ }) -Depth 4 -Compress
            $res
        }
    }
    $reset = { $global:Pkg229.noKill = $null; $global:Pkg229.calls.Clear(); $global:Pkg229.listMode = 'ok'; $global:Pkg229.listFailOn = 'list'; $global:Pkg229.installMode = 'ok'; $global:Pkg229.elevated = $true; $global:Pkg229.ides = @(); $global:Pkg229.exe = 'C:\fake\TcPkg.exe'; $global:Pkg229.defaultExe = 'C:\fake\TcPkg.exe'; $global:Pkg229.sig = @{ ok = $true; status = 'Valid'; subject = 'CN=Beckhoff Automation GmbH & Co. KG, O=Beckhoff Automation GmbH & Co. KG'; error = $null }; $global:Pkg229.sigThrow = $false; $global:Pkg229.pkgProcs = @(); $global:Pkg229.ideThrow = $false; $global:Pkg229.pmThrow = $false; & $mod { $script:TcPkgPlans = @{} } }

    # --- B: Get-TcPackageInfo ---
    & $reset
    $r = Get-TcPackageInfo
    $inst = @($r.data.installed | ForEach-Object { "$($_.id) $($_.version)" }) -join ','
    Check 'B1 success, installed filtered to the three ids (Other.Package dropped)' ($r.success -and $inst -eq 'TwinCAT.Standard.XAE 4026.22.0,TwinCAT.StandardRM.XAE 4024.71.2,TwinCAT.StandardRM.XAE 4026.22.0') $inst
    Check 'B2 one list -i and one list <id> -a per id' (($global:Pkg229.calls -join '|') -eq 'list -i --as-json|list TwinCAT.Standard.XAE -a --as-json|list TwinCAT.Standard.XAR -a --as-json|list TwinCAT.StandardRM.XAE -a --as-json') ($global:Pkg229.calls -join '|')
    $rmAvail = @($r.data.available | Where-Object { $_.id -eq 'TwinCAT.StandardRM.XAE' })
    Check 'B3 available sorted numerically (4024.7.37 before 4024.71.5) with source' ((@($rmAvail | ForEach-Object { $_.version }) -join ',') -eq '4024.7.37,4024.71.5,4026.22.0' -and $rmAvail[1].source -eq 'Beckhoff Outdated Feed') (@($rmAvail | ForEach-Object { $_.version }) -join ',')
    $a715 = $rmAvail | Where-Object { $_.version -eq '4024.71.5' }
    Check 'B4 RM feed 4024.71.5 -> Build_4024.71 exists, not installed' ($a715.buildFolder -eq 'Build_4024.71' -and $a715.buildFolderExists -eq $true -and $a715.installed -eq $false -and $a715.buildFolderPath -eq 'C:\TwinCAT\3.1\Components\Base\Build_4024.71') ($a715 | ConvertTo-Json -Compress)
    $a737 = $rmAvail | Where-Object { $_.version -eq '4024.7.37' }
    Check 'B5 RM feed 4024.7.37 -> Build_4024.7 missing' ($a737.buildFolder -eq 'Build_4024.7' -and $a737.buildFolderExists -eq $false) ($a737 | ConvertTo-Json -Compress)
    $a26 = $rmAvail | Where-Object { $_.version -eq '4026.22.0' }
    $xae = @($r.data.available | Where-Object { $_.id -eq 'TwinCAT.Standard.XAE' })[0]
    Check 'B6 installed flag on feed entries; non-RM entries carry no buildFolder' ($a26.installed -eq $true -and $null -eq $xae.PSObject.Properties['buildFolder']) ''
    $json = $r | ConvertTo-Json -Depth 8 -Compress
    Check 'B7 result serializes to JSON' ($json -match '"success":true') ''
    & $reset
    $r = Get-TcPackageInfo -PackageId 'twincat.standardrm.xae' -NoAvailable
    Check 'B8 -PackageId case-insensitive, -NoAvailable -> only list -i, available null' ($r.success -and @($r.data.installed).Count -eq 2 -and $null -eq $r.data.available -and $global:Pkg229.calls.Count -eq 1) ($global:Pkg229.calls -join '|')
    & $reset; $global:Pkg229.exe = $null
    $r = Get-TcPackageInfo
    Check 'B9 tcpkg missing -> TCPKG_NOT_FOUND with hint, nothing run' (-not $r.success -and $r.error.code -eq 'TCPKG_NOT_FOUND' -and -not [string]::IsNullOrWhiteSpace($r.error.hint) -and $global:Pkg229.calls.Count -eq 0) "$($r.error.code)"
    & $reset; $global:Pkg229.listMode = 'timeout'; $global:Pkg229.listFailOn = '-i'
    $r = Get-TcPackageInfo
    Check 'B10 list -i timeout -> TCPKG_TIMEOUT, no feed query after it' (-not $r.success -and $r.error.code -eq 'TCPKG_TIMEOUT' -and $global:Pkg229.calls.Count -eq 1 -and $r.data.runs[0].timedOut) "$($r.error.code) calls=$($global:Pkg229.calls.Count)"
    & $reset; $global:Pkg229.listMode = 'exit'; $global:Pkg229.listFailOn = 'StandardRM'
    $r = Get-TcPackageInfo
    Check 'B11 feed list exit 144 -> TCPKG_LIST_FAILED with stdout tail and partial data' (-not $r.success -and $r.error.code -eq 'TCPKG_LIST_FAILED' -and $r.error.message -match '144' -and @($r.data.installed).Count -eq 3 -and (@($r.data.runs)[-1].stdoutTail -join ' ') -match 'not found') "$($r.error.code) $($r.error.message)"
    & $reset; $global:Pkg229.listMode = 'notjson'; $global:Pkg229.listFailOn = '-i'
    $r = Get-TcPackageInfo
    Check 'B12 output not JSON -> TCPKG_LIST_FAILED' (-not $r.success -and $r.error.code -eq 'TCPKG_LIST_FAILED' -and $r.error.message -match 'JSON') "$($r.error.message)"
    $bad = $false; try { $null = Get-TcPackageInfo -PackageId 'x; rm -rf' } catch { $bad = $true }
    Check 'B13 -PackageId with spaces / ; rejected by validation' $bad ''
    $bad = $false; try { $null = Get-TcPackageInfo -PackageId a, b, c, d, e, f } catch { $bad = $true }
    Check 'B14 more than 5 ids rejected (bounded total time)' $bad ''
    $bad = $false; try { $null = Get-TcPackageInfo -TimeoutSec 121 } catch { $bad = $true }
    Check 'B15 TimeoutSec above 120 rejected' $bad ''

    # --- C: Install-TcPackage ---
    # #229 PR #257 review: Approved needs the one-time PlanToken of a plan; plan first, clear the calls, then approve
    $plan = { param($id, $ver) Install-TcPackage -PackageId $id -Version $ver }
    $approve = { param($id, $ver, $tok) $global:Pkg229.calls.Clear(); Install-TcPackage -PackageId $id -Version $ver -Approved -PlanToken $tok }
    $installs = { @($global:Pkg229.calls | Where-Object { $_ -like 'install*' }).Count }
    & $reset; $global:Pkg229.elevated = $false; $global:Pkg229.ides = @([PSCustomObject]@{ processId = 4242; name = 'devenv'; path = 'C:\vs\devenv.exe'; title = 'x' })
    $r = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    Check 'C1 default = plan: success, executed false, no install call, one-time planToken' ($r.success -and $r.data.executed -eq $false -and (& $installs) -eq 0 -and $r.data.planToken -match '^[0-9a-f]{32}$' -and $null -ne $r.data.planExpiresAtUtc) ($global:Pkg229.calls -join '|')
    Check 'C2 data.plan: full command, admin need, IDEs, blockers; hint has no ready-to-run Approved command' ($r.data.plan.command -eq 'C:\fake\TcPkg.exe install TwinCAT.StandardRM.XAE=4024.71.5 -y' -and $r.data.plan.requiresAdministrator -and $r.data.plan.isAdministrator -eq $false -and $r.data.plan.runningIdes[0].processId -eq 4242 -and (@($r.data.plan.blockers) -join ',') -eq 'not-elevated,ide-running' -and $r.data.hint -match 'data\.plan' -and $r.data.hint -match 'PlanToken' -and $r.data.hint -notmatch '4024\.71\.5' -and $r.data.hint -notmatch '-Approved\b') "$($r.data.plan.command) / $(@($r.data.plan.blockers) -join ',') / $($r.data.hint)"
    Check 'C3 plan: versionInFeed, feed source, Build folder, signature' ($r.data.plan.versionInFeed -and (@($r.data.plan.feedSources) -join ',') -eq 'Beckhoff Outdated Feed' -and $r.data.buildFolder -eq 'Build_4024.71' -and $r.data.buildFolderExists -eq $true -and $r.data.plan.alreadyInstalled -eq $false -and $r.data.plan.signature.ok) ''
    & $reset
    $r = & $plan TwinCAT.StandardRM.XAE 4024.99.1
    Check 'C4 plan for a version not on the feed -> blocker version-not-in-feed, still only a plan' ($r.success -and $r.data.executed -eq $false -and (@($r.data.plan.blockers) -join ',') -eq 'version-not-in-feed') (@($r.data.plan.blockers) -join ',')
    & $reset
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $null
    Check 'C5 Approved without PlanToken -> TCPKG_PLAN_REQUIRED, no tcpkg call at all' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and $global:Pkg229.calls.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) "$($r.error.code) calls=$($global:Pkg229.calls.Count)"
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 ('0' * 32)
    Check 'C6 unknown PlanToken -> TCPKG_PLAN_REQUIRED, no tcpkg call' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and $global:Pkg229.calls.Count -eq 0) "$($r.error.code)"
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.Standard.XAE 4026.23.1 $t
    Check 'C7 PlanToken of another command -> TCPKG_PLAN_REQUIRED, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and (& $installs) -eq 0) "$($r.error.code)"
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C8 a token presented once (even for a refused command) is used up -> TCPKG_PLAN_REQUIRED' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and (& $installs) -eq 0) "$($r.error.code)"
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    & $mod { foreach ($k in @($script:TcPkgPlans.Keys)) { $script:TcPkgPlans[$k].expiresUtc = [DateTime]::UtcNow.AddSeconds(-1) } }
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C9 expired PlanToken -> TCPKG_PLAN_REQUIRED, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and (& $installs) -eq 0 -and $r.error.message -match 'expired') "$($r.error.message)"
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $global:Pkg229.ides = @([PSCustomObject]@{ processId = 777; name = 'TcXaeShell'; path = 'C:\x\TcXaeShell.exe'; title = 't' })
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C10 state changed since the plan (an IDE started) -> TCPKG_PLAN_REQUIRED, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_PLAN_REQUIRED' -and (& $installs) -eq 0 -and $r.error.message -match 'changed') "$($r.error.message)"
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C11 approved plan with an IDE running -> TCPKG_IDE_RUNNING naming the pid, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_IDE_RUNNING' -and $r.error.message -match '777' -and (& $installs) -eq 0) "$($r.error.message)"
    & $reset; $global:Pkg229.elevated = $false
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C12 approved, not elevated -> TCPKG_ELEVATION_REQUIRED, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_ELEVATION_REQUIRED' -and $r.data.executed -eq $false -and (& $installs) -eq 0) "$($r.error.code)"
    & $reset; $global:Pkg229.pkgProcs = @([PSCustomObject]@{ processId = 31; name = 'TcPkg'; path = 'C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe'; title = '' })
    $p = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $p.data.planToken
    Check 'C13 tcpkg / Package Manager running -> blocker tcpkg-running, TCPKG_RUNNING, no install' ((@($p.data.plan.blockers) -join ',') -eq 'tcpkg-running' -and -not $r.success -and $r.error.code -eq 'TCPKG_RUNNING' -and $r.error.message -match '31' -and (& $installs) -eq 0) "$(@($p.data.plan.blockers) -join ',') $($r.error.code)"
    & $reset; $global:Pkg229.ideThrow = $true
    $p = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $p.data.planToken
    Check 'C14 IDE scan throws -> blocker process-scan-failed, TCPKG_PRECHECK_FAILED (fail closed)' ((@($p.data.plan.blockers) -join ',') -eq 'process-scan-failed' -and -not $r.success -and $r.error.code -eq 'TCPKG_PRECHECK_FAILED' -and (& $installs) -eq 0) "$(@($p.data.plan.blockers) -join ',') $($r.error.code)"
    & $reset; $global:Pkg229.pmThrow = $true
    $p = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    Check 'C15 tcpkg process scan throws -> blocker process-scan-failed' ((@($p.data.plan.blockers) -join ',') -eq 'process-scan-failed') (@($p.data.plan.blockers) -join ',')
    & $reset
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.99.1).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.99.1 $t
    Check 'C16 approved, version not on the feed -> TCPKG_VERSION_NOT_FOUND with feed versions, no install' (-not $r.success -and $r.error.code -eq 'TCPKG_VERSION_NOT_FOUND' -and (@($r.data.availableVersions) -contains '4024.71.5') -and (& $installs) -eq 0) "$($r.error.code)"
    & $reset
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.2).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.2 $t
    Check 'C17 approved, already installed -> success, executed false, no install' ($r.success -and $r.data.executed -eq $false -and $r.data.alreadyInstalled -and (& $installs) -eq 0) ''
    & $reset
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C18 approved, all ok -> exactly "install <id>=<ver> -y", read back, success' ($r.success -and $r.data.executed -and (& $installs) -eq 1 -and @($global:Pkg229.calls | Where-Object { $_ -like 'install*' })[0] -eq 'install TwinCAT.StandardRM.XAE=4024.71.5 -y' -and $global:Pkg229.calls[-1] -eq 'list -i --as-json' -and (@($r.data.steps | ForEach-Object { $_.step }) -join ',') -eq 'query,install,readback') ($global:Pkg229.calls -join '|')
    $r2 = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C19 the same token again after a successful install -> TCPKG_PLAN_REQUIRED' (-not $r2.success -and $r2.error.code -eq 'TCPKG_PLAN_REQUIRED' -and $global:Pkg229.calls.Count -eq 0) "$($r2.error.code)"
    $global:Pkg229.installed = @($global:Pkg229.installed | Where-Object { -not ($_.Id -eq 'TwinCAT.StandardRM.XAE' -and $_.Version -eq '4024.71.5') })
    & $reset; $global:Pkg229.installMode = 'noop'
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C20 install exit 0 but not listed afterwards -> TCPKG_INSTALL_UNVERIFIED (fail closed)' (-not $r.success -and $r.error.code -eq 'TCPKG_INSTALL_UNVERIFIED' -and $r.data.executed) "$($r.error.code)"
    & $reset; $global:Pkg229.installMode = 'exit'
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    $step = @($r.data.steps | Where-Object { $_.step -eq 'install' })[0]
    Check 'C21 install exit 1 -> TCPKG_INSTALL_FAILED with stderr tail; message says whether the target is listed' (-not $r.success -and $r.error.code -eq 'TCPKG_INSTALL_FAILED' -and (@($step.stderrTail) -join ' ') -match 'install failed' -and $r.error.message -match 'not listed') "$($r.error.message)"
    & $reset; $global:Pkg229.installMode = 'timeout'
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C22 install timeout -> TCPKG_TIMEOUT, tcpkg not killed (pid), nothing read back' (-not $r.success -and $r.error.code -eq 'TCPKG_TIMEOUT' -and $r.error.message -match 'NOT stopped' -and $global:Pkg229.noKill -and $r.data.installProcessId -eq 9999 -and $global:Pkg229.calls[-1] -like 'install*') "$($r.error.code) last=$($global:Pkg229.calls[-1])"
    & $reset
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $global:Pkg229.listMode = 'timeout'; $global:Pkg229.listFailOn = 'StandardRM'
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C23 feed query timeout after a valid token -> TCPKG_TIMEOUT before any install' (-not $r.success -and $r.error.code -eq 'TCPKG_TIMEOUT' -and (& $installs) -eq 0) "$($r.error.code)"
    & $reset; $global:Pkg229.listMode = 'timeout'; $global:Pkg229.listFailOn = 'StandardRM'
    $r = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    Check 'C24 plan whose feed query failed -> error, no planToken' (-not $r.success -and $r.error.code -eq 'TCPKG_TIMEOUT' -and $null -eq $r.data.planToken) "$($r.error.code)"
    $bad = $false; try { $null = Install-TcPackage -PackageId TwinCAT.Standard.XAR -Version 4026.22.0 } catch { $bad = $true }
    Check 'C25 the runtime package XAR is not installable' $bad ''
    $bad = $false; try { $null = Install-TcPackage -PackageId TwinCAT.StandardRM.XAE -Version '4024.71.5 --pre' } catch { $bad = $true }
    Check 'C26 -Version must be a plain dotted number' $bad ''
    $bad = $false; try { $null = Install-TcPackage -PackageId TwinCAT.StandardRM.XAE -Version "4024.71.5`n" } catch { $bad = $true }
    Check 'C27 -Version with a trailing newline rejected' $bad ''
    & $reset
    $r = & $plan twincat.standardrm.xae 4024.71.5
    Check 'C28 PackageId in any case -> canonical id; plan with NO blocker still runs no install' ($r.data.plan.command -match 'install TwinCAT\.StandardRM\.XAE=4024\.71\.5 -y$' -and @($r.data.plan.blockers).Count -eq 0 -and $r.data.executed -eq $false -and (& $installs) -eq 0) "$($r.data.plan.command)"
    & $reset; $global:Pkg229.installMode = 'okdep'
    $t = (& $plan TwinCAT.Standard.XAE 4026.23.1).data.planToken
    $r = & $approve TwinCAT.Standard.XAE 4026.23.1 $t
    $chg = @($r.data.changedPackages | ForEach-Object { "$($_.id):$(@($_.before) -join '/')>$(@($_.after) -join '/')" }) -join ','
    Check 'C29 a dependency changed too -> success, changedPackages + unexpectedChanges + warning' ($r.success -and $chg -eq 'TwinCAT.Standard.XAE:4026.22.0>4026.22.0/4026.23.1,TwinCAT.Standard.XAR:>4026.23.1' -and @($r.data.unexpectedChanges).Count -eq 1 -and (@($r.data.warnings) -join ' ') -match 'TwinCAT\.Standard\.XAR') $chg
    & $reset
    $t = (& $plan TwinCAT.StandardRM.XAE 4024.7.37).data.planToken
    $r = & $approve TwinCAT.StandardRM.XAE 4024.7.37 $t
    Check 'C30 RM installed but Build_4024.7 missing -> success with a warning' ($r.success -and $r.data.buildFolderExists -eq $false -and (@($r.data.warnings) -join ' ') -match 'Build_4024\.7 ') (@($r.data.warnings) -join ' | ')
    # executable: only %ProgramData%\Beckhoff\TcPkg\TcPkg.exe, Beckhoff Authenticode signature, fail closed
    & $reset; $global:Pkg229.defaultExe = $null
    $r = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    $g = Get-TcPackageInfo -NoAvailable
    Check 'C31 no TcPkg.exe at the default location -> TCPKG_NOT_FOUND for Install (PATH not used), Get-TcPackageInfo still uses PATH' (-not $r.success -and $r.error.code -eq 'TCPKG_NOT_FOUND' -and $null -eq $r.data.planToken -and $g.success) "$($r.error.code) / get=$($g.success)"
    & $reset; $global:Pkg229.sig = @{ ok = $false; status = 'NotSigned'; subject = $null; error = $null }
    $r = & $plan TwinCAT.StandardRM.XAE 4024.71.5
    Check 'C32 TcPkg.exe not signed by Beckhoff -> TCPKG_SIGNATURE_INVALID, no tcpkg call, no token' (-not $r.success -and $r.error.code -eq 'TCPKG_SIGNATURE_INVALID' -and $global:Pkg229.calls.Count -eq 0 -and $null -eq $r.data.planToken) "$($r.error.code)"
    & $reset; $t = (& $plan TwinCAT.StandardRM.XAE 4024.71.5).data.planToken
    $global:Pkg229.sigThrow = $true
    $r = & $approve TwinCAT.StandardRM.XAE 4024.71.5 $t
    Check 'C33 signature check unavailable at Approved -> TCPKG_SIGNATURE_INVALID (fail closed), no install' (-not $r.success -and $r.error.code -eq 'TCPKG_SIGNATURE_INVALID' -and $global:Pkg229.calls.Count -eq 0) "$($r.error.code)"
    $real = & $mod { param($sb, $p) & $sb -Path $p } $realSig $big
    Check 'C34 real Test-TcPkgSignature: an unsigned script is not ok' (-not $real.ok) "$($real.status)"
    $subj = & $mod { Test-TcPkgSignerSubject 'CN=Beckhoff Automation GmbH & Co. KG, O=Beckhoff Automation GmbH & Co. KG, L=Verl, S=Nordrhein-Westfalen, C=DE' }
    $fake = & $mod { Test-TcPkgSignerSubject 'CN=Evil, O=Beckhoff Automation GmbH & Co. KG Fake, C=XX' }
    Check 'C35 signer subject must have O=Beckhoff Automation GmbH & Co. KG exactly' ($subj -and -not $fake) "$subj/$fake"

    # --- D: PROGID_REQUIRED hint ---
    & $mod {
        function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $true }
        function script:Get-TcProgIdIdeInfo { [CmdletBinding()] param([string]$ProgId) [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = '3.1.4026.22'; xaeBuild = 4026 } }
    }
    function New-Sln229([string]$Name, [string]$TcVersion) {
        $dir = Join-Path $root $Name; New-Item -ItemType Directory -Path (Join-Path $dir 'P1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'P1\P1.tsproj') -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcVersion=`"$TcVersion`"><Project/></TcSmProject>" -Encoding UTF8
        $sln = Join-Path $dir "$Name.sln"
        Set-Content -LiteralPath $sln -Value @('Microsoft Visual Studio Solution File, Format Version 12.00', 'Project("{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}") = "P1", "P1\P1.tsproj", "{10112974-92E6-3C4B-560E-B30614E05491}"', 'EndProject') -Encoding UTF8
        $sln
    }
    $global:Pkg229.xaeBuilds = @('4024.59', '4026.22'); $global:Pkg229.calls.Clear()
    $sln = New-Sln229 'd1' '3.1.4024.71'
    $pick = & $mod { param($x) Resolve-TcLaunchProgId -SolutionPath $x } $sln
    Check 'D1 4024.71 project, Build_4024.71 missing -> PROGID_REQUIRED + remoteManagerInstall 4024.71' ($pick.errorCode -eq 'PROGID_REQUIRED' -and $pick.remoteManagerInstall.build -eq '4024.71' -and $pick.remoteManagerInstall.packageId -eq 'TwinCAT.StandardRM.XAE') ($pick.remoteManagerInstall | ConvertTo-Json -Compress)
    $r = Get-TcProjectVersion -SolutionPath $sln
    Check 'D2 Get-TcProjectVersion hint suggests Get-TcPackageInfo / Install-TcPackage for 4024.71, nothing run' ($r.success -and $r.data.launch.errorCode -eq 'PROGID_REQUIRED' -and $r.data.launch.hint -match 'Install-TcPackage -PackageId TwinCAT\.StandardRM\.XAE' -and $r.data.launch.hint -match 'Build_4024\.71' -and $r.data.launch.remoteManagerInstall.build -eq '4024.71' -and $global:Pkg229.calls.Count -eq 0) "$($r.data.launch.hint)"
    $hint = & $mod { param($p) Get-TcLaunchHint -Pick $p -Hint (Get-TcErrorHint -Code $p.errorCode) } $pick
    Check 'D3 Connect-TcIde hint = PROGID_REQUIRED hint + the install suggestion' ($hint.StartsWith((& $mod { Get-TcErrorHint -Code 'PROGID_REQUIRED' })) -and $hint -match 'Install-TcPackage') ''
    Check 'D4 Connect-TcIde passes the pick through Get-TcLaunchHint and returns remoteManagerInstall' ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Connect-TcIde.ps1')) -match 'Get-TcLaunchHint -Pick \$pick' -and (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Connect-TcIde.ps1')) -match 'remoteManagerInstall = \$pick\.remoteManagerInstall') ''
    $global:Pkg229.xaeBuilds = @('4024.71', '4026.22')
    $pick = & $mod { param($x) Resolve-TcLaunchProgId -SolutionPath $x } $sln
    Check 'D5 folder present -> remote-manager-match, no install suggestion' ($pick.selectedBy -eq 'remote-manager-match' -and $null -eq $pick.remoteManagerInstall) "$($pick.selectedBy)"
    $pick = & $mod { param($x) Resolve-TcLaunchProgId -SolutionPath $x } (New-Sln229 'd6' '3.1.4026.21')
    $hint = & $mod { param($p) Get-TcLaunchHint -Pick $p -Hint 'H' } $pick
    Check 'D6 4026 project without exact XAE -> PROGID_REQUIRED without install suggestion' ($pick.errorCode -eq 'PROGID_REQUIRED' -and $null -eq $pick.remoteManagerInstall -and $hint -eq 'H') "$($pick.errorCode) $hint"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Pkg229 -Scope Global -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
