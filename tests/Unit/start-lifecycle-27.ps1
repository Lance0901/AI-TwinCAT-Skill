. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #27 Start-TcLifecycle (PowerShell counterpart of the MCP composite RunLifecycle).
# Step order, SetTarget branches, parameter pass-through, ADS port decision (PLC_PORT_MISMATCH,
# port of the one selected PLC), GetPlcState readback (RUNTIME_STATE_MISMATCH, -NoLogin), fail
# closed (no later step after a failure, the step's error as it is, LIFECYCLE_BLOCKED with
# data.lifecycleBlock).
# No IDE / ADS / runtime: Connect-TcIde, Set-TcTarget, Build-TcProject, Enable-TcConfig,
# Connect-TcAds and Get-TcPlcState are replaced in module scope by mocks that record their
# parameters and return the result set per case.
#   powershell.exe -NoProfile -File tests/Unit/start-lifecycle-27.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 8 -Compress }

& $mod {
    $script:SlCalls = [System.Collections.Generic.List[object]]::new()
    $script:SlMock = @{}
    function script:Invoke-SlMock([string]$Name, [hashtable]$Bound) {
        $copy = @{}
        foreach ($k in $Bound.Keys) { $copy[$k] = $Bound[$k] }
        $script:SlCalls.Add([PSCustomObject]@{ name = $Name; params = $copy })
        $m = $script:SlMock[$Name]
        if ($m -is [scriptblock]) { return (& $m $copy) }
        $m
    }
    function script:Connect-TcIde { param([string]$ProgId, [string]$SolutionPath, [switch]$NoLaunch) Invoke-SlMock 'Connect-TcIde' $PSBoundParameters }
    function script:Set-TcTarget { param([string]$AmsNetId, [string]$Platform, [switch]$NoPlatformSwitch) Invoke-SlMock 'Set-TcTarget' $PSBoundParameters }
    function script:Build-TcProject { param([int]$TimeoutSec, [string[]]$ExpectedProject) Invoke-SlMock 'Build-TcProject' $PSBoundParameters }
    function script:Enable-TcConfig { param([switch]$Force, [switch]$NoLogin, [int]$TimeoutSec, [string]$Platform, [string[]]$PlcProjectPath) Invoke-SlMock 'Enable-TcConfig' $PSBoundParameters }
    function script:Connect-TcAds { param([string]$AmsNetId, [int]$Port) Invoke-SlMock 'Connect-TcAds' $PSBoundParameters }
    function script:Get-TcPlcState { param() Invoke-SlMock 'Get-TcPlcState' $PSBoundParameters }
}

function Ok($data) { [PSCustomObject]@{ success = $true; data = $data } }
function Err([string]$Code, [string]$Message, $Data) {
    $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ message = $Message; code = $Code; hint = "hint of $Code" } }
    if ($null -ne $Data) { $r | Add-Member -NotePropertyName data -NotePropertyValue $Data }
    $r
}
function Plc([string]$Name, [int]$Port) { [PSCustomObject]@{ name = $Name; projectPath = "TIPC^$Name^$Name Project"; adsPort = $Port; loggedIn = $true; state = 'Run' } }

