# Boot project helpers (complete-automation-interface phase 2, task 3.2): New-TcBootProject.
# GenerateBootProject(bActivate = false) on the PLC root 'TIPC^<Plc>' writes only the project's
# _Boot\<solution platform>\Plc\Port_<adsPort>.* files (.app, .autostart, .cid, .crc, .occ, .ocm,
# Port_<port>_boot.tizip); %ProgramData%\Beckhoff\TwinCAT\3.1\Boot and the UmRT Boot folder did not
# change (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client,
# openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.2).

function Get-TcBootFileSet {
    <#
    .SYNOPSIS
        Boot files of one PLC: @{ Dirs = @(paths); Dir; Derived; Reason; Files = @{ <full path> = <Get-TcOutputFileFacts> } }.
    .DESCRIPTION
        Derived ($true): <folder of the .tsproj that lists the PLC>\_Boot\<platform>\Plc for the
        solution platform and, when it differs, the project platform (Get-TcSolutionPlatform
        projectPlatform); files 'Port_<AdsPort>.*' and 'Port_<AdsPort>_*' (Port_851_boot.tizip).
        The probe had the same solution and project platform ('TwinCAT OS (x64)'); which of the
        two folders XAE writes when they differ is not measured, so both are listed. Dir is the
        first of Dirs. The .tsproj comes from Get-TcPlcProjectFile (DTE Solution.Projects + the
        <Project Name=... PrjFilePath=...> element).
        When the platform, the ADS port or the .tsproj is not known (Reason says which, also an
        empty .tsproj path), Derived is $false and every _Boot\*\Plc\Port_* file below
        -SolutionDir (depth 4, backup folders skipped) is listed instead; Dirs is empty then.
        Never throws.
    .PARAMETER PlcName
        PLC name (TIPC^<Plc>).
    .PARAMETER Platform
        Active solution platform (Get-TcSolutionPlatform), e.g. 'TwinCAT OS (x64)'.
    .PARAMETER ProjectPlatform
        Project platform of the .tsproj under that solution platform (Get-TcSolutionPlatform
        projectPlatform); $null or the same name adds nothing.
    .PARAMETER AdsPort
        ADS port of the PLC (Get-TcPlcProjectList adsPort), 0 = unknown.
    .PARAMETER SolutionDir
        Folder of the .sln (fallback search).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PlcName,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Platform,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ProjectPlatform,
        [Parameter()][int]$AdsPort = 0,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SolutionDir
    )
    $out = @{ Dirs = @(); Dir = $null; Derived = $false; Reason = $null; Files = @{} }
    $tsproj = $null
    if ([string]::IsNullOrWhiteSpace($Platform)) { $out.Reason = 'the solution platform is not known' }
    elseif ($AdsPort -le 0) { $out.Reason = "the ADS port of PLC '$PlcName' is not known" }
    else {
        try {
            $tsproj = [string](Get-TcPlcProjectFile -PlcName $PlcName).TsProjFile
            if ([string]::IsNullOrWhiteSpace($tsproj)) { $out.Reason = "Get-TcPlcProjectFile returned no .tsproj path for PLC '$PlcName'" }
        }
        catch { $out.Reason = "the .tsproj of PLC '$PlcName' is not found ($($_.Exception.Message))" }
    }
    if ($null -eq $out.Reason) {
        $boot = Join-Path ([System.IO.Path]::GetDirectoryName($tsproj)) '_Boot'
        $plats = @($Platform)
        if (-not [string]::IsNullOrWhiteSpace($ProjectPlatform) -and $ProjectPlatform -ne $Platform) { $plats += $ProjectPlatform }
        $out.Dirs = @($plats | ForEach-Object { Join-Path (Join-Path $boot $_) 'Plc' })
        $out.Dir = $out.Dirs[0]
        $out.Derived = $true
        foreach ($d in $out.Dirs) {
            if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Port_$AdsPort.*" -or $_.Name -like "Port_$($AdsPort)_*" })) {
                $out.Files[$f.FullName] = Get-TcOutputFileFacts -Path $f.FullName
            }
        }
        return $out
    }
    if ([string]::IsNullOrWhiteSpace($SolutionDir) -or -not (Test-Path -LiteralPath $SolutionDir -PathType Container)) {
        $out.Reason += '; the solution folder is not known either, so no boot file was searched'
        return $out
    }
    $pattern = if ($AdsPort -gt 0) { "Port_$AdsPort*" } else { 'Port_*' }
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -Depth 4 -File -Filter $pattern -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match '\\_Boot\\[^\\]+\\Plc\\[^\\]+$' -and $_.FullName -notmatch '\\\.tcauto-backup\\' })) {
            $out.Files[$f.FullName] = Get-TcOutputFileFacts -Path $f.FullName
        }
    }
    catch { $out.Reason += "; the search below '$SolutionDir' failed ($($_.Exception.Message))" }
    return $out
}

function Compare-TcBootFileSet {
    <#
    .SYNOPSIS
        Boot files after the call, each with 'updated': @({ path; size; lastWriteTime; updated }).
    .DESCRIPTION
        updated = the file did not exist before, or its LastWriteTimeUtc is later than before.
        Files of -Before that are gone afterwards are listed with size $null and updated $false.
    .PARAMETER Before
        Files hashtable of Get-TcBootFileSet before the call.
    .PARAMETER After
        Files hashtable after the call.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][hashtable]$After)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($After.Keys | Sort-Object)) {
        $a = $After[$k]
        $b = $Before[$k]
        $upd = ($null -eq $b -or -not $b.exists -or ($null -ne $a.lastWriteTimeUtc -and $null -ne $b.lastWriteTimeUtc -and $a.lastWriteTimeUtc -gt $b.lastWriteTimeUtc))
        $list.Add([PSCustomObject]@{ path = $k; size = $a.size; lastWriteTime = $a.lastWriteTime; updated = [bool]$upd })
    }
    foreach ($k in @($Before.Keys | Sort-Object)) {
        if ($After.ContainsKey($k)) { continue }
        $list.Add([PSCustomObject]@{ path = $k; size = $null; lastWriteTime = $null; updated = $false })
    }
    return $list.ToArray()
}
