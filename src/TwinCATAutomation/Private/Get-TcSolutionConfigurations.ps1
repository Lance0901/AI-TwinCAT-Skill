function Get-TcSolutionConfigurations {
    <#
    .SYNOPSIS
        Lists every solution configuration of the connected IDE with its real solution
        platform and the project platform of every project under it.
    .DESCRIPTION
        Two different platform names exist per solution configuration:
          - the SOLUTION platform: SolutionConfiguration2.PlatformName
            https://learn.microsoft.com/en-us/dotnet/api/envdte80.solutionconfiguration2?view=visualstudiosdk-2022
          - the PROJECT platform of each project: SolutionContext.PlatformName
            https://learn.microsoft.com/en-us/dotnet/api/envdte.solutioncontext.platformname?view=visualstudiosdk-2022
            (ITcSysManager.ConfigurationManager.ActiveTargetPlatform, "the project's active
            TwinCAT target platform", ITcConfigManager
            https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21840531467.html;
            that it reads the project platform and not the solution platform is 實測 2026-10-22
            (COM probe, solution 'TwinCAT OS (x64)' -> 'TwinCAT OS (ARMT2)'), not InfoSys text)
        A solution platform may map to a project platform with another name, e.g. solution
        'Release|TwinCAT OS (x64)' -> tsproj / plcproj 'TwinCAT OS (ARMT2)' (ShouldBuild=False).
        The target platform decides what the configuration is compiled for, the Configuration
        Manager whether a sub-project is built (InfoSys "Setting the TwinCAT target platform"
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html).

        SolutionPlatform (實測 2026-10-22, TcXaeShell.DTE.15.0 and VisualStudio.DTE.17.0,
        TwinCAT 3.1.4026.22):
          'PlatformName'  $cfg.PlatformName (late bound) is non-empty: TcXaeShell 15.0.
          'sln'           $cfg.PlatformName is $null (VS2022: IDispatch answers
                          DISP_E_UNKNOWNNAME): the left side of the lines of the .sln
                          GlobalSection(SolutionConfigurationPlatforms) ('Release|TwinCAT OS (x64)
                          = Release|TwinCAT OS (x64)') is mapped by index. The COM enumeration
                          order equals the .sln line order (verified on three solutions). Only
                          used when the .sln has exactly as many lines as COM items, every
                          index has the same configuration name, the solution is saved
                          (Solution.Saved not $false) and the .sln row at the index of the
                          active configuration equals Solution.Properties('ActiveConfig').
          'unknown'       neither: SolutionPlatform = $null (callers may fall back to the
                          project platform of the contexts).
        Throws on a COM failure (mapped by Invoke-TcComRetry: IDE_BUSY, IDE_CRASHED ...).
    .OUTPUTS
        [PSCustomObject[]] @{ Index (0-based); Name; SolutionPlatform;
            SolutionPlatformSource ('PlatformName' | 'sln' | 'unknown');
            Contexts = @(@{ ProjectName; ConfigurationName; PlatformName; ShouldBuild });
            Com (the SolutionConfiguration COM object, for Activate()) }
    #>
    [CmdletBinding()]
    param()

    if ($null -eq $script:TcDte) { return @() }

    # Invoke-TcComRetry hands the array back as ONE object (Write-Output -NoEnumerate).
    $raw = Invoke-TcComRetry -OperationName 'SolutionConfigurations' -ScriptBlock {
        $list = New-Object System.Collections.ArrayList
        $i = 0
        foreach ($cfg in $script:TcDte.Solution.SolutionBuild.SolutionConfigurations) {
            $cfgName = $null
            $cfgPlatform = $null
            try { $cfgName = [string]$cfg.Name } catch { $cfgName = $null }
            try { $cfgPlatform = [string]$cfg.PlatformName } catch { $cfgPlatform = $null }
            $ctxList = New-Object System.Collections.ArrayList
            try {
                foreach ($ctx in $cfg.SolutionContexts) {
                    $pn = $null; $cn = $null; $pl = $null; $sb = $null
                    try { $pn = [string]$ctx.ProjectName } catch { }
                    try { $cn = [string]$ctx.ConfigurationName } catch { }
                    try { $pl = [string]$ctx.PlatformName } catch { }
                    try { $sb = [bool]$ctx.ShouldBuild } catch { }
                    $null = $ctxList.Add([PSCustomObject]@{ ProjectName = $pn; ConfigurationName = $cn; PlatformName = $pl; ShouldBuild = $sb })
                }
            }
            catch { }
            $null = $list.Add([PSCustomObject]@{ Index = $i; Name = $cfgName; PlatformName = $cfgPlatform; Contexts = $ctxList.ToArray(); Com = $cfg })
            $i++
        }
        Write-Output -NoEnumerate $list.ToArray()
    }
    $items = @()
    foreach ($r in $raw) { $items += $r }

    # .sln SolutionConfigurationPlatforms, only read when a PlatformName is missing.
    $slnRows = $null
    $anchor = $null
    if (@($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.PlatformName) }).Count -gt 0) {
        $anchor = Invoke-TcComRetry -MaxRetries 2 -OperationName 'Solution (FullName / Saved / ActiveConfig)' -ScriptBlock {
            $sol = $script:TcDte.Solution
            $fullName = $null; $saved = $null; $activeConfig = $null; $activeCom = $null
            try { $fullName = [string]$sol.FullName } catch { }
            try { $v = $sol.Saved; if ($null -ne $v) { $saved = [bool]$v } } catch { }
            try { $activeConfig = [string]$sol.Properties.Item('ActiveConfig').Value } catch { }
            try { $activeCom = $sol.SolutionBuild.ActiveConfiguration } catch { }
            [PSCustomObject]@{ FullName = $fullName; Saved = $saved; ActiveConfig = $activeConfig; ActiveCom = $activeCom }
        }
        $slnRows = Get-TcSlnConfigurationPlatforms -Path $anchor.FullName
    }
    $slnUsable = ($null -ne $slnRows -and @($slnRows).Count -eq $items.Count)
    if ($slnUsable) {
        for ($k = 0; $k -lt $items.Count; $k++) {
            if (-not ([string]$slnRows[$k].Configuration -ieq [string]$items[$k].Name)) { $slnUsable = $false; break }
        }
    }
    # Unsaved solution: the .sln on disk may not be what the IDE has loaded.
    if ($slnUsable -and $anchor.Saved -eq $false) { $slnUsable = $false }
    # Anchor: the .sln row at the index of the active configuration must equal ActiveConfig
    # ('<Config>|<SolutionPlatform>', correct on both hosts). The active COM item is found by
    # object identity, else by Name + its contexts (several identical items: the ActiveConfig
    # row must be at one of them). No anchor -> unusable.
    if ($slnUsable) {
        $ac = [string]$anchor.ActiveConfig
        $idx = @()
        if ($null -ne $anchor.ActiveCom) {
            $idx = @($items | Where-Object { [object]::ReferenceEquals($_.Com, $anchor.ActiveCom) } | ForEach-Object { $_.Index })
            if ($idx.Count -ne 1) {
                $sig = Get-TcConfigSignature -Name ([string]$anchor.ActiveCom.Name) -Contexts @(Get-TcComContexts -Config $anchor.ActiveCom)
                $idx = @($items | Where-Object { (Get-TcConfigSignature -Name $_.Name -Contexts $_.Contexts) -eq $sig } | ForEach-Object { $_.Index })
            }
        }
        $hit = @($idx | Where-Object { ("$($slnRows[$_].Configuration)|$($slnRows[$_].Platform)") -ieq $ac })
        if ([string]::IsNullOrWhiteSpace($ac) -or $hit.Count -eq 0) { $slnUsable = $false }
    }

    $out = @()
    foreach ($it in $items) {
        $plat = $null
        $src = 'unknown'
        if (-not [string]::IsNullOrWhiteSpace([string]$it.PlatformName)) { $plat = [string]$it.PlatformName; $src = 'PlatformName' }
        elseif ($slnUsable) { $plat = [string]$slnRows[$it.Index].Platform; $src = 'sln' }
        $out += [PSCustomObject]@{
            Index                  = $it.Index
            Name                   = $it.Name
            SolutionPlatform       = $plat
            SolutionPlatformSource = $src
            Contexts               = @($it.Contexts)
            Com                    = $it.Com
        }
    }
    # Enumerated: callers collect with @(Get-TcSolutionConfigurations).
    $out
}

