# Independent project file helpers (complete-automation-interface phase 3, task 4.4): Set-TcIndependentFile.
# ITcSmTreeItem6.SaveInOwnFile (TE1000 Automation Interface manual v1.7.0 5.2.4 p.62-63, 6.3.9 p.210;
# InfoSys https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html): "For other
# items, the getters return neutral values, and the setters do nothing and return S_OK" (p.62).
# Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client
# (openspec/changes/complete-automation-interface/verification/phase3-probe.md questions 20-21):
#   - PLC project, NC axis, NC task, TcCOM instance (4024: I/O device) read back True; PlcTask, Axes,
#     TINC, TIRR return S_OK and read back False.
#   - setting True writes the .xti AT ONCE (no save needed): _Config\PLC\<Plc>.xti,
#     _Config\NC\Axes\<axis>.xti, _Config\NC\NC.xti (NC task), _Config\TcCOM Objects\<name>.xti,
#     _Config\IO\<device>.xti; Project.Save then rewrites the .tsproj to <... File="<x>.xti"/>.
#   - setting False + Project.Save deletes the .xti (and its .bak); the content moves back.
#   - the ProduceXml has no field for it (Set-TcTreeItemXml cannot do it).

function Get-TcXtiSnapshot {
    <#
    .SYNOPSIS
        .xti files below the solution folder (.tcauto-backup skipped): hashtable full path -> 'length|lastWriteTicks'. Never throws.
    .PARAMETER SolutionDir
        Folder of the .sln.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][string]$SolutionDir)
    $h = @{}
    if ([string]::IsNullOrWhiteSpace($SolutionDir) -or -not (Test-Path -LiteralPath $SolutionDir -PathType Container)) { return $h }
    try {
        foreach ($f in @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -File -Filter '*.xti' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.tcauto-backup\\' })) {
            $h[$f.FullName] = "$($f.Length)|$($f.LastWriteTimeUtc.Ticks)"
        }
    }
    catch { Write-Verbose "Get-TcXtiSnapshot: $($_.Exception.Message)" }
    return $h
}

function Get-TcIndependentFileName {
    <#
    .SYNOPSIS
        Expected .xti file name of an item stored in its own file: '<Name>.xti', 'NC.xti' for the NC task.
    .DESCRIPTION
        Measured names (phase3-probe.md question 20): PLC project '<Plc>.xti', NC axis '<axis>.xti',
        NC task 'NC.xti', TcCOM instance '<name (type)>.xti', I/O device '<device>.xti'.
    .PARAMETER Path
        Tree path.
    .PARAMETER Name
        Item name.
    .PARAMETER ItemType
        ItemType.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter()][int]$ItemType = -1)
    if ($Path -like 'TINC^*' -and $ItemType -eq 1) { return 'NC.xti' }
    return "$Name.xti"
}

function Invoke-TcIndependentFileSave {
    <#
    .SYNOPSIS
        Saves the TwinCAT project (.tsproj) with a deadline: @{ Saved = <tsproj> | $null; Error = $null | message }.
    .DESCRIPTION
        Invoke-TcProjectSaveWithDeadline (DTE Project.Save in an STA runspace, PROJECT_SAVE_TIMEOUT,
        CODING_STANDARDS.md 1) on the single .tsproj below the solution folder. Several / none ->
        Error (nothing saved). Never throws.
    .PARAMETER TimeoutSec
        Deadline of the save.
    #>
    [CmdletBinding()]
    param([Parameter()][int]$TimeoutSec = 120)
    $ts = Find-TcSolutionTsProjFile
    if ($null -eq $ts.Single) {
        return @{ Saved = $null; Error = "the .tsproj to save is not known ($(@($ts.Files).Count) .tsproj files below the solution folder)" }
    }
    try {
        $null = Invoke-TcProjectSaveWithDeadline -TsProjFile $ts.Single -TimeoutSec $TimeoutSec
        return @{ Saved = $ts.Single; Error = $null }
    }
    catch { return @{ Saved = $null; Error = $_.Exception.Message } }
}
