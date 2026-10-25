# Unit: Connect-TcIde -SolutionPath with a blocked IDE (issue #29), no IDE / runtime needed.
# Get-AllComObjects, Get-Process and Get-TcIdeModalDialog are replaced inside the module scope;
# the ProgId is a fake one, so Connect-TcIde can never launch a real IDE.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/blocked-solution-ide.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$slnDir = Join-Path $env:TEMP ("tcauto-unit-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $slnDir | Out-Null
$origLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $slnDir   # session records go to the temp folder
$sln = Join-Path $slnDir 'Demo.sln'
Set-Content -Path $sln -Value 'Microsoft Visual Studio Solution File, Format Version 12.00'

# Fake world: pid -> @{ Title; Dialog }
$global:FakeIde = @{}
& $mod {
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id)
        if ($global:FakeIde.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = $global:FakeIde[$Id].Title; MainWindowHandle = [IntPtr]::Zero; StartTime = [DateTime]'2026-01-01T00:00:00' } }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Get-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5)
        if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) { $ProcessId = [int]$script:TcIdeProcessId }
        if ($global:FakeIde.ContainsKey($ProcessId)) { return $global:FakeIde[$ProcessId].Dialog }
        $null
    }
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:FakeRot }
}

# A throwing property getter of a mock reads as $null in PowerShell (only a real COM object
# raises RPC_E_CALL_REJECTED), so the ROT probe of Connect-TcIde (Invoke-TcComRetry) is wrapped:
# objects marked Busy fail the way Invoke-TcComRetry fails after its busy retries.
& $mod {
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Invoke-TcComRetry {
        [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
        if ($OperationName -eq 'Read DTE.Version / Solution.FullName') {
            $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
            if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
        }
        & $script:UnitOrigComRetry @PSBoundParameters
    }
}
function New-Dte([string]$Mode) {
    $o = New-Object PSObject
    $o | Add-Member -MemberType NoteProperty -Name Version -Value ''   # unreadable: empty Version
    $o | Add-Member -MemberType NoteProperty -Name Busy -Value ($Mode -eq 'busy')
    $o
}
function Set-Rot([object[]]$Entries) {
    $global:FakeRot = @($Entries | ForEach-Object { @{ DisplayName = "!Fake.DTE.1:$($_.Pid)"; Object = (New-Dte $_.Mode); ProgId = 'Fake.DTE.1'; ProcessId = $_.Pid } })
}
$reload = @{ Title = 'TcXaeShell'; Text = "The project file '$slnDir\Demo\plc\plc.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"; Hwnd = 0; Buttons = @() }
$reloadOther = @{ Title = 'TcXaeShell'; Text = "The project file 'C:\Elsewhere\Demo\plc\plc.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"; Hwnd = 0; Buttons = @() }

try {
    # --- Find-TcBlockedSolutionIde ---
    $global:FakeIde = @{
        101 = @{ Title = 'Other - TcXaeShell'; Dialog = $reload }        # path inside wins over the title
        102 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null }           # busy, title only
        103 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reloadOther }    # same name, other folder
        104 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null }           # unreadable, no dialog: shutting down
        105 = @{ Title = 'Demo2 - TcXaeShell'; Dialog = $null }          # prefix of another name
    }
    $cands = @(
        [PSCustomObject]@{ pid = 101; progId = 'Fake.DTE.1'; unreadable = $true }
        [PSCustomObject]@{ pid = 102; progId = 'Fake.DTE.1'; busy = $true }
        [PSCustomObject]@{ pid = 103; progId = 'Fake.DTE.1'; busy = $true }
        [PSCustomObject]@{ pid = 104; progId = 'Fake.DTE.1'; unreadable = $true }
        [PSCustomObject]@{ pid = 105; progId = 'Fake.DTE.1'; busy = $true }
        [PSCustomObject]@{ pid = $null; progId = 'Fake.DTE.1'; busy = $true }
    )
    $hits = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } $cands $sln)
    $pids = @($hits | ForEach-Object { [int]$_.Candidate.pid })
    Check 'find-matches' (($pids -join ',') -eq '101,102') "pids=$($pids -join ',')"
    Check 'find-dialog-path-first' ($hits[0].MatchedBy -eq 'dialog-path' -and $hits[1].MatchedBy -eq 'window-title') "$($hits | ForEach-Object { $_.MatchedBy })"

    # --- Connect-TcIde -NoLaunch: unreadable IDE with the reload prompt of THIS solution ---
    $global:FakeIde = @{ 201 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload } }
    Set-Rot @(@{ Pid = 201; Mode = 'unreadable' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-modal-code' (-not $r.success -and $r.error.code -eq 'IDE_MODAL_DIALOG') "code=$($r.error.code) msg=$($r.error.message)"
    Check 'connect-modal-data' ($r.data.ideProcessId -eq 201 -and $r.data.matchedBy -eq 'dialog-path' -and $r.data.attached -and $r.data.dialogKind -eq 'reload-prompt' -and $r.data.rotDisplayName -eq '!Fake.DTE.1:201') "pid=$($r.data.ideProcessId) by=$($r.data.matchedBy) kind=$($r.data.dialogKind)"
    Check 'connect-modal-hint' ($r.error.hint -match 'Reset-TcSolution') "$($r.error.hint)"
    $st = & $mod { [PSCustomObject]@{ pid = $script:TcIdeProcessId; connected = $script:TcIdeConnected; by = $script:TcIdeSelectedBy; sln = $script:TcSolutionPath; sm = $script:TcSysManager } }
    Check 'connect-modal-attached' ($st.pid -eq 201 -and $st.connected -and $st.by -eq 'solution-blocked' -and $st.sln -eq $sln -and $null -eq $st.sm) "pid=$($st.pid) by=$($st.by) sln=$($st.sln)"

    # --- Connect-TcIde (no -NoLaunch): busy IDE, title match, no dialog -> IDE_BUSY, nothing launched ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $global:FakeIde = @{ 301 = @{ Title = 'Demo - Microsoft Visual Studio'; Dialog = $null } }
    Set-Rot @(@{ Pid = 301; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1'
    Check 'connect-busy-code' (-not $r.success -and $r.error.code -eq 'IDE_BUSY' -and $r.data.ideProcessId -eq 301 -and $r.data.matchedBy -eq 'window-title') "code=$($r.error.code) pid=$($r.data.ideProcessId)"
    Check 'connect-busy-not-attached' (-not $r.data.attached -and -not (& $mod { $script:TcIdeConnected })) "attached=$($r.data.attached)"
    Check 'connect-busy-hint' ($r.error.hint -match 'Get-TcIdeModalDialog') "$($r.error.hint)"

    # --- a busy IDE of ANOTHER solution does not block: Connect-TcIde goes on to launch (fake ProgId -> TWINCAT_NOT_FOUND) ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $global:FakeIde = @{ 401 = @{ Title = 'Other - TcXaeShell'; Dialog = $null } }
    Set-Rot @(@{ Pid = 401; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1'
    Check 'connect-other-launches' (-not $r.success -and $r.error.code -eq 'TWINCAT_NOT_FOUND') "code=$($r.error.code)"

    # --- -NoLaunch, unreadable IDE without a dialog (shutting down): IDE_NOT_FOUND as before ---
    $global:FakeIde = @{ 501 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    Set-Rot @(@{ Pid = 501; Mode = 'unreadable' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-shutting-down' (-not $r.success -and $r.error.code -eq 'IDE_NOT_FOUND') "code=$($r.error.code)"
    # --- session record of this very process (busy, title of another name, no dialog) -> strong, attached ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $global:FakeIde = @{ 601 = @{ Title = 'Renamed - TcXaeShell'; Dialog = $null }; 602 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 601 -Solution $s; Save-TcIdeSolutionRecord -ProcessId 602 -Solution 'C:\Elsewhere\Demo.sln' } $sln
    Set-Rot @(@{ Pid = 602; Mode = 'busy' }, @{ Pid = 601; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-record-strong' (-not $r.success -and $r.error.code -eq 'IDE_BUSY' -and $r.data.ideProcessId -eq 601 -and $r.data.matchedBy -eq 'session-record' -and $r.data.attached) "code=$($r.error.code) pid=$($r.data.ideProcessId) by=$($r.data.matchedBy)"
    Check 'connect-record-other-excluded' (@($r.data.blockedCandidates | Where-Object { $_.pid -eq 602 }).Count -eq 0) "blocked=$(@($r.data.blockedCandidates | ForEach-Object { $_.pid }) -join ',')"
    # --- dialog path in a NESTED copy (another .sln below our folder) is not ours; generic paths do not rule out ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $nested = Join-Path $slnDir 'copy\Demo'
    New-Item -ItemType Directory -Path $nested -Force | Out-Null
    Set-Content -Path (Join-Path $nested 'Demo.sln') -Value 'x'
    $global:FakeIde = @{
        701 = @{ Title = 'Demo - TcXaeShell'; Dialog = @{ Title = 'TcXaeShell'; Text = "The project file '$nested\plc\plc.plcproj' has been modified outside of TwinCAT XAE."; Hwnd = 0; Buttons = @() } }
        702 = @{ Title = 'Demo - TcXaeShell'; Dialog = @{ Title = 'Target system reports a fatal error'; Text = "'TwinCAT System' (10000): Error: see C:\TwinCAT\3.1\Boot\log.txt"; Hwnd = 0; Buttons = @() } }
    }
    $hits = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } @([PSCustomObject]@{ pid = 701; busy = $true }, [PSCustomObject]@{ pid = 702; busy = $true }) $sln)
    Check 'find-nested-copy-excluded' (@($hits | Where-Object { $_.Candidate.pid -eq 701 }).Count -eq 0) "hits=$(@($hits | ForEach-Object { "$($_.Candidate.pid):$($_.MatchedBy)" }) -join ',')"
    Check 'find-generic-path-weak' (@($hits | Where-Object { $_.Candidate.pid -eq 702 -and $_.MatchedBy -eq 'window-title' -and -not $_.Strong }).Count -eq 1) "hits=$(@($hits | ForEach-Object { "$($_.Candidate.pid):$($_.MatchedBy)" }) -join ',')"

    # --- weak only: IDE_BLOCKED_SAME_NAME hint, -LaunchIfBlocked goes on to launch ---
    Set-Rot @(@{ Pid = 702; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1'
    Check 'connect-weak-modal' (-not $r.success -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and -not $r.data.attached -and $r.error.hint -match 'LaunchIfBlocked') "code=$($r.error.code) attached=$($r.data.attached)"
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -LaunchIfBlocked
    Check 'connect-weak-launchifblocked' (-not $r.success -and $r.error.code -eq 'TWINCAT_NOT_FOUND') "code=$($r.error.code)"

    # --- module-state: the IDE this module was connected to, same solution (no record, other title) ---
    & $mod { param($s) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcIdeProcessId = 801; $script:TcSolutionPath = $s } $sln
    $global:FakeIde = @{ 801 = @{ Title = 'Something - TcXaeShell'; Dialog = $null } }
    Set-Rot @(@{ Pid = 801; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-module-state' (-not $r.success -and $r.error.code -eq 'IDE_BUSY' -and $r.data.matchedBy -eq 'module-state' -and $r.data.attached) "code=$($r.error.code) by=$($r.data.matchedBy)"
}
finally {
    & $mod { $script:TcDte = $null; $script:TcIdeConnected = $false; $script:TcIdeProcessId = $null; $script:TcSolutionPath = $null }
    $env:LOCALAPPDATA = $origLocalAppData
    Remove-Item -LiteralPath $slnDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name FakeIde, FakeRot -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit $fail
