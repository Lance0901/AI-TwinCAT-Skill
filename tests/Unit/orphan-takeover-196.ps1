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
#   T9  #196 review B1: bridge (host) gone but its MCP server (owner) alive -> owner-alive; owner
#       not verifiable (no ownerPid / no ownerStartTime / start time unreadable) -> owner-unverifiable;
#       owner pid recycled -> taken over; a record without ownerId (manual PowerShell) -> host decides
#   T10 #196 review M2: the takeover is written only after attach + modal check + project scan:
#       a dialog / IDE_CRASHED after the attach, or an owner that came back -> record unchanged
#   T11 #201: a reload prompt of the orphan is answered without reloading (solution Ignore, project
#       No, file Close, on the orphan pid), the DTE is read again, then taken over; a prompt that stays
#       up / an unknown dialog -> IDE_MODAL_DIALOG with a hint that does not point at Reset-TcSolution
#   T12 PR #209 review: M2 failed exits after the attach carry the orphan hint / reloadPromptAttempts /
#       resetRequired; M1 data.dirtyDocuments (dirtyDocumentsError when unreadable); m2 solution-name
#       evidence only for a quoted name in a text without any drive path; m3 no WM_CLOSE fallback
#   powershell.exe -NoProfile -File tests/Unit/orphan-takeover-196.ps1
# Exit code = number of failed checks.
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# #152 N1: the MCP server passes its owner id to the bridge; this process plays that bridge
$env:TCAUTO_OWNER_ID = 'owner-73-A'
# #196 review B1: ... and its own pid as the owner process (this test process plays that server too)
$env:TCAUTO_OWNER_PID = [string]$PID
. (Join-Path $PSScriptRoot 'lib\ModuleMemory.ps1')   # #241: Reset-All without Import-Module -Force
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
$global:NoStart73 = @{}           # fake pid -> $true: its StartTime cannot be read (access denied)
$global:SysMgrHook73 = $null      # scriptblock run by the Get-TcSysManager mock (T10)

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
        $script:TcSysManagerRetryMs = 20   # #241: an ITcSysManager probe that finds none waits 20 ms, not 1 s
        $script:UnitNewFakeDte = $NewFakeDte; $script:UnitNewRotEntry = $NewRotEntry
        $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
        function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $true }
        function script:Get-TcProgIdIdeInfo { [CmdletBinding()] param([string]$ProgId) [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = '3.1.4026.22'; xaeBuild = 4026 } }
        function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() [PSCustomObject]@{ installedBuild = 4026; remoteManagerRoot = $null; remoteManagerBuilds = @('4026.22') } }   # #225 shape; root $null = Remote Manager rule never applies here
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
                    if ($global:NoStart73.ContainsKey($Id)) {
                        $o = [PSCustomObject]@{ Id = $Id; ProcessName = $n; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero }
                        $o | Add-Member ScriptProperty StartTime { throw 'Access is denied' }
                        return $o
                    }
                    return [PSCustomObject]@{ Id = $Id; ProcessName = $n; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs73[$Id] }
                }
                if ($ErrorActionPreference -eq 'SilentlyContinue') { return $null }
                throw "Cannot find a process with the process identifier $Id."
            }
            Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
        }
        function script:Find-TcIdeModalDialog {
            [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
            $mode = $global:Modal73
            if ($global:ModalQueue73.Count -gt 0) { $mode = $global:ModalQueue73[0]; $global:ModalQueue73.RemoveAt(0) }
            $p = if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:TcIdeProcessId }
            switch ($mode) {
                'incomplete' { return (New-TcModalScanIncomplete -ProcessId $p -Reason 'timeout' -TimeoutSec 5 -Message 'mock: cold start') }
                'dialog' { return @{ Title = 'Microsoft Visual Studio'; Text = 'mock dialog'; Hwnd = 0; Buttons = @() } }
                # #201: reload prompts (Kind / ReloadTarget as Find-TcIdeModalDialog reports them)
                'reload-solution' { return @{ Title = 'File Modification Detected'; Text = "The solution 's4026' has been modified outside the environment."; Kind = 'reload-prompt'; ReloadTarget = 'solution'; Hwnd = 201; Buttons = @() } }
                'reload-project' { return @{ Title = 'TcXaeShell'; Text = "The project file '$($global:SlnDir201)\P1\P1.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"; Kind = 'reload-prompt'; ReloadTarget = 'project'; Hwnd = 202; Buttons = @() } }
                # PR #209 review m1: prompts that give no evidence for the solution
                'reload-project-outside' { return @{ Title = 'TcXaeShell'; Text = "The project file 'C:\Elsewhere201\Q\Q.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"; Kind = 'reload-prompt'; ReloadTarget = 'project'; Hwnd = 204; Buttons = @() } }
                'reload-solution-other' { return @{ Title = 'File Modification Detected'; Text = "The solution 'OtherSolution201' has been modified outside the environment."; Kind = 'reload-prompt'; ReloadTarget = 'solution'; Hwnd = 205; Buttons = @() } }
                'reload-file' { return @{ Title = 'Microsoft Visual Studio'; Text = 'File has been changed outside the environment. Reload the new file?'; Kind = 'reload-prompt'; ReloadTarget = 'file'; Hwnd = 203; Buttons = @() } }
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
        function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) if ($null -ne $global:SysMgrHook73) { & $global:SysMgrHook73 }; $o = New-Object PSObject; $o | Add-Member ScriptMethod GetTargetNetId { '5.6.7.8.1.1' }; $script:TcSysManager = $o; $o }
        function script:Get-TcSolutionPlatform { [CmdletBinding()] param() [PSCustomObject]@{ platform = 'TwinCAT RT (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT RT (x64)' } }
        function script:Save-TcIdeTargetNetId { param($AmsNetId) }
    }
    $script:modMemory = Save-UnitModuleMemory $script:mod
}