# Default: every step succeeds; one PLC on 851; Connect-TcAds echoes the port; PLC in Run.
function Reset-Case {
    & $mod {
        $script:SlCalls.Clear()
        $script:SlMock = @{
            'Connect-TcIde'   = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 4242; amsNetId = '5.1.2.3.1.1' } }
            'Set-TcTarget'    = { param($p) [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ amsNetId = $p.AmsNetId } } }
            'Build-TcProject' = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ completeBuild = $true } }
            'Enable-TcConfig' = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ loggedIn = $true; plcState = 'Run'; plcs = @([PSCustomObject]@{ name = 'PLC1'; projectPath = 'TIPC^PLC1^PLC1 Project'; adsPort = 851; loggedIn = $true; state = 'Run' }) } }
            'Connect-TcAds'   = { param($p) $port = if ($p.ContainsKey('Port')) { $p.Port } else { 851 }; [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ amsNetId = '5.1.2.3.1.1'; port = $port } } }
            'Get-TcPlcState'  = [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ state = 'Run'; adsState = 5 } }
        }
    }
}
function Set-Mock([string]$Name, $Value) { & $mod { param($n, $v) $script:SlMock[$n] = $v } $Name $Value }
function Get-Calls { & $mod { @($script:SlCalls) } }
function Get-Call([string]$Name) { @(Get-Calls | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }
function Names($r) { (@($r.data.steps | ForEach-Object { $_.name }) -join ',') }

# --- 1. all success, no target / platform -----------------------------------------------------
Reset-Case
$r = Start-TcLifecycle
Check 'all-success: success' ($r.success -eq $true) (J $r.error)
Check 'all-success: steps' ((Names $r) -eq 'ConnectIde,BuildProject,EnableConfig,ConnectAds,GetPlcState') (Names $r)
Check 'all-success: every step success, code null, durationMs int' (@($r.data.steps | Where-Object { -not $_.success -or $null -ne $_.code -or $_.durationMs -isnot [int] }).Count -eq 0) (J $r.data.steps)
Check 'all-success: failedStep null' ($null -eq $r.data.failedStep) "$($r.data.failedStep)"
Check 'all-success: plcState Run, adsPort 851, loggedIn true' ($r.data.plcState -eq 'Run' -and $r.data.adsPort -eq 851 -and $r.data.loggedIn -eq $true) (J $r.data)
Check 'all-success: plcProjects = Enable data.plcs' (@($r.data.plcProjects).Count -eq 1 -and @($r.data.plcProjects)[0].name -eq 'PLC1') (J $r.data.plcProjects)
Check 'all-success: lifecycleBlock null, no error' ($null -eq $r.data.lifecycleBlock -and $null -eq $r.PSObject.Properties['error']) (J $r)
$e = Get-Call 'Enable-TcConfig'
Check 'all-success: Enable-TcConfig -Force -TimeoutSec 120, nothing else' ($e.params.Force -eq $true -and $e.params.TimeoutSec -eq 120 -and $e.params.Count -eq 2) (J $e.params)
$a = Get-Call 'Connect-TcAds'
Check 'all-success: Connect-TcAds -Port 851 (the one PLC port)' ($a.params.Port -eq 851) (J $a.params)
$b = Get-Call 'Build-TcProject'
Check 'all-success: Build-TcProject without parameters' ($b.params.Count -eq 0) (J $b.params)
Check 'all-success: result raw (step result = mock object)' ($r.data.steps[1].result.data.completeBuild -eq $true) (J $r.data.steps[1])
$jsonOk = $true; try { $null = $r | ConvertTo-Json -Depth 20 } catch { $jsonOk = $false }
Check 'all-success: result serializes to JSON' $jsonOk ''

# --- 2. SetTarget branches --------------------------------------------------------------------
Reset-Case
$r = Start-TcLifecycle -TargetAmsNetId '5.9.9.9.1.1' -Platform 'TwinCAT OS (x64)' -SolutionPath 'C:\x\a.sln' -ProgId 'X.DTE' -NoLaunch
$s = Get-Call 'Set-TcTarget'; $c = Get-Call 'Connect-TcIde'; $e = Get-Call 'Enable-TcConfig'
Check 'platform+netid: steps' ((Names $r) -eq 'ConnectIde,SetTarget,BuildProject,EnableConfig,ConnectAds,GetPlcState') (Names $r)
Check 'platform+netid: Set-TcTarget AmsNetId + Platform, no NoPlatformSwitch' ($s.params.AmsNetId -eq '5.9.9.9.1.1' -and $s.params.Platform -eq 'TwinCAT OS (x64)' -and -not $s.params.ContainsKey('NoPlatformSwitch')) (J $s.params)
Check 'platform+netid: Enable-TcConfig gets the same Platform' ($e.params.Platform -eq 'TwinCAT OS (x64)') (J $e.params)
Check 'platform+netid: Connect-TcIde gets SolutionPath / ProgId / NoLaunch' ($c.params.SolutionPath -eq 'C:\x\a.sln' -and $c.params.ProgId -eq 'X.DTE' -and $c.params.NoLaunch -eq $true) (J $c.params)

Reset-Case
$r = Start-TcLifecycle -TargetAmsNetId '5.9.9.9.1.1'
$s = Get-Call 'Set-TcTarget'; $e = Get-Call 'Enable-TcConfig'
Check 'netid only: Set-TcTarget -NoPlatformSwitch, no Platform' ($s.params.NoPlatformSwitch -eq $true -and -not $s.params.ContainsKey('Platform')) (J $s.params)
Check 'netid only: Enable-TcConfig without Platform' (-not $e.params.ContainsKey('Platform')) (J $e.params)

Reset-Case
$r = Start-TcLifecycle -Platform 'TwinCAT OS (x64)'
$s = Get-Call 'Set-TcTarget'
Check 'platform only: AmsNetId from Connect-TcIde data.amsNetId' ($r.success -and $s.params.AmsNetId -eq '5.1.2.3.1.1' -and $s.params.Platform -eq 'TwinCAT OS (x64)') (J $s.params)

# #307: data.targetKind / targetKindSource: SetTarget wins when it ran, else ConnectIde; null when neither reports it
Reset-Case
Set-Mock 'Connect-TcIde' (Ok ([PSCustomObject]@{ ideProcessId = 4242; amsNetId = '5.1.2.3.1.1'; targetKind = 'remote'; targetKindSource = 'no-local-match' }))
$r = Start-TcLifecycle
Check 'targetKind from Connect-TcIde (no SetTarget)' ($r.success -and $r.data.targetKind -eq 'remote' -and $r.data.targetKindSource -eq 'no-local-match') (J $r.data)
Reset-Case
Set-Mock 'Connect-TcIde' (Ok ([PSCustomObject]@{ ideProcessId = 4242; amsNetId = '5.1.2.3.1.1'; targetKind = 'remote'; targetKindSource = 'no-local-match' }))
Set-Mock 'Set-TcTarget' { param($p) [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ amsNetId = $p.AmsNetId; targetKind = 'local-umrt'; targetKindSource = 'TcRegistry.xml:UmRT_Default' } } }
$r = Start-TcLifecycle -TargetAmsNetId '199.5.42.250.1.1'
Check 'targetKind from Set-TcTarget when it ran' ($r.success -and $r.data.targetKind -eq 'local-umrt' -and $r.data.targetKindSource -eq 'TcRegistry.xml:UmRT_Default') (J $r.data)
Reset-Case
$r = Start-TcLifecycle
Check 'targetKind null when no step reports it' ($r.success -and $null -eq $r.data.targetKind -and $null -eq $r.data.targetKindSource -and ($r.data.PSObject.Properties.Name -contains 'targetKind')) (J $r.data)

