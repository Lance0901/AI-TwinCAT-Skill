# Unit: #73 / #149 the launch record of an IDE this module launched survives a bridge restart
# (simulated with Import-Module -Force: a new module instance with empty memory), no IDE needed.
# Mocked like connect-ide-launch-72.ps1: the ROT (Get-AllComObjects), Get-ComObject, ProgID
# registration / install facts, the launch (New-TcIdeInstance), the pid lookup
# (Get-TcIdeProcessId), Get-Process for the fake pids (with ProcessName), the modal-dialog scan,
# Stop-Process and Stop-TcLaunchedIde. Nothing real is launched, touched or killed.
#   R  restart restores ownership (-Kill allowed) and the no-second-launch guard
#   P  pid reuse: other start time / other image name -> nothing restored
#   F  corrupt / unreadable record file -> nothing owned, attach / launch not blocked
#   U  a pid-unconfirmed record never restores ownership; -ForgetPendingLaunch clears the file
#   Q  Disconnect-TcIde -Quit clears the record (data.launchRecordWarning when it cannot)
#   X  #152 M1: record of another live TcAuto session (hostPid alive) -> not owned, -Kill refused,
#      no second IDE; adopted once that host is gone
#   M  m1: an unconfirmed write never replaces a confirmed record; n3: non-IDE images not recorded
#   J  m3 / m4: JSON of the wrong shape, cleanup only drops records that are certainly stale
#   B  #29 solution-blocked -> launched after a restart (own / other session)
#   C  two processes write the file at the same time (named mutex)
#   powershell.exe -NoProfile -File tests/Unit/launch-record-persist-73.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$modPath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-73-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$slnDir = Join-Path $root 's4026'
New-Item -ItemType Directory -Path (Join-Path $slnDir 'P1') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $slnDir 'P1\P1.tsproj') -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcSmVersion=`"1.0`" TcVersion=`"3.1.4026.22`">`r`n<Project/>`r`n</TcSmProject>" -Encoding UTF8
$sln = Join-Path $slnDir 's4026.sln'
Set-Content -LiteralPath $sln -Encoding UTF8 -Value @('', 'Microsoft Visual Studio Solution File, Format Version 12.00', 'VisualStudioVersion = 17.14.36930.0',
    'Project("{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}") = "P1", "P1\P1.tsproj", "{10112974-92E6-3C4B-560E-B30614E05491}"', 'EndProject')

$global:Launches73 = New-Object System.Collections.ArrayList
$global:LaunchedDtes73 = @{}
$global:NextPid73 = 9001
$global:Procs73 = @{}             # fake pid -> start time
$global:Names73 = @{}             # fake pid -> process name (default TcXaeShell)
$global:Rot73 = @()
$global:LaunchInRot73 = $true
$global:GuessPid73 = 0
$global:Modal73 = 'incomplete'
$global:ModalQueue73 = New-Object System.Collections.ArrayList
$global:Kills73 = New-Object System.Collections.ArrayList
$global:Quits73 = 0
$global:Blocked73 = $false

function New-FakeDte([string]$Solution = '') {
    $sol = New-Object PSObject
    $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty Projects ([PSCustomObject]@{ Count = 0 })
    $sol | Add-Member ScriptMethod Close { param($save) }
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version '17.0'
    $o | Add-Member NoteProperty Solution $sol
    $o | Add-Member NoteProperty Busy $false
    $o | Add-Member ScriptMethod Quit { $global:Quits73++ }
    $o
}
function New-RotEntry([int]$ProcId, [object]$Object, [string]$ProgId = 'TcXaeShell.DTE.17.0') {
    @{ DisplayName = "!${ProgId}:$ProcId"; Object = $Object; ProgId = $ProgId; ProcessId = $ProcId }
}

# (Re)loads the module - a new module instance with empty memory, as after a bridge restart /
# ReloadModule - and installs the mocks into it.
function Restart-Module {
    Import-Module $modPath -Force -WarningAction SilentlyContinue
    $script:mod = Get-Module TwinCATAutomation
    & $script:mod {
        param($NewFakeDte, $NewRotEntry)
        $script:TcLaunchPendingWaitSec = 1
        $script:TcLaunchRotWaitSec = 0
        $script:UnitNewFakeDte = $NewFakeDte; $script:UnitNewRotEntry = $NewRotEntry
        $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
        function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $true }
        function script:Get-TcProgIdIdeInfo { [CmdletBinding()] param([string]$ProgId) [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = '3.1.4026.22'; xaeBuild = 4026 } }
        function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() [PSCustomObject]@{ installedBuild = 4026; remoteManagerBuilds = @('4026.22') } }
        function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) $null }
        function script:New-TcIdeInstance {
            [CmdletBinding()] param([string]$ProgId)
            [void]$global:Launches73.Add($ProgId)
            $pidNew = $global:NextPid73; $global:NextPid73++
            $global:Procs73[$pidNew] = [DateTime]::Now
            $o = & $script:UnitNewFakeDte
            $global:LaunchedDtes73[$pidNew] = $o
            if ($global:LaunchInRot73) { $global:Rot73 = @($global:Rot73) + @(& $script:UnitNewRotEntry $pidNew $o $ProgId) }
            $o
        }
        function script:Get-TcIdeProcessId {
            [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
            if ($KnownPid -gt 0) { return @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = 'known-pid' } }
            if ($global:GuessPid73 -gt 0 -and $null -ne $StartedAfter) { return @{ ProcessId = $global:GuessPid73; MainHwnd = [long]0; Source = 'start-time' } }
            @{ ProcessId = 0; MainHwnd = [long]0; Source = '' }
        }
        function script:Get-Process {
            [CmdletBinding()] param([int]$Id, [string]$Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return @($global:Procs73.Keys | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $Name; ProcessName = $Name; StartTime = $global:Procs73[$_] } })
            }
            if ($Id -ge 9000 -and $Id -lt 10000 -and $Id -ne $PID) {   # fake pids only (the real $PID may be larger)
                if ($global:Procs73.ContainsKey($Id)) {
                    $n = if ($global:Names73.ContainsKey($Id)) { $global:Names73[$Id] } else { 'TcXaeShell' }
                    return [PSCustomObject]@{ Id = $Id; ProcessName = $n; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs73[$Id] }
                }
                if ($ErrorActionPreference -eq 'SilentlyContinue') { return $null }
                throw "Cannot find a process with the process identifier $Id."
            }
            Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
        }
        function script:Find-TcIdeModalDialog {
            [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5)
            $mode = $global:Modal73
            if ($global:ModalQueue73.Count -gt 0) { $mode = $global:ModalQueue73[0]; $global:ModalQueue73.RemoveAt(0) }
            $p = if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:TcIdeProcessId }
            switch ($mode) {
                'incomplete' { return (New-TcModalScanIncomplete -ProcessId $p -Reason 'timeout' -TimeoutSec 5 -Message 'mock: cold start') }
                'dialog' { return @{ Title = 'Microsoft Visual Studio'; Text = 'mock dialog'; Hwnd = 0; Buttons = @() } }
                default { return $null }
            }
        }
        function script:Stop-TcLaunchedIde { [CmdletBinding()] param([object]$Dte, [string]$ProgId, [DateTime]$StartedAfter) [void]$global:Kills73.Add("Stop-TcLaunchedIde $ProgId"); , @() }
        function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) [void]$global:Kills73.Add("Stop-Process $Id"); $global:Procs73.Remove($Id) }
        function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot73 }
        function script:Invoke-TcComRetry {
            [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
            if ($OperationName -like 'Read DTE.Version / Solution.FullName*') {
                $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
                if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
            }
            & $script:UnitOrigComRetry @PSBoundParameters
        }
        # #29 evidence is mocked: strong hit on the first blocked candidate when $global:Blocked73
        function script:Find-TcBlockedSolutionIde {
            [CmdletBinding()] param([object[]]$Candidates, [string]$SolutionPath, [int]$PreviousProcessId, [object]$PreviousStartTime, [string]$PreviousSolution, [string[]]$KnownSolutions)
            if (-not $global:Blocked73 -or @($Candidates).Count -eq 0) { return @() }
            , @([PSCustomObject]@{ Candidate = @($Candidates)[0]; Strong = $true; MatchedBy = 'session-record'; Dialog = $null; WindowTitle = 's4026 - TcXaeShell'; Contradiction = $null; CorroboratedBy = 'window-title' })
        }
    } ${function:New-FakeDte} ${function:New-RotEntry}
}

function Reset-All {
    $global:Rot73 = @(); $global:Launches73.Clear(); $global:LaunchedDtes73 = @{}; $global:Procs73 = @{}; $global:Names73 = @{}
    $global:Modal73 = 'incomplete'; $global:ModalQueue73.Clear(); $global:LaunchInRot73 = $true; $global:GuessPid73 = 0; $global:Kills73.Clear(); $global:Quits73 = 0; $global:Blocked73 = $false
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Restart-Module
}
function Get-RecordFile { Join-Path $env:TCAUTO_STATE_DIR 'launched-ides.json' }
function Read-Records { $f = Get-RecordFile; if (-not (Test-Path -LiteralPath $f)) { return @() }; @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
# Rewrites every record of the file with -Change { param($r) ... } (simulates another writer).
function Edit-Records([scriptblock]$Change) {
    $recs = @(Read-Records)
    foreach ($r in $recs) { & $Change $r }
    Set-Content -LiteralPath (Get-RecordFile) -Value (ConvertTo-Json -InputObject @($recs) -Depth 3) -Encoding UTF8
}
# Another TcAuto session (bridge) that is still running: fake pid 9600.
$global:OtherHostStart73 = [DateTime]'2026-11-06T08:00:00'
function Set-OtherHost { $global:Procs73[9600] = $global:OtherHostStart73; Edit-Records { param($r) $r.hostPid = 9600; $r.hostStartTime = $global:OtherHostStart73.ToUniversalTime().ToString('o') } }
# The launched IDE now answers in the ROT with -Solution open.
function Show-OwnInRot([int]$ProcId, [string]$Solution) {
    $o = $global:LaunchedDtes73[$ProcId]; $o.Solution.FullName = $Solution
    $global:Rot73 = @(New-RotEntry $ProcId $o)
}
# Cold start: launches one IDE, the first Connect-TcIde answers MODAL_SCAN_INCOMPLETE (owned).
function Start-OwnIde { $r = Connect-TcIde -SolutionPath $sln; [PSCustomObject]@{ Result = $r; Pid = [int]$r.data.ideProcessId } }

Restart-Module
$slnL = & $mod { param($x) Get-TcLongPath $x } $sln

try {
    # --- R: restart restores ownership ---
    Reset-All
    $first = Start-OwnIde
    $oldInstance = & $mod { $script:TcModuleInstanceId }
    $recs = @(Read-Records)
    Check 'R1 launch persisted: pid, UTC start time, image name, ProgId, solution, pidSource rot-identity, instance id' ($first.Result.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $recs.Count -eq 1 -and [int]$recs[0].pid -eq $first.Pid -and $recs[0].imageName -eq 'TcXaeShell' -and $recs[0].progId -eq 'TcXaeShell.DTE.17.0' -and $recs[0].solution -eq $slnL -and $recs[0].pidSource -eq 'rot-identity' -and $recs[0].moduleInstanceId -eq $oldInstance -and [int]$recs[0].hostPid -eq $PID -and $null -ne $recs[0].hostStartTime -and [string]$recs[0].startTime -match 'Z$|[+-]\d\d:\d\d$' -and $null -ne $recs[0].createdAt -and $null -ne $recs[0].launchId) ($recs | ConvertTo-Json -Compress)
    Restart-Module
    $mem = & $mod { "$($script:TcModuleInstanceId)|$(if ($null -eq $script:TcLaunchedIdes) { 0 } else { $script:TcLaunchedIdes.Count })|$(if ($null -eq $script:TcLaunchedIdeSolutions) { 0 } else { $script:TcLaunchedIdeSolutions.Count })" }
    Check 'R2 restart: new module instance, empty memory' ($mem -notlike "$oldInstance|*" -and $mem -like '*|0|0') $mem
    $r = Connect-TcIde -SolutionPath $sln   # ROT empty: still starting
    Check 'R3 #149 after restart: no second IDE for the same .sln (IDE_LAUNCH_PENDING, owned)' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $global:Launches73.Count -eq 1 -and [int]$r.data.ideProcessId -eq $first.Pid -and $r.data.ownedBySession -eq $true) "code=$($r.error.code) launches=$($global:Launches73.Count) pid=$($r.data.ideProcessId) owned=$($r.data.ownedBySession)"
    Restart-Module
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R4 #73 after restart: solution-match attach of the own IDE is ownedBySession' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.selectedBy -eq 'solution-match' -and $r.data.ownedBySession -eq $true -and [int]$r.data.ideProcessId -eq $first.Pid -and $global:Launches73.Count -eq 1) "code=$($r.error.code) sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession)"
    $d = Disconnect-TcIde -Quit -Kill
    Check 'R5 Disconnect-TcIde -Quit -Kill after the restart kills the own IDE' ($d.success -and $d.data.killed -eq $true -and $d.data.ownedBySession -eq $true -and ($global:Kills73 -contains "Stop-Process $($first.Pid)")) "code=$($d.error.code) killed=$($d.data.killed) kills=$($global:Kills73 -join ',')"
    Check 'R6 record removed after the kill' (@(Read-Records).Count -eq 0) (@(Read-Records) | ConvertTo-Json -Compress)
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    Show-OwnInRot $first.Pid ''
    [void]$global:ModalQueue73.Add('none'); [void]$global:ModalQueue73.Add('dialog')
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R7 after restart the own IDE (empty solution) is attached session-launched, owned, no second launch' ($r.data.selectedBy -eq 'session-launched' -and $r.data.ownedBySession -eq $true -and $global:Launches73.Count -eq 1) "code=$($r.error.code) sel=$($r.data.selectedBy) launches=$($global:Launches73.Count)"

    # --- P: pid reuse ---
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    $global:Procs73[$first.Pid] = [DateTime]'2026-11-06T11:11:11'
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'P1 same pid, other start time -> not owned' ($r.data.selectedBy -eq 'solution-match' -and $r.data.ownedBySession -eq $false) "sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession)"
    $d = Disconnect-TcIde -Quit -Kill
    Check 'P2 -Kill refused for the recycled pid (IDE_NOT_OWNED), nothing killed' ($d.error.code -eq 'IDE_NOT_OWNED' -and $global:Kills73.Count -eq 0) "code=$($d.error.code) kills=$($global:Kills73 -join ',')"
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    $global:Names73[$first.Pid] = 'notepad'
    $global:Rot73 = @()
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    $r = Connect-TcIde -SolutionPath $sln
    Check 'P3 same pid and start time, other image name -> not owned, guard released (a new launch)' ($own -eq $false -and $global:Launches73.Count -eq 2 -and $r.error.code -ne 'IDE_LAUNCH_PENDING') "owned=$own launches=$($global:Launches73.Count) code=$($r.error.code)"
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    $global:Procs73.Remove($first.Pid); $global:Rot73 = @()
    $r = Connect-TcIde -SolutionPath $sln
    Check 'P4 own IDE gone after the restart -> record ignored, one new launch' ($global:Launches73.Count -eq 2) "launches=$($global:Launches73.Count) code=$($r.error.code)"

    # --- F: corrupt / unreadable record file ---
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    Set-Content -LiteralPath (Get-RecordFile) -Value '[{"pid": 9001, "startTime": ' -Encoding UTF8
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    Check 'F1 corrupt file -> the IDE is not owned' ($own -eq $false) "owned=$own"
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'F2 corrupt file does not block the normal attach (solution-match, not owned)' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.selectedBy -eq 'solution-match' -and [int]$r.data.ideProcessId -eq $first.Pid -and $r.data.ownedBySession -eq $false) "code=$($r.error.code) sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession)"
    $d = Disconnect-TcIde -Quit -Kill
    Check 'F3 corrupt file: -Kill refused (IDE_NOT_OWNED), nothing killed' ($d.error.code -eq 'IDE_NOT_OWNED' -and $global:Kills73.Count -eq 0) "code=$($d.error.code)"
    $null = Disconnect-TcIde
    $global:Rot73 = @(); $global:Modal73 = 'incomplete'
    $r = Connect-TcIde -SolutionPath $sln
    $aside = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json.corrupt-*')
    Check 'F4 corrupt file: Connect-TcIde does not throw / is not blocked; the next write moves the corrupt file aside' ($global:Launches73.Count -eq 2 -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $aside.Count -eq 1 -and @(Read-Records).Count -eq 1) "launches=$($global:Launches73.Count) code=$($r.error.code) aside=$($aside.Count)"
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    $lock = [IO.File]::Open((Get-RecordFile), 'Open', 'ReadWrite', 'None')
    try {
        $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
        $warn = & $mod { $script:TcLaunchRecordWarning }
        $global:Rot73 = @()
        $r = Connect-TcIde -SolutionPath $sln -NoLaunch
    }
    finally { $lock.Dispose() }
    Check 'F5 unreadable file (held open) -> not owned, warning set, Connect-TcIde answers normally' ($own -eq $false -and $warn -match 'unreadable' -and $r.error.code -eq 'IDE_NOT_FOUND') "owned=$own warn=$warn code=$($r.error.code)"
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    Check 'F6 the file is readable again -> ownership restored' ($own -eq $true) "owned=$own"

    # --- U: pid-unconfirmed ---
    Reset-All
    $global:LaunchInRot73 = $false; $global:GuessPid73 = 9777; $global:Procs73[9777] = [DateTime]::Now
    $r = Connect-TcIde -SolutionPath $sln
    $recs = @(Read-Records)
    Check 'U1 unconfirmed launch persisted as pid-unconfirmed (guessed pid), not owned' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.ownedBySession -eq $false -and $recs.Count -eq 1 -and $recs[0].pidSource -eq 'pid-unconfirmed' -and [int]$recs[0].pid -eq 9777) ($recs | ConvertTo-Json -Compress)
    Restart-Module
    & $mod { $script:TcLaunchPendingWaitSec = 10 }
    $own = & $mod { Test-TcLaunchedIde -ProcessId 9777 }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Connect-TcIde -SolutionPath $sln
    $sw.Stop()
    Check 'U2 after restart: pid-unconfirmed record never restores ownership, but no second launch' ($own -eq $false -and $r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.probe -eq 'pid-unconfirmed' -and $r.data.ownedBySession -eq $false -and [int]$r.data.ideProcessId -eq 0 -and $global:Launches73.Count -eq 1) "owned=$own code=$($r.error.code) probe=$($r.data.probe) launches=$($global:Launches73.Count)"
    Check 'U2b m2: restored unconfirmed record answers at once (no 10 s wait), guessed pid only in data.guessedProcessId' ($sw.Elapsed.TotalSeconds -lt 5 -and [double]$r.data.waitedSec -lt 1 -and [int]$r.data.guessedProcessId -eq 9777) "sec=$([math]::Round($sw.Elapsed.TotalSeconds,1)) waited=$($r.data.waitedSec) guessed=$($r.data.guessedProcessId)"
    $global:Procs73[9777] = [DateTime]'2026-11-06T06:06:06'   # guessed pid recycled
    $r = Connect-TcIde -SolutionPath $sln -NoLaunch
    $global:Procs73[9777] = [DateTime]::Now
    Check 'U2c m2: expiry of a restored unconfirmed record = the file pid + start time (recycled -> released)' ($r.error.code -eq 'IDE_NOT_FOUND') "code=$($r.error.code)"
    Reset-All
    $global:LaunchInRot73 = $false; $global:GuessPid73 = 9777; $global:Procs73[9777] = [DateTime]::Now
    $null = Connect-TcIde -SolutionPath $sln
    Restart-Module
    Restart-Module
    $global:Rot73 = @(New-RotEntry 9777 (New-FakeDte $slnL)); $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'U3 the guessed-pid IDE with the solution is attached by solution-match but not owned' ($r.data.selectedBy -eq 'solution-match' -and [int]$r.data.ideProcessId -eq 9777 -and $r.data.ownedBySession -eq $false) "sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession)"
    $d = Disconnect-TcIde -Quit -Kill
    Check 'U4 -Kill refused for it (IDE_NOT_OWNED), nothing killed' ($d.error.code -eq 'IDE_NOT_OWNED' -and $global:Kills73.Count -eq 0) "code=$($d.error.code)"
    $null = Disconnect-TcIde
    Restart-Module
    $fg = Disconnect-TcIde -ForgetPendingLaunch
    Check 'U5 -ForgetPendingLaunch after a restart clears the persisted pid-unconfirmed record' ($fg.success -and @($fg.data.forgottenLaunches).Count -eq 1 -and @($fg.data.forgottenLaunches)[0].persisted -eq $true -and @(Read-Records).Count -eq 0) ($fg | ConvertTo-Json -Compress -Depth 4)
    $global:Rot73 = @(); $global:LaunchInRot73 = $true; $global:GuessPid73 = 0; $global:Modal73 = 'incomplete'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'U6 after forgetting, the next Connect-TcIde may launch again' ($global:Launches73.Count -eq 2) "launches=$($global:Launches73.Count) code=$($r.error.code)"

    # --- Q: -Quit clears the record ---
    Reset-All
    $first = Start-OwnIde
    Restart-Module
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $null = Connect-TcIde -SolutionPath $sln
    $global:Modal73 = 'none'
    $d = Disconnect-TcIde -Quit
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    Check 'Q1 Disconnect-TcIde -Quit (success) removes the launch record' ($d.success -and $d.data.quit -eq $true -and $global:Quits73 -eq 1 -and @(Read-Records).Count -eq 0 -and $own -eq $false) "code=$($d.error.code) quit=$($d.data.quit) records=$(@(Read-Records).Count) owned=$own"

    $lock = $null
    try {
        Reset-All
        $first = Start-OwnIde
        Restart-Module
        Show-OwnInRot $first.Pid $slnL
        $global:Modal73 = 'dialog'
        $null = Connect-TcIde -SolutionPath $sln
        $global:Modal73 = 'none'
        $lock = [IO.File]::Open((Get-RecordFile), 'Open', 'ReadWrite', 'None')
        $d = Disconnect-TcIde -Quit
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
    Check 'Q2 Disconnect-TcIde -Quit while the record file is held open -> success with data.launchRecordWarning' ($d.success -and $d.data.quit -eq $true -and -not [string]::IsNullOrWhiteSpace([string]$d.data.launchRecordWarning)) "code=$($d.error.code) warn=$($d.data.launchRecordWarning)"

    # --- X: #152 M1, another TcAuto session that is still running ---
    Reset-All
    $first = Start-OwnIde
    Set-OtherHost
    Restart-Module
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    $r = Connect-TcIde -SolutionPath $sln
    Check 'X1 record of another live session: not owned, but no second IDE (IDE_LAUNCH_PENDING other-session)' ($own -eq $false -and $r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.probe -eq 'other-session' -and $r.data.ownedBySession -eq $false -and $r.data.launchedBySession -eq $false -and [int]$r.data.ideProcessId -eq 0 -and [int]$r.data.otherSession.hostPid -eq 9600 -and $global:Launches73.Count -eq 1) "owned=$own code=$($r.error.code) probe=$($r.data.probe) launches=$($global:Launches73.Count)"
    $d0 = Disconnect-TcIde -Quit -Kill
    Check 'X2 nothing of the other session is kept for -Kill (not connected, nothing killed)' ($global:Kills73.Count -eq 0 -and $d0.data.reason -eq 'not connected') "code=$($d0.error.code) reason=$($d0.data.reason)"
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    $d = Disconnect-TcIde -Quit -Kill
    Check 'X3 its IDE attached by solution-match is not owned; -Kill refused (IDE_NOT_OWNED), nothing killed' ($r.data.selectedBy -eq 'solution-match' -and $r.data.ownedBySession -eq $false -and $d.error.code -eq 'IDE_NOT_OWNED' -and $global:Kills73.Count -eq 0 -and $global:Launches73.Count -eq 1) "sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession) code=$($d.error.code)"
    $null = Disconnect-TcIde
    $global:Procs73.Remove(9600)   # that session ended
    Restart-Module
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    $recs = @(Read-Records)
    Check 'X4 host process gone -> the record is adopted (hostPid = this process) and owned' ($own -eq $true -and $recs.Count -eq 1 -and [int]$recs[0].hostPid -eq $PID) "owned=$own host=$($recs[0].hostPid)"
    $global:Procs73[9600] = $global:OtherHostStart73.AddHours(1)   # pid 9600 reused by another process
    Edit-Records { param($r) $r.hostPid = 9600; $r.hostStartTime = $global:OtherHostStart73.ToUniversalTime().ToString('o') }
    Restart-Module
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    Check 'X5 host pid recycled (other start time) counts as gone -> owned' ($own -eq $true) "owned=$own"
    Reset-All
    $global:LaunchInRot73 = $false; $global:GuessPid73 = 9777; $global:Procs73[9777] = [DateTime]::Now
    $null = Connect-TcIde -SolutionPath $sln
    Set-OtherHost
    Restart-Module
    $fg = Disconnect-TcIde -ForgetPendingLaunch
    Check 'X6 -ForgetPendingLaunch keeps the unconfirmed record of another live session' ($fg.success -and @($fg.data.forgottenLaunches).Count -eq 0 -and @($fg.data.otherSessionLaunches).Count -eq 1 -and @(Read-Records).Count -eq 1) ($fg | ConvertTo-Json -Compress -Depth 4)

    # --- M: m1, an unconfirmed write never replaces a confirmed record ---
    Reset-All
    $first = Start-OwnIde
    $lid = [string]@(Read-Records)[0].launchId
    $null = & $mod { param($p, $s) Save-TcLaunchRecord -LaunchId ([guid]::NewGuid().ToString('N')) -ProcessId $p -PidSource 'start-time' -ProgId 'TcXaeShell.DTE.17.0' -Solution $s } $first.Pid $slnL
    $null = & $mod { param($p, $s, $l) Save-TcLaunchRecord -LaunchId $l -ProcessId $p -PidSource 'start-time' -ProgId 'TcXaeShell.DTE.17.0' -Solution $s } $first.Pid $slnL $lid
    $recs = @(Read-Records)
    Check 'M1 unconfirmed save (same pid / same launch) does not replace the confirmed record' ($recs.Count -eq 1 -and $recs[0].pidSource -eq 'rot-identity' -and [string]$recs[0].launchId -eq $lid) ($recs | ConvertTo-Json -Compress)
    $null = & $mod { param($p, $s) Save-TcLaunchRecord -LaunchId ([guid]::NewGuid().ToString('N')) -ProcessId $p -PidSource 'main-window' -ProgId 'TcXaeShell.DTE.17.0' -Solution $s } $first.Pid $slnL
    $recs = @(Read-Records)
    Check 'M2 a confirmed save of the same pid replaces it (one record per process)' ($recs.Count -eq 1 -and $recs[0].pidSource -eq 'main-window' -and [string]$recs[0].launchId -ne $lid) ($recs | ConvertTo-Json -Compress)
    $global:Names73[9888] = 'notepad'; $global:Procs73[9888] = [DateTime]::Now
    $null = & $mod { Save-TcLaunchRecord -LaunchId 'n3' -ProcessId 9888 -PidSource 'rot-identity' -ProgId 'TcXaeShell.DTE.17.0' -Solution $null }
    Check 'M3 n3: a process that is not an IDE image is never recorded' (@(Read-Records | Where-Object { [int]$_.pid -eq 9888 }).Count -eq 0) ''

    # --- J: JSON that parses but has the wrong shape ---
    Reset-All
    $first = Start-OwnIde
    $good = @(Read-Records)[0]
    $bad = @([PSCustomObject]@{ pid = 'abc'; startTime = 5 }, 42, 'text', [PSCustomObject]@{ pid = $first.Pid }, [PSCustomObject]@{ pid = $first.Pid; startTime = 'not a date'; imageName = 'TcXaeShell'; pidSource = 'rot-identity'; hostPid = $PID })
    Set-Content -LiteralPath (Get-RecordFile) -Value (ConvertTo-Json -InputObject $bad -Depth 3) -Encoding UTF8
    Restart-Module
    $own = & $mod { param($p) Test-TcLaunchedIde -ProcessId $p } $first.Pid
    Show-OwnInRot $first.Pid $slnL
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'J1 wrong-shape records restore nothing; the attach works (not owned)' ($own -eq $false -and $r.data.selectedBy -eq 'solution-match' -and $r.data.ownedBySession -eq $false) "owned=$own sel=$($r.data.selectedBy)"
    $null = Disconnect-TcIde
    Set-Content -LiteralPath (Get-RecordFile) -Value '{"pid": 1}' -Encoding UTF8
    $null = & $mod { param($g) Update-TcLaunchRecordFile -Mutate { param($all) @($all) + @($g) } } $good
    $recs = @(Read-Records)
    Check 'J2 the next write drops the malformed records and keeps the valid one' ($recs.Count -eq 1 -and [string]$recs[0].launchId -eq [string]$good.launchId) ($recs | ConvertTo-Json -Compress)
    Edit-Records { param($r) }
    $global:Procs73.Remove($first.Pid)
    $null = & $mod { Update-TcLaunchRecordFile -Mutate { param($all) $all } }
    Check 'J3 m3: cleanup drops a record whose process is gone' (@(Read-Records).Count -eq 0) ''

    # --- B: #29 solution-blocked -> launched ---
    foreach ($foreign in @($false, $true)) {
        Reset-All
        $first = Start-OwnIde
        Edit-Records { param($r) $r.solution = $null }   # released: the #29 path decides
        if ($foreign) { Set-OtherHost }
        Restart-Module
        $o = $global:LaunchedDtes73[$first.Pid]; $o.Busy = $true
        $global:Rot73 = @(New-RotEntry $first.Pid $o)
        $global:Blocked73 = $true
        $r = Connect-TcIde -SolutionPath $sln
        if (-not $foreign) {
            Check 'B1 blocked own IDE after a restart (strong #29 evidence) -> attached as launched, owned' ($r.error.code -eq 'IDE_BUSY' -and $r.data.attached -eq $true -and $r.data.launchedBySession -eq $true -and $r.data.ownedBySession -eq $true -and $global:Launches73.Count -eq 1) "code=$($r.error.code) owned=$($r.data.ownedBySession) launched=$($r.data.launchedBySession)"
        }
        else {
            Check 'B2 blocked IDE of another live session -> solution-blocked, not owned, no second launch' ($r.error.code -eq 'IDE_BUSY' -and $r.data.launchedBySession -eq $false -and $r.data.ownedBySession -eq $false -and $global:Launches73.Count -eq 1 -and (& $mod { $script:TcIdeSelectedBy }) -eq 'solution-blocked') "code=$($r.error.code) owned=$($r.data.ownedBySession)"
        }
        $null = Disconnect-TcIde
    }

    # --- C: two processes write the file at the same time (mutex) ---
    Reset-All
    $child = Join-Path $root 'writer-73.ps1'
    Set-Content -LiteralPath $child -Encoding UTF8 -Value @'
param([string]$Name, [int]$HostPid, [string]$HostStart, [string]$ModPath)
Import-Module $ModPath -Force -WarningAction SilentlyContinue
$m = Get-Module TwinCATAutomation
& $m {
    param($n, $hp, $hs)
    $script:TcLaunchRecordLockTimeoutMs = 30000
    for ($i = 0; $i -lt 10; $i++) {
        $id = "$n-$i"
        $f = Update-TcLaunchRecordFile -Mutate { param($all) @($all) + @([PSCustomObject]@{ launchId = $id; pid = $hp; startTime = $hs; imageName = 'powershell'; pidSource = 'pid-unconfirmed'; hostPid = $hp; hostStartTime = $hs }) }
        if ($f) { "FAIL $f" }
    }
} $Name $HostPid $HostStart
'@
    $myStart = (Microsoft.PowerShell.Management\Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $procs = @('A', 'B') | ForEach-Object {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-File', "`"$child`"", '-Name', $_, '-HostPid', $PID, '-HostStart', $myStart, '-ModPath', "`"$((Resolve-Path $modPath).Path)`"") -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root "writer-73-$_.out")
    }
    $procs | ForEach-Object { $_.WaitForExit(120000) | Out-Null }
    $ids = @(Read-Records | ForEach-Object { [string]$_.launchId })
    $outs = (@('A', 'B') | ForEach-Object { Get-Content -LiteralPath (Join-Path $root "writer-73-$_.out") -Raw -ErrorAction SilentlyContinue }) -join ' '
    Check 'C1 two processes writing at once (named mutex): no record lost' ($ids.Count -eq 20 -and @($ids | Sort-Object -Unique).Count -eq 20 -and $outs -notmatch 'FAIL') "records=$($ids.Count) out=$outs"

    Check 'E1 nothing real was killed (Stop-Process is the mock; only R5 used it)' (@($global:Kills73 | Where-Object { $_ -notlike 'Stop-Process 90*' }).Count -eq 0) ($global:Kills73 -join ', ')
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Launches73, LaunchedDtes73, NextPid73, Procs73, Names73, Rot73, LaunchInRot73, GuessPid73, Modal73, ModalQueue73, Kills73, Quits73, Blocked73, OtherHostStart73 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
