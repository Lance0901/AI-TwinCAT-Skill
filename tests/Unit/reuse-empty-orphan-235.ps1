# Unit: #235 Connect-TcIde -SolutionPath reuses the EMPTY IDE that another, ended TcAuto session
# launched for that .sln (cold start -> MODAL_SCAN_INCOMPLETE -> session over), instead of launching a
# second IDE. No IDE needed: the mocks are those of orphan-takeover-196.ps1 (ROT, launch, pid lookup,
# Get-Process of the fake pids, modal scan, Stop-Process); nothing real is launched, touched or killed.
#   R1  (a) record valid + confirmed, host and owner gone, ROT DTE of that pid ready with no solution,
#       no dialog, no document -> reused: same pid, no launch, Solution.Open on it, owned, record
#       owner rewritten (takeovers[] reason empty-orphan-reuse), data.reusedEmptyOrphan + previousOwner
#   R2  (g) Disconnect-TcIde -Quit on the reused IDE -> quit (not IDE_NOT_OWNED)
#   R3  (b) an empty IDE without any launch record (the user's) -> never reused, a new IDE is launched
#   R4  (c) owner alive / host alive -> not reused (IDE_LAUNCH_PENDING other-session, as before)
#   R5  (d) modal dialog / incomplete scan -> IDE_MODAL_DIALOG / MODAL_SCAN_INCOMPLETE, not reused,
#       nothing launched, nothing attached, record unchanged
#   R6  (e) Documents.Count > 0 or unreadable -> not reused (a new IDE is launched, as before)
#   R7  (f) -ProgId other than the launch ProgID -> not reused (launched with that ProgID)
#   R8  pid-unconfirmed record -> not reused
#   R9  writing the new owner fails -> LAUNCH_RECORD_UNAVAILABLE, attach released, not owned
#   R10 a dialog after the attach (before Solution.Open) -> IDE_MODAL_DIALOG, attach released, not owned
#   powershell.exe -NoProfile -File tests/Unit/reuse-empty-orphan-235.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# #152 N1 / #196 review B1: this process plays the bridge and its MCP server (owner id + owner pid)
$env:TCAUTO_OWNER_ID = 'owner-235-A'
$env:TCAUTO_OWNER_PID = [string]$PID
. (Join-Path $PSScriptRoot 'lib\ModuleMemory.ps1')
$modPath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-235-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$slnDir = Join-Path $root 's4026'
New-Item -ItemType Directory -Path (Join-Path $slnDir 'P1') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $slnDir 'P1\P1.tsproj') -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcSmVersion=`"1.0`" TcVersion=`"3.1.4026.22`">`r`n<Project/>`r`n</TcSmProject>" -Encoding UTF8
$sln = Join-Path $slnDir 's4026.sln'
Set-Content -LiteralPath $sln -Encoding UTF8 -Value @('', 'Microsoft Visual Studio Solution File, Format Version 12.00', 'VisualStudioVersion = 17.14.36930.0',
    'Project("{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}") = "P1", "P1\P1.tsproj", "{10112974-92E6-3C4B-560E-B30614E05491}"', 'EndProject')

$global:Launches235 = New-Object System.Collections.ArrayList
$global:LaunchedDtes235 = @{}
$global:NextPid235 = 9001
$global:Procs235 = @{}             # fake pid -> start time
$global:Rot235 = @()
$global:LaunchInRot235 = $true
$global:GuessPid235 = 0
$global:Modal235 = 'incomplete'
$global:ModalQueue235 = New-Object System.Collections.ArrayList
$global:Kills235 = New-Object System.Collections.ArrayList
$global:Quits235 = New-Object System.Collections.ArrayList
$global:Opens235 = New-Object System.Collections.ArrayList   # "<pid>|<solution>" of every Solution.Open

# Fake DTE: Solution.Open loads the .sln at once (one project whose Object is a fake ITcSysManager);
# Documents.Count = -Documents ('<throw>' = not readable)
function New-FakeDte([int]$ProcId = 0, [string]$Solution = '', [object]$Documents = 0) {
    $sol = New-Object PSObject
    $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty Projects ([PSCustomObject]@{ Count = 0 })
    $sol | Add-Member NoteProperty IsOpen $false
    $sol | Add-Member NoteProperty ProcId $ProcId
    $sol | Add-Member ScriptMethod Close { param($save) }
    $sol | Add-Member ScriptMethod Open {
        param($p)
        [void]$global:Opens235.Add("$($this.ProcId)|$p")
        $this.FullName = $p; $this.IsOpen = $true
        $sm = New-Object PSObject; $sm | Add-Member ScriptMethod GetTargetNetId { '1.2.3.4.1.1' }
        $proj = [PSCustomObject]@{ Name = 'P1'; Object = $sm }
        $projs = New-Object PSObject; $projs | Add-Member NoteProperty Count 1; $projs | Add-Member NoteProperty P $proj; $projs | Add-Member ScriptMethod Item { param($i) $this.P }
        $this.Projects = $projs
    }
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version '17.0'
    $o | Add-Member NoteProperty Solution $sol
    $o | Add-Member NoteProperty Busy $false
    $o | Add-Member NoteProperty ProcId $ProcId
    $o | Add-Member NoteProperty DocCount $Documents
    $o | Add-Member ScriptProperty Documents { if ([string]$this.DocCount -eq '<throw>') { throw 'mock: Documents not readable' }; [PSCustomObject]@{ Count = [int]$this.DocCount } }
    $o | Add-Member ScriptMethod Quit { [void]$global:Quits235.Add($this.ProcId) }
    $o
}
function New-RotEntry([int]$ProcId, [object]$Object, [string]$ProgId = 'TcXaeShell.DTE.17.0') {
    @{ DisplayName = "!${ProgId}:$ProcId"; Object = $Object; ProgId = $ProgId; ProcessId = $ProcId }
}

function Restart-Module {
    Import-Module $modPath -Force -WarningAction SilentlyContinue
    $script:mod = Get-Module TwinCATAutomation
    & $script:mod {
        param($NewFakeDte, $NewRotEntry)
        $script:TcLaunchPendingWaitSec = 1
        $script:TcLaunchRotWaitSec = 0
        $script:TcSysManagerRetryMs = 20
        $script:UnitNewFakeDte = $NewFakeDte; $script:UnitNewRotEntry = $NewRotEntry
        $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
        function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $true }
        function script:Get-TcProgIdIdeInfo { [CmdletBinding()] param([string]$ProgId) [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = '3.1.4026.22'; xaeBuild = 4026 } }
        function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() [PSCustomObject]@{ installedBuild = 4026; remoteManagerRoot = $null; remoteManagerBuilds = @('4026.22') } }
        function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) $null }
        function script:New-TcIdeInstance {
            [CmdletBinding()] param([string]$ProgId)
            [void]$global:Launches235.Add($ProgId)
            $pidNew = $global:NextPid235; $global:NextPid235++
            $global:Procs235[$pidNew] = [DateTime]::Now
            $o = & $script:UnitNewFakeDte $pidNew
            $global:LaunchedDtes235[$pidNew] = $o
            if ($global:LaunchInRot235) { $global:Rot235 = @($global:Rot235) + @(& $script:UnitNewRotEntry $pidNew $o $ProgId) }
            $o
        }
        function script:Get-TcIdeProcessId {
            [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
            if ($KnownPid -gt 0) { return @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = 'known-pid' } }
            if ($global:GuessPid235 -gt 0 -and $null -ne $StartedAfter) { return @{ ProcessId = $global:GuessPid235; MainHwnd = [long]0; Source = 'start-time' } }
            @{ ProcessId = 0; MainHwnd = [long]0; Source = '' }
        }
        function script:Get-Process {
            [CmdletBinding()] param([int]$Id, [string]$Name)
            if ($PSBoundParameters.ContainsKey('Name')) {
                return @($global:Procs235.Keys | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $Name; ProcessName = $Name; StartTime = $global:Procs235[$_] } })
            }
            if ($Id -ge 9000 -and $Id -lt 10000 -and $Id -ne $PID) {
                if ($global:Procs235.ContainsKey($Id)) {
                    return [PSCustomObject]@{ Id = $Id; ProcessName = 'TcXaeShell'; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs235[$Id] }
                }
                if ($ErrorActionPreference -eq 'SilentlyContinue') { return $null }
                throw "Cannot find a process with the process identifier $Id."
            }
            Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
        }
        function script:Find-TcIdeModalDialog {
            [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
            $mode = $global:Modal235
            if ($global:ModalQueue235.Count -gt 0) { $mode = $global:ModalQueue235[0]; $global:ModalQueue235.RemoveAt(0) }
            $p = if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:TcIdeProcessId }
            switch ($mode) {
                'incomplete' { return (New-TcModalScanIncomplete -ProcessId $p -Reason 'timeout' -TimeoutSec 5 -Message 'mock: cold start') }
                'dialog' { return @{ Title = 'Microsoft Visual Studio'; Text = 'mock dialog'; Hwnd = 0; Buttons = @() } }
                default { return $null }
            }
        }
        function script:Stop-TcLaunchedIde { [CmdletBinding()] param([object]$Dte, [string]$ProgId, [DateTime]$StartedAfter) [void]$global:Kills235.Add("Stop-TcLaunchedIde $ProgId"); , @() }
        function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) [void]$global:Kills235.Add("Stop-Process $Id"); $global:Procs235.Remove($Id) }
        function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot235 }
        function script:Invoke-TcComRetry {
            [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
            if ($OperationName -like 'Read DTE.Version / Solution.FullName*') {
                $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
                if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
            }
            & $script:UnitOrigComRetry @PSBoundParameters
        }
        function script:Find-TcBlockedSolutionIde { [CmdletBinding()] param([object[]]$Candidates, [string]$SolutionPath, [int]$PreviousProcessId, [object]$PreviousStartTime, [string]$PreviousSolution, [string[]]$KnownSolutions) @() }
        function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $o = New-Object PSObject; $o | Add-Member ScriptMethod GetTargetNetId { '5.6.7.8.1.1' }; $script:TcSysManager = $o; $o }
        function script:Get-TcSolutionPlatform { [CmdletBinding()] param() [PSCustomObject]@{ platform = 'TwinCAT RT (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT RT (x64)' } }
        function script:Save-TcIdeTargetNetId { param($AmsNetId) }
    } ${function:New-FakeDte} ${function:New-RotEntry}
    $script:modMemory = Save-UnitModuleMemory $script:mod
}

function Reset-All {
    $global:Rot235 = @(); $global:Launches235.Clear(); $global:LaunchedDtes235 = @{}; $global:Procs235 = @{}
    $global:Modal235 = 'incomplete'; $global:ModalQueue235.Clear(); $global:LaunchInRot235 = $true; $global:GuessPid235 = 0
    $global:Kills235.Clear(); $global:Quits235.Clear(); $global:Opens235.Clear()
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'ide-solutions.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Restore-UnitModuleMemory $script:mod $script:modMemory
}
function Get-RecordFile { Join-Path $env:TCAUTO_STATE_DIR 'launched-ides.json' }
function Read-Records { $f = Get-RecordFile; if (-not (Test-Path -LiteralPath $f)) { return @() }; @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json) | ForEach-Object { $_ }) }
function Get-RecordJson { Get-Content -LiteralPath (Get-RecordFile) -Raw }
function Edit-Records([scriptblock]$Change) {
    $recs = @(Read-Records)
    foreach ($r in $recs) { & $Change $r }
    Set-Content -LiteralPath (Get-RecordFile) -Value (ConvertTo-Json -InputObject @($recs) -Depth 4) -Encoding UTF8
}
function Test-NotConnected { -not (& $mod { [bool]$script:TcIdeConnected }) -and $null -eq (& $mod { $script:TcDte }) }
function Test-Owned([int]$ProcId) { & $mod { param($x) Test-TcLaunchedIde -ProcessId $x } $ProcId }

# The session that launched the IDE: bridge = fake pid 9600, its MCP server = fake pid 9601.
$global:OtherHostStart235 = [DateTime]'2026-11-11T17:00:00'
$global:OtherOwnerStart235 = [DateTime]'2026-11-11T16:59:00'
# Session A: Connect-TcIde launches the IDE, the cold-start scan never completes (MODAL_SCAN_INCOMPLETE,
# #230), the session ends. The record is made that of the ended session (host 9600, owner 9601, other
# owner id) and a new module instance (session B) starts. The IDE stays in the ROT without a solution.
function New-EmptyOrphan {
    param([switch]$HostAlive, [switch]$OwnerAlive, [object]$Documents = 0, [switch]$NotInRot)
    Reset-All
    $r = Connect-TcIde -SolutionPath $sln
    if ($r.error.code -ne 'MODAL_SCAN_INCOMPLETE') { throw "setup: session A expected MODAL_SCAN_INCOMPLETE, got $($r.error.code)" }
    $p = [int]$r.data.ideProcessId
    Edit-Records { param($x)
        $x.hostPid = 9600; $x.hostStartTime = $global:OtherHostStart235.ToUniversalTime().ToString('o'); $x.ownerId = 'owner-235-B'
        $x | Add-Member -NotePropertyName ownerPid -NotePropertyValue 9601 -Force
        $x | Add-Member -NotePropertyName ownerStartTime -NotePropertyValue $global:OtherOwnerStart235.ToUniversalTime().ToString('o') -Force
    }
    if ($HostAlive) { $global:Procs235[9600] = $global:OtherHostStart235 } else { $global:Procs235.Remove(9600) }
    if ($OwnerAlive) { $global:Procs235[9601] = $global:OtherOwnerStart235 } else { $global:Procs235.Remove(9601) }
    Restart-Module
    $global:LaunchedDtes235[$p].DocCount = $Documents
    $global:Rot235 = if ($NotInRot) { @() } else { @(New-RotEntry $p $global:LaunchedDtes235[$p]) }
    $global:Modal235 = 'none'
    $global:Opens235.Clear()
    $p
}

Restart-Module
$slnL = & $mod { param($x) Get-TcLongPath $x } $sln

try {
    # --- R1 (a): reused ---
    $p = New-EmptyOrphan
    $r = Connect-TcIde -SolutionPath $sln
    $recs = @(Read-Records)
    $tk = @($recs | ForEach-Object { @($_.takeovers) } | Where-Object { $null -ne $_ })
    Check 'R1 empty orphan reused: success, same pid, selectedBy empty-orphan-reuse, no second launch' ($r.success -and [int]$r.data.ideProcessId -eq $p -and $r.data.selectedBy -eq 'empty-orphan-reuse' -and $global:Launches235.Count -eq 1) "code=$($r.error.code) msg=$($r.error.message) sel=$($r.data.selectedBy) pid=$($r.data.ideProcessId) launches=$($global:Launches235.Count)"
    Check 'R1b Solution.Open was called on that IDE with the .sln' (@($global:Opens235 | Where-Object { $_ -eq "$p|$slnL" }).Count -eq 1 -and $r.data.solution -eq $slnL) "opens=$($global:Opens235 -join ',') sol=$($r.data.solution)"
    Check 'R1c ownedBySession true, reusedEmptyOrphan true, previousOwner = the ended session' ($r.data.ownedBySession -eq $true -and $r.data.reusedEmptyOrphan -eq $true -and [int]$r.data.previousOwner.hostPid -eq 9600 -and $r.data.previousOwner.ownerId -eq 'owner-235-B' -and $r.data.previousOwner.hostState -eq 'gone' -and $r.data.previousOwner.ownerState -eq 'gone' -and (Test-Owned $p)) "owned=$($r.data.ownedBySession) reused=$($r.data.reusedEmptyOrphan) prev=$($r.data.previousOwner | ConvertTo-Json -Compress)"
    Check 'R1d record owner rewritten to this process, one takeovers[] entry with reason empty-orphan-reuse, solution kept' ($recs.Count -eq 1 -and [int]$recs[0].pid -eq $p -and [int]$recs[0].hostPid -eq $PID -and $recs[0].ownerId -eq 'owner-235-A' -and $tk.Count -eq 1 -and $tk[0].reason -eq 'empty-orphan-reuse' -and [int]$tk[0].previousHostPid -eq 9600 -and $recs[0].solution -eq $slnL) ((Get-RecordJson) -replace '\s+', ' ')
    Check 'R1e no takenOver flag (that is -TakeOverOrphan only), modal scan done' ($null -eq $r.data.PSObject.Properties['takenOver'] -and $null -ne $r.data.PSObject.Properties['modalScanRetried']) ''

    # --- R2 (g): Disconnect-TcIde -Quit closes it ---
    $d = Disconnect-TcIde -Quit
    Check 'R2 Disconnect-TcIde -Quit on the reused IDE -> quit, not IDE_NOT_OWNED' ($d.success -and $d.error.code -ne 'IDE_NOT_OWNED' -and @($global:Quits235 | Where-Object { $_ -eq $p }).Count -eq 1) "code=$($d.error.code) quits=$($global:Quits235 -join ',')"

    # --- R3 (b): the user's empty IDE (no launch record) is never reused ---
    Reset-All
    $global:Procs235[9500] = [DateTime]::Now.AddMinutes(-5)
    $user = New-FakeDte 9500
    $global:Rot235 = @(New-RotEntry 9500 $user)
    $global:Modal235 = 'none'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R3 empty IDE without a launch record -> not reused, a new IDE is launched and opens the .sln' ($r.success -and $r.data.selectedBy -eq 'launched' -and [int]$r.data.ideProcessId -ne 9500 -and $global:Launches235.Count -eq 1 -and @($global:Opens235 | Where-Object { $_ -like '9500|*' }).Count -eq 0 -and $null -eq $r.data.PSObject.Properties['reusedEmptyOrphan']) "code=$($r.error.code) sel=$($r.data.selectedBy) pid=$($r.data.ideProcessId)"
    $null = Disconnect-TcIde

    # --- R4 (c): owner alive / host alive -> not reused ---
    $p = New-EmptyOrphan -OwnerAlive
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R4 owner (MCP server) alive -> not reused: IDE_LAUNCH_PENDING other-session, nothing opened / launched, record unchanged' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $r.data.probe -eq 'other-session' -and $global:Launches235.Count -eq 1 -and $global:Opens235.Count -eq 0 -and (Get-RecordJson) -eq $before -and -not (Test-Owned $p)) "code=$($r.error.code) probe=$($r.data.probe) launches=$($global:Launches235.Count)"
    $p = New-EmptyOrphan -HostAlive
    $before = Get-RecordJson
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R4b host (bridge) alive -> not reused: IDE_LAUNCH_PENDING other-session, record unchanged' ($r.error.code -eq 'IDE_LAUNCH_PENDING' -and $global:Launches235.Count -eq 1 -and $global:Opens235.Count -eq 0 -and (Get-RecordJson) -eq $before) "code=$($r.error.code)"

    # --- R5 (d): a modal dialog / incomplete scan -> not reused, nothing launched ---
    $p = New-EmptyOrphan
    $before = Get-RecordJson
    $global:Modal235 = 'dialog'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R5 modal dialog -> IDE_MODAL_DIALOG, not reused, no second IDE, nothing opened, not attached, record unchanged' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:Launches235.Count -eq 1 -and $global:Opens235.Count -eq 0 -and (Test-NotConnected) -and (Get-RecordJson) -eq $before -and -not (Test-Owned $p) -and [int]$r.data.ideProcessId -eq $p) "code=$($r.error.code) launches=$($global:Launches235.Count) pid=$($r.data.ideProcessId)"
    Check 'R5a its hint says the call can simply be repeated once the dialog is gone (no -TakeOverOrphan needed)' ([string]$r.error.hint -match 'ConnectIde' -and [string]$r.error.message -notmatch 'TakeOverOrphan') "$($r.error.message) | $($r.error.hint)"
    $global:Modal235 = 'incomplete'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R5b incomplete scan (also after the #230 retry) -> MODAL_SCAN_INCOMPLETE, not reused, no second IDE, not attached' ($r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Launches235.Count -eq 1 -and $global:Opens235.Count -eq 0 -and (Test-NotConnected) -and (Get-RecordJson) -eq $before) "code=$($r.error.code) launches=$($global:Launches235.Count)"
    $global:Modal235 = 'none'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R5c dialog closed, same call again -> reused' ($r.success -and $r.data.reusedEmptyOrphan -eq $true -and [int]$r.data.ideProcessId -eq $p -and $global:Launches235.Count -eq 1) "code=$($r.error.code)"
    $null = Disconnect-TcIde

    # --- R10: a dialog after the attach (the scan before Solution.Open) -> attach released ---
    $p = New-EmptyOrphan
    $before = Get-RecordJson
    [void]$global:ModalQueue235.Add('none')     # Resolve-TcOrphanTakeover: no dialog yet
    [void]$global:ModalQueue235.Add('dialog')   # the scan after the attach finds one
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R10 dialog after the attach -> IDE_MODAL_DIALOG, attach released, not owned, nothing opened, record unchanged' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Test-NotConnected) -and -not (Test-Owned $p) -and $global:Opens235.Count -eq 0 -and $global:Launches235.Count -eq 1 -and (Get-RecordJson) -eq $before -and $r.data.ownedBySession -eq $false) "code=$($r.error.code) owned=$($r.data.ownedBySession)"

    # --- R6 (e): a document open (or unreadable) -> not reused ---
    $p = New-EmptyOrphan -Documents 1
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R6 Documents.Count 1 -> not reused: a new IDE is launched (as before), the orphan untouched' ($r.success -and $r.data.selectedBy -eq 'launched' -and [int]$r.data.ideProcessId -ne $p -and $global:Launches235.Count -eq 2 -and @($global:Opens235 | Where-Object { $_ -like "$p|*" }).Count -eq 0 -and -not (Test-Owned $p)) "code=$($r.error.code) sel=$($r.data.selectedBy) pid=$($r.data.ideProcessId)"
    $null = Disconnect-TcIde
    $p = New-EmptyOrphan -Documents '<throw>'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R6b Documents not readable -> not reused (counts as open)' ($r.success -and $r.data.selectedBy -eq 'launched' -and [int]$r.data.ideProcessId -ne $p -and -not (Test-Owned $p)) "code=$($r.error.code) sel=$($r.data.selectedBy)"
    $null = Disconnect-TcIde

    # --- R7 (f): -ProgId other than the launch ProgID ---
    $p = New-EmptyOrphan
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'VisualStudio.DTE.17.0'
    Check 'R7 -ProgId mismatch -> not reused (launched as VisualStudio.DTE.17.0)' ($r.success -and $r.data.selectedBy -eq 'launched' -and [int]$r.data.ideProcessId -ne $p -and $global:Launches235[-1] -eq 'VisualStudio.DTE.17.0' -and -not (Test-Owned $p)) "code=$($r.error.code) sel=$($r.data.selectedBy) launches=$($global:Launches235 -join ',')"
    $null = Disconnect-TcIde
    $p = New-EmptyOrphan
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'TcXaeShell.DTE.17.0'
    Check 'R7b -ProgId equal to the launch ProgID -> reused' ($r.success -and $r.data.reusedEmptyOrphan -eq $true -and [int]$r.data.ideProcessId -eq $p -and $global:Launches235.Count -eq 1) "code=$($r.error.code) sel=$($r.data.selectedBy)"
    $null = Disconnect-TcIde

    # --- R8: pid-unconfirmed record -> not reused ---
    $p = New-EmptyOrphan
    Edit-Records { param($x) $x.pidSource = 'pid-unconfirmed' }
    Restart-Module
    $global:Rot235 = @(New-RotEntry $p $global:LaunchedDtes235[$p]); $global:Modal235 = 'none'
    $r = Connect-TcIde -SolutionPath $sln
    Check 'R8 pid-unconfirmed record -> not reused' ($null -eq $r.data.PSObject.Properties['reusedEmptyOrphan'] -and [int]$r.data.ideProcessId -ne $p -and -not (Test-Owned $p)) "code=$($r.error.code) sel=$($r.data.selectedBy) pid=$($r.data.ideProcessId)"
    $null = Disconnect-TcIde

    # --- R9: writing the new owner fails -> fail closed ---
    $p = New-EmptyOrphan
    $before = Get-RecordJson
    $h = [IO.File]::Open((Get-RecordFile), 'Open', 'Read', 'Read')   # readers fine, the atomic replace fails
    try { $r = Connect-TcIde -SolutionPath $sln }
    finally { $h.Dispose() }
    Check 'R9 owner not writable -> LAUNCH_RECORD_UNAVAILABLE, attach released, not owned, no second IDE, record unchanged' ($r.error.code -eq 'LAUNCH_RECORD_UNAVAILABLE' -and (Test-NotConnected) -and -not (Test-Owned $p) -and $global:Launches235.Count -eq 1 -and (Get-RecordJson) -eq $before -and $r.data.ownedBySession -eq $false) "code=$($r.error.code) reason=$($r.data.reason)"

    Check 'E1 nothing real was killed (Stop-Process is the mock)' (@($global:Kills235 | Where-Object { $_ -notlike 'Stop-Process 90*' -and $_ -notlike 'Stop-TcLaunchedIde *' }).Count -eq 0) ($global:Kills235 -join ', ')
}
finally {
    Remove-Module TwinCATAutomation -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
