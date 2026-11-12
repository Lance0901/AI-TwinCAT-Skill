# Unit: Connect-TcIde launch selection (#72) and the no-second-IDE guard (#136), no IDE needed.
# Mocked, so no real IDE is ever launched or touched: the ROT (Get-AllComObjects), the
# GetActiveObject fallback (Get-ComObject, the only caller of Marshal.GetActiveObject), ProgID
# registration (Test-TcProgIdRegistered), the IDE install facts (Get-TcProgIdIdeInfo,
# Get-TcXaeInstallInfo), the launch itself (New-TcIdeInstance), the pid lookup
# (Get-TcIdeProcessId), Get-Process for the fake pids, the modal-dialog scan and the busy answer
# of Invoke-TcComRetry.
#   A  Get-TcSolutionTcVersion / Resolve-TcLaunchProgId on generated .sln / .tsproj files
#   B  Connect-TcIde without -ProgId launches the IDE of the .tsproj build (progIdSelectedBy)
#      and launches nothing when it cannot tell (PROGID_REQUIRED / IDE_VERSION_NOT_REGISTERED)
#   C  #136: cold start answers MODAL_SCAN_INCOMPLETE; the retries never launch a second IDE
#      while that process (pid + start time) is alive; they attach to it once it answers
#   D  #147 M2: a pid only guessed from the start time is never owned or attached
#   powershell.exe -NoProfile -File tests/Unit/connect-ide-launch-72.ps1
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

