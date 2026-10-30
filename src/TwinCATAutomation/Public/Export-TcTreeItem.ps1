function Export-TcTreeItem {
    <#
    .SYNOPSIS
        Exports one tree item and its subtree to an .xti file (ITcSmTreeItem.ExportChild). Does not change the configuration.
    .DESCRIPTION
        Generic tree tool (MCP ExportChild). ITcSmTreeItem::ExportChild(bstrName, bstrFile) (TE1000
        Automation Interface manual v1.7.0, 5.2.1.4, p.58) exports a direct child (empty name = the item
        itself) to an .xti file; the target folder must exist and the file must not exist yet
        (E_INVALIDARG otherwise). This cmdlet takes the full path of the item and calls
        <parent>.ExportChild(<item name>, FilePath) (a top-level item: <item>.ExportChild('', FilePath)).
        Import the file again with Import-TcTreeItem (MCP ImportChild); templates for I/O devices and
        axes work this way (TE1000 v1.7.0 6.3.2 "Using Templates", p.198).
        Checks first: FilePath absolute, folder exists, file does not exist (TREEITEM_EXPORT_FAILED,
        data.reason). Read back: the file must exist and not be empty (data.exported=true, data.fileSize).
    .PARAMETER Path
        Full tree path of the item to export, e.g. "TIRT^PlcTask". No wildcards.
    .PARAMETER FilePath
        Absolute path of the .xti file to write; its folder must exist, the file must not.
    .EXAMPLE
        Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath 'C:\Temp\PlcTask.xti'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $data = [PSCustomObject]@{ path = $Path; filePath = $FilePath; exported = $false }
    $reason = $null
    if ([string]::IsNullOrWhiteSpace($FilePath) -or -not [System.IO.Path]::IsPathRooted($FilePath)) { $reason = 'not-absolute' }
    elseif (Test-Path -LiteralPath $FilePath) { $reason = 'file-exists' }
    elseif (-not (Test-Path -LiteralPath ([System.IO.Path]::GetDirectoryName($FilePath)) -PathType Container)) { $reason = 'folder-missing' }
    if ($null -ne $reason) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $reason
        $msg = @{ 'not-absolute' = "-FilePath must be an absolute path (got '$FilePath')"; 'file-exists' = "'$FilePath' already exists (ExportChild does not overwrite, TE1000 5.2.1.4)"; 'folder-missing' = "the folder of '$FilePath' does not exist (TE1000 5.2.1.4)" }[$reason]
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_EXPORT_FAILED' -Data $data -ErrorMessage "$msg; nothing was exported." -Hint (Get-TcErrorHint -Code 'TREEITEM_EXPORT_FAILED')
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $item = $r.Item
        $nodeName = try { [string]$item.Name } catch { Get-TcTreePathLeaf -Path $Path }
        if ([string]::IsNullOrEmpty($nodeName)) { $nodeName = Get-TcTreePathLeaf -Path $Path }
        $parentPath = Get-TcTreePathParent -Path $Path
        if ($null -eq $parentPath) {
            Invoke-TcComRetry -OperationName "ExportChild $Path" -ScriptBlock { $item.ExportChild('', $FilePath) } | Out-Null
        }
        else {
            $rp = Resolve-TcTreeItem -SysManager $sm -Path $parentPath -Data $data -ParameterName 'Path (parent)'
            if ($null -ne $rp.Result) { return $rp.Result }
            $parent = $rp.Item
            Invoke-TcComRetry -OperationName "ExportChild $Path" -ScriptBlock { $parent.ExportChild($nodeName, $FilePath) } | Out-Null
        }
        $fi = Get-Item -LiteralPath $FilePath -ErrorAction SilentlyContinue
        if ($null -eq $fi -or $fi.Length -le 0) {
            $data | Add-Member -NotePropertyName reason -NotePropertyValue 'file-not-written'
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_EXPORT_FAILED' -Data $data `
                -ErrorMessage "ExportChild returned, but '$FilePath' does not exist or is empty." -Hint (Get-TcErrorHint -Code 'TREEITEM_EXPORT_FAILED')
        }
        $data.exported = $true
        $data | Add-Member -NotePropertyName fileSize -NotePropertyValue ([long]$fi.Length)
        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_EXPORT_FAILED' -Data $data -Operation "ExportChild '$Path'"
    }
}
