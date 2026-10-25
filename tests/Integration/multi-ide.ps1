# Integration: several IDEs on the desktop at once - does the module pick the RIGHT one?
#   A  32-bit XAE with ANOTHER solution open (-OtherSolution)        interference 1
#   B  32-bit XAE with no solution                                   interference 2
#   C  VS2022 (devenv.exe) with nothing open, when installed         interference 3 (skipped + logged when absent)
#   D  Connect-TcIde -SolutionPath <target> -ProgId: must LAUNCH a new instance (nobody has the target
#      solution open), ideProcessId not in {A,B,C}, candidates[] lists A and B, A/B untouched
#   E  Connect-TcIde again: selectedBy = solution-match, same pid
#   F  modal dialog in A (DTE.ExecuteCommand from a background job): Get-TcIdeModalDialog on the target
#      -> null, on A's pid -> detected; then the dialog is closed (WM_CLOSE) / A is killed
#   G  Build-TcProject in the target succeeds; A/B still untouched
#   H  Disconnect-TcIde -Quit: only the target pid disappears, A/B/C keep running
#   I  cleanup: A/B/C are closed (only the ones this script started)
# Every step appends one JSON line to -LogPath (step, cmdlet, elapsedMs, pass, code, note, result);
# console prints "PASS/FAIL <step> [cmdlet] <code> <ms>". Exit code = number of failed steps.
# The whole run has a deadline (-DeadlineSec, default 900 s): once it is passed no further step starts
# and the cleanup runs. The pids this script started are written to <LogPath>.pids.json so an OUTER
# watchdog that kills this script can still clean them up.
# Run in a fresh Windows PowerShell 5.1 process (clean COM state):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Integration/multi-ide.ps1
# Needs: no IDE with the target solution already open (that instance would be solution-matched and
# QUIT at step H). IDEs that were already running are recorded and never touched.

param(
    [string]$SolutionPath = 'C:\Temp\TcFestoNoVisu\TwinCAT_Festo.sln',
    [string]$OtherSolution = 'C:\Temp\TcReloadTest\TwinCAT_Festo.sln',
    [string]$ProgId = 'TcXaeShell.DTE.15.0',
    [string]$XaeExe = 'C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe',
    [string]$DevenvExe = '',
    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\multi-ide.log'),
    [int]$DeadlineSec = 900,
    [switch]$SkipVs,
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45).
    [switch]$AllowUnresolvedLibrary
)

$ErrorActionPreference = 'Continue'
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
Import-Module $modulePath -Force
$mod = Get-Module TwinCATAutomation

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Set-Content -Path $LogPath -Value '' -Encoding UTF8
$pidsFile = "$LogPath.pids.json"

