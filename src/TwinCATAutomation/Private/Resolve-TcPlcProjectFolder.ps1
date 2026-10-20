function Resolve-TcPlcProjectFolder {
    <#
    .SYNOPSIS
        Finds the POUs / DUTs / GVLs folder of the first PLC project.
    .DESCRIPTION
        -ExplicitPath given: LookupTreeItem(ExplicitPath)          ResolvedBy = 'explicit'
                             (a failure is passed on to the caller)
        otherwise:           "<Plc Project>^<FolderName>"         ResolvedBy = 'folder'
                             falls back to "<Plc Project>"        ResolvedBy = 'project-root'
        The project path comes from Resolve-TcPlcProjectPath (TIPC^<Plc>^<Plc> Project on
        4024 and 4026). IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT are rethrown.
        Returns @{ Item; Path; ResolvedBy }.
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    .PARAMETER FolderName
        POUs, DUTs or GVLs.
    .PARAMETER ExplicitPath
        Optional full tree path of the target folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter(Mandatory)]
        [ValidateSet('POUs', 'DUTs', 'GVLs')]
        [string]$FolderName,

        [Parameter()]
        [string]$ExplicitPath
    )

    $sm = $SysManager

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $item = Invoke-TcComRetry -OperationName "LookupTreeItem $ExplicitPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($ExplicitPath) }
        if ($null -eq $item) { throw "Tree item '$ExplicitPath' not found." }
        return @{ Item = $item; Path = $ExplicitPath; ResolvedBy = 'explicit' }
    }

    $projPath = Resolve-TcPlcProjectPath -SysManager $sm
    $folderPath = "$projPath^$FolderName"
    $item = $null
    try {
        $item = Invoke-TcComRetry -OperationName "LookupTreeItem $folderPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($folderPath) }
    }
    catch {
        if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
        Write-Verbose "LookupTreeItem('$folderPath') failed: $($_.Exception.Message)"
        $item = $null
    }
    if ($null -ne $item) {
        return @{ Item = $item; Path = $folderPath; ResolvedBy = 'folder' }
    }

    $item = Invoke-TcComRetry -OperationName "LookupTreeItem $projPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($projPath) }
    return @{ Item = $item; Path = $projPath; ResolvedBy = 'project-root' }
}
