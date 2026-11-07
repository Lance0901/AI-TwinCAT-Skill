# Solution load readback for Reset-TcSolution (#135 F5, seen once 2026-11-05, 4024 TcXaeShell
# 32-bit): right after a successful Reset-TcSolution, Build-TcProject failed with a null-valued
# expression (not a compiler error) and a retry worked. That XAE was still loading the solution
# is an inference, not observed. Reset-TcSolution only returns success after these reads all show
# a loaded solution.

function Read-TcSolutionLoadState {
    <#
    .SYNOPSIS
        One read of the solution load state on -Dte. Never throws.
    .DESCRIPTION
        Every DTE read goes through Invoke-TcComRetry -MaxRetries 1 (one attempt, no busy backoff:
        the caller polls). Two groups:
          solution   DTE.Solution, Solution.FullName, Solution.IsOpen, the number of
                     Solution.Projects without the Miscellaneous Files project (UniqueName
                     '<MiscFiles>', EnvDTE vsMiscFilesProjectUniqueName: it comes and goes with
                     open documents, Reset-TcSolution closes them), Solution.SolutionBuild and
                     SolutionBuild.ActiveConfiguration.
          TwinCAT    ITcSysManager ($script:TcSysManager, else the first Solution.Projects item
                     whose .Object is set; a found one is cached in $script:TcSysManager),
                     LookupTreeItem('TIPC') and the names of its children (the PLC projects).
        NoAnswer = $true when a read threw or DTE.Solution / Solution.FullName answered $null:
        what a modal dialog looks like (Reset-TcSolution #87), so the caller scans for one.
    .OUTPUTS
        Hashtable @{ fullName; isOpen; projectCount; solutionBuild; activeConfiguration; tipc;
        plcs; error; NoAnswer }.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Dte,

        [Parameter()]
        [switch]$SolutionOnly
    )
    $out = [ordered]@{ fullName = $null; isOpen = $null; projectCount = $null; solutionBuild = $false; activeConfiguration = $false
        tipc = $false; plcs = @(); error = $null; NoAnswer = $false }
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
        return $out
    }
    if ($SolutionOnly) { return $out }

    try {
        $sm = $script:TcSysManager
        if ($null -eq $sm) {
            $sm = Invoke-TcComRetry -MaxRetries 1 -OperationName 'Scan solution projects (load check)' -ScriptBlock {
                $found = $null
                $projects = $Dte.Solution.Projects
                $n = if ($null -eq $projects) { 0 } else { [int]$projects.Count }
                for ($i = 1; $i -le $n -and $null -eq $found; $i++) {
                    $p = $projects.Item($i)
                    if ($null -eq $p) { continue }
                    try { $found = $p.Object }
                    catch {
                        # busy / dead RPC is not "not a TwinCAT project" (same rule as Get-TcSysManager)
                        if ($_.Exception.Message -match '0x80010001|RPC_E_CALL_REJECTED|0x8001010A|RPC_E_SERVERCALL_RETRYLATER|0x800706BE|0x800706BA|0x80010108') { throw }
                        $found = $null
                    }
                }
                Write-Output -NoEnumerate $found
            }
            if ($null -ne $sm) { $script:TcSysManager = $sm }
        }
        if ($null -eq $sm) {
            if ($null -eq $out.error) { $out.error = 'no ITcSysManager in Solution.Projects' }
            return $out
        }
        $t = Read-TcTipcPlcName -SysManager $sm
        $out.tipc = [bool]$t.Tipc
        $out.plcs = @($t.Plcs)
        if (-not $out.tipc -and $null -eq $out.error) { $out.error = "LookupTreeItem('TIPC') returned null" }
    }
    catch {
        $out.error = [string]$_.Exception.Message
        $out.NoAnswer = $true
    }
    return $out
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

