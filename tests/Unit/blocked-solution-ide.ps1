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
# GitHub's windows runner has TEMP = C:\Users\RUNNER~1\... (8.3 short name) while the module
# compares the long form it reads back (#43: this script failed only in CI). Use the long path.
if ($null -eq ([System.Management.Automation.PSTypeName]'TcUnitLongPath').Type) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
public static class TcUnitLongPath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint size);
    public static string Get(string p) {
        var sb = new StringBuilder(1024);
        uint n = GetLongPathName(p, sb, (uint)sb.Capacity);
        return (n > 0 && n < sb.Capacity) ? sb.ToString() : p;
    }
}
'@
}
$slnDir = [TcUnitLongPath]::Get($slnDir)
$origLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $slnDir   # session records go to the temp folder
$sln = Join-Path $slnDir 'Demo.sln'
Set-Content -Path $sln -Value 'Microsoft Visual Studio Solution File, Format Version 12.00'

# Fake world: pid -> @{ Title; Dialog }
$global:FakeIde = @{}
& $mod {
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id)
        if ($global:FakeIde.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = $global:FakeIde[$Id].Title; MainWindowHandle = [IntPtr]::Zero; StartTime = $(if ($global:FakeIde[$Id].Start) { [DateTime]$global:FakeIde[$Id].Start } else { [DateTime]'2026-01-01T00:00:00' }) } }
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
        if ($OperationName -eq 'Solution.FullName (guard)' -and $global:GuardThrows) { throw 'RPC_E_SERVERCALL_RETRYLATER (mock: XAE busy after the reload)' }
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
        101 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload }         # dialog path inside: strong
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
    # --- session record of this very process (busy, consistent title, no dialog) -> strong, attached ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $global:FakeIde = @{ 601 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null }; 602 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 601 -Solution $s; Save-TcIdeSolutionRecord -ProcessId 602 -Solution 'C:\Elsewhere\Other.sln' } $sln   # not a same-named Demo.sln: that would make the title useless (same-name-elsewhere-weak)
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

    # --- module-state: the IDE this module was connected to (pid + start time), same solution, no record ---
    & $mod { param($s) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcIdeProcessId = 801; $script:TcIdeStartTime = [DateTime]'2026-01-01T00:00:00'; $script:TcSolutionPath = $s } $sln
    $global:FakeIde = @{ 801 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    Set-Rot @(@{ Pid = 801; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch

    Check 'connect-module-state' (-not $r.success -and $r.error.code -eq 'IDE_BUSY' -and $r.data.matchedBy -eq 'module-state' -and $r.data.attached) "code=$($r.error.code) by=$($r.data.matchedBy)"
    # --- pid reuse: same pid as the previous connection but another start time -> not module-state ---
    & $mod { param($s) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcIdeProcessId = 811; $script:TcIdeStartTime = [DateTime]'2025-06-01T00:00:00'; $script:TcSolutionPath = $s } $sln
    $global:FakeIde = @{ 811 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    Set-Rot @(@{ Pid = 811; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'connect-pid-reuse' (-not $r.success -and $r.data.matchedBy -eq 'window-title' -and -not $r.data.attached) "by=$($r.data.matchedBy) attached=$($r.data.attached)"

    # --- S1: a failed / weak Connect-TcIde leaves no connection to the previous IDE ---
    $st = & $mod { $ok = $true; try { Assert-TcConnection } catch { $ok = $false }; [PSCustomObject]@{ ok = $ok; dte = $script:TcDte; pid = $script:TcIdeProcessId } }
    Check 'weak-clears-connection' (-not $st.ok -and $null -eq $st.dte -and $null -eq $st.pid) "assert=$($st.ok) pid=$($st.pid)"
    & $mod { $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcIdeProcessId = 999 }
    $global:FakeIde = @{}
    Set-Rot @()
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    $st = & $mod { $ok = $true; try { Assert-TcConnection } catch { $ok = $false }; $ok }
    Check 'notfound-clears-connection' ($r.error.code -eq 'IDE_NOT_FOUND' -and -not $st) "code=$($r.error.code) assert=$st"

    # --- B1: record says THIS solution, but the IDE now shows another one -> not attached ---
    $global:FakeIde = @{
        901 = @{ Title = 'Other - TcXaeShell'; Dialog = $null }      # record same, title contradicts
        902 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reloadOther } # record same, dialog names files elsewhere
    }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 901 -Solution $s; Save-TcIdeSolutionRecord -ProcessId 902 -Solution $s } $sln
    foreach ($bpid in 901, 902) {
        Set-Rot @(@{ Pid = $bpid; Mode = 'busy' })
        $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
        $conn = & $mod { $script:TcIdeConnected }
        Check "record-contradicted-$bpid" (-not $r.success -and $r.data.ideProcessId -eq $bpid -and $r.data.matchedBy -eq 'session-record' -and -not $r.data.attached -and $r.data.notAttachedReason -and -not $conn -and $r.error.message -match 'IDE_BLOCKED_SAME_NAME') "attached=$($r.data.attached) reason=$($r.data.notAttachedReason)"
    }

    # --- N1: two IDEs with strong evidence -> neither attached, both listed ---
    $global:FakeIde = @{ 911 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload }; 912 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload } }
    Set-Rot @(@{ Pid = 911; Mode = 'unreadable' }, @{ Pid = 912; Mode = 'unreadable' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'two-strong-none-attached' (-not $r.success -and -not $r.data.attached -and @($r.data.blockedCandidates).Count -eq 2 -and -not (& $mod { $script:TcIdeConnected })) "attached=$($r.data.attached) n=$(@($r.data.blockedCandidates).Count)"

    # --- S3: two paths in one dialog text are not glued together ---
    $paths = @(& $mod { param($x) Get-TcDialogProjectPaths -Text $x } "Copy from C:\TwinCAT\3.1\Boot to '$slnDir\Demo\plc\plc.plcproj' failed; see D:\Logs\x.tsproj")
    Check 'paths-not-glued' ($paths.Count -eq 2 -and $paths[0] -eq "$slnDir\Demo\plc\plc.plcproj" -and $paths[1] -eq 'D:\Logs\x.tsproj') "paths=$($paths -join ' | ')"
    $global:FakeIde = @{ 921 = @{ Title = 'Demo - TcXaeShell'; Dialog = @{ Title = 'x'; Text = "Copy from C:\TwinCAT\3.1\Boot to '$slnDir\Demo\plc\plc.plcproj' failed"; Hwnd = 0; Buttons = @() } } }
    $hits = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } @([PSCustomObject]@{ pid = 921; busy = $true }) $sln)
    Check 'two-paths-inside' ($hits.Count -eq 1 -and $hits[0].MatchedBy -eq 'dialog-path' -and $hits[0].Strong) "hits=$(@($hits | ForEach-Object { "$($_.MatchedBy):$($_.Strong)" }) -join ',')"

    # --- after an attach, Disconnect-TcIde -Quit acts on THAT pid only (modal up -> IDE_QUIT_FAILED, nothing quit) ---
    $global:FakeIde = @{ 931 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload } }
    Set-Rot @(@{ Pid = 931; Mode = 'unreadable' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    $global:QuitCalled = $false
    & $mod { $script:TcDte | Add-Member -MemberType ScriptMethod -Name Quit -Value { $global:QuitCalled = $true } -Force }
    $q = Disconnect-TcIde -Quit
    Check 'attached-quit-targets-pid' ($r.data.attached -and -not $q.success -and $q.error.code -eq 'IDE_QUIT_FAILED' -and $q.data.ideProcessId -eq 931 -and -not $global:QuitCalled) "code=$($q.error.code) pid=$($q.data.ideProcessId) quit=$global:QuitCalled"
    # --- F1: record says THIS solution, but no current fact (title empty, no dialog) -> not attached ---
    $global:FakeIde = @{ 941 = @{ Title = ''; Dialog = $null } }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 941 -Solution $s } $sln
    Set-Rot @(@{ Pid = 941; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'record-no-current-fact' (-not $r.success -and $r.data.matchedBy -eq 'session-record' -and -not $r.data.attached -and $r.data.notAttachedReason -match 'no current evidence') "attached=$($r.data.attached) reason=$($r.data.notAttachedReason)"

    # --- F2: module-state says this solution, the session record says another -> contradiction ---
    $global:FakeIde = @{ 951 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 951 -Solution 'C:\Elsewhere\Other.sln'; $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{}; $script:TcIdeProcessId = 951; $script:TcIdeStartTime = [DateTime]'2026-01-01T00:00:00'; $script:TcSolutionPath = $s } $sln
    Set-Rot @(@{ Pid = 951; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'module-vs-record' (-not $r.success -and $r.data.matchedBy -eq 'module-state' -and -not $r.data.attached -and $r.data.notAttachedReason -match 'session record') "attached=$($r.data.attached) reason=$($r.data.notAttachedReason)"

    # --- ownership survives a failed Connect-TcIde: a launched IDE is attached as 'launched' later ---
    $global:FakeIde = @{ 961 = @{ Title = 'Demo - TcXaeShell'; Dialog = $reload } }
    & $mod { Add-TcLaunchedIde -ProcessId 961 }
    Set-Rot @()
    $null = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch      # IDE_NOT_FOUND, selectedBy cleared
    Set-Rot @(@{ Pid = 961; Mode = 'unreadable' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'ownership-kept' ($r.data.attached -and $r.data.ownedBySession -and (& $mod { $script:TcIdeSelectedBy }) -eq 'launched') "attached=$($r.data.attached) owned=$($r.data.ownedBySession)"

    # --- SilentMode original is kept per process across a Connect-TcIde that clears the state ---
    & $mod { Set-TcIdeSilentOriginal -ProcessId 961 -Value $false }
    Set-Rot @()
    $null = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    $orig = & $mod { Get-TcIdeSilentOriginal -ProcessId 961 }
    $global:FakeIde[961].Start = '2026-02-02T00:00:00'   # pid recycled: other start time
    $origRecycled = & $mod { Get-TcIdeSilentOriginal -ProcessId 961 }
    Check 'silent-original-kept' ($orig -eq $false -and $null -ne $orig -and $null -eq $origRecycled) "orig=$orig recycled=$origRecycled"

    # --- Reset-TcSolution refuses when the IDE has another solution open than the module expects ---
    $global:FakeIde = @{ 971 = @{ Title = 'Other - TcXaeShell'; Dialog = $null } }
    $global:ClosedSolution = $false
    $fakeSol = [PSCustomObject]@{ FullName = 'C:\Elsewhere\Other.sln' }
    $fakeSol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($save) $global:ClosedSolution = $true }
    $fakeDocs = [PSCustomObject]@{ Count = 0 }
    $fakeDocs | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($x) $global:ClosedSolution = $true }
    & $mod { param($s, $so, $dc) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ Solution = $so; Documents = $dc }; $script:TcIdeProcessId = 971; $script:TcSolutionPath = $s } $sln $fakeSol $fakeDocs
    $r = Reset-TcSolution -TimeoutSec 10
    Check 'reset-mismatch-refused' (-not $r.success -and $r.error.code -eq 'RESET_SOLUTION_MISMATCH' -and -not $global:ClosedSolution -and $r.data.openSolution -eq 'C:\Elsewhere\Other.sln') "code=$($r.error.code) closed=$global:ClosedSolution"
    # --- blocker: guard read keeps failing -> RESET_SOLUTION_UNVERIFIED, nothing closed ---
    $global:ClosedSolution = $false
    $okSol = [PSCustomObject]@{ FullName = $sln }
    $okSol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($save) $global:ClosedSolution = $true }
    & $mod { param($s, $so, $dc) $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ Solution = $so; Documents = $dc }; $script:TcIdeProcessId = 971; $script:TcSolutionPath = $s } $sln $okSol $fakeDocs
    $global:GuardThrows = $true
    $r = Reset-TcSolution -TimeoutSec 5
    $global:GuardThrows = $false
    Check 'reset-guard-unreadable-fails-closed' (-not $r.success -and $r.error.code -eq 'RESET_SOLUTION_UNVERIFIED' -and -not $global:ClosedSolution -and $r.data.guardError -match 'RETRYLATER') "code=$($r.error.code) closed=$global:ClosedSolution"

    # --- should-fix 2: a same-named .sln known open elsewhere -> the title does not corroborate a record ---
    $global:FakeIde = @{ 981 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    & $mod { param($s) Save-TcIdeSolutionRecord -ProcessId 981 -Solution $s } $sln
    $hits = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s -KnownSolutions @('C:\Elsewhere\Demo.sln') } @([PSCustomObject]@{ pid = 981; busy = $true }) $sln)
    Check 'same-name-elsewhere-weak' ($hits.Count -eq 1 -and -not $hits[0].Strong -and $null -eq $hits[0].CorroboratedBy -and $hits[0].Contradiction -match 'same-named') "strong=$($hits[0].Strong) why=$($hits[0].Contradiction)"
    $hits = @(& $mod { param($c, $s) Find-TcBlockedSolutionIde -Candidates $c -SolutionPath $s } @([PSCustomObject]@{ pid = 981; busy = $true }) $sln)
    Check 'record-title-corroborated' ($hits.Count -eq 1 -and $hits[0].Strong -and $hits[0].CorroboratedBy -eq 'window-title') "strong=$($hits[0].Strong) by=$($hits[0].CorroboratedBy)"

    # --- nit: weak match on an IDE this session launched -> IDE_BLOCKED_OWN hint, no -LaunchIfBlocked advice ---
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null; $script:TcSolutionPath = $null }
    $global:FakeIde = @{ 991 = @{ Title = 'Demo - TcXaeShell'; Dialog = $null } }
    & $mod { Add-TcLaunchedIde -ProcessId 991 }
    Set-Rot @(@{ Pid = 991; Mode = 'busy' })
    $r = Connect-TcIde -SolutionPath $sln -ProgId 'Fake.DTE.1' -NoLaunch
    Check 'weak-own-ide-hint' (-not $r.data.attached -and $r.data.launchedBySession -and $r.error.hint -match 'Stop-Process' -and $r.error.hint -match 'launchedBySession = true') "launched=$($r.data.launchedBySession) hint=$($r.error.hint.Substring(0, 30))"

    # --- nit: unreadable SilentMode original is remembered as 'unknown', never as true ---
    & $mod { Set-TcIdeSilentOriginal -ProcessId 991 -Value 'unknown' }
    $so = & $mod { Get-TcIdeSilentOriginal -ProcessId 991 }
    Check 'silent-unknown' ($so -is [string] -and $so -eq 'unknown') "value=$so"
}
finally {
    & $mod { $script:TcDte = $null; $script:TcIdeConnected = $false; $script:TcIdeProcessId = $null; $script:TcSolutionPath = $null }
    $env:LOCALAPPDATA = $origLocalAppData
    Remove-Item -LiteralPath $slnDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name FakeIde, FakeRot -Scope Global -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
