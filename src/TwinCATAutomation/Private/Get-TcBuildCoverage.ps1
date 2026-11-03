function Get-TcBuildCoverage {
    <#
    .SYNOPSIS
        Reads which PLC projects the active solution configuration builds (#28).
    .DESCRIPTION
        DTE: Solution.SolutionBuild.ActiveConfiguration.SolutionContexts. Each
        SolutionContext names a project (ProjectName = unique name, e.g.
        'Demo\FrameworkUnitTest\FrameworkUnitTest.plcproj'), the project configuration /
        platform it maps to and ShouldBuild: "whether the current project is built when the
        solution configuration associated with this SolutionContext is selected"
        (https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2013/1a52ztxh(v=vs.120)).
        ShouldBuild = false is the DTE view of a missing Build.0 line in the .sln; the .sln
        text is not parsed. Only .plcproj contexts are returned (the .tsproj and other
        projects are not PLC projects). Measured 2026-10-21 on 4026 + VS2022: the PLC
        projects of a TwinCAT solution are listed as their own contexts next to the .tsproj.
    .OUTPUTS
        @{ configuration = '<name>|<solution platform>', '<name>' when the solution platform is
           not readable here, or $null; error = $null or message;
           projects = @( @{ name; uniqueName; configuration; platform; shouldBuild; status } ) }
        status is 'skipped' when ShouldBuild is false, else 'pending' (decided after the build).
    #>
    [CmdletBinding()]
    param()

    $result = @{ configuration = $null; error = $null; projects = @() }
    try {
        $rows = Invoke-TcComRetry -MaxRetries 3 -OperationName 'SolutionBuild.ActiveConfiguration.SolutionContexts' -ScriptBlock {
            $ac = $script:TcDte.Solution.SolutionBuild.ActiveConfiguration
            $out = @()
            $out += ,@{ Kind = 'config'; Name = [string]$ac.Name; Platform = $(try { [string]$ac.PlatformName } catch { '' }) }
            foreach ($ctx in $ac.SolutionContexts) {
                $out += ,@{
                    Kind          = 'ctx'
                    ProjectName   = [string]$ctx.ProjectName
                    Configuration = [string]$ctx.ConfigurationName
                    Platform      = [string]$ctx.PlatformName
                    ShouldBuild   = [bool]$ctx.ShouldBuild
                }
            }
            Write-Output -NoEnumerate $out
        }
    }
    catch {
        if ($_.Exception.Message -match 'IDE_CRASHED|IDE_MODAL_DIALOG') { throw }
        $result.error = $_.Exception.Message
        return $result
    }

    $projects = @()
    foreach ($r in @($rows)) {
        if ($r.Kind -eq 'config') {
            # SolutionConfiguration2.PlatformName is the SOLUTION platform
            # (https://learn.microsoft.com/en-us/dotnet/api/envdte80.solutionconfiguration2?view=visualstudiosdk-2022);
            # it is non-empty in TcXaeShell.DTE.15.0 and $null through the PowerShell COM binder in
            # VisualStudio.DTE.17.0 (VS2022) (measured 2026-10-22, TwinCAT 3.1.4026.22, same reading
            # as Get-TcSolutionPlatform 'PlatformName'); then only the name is kept.
            # The platform of the PLC contexts is NOT used for the label: that is the project
            # platform ('TwinCAT OS (ARMT2)' under solution 'TwinCAT OS (x64)', #58).
            # Build-TcProject reports the solution configuration from Get-TcSolutionPlatform.
            $result.configuration = $r.Name
            if (-not [string]::IsNullOrWhiteSpace($r.Name) -and -not [string]::IsNullOrWhiteSpace($r.Platform)) {
                $result.configuration = "$($r.Name)|$($r.Platform)"
            }
            continue
        }
        if ($r.ProjectName -notmatch '(?i)\.plcproj$') { continue }
        $projects += [PSCustomObject]@{
            name          = [IO.Path]::GetFileNameWithoutExtension($r.ProjectName)
            uniqueName    = $r.ProjectName
            configuration = $r.Configuration
            platform      = $r.Platform
            shouldBuild   = $r.ShouldBuild
            status        = if ($r.ShouldBuild) { 'pending' } else { 'skipped' }
        }
    }
    $result.projects = $projects
    return $result
}

function Find-TcBuildCoverageEntry {
    <#
    .SYNOPSIS
        Finds a PLC project entry (Get-TcBuildCoverage / Build-TcProject data.projects) by name.
    .DESCRIPTION
        Matches the .plcproj file name without extension, the unique name, or the PLC tree
        name given as 'TIPC^<Plc>' / 'TIPC^<Plc>^<Plc> Project' (the second segment), all
        case-insensitively. $null when nothing matches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Projects,
        [Parameter(Mandatory)][string]$Name
    )
    $n = $Name.Trim()
    if ($n -match '^TIPC\^([^\^]+)') { $n = $Matches[1] }
    foreach ($p in $Projects) {
        if ($n -ieq [string]$p.name -or $n -ieq [string]$p.uniqueName) { return $p }
    }
    return $null
}