$script:failCount = 0
$script:deadline = (Get-Date).AddSeconds($DeadlineSec)
$script:started = [ordered]@{ A = 0; B = 0; C = 0; target = 0 }
$script:aKilledInF = $false
$script:preIdePids = @(Get-Process TcXaeShell*, devenv -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class MultiIdeWin {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static List<KeyValuePair<long, string>> Windows(int pid) {
        var list = new List<KeyValuePair<long, string>>();
        EnumWindows((h, p) => { uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)pid && IsWindowVisible(h)) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); list.Add(new KeyValuePair<long, string>((long)h, sb.ToString())); }
            return true; }, IntPtr.Zero);
        return list;
    }
    public static bool Close(long h) { return PostMessage((IntPtr)h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
}
'@

function Save-Pids {
    $script:started | ConvertTo-Json -Compress | Set-Content -Path $pidsFile -Encoding UTF8
}

function Write-StepLog {
    param([string]$Step, [string]$Cmdlet, [int]$ElapsedMs, [bool]$Pass, $Result, [string]$Note)
    $code = $null
    if ($null -ne $Result -and $Result.PSObject.Properties['error'] -and $null -ne $Result.error) { $code = $Result.error.code }
    $entry = [PSCustomObject]@{
        time      = (Get-Date).ToString('s')
        step      = $Step
        cmdlet    = $Cmdlet
        elapsedMs = $ElapsedMs
        pass      = $Pass
        code      = $code
        note      = $Note
        result    = $Result
    }
    $line = $entry | ConvertTo-Json -Depth 8 -Compress
    for ($try = 1; $try -le 10; $try++) {
        try { Add-Content -Path $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop; break }
        catch { if ($try -eq 10) { Write-Host "LOG WRITE FAILED: $($_.Exception.Message)" } else { Start-Sleep -Milliseconds 300 } }
    }
    if ($Pass) { $tag = 'PASS' } else { $tag = 'FAIL'; $script:failCount++ }
    $codeText = if ($code) { " $code" } else { '' }
    Write-Host ("{0} {1} [{2}]{3} {4}ms" -f $tag, $Step, $Cmdlet, $codeText, $ElapsedMs)
}

# Runs $Block, logs it, returns the result. $Check(result) decides pass/fail (default: .success).
# Past the deadline the step is logged as DEADLINE (fail) and the run is aborted.
function Invoke-Step {
    param([string]$Step, [string]$Cmdlet, [scriptblock]$Block, [scriptblock]$Check, [string]$Note)
    if ((Get-Date) -gt $script:deadline) {
        $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'DEADLINE'; message = "run deadline ($DeadlineSec s) passed before step $Step" } }
        Write-StepLog -Step $Step -Cmdlet $Cmdlet -ElapsedMs 0 -Pass $false -Result $r -Note $Note
        throw 'DEADLINE'
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = $null
    try { $r = & $Block }
    catch { $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SCRIPT_EXCEPTION'; message = $_.Exception.Message } } }
    $sw.Stop()
    $pass = $false
    try { $pass = if ($Check) { [bool](& $Check $r) } else { [bool]$r.success } } catch { $pass = $false; $Note = "$Note check threw: $($_.Exception.Message)" }
    Write-StepLog -Step $Step -Cmdlet $Cmdlet -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $pass -Result $r -Note $Note
    return $r
}

# Seconds left before the deadline, capped at $Max.
function Get-Budget([int]$Max) {
    $left = [int][Math]::Floor(($script:deadline - (Get-Date)).TotalSeconds)
    if ($left -lt 1) { return 1 }
    if ($left -gt $Max) { return $Max }
    return $left
}

# ROT snapshot without COM objects: pid / progId / solution per DTE entry (solution '<busy>' or
# '<error:...>' when the instance does not answer).
function Get-RotSnapshot {
    $entries = @(& $mod { Get-AllComObjects -IncludeDisplayName })
    $out = @()
    foreach ($e in $entries) {
        $sol = $null
        try {
            $s = $e['Object'].Solution
            $sol = if ($null -ne $s) { [string]$s.FullName } else { '' }
        }
        catch { $sol = if ($_.Exception.Message -match '0x80010001|RPC_E_CALL_REJECTED|busy') { '<busy>' } else { "<error:$($_.Exception.Message)>" } }
        $out += [PSCustomObject]@{ pid = $e['ProcessId']; progId = $e['ProgId']; solution = $sol; displayName = $e['DisplayName'] }
    }
    return $out
}

function Same-Path([string]$a, [string]$b) {
    if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b)) { return $false }
    try { return [string]::Equals([IO.Path]::GetFullPath($a), [IO.Path]::GetFullPath($b), [StringComparison]::OrdinalIgnoreCase) } catch { return $a -ieq $b }
}

# Polls the ROT until the pid shows up (and, when -Solution is given, has that solution open;
# -Empty: has no solution). Returns the snapshot entry (last seen one on timeout) or $null.
function Wait-RotEntry([int]$ProcId, [string]$Solution, [switch]$Empty, [int]$TimeoutSec) {
    $until = (Get-Date).AddSeconds((Get-Budget $TimeoutSec))
    $last = $null
    while ((Get-Date) -lt $until) {
        $snap = @(Get-RotSnapshot)
        $hit = $snap | Where-Object { $_.pid -eq $ProcId } | Select-Object -First 1
        if ($null -ne $hit) {
            $last = $hit
            $ok = $true
            if ($Solution) { $ok = Same-Path $hit.solution $Solution }
            elseif ($Empty) { $ok = [string]::IsNullOrWhiteSpace($hit.solution) }
            if ($ok) { return $hit }
        }
        Start-Sleep -Milliseconds 1000
    }
    return $last
}

function Get-IdeProcs {
    @(Get-Process TcXaeShell*, devenv -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, MainWindowTitle)
}