Reset-Case
Set-Mock 'Connect-TcIde' (Ok ([PSCustomObject]@{ ideProcessId = 4242 }))
$r = Start-TcLifecycle -Platform 'TwinCAT OS (x64)'
Check 'platform, no netid anywhere: AMS_NETID_REQUIRED at SetTarget' ($r.success -eq $false -and $r.error.code -eq 'AMS_NETID_REQUIRED' -and $r.data.failedStep -eq 'SetTarget') (J $r)
Check 'platform, no netid anywhere: steps ConnectIde,SetTarget; Set-TcTarget / Build not called' ((Names $r) -eq 'ConnectIde,SetTarget' -and $null -eq (Get-Call 'Set-TcTarget') -and $null -eq (Get-Call 'Build-TcProject')) (Names $r)
Check 'platform, no netid anywhere: step code AMS_NETID_REQUIRED, hint set' ($r.data.steps[1].code -eq 'AMS_NETID_REQUIRED' -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r.data.steps[1])

Reset-Case
$r = Start-TcLifecycle -TargetAmsNetId ''
Check 'no target, no platform: no SetTarget step' ((Names $r) -eq 'ConnectIde,BuildProject,EnableConfig,ConnectAds,GetPlcState' -and $null -eq (Get-Call 'Set-TcTarget')) (Names $r)

# --- 3. Build failure stops before Enable-TcConfig; build parameters ------------------------
Reset-Case
$bf = Err 'BUILD_FAILED' 'mock build failed' ([PSCustomObject]@{ errorItems = @('e1') })
Set-Mock 'Build-TcProject' $bf
$r = Start-TcLifecycle -ExpectedProject 'FrameworkUnitTest' -BuildTimeoutSec 900
$b = Get-Call 'Build-TcProject'
Check 'build fail: failedStep BuildProject' ($r.success -eq $false -and $r.data.failedStep -eq 'BuildProject') (J $r.data.failedStep)
Check 'build fail: error is the step error as it is' ([object]::ReferenceEquals($r.error, $bf.error)) (J $r.error)
Check 'build fail: Enable-TcConfig / Connect-TcAds not called' ($null -eq (Get-Call 'Enable-TcConfig') -and $null -eq (Get-Call 'Connect-TcAds')) (J (Get-Calls))
Check 'build fail: step code BUILD_FAILED, later data null' ($r.data.steps[-1].code -eq 'BUILD_FAILED' -and $null -eq $r.data.plcProjects -and $null -eq $r.data.adsPort -and $null -eq $r.data.plcState -and $null -eq $r.data.loggedIn) (J $r.data)
Check 'build: -ExpectedProject and -BuildTimeoutSec passed on' (@($b.params.ExpectedProject) -join ',' -eq 'FrameworkUnitTest' -and $b.params.TimeoutSec -eq 900) (J $b.params)

