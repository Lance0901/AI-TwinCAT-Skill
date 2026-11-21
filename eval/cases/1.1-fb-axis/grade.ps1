<#
.SYNOPSIS
    Acceptance tests 1-7 of eval case 1.1 (FB_Axis) against the PLC on the local UmRT, over ADS.
.DESCRIPTION
    Uses only the PowerShell module cmdlets Connect-TcAds / Write-TcVariable / Read-TcVariable of this
    checkout: no MCP server, no AI, no IDE. The PLC must already run the program the AI left behind;
    this script never builds, activates or changes the runtime state.

    Interface under test: MAIN.fbAxis (FB_Axis) with inputs bEnable, bReset, bHome, fHomePosition,
    bMoveAbs, fPosition, fVelocity, bMoveVelo, fVeloSet, bStop and outputs bReady, bHomed, bBusy, bDone,
    bError, nErrorId, fActPos, fActVelo (eval-cases-v0.md, 1.1). Edge inputs are pulsed TRUE for
    PulseMs and then written FALSE.

    Writes <OutFile> (JSON): {case, startedAt, finishedAt, amsNetId, precondition, tests:[{id, name,
    pass, detail, observed, elapsedMs}], passed, total}. Exit code 0 = script ran (even with failed
    tests), 2 = could not run (no ADS / interface missing).
.PARAMETER AmsNetId
    Target; default: AmsNetId of the local UmRT_Default (TcRegistry.xml).
.PARAMETER Port
    PLC ADS port (default 851).
.PARAMETER Instance
    Symbol of the FB instance (default MAIN.fbAxis).
.PARAMETER OutFile
    Result JSON path (default grade.json in the current directory).
.PARAMETER PulseMs
    Width of an edge pulse in ms (default 200; the PLC task of the fixture runs far faster).