function Test-Alive([int]$ProcId) {
    if ($ProcId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcId -ErrorAction SilentlyContinue))
}

# Launches an interference IDE, waits for its ROT entry, logs it. Returns pid (0 when it failed).
function Start-Interference([string]$Key, [string]$Exe, [string[]]$ArgList, [string]$Solution, [switch]$Empty, [int]$TimeoutSec) {
    $r = Invoke-Step "$Key-start" "Start-Process $(Split-Path -Leaf $Exe) $($ArgList -join ' ')" {
        $p = if ($ArgList -and $ArgList.Count -gt 0) { Start-Process -FilePath $Exe -ArgumentList $ArgList -PassThru } else { Start-Process -FilePath $Exe -PassThru }
        $procId = [int]$p.Id
        $script:started[$Key] = $procId; Save-Pids
        [PSCustomObject]@{ success = ($procId -gt 0); data = [PSCustomObject]@{ pid = $procId; exe = $Exe; args = $ArgList } }
    }
    if (-not $r.success) { return 0 }
    $procId = [int]$r.data.pid
    $null = Invoke-Step "$Key-rot" "ROT entry for pid $procId" {
        $hit = Wait-RotEntry -ProcId $procId -Solution $Solution -Empty:$Empty -TimeoutSec $TimeoutSec
        $ok = $false
        if ($null -ne $hit) {
            $ok = if ($Solution) { Same-Path $hit.solution $Solution } elseif ($Empty) { [string]::IsNullOrWhiteSpace($hit.solution) } else { $true }
        }
        [PSCustomObject]@{ success = $ok; data = [PSCustomObject]@{ entry = $hit; alive = (Test-Alive $procId); windows = @([MultiIdeWin]::Windows($procId) | ForEach-Object { $_.Value }) } }
    } -Note "expected: $(if ($Solution) { "solution $Solution" } elseif ($Empty) { 'no solution' } else { 'any' })"
    return $procId
}

# Runs DTE.ExecuteCommand($Command) on the IDE with pid $ProcId in a background job (the call
# blocks while the modal dialog is open). Returns the job.
function Start-ModalJob([int]$ProcId, [string]$Command) {
    Start-Job -ArgumentList $modulePath, $ProcId, $Command -ScriptBlock {
        param($modulePath, $procId, $command)
        Import-Module $modulePath -Force
        $m = Get-Module TwinCATAutomation
        $entries = @(& $m { Get-AllComObjects -IncludeDisplayName })
        $e = $entries | Where-Object { $_['ProcessId'] -eq $procId } | Select-Object -First 1
        if ($null -eq $e) { return "no ROT entry for pid $procId" }
        try { $e['Object'].ExecuteCommand($command); return "ExecuteCommand($command) returned" }
        catch { return "ExecuteCommand($command) failed: $($_.Exception.Message)" }
    }
}

function Close-Interference([string]$Key) {
    $procId = [int]$script:started[$Key]
    if ($procId -le 0) { return }
    if (-not (Test-Alive $procId)) { $script:started[$Key] = 0; Save-Pids; return }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $note = ''
    try {
        $entries = @(& $mod { Get-AllComObjects -IncludeDisplayName })
        $e = $entries | Where-Object { $_['ProcessId'] -eq $procId } | Select-Object -First 1
        if ($null -ne $e) {
            try { $e['Object'].Solution.Close($false); $note += 'Solution.Close(false); ' } catch { $note += "Solution.Close: $($_.Exception.Message); " }
            try { $e['Object'].Quit(); $note += 'Quit(); ' } catch { $note += "Quit: $($_.Exception.Message); " }
        }
        else { $note += 'no ROT entry; ' }
    }
    catch { $note += "ROT: $($_.Exception.Message); " }
    $until = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $until -and (Test-Alive $procId)) { Start-Sleep -Milliseconds 500 }
    if (Test-Alive $procId) {
        try { Stop-Process -Id $procId -Force -Confirm:$false -ErrorAction Stop; $note += 'Stop-Process -Force; ' } catch { $note += "Stop-Process: $($_.Exception.Message); " }
        Start-Sleep -Seconds 2
    }
    $sw.Stop()
    $gone = -not (Test-Alive $procId)
    Write-StepLog -Step "I-close-$Key" -Cmdlet "close interference $Key (pid $procId)" -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $gone -Result ([PSCustomObject]@{ success = $gone; data = [PSCustomObject]@{ pid = $procId } }) -Note $note
    if ($gone) { $script:started[$Key] = 0; Save-Pids }
}

