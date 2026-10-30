function Get-TcTreeItemXml {
    <#
    .SYNOPSIS
        Returns the XML description of one tree item (ITcSmTreeItem.ProduceXml). Read-only.
    .DESCRIPTION
        Generic tree tool (MCP ProduceXml). ITcSmTreeItem::ProduceXml (TE1000 Automation Interface
        manual v1.7.0, 5.2.1.8, p.61) serializes the item with the root node TreeItem; ProduceXml /
        ConsumeXml correspond to "Export/Import XML Description" in the IDE (4.2.3).
        data: path, xml, recursive, length. Use the element paths of this XML to build a ConsumeXml
        fragment (Set-TcTreeItemXml), e.g. TreeItem/TaskDef/CycleTime for a task.
        A missing path returns TREEITEM_NOT_FOUND with the nearest existing parent in error.hint.
    .PARAMETER Path
        Full tree path, e.g. "TIRT^PlcTask". No wildcards.
    .PARAMETER Recursive
        Passed as bRecursive to ProduceXml (default false). What it adds is not described in the manual
        excerpt (5.2.1.8); not measured.
    .EXAMPLE
        Get-TcTreeItemXml -Path 'TIRT^PlcTask'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [switch]$Recursive
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $data = [PSCustomObject]@{ path = $Path; recursive = [bool]$Recursive }
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $xml = Get-TcTreeItemXmlText -Item $r.Item -Recursive ([bool]$Recursive) -Path $Path
        if ([string]::IsNullOrWhiteSpace($xml)) {
            return New-TcResult -Success $false -ErrorCode 'TREEITEM_READ_FAILED' -Data $data `
                -ErrorMessage "ProduceXml('$Path') returned no XML" -Hint (Get-TcErrorHint -Code 'TREEITEM_READ_FAILED')
        }
        $data | Add-Member -NotePropertyName xml -NotePropertyValue $xml
        $data | Add-Member -NotePropertyName length -NotePropertyValue $xml.Length
        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_READ_FAILED' -Data $data -Operation "ProduceXml '$Path'"
    }
}
