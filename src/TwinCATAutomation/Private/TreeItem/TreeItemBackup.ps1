# Backups before a tree item is modified (complete-automation-interface phase 1, task 2.2; design D2 / D3).
# Layout: <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\<safe tree path>.xml  (ProduceXml before the change)
#         plus copies of the disk files of the node that XAE rewrites by itself, next to it.
# Measured 2026-10-30 (task 2.1, 4026 VS2022): ConsumeXml on TIRT^PlcTask rewrote
# <plc project dir>\PlcTask.TcTTO on disk immediately, without saving the solution, so the ProduceXml
# backup alone does not cover it.

# Node -> disk file rules. A file is backed up only when exactly ONE file with that name is found below
# the solution directory (backup folders excluded); none or several -> data.warnings, not copied.
# Match = scriptblock param($Path, $ItemType) -> bool. ReferencedIn = project file patterns: when no file
# is found, those project files below the solution directory are searched for the file name
# (case-insensitive); only a referenced but missing file is a warning (a scan error is one too).
# Several files are always a warning. Extend by adding entries.
$script:TcTreeItemDiskFileRules = @(
    @{
        Kind      = 'Task'
        Extension = '.TcTTO'
        # TIRT^<task>: measured 2026-10-30 (task 2.1), the PLC project folder holds <task>.TcTTO.
        Match     = { param([string]$Path, [int]$ItemType) $Path -match '^TIRT\^[^\^]+$' }
        # A task created directly below TIRT (no PLC project behind it) has no .TcTTO at all: registered
        # tcauto measured 2026-10-30, 4026 VS2022 XAE 3.1.4026.22, CreateChild TIRT SubType 1 then
        # DeleteChild / search below the solution (phase1-2.8.md issue #3). A PLC task's file is listed
        # in the .plcproj (<Compile Include="PlcTask.TcTTO">, read 2026-10-30 from the 4026 copy
        # C:\Temp\Verify-4026-axis), so a missing file is a warning only when a project references it.
        ReferencedIn = @('*.plcproj', '*.tsproj')
    },
    @{
        Kind      = 'PlcPou'
        Extension = '.TcPOU'
        # ItemType 602 / 603 / 604 = FB / Function / Program (Get-TcProjectTree table, measured 4024).
        Match     = { param([string]$Path, [int]$ItemType) $Path -like 'TIPC^*' -and @(602, 603, 604) -contains $ItemType }
    },
    @{
        Kind      = 'PlcDut'
        Extension = '.TcDUT'
        Match     = { param([string]$Path, [int]$ItemType) $Path -like 'TIPC^*' -and $ItemType -eq 606 }
    },
    @{
        Kind      = 'PlcGvl'
        Extension = '.TcGVL'
        Match     = { param([string]$Path, [int]$ItemType) $Path -like 'TIPC^*' -and $ItemType -eq 615 }
    }
)

$script:TcTreeItemBackupFolder = '.tcauto-backup'

function Get-TcTreeItemSolutionDir {
    <#
    .SYNOPSIS
        Directory of the open solution ($script:TcSolutionPath, else DTE Solution.FullName), or $null.
    #>
    [CmdletBinding()]
    param()
    $sln = [string]$script:TcSolutionPath
    if ([string]::IsNullOrWhiteSpace($sln) -and $null -ne $script:TcDte) {
        try { $sln = [string]$script:TcDte.Solution.FullName } catch { $sln = '' }
    }
    if ([string]::IsNullOrWhiteSpace($sln)) { return $null }
    $dir = [System.IO.Path]::GetDirectoryName($sln)
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    return $dir
}

function ConvertTo-TcSafeFileName {
    <#
    .SYNOPSIS
        Tree path -> file name: '^' and characters invalid in file names become '_'; longer than 120
        characters is cut and suffixed with 8 hex characters of its SHA-256 (stays unique).
    .PARAMETER Name
        Tree path or name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($ch -eq '^' -or $invalid -contains $ch) { [void]$sb.Append('_') } else { [void]$sb.Append($ch) }
    }
    $safe = $sb.ToString().Trim().TrimEnd('.')
    if ($safe.Length -eq 0) { $safe = '_' }
    if ($safe.Length -gt 120) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))[0..3] | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
        $safe = $safe.Substring(0, 111) + '-' + $hash
    }
    return $safe
}