$root = Join-Path $env:TEMP ("tcauto-unit-72-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

# $TcVersions: one entry per .tsproj: a version, '' (no TcVersion attribute), '<missing>' (file
# not on disk) or '<corrupt>' (not XML)
function New-Sln([string]$Name, [string[]]$TcVersions, [string]$VsVersion = '17.14.36930.0') {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $lines = @('', 'Microsoft Visual Studio Solution File, Format Version 12.00', "VisualStudioVersion = $VsVersion")
    $i = 0
    foreach ($v in $TcVersions) {
        $i++
        $sub = Join-Path $dir "P$i"
        New-Item -ItemType Directory -Path $sub | Out-Null
        $file = Join-Path $sub "P$i.tsproj"
        if ($v -eq '<corrupt>') { Set-Content -LiteralPath $file -Value 'this is <not xml' -Encoding UTF8 }
        elseif ($v -ne '<missing>') {
            $attr = if ($v) { " TcVersion=`"$v`"" } else { '' }
            Set-Content -LiteralPath $file -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcSmVersion=`"1.0`"$attr>`r`n<Project/>`r`n</TcSmProject>" -Encoding UTF8
        }
        $lines += "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"P$i`", `"P$i\P$i.tsproj`", `"{10112974-92E6-3C4B-560E-B30614E0549$i}`""
        $lines += 'EndProject'
    }
    $sln = Join-Path $dir "$Name.sln"
    Set-Content -LiteralPath $sln -Value $lines -Encoding UTF8
    $sln
}

$sln26 = New-Sln 's4026' @('3.1.4026.22')
$sln24 = New-Sln 's4024' @('3.1.4024.71') '15.0.35826.109'
$slnNoVer = New-Sln 'snover' @('')
$slnMixed = New-Sln 'smixed' @('3.1.4024.71', '3.1.4026.22')
$slnHalf = New-Sln 'shalf' @('3.1.4026.22', '')
$slnMissing = New-Sln 'smissing' @('<missing>')
$slnCorrupt = New-Sln 'scorrupt' @('<corrupt>')
$slnNoTs = New-Sln 'snots' @()
$slnOther = New-Sln 'sother' @('3.1.4026.22')
$sln26r19 = New-Sln 's4026r19' @('3.1.4026.19')
$sln24r59 = New-Sln 's4024r59' @('3.1.4024.59')
$slnRevMix = New-Sln 'srevmix' @('3.1.4026.22', '3.1.4026.19')
$long = { param($p) & $mod { param($x) Get-TcLongPath $x } $p }
$sln26L = & $long $sln26

$all3 = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')
# measured layout of this repo's dev machine (XAE 3.1.4026.22 in all three hosts, Remote Manager 4024.71)
$ideDefault = @{ 'TcXaeShell.DTE.15.0' = '3.1.4026.22'; 'TcXaeShell.DTE.17.0' = '3.1.4026.22'; 'VisualStudio.DTE.17.0' = '3.1.4026.22' }
$instDefault = [PSCustomObject]@{ installedBuild = 4026; remoteManagerBuilds = @('4024.59', '4024.71', '4026.22') }
$global:Reg72 = $all3
$global:Ide72 = $ideDefault.Clone()
$global:Inst72 = $instDefault
$global:Launches72 = New-Object System.Collections.ArrayList
$global:LaunchedDtes72 = @{}      # pid -> DTE object handed out by New-TcIdeInstance
$global:NextPid72 = 9001
$global:Procs72 = @{}             # fake pid -> start time
$global:Rot72 = @()
$global:LaunchInRot72 = $true     # New-TcIdeInstance registers the new DTE in the fake ROT
$global:GuessPid72 = 0            # Get-TcIdeProcessId: pid guessed from the start time
$global:Modal72 = 'incomplete'    # 'incomplete' | 'dialog' | 'none'
$global:ModalQueue72 = New-Object System.Collections.ArrayList
$global:GetComObjectCalls72 = 0
$global:Kills72 = New-Object System.Collections.ArrayList   # m-c: Stop-TcLaunchedIde / Stop-Process are mocks, nothing real is ever killed

function New-FakeDte([string]$Version = '17.0', [string]$Solution = '', [bool]$Busy = $false) {
    $sol = New-Object PSObject
    $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty Projects ([PSCustomObject]@{ Count = 0 })
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version $Version
    $o | Add-Member NoteProperty Solution $sol
    $o | Add-Member NoteProperty Busy $Busy
    $o
}
function New-RotEntry([int]$ProcId, [object]$Object, [string]$ProgId = 'VisualStudio.DTE.17.0') {
    @{ DisplayName = "!${ProgId}:$ProcId"; Object = $Object; ProgId = $ProgId; ProcessId = $ProcId }
}

& $mod {
    param($NewFakeDte, $NewRotEntry)
    $script:TcLaunchPendingWaitSec = 1
    $script:TcLaunchRotWaitSec = 0
    $script:UnitNewFakeDte = $NewFakeDte; $script:UnitNewRotEntry = $NewRotEntry
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $global:Reg72 -contains $ProgId }
    function script:Get-TcProgIdIdeInfo {
        [CmdletBinding()] param([string]$ProgId)
        if ($global:Reg72 -notcontains $ProgId) { return $null }
        $v = $global:Ide72[$ProgId]
        [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = $v; xaeBuild = (ConvertTo-TcBuildNumber $v) }
    }
    function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() $global:Inst72 }
    function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) $global:GetComObjectCalls72++; $null }
    function script:New-TcIdeInstance {
        [CmdletBinding()] param([string]$ProgId)
        [void]$global:Launches72.Add($ProgId)
        $pidNew = $global:NextPid72; $global:NextPid72++
        $global:Procs72[$pidNew] = [DateTime]::Now
        $o = & $script:UnitNewFakeDte
        $global:LaunchedDtes72[$pidNew] = $o
        if ($global:LaunchInRot72) { $global:Rot72 = @($global:Rot72) + @(& $script:UnitNewRotEntry $pidNew $o $ProgId) }
        $o
    }
    function script:Get-TcIdeProcessId {
        [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
        if ($KnownPid -gt 0) { return @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = 'known-pid' } }
        if ($global:GuessPid72 -gt 0 -and $null -ne $StartedAfter) { return @{ ProcessId = $global:GuessPid72; MainHwnd = [long]0; Source = 'start-time' } }
        @{ ProcessId = 0; MainHwnd = [long]0; Source = '' }
    }
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id, [string]$Name)
        if ($PSBoundParameters.ContainsKey('Name')) {
            return @($global:Procs72.Keys | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $Name; StartTime = $global:Procs72[$_] } })
        }
        if ($Id -ge 9000) {
            if ($global:Procs72.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs72[$Id] } }
            throw "Cannot find a process with the process identifier $Id."
        }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $mode = $global:Modal72
        if ($global:ModalQueue72.Count -gt 0) { $mode = $global:ModalQueue72[0]; $global:ModalQueue72.RemoveAt(0) }
        $p = if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:TcIdeProcessId }
        switch ($mode) {
            'incomplete' { return (New-TcModalScanIncomplete -ProcessId $p -Reason 'timeout' -TimeoutSec 5 -Message 'mock: cold start') }
            'dialog' { return @{ Title = 'Microsoft Visual Studio'; Text = 'mock dialog'; Hwnd = 0; Buttons = @() } }
            default { return $null }
        }
    }
    function script:Invoke-TcComRetry {
        [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
        if ($OperationName -like 'Read DTE.Version / Solution.FullName*') {
            $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
            if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
        }
        & $script:UnitOrigComRetry @PSBoundParameters
    }
    function script:Stop-TcLaunchedIde { [CmdletBinding()] param([object]$Dte, [string]$ProgId, [DateTime]$StartedAfter) [void]$global:Kills72.Add("Stop-TcLaunchedIde $ProgId"); ,@() }
    function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) [void]$global:Kills72.Add("Stop-Process $Id") }
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot72 }
} ${function:New-FakeDte} ${function:New-RotEntry}