if (-not $DevenvExe) {
    $DevenvExe = @(Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\2022\*\Common7\IDE\devenv.exe', 'C:\Program Files (x86)\Microsoft Visual Studio\2022\*\Common7\IDE\devenv.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
}

$modalJob = $null
$pidA = 0; $pidB = 0; $pidC = 0; $pidTarget = 0
try {
    $null = Invoke-Step '00-preexisting' 'Get-Process TcXaeShell*, devenv' {
        [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ preIdePids = $script:preIdePids; procs = (Get-IdeProcs); rot = @(Get-RotSnapshot); deadlineSec = $DeadlineSec; devenv = $DevenvExe } }
    } -Note 'IDEs already running are never touched; an instance with the target solution already open would break step D'
    $busyTarget = @(Get-RotSnapshot | Where-Object { Same-Path $_.solution $SolutionPath })
    if ($busyTarget.Count -gt 0) {
        $null = Invoke-Step '00-target-already-open' 'ROT' { [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'PRECONDITION'; message = "target solution already open in pid $($busyTarget[0].pid); refusing to run (step H would quit it)" } } }
        throw 'PRECONDITION'
    }

    # A / B / C
    $pidA = Start-Interference -Key 'A' -Exe $XaeExe -ArgList @("`"$OtherSolution`"") -Solution $OtherSolution -TimeoutSec 180
    $pidB = Start-Interference -Key 'B' -Exe $XaeExe -ArgList @() -Empty -TimeoutSec 120
    if ($SkipVs -or -not $DevenvExe) {
        $null = Invoke-Step 'C-skipped' 'devenv.exe' { [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ reason = $(if ($SkipVs) { '-SkipVs' } else { 'devenv.exe not found' }) } } } -Note 'VS2022 interference instance skipped'
    }
    else {
        $pidC = Start-Interference -Key 'C' -Exe $DevenvExe -ArgList @('/nosplash') -TimeoutSec 120
    }
    $interferencePids = @(@($pidA, $pidB, $pidC) | Where-Object { $_ -gt 0 })
    $foreignPids = @($interferencePids + $script:preIdePids)

    # D: connect to the target solution -> must launch a NEW instance
    $d = Invoke-Step 'D-connect-launch' "Connect-TcIde -SolutionPath -ProgId $ProgId" { Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId } {
        param($x)
        if (-not $x.success) { return $false }
        $cpids = @($x.data.candidates | ForEach-Object { [int]$_.pid })
        ($x.data.selectedBy -eq 'launched') -and
        ([int]$x.data.ideProcessId -gt 0) -and
        ($foreignPids -notcontains [int]$x.data.ideProcessId) -and
        (Same-Path $x.data.solution $SolutionPath) -and
        (($pidA -le 0) -or ($cpids -contains $pidA)) -and
        (($pidB -le 0) -or ($cpids -contains $pidB))
    } -Note "expect selectedBy=launched, ideProcessId not in {A=$pidA,B=$pidB,C=$pidC,pre=$($script:preIdePids -join ',')}, candidates list A and B"
    if ($d.success -and [int]$d.data.ideProcessId -gt 0) { $pidTarget = [int]$d.data.ideProcessId; $script:started['target'] = $pidTarget; Save-Pids }
    $null = Invoke-Step 'D-others-untouched' 'ROT snapshot' {
        $snap = @(Get-RotSnapshot)
        $a = $snap | Where-Object { $_.pid -eq $pidA } | Select-Object -First 1
        $b = $snap | Where-Object { $_.pid -eq $pidB } | Select-Object -First 1
        $okA = ($pidA -le 0) -or ($null -ne $a -and (Same-Path $a.solution $OtherSolution))
        $okB = ($pidB -le 0) -or ($null -ne $b -and [string]::IsNullOrWhiteSpace($b.solution))
        [PSCustomObject]@{ success = ($okA -and $okB); data = [PSCustomObject]@{ a = $a; b = $b; rot = $snap; aliveA = (Test-Alive $pidA); aliveB = (Test-Alive $pidB); aliveC = (Test-Alive $pidC) } }
    } -Note 'A still has the other solution, B still empty (the target was not opened into them)'
    $null = Invoke-Step 'D-no-dialog' 'Get-TcIdeModalDialog (target)' {
        $dlg = & $mod { Get-TcIdeModalDialog }
        [PSCustomObject]@{ success = ($null -eq $dlg); data = [PSCustomObject]@{ dialog = $dlg; pid = (& $mod { $script:TcIdeProcessId }); mainHwnd = (& $mod { $script:TcIdeMainHwnd }) } }
    }
    if (-not $d.success -or $pidTarget -le 0 -or ($foreignPids -contains $pidTarget)) {
        # Wrong instance (or none): do not continue, step H would quit somebody else's IDE.
        if ($foreignPids -contains $pidTarget) { $script:started['target'] = 0; Save-Pids }
        throw 'ABORT'
    }

    # E: connect again -> solution-match, same pid
    $null = Invoke-Step 'E-connect-again' 'Connect-TcIde (same args)' { Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId } {
        param($x) $x.success -and ($x.data.selectedBy -eq 'solution-match') -and ([int]$x.data.ideProcessId -eq $pidTarget)
    } -Note "expect selectedBy=solution-match, ideProcessId=$pidTarget"

    # F: modal dialog in A, detection must stay per-pid
    if ($pidA -gt 0) {
        $detected = $null
        $usedCommand = $null
        foreach ($cmd in @('Tools.Options', 'Help.About')) {
            $modalJob = Start-ModalJob -ProcId $pidA -Command $cmd
            $r = Invoke-Step 'F-open-dialog-A' "DTE(A).ExecuteCommand('$cmd') via job; poll Get-TcIdeModalDialog -ProcessId $pidA" {
                $until = (Get-Date).AddSeconds((Get-Budget 30))
                $dlg = $null
                while ((Get-Date) -lt $until -and $null -eq $dlg) {
                    $dlg = & $mod { param($p) Get-TcIdeModalDialog -ProcessId $p } $pidA
                    if ($null -eq $dlg) { Start-Sleep -Milliseconds 1000 }
                }
                $jobState = [string]$modalJob.State
                $jobOut = if ($jobState -ne 'Running') { @(Receive-Job $modalJob -ErrorAction SilentlyContinue) -join ' ' } else { $null }
                [PSCustomObject]@{ success = ($null -ne $dlg); data = [PSCustomObject]@{ command = $cmd; dialog = $dlg; jobState = $jobState; jobOutput = $jobOut; windowsA = @([MultiIdeWin]::Windows($pidA) | ForEach-Object { $_.Value }) } }
            } -Note 'expect a dialog detected on A (title/text)'
            if ($r.success) { $detected = $r.data.dialog; $usedCommand = $cmd; break }
            try { Stop-Job $modalJob -ErrorAction SilentlyContinue; Remove-Job $modalJob -Force -ErrorAction SilentlyContinue } catch { }
            $modalJob = $null
        }

        $null = Invoke-Step 'F-target-no-dialog' 'Get-TcIdeModalDialog (connected target, default pid)' {
            $dlg = & $mod { Get-TcIdeModalDialog }
            [PSCustomObject]@{ success = ($null -eq $dlg); data = [PSCustomObject]@{ dialog = $dlg; pid = (& $mod { $script:TcIdeProcessId }) } }
        } -Note "A has a dialog open; the target (pid $pidTarget) must report none"
        $null = Invoke-Step 'F-target-no-dialog-explicit' "Get-TcIdeModalDialog -ProcessId $pidTarget" {
            $dlg = & $mod { param($p) Get-TcIdeModalDialog -ProcessId $p } $pidTarget
            [PSCustomObject]@{ success = ($null -eq $dlg); data = [PSCustomObject]@{ dialog = $dlg } }
        }
        $null = Invoke-Step 'F-A-dialog-detected' "Get-TcIdeModalDialog -ProcessId $pidA" {
            $dlg = & $mod { param($p) Get-TcIdeModalDialog -ProcessId $p } $pidA
            [PSCustomObject]@{ success = ($null -ne $dlg); data = [PSCustomObject]@{ dialog = $dlg; command = $usedCommand } }
        } -Note 'the dialog in A is seen when asked for pid A'

        $null = Invoke-Step 'F-close-dialog-A' 'PostMessage WM_CLOSE to the dialog; else kill A' {
            $closed = $false; $how = ''
            $title = if ($detected) { [string]$detected.Title } else { '' }
            $wins = @([MultiIdeWin]::Windows($pidA))
            $dlgWins = @($wins | Where-Object { $_.Value -and ($_.Value -eq $title -or ($title -and $_.Value -like "$title*")) })
            if ($dlgWins.Count -eq 0) { $dlgWins = @($wins | Where-Object { $_.Value -and $_.Value -notmatch '\s-\sTcXaeShell' }) }
            foreach ($w in $dlgWins) { $null = [MultiIdeWin]::Close($w.Key); $how += "WM_CLOSE '$($w.Value)'; " }
            $until = (Get-Date).AddSeconds((Get-Budget 30))
            while ((Get-Date) -lt $until) {
                $dlg = & $mod { param($p) Get-TcIdeModalDialog -ProcessId $p } $pidA
                if ($null -eq $dlg) { $closed = $true; break }
                Start-Sleep -Milliseconds 1000
            }
            if ($modalJob) { $null = Wait-Job $modalJob -Timeout 10 }
            $jobOut = if ($modalJob -and $modalJob.State -ne 'Running') { @(Receive-Job $modalJob -ErrorAction SilentlyContinue) -join ' ' } else { 'job still running' }
            if (-not $closed) {
                try { Stop-Process -Id $pidA -Force -Confirm:$false -ErrorAction Stop; $how += 'Stop-Process A; ' } catch { $how += "Stop-Process A: $($_.Exception.Message); " }
                Start-Sleep -Seconds 2
                $script:aKilledInF = $true
                $closed = -not (Test-Alive $pidA)
            }
            [PSCustomObject]@{ success = $closed; data = [PSCustomObject]@{ how = $how; jobOutput = $jobOut; aliveA = (Test-Alive $pidA); windowsA = @([MultiIdeWin]::Windows($pidA) | ForEach-Object { $_.Value }) } }
        }
        if ($modalJob) { try { Stop-Job $modalJob -ErrorAction SilentlyContinue; Remove-Job $modalJob -Force -ErrorAction SilentlyContinue } catch { }; $modalJob = $null }
    }
    else {
        $null = Invoke-Step 'F-skipped' 'no interference A' { [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'NO_A'; message = 'interference A did not start' } } }
    }

    # G: build in the target
    # Clean($false) + BuildState polling: the synchronous Clean($true) never returns through
    # out-of-process COM in VS2022 (same reason as Build-TcProject).
    $null = Invoke-Step 'G-clean' 'SolutionBuild.Clean($false)+poll' {
        $state = & $mod {
            $sb = Invoke-TcComRetry -MaxRetries 5 -OperationName 'SolutionBuild.Clean' -ScriptBlock { $x = $script:TcDte.Solution.SolutionBuild; $x.Clean($false); Write-Output -NoEnumerate $x }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $st = $null
            while ($sw.Elapsed.TotalSeconds -lt 120) {
                try { $st = [int]$sb.BuildState } catch { $st = $null }
                if ($st -eq 3 -and $sw.Elapsed.TotalSeconds -ge 1) { break }
                Start-Sleep -Milliseconds 500
            }
            $st
        }
        [PSCustomObject]@{ success = ($state -eq 3); data = [PSCustomObject]@{ buildState = $state } }
    }
    $null = Invoke-Step 'G-build' 'Build-TcProject' {
        $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        if ($b.data -and $b.data.PSObject.Properties['messages']) { $b.data.PSObject.Properties.Remove('messages') }
        $b
    } { param($x) $x.success -and $x.data.buildSucceeded -eq $true }
    $null = Invoke-Step 'G-others-untouched' 'ROT snapshot' {
        $snap = @(Get-RotSnapshot)
        $a = $snap | Where-Object { $_.pid -eq $pidA } | Select-Object -First 1
        $b = $snap | Where-Object { $_.pid -eq $pidB } | Select-Object -First 1
        $t = $snap | Where-Object { $_.pid -eq $pidTarget } | Select-Object -First 1
        $okA = ($pidA -le 0) -or (-not (Test-Alive $pidA)) -or ($null -ne $a -and (Same-Path $a.solution $OtherSolution))
        $okB = ($pidB -le 0) -or ($null -ne $b -and [string]::IsNullOrWhiteSpace($b.solution))
        $okT = ($null -ne $t -and (Same-Path $t.solution $SolutionPath))
        [PSCustomObject]@{ success = ($okA -and $okB -and $okT); data = [PSCustomObject]@{ a = $a; b = $b; target = $t } }
    } -Note 'A (if still alive after F) unchanged, B still empty, target still has the target solution'

    # H: quit only the target
    $null = Invoke-Step 'H-disconnect-quit' 'Disconnect-TcIde -Quit' { Disconnect-TcIde -Quit } { param($x) $x.success -and $x.data.quit -eq $true }
    $null = Invoke-Step 'H-only-target-gone' "wait pid $pidTarget exit; A/B/C alive" {
        $until = (Get-Date).AddSeconds((Get-Budget 60))
        while ((Get-Date) -lt $until -and (Test-Alive $pidTarget)) { Start-Sleep -Milliseconds 500 }
        $aliveT = Test-Alive $pidTarget
        $aliveA = Test-Alive $pidA; $aliveB = Test-Alive $pidB; $aliveC = Test-Alive $pidC
        $ok = (-not $aliveT) -and (($pidB -le 0) -or $aliveB) -and (($pidC -le 0) -or $aliveC)
        # A may have been killed in F when its dialog did not close; that is recorded there, not here.
        if ($pidA -gt 0 -and -not $script:aKilledInF) { $ok = $ok -and $aliveA }
        [PSCustomObject]@{ success = $ok; data = [PSCustomObject]@{ targetAlive = $aliveT; aAlive = $aliveA; bAlive = $aliveB; cAlive = $aliveC; aKilledInF = $script:aKilledInF; procs = (Get-IdeProcs) } }
    } -Note 'only the target pid may disappear'
    if (-not (Test-Alive $pidTarget)) { $script:started['target'] = 0; Save-Pids }
}
catch {
    if ($_.Exception.Message -notin @('ABORT', 'DEADLINE', 'PRECONDITION')) {
        Write-StepLog -Step 'XX-unhandled' -Cmdlet 'script' -ElapsedMs 0 -Pass $false -Result ([PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SCRIPT_EXCEPTION'; message = $_.Exception.Message; position = $_.InvocationInfo.PositionMessage } })
    }
}
finally {
    # I: cleanup (own processes only)
    if ($modalJob) { try { Stop-Job $modalJob -ErrorAction SilentlyContinue; Remove-Job $modalJob -Force -ErrorAction SilentlyContinue } catch { } }
    try { if (& $mod { $script:TcIdeConnected }) { $null = Disconnect-TcIde } } catch { }
    if ([int]$script:started['target'] -gt 0 -and (Test-Alive ([int]$script:started['target']))) {
        $tp = [int]$script:started['target']
        try { Stop-Process -Id $tp -Force -Confirm:$false -ErrorAction Stop } catch { }
        Write-StepLog -Step 'I-kill-target' -Cmdlet "Stop-Process $tp" -ElapsedMs 0 -Pass $true -Result ([PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ pid = $tp } }) -Note 'target IDE still alive after the run (H failed or run aborted): killed'
        $script:started['target'] = 0; Save-Pids
    }
    foreach ($k in @('A', 'B', 'C')) { Close-Interference -Key $k }
    $leftover = @(Get-IdeProcs | Where-Object { $script:preIdePids -notcontains [int]$_.Id })
    Write-StepLog -Step 'I-final' -Cmdlet 'Get-Process TcXaeShell*, devenv' -ElapsedMs 0 -Pass ($leftover.Count -eq 0) -Result ([PSCustomObject]@{ success = ($leftover.Count -eq 0); data = [PSCustomObject]@{ leftover = $leftover; preIdePids = $script:preIdePids } }) -Note 'no IDE started by this run may remain'
    Write-Host "DONE failed=$($script:failCount) log=$LogPath"
}
exit $script:failCount
