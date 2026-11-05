# Unit: Connect-TcIde launch selection (#72) and the no-second-IDE guard (#136), no IDE needed.
# The ROT (Get-AllComObjects), ProgID registration (Test-TcProgIdRegistered), the launch itself
# (New-TcIdeInstance), the pid lookup (Get-TcIdeProcessId), Get-Process for the fake pids and the
# modal-dialog scan are mocked: nothing is ever launched.
#   A  Get-TcSolutionTcVersion / Resolve-TcLaunchProgId on generated .sln / .tsproj files
#   B  Connect-TcIde without -ProgId launches the IDE of the .tsproj build (progIdSelectedBy)
#      and launches nothing when it cannot tell (PROGID_REQUIRED / IDE_VERSION_NOT_REGISTERED)
#   C  #136: cold start answers MODAL_SCAN_INCOMPLETE; the retries never launch a second IDE
#      while that process (pid + start time) is alive; they attach to it once it answers
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

function New-Sln([string]$Name, [string[]]$TcVersions, [string]$VsVersion = '17.14.36930.0') {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $lines = @('', 'Microsoft Visual Studio Solution File, Format Version 12.00', "VisualStudioVersion = $VsVersion")
    $i = 0
    foreach ($v in $TcVersions) {
        $i++
        $sub = Join-Path $dir "P$i"
        New-Item -ItemType Directory -Path $sub | Out-Null
        $attr = if ($v) { " TcVersion=`"$v`"" } else { '' }
        Set-Content -LiteralPath (Join-Path $sub "P$i.tsproj") -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcSmVersion=`"1.0`"$attr>`r`n<Project/>`r`n</TcSmProject>" -Encoding UTF8
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
$slnOther = New-Sln 'sother' @('3.1.4026.22')
$long = { param($p) & $mod { param($x) Get-TcLongPath $x } $p }
$sln26L = & $long $sln26

$all3 = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')
$global:Reg72 = $all3
$global:Launches72 = New-Object System.Collections.ArrayList
$global:NextPid72 = 9001
$global:Procs72 = @{}            # fake pid -> start time
$global:Rot72 = @()
$global:Modal72 = 'incomplete'   # 'incomplete' | 'dialog' | 'none'

& $mod {
    $script:TcLaunchPendingWaitSec = 1
    function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $global:Reg72 -contains $ProgId }
    function script:New-TcIdeInstance {
        [CmdletBinding()] param([string]$ProgId)
        [void]$global:Launches72.Add($ProgId)
        $pidNew = $global:NextPid72; $global:NextPid72++
        $global:Procs72[$pidNew] = [DateTime]'2026-11-06T10:00:00'
        $sol = New-Object PSObject; $sol | Add-Member NoteProperty FullName ''
        $o = New-Object PSObject
        $o | Add-Member NoteProperty Version '17.0'
        $o | Add-Member NoteProperty Solution $sol
        $o | Add-Member NoteProperty FakePid $pidNew
        $o
    }
    function script:Get-TcIdeProcessId {
        [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
        $p = if ($KnownPid -gt 0) { $KnownPid } elseif ($null -ne $Dte -and $Dte.PSObject.Properties['FakePid']) { [int]$Dte.FakePid } else { 0 }
        @{ ProcessId = $p; MainHwnd = [long]0 }
    }
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id)
        if ($Id -ge 9000) {
            if ($global:Procs72.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs72[$Id] } }
            throw "Cannot find a process with the process identifier $Id."
        }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5)
        switch ($global:Modal72) {
            'incomplete' { return (New-TcModalScanIncomplete -ProcessId $script:TcIdeProcessId -Reason 'timeout' -TimeoutSec 5 -Message 'mock: cold start') }
            'dialog' { return @{ Title = 'Microsoft Visual Studio'; Text = 'mock dialog'; Hwnd = 0; Buttons = @() } }
            default { return $null }
        }
    }
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot72 }
}