Reset-Case
$r = Start-TcLifecycle -SkipBuild
Check 'SkipBuild: no BuildProject step' ((Names $r) -eq 'ConnectIde,EnableConfig,ConnectAds,GetPlcState' -and $null -eq (Get-Call 'Build-TcProject')) (Names $r)

# --- 4. LIFECYCLE_BLOCKED from Enable-TcConfig ------------------------------------------------
Reset-Case
$block = [PSCustomObject]@{ amsNetId = '5.1.2.3.1.1'; command = 'Set-TcSystemState'; errorCode = 'SYSTEM_STATE_TIMEOUT' }
$lb = Err 'LIFECYCLE_BLOCKED' 'mock blocked' ([PSCustomObject]@{ lifecycleBlock = $block; activated = $false })
Set-Mock 'Enable-TcConfig' $lb
$r = Start-TcLifecycle -TimeoutSec 300 -NoLogin -PlcProjectPath 'FrameworkUnitTest'
$e = Get-Call 'Enable-TcConfig'
Check 'blocked: LIFECYCLE_BLOCKED as it is' ($r.success -eq $false -and [object]::ReferenceEquals($r.error, $lb.error) -and $r.error.hint -eq 'hint of LIFECYCLE_BLOCKED') (J $r.error)
Check 'blocked: data.lifecycleBlock = step data.lifecycleBlock' ([object]::ReferenceEquals($r.data.lifecycleBlock, $block)) (J $r.data.lifecycleBlock)
Check 'blocked: failedStep EnableConfig, Connect-TcAds not called' ($r.data.failedStep -eq 'EnableConfig' -and $null -eq (Get-Call 'Connect-TcAds')) (J $r.data.failedStep)
Check 'blocked: Enable-TcConfig got -TimeoutSec 300 -NoLogin -PlcProjectPath' ($e.params.TimeoutSec -eq 300 -and $e.params.NoLogin -eq $true -and (@($e.params.PlcProjectPath) -join ',') -eq 'FrameworkUnitTest' -and $e.params.Force -eq $true) (J $e.params)

# --- 4b. #287: SYSTEM_EXCEPTION from the set-plc-run step of Enable-TcConfig passes through as it is
Reset-Case
$block287 = [PSCustomObject]@{ amsNetId = '5.1.2.3.1.1'; command = 'Enable-TcConfig'; errorCode = 'SYSTEM_EXCEPTION' }
$se = Err 'SYSTEM_EXCEPTION' 'mock system exception' ([PSCustomObject]@{ lifecycleBlock = $block287; systemState = 'Exception'; adsState = 19 })
Set-Mock 'Enable-TcConfig' $se
$r = Start-TcLifecycle
Check '#287 SYSTEM_EXCEPTION: code / hint as they are, failedStep EnableConfig, lifecycleBlock, no later step' ($r.success -eq $false -and $r.error.code -eq 'SYSTEM_EXCEPTION' -and $r.error.hint -eq 'hint of SYSTEM_EXCEPTION' -and $r.data.failedStep -eq 'EnableConfig' -and [object]::ReferenceEquals($r.data.lifecycleBlock, $block287) -and $null -eq (Get-Call 'Connect-TcAds') -and $null -eq (Get-Call 'Get-TcPlcState')) (J $r)

