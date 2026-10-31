function Export-TcPlcOpen {
    <#
    .SYNOPSIS
        Exports PLC objects (or the whole PLC project) to a PLCopen XML file (PlcOpenExport on '<Plc> Project'); does not change the project. Reads the file back and lists its objects.
    .DESCRIPTION
        API: ITcPlcOpenImportExport.PlcOpenExport(bstrFile, bstrSelection) on the '<Plc> Project'
        node (TE1000 Automation Interface manual v1.7.0, 5.20 p.105-108; sample 6.5.4 p.228-229).
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client
        (openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.3):
          - selection: '.' between folder levels ('LIB.AxisControl.FB_AxisControl', a folder name
            with a space works), several objects joined with ';', a bare object name works too
            ('FB_P2Probe'); an empty selection exports the whole project.
          - the subtree is included: an FB comes with its methods, properties (Get / Set) and
            actions; EXCEPT the properties of an INTERFACE without Get / Set, which are not exported
            (see below). A method or accessor alone is refused by XAE ("Couldn't create ExportObjects").
          - '^' instead of '.' -> COMException 0x98510008 "Selection '...' not found!"; an
            unknown name -> the same error.
          - an existing file -> ArgumentException "File '...' already exists!" (the file is kept);
            a missing folder -> ArgumentException "Directory '...' does not exist!".
          - the properties of an INTERFACE (without Get / Set) are not exported, only its methods;
            with accessors not measured.
        Checks before the call (nothing written on failure):
          - each -Selection element: not empty, no '^', no ';', no empty level ('..') ->
            PLCOPEN_FAILED reason invalid-selection.
          - an element that points at a method / property / action / transition / accessor (looked
            up as '<Plc> Project^<element with ^>', else Resolve-TcPouPath; ItemType 608-616, 654,
            655) -> PLCOPEN_FAILED reason member-selection, data.memberSelection.suggestedSelection
            = the object that contains it. An element the module cannot find goes to XAE as given.
          - FilePath: absolute, valid, folder exists (PLCOPEN_FAILED reason not-absolute /
            invalid-path / folder-missing); an existing file -> PLCOPEN_FILE_EXISTS unless
            -Overwrite.
          - IDE_MODAL_DIALOG when a dialog is open.
        -Overwrite: the existing file is renamed to '<FilePath>.bak' (-2, -3 ... when taken) before
        the call (data.previousFile); when the call or the readback fails, the new file (if any) is
        renamed to '<FilePath>.failed' and the old one is put back (data.restore).
        XAE errors: 0x98510008 -> PLCOPEN_FAILED reason selection-not-found; ArgumentException ->
        reason invalid-argument; other -> reason export-failed (data.xaeMessage, data.hresult).
        Readback: the file exists and is not empty, parses as PLCopen XML (Read-TcXmlFile, no DTD:
        no XXE) and every -Selection element's last level is the name of an object or folder in the
        file (PLCOPEN_VERIFY_FAILED, data.missingSelections). data.objects: name, kind (POU / DUT /
        ITF / GVL; also the objects of a whole-project export below addData, one GVL per name),
        pouType, folder (from the -Selection path when the file has no Folder for an object selected
        inside a folder, verification/phase2-3.8.md P5), members (name, kind; interface methods and
        properties included).
        The project is not changed and BUILD_REQUIRED is not touched.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Selection
        Objects or folders relative to '<Plc> Project', one per element, '.' between folder levels;
        the first level is a folder of the PLC project, e.g. 'AxisInterface.LIB.AxisControl.FB_AxisControl'
        (the string measured 2026-10-31) or 'POUs.FB_A'. Leading / trailing blanks are trimmed. Empty =
        the whole PLC project.
    .PARAMETER FilePath
        Absolute path of the PLCopen XML file to write (e.g. C:\Temp\export.xml); its folder must exist.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER Overwrite
        Replace an existing file: it is renamed to '<FilePath>.bak' first and put back when the export fails.
    .EXAMPLE
        Export-TcPlcOpen -Selection 'AxisInterface.LIB.AxisControl.FB_AxisControl' -FilePath 'C:\Temp\axis.xml'
        The selection string measured 2026-10-31 (4026 VS2022, self-built client); its first level
        'AxisInterface' is a folder of the PLC project, not the PLC name.
    .EXAMPLE
        Export-TcPlcOpen -FilePath 'C:\Temp\whole-project.xml' -Overwrite
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Selection,

        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [switch]$Overwrite
    )

    # trimmed before the checks and before XAE gets them
    $sel = @($Selection | Where-Object { $null -ne $_ } | ForEach-Object { $_.Trim() })
    $data = [PSCustomObject]@{ filePath = $FilePath; selection = $sel; overwrite = [bool]$Overwrite; exported = $false }
    $badSel = Test-TcPlcOpenSelection -Selection $sel
    if ($null -ne $badSel) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $badSel.Reason
        return New-TcResult -Success $false -ErrorCode 'PLCOPEN_FAILED' -Data $data -ErrorMessage "$($badSel.Message); nothing was exported." -Hint (Get-TcErrorHint -Code 'PLCOPEN_FAILED')
    }
    $bad = Test-TcOutputFilePath -FilePath $FilePath -AllowExisting:$Overwrite
    if ($null -ne $bad) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $bad.Reason
        if ($bad.Reason -eq 'file-exists') {
            return New-TcResult -Success $false -ErrorCode 'PLCOPEN_FILE_EXISTS' -Data $data `
                -ErrorMessage "$($bad.Message) (PlcOpenExport does not overwrite: ArgumentException 'File ... already exists!', measured 2026-10-31); nothing was exported." -Hint (Get-TcErrorHint -Code 'PLCOPEN_FILE_EXISTS')
        }
        return New-TcResult -Success $false -ErrorCode 'PLCOPEN_FAILED' -Data $data -ErrorMessage "$($bad.Message); nothing was exported." -Hint (Get-TcErrorHint -Code 'PLCOPEN_FAILED')
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED_IDE')
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $bak = $null
    $restoreAndFail = {
        param([string]$Code, [string]$Reason, [string]$Message)
        if (-not [string]::IsNullOrEmpty($Reason)) { $data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force }
        $m = $Message
        if ($null -ne $bak) {
            $rs = Restore-TcFileAside -FilePath $FilePath -BakPath $bak
            $data | Add-Member -NotePropertyName restore -NotePropertyValue $rs -Force
            $m += $(if ($rs.restored) { "; the previous file was put back from '$bak'" + $(if ($rs.failedFile) { " (the new file is '$($rs.failedFile)')" } else { '' }) } else { "; $($rs.message)" })
        }
        New-TcResult -Success $false -ErrorCode $Code -Data $data -ErrorMessage $m -Hint (Get-TcErrorHint -Code $Code)
    }
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $data | Add-Member -NotePropertyName plcProjectPath -NotePropertyValue $prjPath
        $r = Resolve-TcTreeItem -SysManager $sm -Path $prjPath -Data $data -ParameterName 'PlcProjectPath'
        if ($null -ne $r.Result) { return $r.Result }
        $prj = $r.Item

        # a member alone is refused by XAE ("Couldn't create ExportObjects", measured): check first
        foreach ($el in $sel) {
            $hit = Find-TcPlcOpenSelectionItem -SysManager $sm -ProjectPath $prjPath -Element $el
            if ($null -ne $hit -and $script:TcPlcOpenMemberItemTypes -contains $hit.ItemType) {
                $kind = (Get-TcPlcObjectKind -ItemType $hit.ItemType).ObjectKind
                $parentSel = Get-TcPlcOpenParentSelection -SysManager $sm -ProjectPath $prjPath -Path $hit.Path
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'member-selection'
                $data | Add-Member -NotePropertyName memberSelection -NotePropertyValue ([PSCustomObject]@{ element = $el; path = $hit.Path; itemType = $hit.ItemType; objectKind = $kind; suggestedSelection = $parentSel })
                return New-TcResult -Success $false -ErrorCode 'PLCOPEN_FAILED' -Data $data `
                    -ErrorMessage "-Selection '$el' is a $kind ('$($hit.Path)', ItemType $($hit.ItemType)); XAE exports members only with their object (ArgumentException 'Couldn't create ExportObjects', measured 2026-10-31). Select '$parentSel' instead; nothing was exported." `
                    -Hint (Get-TcErrorHint -Code 'PLCOPEN_FAILED')
            }
        }

        $dlg = Get-TcTreeItemDialogResult -Operation "PlcOpenExport '$FilePath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        if ($Overwrite -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            try { $bak = Move-TcFileAside -FilePath $FilePath }
            catch {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'overwrite-move-failed'
                return New-TcResult -Success $false -ErrorCode 'PLCOPEN_FAILED' -Data $data -ErrorMessage "-Overwrite: '$FilePath' could not be renamed to .bak ($($_.Exception.Message)); nothing was exported." -Hint (Get-TcErrorHint -Code 'PLCOPEN_FAILED')
            }
            $data | Add-Member -NotePropertyName previousFile -NotePropertyValue $bak
        }

        $selString = $sel -join ';'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline (CODING_STANDARDS.md section 1): a dialog was ruled out just above,
            # Connect-TcIde turns on ITcAutomationSettings.SilentMode, and PlcOpenExport returned in
            # 145-231 ms (2 MB for a whole project in 177 ms) without a dialog in every probe call
            # (measured 2026-10-31 4026 VS2022, self-built client). The MCP tool timeout bounds it.
            Invoke-TcComRetry -OperationName 'PlcOpenExport' -ScriptBlock { $prj.PlcOpenExport($FilePath, $selString) } | Out-Null
        }
        catch {
            $pass = Get-TcTreeItemPassThroughError -ErrorRecord $_
            if ($null -ne $pass) {
                $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'PLCOPEN_FAILED' -Data $data -Operation 'PlcOpenExport'
                if ($null -ne $bak) { $res.data | Add-Member -NotePropertyName restore -NotePropertyValue (Restore-TcFileAside -FilePath $FilePath -BakPath $bak) -Force }
                return $res
            }
            $info = Get-TcComErrorInfo -ErrorRecord $_
            $data | Add-Member -NotePropertyName xaeMessage -NotePropertyValue $info.message
            $data | Add-Member -NotePropertyName hresult -NotePropertyValue $info.hresultHex
            $reason = if ($info.hresult -eq $script:TcPlcOpenSelectionNotFoundHResult) { 'selection-not-found' } elseif ($info.argument) { 'invalid-argument' } else { 'export-failed' }
            return (& $restoreAndFail 'PLCOPEN_FAILED' $reason "PlcOpenExport '$FilePath' (selection '$selString') failed: $($info.message)")
        }
        $sw.Stop()
        $data | Add-Member -NotePropertyName exportSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))

        $facts = Get-TcOutputFileFacts -Path $FilePath
        if (-not $facts.exists -or $facts.size -le 0) {
            return (& $restoreAndFail 'PLCOPEN_VERIFY_FAILED' 'file-not-written' "PlcOpenExport returned, but '$FilePath' does not exist or is empty")
        }
        $data | Add-Member -NotePropertyName fileSize -NotePropertyValue $facts.size
        $parsed = $null
        try { $parsed = Read-TcPlcOpenFile -Path $FilePath }
        catch { return (& $restoreAndFail 'PLCOPEN_VERIFY_FAILED' 'invalid-file' "PlcOpenExport returned, but '$FilePath' cannot be read as PLCopen XML: $($_.Exception.Message)") }
        $objects = @($parsed.Objects)
        # One object selected inside a folder: the file has no Folder for it (measured 2026-10-31 4026
        # and 4024, verification/phase2-3.8.md P5), so the folder comes from the selection path.
        foreach ($s in @($sel)) {
            $levels = @($s.Trim() -split '\.')
            if ($levels.Count -lt 2) { continue }
            foreach ($o in @($objects | Where-Object { $null -eq $_.folder -and $_.name -ieq $levels[-1] })) {
                $o.folder = ($levels[0..($levels.Count - 2)] -join '.')
            }
        }
        $data | Add-Member -NotePropertyName objects -NotePropertyValue $objects
        $data | Add-Member -NotePropertyName objectCount -NotePropertyValue $objects.Count
        $names = @($objects | ForEach-Object { $_.name }) + @($parsed.Folders)
        $missing = @($sel | Where-Object {
                $leaf = ($_.Trim() -split '\.')[-1]
                @($names | Where-Object { $_ -ieq $leaf }).Count -eq 0
            })
        if ($missing.Count -gt 0) {
            $data | Add-Member -NotePropertyName missingSelections -NotePropertyValue $missing
            return (& $restoreAndFail 'PLCOPEN_VERIFY_FAILED' 'selection-missing' "PlcOpenExport returned, but '$FilePath' has no object or folder named after $(($missing | ForEach-Object { "'$_'" }) -join ', ') (objects in the file: $(@($objects | ForEach-Object { $_.name }) -join ', '))")
        }
        $data.exported = $true
        New-TcResult -Success $true -Data $data
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'PLCOPEN_FAILED' -Data $data -Operation 'Export-TcPlcOpen'
        if ($null -ne $bak) { $res.data | Add-Member -NotePropertyName restore -NotePropertyValue (Restore-TcFileAside -FilePath $FilePath -BakPath $bak) -Force }
        return $res
    }
}
