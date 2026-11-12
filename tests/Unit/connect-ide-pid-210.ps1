# Unit: Connect-TcIde -ProcessId (#210), -LiteralPath for -SolutionPath (#224) and the ownership
# check of Disconnect-TcIde -Quit (#227), no IDE needed.
# Mocked, so no real IDE is ever launched, quit or killed: the ROT (Get-AllComObjects), the
# GetActiveObject fallback (Get-ComObject), the launch (New-TcIdeInstance), the pid lookup
# (Get-TcIdeProcessId), Get-Process for the fake pids (>= 9000), the modal-dialog scan, the busy
# answer of Invoke-TcComRetry, ITcSysManager and the solution platform read.
#   P  -ProcessId binds only that pid: not running / not in the ROT / ProgId / solution mismatch /
#      blocked -> error, nothing launched or attached; match or empty IDE -> attached, not owned
#   L  #224: a .sln in a folder with [ ] is found (Test-Path / Resolve-Path -LiteralPath)
#   Q  #227: Disconnect-TcIde -Quit (-Kill) refuses an IDE this session did not launch; an own one
#      is still quit
#   powershell.exe -NoProfile -File tests/Unit/connect-ide-pid-210.ps1
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
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$root = Join-Path $env:TEMP ("tcauto-unit-210-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function New-Sln([string]$Dir, [string]$Name) {
    $d = Join-Path $root $Dir
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $p = Join-Path $d "$Name.sln"
    Set-Content -LiteralPath $p -Value 'Microsoft Visual Studio Solution File, Format Version 12.00' -Encoding UTF8
    & $mod { param($x) Get-TcLongPath $x } $p
}
$slnA = New-Sln 'a' 'A'
$slnB = New-Sln 'b' 'B'
$slnBr = New-Sln 'Verify [226]' 'Br'   # #224: [226] is a wildcard for one of '2' / '6'

$global:Rot210 = @()
$global:Procs210 = @{}           # fake pid -> @{ Name; StartTime }
$global:Launches210 = New-Object System.Collections.ArrayList
$global:Modal210 = 'none'        # 'none' | 'dialog' | 'incomplete'
$global:Quits210 = New-Object System.Collections.ArrayList
$global:Opens210 = New-Object System.Collections.ArrayList

function New-FakeDte([int]$ProcId, [string]$Solution = '', [bool]$Busy = $false, [bool]$Unreadable = $false) {
    $sol = New-Object PSObject
    $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty IsOpen (-not [string]::IsNullOrEmpty($Solution))
    $sol | Add-Member NoteProperty Projects ([PSCustomObject]@{ Count = $(if ($Solution) { 1 } else { 0 }) })
    $sol | Add-Member NoteProperty ProcId $ProcId
    $sol | Add-Member ScriptMethod Open { param($p) [void]$global:Opens210.Add("$($this.ProcId)|$p"); $this.FullName = $p; $this.IsOpen = $true; $this.Projects = [PSCustomObject]@{ Count = 1 } }
    $sol | Add-Member ScriptMethod Close { param($s) $this.FullName = ''; $this.IsOpen = $false }
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version $(if ($Unreadable) { '' } else { '17.0' })
    $o | Add-Member NoteProperty Solution $sol
    $o | Add-Member NoteProperty Busy $Busy
    $o | Add-Member NoteProperty ProcId $ProcId
    $o | Add-Member ScriptMethod Quit { [void]$global:Quits210.Add($this.ProcId) }
    $o
}
function Add-Ide([int]$ProcId, [string]$Solution = '', [string]$ProgId = 'VisualStudio.DTE.17.0', [bool]$Busy = $false, [bool]$Unreadable = $false) {
    $global:Procs210[$ProcId] = @{ Name = 'devenv'; StartTime = [DateTime]::Now.AddMinutes(-5) }
    $o = New-FakeDte $ProcId $Solution $Busy $Unreadable
    $global:Rot210 = @($global:Rot210) + @(@{ DisplayName = "!${ProgId}:$ProcId"; Object = $o; ProgId = $ProgId; ProcessId = $ProcId })
    $o
}

