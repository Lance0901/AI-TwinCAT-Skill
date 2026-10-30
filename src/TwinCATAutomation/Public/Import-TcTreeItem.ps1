function Import-TcTreeItem {
    <#
    .SYNOPSIS
        Imports an .xti / XML file as a child of a tree item (ITcSmTreeItem.ImportChild). Dry-run by default; backs up the parent and reads back.
    .DESCRIPTION
        Generic tree tool (MCP ImportChild). ITcSmTreeItem::ImportChild(bstrFile, bstrBefore, bReconnect,
        bstrName) (TE1000 Automation Interface manual v1.7.0, 5.2.1.6, p.59): loads the file, inserts the
        item as a child, reassigns variable IDs and, when bReconnect is not false, restores mappings.
        Samples: TE1000 v1.7.0 6.3.2 "Using Templates" (p.198-199), e.g. TIID ImportChild(file, "", true,
        "SomeName"). Export a file with Export-TcTreeItem (MCP ExportChild).
        Checks first (nothing imported on failure): FilePath absolute and exists
        (TREEITEM_IMPORT_FAILED, data.reason), Path exists (TREEITEM_NOT_FOUND), a child named Name does
        not exist yet (TREEITEM_ALREADY_EXISTS), Before is an existing child.
        DryRun (default true): ImportChild is NOT called; data.dryRun=true, data.currentChildren,
        data.fileSize.
        DryRun=false: ProduceXml backup of the PARENT (data.backupPath), ImportChild, then the imported
        item is looked up again (returned item, else Path^Name, else a new child name):
        data.verified=true, data.importedPath / importedName; not found -> TREEITEM_VERIFY_FAILED.
        XAE refusing the call -> TREEITEM_IMPORT_FAILED. Below TIPC: BUILD_REQUIRED code-changed.
    .PARAMETER Path
        Full tree path of the PARENT, e.g. "TIRT" or "TIID". No wildcards.
    .PARAMETER FilePath
        Absolute path of the .xti / XML file to import.
    .PARAMETER Before
        Optional name of an existing child before which the item is inserted (bstrBefore).
    .PARAMETER Reconnect
        bReconnect (default true): re-establish existing mapping information.
    .PARAMETER Name
        Optional new name of the imported item (bstrName); empty keeps the name from the file.
    .PARAMETER DryRun
        Default true: only report the plan. false: back up the parent, import, read back.
    .EXAMPLE
        Import-TcTreeItem -Path 'TIRT' -FilePath 'C:\Temp\PlcTask.xti' -Name 'PlcTask Copy' -DryRun $false
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$Before = '',

        [Parameter()]
        [bool]$Reconnect = $true,

        [Parameter()]
        [string]$Name = '',

        [Parameter()]
        [bool]$DryRun = $true
    )

    $data = [PSCustomObject]@{ path = $Path; filePath = $FilePath; before = $Before; reconnect = $Reconnect; name = $Name; dryRun = $DryRun }
    $reason = $null
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not [System.IO.Path]::IsPathRooted($FilePath)) { $reason = 'not-absolute' }
    elseif (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { $reason = 'file-missing' }
    if ($null -ne $reason) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $reason
        $msg = if ($reason -eq 'not-absolute') { "-FilePath must be an absolute path (got '$FilePath')" } else { "'$FilePath' does not exist" }
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_IMPORT_FAILED' -Data $data -ErrorMessage "$msg; nothing was imported." -Hint (Get-TcErrorHint -Code 'TREEITEM_IMPORT_FAILED')
    }
    if ($Name.Contains('^')) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -Data $data -ErrorMessage "-Name must not contain '^' (got '$Name')."
    }
    $data | Add-Member -NotePropertyName fileSize -NotePropertyValue ([long](Get-Item -LiteralPath $FilePath).Length)

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $stage = 'lookup'
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $parent = $r.Item
        $childrenBefore = @(Get-TcTreeItemChildNames -Item $parent)
        $data | Add-Member -NotePropertyName currentChildren -NotePropertyValue $childrenBefore
        if (-not [string]::IsNullOrEmpty($Name)) {
            if ($null -ne (Find-TcTreeItemNoThrow -SysManager $sm -Path "$Path^$Name")) {
                return New-TcResult -Success $false -ErrorCode 'TREEITEM_ALREADY_EXISTS' -Data $data `
                    -ErrorMessage "'$Path^$Name' already exists; nothing was imported." -Hint (Get-TcErrorHint -Code 'TREEITEM_ALREADY_EXISTS')
            }
        }
        if (-not [string]::IsNullOrEmpty($Before) -and ($childrenBefore -notcontains $Before)) {
            $list = if ($childrenBefore.Count -gt 0) { ($childrenBefore | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' }
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_NOT_FOUND' -Data $data `
                -ErrorMessage "-Before '$Before' is not a child of '$Path'; nothing was imported." `
                -Hint "-Before must be the name of an existing child of '$Path': $list. Leave it empty to append."
        }

        if ($DryRun) { return New-TcResult -Success $true -Data $data }

        $stage = 'backup'
        $bk = Invoke-TcTreeItemBackup -Item $parent -Path $Path -Data $data -Tag 'parent'
        if ($null -ne $bk.Result) { return $bk.Result }
        Add-TcBackupToData -Data $data -Backup $bk.Backup

        $stage = 'import'
        $isPlc = Test-TcTreePathIsPlc -Path $Path
        $imported = $null
        try {
            $imported = Invoke-TcComRetry -OperationName "ImportChild $Path" -ScriptBlock {
                Write-Output -NoEnumerate $parent.ImportChild($FilePath, $Before, $Reconnect, $Name)
            }
        }
        catch {
            $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_IMPORT_FAILED' -Data $data -Operation "ImportChild '$FilePath' into '$Path'"
            if ($isPlc -and $_.Exception.Message -match '^IDE_') { $res = Register-TcCodeChange -Result $res -Change "Import-TcTreeItem $Path [failed]" }
            return $res
        }

        $stage = 'verify'
        $candidates = [System.Collections.Generic.List[string]]::new()
        if ($null -ne $imported) {
            $ip = try { [string]$imported.PathName } catch { '' }
            $iname = try { [string]$imported.Name } catch { '' }
            if (-not [string]::IsNullOrWhiteSpace($ip)) { $candidates.Add($ip) }
            if (-not [string]::IsNullOrWhiteSpace($iname)) { $candidates.Add("$Path^$iname") }
        }
        if (-not [string]::IsNullOrEmpty($Name)) { $candidates.Add("$Path^$Name") }
        $afterNames = @(Get-TcTreeItemChildNames -Item $parent)
        foreach ($n in $afterNames) { if ($childrenBefore -notcontains $n) { $candidates.Add("$Path^$n") } }
        $found = $null
        foreach ($c in $candidates) {
            $hit = Find-TcTreeItemNoThrow -SysManager $sm -Path $c
            if ($null -ne $hit) { $found = $hit; $data | Add-Member -NotePropertyName importedPath -NotePropertyValue $c; break }
        }
        if ($null -eq $found) {
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $false
            $res = New-TcResult -Success $false -ErrorCode 'TREEITEM_VERIFY_FAILED' -Data $data `
                -ErrorMessage "ImportChild returned, but no imported item is found below '$Path' (looked for: $(@($candidates) -join ', '))." -Hint (Get-TcErrorHint -Code 'TREEITEM_VERIFY_FAILED')
        }
        else {
            $s = Get-TcTreeItemSummary -Item $found
            $data | Add-Member -NotePropertyName importedName -NotePropertyValue $s.name
            $data | Add-Member -NotePropertyName itemType -NotePropertyValue $s.itemType
            $data | Add-Member -NotePropertyName verified -NotePropertyValue $true
            if (-not [string]::IsNullOrEmpty($Name) -and $s.name -cne $Name) {
                $data.warnings = @(@($data.warnings) + @("XAE named the imported item '$($s.name)', not '$Name'"))
            }
            $res = New-TcResult -Success $true -Data $data
        }
        if ($isPlc) { $res = Register-TcCodeChange -Result $res -Change "Import-TcTreeItem $Path" }
        return $res
    }
    catch {
        $code = if ($stage -eq 'import') { 'TREEITEM_IMPORT_FAILED' } elseif ($stage -eq 'verify') { 'TREEITEM_VERIFY_FAILED' } else { 'TREEITEM_READ_FAILED' }
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode $code -Data $data -Operation "ImportChild '$FilePath' into '$Path' ($stage)"
    }
}
