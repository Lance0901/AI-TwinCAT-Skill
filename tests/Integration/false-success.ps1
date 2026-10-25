param(
    [string]$Repo = (Join-Path $PSScriptRoot '..\..'),
    [string]$Sln = 'C:\Temp\FalseSuccess-b\RobustSolutionFrameworkDemo.sln',
    [string]$ProgId = 'VisualStudio.DTE.17.0',
    [string]$NetId = '199.5.42.250.1.1',
    [string]$FwGuid = 'B7598CF7-8B30-4C49-8EFB-69ED4671CC91',
    [Parameter(Mandatory)][string]$LogPath,
    [int]$DeadlineMin = 45,
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45).
    [switch]$AllowUnresolvedLibrary
)
# Integration: "no false success" scenarios for #28 / #32 against a real runtime (local UmRT).
#   1. FrameworkUnitTest without Build.0 in the .sln -> Build-TcProject warning / -ExpectedProject failure
#   2. multi-PLC Enable-TcConfig -Force (851 + 852 Run, boot package compared, final readback)
#   3. nested / alias ADS reads on port 852 return scalars
#   4. Set-TcSystemState Run -> Run restart is observed (leftOriginal); a Run that falls back to Config
#      (a second process sends Reconfig 0.8 s after Run) returns SYSTEM_STATE_MISMATCH
# Needs a COPY of a solution with two PLC projects; the second one must be 'FrameworkUnitTest'
# (port 852) and -FwGuid its project GUID in the .sln. The script rewrites that .sln (Build.0 line) and
# the FrameworkUnitTest MAIN. Runs in ONE PowerShell process (one COM session), closes its IDE at the end.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Integration/false-success.ps1 `
#       -Repo <repo root> -Sln C:\Temp\FalseSuccess-b\RobustSolutionFrameworkDemo.sln -FwGuid <guid> -LogPath tests/Integration/logs/false-success.jsonl
$ErrorActionPreference = 'Continue'
Import-Module "$Repo\src\TwinCATAutomation\TwinCATAutomation.psm1" -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$deadline = (Get-Date).AddMinutes($DeadlineMin)
New-Item -ItemType Directory -Force -Path (Split-Path $LogPath) | Out-Null
Set-Content -Path $LogPath -Value '' -Encoding UTF8
$umrtBoot = 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Boot'
$buildLine = "`t`t{$FwGuid}.Release|TwinCAT OS (x64).Build.0 = Release|TwinCAT OS (x64)"
$actLine = "`t`t{$FwGuid}.Release|TwinCAT OS (x64).ActiveCfg = Release|TwinCAT OS (x64)"

function Log($step, $obj, [string]$expect, [bool]$pass) {
    $line = [ordered]@{ t = (Get-Date).ToString('HH:mm:ss'); step = $step; expect = $expect; pass = $pass; result = $obj } | ConvertTo-Json -Depth 8 -Compress
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
    $code = if ($obj -and $obj.PSObject.Properties['error'] -and $obj.error) { $obj.error.code } else { '' }
    "{0} {1} [{2}] expect: {3}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $step, $code, $expect
}
function Check-Deadline { if ((Get-Date) -gt $deadline) { throw "DEADLINE: scenario exceeded $DeadlineMin min" } }
function Ensure-UmRt {
    if (-not (Get-Process TcSystemServiceUm -ErrorAction SilentlyContinue)) {
        Start-Process "$env:TWINCAT3DIR\Runtimes\bin\TcSystemServiceUm.exe" -ArgumentList '-t bin -i path -n "UmRT_Default" -c .\3.1' -WorkingDirectory 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default'
        "UmRT was down -> restarted"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 30) { $s = Get-TcSystemState -AmsNetId $NetId; if ($s.success) { break }; Start-Sleep -Milliseconds 500 }
    }
}
function Set-FwBuild0([bool]$present) {
    $t = [IO.File]::ReadAllText($Sln)
    if (-not $t.Contains($actLine)) { throw "ActiveCfg line of $FwGuid not found in $Sln" }
    $has = $t.Contains($buildLine)
    if ($present -and -not $has) { $t = $t.Replace($actLine, "$actLine`r`n$buildLine") }
    elseif (-not $present -and $has) { $t = $t.Replace("$buildLine`r`n", '') }
    [IO.File]::WriteAllText($Sln, $t, (New-Object Text.UTF8Encoding($true)))
    "Build.0 of FrameworkUnitTest present=$present (was $has)"
}
function Open-Ide {
    $c = Connect-TcIde -ProgId $ProgId -SolutionPath $Sln
    Log 'connect' $c 'success' $c.success
    $t = Set-TcTarget -AmsNetId $NetId -Platform 'TwinCAT OS (x64)'
    Log 'set-target' $t 'success' $t.success
    return $c.success
}
function Close-Ide { $q = Disconnect-TcIde -Quit; if (-not $q.success) { $q = Disconnect-TcIde -Quit -Kill }; Log 'quit-ide' $q 'success' $q.success }
function Write-FwMain([string]$tag) {
    $decl = "PROGRAM MAIN`r`nVAR`r`n    nProbe : UDINT;`r`n    sTag : STRING(40) := '$tag';`r`n    sAlias : T_MaxString := 'alias-$tag';`r`n    stAddr : ST_AmsAddr;`r`n    bFlag : BOOL := TRUE;`r`nEND_VAR"
    $impl = "nProbe := nProbe + 1;`r`nstAddr.port := 852;"
    Write-TcPouCode -PouName MAIN -PouPath 'TIPC^FrameworkUnitTest^FrameworkUnitTest Project^POUs^MAIN' -Declaration $decl -Implementation $impl
}