& $mod {
    $script:TcLaunchPendingWaitSec = 1
    $script:TcLaunchRotWaitSec = 0
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) $null }
    function script:New-TcIdeInstance { [CmdletBinding()] param([string]$ProgId) [void]$global:Launches210.Add($ProgId); throw 'unit: launching is not allowed in this test' }
    function script:Get-TcIdeProcessId {
        [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
        @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = $(if ($KnownPid -gt 0) { 'known-pid' } else { '' }) }
    }
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id, [string]$Name)
        if ($PSBoundParameters.ContainsKey('Name')) {
            return @($global:Procs210.Keys | Where-Object { $global:Procs210[$_].Name -eq $Name } | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $Name; StartTime = $global:Procs210[$_].StartTime } })
        }
        if ($Id -ge 9000) {
            if ($global:Procs210.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; Name = $global:Procs210[$Id].Name; MainWindowTitle = ''; MainWindowHandle = [IntPtr]::Zero; StartTime = $global:Procs210[$Id].StartTime } }
            throw "Cannot find a process with the process identifier $Id."
        }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $p = if ($ProcessId -gt 0) { $ProcessId } else { [int]$script:TcIdeProcessId }
        switch ($global:Modal210) {
            'incomplete' { return (New-TcModalScanIncomplete -ProcessId $p -Reason 'timeout' -TimeoutSec 5 -Message 'mock') }
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
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $null }
    function script:Get-TcSolutionPlatform { [CmdletBinding()] param() @{ platform = $null; configuration = $null; projectPlatform = $null } }
    function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) throw "unit: Stop-Process $Id is not allowed" }
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot210 }
}

function Reset-State {
    $global:Rot210 = @(); $global:Procs210 = @{}; $global:Launches210.Clear(); $global:Modal210 = 'none'; $global:Quits210.Clear(); $global:Opens210.Clear()
    & $mod { Remove-Item -LiteralPath (Get-TcLaunchRecordPath) -Force -ErrorAction SilentlyContinue; $script:TcLaunchedIdes = @{}; $script:TcLaunchedIdeSolutions = @{}; $script:TcIdeProcessId = $null; $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null; $script:TcIdeStartTime = $null; $script:TcIdeSelectedBy = $null }
}
function Get-Conn { & $mod { [PSCustomObject]@{ connected = [bool]$script:TcIdeConnected; pid = $script:TcIdeProcessId; selectedBy = $script:TcIdeSelectedBy } } }
# the user's IDEs: 9001 with A, 9002 with B, 9003 empty; a notepad 9100 (not in the ROT)
function Set-Desktop {
    Reset-State
    $null = Add-Ide 9001 $slnA
    $null = Add-Ide 9002 $slnB
    $null = Add-Ide 9003 ''
    $global:Procs210[9100] = @{ Name = 'notepad'; StartTime = [DateTime]::Now }
}

