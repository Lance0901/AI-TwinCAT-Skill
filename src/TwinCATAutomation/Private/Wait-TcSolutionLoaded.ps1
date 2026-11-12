# Solution load readback for Reset-TcSolution (#135 F5, seen once 2026-11-05, 4024 TcXaeShell
# 32-bit): right after a successful Reset-TcSolution, Build-TcProject failed with a null-valued
# expression (not a compiler error) and a retry worked. That XAE was still loading the solution
# is an inference, not observed. Reset-TcSolution only returns success after these reads all show
# a loaded solution.

function Test-TcIdeCrashedMessage {
    # IDE_CRASHED from Invoke-TcComRetry (message start) or wrapped by a property getter
    # ('Exception getting "X": "IDE_CRASHED: ..."').
    param([AllowNull()][string]$Message)
    return (-not [string]::IsNullOrEmpty($Message) -and $Message -match '(^|")IDE_CRASHED:')
}

function Read-TcTipcPlcName {
    <#
    .SYNOPSIS
        LookupTreeItem('TIPC') on -SysManager and the names of its children (the PLC projects),
        in one Invoke-TcComRetry -MaxRetries 1. Throws what the COM call throws.
    .OUTPUTS
        Hashtable @{ Tipc = [bool]; Plcs = [string[]] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$SysManager
    )
    $sm = $SysManager
    Invoke-TcComRetry -MaxRetries 1 -OperationName 'LookupTreeItem TIPC (load check)' -ScriptBlock {
        $r = @{ Tipc = $false; Plcs = @() }
        $tipc = $sm.LookupTreeItem('TIPC')
        if ($null -eq $tipc) { return $r }
        $r.Tipc = $true
        $names = [System.Collections.Generic.List[string]]::new()
        $cnt = [int]$tipc.ChildCount
        for ($i = 1; $i -le $cnt; $i++) {
            $child = $tipc.Child($i)
            $names.Add([string]$child.Name)
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($child) | Out-Null } catch { }
        }
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tipc) | Out-Null } catch { }
        $r.Plcs = $names.ToArray()
        $r
    }
}

function Get-TcTsprojPlcName {
    <#
    .SYNOPSIS
        PLC project names a .tsproj lists: the Name attribute of every <Plc><Project Name="..."
        PrjFilePath="..."> element (read 2026-11-07 from the 4024 copy BFH_1650.tsproj, PLC1, and
        the 4026 copy AxisInterface_Type01_Library.tsproj, AxisInterface; both
        TcSmProject/Project/Plc/Project). A PLC kept in an independent project file (.xti) has no
        Name there (not verified, no such project here) and is not listed. Throws when the file
        is not readable XML.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.Load($Path)
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @($xml.SelectNodes('/TcSmProject/Project/Plc/Project[@Name]'))) {
        $n = [string]$node.GetAttribute('Name')
        if (-not [string]::IsNullOrWhiteSpace($n) -and -not $names.Contains($n)) { $names.Add($n) }
    }
    return $names.ToArray()
}

function Get-TcSolutionLoadExpectation {
    <#
    .SYNOPSIS
        What the readback expects after the reload / reopen, from DISK first (#135 review S2/S5/S6).
    .DESCRIPTION
        The .tsproj files the .sln references (Get-TcSlnTsProjFiles):
          none      -> the memory baseline when it has PLC names: from 'memory', requireTipc =
                       $true (PR #173 review); else from 'none', requireTipc = $false (a solution
                       without a TwinCAT project is loaded without TIPC)
          PLC names in the .tsproj (Get-TcTsprojPlcName) -> from 'disk', every name below TIPC
          no names  -> the memory baseline (PLC names below TIPC before the reset) when it has
                       some: from 'memory'; else from 'none' with requireTipc = $true and
                       minPlcCount = 1 (TIPC answers and has at least one child)
        expectationSource = from ('disk' | 'memory' | 'none'); 'none' tells the caller that no
        PLC names were expected (the readback is weaker). Never throws.
    .OUTPUTS
        [PSCustomObject]@{ from; requireTipc; plcs; minPlcCount; tsproj; error; expectationSource }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter()]
        [AllowNull()]
        [object]$MemoryBaseline
    )
    $e = [PSCustomObject]@{ from = 'none'; requireTipc = $false; plcs = @(); minPlcCount = 0; tsproj = @(); error = $null; expectationSource = 'none' }
    $mem = @()
    if ($null -ne $MemoryBaseline -and $MemoryBaseline.known) { $mem = @($MemoryBaseline.plcs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) }
    $ts = @(Get-TcSlnTsProjFiles -SolutionFile $SolutionPath)
    $e.tsproj = $ts
    if ($ts.Count -eq 0) {
        # PR #173 review: no .tsproj found from the .sln, but step 0 saw PLCs below TIPC: the
        # memory baseline still holds (TIPC required), the readback is not weakened.
        if ($mem.Count -gt 0) {
            $e.from = 'memory'; $e.expectationSource = 'memory'; $e.requireTipc = $true; $e.plcs = $mem; $e.minPlcCount = $mem.Count
        }
        return $e
    }
    $e.requireTipc = $true
    $names = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $ts) {
        try { foreach ($n in @(Get-TcTsprojPlcName -Path $t)) { if (-not $names.Contains($n)) { $names.Add($n) } } }
        catch { $errors.Add("$([IO.Path]::GetFileName($t)): $($_.Exception.Message)") }
    }
    if ($errors.Count -gt 0) { $e.error = $errors -join '; ' }
    if ($names.Count -gt 0) {
        $e.from = 'disk'; $e.expectationSource = 'disk'; $e.plcs = $names.ToArray(); $e.minPlcCount = $names.Count
        return $e
    }
    if ($mem.Count -gt 0) {
        $e.from = 'memory'; $e.expectationSource = 'memory'; $e.plcs = $mem; $e.minPlcCount = $mem.Count
        return $e
    }
    $e.minPlcCount = 1
    return $e
}