# --- 5. ADS port decision ---------------------------------------------------------------------
Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'FrameworkUnitTest' -AdsPort 851
$sd = $r.data.steps[-1].result.data
Check 'port mismatch: PLC_PORT_MISMATCH at ConnectAds' ($r.success -eq $false -and $r.error.code -eq 'PLC_PORT_MISMATCH' -and $r.data.failedStep -eq 'ConnectAds') (J $r)
Check 'port mismatch: Connect-TcAds not called, adsPort null' ($null -eq (Get-Call 'Connect-TcAds') -and $null -eq $r.data.adsPort) (J (Get-Calls))
Check 'port mismatch: message names the port, the allowed ports and the PLC' ($r.error.message -match 'AdsPort 851' -and $r.error.message -match 'allowed: 852' -and $r.error.message -match 'FrameworkUnitTest:852') $r.error.message
Check 'port mismatch: hint = module hint, step data adsPort / allowedPorts / plcs' ($r.error.hint -eq (& $mod { Get-TcErrorHint -Code 'PLC_PORT_MISMATCH' }) -and $sd.adsPort -eq 851 -and (@($sd.allowedPorts) -join ',') -eq '852' -and @($sd.plcs)[0].name -eq 'FrameworkUnitTest') (J $sd)
Check 'port mismatch: plcProjects / loggedIn reported' (@($r.data.plcProjects).Count -eq 1 -and $r.data.loggedIn -eq $true) (J $r.data)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'FrameworkUnitTest'
$a = Get-Call 'Connect-TcAds'
Check 'port auto: Connect-TcAds -Port 852 from the one selected PLC' ($r.success -and $a.params.Port -eq 852 -and $r.data.adsPort -eq 852) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle
$a = Get-Call 'Connect-TcAds'
Check 'port auto without PlcProjectPath: plcs=[FrameworkUnitTest:852] -> -Port 852' ($r.success -and $a.params.Port -eq 852 -and $r.data.adsPort -eq 852) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852), (Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'FrameworkUnitTest', 'FrameworkUnitTest'
$a = Get-Call 'Connect-TcAds'
Check 'same PLC twice in PlcProjectPath: one port, -Port 852' ($r.success -and $a.params.Port -eq 852) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852), (Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'FrameworkUnitTest', 'FrameworkUnitTest' -AdsPort 851
Check 'same PLC twice + wrong AdsPort: PLC_PORT_MISMATCH, allowed 852 once' ($r.error.code -eq 'PLC_PORT_MISMATCH' -and (@($r.data.steps[-1].result.data.allowedPorts) -join ',') -eq '852') (J $r.error)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'FrameworkUnitTest' -AdsPort 852
$a = Get-Call 'Connect-TcAds'
Check 'port given = PLC port: connects with it' ($r.success -and $a.params.Port -eq 852) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'PLC1' 851), (Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle
$a = Get-Call 'Connect-TcAds'
Check 'several ports, no PlcProjectPath: no -Port (default 851)' ($r.success -and $a.params.Count -eq 0 -and $r.data.adsPort -eq 851) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'PLC1' 851), (Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'PLC1', 'FrameworkUnitTest' -AdsPort 853
Check 'two selected PLCs + AdsPort 853: PLC_PORT_MISMATCH, allowed 851, 852' ($r.error.code -eq 'PLC_PORT_MISMATCH' -and $r.error.message -match 'allowed: 851, 852' -and $null -eq (Get-Call 'Connect-TcAds')) (J $r.error)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'PLC1' 851), (Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -PlcProjectPath 'PLC1', 'FrameworkUnitTest' -AdsPort 852
$a = Get-Call 'Connect-TcAds'
Check 'two selected PLCs + AdsPort 852 (one of them): -Port 852' ($r.success -and $a.params.Port -eq 852) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle -AdsPort 851
$a = Get-Call 'Connect-TcAds'
Check 'AdsPort without PlcProjectPath: no mismatch check' ($r.success -and $a.params.Port -eq 851) (J $a.params)

Reset-Case
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $true; plcs = $null }))
$r = Start-TcLifecycle
Check 'Enable data.plcs null: plcProjects null (not @($null)), no -Port' ($r.success -and $null -eq $r.data.plcProjects -and (Get-Call 'Connect-TcAds').params.Count -eq 0) (J $r.data.plcProjects)

Reset-Case
Set-Mock 'Enable-TcConfig' (Err 'RUNTIME_STATE_MISMATCH' 'mock verify' ([PSCustomObject]@{ loggedIn = $true; plcs = @((Plc 'FrameworkUnitTest' 852)) }))
$r = Start-TcLifecycle
Check 'Enable ordinary failure: its error, plcProjects / loggedIn still reported' ($r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $r.data.failedStep -eq 'EnableConfig' -and @($r.data.plcProjects).Count -eq 1 -and $r.data.loggedIn -eq $true -and $null -eq $r.data.lifecycleBlock -and $null -eq (Get-Call 'Connect-TcAds')) (J $r.data)

Reset-Case
Set-Mock 'Connect-TcAds' (Err 'ADS_PORT_NOT_FOUND' 'mock no port' $null)
$r = Start-TcLifecycle
Check 'ConnectAds failure: stops, GetPlcState not called' ($r.error.code -eq 'ADS_PORT_NOT_FOUND' -and $r.data.failedStep -eq 'ConnectAds' -and $null -eq (Get-Call 'Get-TcPlcState')) (J $r)

