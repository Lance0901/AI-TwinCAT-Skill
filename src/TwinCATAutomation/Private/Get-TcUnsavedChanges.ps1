function Get-TcUnsavedChanges {
    <#
    .SYNOPSIS
        What the IDE holds unsaved (#175): documents with Document.Saved = $false, top-level projects
        with Project.Saved = $false and the solution with Solution.Saved = $false. Reset-TcSolution
        closes without saving, so these are what it would drop.
    .DESCRIPTION
        Measured 2026-11-12 (4026 VisualStudio.DTE.17.0, local UmRT, registered tcauto + a read-only
        ROT probe): Set-TcTarget leaves the .tsproj project Saved = False / IsDirty = True (also with
        the same NetId); Build-TcProject saves it again (Saved = True). Write-TcPouCode writes the
        object file on disk at once: no Document / Project / Solution reports a change afterwards.
        Solution.Saved read True on that solution (never $null).
        Unreadable (Error set, the caller fails closed): DTE.Documents / Solution / Solution.Projects
        answer $null, a Document.Saved or Solution.Saved reads $null, a project that identifies itself
        (Kind or FullName readable) answers $null to Saved, or any other error from the reads.
        THROWN, not Error (PR #256 review S1): a busy IDE (Invoke-TcComRetry gave up: IDE_BUSY), a dead
        RPC (0x800706BE / RPC_E_DISCONNECTED ...: IDE_CRASHED), a modal dialog or a timeout
        (Test-TcComMustRethrow): those are IDE states, not "unsaved state unknown", and the caller maps
        them to IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT instead of asking for -Force.
        Not refused (Unchecked): a project object that answers $null to Kind, FullName and Saved without
        throwing - the TwinCAT Scope project (.tcmproj) of the 4026 test solution does that (measured
        2026-11-12); it is not an EnvDTE project the module can ask. The Miscellaneous Files project is
        skipped (its documents are in DTE.Documents).
        Scope (known limit): only the top-level entries of Solution.Projects are read. Projects inside a
        solution folder (SubProject of its ProjectItems) and the PLC projects (.plcproj) nested in a
        .tsproj are not read; DTE does not list the nested .plcproj in Project.ProjectItems
        (docs/troubleshooting.md, section on editing project files on disk), and unsaved PLC objects are what step 1b of
        Reset-TcSolution compares with the disk (#76).
        Why no deadline of its own (PR #256 review N1): these are plain property reads, run by
        Reset-TcSolution right after its guard scan found no modal dialog. Invoke-TcComRetry
        (-TimeoutSec) retries a busy IDE and its dialog watchdog turns a blocking modal into
        IDE_MODAL_DIALOG; a call that never returns at all cannot be interrupted from this thread - the
        same accepted risk as every other plain DTE property read after a clean scan (CODING_STANDARDS 1).
    .OUTPUTS
        @{ Documents = [string[]]; Projects = [{name, file}]; Solution = <path> | $null;
           Unchecked = [{what, reason}]; Error = <message> | $null; Sec }
    #>
    [CmdletBinding()]
    param([object]$Dte, [int]$TimeoutSec = 30)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $empty = @{ Documents = @(); Projects = @(); Solution = $null; Unchecked = @(); Error = $null; Sec = 0 }
    if ($null -eq $Dte) { $empty.Error = 'no DTE'; return $empty }
    try {
        $r = Invoke-TcComRetry -MaxRetries 5 -TimeoutSec $TimeoutSec -OperationName 'unsaved changes (Document / Project / Solution .Saved)' -ScriptBlock {
            $docsOut = [System.Collections.Generic.List[string]]::new()
            $projOut = [System.Collections.Generic.List[object]]::new()
            $unchecked = [System.Collections.Generic.List[object]]::new()
            $docs = $Dte.Documents
            if ($null -eq $docs) { throw 'DTE.Documents answered $null' }
            $n = [int]$docs.Count
            for ($i = 1; $i -le $n; $i++) {
                $d = $docs.Item($i)
                $saved = $d.Saved
                if ($null -eq $saved) { throw "Document.Saved of document $i could not be read" }
                if (-not [bool]$saved) { $docsOut.Add([string]$d.FullName) }
            }
            $sol = $Dte.Solution
            if ($null -eq $sol) { throw 'DTE.Solution answered $null' }
            $solFile = $null
            $solSaved = $sol.Saved
            if ($null -eq $solSaved) { throw 'Solution.Saved could not be read' }   # PR #256 review S4: fail closed
            if (-not [bool]$solSaved) { $solFile = [string]$sol.FullName }
            $projects = $sol.Projects
            if ($null -eq $projects) { throw 'Solution.Projects answered $null' }
            $pc = [int]$projects.Count
            for ($i = 1; $i -le $pc; $i++) {
                $p = $projects.Item($i)
                if ($null -eq $p) { throw "Solution.Projects.Item($i) answered `$null" }
                $kind = [string]$p.Kind
                $unique = [string]$p.UniqueName
                if ($kind -eq '{66A2671D-8FB5-11D2-AA7E-00C04F688DDE}' -or $unique -eq '<MiscFiles>') { continue }   # Miscellaneous Files
                $file = [string]$p.FullName
                $saved = $p.Saved
                if ($null -eq $saved) {
                    if ([string]::IsNullOrWhiteSpace($kind) -and [string]::IsNullOrWhiteSpace($file)) {
                        $unchecked.Add([PSCustomObject]@{ what = "project $i"; reason = 'not an EnvDTE project: Kind, FullName and Saved answered $null (e.g. a TwinCAT Scope project)' })
                        continue
                    }
                    throw "Project.Saved of project $i ($file) could not be read"
                }
                if (-not [bool]$saved) { $projOut.Add([PSCustomObject]@{ name = [string]$p.Name; file = $file }) }
            }
            @{ Documents = $docsOut.ToArray(); Projects = $projOut.ToArray(); Solution = $solFile; Unchecked = $unchecked.ToArray() }
        }
        return @{ Documents = @($r.Documents); Projects = @($r.Projects); Solution = $r.Solution; Unchecked = @($r.Unchecked); Error = $null; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
    }
    catch {
        # PR #256 review S1: busy / dead RPC / modal / timeout are IDE states for the caller to report
        if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
        $empty.Error = $_.Exception.Message
        $empty.Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        return $empty
    }
}