function Get-TcSolutionLoadBaseline {
    <#
    .SYNOPSIS
        Memory baseline for Get-TcSolutionLoadExpectation: the PLC names below TIPC before the
        reset, through a fresh Get-TcSysManager -Refresh (#106: never the cached one). Never throws.
    .OUTPUTS
        [PSCustomObject]@{ known; plcs; error }
    #>
    [CmdletBinding()]
    param()
    $b = [PSCustomObject]@{ known = $false; plcs = @(); error = $null }
    $sm = $null
    try { $sm = Get-TcSysManager -Refresh -MaxRetries 1 } catch { $b.error = [string]$_.Exception.Message; return $b }
    if ($null -eq $sm) {
        $b.error = 'no ITcSysManager'
        if (-not [string]::IsNullOrWhiteSpace([string]$script:TcLastSysManagerError)) { $b.error += ": $($script:TcLastSysManagerError)" }
        return $b
    }
    try { $t = Read-TcTipcPlcName -SysManager $sm }
    catch { $b.error = [string]$_.Exception.Message; return $b }
    if (-not $t.Tipc) { $b.error = "LookupTreeItem('TIPC') returned null"; return $b }
    $b.plcs = @($t.Plcs)
    $b.known = $true
    return $b
}

function Read-TcSolutionLoadState {
    <#
    .SYNOPSIS
        One read of the solution load state on -Dte. Never throws.
    .DESCRIPTION
        Every DTE read goes through Invoke-TcComRetry -MaxRetries 1 (one attempt, no busy backoff:
        the caller polls), the ITcSysManager through Get-TcSysManager -MaxRetries 1. Reads:
          solution   DTE.Solution, Solution.FullName, Solution.IsOpen, the number of
                     Solution.Projects without the Miscellaneous Files project (UniqueName
                     '<MiscFiles>', EnvDTE vsMiscFilesProjectUniqueName; left out because it is
                     only there while loose files are open and Reset-TcSolution closes every
                     document - an inference, not measured), Solution.SolutionBuild and
                     SolutionBuild.ActiveConfiguration.
          TwinCAT    (-NeedTipc only) ITcSysManager ($script:TcSysManager, else
                     Get-TcSysManager -Refresh), LookupTreeItem('TIPC') and the names of its
                     children. A LookupTreeItem that throws clears $script:TcSysManager (review
                     S3), so the next read takes a fresh one.
        NoAnswer = $true when a read threw or DTE.Solution / Solution.FullName answered $null:
        what a modal dialog looks like (Reset-TcSolution #87), so the caller scans for one.
        Crashed = the IDE_CRASHED message when a read reported that the IDE process is gone.
    .OUTPUTS
        Hashtable @{ fullName; isOpen; projectCount; solutionBuild; activeConfiguration; tipc;
        plcs; error; NoAnswer; Crashed }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Dte,

        [Parameter()]
        [switch]$NeedTipc
    )
    $out = [ordered]@{ fullName = $null; isOpen = $null; projectCount = $null; solutionBuild = $false; activeConfiguration = $false
        tipc = $false; plcs = @(); error = $null; NoAnswer = $false; Crashed = $null }
    if ($null -eq $Dte) { $out.error = 'no DTE'; $out.NoAnswer = $true; return $out }
    try {
        $s = Invoke-TcComRetry -MaxRetries 1 -OperationName 'Solution load state' -ScriptBlock {
            $r = @{ Solution = $false; FullName = $null; IsOpen = $null; ProjectCount = $null; SolutionBuild = $false; ActiveConfiguration = $false }
            $sol = $Dte.Solution
            if ($null -eq $sol) { return $r }
            $r.Solution = $true
            $r.FullName = $sol.FullName
            $r.IsOpen = [bool]$sol.IsOpen
            $projects = $sol.Projects
            if ($null -ne $projects) {
                $n = [int]$projects.Count
                $c = 0
                for ($i = 1; $i -le $n; $i++) {
                    $p = $projects.Item($i)
                    if ($null -eq $p) { continue }
                    if ([string]$p.UniqueName -ne '<MiscFiles>') { $c++ }
                }
                $r.ProjectCount = $c
            }
            $sb = $sol.SolutionBuild
            if ($null -ne $sb) {
                $r.SolutionBuild = $true
                $r.ActiveConfiguration = ($null -ne $sb.ActiveConfiguration)
            }
            $r
        }
        if (-not $s.Solution) { $out.error = 'DTE.Solution answered $null'; $out.NoAnswer = $true; return $out }
        if ($null -ne $s.FullName) { $out.fullName = [string]$s.FullName }
        else { $out.error = 'Solution.FullName answered $null'; $out.NoAnswer = $true }
        $out.isOpen = $s.IsOpen
        $out.projectCount = $s.ProjectCount
        $out.solutionBuild = [bool]$s.SolutionBuild
        $out.activeConfiguration = [bool]$s.ActiveConfiguration
    }
    catch {
        $out.error = [string]$_.Exception.Message
        $out.NoAnswer = $true
        if (Test-TcIdeCrashedMessage $out.error) { $out.Crashed = $out.error }
        return $out
    }
    if (-not $NeedTipc) { return $out }

    $sm = $script:TcSysManager
    if ($null -eq $sm) {
        try { $sm = Get-TcSysManager -Refresh -MaxRetries 1 }
        catch { $sm = $null; $script:TcLastSysManagerError = [string]$_.Exception.Message }
        if ($null -eq $sm) {
            $why = [string]$script:TcLastSysManagerError
            if (Test-TcIdeCrashedMessage $why) { $out.Crashed = $why; $out.NoAnswer = $true }
            elseif (-not [string]::IsNullOrWhiteSpace($why)) { $out.NoAnswer = $true }
            if ($null -eq $out.error) { $out.error = if ([string]::IsNullOrWhiteSpace($why)) { 'no ITcSysManager in Solution.Projects' } else { "no ITcSysManager: $why" } }
            return $out
        }
    }
    try {
        $t = Read-TcTipcPlcName -SysManager $sm
        $out.tipc = [bool]$t.Tipc
        $out.plcs = @($t.Plcs)
        if (-not $out.tipc -and $null -eq $out.error) { $out.error = "LookupTreeItem('TIPC') returned null" }
    }
    catch {
        # review S3: a stale ITcSysManager (e.g. "System Manager already disposed!") is dropped
        $script:TcSysManager = $null
        $out.error = [string]$_.Exception.Message
        $out.NoAnswer = $true
        if (Test-TcIdeCrashedMessage $out.error) { $out.Crashed = $out.error }
    }
    return $out
}

function Wait-TcSolutionLoaded {
    <#
    .SYNOPSIS
        Polls until the solution -SolutionPath is loaded in the connected IDE (Reset-TcSolution
        readback before success, #135 F5).
    .DESCRIPTION
        Expectation from disk (Get-TcSolutionLoadExpectation; -MemoryBaseline is its fallback).
        Every 500 ms Read-TcSolutionLoadState on $script:TcDte until ALL hold:
          - Solution.FullName equals -SolutionPath (Get-TcLongPath, OrdinalIgnoreCase)
          - Solution.IsOpen
          - Solution.Projects (without Miscellaneous Files) >= 1
          - Solution.SolutionBuild and SolutionBuild.ActiveConfiguration are not $null
          - when the .sln references a .tsproj: LookupTreeItem('TIPC') is not $null, every
            expected PLC name is a child of TIPC (case-insensitive) and it has at least
            minPlcCount children
        A poll whose read got no answer (exception, DTE.Solution / FullName $null) scans for a
        modal dialog (Find-TcIdeModalDialog); a dialog (an incomplete scan does not count, #42)
        ends the wait with .Dialog set. Before giving up at the deadline the dialog is scanned
        once more (review N5). A read reporting IDE_CRASHED ends it at once (.Crashed). The
        deadline is shared with the caller: -Stopwatch reaching -TimeoutSec (at least one poll).
    .OUTPUTS
        Hashtable @{ Complete = [bool]; Dialog = <dialog record or $null>; Crashed = <message or
        $null>; LoadCheck = [PSCustomObject]@{ complete; sec; polls; expectedFrom ('disk' |
        'memory' | 'none'); expectationSource (same value; 'none' = no PLC names expected); expected{requireTipc, plcs, minPlcCount, tsproj}; expectationError;
        last{fullName, isOpen, projectCount, solutionBuild, activeConfiguration, tipc, plcs};
        lastError } }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter()]
        [AllowNull()]
        [object]$MemoryBaseline,

        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory)]
        [int]$TimeoutSec
    )
    $wsw = [System.Diagnostics.Stopwatch]::StartNew()
    # #241: same time scale as the caller Reset-TcSolution ($script:TcResetTimeScale, 1.0 = real seconds)
    $timeScale = Get-TcTimeScale -Value $script:TcResetTimeScale
    $pollMs = if ($timeScale -eq 1.0) { 500 } else { [int][math]::Max(1, [math]::Round(500 * $timeScale)) }
    $exp = Get-TcSolutionLoadExpectation -SolutionPath $SolutionPath -MemoryBaseline $MemoryBaseline
    $want = try { Get-TcLongPath $SolutionPath } catch { $SolutionPath }
    $polls = 0
    $complete = $false
    $dialog = $null
    $crashed = $null
    $last = $null
    $lastError = $null
    while ($true) {
        $polls++
        $snap = Read-TcSolutionLoadState -Dte $script:TcDte -NeedTipc:($exp.requireTipc)
        $last = $snap
        if ($null -ne $snap.Crashed) { $crashed = [string]$snap.Crashed; $lastError = $crashed; break }   # review S4
        $missing = [System.Collections.Generic.List[string]]::new()
        $fullOk = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$snap.fullName)) {
            $have = try { Get-TcLongPath ([string]$snap.fullName) } catch { [string]$snap.fullName }
            $fullOk = [string]::Equals($have, $want, [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $fullOk) { $missing.Add("Solution.FullName '$($snap.fullName)' is not '$want'") }
        if ($snap.isOpen -ne $true) { $missing.Add('Solution.IsOpen is not true') }
        if ($null -eq $snap.projectCount -or [int]$snap.projectCount -lt 1) { $missing.Add("Solution.Projects $($snap.projectCount) < 1") }
        if (-not $snap.solutionBuild) { $missing.Add('Solution.SolutionBuild is $null') }
        elseif (-not $snap.activeConfiguration) { $missing.Add('SolutionBuild.ActiveConfiguration is $null') }
        if ($exp.requireTipc) {
            if (-not $snap.tipc) { $missing.Add("LookupTreeItem('TIPC') not available") }
            else {
                $lost = @($exp.plcs | Where-Object { $n = [string]$_; -not @($snap.plcs | Where-Object { [string]::Equals([string]$_, $n, [StringComparison]::OrdinalIgnoreCase) }) })
                if ($lost.Count -gt 0) { $missing.Add("PLC project(s) not below TIPC: $($lost -join ', ')") }
                elseif (@($snap.plcs).Count -lt $exp.minPlcCount) { $missing.Add("TIPC has $(@($snap.plcs).Count) child(ren), expected at least $($exp.minPlcCount)") }
            }
        }
        if ($missing.Count -eq 0) { $complete = $true; $lastError = $null; break }
        $lastError = if ($null -ne $snap.error) { "$($snap.error); $($missing -join '; ')" } else { $missing -join '; ' }

        $timeUp = $Stopwatch.Elapsed.TotalSeconds / $timeScale -ge $TimeoutSec
        if ($snap.NoAnswer -or $timeUp) {
            # review N5: also one last scan before giving up
            $d = Find-TcIdeModalDialog
            if (Test-TcModalScanIncomplete $d) { $d = $null }   # #42: unknown, keep polling
            if ($null -ne $d) { $dialog = $d; break }
        }
        if ($timeUp) { break }
        Start-Sleep -Milliseconds $pollMs
    }
    $loadCheck = [PSCustomObject]@{
        complete         = $complete
        sec              = [math]::Round($wsw.Elapsed.TotalSeconds, 1)
        polls            = $polls
        expectedFrom     = $exp.from
        expectationSource = $exp.expectationSource
        expected         = [PSCustomObject]@{ requireTipc = [bool]$exp.requireTipc; plcs = @($exp.plcs); minPlcCount = $exp.minPlcCount; tsproj = @($exp.tsproj) }
        expectationError = $exp.error
        last             = [PSCustomObject]@{
            fullName            = $last.fullName
            isOpen              = $last.isOpen
            projectCount        = $last.projectCount
            solutionBuild       = [bool]$last.solutionBuild
            activeConfiguration = [bool]$last.activeConfiguration
            tipc                = [bool]$last.tipc
            plcs                = @($last.plcs)
        }
        lastError        = $lastError
    }
    return @{ Complete = $complete; Dialog = $dialog; Crashed = $crashed; LoadCheck = $loadCheck }
}
