# Shared helpers for the AI behaviour eval harness (eval/run-case.ps1, eval/score.ps1, eval/cases/*/grade.ps1).
# Windows PowerShell 5.1. Dot-source it: . (Join-Path $PSScriptRoot 'lib\EvalCommon.ps1')

function Get-EvalUmRtAmsNetId {
    <#
    .SYNOPSIS
        AmsNetId of a local Usermode Runtime, read from its TcRegistry.xml (no IDE, no ADS).
    .DESCRIPTION
        %ProgramData%\Beckhoff\TwinCAT\3.1\Runtimes\<Name>\3.1\TcRegistry.xml holds
        <Value Name="AmsNetId" Type="BIN">C7052AFA0101</Value> (6 bytes hex). The layout is not documented
        in InfoSys; same source the module uses for targetKind (measured 2026-10-21, UmRT_Default).
    .PARAMETER Name
        Runtime name (default UmRT_Default).
    #>
    param([string]$Name = 'UmRT_Default')
    $reg = Join-Path $env:ProgramData "Beckhoff\TwinCAT\3.1\Runtimes\$Name\3.1\TcRegistry.xml"
    if (-not (Test-Path -LiteralPath $reg)) { throw "TcRegistry.xml of runtime '$Name' not found: $reg" }
    $text = [System.IO.File]::ReadAllText($reg)
    $m = [regex]::Match($text, '<Value Name="AmsNetId" Type="BIN">([0-9A-Fa-f]{12})<')
    if (-not $m.Success) { throw "No AmsNetId BIN value in $reg" }
    $hex = $m.Groups[1].Value
    $bytes = for ($i = 0; $i -lt 12; $i += 2) { [Convert]::ToInt32($hex.Substring($i, 2), 16) }
    return ($bytes -join '.')
}

function Read-EvalJsonLines {
    <#
    .SYNOPSIS
        Reads a JSONL file into objects; unparsable lines are returned as {parseError, line}.
    .PARAMETER Path
        The .jsonl file. Missing file -> empty array.
    #>
    param([string]$Path)
    $out = [System.Collections.ArrayList]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return }
    # FileShare.ReadWrite: the file may still be open for writing (a run in progress)
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8); $all = $sr.ReadToEnd() } finally { $fs.Dispose() }
    foreach ($line in ($all -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json)) }
        catch { [void]$out.Add([pscustomobject]@{ parseError = $_.Exception.Message; line = $line }) }
    }
    # emitted one by one: callers wrap the call in @()
    return $out.ToArray()
}

function Write-EvalJson {
    <#
    .SYNOPSIS
        Writes an object as UTF-8 (no BOM) JSON.
    .PARAMETER InputObject
        Object to serialise.
    .PARAMETER Path
        Target file.
    #>
    param($InputObject, [string]$Path)
    $json = $InputObject | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Get-EvalIdeProcesses {
    <#
    .SYNOPSIS
        Running XAE / Visual Studio processes (devenv, TcXaeShell) with pid, start time and command line.
    #>
    $list = @(Get-CimInstance Win32_Process -Filter "Name='devenv.exe' or Name='TcXaeShell.exe'" -ErrorAction SilentlyContinue)
    # emitted one by one: callers wrap the call in @()
    return @($list | ForEach-Object {
        [pscustomobject]@{
            pid         = [int]$_.ProcessId
            name        = [string]$_.Name
            startTime   = $_.CreationDate.ToString('o')
            commandLine = [string]$_.CommandLine
        }
    })
}