function Reset-State {
    $global:Rot72 = @(); $global:Launches72.Clear(); $global:LaunchedDtes72 = @{}; $global:Procs72 = @{}; $global:Modal72 = 'incomplete'; $global:ModalQueue72.Clear()
    $global:Reg72 = $all3; $global:Ide72 = $ideDefault.Clone(); $global:Inst72 = $instDefault; $global:LaunchInRot72 = $true; $global:GuessPid72 = 0
    & $mod { Remove-Item -LiteralPath (Get-TcLaunchRecordPath) -Force -ErrorAction SilentlyContinue; $script:TcLaunchedIdes = @{}; $script:TcLaunchedIdeSolutions = @{}; $script:TcIdeProcessId = $null; $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null; $script:TcIdeStartTime = $null; $script:TcIdeSelectedBy = $null }
}
function Set-OwnRot([int]$ProcId, [string]$Mode, [string]$Solution = '') {
    $o = $global:LaunchedDtes72[$ProcId]
    $o.Version = $(if ($Mode -eq 'unreadable') { '' } else { '17.0' })
    $o.Busy = ($Mode -eq 'busy')
    $o.Solution.FullName = $Solution
    $global:Rot72 = @(New-RotEntry $ProcId $o 'TcXaeShell.DTE.17.0')
}

