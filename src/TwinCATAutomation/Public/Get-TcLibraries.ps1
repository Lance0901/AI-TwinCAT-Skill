function Get-TcLibraries {
    <#
    .SYNOPSIS
        Lists the library references and placeholders of a PLC project, or with -Repository the libraries installed on this machine.
    .DESCRIPTION
        Read-only. ITcPlcLibraryManager on the References node TIPC^<Plc>^<Plc> Project^References
        (TE1000 Automation Interface manual v1.7.0, 6.5.14 "Managing PLC libraries and placeholders",
        p.241-244; 5.25.1 p.113-119).
        Default: ITcPlcLibraryManager.References. Each entry: name, isPlaceholder, placeholderName,
        libraryName, version, distributor, displayName, effectiveResolution, defaultResolution,
        resolvedFrom, frozen, projectResolution. A placeholder is listed as '#<name>' (TE1000 5.24
        p.112). On a placeholder LibraryName / Version / Distributor read as empty strings, so they are
        taken from EffectiveResolution (else DefaultResolution; resolvedFrom says which). A visu
        placeholder has no EffectiveResolution ($null). Measured 2026-10-31 4026 VS2022 (self-built
        client, openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.1).
        frozen: FreezePlaceholder only changes <PlaceholderResolution><Resolution> in the .plcproj
        (version '*' -> the fixed version); the References objects look the same before and after
        (measured 2026-10-31 4026 VS2022). So frozen / projectResolution are read from the .plcproj ON
        DISK: frozen = true when its Resolution names a version other than '*'; changes that are only
        in XAE memory (not saved) are not seen. When the .plcproj cannot be located or read, frozen is
        $null and data.warnings says why. Whether XAE writes a fixed version into Resolution for a
        placeholder that was added with a fixed version (it then reads as frozen) is not measured.
        -Repository: ITcPlcLibraryManager.ScanLibraries() instead (TE1000 5.25.1): every library
        installed in any repository of this machine, one entry per version (name, version,
        distributor, displayName). Measured 2026-10-31 4026 VS2022: 473 entries in 372-747 ms; the
        repository of an entry is not reported.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Repository
        List the libraries installed on this machine (ScanLibraries) instead of the project references.
    .PARAMETER Filter
        Wildcard on the name (-like, case-insensitive), e.g. 'Tc2_*'. References: matches name,
        placeholderName or libraryName. Default: everything.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS). -Repository needs a PLC project too (the
        Library Manager lives on its References node).
    .OUTPUTS
        data: mode (references | repository), plcProjectPath, referencesPath, filter, count,
        totalCount, libraries[], projectFile (references), warnings.
    .EXAMPLE
        Get-TcLibraries
    .EXAMPLE
        Get-TcLibraries -Repository -Filter 'Tc2_M*'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Repository,

        [Parameter()]
        [string]$Filter,

        [Parameter()]
        [string]$PlcProjectPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $pattern = if ([string]::IsNullOrWhiteSpace($Filter)) { '*' } else { $Filter.Trim() }
    try {
        $mgr = Resolve-TcLibraryManager -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $mgr.Result) { return $mgr.Result }
        $warnings = [System.Collections.Generic.List[string]]::new()

        if ($Repository) {
            $all = @(Get-TcInstalledLibraryList -Refs $mgr.Refs)
            $hit = @($all | Where-Object { [string]$_.name -like $pattern } | Sort-Object name, version, distributor)
            return New-TcResult -Success $true -Data ([PSCustomObject]@{
                mode           = 'repository'
                plcProjectPath = $mgr.PlcProjectPath
                referencesPath = $mgr.RefsPath
                filter         = $(if ($pattern -eq '*') { $null } else { $pattern })
                count          = $hit.Count
                totalCount     = $all.Count
                libraries      = $hit
                warnings       = @()
            })
        }

        $all = @(Get-TcLibraryReferenceList -Refs $mgr.Refs)
        $projectFile = $null
        $entries = $null
        try {
            $projectFile = Get-TcLibraryPlcProjFile -RefsPath $mgr.RefsPath
            $entries = Get-TcPlcProjectLibraryEntries -Path $projectFile
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $warnings.Add("frozen / projectResolution unknown: the .plcproj could not be read ($($_.Exception.Message)).")
            $entries = $null
        }
        foreach ($e in $all) {
            $frozen = $null; $projRes = $null
            if ($null -ne $entries -and $e.isPlaceholder) {
                $pe = $entries.Placeholders[[string]$e.placeholderName]
                if ($null -ne $pe) { $frozen = [bool]$pe.frozen; $projRes = $pe.resolution }
                else { $frozen = $false }
            }
            elseif ($null -ne $entries) { $frozen = $false }
            $e | Add-Member -NotePropertyName frozen -NotePropertyValue $frozen -Force
            $e | Add-Member -NotePropertyName projectResolution -NotePropertyValue $projRes -Force
        }
        $hit = @($all | Where-Object { [string]$_.name -like $pattern -or [string]$_.placeholderName -like $pattern -or [string]$_.libraryName -like $pattern })
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            mode           = 'references'
            plcProjectPath = $mgr.PlcProjectPath
            referencesPath = $mgr.RefsPath
            filter         = $(if ($pattern -eq '*') { $null } else { $pattern })
            count          = $hit.Count
            totalCount     = $all.Count
            libraries      = $hit
            projectFile    = $projectFile
            warnings       = $warnings.ToArray()
        })
    }
    catch {
        New-TcLibraryErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_READ_FAILED' -Operation 'Get-TcLibraries'
    }
}