# Clean start of a case: mocks and state files reset, module memory (variables and functions) back
# to just after the last Restart-Module (#241: lib\ModuleMemory.ps1, no Import-Module -Force; the
# steps that need a NEW module instance still call Restart-Module).
function Reset-All {
    $global:Rot73 = @(); $global:Launches73.Clear(); $global:LaunchedDtes73 = @{}; $global:Procs73 = @{}; $global:Names73 = @{}
    $global:NoStart73 = @{}; $global:SysMgrHook73 = $null
    $global:Modal73 = 'incomplete'; $global:ModalQueue73.Clear(); $global:LaunchInRot73 = $true; $global:GuessPid73 = 0; $global:Kills73.Clear(); $global:Quits73 = 0; $global:Blocked73 = $false; $global:NextName73 = $null
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'build-required.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Restore-UnitModuleMemory $script:mod $script:modMemory
}
function Get-RecordFile { Join-Path $env:TCAUTO_STATE_DIR 'launched-ides.json' }
function Read-Records { $f = Get-RecordFile; if (-not (Test-Path -LiteralPath $f)) { return @() }; @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
function Edit-Records([scriptblock]$Change) {
    $recs = @(Read-Records)
    foreach ($r in $recs) { & $Change $r }
    Set-Content -LiteralPath (Get-RecordFile) -Value (ConvertTo-Json -InputObject @($recs) -Depth 4) -Encoding UTF8
}
# The TcAuto session (bridge) that launched the IDE: fake pid 9600, owner id of another MCP server
# whose process (#196 review B1: ownerPid / ownerStartTime) is fake pid 9601.
$global:OtherHostStart73 = [DateTime]'2026-11-06T08:00:00'
$global:OtherOwnerStart73 = [DateTime]'2026-11-06T07:59:00'
function Set-OtherOwner {
    Edit-Records { param($r)
        $r.hostPid = 9600; $r.hostStartTime = $global:OtherHostStart73.ToUniversalTime().ToString('o'); $r.ownerId = 'owner-196-B'
        $r | Add-Member -NotePropertyName ownerPid -NotePropertyValue 9601 -Force
        $r | Add-Member -NotePropertyName ownerStartTime -NotePropertyValue $global:OtherOwnerStart73.ToUniversalTime().ToString('o') -Force
    }
}
function Show-InRot([int]$ProcId, [string]$Solution) {
    $o = $global:LaunchedDtes73[$ProcId]; $o.Solution.FullName = $Solution
    $global:Rot73 = @(New-RotEntry $ProcId $o)
}
# An IDE launched by this module (cold start, MODAL_SCAN_INCOMPLETE) whose record is then made the
# record of an ENDED session (host 9600 not running, other ownerId) in a new module instance.
function New-Orphan {
    param([switch]$HostAlive, [switch]$OwnerAlive, [AllowNull()][string]$RotSolution = $script:slnL, [switch]$NotInRot)
    Reset-All
    $r = Connect-TcIde -SolutionPath $sln
    $p = [int]$r.data.ideProcessId
    Set-OtherOwner
    if ($HostAlive) { $global:Procs73[9600] = $global:OtherHostStart73 } else { $global:Procs73.Remove(9600) }
    if ($OwnerAlive) { $global:Procs73[9601] = $global:OtherOwnerStart73 } else { $global:Procs73.Remove(9601) }
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
    Check 'T1b record owner = this process (hostPid, ownerId, ownerPid, moduleInstanceId) + one takeovers[] entry with the previous owner' ($recs.Count -eq 1 -and [int]$recs[0].hostPid -eq $PID -and $recs[0].ownerId -eq 'owner-73-A' -and [int]$recs[0].ownerPid -eq $PID -and -not [string]::IsNullOrWhiteSpace([string]$recs[0].ownerStartTime) -and [int]$tk[0].previousOwnerPid -eq 9601 -and $r.data.previousOwner.ownerState -eq 'gone' -and $recs[0].moduleInstanceId -eq (& $mod { $script:TcModuleInstanceId }) -and $tk.Count -eq 1 -and [int]$tk[0].previousHostPid -eq 9600 -and $tk[0].previousOwnerId -eq 'owner-196-B' -and $tk[0].reason -eq 'orphan-takeover' -and [int]$tk[0].hostPid -eq $PID -and -not [string]::IsNullOrWhiteSpace([string]$tk[0].takenOverAt) -and -not [string]::IsNullOrWhiteSpace([string]$tk[0].previousHostStartTime)) ((Get-RecordJson) -replace '\s+', ' ')
    $global:Modal73 = 'dialog'
    $d = Disconnect-TcIde -Quit -Kill
    Check 'T1c afterwards Disconnect-TcIde -Quit -Kill treats it as owned (killed)' ($d.success -and $d.data.ownedBySession -eq $true -and $d.data.killed -eq $true -and @($global:Kills73 | Where-Object { $_ -eq "Stop-Process $p" }).Count -eq 1) "code=$($d.error.code) owned=$($d.data.ownedBySession) kills=$($global:Kills73 -join ',')"
    # a second takeover appends to the history
    $p = New-Orphan
    $null = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $null = Disconnect-TcIde
    Set-OtherOwner
    $global:Procs73.Remove(9600); $global:Procs73.Remove(9601)
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
    $global:Procs73.Remove(9600); $global:Procs73.Remove(9601)
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

    # --- T9: #196 review B1 - the owner process (MCP server) decides as well ---
    $p = New-Orphan -OwnerAlive
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T9 bridge restarted (hostPid gone, other ownerId) but its MCP server alive -> refused owner-alive, record unchanged, not connected' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'owner-alive' -and $r.data.otherSession.hostState -eq 'gone' -and $r.data.otherSession.ownerState -eq 'alive' -and [int]$r.data.otherSession.ownerPid -eq 9601 -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and $global:Launches73.Count -eq 1) "code=$($r.error.code) reason=$($r.data.reason)"
    $global:Rot73 = @()
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T9a same, without the switch: IDE_LAUNCH_PENDING other-session, message not "has ended", hint does not offer -TakeOverOrphan' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.otherSession.ownerState -eq 'alive' -and $r.error.message -notmatch 'has ended' -and $r.error.hint -notmatch 'TakeOverOrphan' -and (Get-RecordJson) -eq $before) "$($r.error.code) | $($r.error.message)"
    Show-InRot $p $slnL
    $global:Procs73[9601] = $global:OtherOwnerStart73.AddHours(2)   # pid 9601 now another process
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T9b owner pid recycled (other start time) counts as gone -> taken over' ($r.success -and $r.data.takenOver -eq $true -and $r.data.previousOwner.ownerState -eq 'gone') "code=$($r.error.code) reason=$($r.data.reason)"
    $null = Disconnect-TcIde
    foreach ($case in @(
            @{ Name = 'T9c record with ownerId but no ownerPid (written before the fix)'; Change = { param($r) $r.PSObject.Properties.Remove('ownerPid'); $r.PSObject.Properties.Remove('ownerStartTime') } },
            @{ Name = 'T9d record with ownerPid but no ownerStartTime'; Change = { param($r) $r.ownerStartTime = $null } },
            @{ Name = 'T9e owner pid running, its start time not readable'; Change = { param($r) $global:Procs73[9601] = $global:OtherOwnerStart73; $global:NoStart73[9601] = $true } })) {
        $p = New-Orphan
        Edit-Records $case.Change
        Restart-Module
        Show-InRot $p $slnL
        $global:Modal73 = 'none'
        $before = Get-RecordJson
        $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
        Check "$($case.Name) -> refused owner-unverifiable, record unchanged, not connected" ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'owner-unverifiable' -and $r.data.otherSession.ownerState -eq 'unverifiable' -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"
    $global:Rot73 = @()
    $r = Connect-TcIde -SolutionPath $sln
    Check "$($case.Name) -> without the switch the hint does not suggest taking over (ownerState unverifiable)" ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.otherSession.ownerState -eq 'unverifiable' -and $r.error.hint -notmatch 'TakeOverOrphan' -and $r.error.hint -match 'ownerState') "$($r.error.code) | $($r.error.hint)"
    }
    $p = New-Orphan
    Edit-Records { param($r) $r.ownerId = $null; $r.ownerPid = $null; $r.ownerStartTime = $null }
    Restart-Module
    Show-InRot $p $slnL
    $global:Modal73 = 'none'
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T9f record without ownerId (manual PowerShell), host gone -> taken over as before (ownerState none)' ($r.success -and $r.data.takenOver -eq $true -and $r.data.previousOwner.ownerState -eq 'none') "code=$($r.error.code) reason=$($r.data.reason)"
    $null = Disconnect-TcIde

    # --- T10: #196 review M2 - nothing is written before the attach has passed ---
    $p = New-Orphan
    $before = Get-RecordJson
    [void]$global:ModalQueue73.Add('none')     # Resolve-TcOrphanTakeover: no dialog yet
    [void]$global:ModalQueue73.Add('dialog')   # the check after the attach finds one
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T10 dialog after the attach -> IDE_MODAL_DIALOG, takenOver false, record unchanged, not owned' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.takenOver -eq $false -and $r.data.ownedBySession -eq $false -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and -not (& $mod { param($x) Test-TcLaunchedIde -ProcessId $x } $p)) "code=$($r.error.code) took=$($r.data.takenOver)"
    $null = Disconnect-TcIde
    $global:SysMgrHook73 = { throw 'IDE_CRASHED: mock - the IDE died during the project scan' }
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T10b IDE_CRASHED in the project scan after the attach -> failure, record unchanged, not owned' (-not $r.success -and $r.error.code -eq 'IDE_CRASHED' -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and -not (& $mod { param($x) Test-TcLaunchedIde -ProcessId $x } $p)) "code=$($r.error.code)"
    $null = Disconnect-TcIde
    $global:SysMgrHook73 = { $global:Procs73[9601] = $global:OtherOwnerStart73 }   # the owner check under the lock sees it alive
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T10c owner alive when the takeover is written (under the lock) -> refused owner-alive, attach released, record unchanged' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'owner-alive' -and $r.data.takenOver -eq $false -and (Get-RecordJson) -eq $before -and (Test-NotConnected) -and -not (& $mod { param($x) Test-TcLaunchedIde -ProcessId $x } $p)) "code=$($r.error.code) reason=$($r.data.reason)"

    $null = Disconnect-TcIde
    # owner id set, but the start time of this server's process unreadable -> refused before writing
    $p = New-Orphan
    $before = Get-RecordJson
    $savedOwnerPid = $env:TCAUTO_OWNER_PID
    $env:TCAUTO_OWNER_PID = '9602'   # no such process at import: ownerStartTime $null
    try {
        Restart-Module
        Show-InRot $p $slnL
        $global:Modal73 = 'none'
        $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    }
    finally { $env:TCAUTO_OWNER_PID = $savedOwnerPid }
    Check 'T10d own owner start time unreadable -> refused owner-start-time-unreadable, record unchanged, not connected' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'owner-start-time-unreadable' -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"
    Restart-Module
    # #152 R3-1 release: an empty-solution IDE of a restarted bridge whose server still runs keeps blocking
    $p = New-Orphan -OwnerAlive -RotSolution ''
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T9g host gone, owner alive, IDE with no solution yet: still IDE_LAUNCH_PENDING other-session, no second IDE' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.probe -eq 'other-session' -and $global:Launches73.Count -eq 1) "code=$($r.error.code) probe=$($r.data.probe) launches=$($global:Launches73.Count)"
    $p = New-Orphan -RotSolution ''
    $r = Connect-TcIde -SolutionPath $sln
    Check 'T9h host and owner gone, IDE with no solution: released as before (a new IDE is launched)' ($global:Launches73.Count -eq 2) "code=$($r.error.code) launches=$($global:Launches73.Count)"
    $null = Disconnect-TcIde

    # --- T11 (#201): a reload prompt of the orphan is answered "do not reload", then taken over ---
    # Close-TcReloadPrompt is mocked: logs "<answer>|<pid>"; $global:CloseFail201 = answers that fail;
    # $global:CloseHook201 runs after a successful answer (e.g. the DTE stops being busy)
    $global:Answers201 = New-Object System.Collections.ArrayList
    $global:CloseFail201 = @()
    $global:CloseHook201 = $null
    function Install-ReloadMock {
        & $script:mod {
            function script:Close-TcReloadPrompt {
                [CmdletBinding()] param([object]$Dialog, [string]$Answer = 'Close', [int]$TimeoutSec = 8, [switch]$NoFollowUpScan, [int]$ProcessId = 0)
                [void]$global:Answers201.Add("$Answer|$ProcessId|$NoFollowUpScan")
                if ($global:CloseFail201 -contains $Answer) {
                    return @{ Dismissed = $false; Sent = $true; Method = 'BM_CLICK'; ControlId = 0; Reason = "mock: still shown after $TimeoutSec s"; WmCommand = 'posted-still-open'; NextDialog = $null }
                }
                if ($null -ne $global:CloseHook201) { & $global:CloseHook201 }
                @{ Dismissed = $true; Sent = $true; Method = 'BM_CLICK'; ControlId = 1412; Reason = 'dialog closed (follow-up scan skipped)'; WmCommand = 'not-needed'; NextDialog = $null }
            }
        }
    }
    $global:SlnDir201 = $slnDir
    function Get-ResetGuard { & $script:mod { param($x) Get-TcResetRequiredGuard -SolutionPath $x } $slnL }
    function New-ReloadOrphan([string[]]$Queue) {
        $pp = New-Orphan
        Install-ReloadMock
        $global:Answers201.Clear(); $global:CloseFail201 = @(); $global:CloseHook201 = $null
        $global:ModalQueue73.Clear(); foreach ($q in $Queue) { [void]$global:ModalQueue73.Add($q) }
        $global:Modal73 = 'none'
        $pp
    }

    $p = New-ReloadOrphan @('reload-solution')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $att = @($r.data.reloadPromptAttempts)
    Check 'T11 solution reload prompt -> answered Ignore on the orphan pid (no follow-up scan), then taken over' ($r.success -and $r.data.takenOver -eq $true -and $r.data.ownedBySession -eq $true -and ($global:Answers201 -join ',') -eq "Ignore|$p|True" -and $att.Count -eq 1 -and $att[0].target -eq 'solution' -and $att[0].answer -eq 'Ignore' -and $att[0].dismissed -eq $true) "code=$($r.error.code) answers=$($global:Answers201 -join ',') hint=$($r.error.hint)"
    Check 'T11a success says the disk changes are not loaded and names Reset-TcSolution as next step' ($r.data.diskChangesNotLoaded -eq $true -and [string]$r.data.nextStep -match 'Reset-TcSolution') "nextStep=$($r.data.nextStep)"
    Check 'T11a2 success carries data.resetRequired and the reset-required record exists (M1)' ($null -ne $r.data.resetRequired -and $null -ne (Get-ResetGuard) -and @($r.data.reloadPromptAttempts)[0].evidence -eq 'dte-solution') "resetRequired=$($r.data.resetRequired | ConvertTo-Json -Compress)"
    $bt = Build-TcProject
    Check 'T11a3 Build-TcProject right after the takeover -> RESET_REQUIRED, hint names Reset-TcSolution (M1)' (-not $bt.success -and $bt.error.code -eq 'RESET_REQUIRED' -and $bt.error.hint -match 'Reset-TcSolution') "code=$($bt.error.code)"
    Check 'T11b record owner rewritten (taken over)' ([int]@(Read-Records)[0].hostPid -eq $PID -and @(@(Read-Records)[0].takeovers).Count -eq 1) ((Get-RecordJson) -replace '\s+', ' ')
    $null = Disconnect-TcIde

    # project prompt while the DTE is busy (the prompt blocks it); No, then the DTE is read again
    $p = New-ReloadOrphan @('reload-project')
    $global:LaunchedDtes73[$p].Busy = $true
    $global:P201 = $p; $global:CloseHook201 = { $global:LaunchedDtes73[$global:P201].Busy = $false }
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11c project prompt on a busy DTE -> answered No (never Yes / WM_CLOSE), DTE read again, taken over' ($r.success -and $r.data.takenOver -eq $true -and ($global:Answers201 -join ',') -eq "No|$p|True" -and @($r.data.reloadPromptAttempts)[0].answer -eq 'No') "code=$($r.error.code) reason=$($r.data.reason) answers=$($global:Answers201 -join ',')"
    $null = Disconnect-TcIde

    $p = New-ReloadOrphan @('reload-file')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11d file prompt -> WM_CLOSE (Close), taken over' ($r.success -and $r.data.takenOver -eq $true -and ($global:Answers201 -join ',') -eq "Close|$p|True") "code=$($r.error.code) answers=$($global:Answers201 -join ',')"
    $null = Disconnect-TcIde

    # two prompts in a row (solution, then project) -> both answered
    $p = New-ReloadOrphan @('reload-solution', 'reload-project')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11e two prompts in a row -> Ignore then No, taken over, two attempts reported' ($r.success -and ($global:Answers201 -join ',') -eq "Ignore|$p|True,No|$p|True" -and @($r.data.reloadPromptAttempts).Count -eq 2) "code=$($r.error.code) answers=$($global:Answers201 -join ',')"
    $null = Disconnect-TcIde

    # the prompt stays up (Ignore fails; m3: no WM_CLOSE fallback) -> fail closed, truthful hint
    $p = New-ReloadOrphan @('reload-solution')
    $global:CloseFail201 = @('Ignore', 'Close')
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11f prompt not dismissed -> IDE_MODAL_DIALOG, not taken over, record unchanged, not connected, only Ignore tried (m3: no WM_CLOSE)' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.takenOver -eq $false -and $r.data.attached -eq $false -and $r.data.dialog.kind -eq 'reload-prompt' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and ($global:Answers201 -join ',') -eq "Ignore|$p|True" -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) answers=$($global:Answers201 -join ',')"
    Check 'T11f2 failed takeover after an answer still records reset-required and reports it (M2)' ($null -ne $r.data.resetRequired -and $null -ne (Get-ResetGuard)) "resetRequired=$($r.data.resetRequired)"
    Check 'T11g its hint says nothing is attached and does NOT send the caller to Reset-TcSolution (the #201 dead end)' ($r.error.hint -match 'NOT_CONNECTED' -and $r.error.hint -match 'TakeOverOrphan' -and $r.error.hint -notmatch '直接呼叫 Reset-TcSolution') "$($r.error.hint)"

    # M2: the prompt was closed by the user afterwards; the retried takeover still reports the record
    $global:CloseFail201 = @(); $global:ModalQueue73.Clear()
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11r retried takeover (prompt answered by the earlier call) -> success, diskChangesNotLoaded + resetRequired from the persisted record (M2)' ($r.success -and $r.data.takenOver -eq $true -and $r.data.diskChangesNotLoaded -eq $true -and $null -ne $r.data.resetRequired -and $global:Answers201.Count -eq 1 -and $null -eq $r.data.PSObject.Properties['reloadPromptAttempts']) "code=$($r.error.code) disk=$($r.data.diskChangesNotLoaded)"
    $null = Disconnect-TcIde

    # m1: DTE blocked (busy) and the prompt gives no evidence for this .sln -> nothing clicked
    $p = New-ReloadOrphan @('reload-project-outside')
    $global:LaunchedDtes73[$p].Busy = $true
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11p busy DTE + project prompt naming a file outside the solution folder -> IDE_MODAL_DIALOG, nothing answered, no reset-required (m1)' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:Answers201.Count -eq 0 -and $r.data.reloadPromptEvidence -eq 'none' -and $null -eq $r.data.PSObject.Properties['reloadPromptAttempts'] -and $null -eq (Get-ResetGuard) -and $r.error.hint -match 'NOT_CONNECTED' -and (Test-NotConnected)) "code=$($r.error.code) answers=$($global:Answers201 -join ',') ev=$($r.data.reloadPromptEvidence)"
    $p = New-ReloadOrphan @('reload-solution-other')
    $global:LaunchedDtes73[$p].Busy = $true
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11q busy DTE + solution prompt naming another solution -> nothing answered (m1)' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:Answers201.Count -eq 0 -and $r.data.reloadPromptEvidence -eq 'none') "code=$($r.error.code) answers=$($global:Answers201 -join ',')"
    $p = New-ReloadOrphan @('reload-solution')
    $global:LaunchedDtes73[$p].Busy = $true
    $global:P201 = $p; $global:CloseHook201 = { $global:LaunchedDtes73[$global:P201].Busy = $false }
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11s busy DTE + solution prompt naming this solution -> answered (evidence solution-name), taken over' ($r.success -and $r.data.takenOver -eq $true -and @($r.data.reloadPromptAttempts)[0].evidence -eq 'solution-name') "code=$($r.error.code) ev=$(@($r.data.reloadPromptAttempts)[0].evidence)"
    $null = Disconnect-TcIde

    # an unknown dialog is never answered
    $p = New-ReloadOrphan @('dialog')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11h unknown dialog -> IDE_MODAL_DIALOG with the orphan hint, nothing answered, not connected' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:Answers201.Count -eq 0 -and $null -eq (Get-ResetGuard) -and $r.error.hint -match 'NOT_CONNECTED' -and $null -eq $r.data.PSObject.Properties['reloadPromptAttempts'] -and (Test-NotConnected)) "code=$($r.error.code) answers=$($global:Answers201 -join ',')"

    # prompts keep coming: at most 5 answered
    $p = New-ReloadOrphan @('reload-file', 'reload-file', 'reload-file', 'reload-file', 'reload-file', 'reload-file')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11i a sixth prompt -> IDE_MODAL_DIALOG after 5 answers, not taken over' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:Answers201.Count -eq 5 -and $r.data.takenOver -eq $false -and (Test-NotConnected)) "code=$($r.error.code) answers=$($global:Answers201.Count)"

    # the scan after the answer is incomplete 3 times -> MODAL_SCAN_INCOMPLETE (fail closed)
    $p = New-ReloadOrphan @('reload-solution', 'incomplete', 'incomplete', 'incomplete')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11j scan after the answer never completes -> MODAL_SCAN_INCOMPLETE, not taken over' ($r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.data.takenOver -eq $false -and (Test-NotConnected)) "code=$($r.error.code)"
    $p = New-ReloadOrphan @('reload-solution', 'incomplete')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11k one incomplete scan after the answer, then a complete one -> taken over' ($r.success -and $r.data.takenOver -eq $true) "code=$($r.error.code)"
    $null = Disconnect-TcIde

    # after the answer the IDE turns out to have another solution open -> solution-mismatch
    $p = New-ReloadOrphan @('reload-project')
    $global:LaunchedDtes73[$p].Busy = $true
    $global:P201 = $p; $global:SlnY201 = $slnYL; $global:CloseHook201 = { $global:LaunchedDtes73[$global:P201].Busy = $false; $global:LaunchedDtes73[$global:P201].Solution.FullName = $global:SlnY201 }
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11l busy DTE, project prompt naming a file in the solution folder (evidence dialog-path) answered; the DTE read afterwards shows another .sln -> ORPHAN_TAKEOVER_REFUSED solution-mismatch, attempts + resetRequired reported, record unchanged' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'solution-mismatch' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and @($r.data.reloadPromptAttempts)[0].evidence -eq 'dialog-path' -and $null -ne $r.data.resetRequired -and (Get-RecordJson) -eq $before -and (Test-NotConnected)) "code=$($r.error.code) reason=$($r.data.reason)"

    # a host that is alive: the prompt is never touched (ownership checks come first)
    $p = New-Orphan -HostAlive
    Install-ReloadMock
    $global:Answers201.Clear(); $global:ModalQueue73.Clear(); [void]$global:ModalQueue73.Add('reload-solution')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T11m host alive + reload prompt -> refused host-alive, the prompt is not answered, no reset-required' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and $r.data.reason -eq 'host-alive' -and $global:Answers201.Count -eq 0 -and $null -eq (Get-ResetGuard)) "code=$($r.error.code) answers=$($global:Answers201 -join ',')"

    # Close-TcReloadPrompt passes -ProcessId on to Close-TcMessageBox (the orphan is not connected)
    Restart-Module
    $global:MsgBoxPid201 = $null
    & $mod { function script:Close-TcMessageBox { [CmdletBinding()] param([IntPtr]$Hwnd, [string]$Answer = 'Close', [int]$ProcessId = 0) $global:MsgBoxPid201 = $ProcessId; @{ Sent = $false; Method = $null; ControlId = 0; Reason = 'dialog already gone' } } }
    $cr = & $mod { Close-TcReloadPrompt -Dialog @{ Hwnd = 77 } -Answer Ignore -ProcessId 4242 }
    Check 'T11n Close-TcReloadPrompt -ProcessId reaches Close-TcMessageBox' ($global:MsgBoxPid201 -eq 4242 -and $cr.Dismissed -eq $true) "pid=$($global:MsgBoxPid201)"
    $cr = & $mod { Close-TcReloadPrompt -Dialog @{ Hwnd = 77 } -Answer Ignore }
    Check 'T11o without -ProcessId: 0 (Close-TcMessageBox falls back to the connected IDE, unchanged)' ($global:MsgBoxPid201 -eq 0) "pid=$($global:MsgBoxPid201)"

    # --- T12: PR #209 review ---
    Install-ReloadMock
    # M2: a dialog found by the check AFTER the attach (prompt answered before) -> orphan hint, not the
    # reload hint (that one sends the caller to Reset-TcSolution -> NOT_CONNECTED, #201), same fields
    $p = New-ReloadOrphan @('reload-solution', 'none', 'dialog')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T12a M2 dialog after the attach -> IDE_MODAL_DIALOG with the orphan hint, attempts + resetRequired, not connected' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.error.hint -match 'NOT_CONNECTED' -and $r.error.hint -notmatch '直接呼叫 Reset-TcSolution' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $null -ne $r.data.resetRequired -and $r.data.takenOver -eq $false -and $r.data.attached -eq $false -and (Test-NotConnected)) "code=$($r.error.code) hint=$($r.error.hint)"
    $null = Disconnect-TcIde
    $p = New-ReloadOrphan @('reload-solution')
    $global:SysMgrHook73 = { throw 'IDE_CRASHED: mock - the IDE died during the project scan' }
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $global:SysMgrHook73 = $null
    Check 'T12b M2 IDE_CRASHED after the attach (prompt answered) -> reloadPromptAttempts + resetRequired carried' ($r.error.code -eq 'IDE_CRASHED' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $null -ne $r.data.resetRequired -and $r.data.takenOver -eq $false -and (Test-NotConnected)) "code=$($r.error.code) data=$($r.data | ConvertTo-Json -Compress -Depth 2)"
    $null = Disconnect-TcIde
    # M2: a takeover refused at the write after an earlier call answered the prompt -> resetRequired from the record
    $p = New-ReloadOrphan @('reload-solution')
    $global:SysMgrHook73 = { $global:Procs73[9601] = $global:OtherOwnerStart73 }
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    $global:SysMgrHook73 = $null; $global:Procs73.Remove(9601)
    Check 'T12c M2 takeover write refused (owner back) -> ORPHAN_TAKEOVER_REFUSED with attempts + resetRequired' ($r.error.code -eq 'ORPHAN_TAKEOVER_REFUSED' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $null -ne $r.data.resetRequired) "code=$($r.error.code) reason=$($r.data.reason)"
    $null = Disconnect-TcIde

    # M1: unsaved editor documents of the orphan are listed; unreadable -> dirtyDocumentsError, takeover still succeeds
    $p = New-ReloadOrphan @('reload-solution')
    $global:Docs209 = @([PSCustomObject]@{ FullName = 'C:\x\MAIN.TcPOU'; Saved = $false }, [PSCustomObject]@{ FullName = 'C:\x\GVL.TcGVL'; Saved = $true })
    $dd = New-Object PSObject
    $dd | Add-Member -MemberType ScriptProperty -Name Count -Value { @($global:Docs209).Count }
    $dd | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) @($global:Docs209)[$i - 1] }
    $global:LaunchedDtes73[$p] | Add-Member -NotePropertyName Documents -NotePropertyValue $dd -Force
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T12d M1 success lists the unsaved documents (data.dirtyDocuments) and nextStep names -DiscardProjectChanges' ($r.success -and (@($r.data.dirtyDocuments) -join ',') -eq 'C:\x\MAIN.TcPOU' -and $null -eq $r.data.PSObject.Properties['dirtyDocumentsError'] -and [string]$r.data.nextStep -match 'DiscardProjectChanges') "code=$($r.error.code) dirty=$(@($r.data.dirtyDocuments) -join ',')"
    $null = Disconnect-TcIde
    Remove-Variable -Name Docs209 -Scope Global -ErrorAction SilentlyContinue
    $p = New-ReloadOrphan @('reload-solution')
    $r = Connect-TcIde -SolutionPath $sln -TakeOverOrphan
    Check 'T12e M1 Documents not readable -> dirtyDocumentsError, the takeover still succeeds' ($r.success -and -not [string]::IsNullOrWhiteSpace([string]$r.data.dirtyDocumentsError) -and $null -eq $r.data.PSObject.Properties['dirtyDocuments']) "code=$($r.error.code) err=$($r.data.dirtyDocumentsError)"
    $null = Disconnect-TcIde

    # m2: solution-name evidence only for a quoted name in a text without any drive path
    $bfh = 'C:\Proj\BFH-1650\BFH-1650.sln'
    $ev = { param($t) & $mod { param($x, $y) Get-TcOrphanDialogEvidence -Dialog @{ Text = $x } -SolutionPath $y } $t $bfh }
    Check 'T12f m2 quoted name, no path -> solution-name' ((& $ev "The solution 'BFH-1650' has been modified outside the environment.") -eq 'solution-name') ''
    Check 'T12g m2 unquoted name -> no evidence' ($null -eq (& $ev 'The solution BFH-1650 has been modified outside the environment.')) ''
    Check 'T12h m2 a non-project path that contains the name -> no evidence' ($null -eq (& $ev 'File C:\Other\BFH-1650\notes.txt has been changed outside the environment.')) ''
    Check 'T12i m2 quoted name next to a non-project path -> no evidence' ($null -eq (& $ev "The solution 'BFH-1650': C:\Other\BFH-1650\notes.txt was modified.")) ''
    Check 'T12j m2 a truncated path -> no evidence' ($null -eq (& $ev "The project file 'C:\Proj\BFH-1650\PLC1\PLC1.plcpr...' of 'BFH-1650' has been modified.")) ''
    Check 'T12k m2 a project file inside the solution folder -> dialog-path (unchanged)' ((& $ev "The project file 'C:\Proj\BFH-1650\PLC1\PLC1.plcproj' has been modified outside of TwinCAT XAE.") -eq 'dialog-path') ''

    Remove-Variable -Name Answers201, CloseFail201, CloseHook201, MsgBoxPid201, P201, SlnY201, SlnDir201 -Scope Global -ErrorAction SilentlyContinue
    Restart-Module

    Check 'E1 nothing real was killed (Stop-Process is the mock)' (@($global:Kills73 | Where-Object { $_ -notlike 'Stop-Process 90*' }).Count -eq 0) ($global:Kills73 -join ', ')
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Launches73, LaunchedDtes73, NextPid73, Procs73, Names73, Rot73, LaunchInRot73, GuessPid73, Modal73, ModalQueue73, Kills73, Quits73, Blocked73, OtherHostStart73, OtherOwnerStart73, NextName73, NoStart73, SysMgrHook73 -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