function Get-TcSlnConfigurationPlatforms {
    <#
    .SYNOPSIS
        Parses GlobalSection(SolutionConfigurationPlatforms) of a .sln file. Never throws.
    .OUTPUTS
        [PSCustomObject[]] @{ Configuration; Platform } in file order, or $null when the
        file or the section is missing.
    #>
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $lines = [System.IO.File]::ReadAllLines($Path) } catch { return $null }
    $rows = New-Object System.Collections.ArrayList
    $inSection = $false
    $found = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if (-not $inSection) {
            if ($t -match '^GlobalSection\(SolutionConfigurationPlatforms\)') { $inSection = $true; $found = $true }
            continue
        }
        if ($t -match '^EndGlobalSection') { break }
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $left = ($t -split '=', 2)[0].Trim()
        $parts = $left -split '\|', 2
        if ($parts.Count -lt 2) { continue }
        $null = $rows.Add([PSCustomObject]@{ Configuration = $parts[0].Trim(); Platform = $parts[1].Trim() })
    }
    if (-not $found) { return $null }
    Write-Output -NoEnumerate $rows.ToArray()
}

function Get-TcComContexts {
    # SolutionContexts of a COM SolutionConfiguration as plain objects (never throws).
    param($Config)
    $list = New-Object System.Collections.ArrayList
    try {
        foreach ($ctx in $Config.SolutionContexts) {
            $pn = $null; $cn = $null; $pl = $null; $sb = $null
            try { $pn = [string]$ctx.ProjectName } catch { }
            try { $cn = [string]$ctx.ConfigurationName } catch { }
            try { $pl = [string]$ctx.PlatformName } catch { }
            try { $sb = [bool]$ctx.ShouldBuild } catch { }
            $null = $list.Add([PSCustomObject]@{ ProjectName = $pn; ConfigurationName = $cn; PlatformName = $pl; ShouldBuild = $sb })
        }
    }
    catch { }
    Write-Output -NoEnumerate $list.ToArray()
}

function Get-TcConfigSignature {
    # Name + every context (project, configuration, platform, ShouldBuild) as one string.
    param([string]$Name, [object[]]$Contexts)
    $parts = @(@($Contexts) | ForEach-Object { "$($_.ProjectName)/$($_.ConfigurationName)/$($_.PlatformName)/$($_.ShouldBuild)" })
    "$Name::" + ($parts -join ';')
}

function Select-TcTsprojContext {
    <#
    .SYNOPSIS
        Picks the TwinCAT project (.tsproj) context(s) out of SolutionContexts rows. The one
        definition of "project platform" used by Get-TcSolutionPlatform and
        Set-TcSolutionPlatform: no .tsproj context -> $null (-All: empty array).
    #>
    param([object[]]$Contexts, [switch]$All)
    $ts = @(@($Contexts) | Where-Object { $null -ne $_ -and [string]$_.ProjectName -match '(?i)\.tsproj$' })
    if ($All) { Write-Output -NoEnumerate $ts; return }
    if ($ts.Count -gt 0) { return $ts[0] }
    return $null
}
