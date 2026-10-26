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
