function Get-TcSolutionPlatform {
    <#
    .SYNOPSIS
        Reads the active solution platform / configuration of the connected IDE and the
        project platform the TwinCAT project is built for under it.
    .DESCRIPTION
        platform = the SOLUTION platform (SolutionConfiguration2.PlatformName,
        https://learn.microsoft.com/en-us/dotnet/api/envdte80.solutionconfiguration2?view=visualstudiosdk-2022),
        read in this order (platformSource):
          'ActiveConfig'  DTE.Solution.Properties.Item('ActiveConfig').Value =
                          '<Configuration>|<SolutionPlatform>' (correct in TcXaeShell.DTE.15.0
                          and VisualStudio.DTE.17.0, 實測 2026-10-22, TwinCAT 3.1.4026.22);
          'PlatformName'  SolutionBuild.ActiveConfiguration.PlatformName (non-empty in
                          TcXaeShell 15.0; $null through the PowerShell COM binder in VS2022);
          'context'       last resort, the old reading: PlatformName of the first
                          SolutionContexts item. That is the PROJECT platform
                          (https://learn.microsoft.com/en-us/dotnet/api/envdte.solutioncontext.platformname?view=visualstudiosdk-2022)
                          and can differ from the solution platform (solution 'TwinCAT OS (x64)'
                          -> project 'TwinCAT OS (ARMT2)').
        projectPlatform = PlatformName of the .tsproj context of the active configuration
        (Select-TcTsprojContext; no .tsproj context: $null, same as projectCheck 'no-tsproj'
        of Set-TcSolutionPlatform). The target platform decides what the
        configuration is compiled for (InfoSys "Setting the TwinCAT target platform"
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html).
        configuration = left side of ActiveConfig, else ActiveConfiguration.Name, else the
        context's ConfigurationName.
        Never throws.
    .OUTPUTS
        [PSCustomObject]@{ platform; configuration; projectPlatform;
                           platformSource ('ActiveConfig' | 'PlatformName' | 'context' | $null) }
    #>
    [CmdletBinding()]
    param()

    $out = [PSCustomObject]@{ platform = $null; configuration = $null; projectPlatform = $null; platformSource = $null }
    if ($null -eq $script:TcDte) { return $out }
    try {
        $raw = Invoke-TcComRetry -MaxRetries 2 -OperationName 'SolutionBuild.ActiveConfiguration' -ScriptBlock {
            $activeConfig = $null
            try { $activeConfig = [string]$script:TcDte.Solution.Properties.Item('ActiveConfig').Value } catch { $activeConfig = $null }
            $name = $null
            $cfgPlat = $null
            $ctxs = New-Object System.Collections.ArrayList
            $active = $null
            try { $active = $script:TcDte.Solution.SolutionBuild.ActiveConfiguration } catch { $active = $null }
            if ($null -ne $active) {
                try { $name = [string]$active.Name } catch { $name = $null }
                try { $cfgPlat = [string]$active.PlatformName } catch { $cfgPlat = $null }
                try {
                    foreach ($ctx in $active.SolutionContexts) {
                        $pn = $null; $cn = $null; $pl = $null
                        try { $pn = [string]$ctx.ProjectName } catch { }
                        try { $cn = [string]$ctx.ConfigurationName } catch { }
                        try { $pl = [string]$ctx.PlatformName } catch { }
                        $null = $ctxs.Add([PSCustomObject]@{ ProjectName = $pn; ConfigurationName = $cn; PlatformName = $pl })
                    }
                }
                catch { }
            }
            [PSCustomObject]@{ ActiveConfig = $activeConfig; Name = $name; PlatformName = $cfgPlat; Contexts = $ctxs.ToArray() }
        }

        $ctxs = @($raw.Contexts)
        $firstCtx = if ($ctxs.Count -gt 0) { $ctxs[0] } else { $null }
        $projCtx = Select-TcTsprojContext -Contexts $ctxs
        if ($null -ne $projCtx -and -not [string]::IsNullOrWhiteSpace([string]$projCtx.PlatformName)) { $out.projectPlatform = [string]$projCtx.PlatformName }

        $ac = [string]$raw.ActiveConfig
        $i = $ac.IndexOf('|')
        if ($i -gt 0 -and $i -lt $ac.Length - 1) {
            $out.configuration = $ac.Substring(0, $i).Trim()
            $out.platform = $ac.Substring($i + 1).Trim()
            $out.platformSource = 'ActiveConfig'
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$raw.PlatformName)) {
            $out.platform = [string]$raw.PlatformName
            $out.platformSource = 'PlatformName'
        }
        elseif ($null -ne $firstCtx -and -not [string]::IsNullOrWhiteSpace([string]$firstCtx.PlatformName)) {
            $out.platform = [string]$firstCtx.PlatformName
            $out.platformSource = 'context'
        }
        if ([string]::IsNullOrWhiteSpace($out.configuration)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.Name)) { $out.configuration = [string]$raw.Name }
            elseif ($null -ne $firstCtx -and -not [string]::IsNullOrWhiteSpace([string]$firstCtx.ConfigurationName)) { $out.configuration = [string]$firstCtx.ConfigurationName }
        }
    }
    catch {
        Write-Verbose "Get-TcSolutionPlatform: $($_.Exception.Message)"
    }
    return $out
}