function New-RotEntry([int]$ProcId, [string]$Mode, [string]$Solution = '') {
    $sol = New-Object PSObject; $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty Projects ([PSCustomObject]@{ Count = 0 })
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version $(if ($Mode -eq 'unreadable') { '' } else { '17.0' })
    $o | Add-Member NoteProperty Solution $sol
    @{ DisplayName = "!VisualStudio.DTE.17.0:$ProcId"; Object = $o; ProgId = 'VisualStudio.DTE.17.0'; ProcessId = $ProcId }
}
function Reset-State {
    $global:Rot72 = @(); $global:Launches72.Clear(); $global:Procs72 = @{}; $global:Modal72 = 'incomplete'; $global:Reg72 = $all3
    & $mod { $script:TcLaunchedIdes = @{}; $script:TcLaunchedIdeSolutions = @{}; $script:TcIdeProcessId = $null; $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null; $script:TcIdeStartTime = $null }
}

try {
    # --- A: version evidence and ProgID choice ---
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $sln26
    Check 'A1 tsproj TcVersion read (4026)' ($ev.builds.Count -eq 1 -and $ev.builds[0] -eq 4026 -and $ev.tsprojects[0].tcVersion -eq '3.1.4026.22' -and $null -eq $ev.reason -and $ev.visualStudioVersion -eq '17.14.36930.0') ($ev | ConvertTo-Json -Compress -Depth 4)
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnMixed
    Check 'A2 conflicting builds reported' ($ev.builds.Count -eq 2 -and $ev.reason -match 'different TwinCAT builds') "$($ev.reason)"
    $ev = & $mod { param($s) Get-TcSolutionTcVersion -SolutionPath $s } $slnNoVer
    Check 'A3 missing TcVersion reported' ($ev.builds.Count -eq 0 -and $ev.reason -match 'no TcVersion') "$($ev.reason)"

    $rp = { param($p, $s) & $mod { param($a, $b) Resolve-TcLaunchProgId -ProgId $a -SolutionPath $b } $p $s }
    $global:Reg72 = $all3
    $r = & $rp '' $sln26;   Check 'A4 4026 -> TcXaeShell.DTE.17.0' ($r.progId -eq 'TcXaeShell.DTE.17.0' -and $r.selectedBy -eq 'tsproj-version') "$($r.progId)/$($r.selectedBy)"
    $r = & $rp '' $sln24;   Check 'A5 4024 -> TcXaeShell.DTE.15.0' ($r.progId -eq 'TcXaeShell.DTE.15.0' -and $r.selectedBy -eq 'tsproj-version') "$($r.progId)/$($r.selectedBy)"
    $global:Reg72 = @('TcXaeShell.DTE.15.0', 'VisualStudio.DTE.17.0')
    $r = & $rp '' $sln26;   Check 'A6 4026 without TcXaeShell64 -> VisualStudio.DTE.17.0' ($r.progId -eq 'VisualStudio.DTE.17.0' -and $r.selectedBy -eq 'tsproj-version') "$($r.progId)/$($r.selectedBy)"
    $global:Reg72 = @('TcXaeShell.DTE.15.0')
    $r = & $rp '' $sln26;   Check 'A7 4026 with only the 4024 shell -> IDE_VERSION_NOT_REGISTERED (no guess)' ($null -eq $r.progId -and $r.errorCode -eq 'IDE_VERSION_NOT_REGISTERED') "$($r.errorCode)"
    $r = & $rp '' $slnNoVer; Check 'A8 no TcVersion, one registered -> only-one-registered' ($r.progId -eq 'TcXaeShell.DTE.15.0' -and $r.selectedBy -eq 'only-one-registered') "$($r.progId)/$($r.selectedBy)"
    $global:Reg72 = $all3
    $r = & $rp '' $slnNoVer; Check 'A9 no TcVersion, several registered -> PROGID_REQUIRED' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' $slnMixed; Check 'A10 conflicting builds -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp '' '';       Check 'A11 no solution, several registered -> PROGID_REQUIRED' ($r.errorCode -eq 'PROGID_REQUIRED') "$($r.errorCode)"
    $r = & $rp 'VisualStudio.DTE.17.0' $sln24; Check 'A12 -ProgId wins -> explicit' ($r.progId -eq 'VisualStudio.DTE.17.0' -and $r.selectedBy -eq 'explicit') "$($r.progId)/$($r.selectedBy)"
    $global:Reg72 = @()
    $r = & $rp '' $sln26;   Check 'A13 nothing registered -> TWINCAT_NOT_FOUND' ($r.errorCode -eq 'TWINCAT_NOT_FOUND') "$($r.errorCode)"

    # --- B: Connect-TcIde launch path ---
    Reset-State
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B1 4026 sln launches TcXaeShell.DTE.17.0' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'TcXaeShell.DTE.17.0' -and $r.data.progIdSelectedBy -eq 'tsproj-version' -and $r.data.progId -eq 'TcXaeShell.DTE.17.0') "launches=$($global:Launches72 -join ',') code=$($r.error.code) by=$($r.data.progIdSelectedBy)"
    Reset-State
    $r = Connect-TcIde -SolutionPath $sln24
    Check 'B2 4024 sln launches TcXaeShell.DTE.15.0' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'TcXaeShell.DTE.15.0' -and $r.data.progIdSelectedBy -eq 'tsproj-version') "launches=$($global:Launches72 -join ',') by=$($r.data.progIdSelectedBy)"
    Reset-State
    $r = Connect-TcIde -SolutionPath $slnNoVer
    Check 'B3 undeterminable -> PROGID_REQUIRED, nothing launched' ($r.success -eq $false -and $r.error.code -eq 'PROGID_REQUIRED' -and $global:Launches72.Count -eq 0 -and $r.error.hint -match '-ProgId' -and @($r.data.registeredProgIds).Count -eq 3) "code=$($r.error.code) launches=$($global:Launches72.Count)"
    Reset-State; $global:Reg72 = @('TcXaeShell.DTE.15.0')
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B4 4026 sln, only the 4024 shell -> IDE_VERSION_NOT_REGISTERED, nothing launched' ($r.error.code -eq 'IDE_VERSION_NOT_REGISTERED' -and $global:Launches72.Count -eq 0 -and $null -ne $r.error.hint) "code=$($r.error.code) launches=$($global:Launches72.Count)"
    Reset-State
    $r = Connect-TcIde -SolutionPath $sln24 -ProgId 'VisualStudio.DTE.17.0'
    Check 'B5 explicit -ProgId is launched as given' ($global:Launches72.Count -eq 1 -and $global:Launches72[0] -eq 'VisualStudio.DTE.17.0' -and $r.data.progIdSelectedBy -eq 'explicit') "launches=$($global:Launches72 -join ',') by=$($r.data.progIdSelectedBy)"
    Reset-State
    $global:Rot72 = @(New-RotEntry 9500 'ready' $sln26L); $global:Procs72[9500] = [DateTime]'2026-11-06T09:00:00'
    $r = Connect-TcIde -SolutionPath $sln26
    Check 'B6 IDE that has the solution open -> running-instance, nothing launched' ($global:Launches72.Count -eq 0 -and $r.data.progIdSelectedBy -eq 'running-instance' -and $r.data.ideProcessId -eq 9500) "launches=$($global:Launches72.Count) by=$($r.data.progIdSelectedBy) pid=$($r.data.ideProcessId)"
    Reset-State
    $r = Connect-TcIde
    Check 'B7 no -SolutionPath, several registered -> PROGID_REQUIRED' ($r.error.code -eq 'PROGID_REQUIRED' -and $global:Launches72.Count -eq 0) "code=$($r.error.code)"

    # --- C: #136 cold start, retries never launch a second IDE ---
    Reset-State
    $r1 = Connect-TcIde -SolutionPath $sln26
    $own = [int]$r1.data.ideProcessId
    Check 'C1 cold start: MODAL_SCAN_INCOMPLETE after launching one IDE' ($r1.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Launches72.Count -eq 1 -and $own -ge 9001 -and $r1.data.ownedBySession -eq $true) "code=$($r1.error.code) launches=$($global:Launches72.Count) pid=$own"
    $global:Modal72 = 'none'
    $r2 = Connect-TcIde -SolutionPath $sln26           # not in the ROT yet
    Check 'C2 retry, own IDE not in ROT -> IDE_LAUNCH_PENDING, no second launch' ($r2.error.code -eq 'IDE_LAUNCH_PENDING' -and $global:Launches72.Count -eq 1 -and $r2.data.ideProcessId -eq $own -and $r2.data.probe -eq 'not-in-rot' -and $r2.error.hint -match "$own") "code=$($r2.error.code) launches=$($global:Launches72.Count) probe=$($r2.data.probe)"
    $kept = & $mod { "$($script:TcIdeProcessId)|$($script:TcIdeSelectedBy)|$($script:TcIdeConnected)" }
    Check 'C3 pending IDE kept by pid only (Disconnect-TcIde -Quit -Kill can act), not connected' ($kept -eq "$own|launched|False") $kept
    $global:Rot72 = @(New-RotEntry $own 'unreadable')
    $r3 = Connect-TcIde -SolutionPath $sln26 -LaunchIfBlocked
    Check 'C4 retry, own IDE unreadable (even with -LaunchIfBlocked) -> no second launch' ($global:Launches72.Count -eq 1 -and $r3.success -eq $false -and $r3.error.code -in 'IDE_LAUNCH_PENDING', 'IDE_BUSY', 'IDE_MODAL_DIALOG') "code=$($r3.error.code) launches=$($global:Launches72.Count)"
    $r3n = Connect-TcIde -SolutionPath $sln26 -NoLaunch
    Check 'C5 -NoLaunch with a pending own IDE -> IDE_LAUNCH_PENDING (not IDE_NOT_FOUND)' ($r3n.error.code -in 'IDE_LAUNCH_PENDING', 'IDE_BUSY') "code=$($r3n.error.code)"
    $global:Rot72 = @(New-RotEntry $own 'ready' '')
    $global:Modal72 = 'dialog'                         # stops the flow right after attaching
    $r4 = Connect-TcIde -SolutionPath $sln26
    Check 'C6 own IDE answers (empty solution) -> attached, selectedBy session-launched, no second launch' ($global:Launches72.Count -eq 1 -and $r4.error.code -eq 'IDE_MODAL_DIALOG' -and $r4.data.ideProcessId -eq $own -and $r4.data.selectedBy -eq 'session-launched' -and $r4.data.ownedBySession -eq $true) "code=$($r4.error.code) launches=$($global:Launches72.Count) sel=$($r4.data.selectedBy) pid=$($r4.data.ideProcessId)"
    # another solution: the guard is per solution
    $global:Rot72 = @(New-RotEntry $own 'unreadable'); $global:Modal72 = 'incomplete'
    $r5 = Connect-TcIde -SolutionPath $slnOther
    Check 'C7 other solution is not held back by the pending IDE' ($global:Launches72.Count -eq 2) "launches=$($global:Launches72 -join ',') code=$($r5.error.code)"
    # own IDE meanwhile has another solution open -> released, a new IDE may be launched
    $global:Rot72 = @(New-RotEntry $own 'ready' (& $long $slnOther))
    $r6 = Connect-TcIde -SolutionPath $sln26
    Check 'C8 own IDE now has another solution -> guard released, one new launch' ($global:Launches72.Count -eq 3) "launches=$($global:Launches72.Count) code=$($r6.error.code)"
    # process gone (or pid recycled with another start time) -> launch is allowed again
    Reset-State
    $null = Connect-TcIde -SolutionPath $sln26
    $own = [int](& $mod { $script:TcIdeProcessId })
    $global:Procs72[$own] = [DateTime]'2026-11-06T11:11:11'   # same pid, other start time
    $global:Rot72 = @(); $global:Modal72 = 'incomplete'
    $r7 = Connect-TcIde -SolutionPath $sln26
    Check 'C9 recycled pid (other start time) is not our IDE -> new launch' ($global:Launches72.Count -eq 2 -and $r7.error.code -ne 'IDE_LAUNCH_PENDING') "launches=$($global:Launches72.Count) code=$($r7.error.code)"
}
finally {
    Reset-State
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Reg72, Launches72, NextPid72, Procs72, Rot72, Modal72 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
