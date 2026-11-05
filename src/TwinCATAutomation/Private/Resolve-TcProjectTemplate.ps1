function Get-TcRegistryInstallDir {
    <#
    .SYNOPSIS
        Reads the TwinCATDir value (HKLM\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3) or returns $null (#70).
        Separate function so tests can replace the registry level.
    #>
    [CmdletBinding()]
    param()
    try {
        $v = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3' -Name TwinCATDir -ErrorAction Stop).TwinCATDir
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return [string]$v
    }
    catch { return $null }   # no registry value: the other candidates still apply
}

function Resolve-TcProjectTemplate {
    <#
    .SYNOPSIS
        Finds the TwinCAT XAE project template (TwinCAT Project.tsproj) for Solution.AddFromTemplate (#70).
    .DESCRIPTION
        InfoSys "Accessing TwinCAT configuration" (Automation Interface) passes the full file path
        C:\TwinCAT\3.1\Components\Base\PrjTemplate\TwinCAT Project.tsproj to AddFromTemplate and
        says to adjust it to the environment:
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html
        Search order (first existing file wins): $env:TWINCAT3DIR, the registry value TwinCATDir
        (+ '3.1'), Program Files (x86), Program Files, C:\TwinCAT\3.1. Each is
        <dir>\Components\Base\PrjTemplate\TwinCAT Project.tsproj.
        Measured 2026-11-05 (local machine, read only): the file exists under
        C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\PrjTemplate\; it is a
        version-neutral 67 byte skeleton below the shared Components\Base\PrjTemplate folder
        (4024 and 4026 builds are installed side by side below the same Components folder).
        A candidate that cannot be built or probed (a drive that does not exist, an invalid path)
        is still listed in Searched and never throws.
        Returns [PSCustomObject]@{ Path = <file or $null>; Searched = <all candidates> }.
    #>
    [CmdletBinding()]
    param()

    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:TWINCAT3DIR)) { $roots.Add($env:TWINCAT3DIR) }
    $regDir = Get-TcRegistryInstallDir
    if (-not [string]::IsNullOrWhiteSpace($regDir)) { $roots.Add([System.IO.Path]::Combine($regDir.TrimEnd('\'), '3.1')) }
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($pf)) { $roots.Add([System.IO.Path]::Combine($pf, 'Beckhoff\TwinCAT\3.1')) }
    }
    $roots.Add('C:\TwinCAT\3.1')

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $searched = [System.Collections.Generic.List[string]]::new()
    $found = $null
    foreach ($root in $roots) {
        $r = $root.TrimEnd('\')
        if (-not $seen.Add($r)) { continue }
        # Path.Combine and Test-Path both stay inside the try: a missing drive must not escape (ErrorActionPreference=Stop)
        $candidate = $r + '\Components\Base\PrjTemplate\TwinCAT Project.tsproj'
        try { $candidate = [System.IO.Path]::Combine($r, 'Components\Base\PrjTemplate\TwinCAT Project.tsproj') } catch { $null = $_ }
        $searched.Add($candidate)
        if ($null -eq $found) {
            try { if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found = $candidate } } catch { $null = $_ }
        }
    }
    [PSCustomObject]@{ Path = $found; Searched = @($searched) }
}