try {
    Ensure-UmRt
    # ---------------- 1. FrameworkUnitTest without Build.0 (#28) ----------------
    Set-FwBuild0 $false
    if (Open-Ide) {
        Check-Deadline
        $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        $fw = @($b.data.projects | Where-Object { $_.name -eq 'FrameworkUnitTest' })[0]
        Log 'skip-build' $b 'success, coverageComplete=false, FrameworkUnitTest skipped, warningCode PROJECT_SKIPPED_BY_CONFIGURATION' ($b.data.coverageComplete -eq $false -and $fw.status -eq 'skipped' -and $b.data.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION')
        $b = Build-TcProject -ExpectedProject FrameworkUnitTest -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        Log 'skip-build-expected' $b 'success=false PROJECT_SKIPPED_BY_CONFIGURATION' ((-not $b.success) -and $b.error.code -eq 'PROJECT_SKIPPED_BY_CONFIGURATION')
        $b = Build-TcProject -ExpectedProject Untitled1 -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        Log 'skip-build-expected-other' $b 'success (Untitled1 built), coverageComplete=false' ($b.success -and $b.data.coverageComplete -eq $false)
        Close-Ide
    }
    Set-FwBuild0 $true
    Ensure-UmRt
    Check-Deadline

    # ---------------- 2. multi-PLC lifecycle with readback (#32) ----------------
    if (Open-Ide) {
        $w = Write-FwMain 'v3'
        Log 'v3-write' $w 'success' $w.success
        $b = Build-TcProject -ExpectedProject FrameworkUnitTest, Untitled1 -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        Log 'v3-build' $b 'success coverageComplete' ($b.success -and $b.data.coverageComplete)
        Check-Deadline
        $e = Enable-TcConfig -Force -TimeoutSec 240 -ActivateTimeoutSec 150
        Log 'enable-force' $e 'success, 851+852 Run, bootPackage match' ($e.success -and $e.data.finalCheck.ok -and $e.data.bootPackage.status -eq 'match')
        Check-Deadline

        # ---------------- 3. nested / alias ADS reads (#32 item 6) ----------------
        $a = Connect-TcAds -AmsNetId $NetId -Port 852
        Log 'ads-852' $a 'success' $a.success
        $r = Read-TcVariable -Path 'MAIN.sTag', 'MAIN.sAlias', 'MAIN.stAddr.port', 'MAIN.bFlag', 'TwinCAT_SystemInfoVarList._AppInfo.ProjectName', 'TwinCAT_SystemInfoVarList._AppInfo.AdsPort', 'TwinCAT_SystemInfoVarList._TaskInfo[1].FirstCycle'
        $vals = @($r.data.values)
        if ($vals.Count -eq 0) { $vals = @($r.data) }
        $scalar = @($vals | Where-Object { $_.value -is [array] }).Count -eq 0
        Log 'nested-read' $r 'every value scalar (no byte array)' ($r.success -and $scalar)
        $d = Disconnect-TcAds

        $s = Set-TcSystemState -State Run -AmsNetId $NetId
        Log 'run-to-run' $s 'success, leftOriginal, originalState Run, finalState Run, latencyMs' ($s.success -and $s.data.leftOriginal -and $s.data.originalState -eq 'Run' -and $s.data.finalState -eq 'Run' -and $s.data.latencyMs -gt 0)
        Ensure-UmRt
        # ---------------- 4. simulated fall-back: Run reached, then Config (#32 item 1) ----------------
        $s = Set-TcSystemState -State Config -AmsNetId $NetId
        Log 'sim-config' $s 'success' $s.success
        Ensure-UmRt
        $job = Start-Job -ScriptBlock {
            param($dll, $netId)
            Add-Type -Path $dll
            $sw = [Diagnostics.Stopwatch]::StartNew(); $sent = $false
            while ($sw.Elapsed.TotalSeconds -lt 60 -and -not $sent) {
                try {
                    $c = New-Object TwinCAT.Ads.TcAdsClient; $c.Connect($netId, 10000)
                    if ($c.ReadState().AdsState.ToString() -eq 'Run') {
                        Start-Sleep -Milliseconds 800
                        $si = New-Object TwinCAT.Ads.StateInfo; $si.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 16); $si.DeviceState = 0
                        $c.WriteControl($si); $sent = $true; "Reconfig sent at $([int]$sw.ElapsedMilliseconds) ms"
                    }
                    $c.Dispose()
                } catch { }
                Start-Sleep -Milliseconds 100
            }
        } -ArgumentList (& $mod { $script:TcAdsAssemblyPath }), $NetId
        Start-Sleep -Seconds 2
        $s = Set-TcSystemState -State Run -AmsNetId $NetId -TimeoutSec 60
        $jobOut = Receive-Job $job -Wait -AutoRemoveJob
        "  job: $jobOut"
        Log 'sim-fallback-run' $s 'success=false SYSTEM_STATE_MISMATCH' ((-not $s.success) -and $s.error.code -eq 'SYSTEM_STATE_MISMATCH')
        Ensure-UmRt
        Check-Deadline
        $e = Enable-TcConfig -Force -TimeoutSec 240 -ActivateTimeoutSec 150
        Log 'restore-enable-force' $e 'success' $e.success
        Close-Ide
    }
}
catch {
    Log 'EXCEPTION' ([PSCustomObject]@{ message = $_.Exception.Message; at = $_.InvocationInfo.PositionMessage }) 'none' $false
    try { Close-Ide } catch { }
}
finally {
    try { Set-FwBuild0 $true } catch { "restore Build.0 failed: $($_.Exception.Message)" }
    "done"
}