function Resolve-TcPlcCoverageNodes {
    <#
    .SYNOPSIS
        Matches PLC tree items (Get-TcPlcProjectList) to .plcproj SolutionContexts entries
        (Get-TcBuildCoverage projects) one to one. Shared by Build-TcProject (#104) and
        Set-TcSolutionPlatform (#67). Never throws, never touches the IDE.
    .DESCRIPTION
        1st: by .plcproj path. The PLC node's projectFile (ProduceXml PlcProjectDef/ProjectPath,
        absolute, measured 2026-11-03 on 4026 + VS2022) against the entry's uniqueName (relative
        to the solution directory, or absolute), both through Get-TcLongPath (GetFullPath + 8.3
        long name), case-insensitive. Used only when every node has a projectFile, every node
        matches exactly one entry and no entry matches two nodes.
        2nd: by name (.plcproj file name without extension = TIPC child name). The name is not a
        reliable key (two folders with PLC.plcproj; an enabled node 'Main' whose file is
        Legacy.plcproj next to a disabled node 'Legacy'), so it must be one to one, else fail
        closed: a disabled node that matches more than one entry, an enabled node that matches no
        entry, or an entry that matches more than one node -> Error (no Nodes). The caller words
        the message; Get-TcPlcMatchErrorText gives the common start. An entry without a
        matching node keeps $null (callers count it as enabled).
    .OUTPUTS
        @{ MatchBy ('path' | 'name' | $null on Error); Error ($null or the reasons, '; '-joined);
           Nodes (object[], the matched node per entry index or $null) }
    #>
    param([object[]]$Entries, [object[]]$PlcList, [string]$SolutionPath)
    $entries = @($Entries)
    $plcList = @($PlcList)
    $nodes = [object[]]::new($entries.Count)
    $normPath = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
        try { return (Get-TcLongPath $Path).TrimEnd('\', '/').ToLowerInvariant() } catch { return $null }
    }
    $slnDir = $null
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        try { $slnDir = [IO.Path]::GetDirectoryName($SolutionPath) } catch { $slnDir = $null }
    }
    $entryPaths = [object[]]::new($entries.Count)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $u = [string]$entries[$i].uniqueName
        $abs = $null
        if (-not [string]::IsNullOrWhiteSpace($u)) {
            if ([IO.Path]::IsPathRooted($u)) { $abs = $u }
            elseif ($null -ne $slnDir) { $abs = Join-Path $slnDir $u }
        }
        $entryPaths[$i] = & $normPath $abs
    }
    $pathOk = (@($plcList | Where-Object { $null -eq (& $normPath ([string]$_.projectFile)) }).Count -eq 0)
    if ($pathOk) {
        foreach ($n in $plcList) {
            $np = & $normPath ([string]$n.projectFile)
            $hits = @(for ($i = 0; $i -lt $entries.Count; $i++) { if ($null -ne $entryPaths[$i] -and $entryPaths[$i] -eq $np) { $i } })
            if ($hits.Count -ne 1 -or $null -ne $nodes[$hits[0]]) { $pathOk = $false; break }
            $nodes[$hits[0]] = $n
        }
    }
    if ($pathOk) { return [PSCustomObject]@{ MatchBy = 'path'; Error = $null; Nodes = $nodes } }

    $nodes = [object[]]::new($entries.Count)
    $ambiguous = @()
    foreach ($n in $plcList) {
        $hits = @($entries | Where-Object { [string]$_.name -ieq [string]$n.name })
        if ($n.disabled -eq $true -and $hits.Count -gt 1) { $ambiguous += "disabled PLC '$($n.name)' matches $($hits.Count) .plcproj entries ($(($hits | ForEach-Object { $_.uniqueName }) -join ', '))" }
        if ($n.disabled -ne $true -and $hits.Count -eq 0) { $ambiguous += "enabled PLC '$($n.name)' matches no .plcproj entry (its project file has another name)" }
    }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $hit = @($plcList | Where-Object { [string]$_.name -ieq [string]$entries[$i].name })
        if ($hit.Count -gt 1) { $ambiguous += ".plcproj entry '$($entries[$i].uniqueName)' matches $($hit.Count) PLC tree items" }
        elseif ($hit.Count -eq 1) { $nodes[$i] = $hit[0] }
    }
    if ($ambiguous.Count -gt 0) {
        return [PSCustomObject]@{
            MatchBy = $null
            Error   = ($ambiguous -join '; ')
            Nodes   = [object[]]::new($entries.Count)
        }
    }
    [PSCustomObject]@{ MatchBy = 'name'; Error = $null; Nodes = $nodes }
}

function Get-TcPlcMatchErrorText {
    # Common wording of a failed Resolve-TcPlcCoverageNodes; -Consequence is what the caller does.
    param([string]$Reasons, [string]$Consequence)
    "PLC tree items cannot be matched one to one to the .plcproj entries, neither by .plcproj path (a PLC node without ProjectPath, or no one-to-one path match) nor by name, so $($Consequence): $Reasons"
}
