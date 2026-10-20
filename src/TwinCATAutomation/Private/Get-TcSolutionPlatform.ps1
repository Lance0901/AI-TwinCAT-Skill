function Get-TcSolutionPlatform {
    <#
    .SYNOPSIS
        Reads the active solution platform / configuration of the connected IDE.
    .DESCRIPTION
        Platform = PlatformName of the FIRST SolutionContexts item of
        DTE.Solution.SolutionBuild.ActiveConfiguration. SolutionConfiguration.PlatformName
        itself comes back empty through the PowerShell COM binder (VS2022, 2026-10-21);
        SolutionContexts works. Configuration = ActiveConfiguration.Name (fallback: the
        context's ConfigurationName).
        In 4026 the active solution platform must match the target platform (a local UmRT
        is TcOsSys in user mode = 'TwinCAT OS (x64)', a Windows RT target 'TwinCAT RT (x64)'),
        otherwise ActivateConfiguration() silently fails ('Check config failed!').
        Never throws.
    .OUTPUTS
        [PSCustomObject]@{ platform = [string|$null]; configuration = [string|$null] }
    #>
    [CmdletBinding()]
    param()

    $out = [PSCustomObject]@{ platform = $null; configuration = $null }
    if ($null -eq $script:TcDte) { return $out }
    try {
        $pair = Invoke-TcComRetry -MaxRetries 2 -OperationName 'SolutionBuild.ActiveConfiguration' -ScriptBlock {
            $plat = $null
            $conf = $null
            $active = $script:TcDte.Solution.SolutionBuild.ActiveConfiguration
            if ($null -ne $active) {
                try { $conf = [string]$active.Name } catch { $conf = $null }
                foreach ($ctx in $active.SolutionContexts) {
                    try { $plat = [string]$ctx.PlatformName } catch { $plat = $null }
                    if ([string]::IsNullOrWhiteSpace($conf)) { try { $conf = [string]$ctx.ConfigurationName } catch { } }
                    break
                }
            }
            Write-Output -NoEnumerate @($plat, $conf)
        }
        $pair = @($pair)
        if ($pair.Count -ge 2) {
            if (-not [string]::IsNullOrWhiteSpace([string]$pair[0])) { $out.platform = [string]$pair[0] }
            if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) { $out.configuration = [string]$pair[1] }
        }
    }
    catch {
        Write-Verbose "Get-TcSolutionPlatform: $($_.Exception.Message)"
    }
    return $out
}
