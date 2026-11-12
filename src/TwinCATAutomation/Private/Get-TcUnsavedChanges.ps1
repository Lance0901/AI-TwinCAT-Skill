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
        Fail closed (Error set): DTE.Documents / Solution / Solution.Projects cannot be read, a COM
        call throws, a Document.Saved reads $null, or a project that identifies itself (Kind or
        FullName readable) answers $null to Saved.
        Not refused (Unchecked): a project object that answers $null to Kind, FullName and Saved without
        throwing - the TwinCAT Scope project (.tcmproj) of the 4026 test solution does that (measured
        2026-11-12); it is not an EnvDTE project the module can ask. The Miscellaneous Files project is
        skipped (its documents are in DTE.Documents). Solution.Saved reading $null is Unchecked too.
        Not detected (known limit): unsaved objects created through ITcSmTreeItem.CreateChild (DTE does
        not report them, #76: Reset-TcSolution step 1b compares them with the .plcproj on disk).
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
            if ($null -eq $solSaved) { $unchecked.Add([PSCustomObject]@{ what = 'solution'; reason = 'Solution.Saved answered $null' }) }
            elseif (-not [bool]$solSaved) { $solFile = [string]$sol.FullName }
            $projects = $sol.Projects
            if ($null -eq $projects) { throw 'Solution.Projects answered $null' }
            $pc = [int]$projects.Count
            for ($i = 1; $i -le $pc; $i++) {
                $p = $projects.Item($i)
                if ($null -eq $p) { $unchecked.Add([PSCustomObject]@{ what = "project $i"; reason = 'Solution.Projects.Item answered $null' }); continue }
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
        $empty.Error = $_.Exception.Message
        $empty.Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        return $empty
    }
}