function Find-TcTreeItemDiskFile {
    <#
    .SYNOPSIS
        Disk files of a tree item per $script:TcTreeItemDiskFileRules: @{ Files = @(paths); Warnings = @() }.
    .DESCRIPTION
        Only rules that match the node are applied. For each: '<Name><Extension>' searched below
        -SolutionDir (backup folders skipped). Exactly one hit -> Files; several -> a warning (the
        file is not backed up); none -> a warning, except for a rule with ReferencedIn (Task): then
        the warning comes only when a project file (.plcproj / .tsproj) names the file or the scan
        fails (a task without a PLC project has no .TcTTO and is referenced nowhere). A node no rule
        matches returns no file and no warning.
    .PARAMETER SolutionDir
        Directory of the .sln.
    .PARAMETER Path
        Full tree path of the node.
    .PARAMETER Name
        Node name (ITcSmTreeItem.Name).
    .PARAMETER ItemType
        ITcSmTreeItem.ItemType (-1 unknown).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionDir,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][int]$ItemType = -1
    )
    $files = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($rule in $script:TcTreeItemDiskFileRules) {
        $hit = $false
        try { $hit = [bool](& $rule.Match $Path $ItemType) } catch { $hit = $false }
        if (-not $hit) { continue }
        $fileName = "$Name$($rule.Extension)"
        $found = @()
        try {
            $found = @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -File -Filter $fileName -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.tcauto-backup\\' } | ForEach-Object { $_.FullName })
        }
        catch { $found = @() }
        if ($found.Count -eq 1) { $files.Add($found[0]) }
        elseif ($found.Count -eq 0) {
            if ($rule.ContainsKey('ReferencedIn')) {
                $ref = Test-TcProjectFileReference -SolutionDir $SolutionDir -Patterns @($rule.ReferencedIn) -FileName $fileName
                if ($null -ne $ref.Error) {
                    $warnings.Add("$($rule.Kind) node '$Path': no $fileName found below $SolutionDir and the project files could not be checked for it ($($ref.Error)); if it exists it is NOT in the backup")
                    continue
                }
                if (@($ref.Files).Count -eq 0) { continue }
            }
            $warnings.Add("$($rule.Kind) node '$Path': no $fileName found below $SolutionDir; that disk file is NOT in the backup (XAE may rewrite it when the node changes)")
        }
        else { $warnings.Add("$($rule.Kind) node '$Path': $($found.Count) files named $fileName below $SolutionDir ($($found -join '; ')); none was backed up because the right one cannot be told apart") }
    }
    return @{ Files = $files.ToArray(); Warnings = $warnings.ToArray() }
}

function Test-TcProjectFileReference {
    <#
    .SYNOPSIS
        Project files below -SolutionDir (backup folders skipped) whose text contains -FileName
        (case-insensitive): @{ Files = @(paths); Error = $null | message }.
    .PARAMETER SolutionDir
        Directory of the .sln.
    .PARAMETER Patterns
        File name patterns, e.g. '*.plcproj', '*.tsproj'.
    .PARAMETER FileName
        File name to look for, e.g. 'PlcTask.TcTTO'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionDir,
        [Parameter(Mandatory)][string[]]$Patterns,
        [Parameter(Mandatory)][string]$FileName
    )
    $hits = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($pat in $Patterns) {
            $files = @(Get-ChildItem -LiteralPath $SolutionDir -Recurse -File -Filter $pat -ErrorAction Stop |
                Where-Object { $_.FullName -notmatch '\\\.tcauto-backup\\' })
            foreach ($f in $files) {
                $text = [System.IO.File]::ReadAllText($f.FullName)
                if ($text.IndexOf($FileName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add($f.FullName) }
            }
        }
    }
    catch { return @{ Files = $hits.ToArray(); Error = $_.Exception.Message } }
    return @{ Files = $hits.ToArray(); Error = $null }
}

function New-TcTreeItemBackup {
    <#
    .SYNOPSIS
        Writes the ProduceXml backup (and copies of -DiskFiles) to
        <SolutionDir>\.tcauto-backup\<yyyyMMdd-HHmmss>\: @{ backupPath; backupDir; backupFiles; warnings }.
    .DESCRIPTION
        backupPath = '<safe path>.xml' (UTF-8 without BOM, exactly the ProduceXml text); an existing name
        in the same second gets '-2', '-3' ... Disk files are copied as '<safe path>.<file name>'; a copy
        that fails becomes a warning. Throws when the XML cannot be written (the caller must not modify
        anything then: TREEITEM_BACKUP_FAILED).
    .PARAMETER SolutionDir
        Directory of the .sln.
    .PARAMETER Path
        Full tree path of the node.
    .PARAMETER Xml
        ProduceXml text.
    .PARAMETER DiskFiles
        Disk files to copy (Find-TcTreeItemDiskFile).
    .PARAMETER Tag
        Optional suffix of the file name, e.g. 'parent'.
    .PARAMETER Now
        Timestamp (tests); default Get-Date.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SolutionDir,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Xml,
        [Parameter()][AllowEmptyCollection()][string[]]$DiskFiles = @(),
        [Parameter()][string]$Tag = '',
        [Parameter()][Nullable[datetime]]$Now = $null
    )
    $ts = if ($null -ne $Now) { [datetime]$Now } else { Get-Date }
    $dir = Join-Path (Join-Path $SolutionDir $script:TcTreeItemBackupFolder) ($ts.ToString('yyyyMMdd-HHmmss'))
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
    $base = ConvertTo-TcSafeFileName -Name $Path
    if (-not [string]::IsNullOrWhiteSpace($Tag)) { $base = "$base.$Tag" }
    $target = Join-Path $dir "$base.xml"
    $n = 1
    while (Test-Path -LiteralPath $target) { $n++; $target = Join-Path $dir "$base-$n.xml" }
    [System.IO.File]::WriteAllText($target, $Xml, (New-Object System.Text.UTF8Encoding($false)))
    $copied = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($target)
    foreach ($f in @($DiskFiles)) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        try {
            $dest = Join-Path $dir ("$stem." + [System.IO.Path]::GetFileName($f))
            Copy-Item -LiteralPath $f -Destination $dest -Force -ErrorAction Stop
            $copied.Add($dest)
        }
        catch { $warnings.Add("disk file '$f' could not be copied into the backup: $($_.Exception.Message)") }
    }
    return @{ backupPath = $target; backupDir = $dir; backupFiles = $copied.ToArray(); warnings = $warnings.ToArray() }
}