#>
[CmdletBinding()]
param(
    [string]$AmsNetId,
    [int]$Port = 851,
    [string]$Instance = 'MAIN.fbAxis',
    [string]$OutFile = (Join-Path (Get-Location) 'grade.json'),
    [int]$PulseMs = 200
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $repo 'eval\lib\EvalCommon.ps1')
Import-Module (Join-Path $repo 'src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -DisableNameChecking

if (-not $AmsNetId) { $AmsNetId = Get-EvalUmRtAmsNetId }

$result = [ordered]@{
    case         = '1.1-fb-axis'
    startedAt    = (Get-Date).ToString('o')
    finishedAt   = $null
    amsNetId     = $AmsNetId
    port         = $Port
    instance     = $Instance
    precondition = $null
    tests        = @()
    passed       = 0
    total        = 7
}

function ConvertTo-EvalObject($r) { if ($r -is [string]) { return ($r | ConvertFrom-Json) } return $r }

function Read-Fb {
    param([string[]]$Names)
    $paths = @($Names | ForEach-Object { "$Instance.$_" })
    $r = ConvertTo-EvalObject (Read-TcVariable -Path $paths)
    $vals = @{}
    $entries = @($r.data)
    for ($i = 0; $i -lt $Names.Count; $i++) {
        $e = $entries[$i]
        if ($null -ne $e -and $null -eq $e.error) { $vals[$Names[$i]] = $e.value } else { $vals[$Names[$i]] = $null }
    }
    return $vals
}

function Write-Fb {
    param([string]$Name, $Value)
    $r = ConvertTo-EvalObject (Write-TcVariable -Path "$Instance.$Name" -Value $Value)
    if (-not $r.success) { throw "write $Instance.$Name failed: $($r.error.code) $($r.error.message)" }
}

function Send-Pulse {
    param([string]$Name)
    Write-Fb $Name $false
    Start-Sleep -Milliseconds 50
    Write-Fb $Name $true
    Start-Sleep -Milliseconds $PulseMs
    Write-Fb $Name $false
}

# Polls until $Condition (scriptblock over the value table) is true or TimeoutMs passed.
function Wait-Fb {
    param([string[]]$Names, [scriptblock]$Condition, [int]$TimeoutMs, [int]$PollMs = 50)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $v = $null
    do {
        $v = Read-Fb $Names
        if (& $Condition $v) { return [pscustomobject]@{ ok = $true; values = $v; elapsedMs = $sw.ElapsedMilliseconds } }
        Start-Sleep -Milliseconds $PollMs
    } while ($sw.ElapsedMilliseconds -lt $TimeoutMs)
    return [pscustomobject]@{ ok = $false; values = $v; elapsedMs = $sw.ElapsedMilliseconds }
}

function Add-Test {
    param([int]$Id, [string]$Name, [bool]$Pass, [string]$Detail, $Observed, $ElapsedMs)
    $script:result.tests += [ordered]@{ id = $Id; name = $Name; pass = $Pass; detail = $Detail; observed = $Observed; elapsedMs = $ElapsedMs }
    if ($Pass) { $script:result.passed++ }
}

function Save-Result {
    $script:result.finishedAt = (Get-Date).ToString('o')
    Write-EvalJson -InputObject $script:result -Path $OutFile
}

$outs = @('bReady', 'bHomed', 'bBusy', 'bDone', 'bError', 'nErrorId', 'fActPos', 'fActVelo')
$ins = @('bEnable', 'bReset', 'bHome', 'fHomePosition', 'bMoveAbs', 'fPosition', 'fVelocity', 'bMoveVelo', 'fVeloSet', 'bStop')

# --- precondition: ADS reachable, PLC Run, every interface symbol present ---------------------------
try {
    $c = ConvertTo-EvalObject (Connect-TcAds -AmsNetId $AmsNetId -Port $Port)
    if (-not $c.success) { throw "Connect-TcAds: $($c.error.code) $($c.error.message)" }
    $missing = @()
    foreach ($n in ($ins + $outs)) {
        $r = ConvertTo-EvalObject (Read-TcVariable -Path @("$Instance.$n"))
        if (-not $r.success) { $missing += $n }
    }
    $result.precondition = [ordered]@{ ok = ($missing.Count -eq 0); plcState = [string]$c.data.state; missingSymbols = $missing }
    if ($missing.Count -gt 0) { throw "interface symbols missing: $($missing -join ', ')" }
} catch {
    if ($null -eq $result.precondition) { $result.precondition = [ordered]@{ ok = $false } }
    $result.precondition.error = $_.Exception.Message
    for ($i = 1; $i -le 7; $i++) { Add-Test $i "test $i" $false "not run: precondition failed ($($_.Exception.Message))" $null $null }
    Save-Result
    exit 2
}

$tests = @(
    @{ id = 1; name = 'bEnable -> bReady within 1 s' },
    @{ id = 2; name = 'bHome -> bHomed, fActPos = fHomePosition (0) +-0.001' },
    @{ id = 3; name = 'bMoveAbs 100 @ 50 -> bDone, fActPos 100 +-0.01, no bError' },
    @{ id = 4; name = 'bMoveVelo 30 -> fActVelo 30 +-0.5 within 1 s' },
    @{ id = 5; name = 'bStop while moving -> fActVelo 0' },
    @{ id = 6; name = 'bMoveAbs while moving -> new target taken over' },
    @{ id = 7; name = 'fVelocity 5000 (> max 1000) -> bError, nErrorId <> 0; bReset clears bError' }
)

function Invoke-Step {
    param([hashtable]$T, [scriptblock]$Body)
    try { & $Body }
    catch { Add-Test $T.id $T.name $false "exception: $($_.Exception.Message)" $null $null }
}

# Start from a known input state.
try {
    foreach ($n in 'bHome', 'bMoveAbs', 'bMoveVelo', 'bStop', 'bReset', 'bEnable') { Write-Fb $n $false }
    Write-Fb 'fHomePosition' 0.0
    Start-Sleep -Milliseconds 300
    # The session may leave the FB with a latched error (its own last test). bReset is part of the interface,
    # so one reset pulse starts every implementation from the same state; the outputs before it are kept in
    # initialState (2026-11-20: a run left bError=TRUE and tests 1-6 failed on that alone).
    $result.initialState = Read-Fb $outs
    Send-Pulse 'bReset'
    Start-Sleep -Milliseconds 300
    $result.afterReset = Read-Fb $outs
} catch { }

# 1 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[0] {
    Write-Fb 'bEnable' $true
    $w = Wait-Fb $outs { param($v) $v.bReady -eq $true } 1000 20
    Add-Test 1 $tests[0].name $w.ok ($(if ($w.ok) { "bReady after $($w.elapsedMs) ms" } else { 'bReady not TRUE within 1000 ms' })) $w.values $w.elapsedMs
}

# 2 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[1] {
    Write-Fb 'fHomePosition' 0.0
    Send-Pulse 'bHome'
    $w = Wait-Fb $outs { param($v) ($v.bHomed -eq $true) -and ($v.bBusy -ne $true) } 30000
    $pos = $w.values.fActPos
    $ok = $w.ok -and ($null -ne $pos) -and ([math]::Abs([double]$pos) -le 0.001)
    Add-Test 2 $tests[1].name $ok ("bHomed={0} fActPos={1}" -f $w.values.bHomed, $pos) $w.values $w.elapsedMs
}

# 3 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[2] {
    Write-Fb 'fPosition' 100.0
    Write-Fb 'fVelocity' 50.0
    Send-Pulse 'bMoveAbs'
    $w = Wait-Fb $outs { param($v) ($v.bDone -eq $true) -or ($v.bError -eq $true) } 15000
    $pos = $w.values.fActPos
    $ok = $w.ok -and ($w.values.bDone -eq $true) -and ($w.values.bError -ne $true) -and ([math]::Abs([double]$pos - 100.0) -le 0.01)
    Add-Test 3 $tests[2].name $ok ("bDone={0} bError={1} fActPos={2}" -f $w.values.bDone, $w.values.bError, $pos) $w.values $w.elapsedMs
}