function Get-TcSolutionLoadBaseline {
    <#
    .SYNOPSIS
        What Reset-TcSolution expects to be loaded again after the reload / reopen (#135 F5):
        the number of Solution.Projects (without Miscellaneous Files) and the PLC project names
        (children of TIPC through a fresh Get-TcSysManager -Refresh). Never throws.
    .OUTPUTS
        [PSCustomObject]@{ known; projectCount; plcs; error }. known = $false when any part could
        not be read: projectCount then defaults to 1 (if it could not be read) and plcs to @().
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Dte
    )
    $b = [PSCustomObject]@{ known = $false; projectCount = 1; plcs = @(); error = $null }
    $s = Read-TcSolutionLoadState -Dte $Dte -SolutionOnly
    if ($null -ne $s.error -or $null -eq $s.projectCount) {
        $b.error = if ($null -ne $s.error) { $s.error } else { 'Solution.Projects not readable' }
        return $b
    }
    $b.projectCount = [int]$s.projectCount
    # #106: never the cached ITcSysManager (it may belong to a solution XAE reloaded meanwhile)
    $sm = Get-TcSysManager -Refresh
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

function Wait-TcSolutionLoaded {
    <#
    .SYNOPSIS
        Polls until the solution -SolutionPath is loaded in the connected IDE (Reset-TcSolution
        readback before success, #135 F5).
    .DESCRIPTION
        Every 500 ms Read-TcSolutionLoadState on $script:TcDte until ALL hold:
          - Solution.FullName equals -SolutionPath (Get-TcLongPath, OrdinalIgnoreCase)
          - Solution.IsOpen
          - Solution.Projects (without Miscellaneous Files) >= -Baseline.projectCount
          - Solution.SolutionBuild and SolutionBuild.ActiveConfiguration are not $null
          - ITcSysManager LookupTreeItem('TIPC') is not $null and every PLC of -Baseline.plcs
            is a child of TIPC (case-insensitive)
        A poll whose read got no answer (exception, DTE.Solution / FullName $null) scans for a
        modal dialog (Find-TcIdeModalDialog); a dialog (an incomplete scan does not count, #42)
        ends the wait with .Dialog set. The deadline is shared with the caller: -Stopwatch
        reaching -TimeoutSec ends it (at least one poll is always made).
    .OUTPUTS
        Hashtable @{ Complete = [bool]; Dialog = <dialog record or $null>; LoadCheck =
        [PSCustomObject]@{ complete; sec; polls; baselineKnown; baseline{projectCount, plcs}; baselineError;
        last{fullName, isOpen, projectCount, solutionBuild, activeConfiguration, tipc, plcs};
        lastError } }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter()]
        [AllowNull()]
        [object]$Baseline,

        [Parameter(Mandatory)]
        [System.Diagnostics.Stopwatch]$Stopwatch,

        [Parameter(Mandatory)]
        [int]$TimeoutSec
    )
    $wsw = [System.Diagnostics.Stopwatch]::StartNew()
    $known = $false
    $wantCount = 1
    $wantPlcs = @()
    if ($null -ne $Baseline) {
        $known = [bool]$Baseline.known
        if ($null -ne $Baseline.projectCount) { $wantCount = [int]$Baseline.projectCount }
        $wantPlcs = @($Baseline.plcs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $want = try { Get-TcLongPath $SolutionPath } catch { $SolutionPath }
    $polls = 0
    $complete = $false
    $dialog = $null
    $last = $null
    $lastError = $null
    while ($true) {
        $polls++
        $snap = Read-TcSolutionLoadState -Dte $script:TcDte
        $last = $snap
        $missing = [System.Collections.Generic.List[string]]::new()
        $fullOk = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$snap.fullName)) {
            $have = try { Get-TcLongPath ([string]$snap.fullName) } catch { [string]$snap.fullName }
            $fullOk = [string]::Equals($have, $want, [StringComparison]::OrdinalIgnoreCase)
        }
        if (-not $fullOk) { $missing.Add("Solution.FullName '$($snap.fullName)' is not '$want'") }
        if ($snap.isOpen -ne $true) { $missing.Add('Solution.IsOpen is not true') }
        if ($null -eq $snap.projectCount -or [int]$snap.projectCount -lt $wantCount) { $missing.Add("Solution.Projects $($snap.projectCount) < $wantCount") }
        if (-not $snap.solutionBuild) { $missing.Add('Solution.SolutionBuild is $null') }
        elseif (-not $snap.activeConfiguration) { $missing.Add('SolutionBuild.ActiveConfiguration is $null') }
        if (-not $snap.tipc) { $missing.Add("LookupTreeItem('TIPC') not available") }
        else {
            $lost = @($wantPlcs | Where-Object { $n = [string]$_; -not @($snap.plcs | Where-Object { [string]::Equals([string]$_, $n, [StringComparison]::OrdinalIgnoreCase) }) })
            if ($lost.Count -gt 0) { $missing.Add("PLC project(s) not loaded: $($lost -join ', ')") }
        }
        if ($missing.Count -eq 0) { $complete = $true; $lastError = $null; break }
        $lastError = if ($null -ne $snap.error) { "$($snap.error); $($missing -join '; ')" } else { $missing -join '; ' }

        if ($snap.NoAnswer) {
            $d = Find-TcIdeModalDialog
            if (Test-TcModalScanIncomplete $d) { $d = $null }   # #42: unknown, keep polling
            if ($null -ne $d) { $dialog = $d; break }
        }
        if ($Stopwatch.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
        Start-Sleep -Milliseconds 500
    }
    $loadCheck = [PSCustomObject]@{
        complete      = $complete
        sec           = [math]::Round($wsw.Elapsed.TotalSeconds, 1)
        polls         = $polls
        baselineKnown = $known
        baseline      = [PSCustomObject]@{ projectCount = $wantCount; plcs = @($wantPlcs) }
        baselineError = $(if ($null -ne $Baseline) { $Baseline.error } else { 'no baseline' })
        last          = [PSCustomObject]@{
            fullName            = $last.fullName
            isOpen              = $last.isOpen
            projectCount        = $last.projectCount
            solutionBuild       = [bool]$last.solutionBuild
            activeConfiguration = [bool]$last.activeConfiguration
            tipc                = [bool]$last.tipc
            plcs                = @($last.plcs)
        }
        lastError     = $lastError
    }
    return @{ Complete = $complete; Dialog = $dialog; LoadCheck = $loadCheck }
}