function Invoke-TcTreeItemBackup {
    <#
    .SYNOPSIS
        ProduceXml + disk files of a tree item into a backup: @{ Result = $null | <failed result>; Backup = @{...} }.
    .DESCRIPTION
        Failed result TREEITEM_BACKUP_FAILED when the solution directory is unknown, ProduceXml fails or
        the backup cannot be written; the caller then modifies nothing. Disk file problems are warnings
        (Backup.warnings). Errors in $script:TcTreeItemPassThroughCodes (IDE_*, PLC_LOGGED_IN) are
        rethrown so that they keep their code.
    .PARAMETER Item
        ITcSmTreeItem to back up.
    .PARAMETER Path
        Its full tree path.
    .PARAMETER Data
        Data attached to a failed result.
    .PARAMETER Tag
        File name suffix (e.g. 'parent').
    .PARAMETER Xml
        ProduceXml text already read (skips the extra COM call).
    .PARAMETER Recursive
        ProduceXml($true): the backup includes the subtree (used before DeleteChild).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object]$Data,
        [Parameter()][string]$Tag = '',
        [Parameter()][AllowNull()][string]$Xml = $null,
        [Parameter()][switch]$Recursive
    )
    $solutionDir = Get-TcTreeItemSolutionDir
    if ($null -eq $solutionDir) {
        return @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'TREEITEM_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage 'No solution path is known (Connect-TcIde -SolutionPath / Open-TcProject); the backup cannot be written, nothing was changed.' `
                    -Hint (Get-TcErrorHint -Code 'TREEITEM_BACKUP_FAILED')) }
    }
    try {
        if ([string]::IsNullOrEmpty($Xml)) { $Xml = Get-TcTreeItemXmlText -Item $Item -Path $Path -Recursive ([bool]$Recursive) }
        $name = try { [string]$Item.Name } catch { Get-TcTreePathLeaf -Path $Path }
        $itemType = try { [int]$Item.ItemType } catch { -1 }
        $disk = Find-TcTreeItemDiskFile -SolutionDir $solutionDir -Path $Path -Name $name -ItemType $itemType
        $b = New-TcTreeItemBackup -SolutionDir $solutionDir -Path $Path -Xml $Xml -DiskFiles @($disk.Files) -Tag $Tag
        $b.warnings = @(@($disk.Warnings) + @($b.warnings))
        return @{ Backup = $b; Result = $null }
    }
    catch {
        $m = $_.Exception.Message
        # Same list as New-TcTreeItemErrorResult: these keep their own code (the caller's catch maps them).
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        return @{ Backup = $null; Result = (New-TcResult -Success $false -ErrorCode 'TREEITEM_BACKUP_FAILED' -Data $Data `
                    -ErrorMessage "Backup of '$Path' failed, nothing was changed: $m" -Hint (Get-TcErrorHint -Code 'TREEITEM_BACKUP_FAILED')) }
    }
}

function Add-TcBackupToData {
    <#
    .SYNOPSIS
        Adds backupPath / backupFiles / warnings of a backup to a data object.
    .PARAMETER Data
        PSCustomObject.
    .PARAMETER Backup
        Backup hashtable (New-TcTreeItemBackup).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Data, [Parameter()][AllowNull()][object]$Backup)
    if ($null -eq $Backup) { return }
    $Data | Add-Member -NotePropertyName backupPath -NotePropertyValue $Backup.backupPath -Force
    $Data | Add-Member -NotePropertyName backupFiles -NotePropertyValue @($Backup.backupFiles) -Force
    $existing = @()
    $wp = $Data.PSObject.Properties['warnings']
    if ($null -ne $wp -and $null -ne $wp.Value) { $existing = @($wp.Value) }
    $Data | Add-Member -NotePropertyName warnings -NotePropertyValue @($existing + @($Backup.warnings)) -Force
}