# 4 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[3] {
    Write-Fb 'fVeloSet' 30.0
    Send-Pulse 'bMoveVelo'
    # the pulse itself takes PulseMs; the 1 s window counts from the rising edge
    $w = Wait-Fb $outs { param($v) ($null -ne $v.fActVelo) -and ([math]::Abs([double]$v.fActVelo - 30.0) -le 0.5) } ([math]::Max(100, 1000 - $PulseMs)) 20
    Add-Test 4 $tests[3].name $w.ok ("fActVelo={0} after {1} ms (+{2} ms pulse)" -f $w.values.fActVelo, $w.elapsedMs, $PulseMs) $w.values ($w.elapsedMs + $PulseMs)
}

# 5 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[4] {
    $before = Read-Fb $outs
    $moving = ($null -ne $before.fActVelo) -and ([math]::Abs([double]$before.fActVelo) -gt 0.1)
    if (-not $moving) {
        # test 4 failed to start a motion: start one so bStop can still be judged
        Write-Fb 'fVeloSet' 30.0
        Send-Pulse 'bMoveVelo'
        $null = Wait-Fb $outs { param($v) ($null -ne $v.fActVelo) -and ([math]::Abs([double]$v.fActVelo) -gt 0.1) } 2000
        $before = Read-Fb $outs
        $moving = ($null -ne $before.fActVelo) -and ([math]::Abs([double]$before.fActVelo) -gt 0.1)
    }
    if (-not $moving) {
        Add-Test 5 $tests[4].name $false "axis not moving before bStop (fActVelo=$($before.fActVelo)); cannot judge" $before $null
        return
    }
    Send-Pulse 'bStop'
    $w = Wait-Fb $outs { param($v) ($null -ne $v.fActVelo) -and ([math]::Abs([double]$v.fActVelo) -le 0.01) } 5000
    Add-Test 5 $tests[4].name $w.ok ("fActVelo before={0} after={1}" -f $before.fActVelo, $w.values.fActVelo) $w.values $w.elapsedMs
}

# 6 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[5] {
    $null = Wait-Fb $outs { param($v) ($null -ne $v.fActVelo) -and ([math]::Abs([double]$v.fActVelo) -le 0.01) } 5000
    $p0 = [double](Read-Fb @('fActPos')).fActPos
    $first = $p0 + 200.0
    $second = $p0 + 60.0
    Write-Fb 'fVelocity' 50.0
    Write-Fb 'fPosition' $first
    Send-Pulse 'bMoveAbs'
    Start-Sleep -Milliseconds 300
    $mid = Read-Fb $outs
    $wasMoving = ($null -ne $mid.fActVelo) -and ([math]::Abs([double]$mid.fActVelo) -gt 0.1)
    Write-Fb 'fPosition' $second
    Send-Pulse 'bMoveAbs'
    $w = Wait-Fb $outs { param($v) (($v.bDone -eq $true) -or ($v.bError -eq $true)) -and ($null -ne $v.fActVelo) -and ([math]::Abs([double]$v.fActVelo) -le 0.01) } 15000
    $pos = $w.values.fActPos
    $ok = $wasMoving -and $w.ok -and ($w.values.bError -ne $true) -and ([math]::Abs([double]$pos - $second) -le 0.01)
    $detail = "start={0:N3} first={1:N3} second={2:N3} movingAtSecond={3} final={4} bDone={5} bError={6}" -f $p0, $first, $second, $wasMoving, $pos, $w.values.bDone, $w.values.bError
    Add-Test 6 $tests[5].name $ok $detail $w.values $w.elapsedMs
}

# 7 -------------------------------------------------------------------------------------------------
Invoke-Step $tests[6] {
    $p0 = [double](Read-Fb @('fActPos')).fActPos
    Write-Fb 'fPosition' ($p0 + 100.0)
    Write-Fb 'fVelocity' 5000.0
    Send-Pulse 'bMoveAbs'
    $we = Wait-Fb $outs { param($v) $v.bError -eq $true } 3000
    $errId = $we.values.nErrorId
    $errOk = $we.ok -and ($null -ne $errId) -and ([long]$errId -ne 0)
    Write-Fb 'fVelocity' 50.0
    Send-Pulse 'bReset'
    $wr = Wait-Fb $outs { param($v) $v.bError -eq $false } 3000
    $ok = $errOk -and $wr.ok
    $detail = "bError={0} nErrorId={1} (after {2} ms); after bReset bError={3}" -f $we.values.bError, $errId, $we.elapsedMs, $wr.values.bError
    Add-Test 7 $tests[6].name $ok $detail ([ordered]@{ error = $we.values; afterReset = $wr.values }) ($we.elapsedMs + $wr.elapsedMs)
}

# leave the axis standing, disabled
try { Send-Pulse 'bStop'; Write-Fb 'bEnable' $false } catch { }
try { $null = Disconnect-TcAds } catch { }

Save-Result
Write-Output ("grade: {0}/{1} passed -> {2}" -f $result.passed, $result.total, $OutFile)
exit 0
