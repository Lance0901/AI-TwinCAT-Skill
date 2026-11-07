# Unit: #196 Connect-TcIde -TakeOverOrphan - an IDE launched by another TcAuto session whose host
# process is gone can be taken over explicitly, and only when every condition holds. No IDE needed.
# The mocks are those of launch-record-persist-73.ps1 (ROT, launch, pid lookup, Get-Process of the
# fake pids, modal scan, Stop-Process); nothing real is launched, touched or killed.
#   T1  success: attached, owned, record owner rewritten + takeovers[] history, -Quit -Kill allowed
#   T2  host alive -> ORPHAN_TAKEOVER_REFUSED host-alive, record unchanged
#   T3  solution mismatch / no record for the solution / no -SolutionPath -> refused
#   T4  pid-unconfirmed record -> refused
#   T5  modal dialog / incomplete scan -> IDE_MODAL_DIALOG / MODAL_SCAN_INCOMPLETE, not taken over
#   T6  without -TakeOverOrphan: unchanged (IDE_LAUNCH_PENDING other-session); gone -> message
#       'has ended' + hint names -TakeOverOrphan; alive -> no such hint
#   T7  record file cannot be written / read -> LAUNCH_RECORD_UNAVAILABLE (fail closed)
#   T8  own record (hostState self) / -ProgId mismatch / IDE not in the ROT / busy -> refused
#   powershell.exe -NoProfile -File tests/Unit/orphan-takeover-196.ps1
# Exit code = number of failed checks.
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# #152 N1: the MCP server passes its owner id to the bridge; this process plays that bridge
$env:TCAUTO_OWNER_ID = 'owner-73-A'
$modPath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-196-{0}" -f [guid]::NewGuid().ToString('N'))
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
$global:NextName73 = $null       # process name of the next launched IDE (default TcXaeShell)

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
            if ($null -ne $global:NextName73) { $global:Names73[$pidNew] = $global:NextName73 }
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
    # #196: a successful attach goes on to the ITcSysManager / platform reads: answered at once
    & $script:mod {
        function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $o = New-Object PSObject; $o | Add-Member ScriptMethod GetTargetNetId { '5.6.7.8.1.1' }; $script:TcSysManager = $o; $o }
        function script:Get-TcSolutionPlatform { [CmdletBinding()] param() [PSCustomObject]@{ platform = 'TwinCAT RT (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT RT (x64)' } }
        function script:Save-TcIdeTargetNetId { param($AmsNetId) }
    }
}