try {
    # --- P: -ProcessId ---
    Set-Desktop
    $r = Connect-TcIde -ProcessId 9999
    $c = Get-Conn
    Check 'P1 pid not running -> IDE_PID_NOT_FOUND process-not-found, nothing launched / attached' ((-not $r.success) -and $r.error.code -eq 'IDE_PID_NOT_FOUND' -and $r.data.reason -eq 'process-not-found' -and $r.data.attached -eq $false -and $global:Launches210.Count -eq 0 -and -not $c.connected -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r)

    $r = Connect-TcIde -ProcessId 9100 -SolutionPath $slnA
    $c = Get-Conn
    Check 'P2 pid of a notepad -> IDE_PID_NOT_FOUND not-in-rot (processName), no fallback to the IDE that has the .sln open' ((-not $r.success) -and $r.error.code -eq 'IDE_PID_NOT_FOUND' -and $r.data.reason -eq 'not-in-rot' -and $r.data.processName -eq 'notepad' -and -not $c.connected -and $global:Launches210.Count -eq 0 -and $global:Opens210.Count -eq 0) (J $r)

    $r = Connect-TcIde -ProcessId 0
    Check 'P3 pid 0 -> IDE_PID_NOT_FOUND invalid-pid' ((-not $r.success) -and $r.error.code -eq 'IDE_PID_NOT_FOUND' -and $r.data.reason -eq 'invalid-pid') (J $r)

    $r = Connect-TcIde -ProcessId 9002 -SolutionPath $slnA
    $c = Get-Conn
    Check 'P4 pid has another .sln open -> IDE_PID_MISMATCH solution, its solution not replaced, not attached' ((-not $r.success) -and $r.error.code -eq 'IDE_PID_MISMATCH' -and $r.data.reason -eq 'solution' -and $r.data.ideProcessId -eq 9002 -and $global:Opens210.Count -eq 0 -and -not $c.connected -and $global:Launches210.Count -eq 0) (J $r)

    $r = Connect-TcIde -ProcessId 9002 -ProgId 'TcXaeShell.DTE.15.0'
    Check 'P5 ProgId differs from the ROT entry -> IDE_PID_MISMATCH progid' ((-not $r.success) -and $r.error.code -eq 'IDE_PID_MISMATCH' -and $r.data.reason -eq 'progid' -and $r.data.progId -eq 'VisualStudio.DTE.17.0') (J $r)

    $r = Connect-TcIde -ProcessId 9002 -SolutionPath $slnB -ProgId 'VisualStudio.DTE.17.0'
    $c = Get-Conn
    $noRec = & $mod { (-not (Test-Path -LiteralPath (Get-TcLaunchRecordPath))) -and $script:TcLaunchedIdes.Count -eq 0 -and -not (Test-TcLaunchedIde -ProcessId 9002) }
    Check 'P6 matching pid + solution -> attached, selectedBy process-id, not owned (user IDE), no launch record written' ($r.success -and $r.data.selectedBy -eq 'process-id' -and $r.data.ideProcessId -eq 9002 -and $r.data.ownedBySession -eq $false -and $c.connected -and $c.pid -eq 9002 -and $global:Opens210.Count -eq 0 -and $noRec) "$(J $r) noRecord=$noRec"
    $q = Disconnect-TcIde -Quit
    $c = Get-Conn
    Check 'Q1 #227 Disconnect-TcIde -Quit on that IDE -> IDE_NOT_OWNED, not quit, connection kept' ((-not $q.success) -and $q.error.code -eq 'IDE_NOT_OWNED' -and $q.data.quit -eq $false -and $q.data.disconnected -eq $false -and $global:Quits210.Count -eq 0 -and $c.connected -and $c.pid -eq 9002) (J $q)
    $q = Disconnect-TcIde -Quit -Kill
    Check 'Q2 #227 -Quit -Kill on that IDE -> IDE_NOT_OWNED, nothing quit or killed' ((-not $q.success) -and $q.error.code -eq 'IDE_NOT_OWNED' -and $global:Quits210.Count -eq 0) (J $q)
    $q = Disconnect-TcIde
    Check 'Q3 Disconnect-TcIde without -Quit releases it' ($q.success -and -not (Get-Conn).connected -and $global:Quits210.Count -eq 0) (J $q)

    $r = Connect-TcIde -ProcessId 9001
    Check 'P7 pid without -SolutionPath -> that IDE (not the first / another one)' ($r.success -and $r.data.ideProcessId -eq 9001 -and $r.data.selectedBy -eq 'process-id') (J $r)

    $r = Connect-TcIde -ProcessId 9003 -SolutionPath $slnA
    $noRec = & $mod { (-not (Test-Path -LiteralPath (Get-TcLaunchRecordPath))) -and $script:TcLaunchedIdes.Count -eq 0 -and -not (Test-TcLaunchedIde -ProcessId 9003) }
    Check 'P8 empty IDE -> -SolutionPath opened there (not in 9001 that has it open), not owned, no launch record' ($r.success -and $r.data.ideProcessId -eq 9003 -and $global:Opens210.Count -eq 1 -and $global:Opens210[0] -eq "9003|$slnA" -and $r.data.ownedBySession -eq $false -and $noRec) "$(J $r) opens=$($global:Opens210 -join ',') noRecord=$noRec"

    Set-Desktop
    $null = Add-Ide 9004 '' 'VisualStudio.DTE.17.0' $true
    $global:Modal210 = 'dialog'
    $r = Connect-TcIde -ProcessId 9004 -SolutionPath $slnA
    $c = Get-Conn
    Check 'P9 busy pid with a dialog -> IDE_MODAL_DIALOG, attached=false, pid hint' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.attached -eq $false -and $r.data.ideProcessId -eq 9004 -and -not $c.connected -and $r.error.hint -match '-ProcessId') (J $r)
    $global:Modal210 = 'none'
    $r = Connect-TcIde -ProcessId 9004
    Check 'P10 busy pid, no dialog -> IDE_BUSY, attached=false' ((-not $r.success) -and $r.error.code -eq 'IDE_BUSY' -and $r.data.attached -eq $false -and -not (Get-Conn).connected) (J $r)
    $global:Modal210 = 'incomplete'
    $r = Connect-TcIde -ProcessId 9004
    Check 'P11 busy pid, scan incomplete -> MODAL_SCAN_INCOMPLETE, attached=false' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.data.attached -eq $false) (J $r)
    $global:Modal210 = 'none'
    $null = Add-Ide 9005 '' 'VisualStudio.DTE.17.0' $false $true
    $r = Connect-TcIde -ProcessId 9005
    Check 'P12 unreadable DTE (empty Version) -> not attached (IDE_BUSY)' ((-not $r.success) -and $r.error.code -eq 'IDE_BUSY' -and $r.data.attached -eq $false -and $r.data.probe -match 'unreadable') (J $r)

    $r = Connect-TcIde -ProcessId 9001 -SolutionPath $slnA -TakeOverOrphan
    Check 'P13 -ProcessId with -TakeOverOrphan -> INVALID_PARAMS' ((-not $r.success) -and $r.error.code -eq 'INVALID_PARAMS') (J $r)

    # an IDE this session launched keeps its ownership through -ProcessId, -Quit quits it
    Set-Desktop
    & $mod { Add-TcLaunchedIde -ProcessId 9002 }
    $r = Connect-TcIde -ProcessId 9002 -SolutionPath $slnB
    Check 'P14 own launched IDE bound by pid -> ownedBySession=true' ($r.success -and $r.data.ownedBySession -eq $true) (J $r)
    $q = Disconnect-TcIde -Quit
    Check 'Q4 own IDE -> -Quit still quits it' ($q.success -and $q.data.quit -eq $true -and @($global:Quits210) -contains 9002) (J $q)

    # #227 without -ProcessId: solution-match on the user's IDE
    Set-Desktop
    $r = Connect-TcIde -SolutionPath $slnA -NoLaunch
    $q = Disconnect-TcIde -Quit
    Check 'Q5 #227 solution-match on a user IDE -> -Quit refused (IDE_NOT_OWNED)' ($r.success -and $r.data.selectedBy -eq 'solution-match' -and (-not $q.success) -and $q.error.code -eq 'IDE_NOT_OWNED' -and $global:Quits210.Count -eq 0) "$(J $q)"
    $null = Disconnect-TcIde
    $q = Disconnect-TcIde -Quit
    Check 'Q6 -Quit when not connected -> success, reason not connected (unchanged)' ($q.success -and $q.data.reason -eq 'not connected') (J $q)

    # --- L: #224 ---
    Set-Desktop
    $null = Add-Ide 9006 $slnBr
    $r = Connect-TcIde -SolutionPath $slnBr -NoLaunch
    Check 'L1 #224 .sln in a folder with [ ] is found and solution-matched (no FILE_NOT_FOUND)' ($r.success -and $r.data.ideProcessId -eq 9006 -and $r.data.selectedBy -eq 'solution-match') (J $r)
    $r = Connect-TcIde -SolutionPath (Join-Path $root 'Verify [226]\nothere.sln') -NoLaunch
    Check 'L2 missing .sln in such a folder -> FILE_NOT_FOUND' ((-not $r.success) -and $r.error.code -eq 'FILE_NOT_FOUND') (J $r)
    $wild = Join-Path $root 'Verify 2'
    New-Item -ItemType Directory -Path $wild -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $wild 'Br.sln') -Value 'x' -Encoding UTF8
    Remove-Item -LiteralPath $slnBr -Force
    $r = Connect-TcIde -SolutionPath $slnBr -NoLaunch
    Check 'L3 #224 [226] is not a wildcard: "Verify 2\Br.sln" exists, "Verify [226]\Br.sln" does not -> FILE_NOT_FOUND' ((-not $r.success) -and $r.error.code -eq 'FILE_NOT_FOUND') (J $r)
}
finally {
    Reset-State
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
