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
        (HKLM\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3, + '3.1'), Program Files (x86), Program Files,
        C:\TwinCAT\3.1. Each is <dir>\Components\Base\PrjTemplate\TwinCAT Project.tsproj.
        Measured 2026-11-05 (local machine, read only): the file exists under
        C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\PrjTemplate\ (4024 and 4026
        builds are installed side by side below the same Components folder).
        Returns [PSCustomObject]@{ Path = <file or $null>; Searched = <all candidates> }.
    #>
    [CmdletBinding()]
    param()

    $roots = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:TWINCAT3DIR)) { $roots.Add($env:TWINCAT3DIR) }
    try {
        $regDir = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3' -Name TwinCATDir -ErrorAction Stop).TwinCATDir
        if (-not [string]::IsNullOrWhiteSpace($regDir)) { $roots.Add((Join-Path $regDir '3.1')) }
    }
    catch { $null = $_ }   # no registry value: the other candidates still apply
    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not [string]::IsNullOrWhiteSpace($pf)) { $roots.Add((Join-Path $pf 'Beckhoff\TwinCAT\3.1')) }
    }
    $roots.Add('C:\TwinCAT\3.1')

    $searched = @($roots | Select-Object -Unique | ForEach-Object { Join-Path $_ 'Components\Base\PrjTemplate\TwinCAT Project.tsproj' })
    $found = $searched | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    [PSCustomObject]@{ Path = $(if ($found) { [string]$found } else { $null }); Searched = $searched }
}