try {
    # --- A: version evidence and ProgID choice ---
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $sln26
    Check 'A1 tsproj TcVersion read (4026)' ($ev.builds.Count -eq 1 -and $ev.builds[0] -eq 4026 -and $ev.tsprojects[0].tcVersion -eq '3.1.4026.22' -and $null -eq $ev.reason -and $ev.visualStudioVersion -eq '17.14.36930.0') ($ev | ConvertTo-Json -Compress -Depth 4)
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnMixed
    Check 'A2 conflicting builds reported' ($ev.builds.Count -eq 2 -and $ev.reason -match 'different TwinCAT builds') "$($ev.reason)"
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnNoVer
    Check 'A3 missing TcVersion reported' ($ev.builds.Count -eq 0 -and $ev.reason -match 'unknown' -and $ev.tsprojects[0].error -match 'no TcVersion') "$($ev.reason)"
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnHalf
    Check 'A3b one of two .tsproj without TcVersion -> reason set although one build is known' ($ev.builds.Count -eq 1 -and $null -ne $ev.reason) "$($ev.reason)"
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnMissing
    Check 'A3c referenced .tsproj missing on disk -> reason' ($ev.tsprojects[0].error -eq 'file not found' -and $null -ne $ev.reason) "$($ev.reason)"
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnCorrupt
    Check 'A3d corrupt .tsproj XML -> reason' ($ev.tsprojects[0].error -match 'unreadable' -and $null -ne $ev.reason) "$($ev.reason)"

    $rp = { param($p, $s) & $mod { param($a, $b) Resolve-TcLaunchProgId -ProgId $a -SolutionPath $b } $p $s }
    Reset-State
    $r = & $rp '' $sln26;   Check 'A4 4026 -> TcXaeShell.DTE.17.0' ($r.progId -eq 'TcXaeShell.DTE.17.0' -and $r.selectedBy -eq 'tsproj-version') "$($r.progId)/$($r.selectedBy)"
    $r = & $rp '' $sln24;   Check 'A5 M3-b: 4024 project, 32-bit shell is XAE 4026 (+ Remote Manager 4024.71) -> PROGID_REQUIRED, untested path' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'not measured yet') "$($r.errorCode) $($r.errorMessage)"
    $r = & $rp '' $sln26r19; Check 'A5b m-a: 4026.19 project, XAE 4026.22 -> PROGID_REQUIRED (revision compared strictly)' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.progId)/$($r.errorCode)"
    $r = & $rp '' $slnRevMix; Check 'A5c two .tsproj, same build, other revision -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'different TwinCAT versions') "$($r.errorCode)"
    $global:Reg72 = @('TcXaeShell.DTE.15.0', 'VisualStudio.DTE.17.0')
    $r = & $rp '' $sln26;   Check 'A6 4026 without TcXaeShell64 -> VisualStudio.DTE.17.0 (XAE integrated)' ($r.progId -eq 'VisualStudio.DTE.17.0' -and $r.selectedBy -eq 'tsproj-version') "$($r.progId)/$($r.selectedBy)"
    $global:Ide72['VisualStudio.DTE.17.0'] = $null
    $r = & $rp '' $sln26;   Check 'A6b 4026, VS2022 without TwinCAT XAE integration -> IDE_VERSION_NOT_REGISTERED' ($null -eq $r.progId -and $r.errorCode -eq 'IDE_VERSION_NOT_REGISTERED') "$($r.errorCode)"
    Reset-State; $global:Reg72 = @('TcXaeShell.DTE.15.0')
    $r = & $rp '' $sln26;   Check 'A7 4026 with only the 32-bit shell -> IDE_VERSION_NOT_REGISTERED (no guess)' ($null -eq $r.progId -and $r.errorCode -eq 'IDE_VERSION_NOT_REGISTERED') "$($r.errorCode)"
    $r = & $rp '' $slnNoVer; Check 'A8 no TcVersion, one registered -> PROGID_REQUIRED (m1: unknown version never falls back)' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)/$($r.selectedBy)"
    $r = & $rp '' $slnNoTs; Check 'A8b solution without .tsproj, one registered -> only-one-registered' ($r.progId -eq 'TcXaeShell.DTE.15.0' -and $r.selectedBy -eq 'only-one-registered') "$($r.progId)/$($r.selectedBy)"
    $r = & $rp '' '';       Check 'A8c no solution, one registered -> only-one-registered' ($r.selectedBy -eq 'only-one-registered') "$($r.selectedBy)"
    Reset-State
    $r = & $rp '' $slnNoVer; Check 'A9 no TcVersion, several registered -> PROGID_REQUIRED' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' $slnMixed; Check 'A10 conflicting builds -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' $slnHalf;  Check 'A10b one .tsproj without version -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' $slnMissing; Check 'A10c .tsproj missing -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' $slnCorrupt; Check 'A10d corrupt .tsproj -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' '';       Check 'A11 no solution, several registered -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp 'VisualStudio.DTE.17.0' $sln24; Check 'A12 -ProgId wins -> explicit' ($r.progId -eq 'VisualStudio.DTE.17.0' -and $r.selectedBy -eq 'explicit') "$($r.progId)/$($r.selectedBy)"
    $global:Reg72 = @()
    $r = & $rp '' $sln26;   Check 'A13 nothing registered -> TWINCAT_NOT_FOUND' ($r.errorCode -eq 'TWINCAT_NOT_FOUND') "$($r.errorCode)"
    # M3: which build the 32-bit TcXaeShell (ProgID 15.0) really is
    Reset-State; $global:Inst72 = [PSCustomObject]@{ installedBuild = 4026; remoteManagerBuilds = @('4026.22') }
    $r = & $rp '' $sln24;   Check 'A14 4024, 32-bit shell is XAE 4026 without Remote Manager 4024 -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'Remote Manager') "$($r.errorCode)"
    Reset-State; $global:Ide72['TcXaeShell.DTE.15.0'] = '3.1.4024.71'; $global:Inst72 = [PSCustomObject]@{ installedBuild = 4024; remoteManagerBuilds = @() }
    $r = & $rp '' $sln24;   Check 'A15 4024.71 project, 32-bit shell is XAE 4024.71 -> TcXaeShell.DTE.15.0' ($r.progId -eq 'TcXaeShell.DTE.15.0') "$($r.progId)/$($r.errorCode)"
    $r = & $rp '' $sln24r59; Check 'A15b 4024.59 project, XAE 4024.71 -> PROGID_REQUIRED (4024.59 != 4024.71)' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.progId)/$($r.errorCode)"
    $global:Ide72['TcXaeShell.DTE.15.0'] = $null; $global:Inst72 = [PSCustomObject]@{ installedBuild = 4026; remoteManagerBuilds = @('4024.71') }
    $r = & $rp '' $sln24;   Check 'A16 4024, XAE build of the 32-bit shell unreadable and 4026 installed -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $global:Inst72 = [PSCustomObject]@{ installedBuild = 4024; remoteManagerBuilds = @() }
    $r = & $rp '' $sln24;   Check 'A17 4024, XAE unreadable and no 4026 installed -> PROGID_REQUIRED (m-a: only an equal XAE version is accepted)' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.progId)/$($r.errorCode)"
    Reset-State; $global:Ide72['TcXaeShell.DTE.17.0'] = $null
    $r = & $rp '' $sln26;   Check 'A18 4026, TcXaeShell64 XAE unreadable -> VisualStudio.DTE.17.0' ($r.progId -eq 'VisualStudio.DTE.17.0') "$($r.progId)/$($r.errorCode)"

    # --- B: Connect-TcIde launch path ---
    Reset-State
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B1 4026 sln launches TcXaeShell.DTE.17.0' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'TcXaeShell.DTE.17.0' -and $r.data.progIdSelectedBy -eq 'tsproj-version' -and $r.data.progId -eq 'TcXaeShell.DTE.17.0') "launches=$($global:Launches72 -join ',') code=$($r.error.code) by=$($r.data.progIdSelectedBy)"
    Reset-State; $global:Ide72['TcXaeShell.DTE.15.0'] = '3.1.4024.71'
    $r = Connect-TcIde -SolutionPath $sln24
    Check 'B2 4024 sln launches TcXaeShell.DTE.15.0' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'TcXaeShell.DTE.15.0' -and $r.data.progIdSelectedBy -eq 'tsproj-version') "launches=$($global:Launches72 -join ',') by=$($r.data.progIdSelectedBy)"
    Reset-State
    $r = Connect-TcIde -SolutionPath $slnNoVer
    Check 'B3 undeterminable -> PROGID_REQUIRED, nothing launched' ($r.success -eq $false -and $r.error.code -eq 'PROGID_REQUIRED' -and $global:Launches72.Count -eq 0 -and $r.error.hint -match '-ProgId' -and @($r.data.registeredProgIds).Count -eq 3) "code=$($r.error.code) launches=$($global:Launches72.Count)"
    Reset-State; $global:Reg72 = @('TcXaeShell.DTE.15.0')
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B4 4026 sln, only the 32-bit shell -> IDE_VERSION_NOT_REGISTERED, nothing launched' ($r.error.code -eq 'IDE_VERSION_NOT_REGISTERED' -and $global:Launches72.Count -eq 0 -and $null -ne $r.error.hint) "code=$($r.error.code) launches=$($global:Launches72.Count)"
    Reset-State
    $r = Connect-TcIde -SolutionPath $sln24 -ProgId 'VisualStudio.DTE.17.0'
    Check 'B5 explicit -ProgId is launched as given' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'VisualStudio.DTE.17.0' -and $r.data.progIdSelectedBy -eq 'explicit') "launches=$($global:Launches72 -join ',') by=$($r.data.progIdSelectedBy)"
    Reset-State
    $global:Rot72 = @(New-RotEntry 9500 (New-FakeDte '17.0' $sln26L)); $global:Procs72[9500] = [DateTime]'2026-11-06T09:00:00'
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B6 IDE that has the solution open -> running-instance, nothing launched' ($global:Launches72.Count -eq 0 -and $r.data.progIdSelectedBy -eq 'running-instance' -and $r.data.ideProcessId -eq 9500) "launches=$($global:Launches72.Count) by=$($r.data.progIdSelectedBy) pid=$($r.data.ideProcessId)"
    Reset-State
    $r = Connect-TcIde
    Check 'B7 no -SolutionPath, several registered -> PROGID_REQUIRED' ($r.error.code -eq 'PROGID_REQUIRED' -and $global:Launches72.Count -eq 0) "code=$($r.error.code)"

    # --- C: #136 cold start, retries never launch a second IDE ---
    Reset-State
    $r1 = Connect-TcIde -SolutionPath $sln26
    $own = [int]$r1.data.ideProcessId
    Check 'C1 cold start: MODAL_SCAN_INCOMPLETE after launching one IDE (pid from the ROT entry of that DTE)' ($r1.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Launches72.Count -eq 1 -and $own -ge 9001 -and $r1.data.ownedBySession -eq $true) "code=$($r1.error.code) launches=$($global:Launches72.Count) pid=$own"
    $global:Modal72 = 'none'; $global:Rot72 = @()
    $r2 = Connect-TcIde -SolutionPath $sln26           # not in the ROT (any more)
    Check 'C2 retry, own IDE not in ROT -> IDE_LAUNCH_PENDING, no second launch' ($r2.error.code -eq 'IDE_LAUNCH_PENDING' -and $global:Launches72.Count -eq 1 -and $r2.data.ideProcessId -eq $own -and $r2.data.probe -eq 'not-in-rot' -and $r2.error.hint -match "$own") "code=$($r2.error.code) launches=$($global:Launches72.Count) probe=$($r2.data.probe)"
    $kept = & $mod { "$($script:TcIdeProcessId)|$($script:TcIdeSelectedBy)|$($script:TcIdeConnected)" }
    Check 'C3 pending IDE kept by pid only (Disconnect-TcIde -Quit -Kill can act), not connected' ($kept -eq "$own|launched|False") $kept
    Set-OwnRot $own 'unreadable'
    $r3 = Connect-TcIde -SolutionPath $sln26 -LaunchIfBlocked
    Check 'C4 own IDE unreadable, even with -LaunchIfBlocked -> IDE_LAUNCH_PENDING, no second launch' ($global:Launches72.Count -eq 1 -and $r3.error.code -eq 'IDE_LAUNCH_PENDING' -and $r3.data.probe -eq 'unreadable') "code=$($r3.error.code) probe=$($r3.data.probe) launches=$($global:Launches72.Count)"
    $r3n = Connect-TcIde -SolutionPath $sln26 -NoLaunch
    Check 'C5 -NoLaunch with a pending own IDE -> IDE_LAUNCH_PENDING (not IDE_NOT_FOUND)' ($r3n.error.code -eq 'IDE_LAUNCH_PENDING') "code=$($r3n.error.code)"
    Set-OwnRot $own 'busy'
    $r3b = Connect-TcIde -SolutionPath $sln26
    Check 'C5b own IDE busy (RPC_E_CALL_REJECTED) -> IDE_LAUNCH_PENDING probe busy' ($r3b.error.code -eq 'IDE_LAUNCH_PENDING' -and $r3b.data.probe -eq 'busy' -and $global:Launches72.Count -eq 1) "code=$($r3b.error.code) probe=$($r3b.data.probe)"
    Set-OwnRot $own 'ready'
    $global:Modal72 = 'dialog'
    $r3d = Connect-TcIde -SolutionPath $sln26
    Check 'C5c dialog in own IDE: scanned before any DTE read -> IDE_MODAL_DIALOG, no second launch' ($r3d.error.code -eq 'IDE_MODAL_DIALOG' -and $r3d.data.ideProcessId -eq $own -and $global:Launches72.Count -eq 1) "code=$($r3d.error.code) launches=$($global:Launches72.Count)"
    $global:Modal72 = 'incomplete'
    $r3i = Connect-TcIde -SolutionPath $sln26
    Check 'C5d incomplete scan of own IDE -> IDE_LAUNCH_PENDING scan-incomplete (DTE not read)' ($r3i.error.code -eq 'IDE_LAUNCH_PENDING' -and $r3i.data.probe -eq 'scan-incomplete' -and $r3i.data.scanComplete -eq $false) "code=$($r3i.error.code) probe=$($r3i.data.probe)"
    $global:Modal72 = 'none'
    $r3m = Connect-TcIde -SolutionPath $sln26 -ProgId 'VisualStudio.DTE.17.0'
    Check 'C5e M1: -ProgId other than the launched one -> IDE_LAUNCH_PENDING progIdMismatch, not attached, no launch' ($r3m.error.code -eq 'IDE_LAUNCH_PENDING' -and $r3m.data.probe -eq 'progid-mismatch' -and $r3m.data.progIdMismatch.launched -eq 'TcXaeShell.DTE.17.0' -and $r3m.data.progIdMismatch.requested -eq 'VisualStudio.DTE.17.0' -and $r3m.data.attached -eq $false -and $global:Launches72.Count -eq 1) "code=$($r3m.error.code) probe=$($r3m.data.probe) launches=$($global:Launches72.Count)"
    [void]$global:ModalQueue72.Add('none'); [void]$global:ModalQueue72.Add('dialog')   # wait scan: none; after attaching: a dialog stops the flow
    $r4 = Connect-TcIde -SolutionPath $sln26 -ProgId 'TcXaeShell.DTE.17.0'
    Check 'C6 own IDE answers (empty solution), same -ProgId -> attached session-launched, no second launch' ($global:Launches72.Count -eq 1 -and $r4.error.code -eq 'IDE_MODAL_DIALOG' -and $r4.data.ideProcessId -eq $own -and $r4.data.selectedBy -eq 'session-launched' -and $r4.data.ownedBySession -eq $true) "code=$($r4.error.code) launches=$($global:Launches72.Count) sel=$($r4.data.selectedBy) pid=$($r4.data.ideProcessId)"
    Set-OwnRot $own 'unreadable'; $global:Modal72 = 'incomplete'
    $r5 = Connect-TcIde -SolutionPath $slnOther
    Check 'C7 other solution is not held back by the pending IDE' ($global:Launches72.Count -eq 2) "launches=$($global:Launches72 -join ',') code=$($r5.error.code)"
    Set-OwnRot $own 'ready' (& $long $slnOther); $global:Modal72 = 'none'
    [void]$global:ModalQueue72.Add('none'); [void]$global:ModalQueue72.Add('incomplete')
    $r6 = Connect-TcIde -SolutionPath $sln26
    Check 'C8 own IDE now has another solution -> guard released, one new launch' ($global:Launches72.Count -eq 3) "launches=$($global:Launches72.Count) code=$($r6.error.code)"
    Reset-State
    $null = Connect-TcIde -SolutionPath $sln26
    $own = [int](& $mod { $script:TcIdeProcessId })
    $global:Procs72[$own] = [DateTime]'2026-11-06T11:11:11'   # same pid, other start time
    $global:Rot72 = @()
    $r7 = Connect-TcIde -SolutionPath $sln26
    Check 'C9 recycled pid (other start time) is not our IDE -> new launch' ($global:Launches72.Count -eq 2 -and $r7.error.code -ne 'IDE_LAUNCH_PENDING') "launches=$($global:Launches72.Count) code=$($r7.error.code)"
    Reset-State
    $null = Connect-TcIde -SolutionPath $sln26
    $own = [int](& $mod { $script:TcIdeProcessId })
    $global:Procs72.Remove($own); $global:Rot72 = @()
    $r8 = Connect-TcIde -SolutionPath $sln26
    Check 'C10 own IDE process gone -> new launch' ($global:Launches72.Count -eq 2 -and $r8.error.code -ne 'IDE_LAUNCH_PENDING') "launches=$($global:Launches72.Count) code=$($r8.error.code)"

    # --- D: #147 M2, a pid guessed from the start time is never ours ---
    Reset-State
    $global:LaunchInRot72 = $false
    $global:Procs72[9777] = [DateTime]::Now                       # the user's IDE, started at the same moment
    $userDte = New-FakeDte '17.0' ''
    $global:GuessPid72 = 9777
    $d1 = Connect-TcIde -SolutionPath $sln26
    $state = & $mod { "$($script:TcIdeProcessId)|$($script:TcIdeConnected)|$(Test-TcLaunchedIde -ProcessId 9777)" }
    Check 'D1 launched IDE not in ROT, pid only guessed -> IDE_LAUNCH_PENDING, not owned, nothing attached' ($d1.error.code -eq 'IDE_LAUNCH_PENDING' -and $d1.data.pidConfirmed -eq $false -and $d1.data.ownedBySession -eq $false -and $d1.data.guessedProcessId -eq 9777 -and $state -eq '|False|False' -and $global:Launches72.Count -eq 1) "code=$($d1.error.code) state=$state"
    $global:Rot72 = @(New-RotEntry 9777 $userDte)                  # the user's IDE shows up in the ROT, empty
    $d2 = Connect-TcIde -SolutionPath $sln26
    Check 'D2 retry: the other IDE (same start time) is never attached; no second launch' ($d2.error.code -eq 'IDE_LAUNCH_PENDING' -and $d2.data.probe -eq 'pid-unconfirmed' -and $d2.data.ideProcessId -eq 0 -and $global:Launches72.Count -eq 1) "code=$($d2.error.code) probe=$($d2.data.probe) pid=$($d2.data.ideProcessId) launches=$($global:Launches72.Count)"
    $launchedPid = @($global:LaunchedDtes72.Keys)[0]
    $global:Rot72 = @(New-RotEntry 9777 $userDte) + @(New-RotEntry $launchedPid $global:LaunchedDtes72[$launchedPid] 'TcXaeShell.DTE.17.0')
    [void]$global:ModalQueue72.Add('none'); [void]$global:ModalQueue72.Add('dialog')
    $d3 = Connect-TcIde -SolutionPath $sln26
    Check 'D3 ROT now lists the identical DTE -> pid confirmed from the moniker, attached and owned' ($d3.error.code -eq 'IDE_MODAL_DIALOG' -and $d3.data.ideProcessId -eq $launchedPid -and $d3.data.selectedBy -eq 'session-launched' -and $d3.data.ownedBySession -eq $true -and $global:Launches72.Count -eq 1) "code=$($d3.error.code) pid=$($d3.data.ideProcessId) sel=$($d3.data.selectedBy)"
    Reset-State
    $global:LaunchInRot72 = $false; $global:GuessPid72 = 9777; $global:Procs72[9777] = [DateTime]::Now
    $null = Connect-TcIde -SolutionPath $sln26
    $global:Procs72 = @{}; $global:GuessPid72 = 0; $global:LaunchInRot72 = $true
    $d4 = Connect-TcIde -SolutionPath $sln26
    Check 'D4 unconfirmed launch and no IDE process started since then is alive -> record dropped, new launch' ($global:Launches72.Count -eq 2) "launches=$($global:Launches72.Count) code=$($d4.error.code)"

    # --- D5: m-b, the exit for pid-unconfirmed ---
    Reset-State
    $global:LaunchInRot72 = $false; $global:GuessPid72 = 9777; $global:Procs72[9777] = [DateTime]::Now
    $null = Connect-TcIde -SolutionPath $sln26
    $bad = Disconnect-TcIde -ForgetPendingLaunch -Quit
    Check 'D5 -ForgetPendingLaunch with -Quit -> INVALID_PARAMS' ($bad.error.code -eq 'INVALID_PARAMS') "code=$($bad.error.code)"
    $fg = Disconnect-TcIde -ForgetPendingLaunch
    Check 'D6 Disconnect-TcIde -ForgetPendingLaunch forgets the unconfirmed launch record' ($fg.success -and @($fg.data.forgottenLaunches).Count -eq 1 -and @($fg.data.forgottenLaunches)[0].solution -eq $sln26L) ($fg | ConvertTo-Json -Compress -Depth 4)
    $global:LaunchInRot72 = $true; $global:GuessPid72 = 0
    $d7 = Connect-TcIde -SolutionPath $sln26
    Check 'D7 after forgetting, the next Connect-TcIde may launch again' ($global:Launches72.Count -eq 2) "launches=$($global:Launches72.Count) code=$($d7.error.code)"

    # --- E: nothing real ---
    Check 'E1 the GetActiveObject fallback is the mock (no real ROT lookup)' ($global:GetComObjectCalls72 -gt 0) "calls=$($global:GetComObjectCalls72)"
    $srcText = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Connect-TcIde.ps1') -Raw) + (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Private\Resolve-TcLaunchProgId.ps1') -Raw)
    Check 'E3 m-c: nothing was killed (Stop-TcLaunchedIde / Stop-Process are mocks and were not called)' ($global:Kills72.Count -eq 0) ($global:Kills72 -join ', ')
    Check 'E2 Connect-TcIde / launch helpers call GetActiveObject only through Get-ComObject' ($srcText -notmatch 'Marshal\]::GetActiveObject') ''
}
finally {
    Reset-State
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Kills72, Reg72, Ide72, Inst72, Launches72, LaunchedDtes72, NextPid72, Procs72, Rot72, LaunchInRot72, GuessPid72, Modal72, ModalQueue72, GetComObjectCalls72 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