# --- 6. readback ------------------------------------------------------------------------------
Reset-Case
Set-Mock 'Get-TcPlcState' (Ok ([PSCustomObject]@{ state = 'Stop'; adsState = 6 }))
$r = Start-TcLifecycle
Check 'readback Stop: RUNTIME_STATE_MISMATCH at GetPlcState' ($r.success -eq $false -and $r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $r.data.failedStep -eq 'GetPlcState') (J $r)
Check 'readback Stop: step failed with code, result is the raw Get-TcPlcState result' ($r.data.steps[-1].success -eq $false -and $r.data.steps[-1].code -eq 'RUNTIME_STATE_MISMATCH' -and $r.data.steps[-1].result.success -eq $true) (J $r.data.steps[-1])
Check 'readback Stop: plcState Stop, message names the state' ($r.data.plcState -eq 'Stop' -and $r.error.message -match "'Stop'") $r.error.message

Reset-Case
Set-Mock 'Get-TcPlcState' (Ok ([PSCustomObject]@{ state = 'Stop'; adsState = 6 }))
Set-Mock 'Enable-TcConfig' (Ok ([PSCustomObject]@{ loggedIn = $false; plcs = @((Plc 'PLC1' 851)) }))
$r = Start-TcLifecycle -NoLogin
Check 'NoLogin: Stop is only reported (success)' ($r.success -eq $true -and $r.data.plcState -eq 'Stop' -and $r.data.loggedIn -eq $false) (J $r)
Check 'NoLogin: Enable-TcConfig -NoLogin' ((Get-Call 'Enable-TcConfig').params.NoLogin -eq $true) ''

Reset-Case
Set-Mock 'Get-TcPlcState' (Err 'NOT_CONNECTED' 'mock' $null)
$r = Start-TcLifecycle
Check 'GetPlcState failure: its error' ($r.error.code -eq 'NOT_CONNECTED' -and $r.data.failedStep -eq 'GetPlcState' -and $null -eq $r.data.plcState) (J $r)

# --- 7. a throwing step / no result -----------------------------------------------------------
Reset-Case
Set-Mock 'Connect-TcIde' { param($p) throw 'boom' }
$r = Start-TcLifecycle
Check 'throw: INTERNAL_ERROR at ConnectIde, nothing else called' ($r.error.code -eq 'INTERNAL_ERROR' -and $r.data.failedStep -eq 'ConnectIde' -and @(Get-Calls).Count -eq 1) (J $r)

Reset-Case
Set-Mock 'Build-TcProject' $null
$r = Start-TcLifecycle
Check 'no result: INTERNAL_ERROR at BuildProject' ($r.error.code -eq 'INTERNAL_ERROR' -and $r.data.failedStep -eq 'BuildProject') (J $r)

Reset-Case
Set-Mock 'Set-TcTarget' (Err 'TARGET_NOT_FOUND' 'mock target' $null)
$r = Start-TcLifecycle -TargetAmsNetId '5.9.9.9.1.1'
Check 'SetTarget failure: stops before BuildProject' ($r.error.code -eq 'TARGET_NOT_FOUND' -and $r.data.failedStep -eq 'SetTarget' -and $null -eq (Get-Call 'Build-TcProject')) (J $r)

# --- 8. parameter validation ------------------------------------------------------------------
foreach ($bad in @(@{ AdsPort = 0 }, @{ AdsPort = 65536 }, @{ BuildTimeoutSec = 4 }, @{ BuildTimeoutSec = 7201 }, @{ TimeoutSec = 9 }, @{ TimeoutSec = 3601 })) {
    Reset-Case
    $threw = $false
    try { $null = Start-TcLifecycle @bad } catch { $threw = $true }
    Check "validation: $(J $bad) refused before any step" ($threw -and @(Get-Calls).Count -eq 0) ''
}

# --- 9. export / CLI action / MCP exclusion -----------------------------------------------------
Check 'exported by the module' ($null -ne (Get-Command Start-TcLifecycle -Module TwinCATAutomation -ErrorAction SilentlyContinue)) ''
$cli = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\Invoke-TwinCATAutomation.ps1'))
Check 'CLI action StartLifecycle -> Start-TcLifecycle' ($cli -match "'StartLifecycle'\s*=\s*'Start-TcLifecycle'") ''
$exp = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\..\mcp-server\scripts\Export-ToolSchema.ps1'))
Check 'not a catalog tool (served by the composite RunLifecycle)' ($exp -match "\`$excludedTools = @\([^)]*'StartLifecycle'") ''

"failed: $fail"
exit $fail