function Reset-All {
    $global:Rot73 = @(); $global:Launches73.Clear(); $global:LaunchedDtes73 = @{}; $global:Procs73 = @{}; $global:Names73 = @{}
    $global:Modal73 = 'incomplete'; $global:ModalQueue73.Clear(); $global:LaunchInRot73 = $true; $global:GuessPid73 = 0; $global:Kills73.Clear(); $global:Quits73 = 0; $global:Blocked73 = $false; $global:NextName73 = $null
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Restart-Module
}
function Get-RecordFile { Join-Path $env:TCAUTO_STATE_DIR 'launched-ides.json' }
function Read-Records { $f = Get-RecordFile; if (-not (Test-Path -LiteralPath $f)) { return @() }; @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
function Edit-Records([scriptblock]$Change) {
    $recs = @(Read-Records)
    foreach ($r in $recs) { & $Change $r }
    Set-Content -LiteralPath (Get-RecordFile) -Value (ConvertTo-Json -InputObject @($recs) -Depth 4) -Encoding UTF8
}
# The TcAuto session (bridge) that launched the IDE: fake pid 9600, owner id of another MCP server.
$global:OtherHostStart73 = [DateTime]'2026-11-06T08:00:00'
function Set-OtherOwner { Edit-Records { param($r) $r.hostPid = 9600; $r.hostStartTime = $global:OtherHostStart73.ToUniversalTime().ToString('o'); $r.ownerId = 'owner-196-B' } }
function Show-InRot([int]$ProcId, [string]$Solution) {
    $o = $global:LaunchedDtes73[$ProcId]; $o.Solution.FullName = $Solution
    $global:Rot73 = @(New-RotEntry $ProcId $o)
}
# An IDE launched by this module (cold start, MODAL_SCAN_INCOMPLETE) whose record is then made the
# record of an ENDED session (host 9600 not running, other ownerId) in a new module instance.
function New-Orphan {
    param([switch]$HostAlive, [AllowNull()][string]$RotSolution = $script:slnL, [switch]$NotInRot)
    Reset-All
    $r = Connect-TcIde -SolutionPath $sln
    $p = [int]$r.data.ideProcessId
    Set-OtherOwner
    if ($HostAlive) { $global:Procs73[9600] = $global:OtherHostStart73 } else { $global:Procs73.Remove(9600) }
    Restart-Module
    if ($NotInRot) { $global:Rot73 = @() } else { Show-InRot $p $RotSolution }
    $global:Modal73 = 'none'
    $p
}
function Get-RecordJson { Get-Content -LiteralPath (Get-RecordFile) -Raw }
function Test-NotConnected { -not (& $mod { [bool]$script:TcIdeConnected }) -and $null -eq (& $mod { $script:TcDte }) }

Restart-Module
$slnL = & $mod { param($x) Get-TcLongPath $x } $sln
$slnY = Join-Path $slnDir 'other-196.sln'
Set-Content -LiteralPath $slnY -Value '' -Encoding UTF8
$slnYL = & $mod { param($x) Get-TcLongPath $x } $slnY

try {
    # --- T1: success ---
    $p = New-Orphan
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $recs = @(Read-Records)
    $tk = @($recs[0].takeovers)
    Check 'T1 taken over: success, selectedBy orphan-takeover, takenOver, owned, previousOwner = ended host' ($r.success -and $r.data.selectedBy -eq 'orphan-takeover' -and $r.data.takenOver -eq $true -and $r.data.ownedBySession -eq $true -and [int]$r.data.ideProcessId -eq $p -and [int]$r.data.previousOwner.hostPid -eq 9600 -and $r.data.previousOwner.ownerId -eq 'owner-196-B' -and $r.data.previousOwner.hostState -eq 'gone' -and $global:Launches73.Count -eq 1) "code=$($r.error.code) msg=$($r.error.message) sel=$($r.data.selectedBy) owned=$($r.data.ownedBySession)"
    Check 'T1b record owner = this process (hostPid, ownerId, moduleInstanceId) + one takeovers[] entry with the previous owner' ($recs.Count -eq 1 -and [int]$recs[0].hostPid -eq $PID -and $recs[0].ownerId -eq 'owner-73-A' -and $recs[0].moduleInstanceId -eq (& $mod { $script:TcModuleInstanceId }) -and $tk.Count -eq 1 -and [int]$tk[0].previousHostPid -eq 9600 -and $tk[0].previousOwnerId -eq 'owner-196-B' -and $tk[0].reason -eq 'orphan-takeover' -and [int]$tk[0].hostPid -eq $PID -and -not [string]::IsNullOrWhiteSpace([string]$tk[0].takenOverAt) -and -not [string]::IsNullOrWhiteSpace([string]$tk[0].previousHostStartTime)) ((Get-RecordJson) -replace '\s+', ' ')
    $global:Modal73 = 'dialog'
    $d = Disconnect-TcIde -Quit -Kill
    Check 'T1c afterwards Disconnect-TcIde -Quit -Kill treats it as owned (killed)' ($d.success -and $d.data.ownedBySession -eq $true -and $d.data.killed -eq $true -and @($global:Kills73 | Where-Object { $_ -eq "Stop-Process $p" }).Count -eq 1) "code=$($d.error.code) owned=$($d.data.ownedBySession) kills=$($global:Kills73 -join ',')"
    # a second takeover appends to the history
    $p = New-Orphan
    $null = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $null = Disconnect-TcIde
    Set-OtherOwner
    $global:Procs73.Remove(9600)
    Restart-Module
    Show-InRot $p $slnL
    $global:Modal73 = 'none'
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T1d a second takeover keeps the first in takeovers[] (2 entries)' ($r.success -and $r.data.takenOver -eq $true -and @(@(Read-Records)[0].takeovers).Count -eq 2) ((Get-RecordJson) -replace '\s+', ' ')
    $null = Disconnect-TcIde

    # --- T2: host alive ---
    $p = New-Orphan -HostAlive
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T2 host alive -> ORPHAN_TAKEOVER_REFUSED host-alive, otherSession carried, record unchanged, not connected' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'host-alive' -and $r.data.takenOver -eq $false -and $r.data.otherSession.hostState -eq 'alive' -and [int]$r.data.otherSession.hostPid -eq 9600 -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and $global:Launches73.Count -eq 1) "code=$($r.error.code) reason=$($r.data.reason)"
    $global:Procs73[9600] = $global:OtherHostStart73.AddHours(1)   # pid 9600 reused by another process
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T2b host pid reused by another process (other start time) counts as gone -> taken over' ($r.success -and $r.data.takenOver -eq $true) "code=$($r.error.code) reason=$($r.data.reason)"
    $null = Disconnect-TcIde

    # --- T3: solution mismatch / no record / no -SolutionPath ---
    $p = New-Orphan -RotSolution $slnYL
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T3 IDE has another solution open in the ROT -> refused solution-mismatch, record unchanged' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'solution-mismatch' -and $r.data.rotSolution -eq $slnYL -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"
    $r = Connect-TcIde -SolutionPath $slnY -TakeOverOrphan
    Check 'T3b no launch record for that solution -> refused no-launch-record (no other path taken)' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'no-launch-record' -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and $global:Launches73.Count -eq 1) "code=$($r.error.code) reason=$($r.data.reason)"
    $r = Connect-TcIde -TakeOverOrphan
    Check 'T3c -TakeOverOrphan without -SolutionPath -> refused solution-path-required' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'solution-path-required' -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"

    # --- T4: pid-unconfirmed ---
    Reset-All
    $global:LaunchInRot73 = $false; $global:GuessPid73 = 9777; $global:Procs73[9777] = [DateTime]::Now
    $null = Connect-TcIde -SolutionPath $sln
    Set-OtherOwner
    $global:Procs73.Remove(9600)
    Restart-Module
    $o = New-FakeDte $slnL
    $global:Rot73 = @(New-RotEntry 9777 $o)
    $global:Modal73 = 'none'
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T4 pid-unconfirmed record -> refused pid-unconfirmed, record unchanged, nothing launched' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'pid-unconfirmed' -and $r.data.otherSession.pidSource -eq 'pid-unconfirmed' -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and $global:Launches73.Count -eq 1) "code=$($r.error.code) reason=$($r.data.reason)"

    # --- T5: modal dialog / incomplete scan ---
    $p = New-Orphan
    $before = Get-RecordJson
    $global:Modal73 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T5 modal dialog -> IDE_MODAL_DIALOG, takenOver false, record unchanged, not connected' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.takenOver -eq $false -and $r.data.reason -eq 'modal-dialog' -and $null -ne $r.data.dialog -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"
    $global:Modal73 = 'incomplete'
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T5b incomplete modal scan -> MODAL_SCAN_INCOMPLETE, not taken over' ($r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.data.takenOver -eq $false -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code)"

    # --- T6: without -TakeOverOrphan nothing changes ---
    $p = New-Orphan -NotInRot
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T6 no switch, host gone -> IDE_LAUNCH_PENDING other-session as before, nothing launched / changed' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.probe -eq 'other-session' -and $r.data.otherSession.hostState -eq 'gone' -and $r.data.ownedBySession -eq $false -and $global:Launches73.Count -eq 1 -and (Get-RecordJson) -eq $before) "code=$($r.error.code) probe=$($r.data.probe)"
    Check 'T6b gone: message says the session has ended (not still running), hint names -TakeOverOrphan' ($r.error.message -match 'has ended' -and $r.error.message -notmatch 'still running' -and $r.error.hint -match 'TakeOverOrphan' -and $r.error.hint -match "pid $p") "$($r.error.message) | $($r.error.hint)"
    $p = New-Orphan -HostAlive -NotInRot
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T6c alive: message says still running, hint does not offer -TakeOverOrphan' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.error.message -match 'still running' -and $r.error.hint -notmatch 'TakeOverOrphan') "$($r.error.message)"
    $p = New-Orphan
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T6d no switch, IDE in the ROT with the solution: solution-match attach, not owned (unchanged)' ($r.success -and $r.data.selectedBy -eq 'solution-match' -and $r.data.ownedBySession -eq $false -and $null -eq $r.data.PSObject.Properties['takenOver'] -and [int]@(Read-Records)[0].hostPid -eq 9600) "code=$($r.error.code) sel=$($r.data.selectedBy)"
    $null = Disconnect-TcIde

    # --- T7: record file not writable / not readable -> fail closed ---
    $p = New-Orphan
    $before = Get-RecordJson
    $h = [IO.File]::Open((Get-RecordFile), 'Open', 'Read', 'Read')   # readers fine, the atomic replace fails
    try { $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan }
    finally { $h.Dispose() }
    Check 'T7 takeover not writable -> LAUNCH_RECORD_UNAVAILABLE launch-record-write-failed, not attached, record unchanged' ($r.error.code -eq 'LAUNCH_RECORD_UNAVAILABLE' -and $r.data.reason -eq 'launch-record-write-failed' -and $r.data.takenOver -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$r.data.launchRecordWarning) -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and -not (& $mod { param($x) Test-TcLaunchedIde -ProcessId $x } $p)) "code=$($r.error.code) reason=$($r.data.reason) warn=$($r.data.launchRecordWarning)"
    $h = [IO.File]::Open((Get-RecordFile), 'Open', 'ReadWrite', 'None')
    try { $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan }
    finally { $h.Dispose() }
    Check 'T7b records not readable -> LAUNCH_RECORD_UNAVAILABLE launch-record-unavailable, not attached' ($r.error.code -eq 'LAUNCH_RECORD_UNAVAILABLE' -and $r.data.reason -eq 'launch-record-unavailable' -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"

    # --- T8: other refusals ---
    Reset-All
    $r0 = Connect-TcIde -SolutionPath $sln
    Show-InRot ([int]$r0.data.ideProcessId) $slnL
    $global:Modal73 = 'none'
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T8 own record (hostState self) -> refused owned-by-this-session' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'owned-by-this-session' -and $r.data.otherSession.hostState -eq 'self') "code=$($r.error.code) reason=$($r.data.reason)"
    $p = New-Orphan
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'VisualStudio.DTE.17.0' -TakeOverOrphan
    Check 'T8b -ProgId other than the launch ProgID -> refused progid-mismatch' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'progid-mismatch') "code=$($r.error.code) reason=$($r.data.reason)"
    $global:Rot73 = @()
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T8c IDE not in the ROT -> refused not-in-rot, nothing launched' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'not-in-rot' -and $global:Launches73.Count -eq 1) "code=$($r.error.code) reason=$($r.data.reason)"
    Show-InRot $p $slnL
    $global:LaunchedDtes73[$p].Busy = $true
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T8d busy IDE without a dialog -> refused ide-busy' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'ide-busy' -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"

    Check 'E1 nothing real was killed (Stop-Process is the mock)' (@($global:Kills73 | Where-Object { $_ -notlike 'Stop-Process 90*' }).Count -eq 0) ($global:Kills73 -join ', ')
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Launches73, LaunchedDtes73, NextPid73, Procs73, Names73, Rot73, LaunchInRot73, GuessPid73, Modal73, ModalQueue73, Kills73, Quits73, Blocked73, OtherHostStart73, NextName73 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
