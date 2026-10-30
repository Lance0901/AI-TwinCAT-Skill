function Export-TcTreeItem {
    <#
    .SYNOPSIS
        Exports one tree item and its subtree to an .xti file (.zip below TIPC) (ITcSmTreeItem.ExportChild). Does not change the configuration.
    .DESCRIPTION
        Generic tree tool (MCP ExportChild). ITcSmTreeItem::ExportChild(bstrName, bstrFile) (TE1000
        Automation Interface manual v1.7.0, 5.2.1.4, p.58) exports a direct child (empty name = the item
        itself) to an .xti file; the target folder must exist and the file must not exist yet
        (E_INVALIDARG otherwise). This cmdlet takes the full path of the item and calls
        <parent>.ExportChild(<item name>, FilePath) (a top-level item: <item>.ExportChild('', FilePath)).
        Import the file again with Import-TcTreeItem (MCP ImportChild); templates for I/O devices and
        axes work this way (TE1000 v1.7.0 6.3.2 "Using Templates", p.198).
        A node below TIPC (inside a PLC project) needs a .zip file name: XAE refuses .xti there with
        "The filename '...' doesn't specify a zip archive!" (measured 2026-10-30 4026 VS2022, XAE
        3.1.4026.22; not in TE1000 5.2.1.4). Other nodes use .xti.
        Checks first: FilePath is a valid absolute file path (not-absolute / invalid-path: characters
        such as < > | " * ?, or no file name such as C:\), a path below TIPC ends in .zip
        (plc-requires-zip), folder exists (folder-missing), file does not exist (file-exists) ->
        TREEITEM_EXPORT_FAILED with data.reason. IDE_MODAL_DIALOG when a dialog is
        open (nothing exported). Read back: the file must exist and not be empty (data.exported=true,
        data.fileSize).
    .PARAMETER Path
        Full tree path of the item to export, e.g. "TIRT^PlcTask". No wildcards.
    .PARAMETER FilePath
        Absolute path of the file to write: .xti, or .zip for a node below TIPC (PLC node; measured
        2026-10-30 4026 VS2022). Its folder must exist, the file must not.
    .EXAMPLE
        Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath 'C:\Temp\PlcTask.xti'
    .EXAMPLE
        Export-TcTreeItem -Path 'TIPC^Plc^Plc Project^POUs' -FilePath 'C:\Temp\POUs.zip'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$FilePath
    )

    $data = [PSCustomObject]@{ path = $Path; filePath = $FilePath; exported = $false }
    # Path checks inside try: an invalid path (bad characters, a root such as C:\) must become
    # TREEITEM_EXPORT_FAILED invalid-path, not an EXECUTION_ERROR thrown by Test-Path / GetDirectoryName.
    $bad = $null
    try {
        $bad = Test-TcTreeItemFilePath -FilePath $FilePath
        $wantExt = Get-TcTreeItemExportExtension -Path $Path
        if ($null -eq $bad -and $wantExt -eq '.zip' -and [System.IO.Path]::GetExtension($FilePath) -ine '.zip') {
            $bad = @{ Reason = 'plc-requires-zip'; Message = "'$Path' is a node below TIPC: XAE only exports it to a .zip file ('$FilePath' would be refused with 'doesn't specify a zip archive', measured 2026-10-30)" }
        }
        if ($null -eq $bad -and (Test-Path -LiteralPath $FilePath)) { $bad = @{ Reason = 'file-exists'; Message = "'$FilePath' already exists (ExportChild does not overwrite, TE1000 5.2.1.4)" } }
        if ($null -eq $bad -and -not (Test-Path -LiteralPath ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($FilePath))) -PathType Container)) {
            $bad = @{ Reason = 'folder-missing'; Message = "the folder of '$FilePath' does not exist (TE1000 5.2.1.4)" }
        }
    }
    catch { $bad = @{ Reason = 'invalid-path'; Message = "-FilePath '$FilePath' cannot be checked: $($_.Exception.Message)" } }
    if ($null -ne $bad) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $bad.Reason
        $hint = Get-TcErrorHint -Code 'TREEITEM_EXPORT_FAILED'
        if ($bad.Reason -eq 'plc-requires-zip') {
            $hint = "A node below TIPC (PLC node) is exported to a .zip file (measured 2026-10-30 4026 VS2022): rerun Export-TcTreeItem -Path '$Path' -FilePath '$([System.IO.Path]::ChangeExtension($FilePath, '.zip'))'. Import it again with Import-TcTreeItem (the .zip file)."
        }
        return New-TcResult -Success $false -ErrorCode 'TREEITEM_EXPORT_FAILED' -Data $data -ErrorMessage "$($bad.Message); nothing was exported." -Hint $hint
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
        $dlg = Get-TcTreeItemDialogResult -Operation "ExportChild '$Path'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        # No deadline (CODING_STANDARDS.md section 1), same as CreateChild in New-TcPlcObject: an open
        # dialog was ruled out just above and Connect-TcIde turns on ITcAutomationSettings.SilentMode
        # (XAE answers prompts with the default). ExportChild only writes a file; not timed yet (task 2.8).
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
