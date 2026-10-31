function Save-TcPlcLibrary {
    <#
    .SYNOPSIS
        Saves the PLC project as a library file (.library / .compiled-library) with SaveAsLibrary(path, $false): the library is NOT installed. Does not change the project. Reads the file back.
    .DESCRIPTION
        API: ITcPlcIECProject.SaveAsLibrary(bstrLibraryPath, bInstall) on the '<Plc> Project' node,
        called with bInstall = false (TE1000 Automation Interface manual v1.7.0, 5.28.1.1 p.123;
        sample 6.5.13 p.240). To install the file afterwards use Install-TcLibrary -LibraryPath
        <file>. Encryption (SaveAsLibrary2 with bEncrypt) is not offered: XAE refuses it without a
        connected software protection / user database ("No Software-Protection/User-Database is
        connected to this TwinCAT project. Cannot save library with encryption!").
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client
        (openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.4):
          - '.library' (870 KB) and '.compiled-library' (480 KB) both work, 5.5-7 s per call.
          - an existing file -> ArgumentException "File '...' already exist. Cannot SaveAsLibrary!";
            another extension -> ArgumentException "... invalid file extension"; a missing folder ->
            DirectoryNotFoundException.
          - no project file changes (only the VS '.~u' file), no modal dialog. The library takes
            title / company / version from the project information.
          - whether it opens a dialog on a project that was never built is not measured.
        Checks before the call (nothing written on failure): FilePath absolute, valid, '.library'
        or '.compiled-library', folder exists (LIBRARY_SAVE_FAILED reason not-absolute /
        invalid-path / extension / folder-missing); an existing file -> LIBRARY_SAVE_FILE_EXISTS
        unless -Overwrite; IDE_MODAL_DIALOG when a dialog is open.
        -Overwrite: the existing file is renamed to '<FilePath>.bak' (-2, -3 ... when taken) first
        (data.previousFile); when the call or the readback fails the new file (if any) is renamed to
        '<FilePath>.failed' and the old one is put back (data.restore).
        XAE refusing -> LIBRARY_SAVE_FAILED reason save-failed (data.xaeMessage, data.hresult).
        Readback: the file exists, is not empty and was written during this call (LastWriteTimeUtc
        not older than 2 s before the call); else LIBRARY_SAVE_FAILED reason not-written.
        The project is not changed: BUILD_REQUIRED is not touched.
        No deadline (CODING_STANDARDS.md section 1): a dialog is ruled out right before the call,
        Connect-TcIde turns on ITcAutomationSettings.SilentMode, the probe calls returned in 5.5-7 s
        without a dialog; the MCP tool timeout bounds it from outside.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER FilePath
        Absolute path of the library file to write, ending in .library or .compiled-library.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one PLC
        project (otherwise PLC_PROJECT_AMBIGUOUS).
    .PARAMETER Overwrite
        Replace an existing file: it is renamed to '<FilePath>.bak' first and put back when saving fails.
    .EXAMPLE
        Save-TcPlcLibrary -FilePath 'C:\Temp\MyLib.library'
    .EXAMPLE
        Save-TcPlcLibrary -FilePath 'C:\Temp\MyLib.compiled-library' -Overwrite
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [switch]$Overwrite
    )

    $data = [PSCustomObject]@{ filePath = $FilePath; overwrite = [bool]$Overwrite; installed = $false; saved = $false }
    $bad = Test-TcOutputFilePath -FilePath $FilePath -Extensions @('.library', '.compiled-library') -AllowExisting:$Overwrite
    if ($null -ne $bad) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $bad.Reason
        if ($bad.Reason -eq 'file-exists') {
            return New-TcResult -Success $false -ErrorCode 'LIBRARY_SAVE_FILE_EXISTS' -Data $data `
                -ErrorMessage "$($bad.Message) (SaveAsLibrary does not overwrite: ArgumentException 'already exist', measured 2026-10-31); nothing was saved." -Hint (Get-TcErrorHint -Code 'LIBRARY_SAVE_FILE_EXISTS')
        }
        return New-TcResult -Success $false -ErrorCode 'LIBRARY_SAVE_FAILED' -Data $data -ErrorMessage "$($bad.Message); nothing was saved." -Hint (Get-TcErrorHint -Code 'LIBRARY_SAVE_FAILED')
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $bak = $null
    $restoreAndFail = {
        param([string]$Reason, [string]$Message)
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force
        $m = $Message
        if ($null -ne $bak) {
            $rs = Restore-TcFileAside -FilePath $FilePath -BakPath $bak
            $data | Add-Member -NotePropertyName restore -NotePropertyValue $rs -Force
            $m += $(if ($rs.restored) { "; the previous file was put back from '$bak'" + $(if ($rs.failedFile) { " (the new file is '$($rs.failedFile)')" } else { '' }) } else { "; $($rs.message)" })
        }
        New-TcResult -Success $false -ErrorCode 'LIBRARY_SAVE_FAILED' -Data $data -ErrorMessage $m -Hint (Get-TcErrorHint -Code 'LIBRARY_SAVE_FAILED')
    }
    try {
        $spec = Resolve-TcPlcProjectSpec -SysManager $sm -PlcProjectPath $PlcProjectPath
        if ($null -ne $spec.Result) { return $spec.Result }
        $prjPath = $spec.PlcProjectPath
        $data | Add-Member -NotePropertyName plcProjectPath -NotePropertyValue $prjPath
        $r = Resolve-TcTreeItem -SysManager $sm -Path $prjPath -Data $data -ParameterName 'PlcProjectPath'
        if ($null -ne $r.Result) { return $r.Result }
        $prj = $r.Item

        $dlg = Get-TcTreeItemDialogResult -Operation "SaveAsLibrary '$FilePath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        if ($Overwrite -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            try { $bak = Move-TcFileAside -FilePath $FilePath }
            catch {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'overwrite-move-failed'
                return New-TcResult -Success $false -ErrorCode 'LIBRARY_SAVE_FAILED' -Data $data -ErrorMessage "-Overwrite: '$FilePath' could not be renamed to .bak ($($_.Exception.Message)); nothing was saved." -Hint (Get-TcErrorHint -Code 'LIBRARY_SAVE_FAILED')
            }
            $data | Add-Member -NotePropertyName previousFile -NotePropertyValue $bak
        }
        $t0 = (Get-Date).ToUniversalTime()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline: see .DESCRIPTION (dialog ruled out above, SilentMode, 5.5-7 s measured).
            Invoke-TcComRetry -OperationName 'SaveAsLibrary' -ScriptBlock { $prj.SaveAsLibrary($FilePath, $false) } | Out-Null
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) {
                $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_SAVE_FAILED' -Data $data -Operation 'SaveAsLibrary'
                if ($null -ne $bak) { $res.data | Add-Member -NotePropertyName restore -NotePropertyValue (Restore-TcFileAside -FilePath $FilePath -BakPath $bak) -Force }
                return $res
            }
            $info = Get-TcComErrorInfo -ErrorRecord $_
            $data | Add-Member -NotePropertyName xaeMessage -NotePropertyValue $info.message
            $data | Add-Member -NotePropertyName hresult -NotePropertyValue $info.hresultHex
            return (& $restoreAndFail 'save-failed' "SaveAsLibrary '$FilePath' failed: $($info.message)")
        }
        $sw.Stop()
        $data | Add-Member -NotePropertyName saveSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))
        $facts = Get-TcOutputFileFacts -Path $FilePath
        if (-not $facts.exists -or $facts.size -le 0 -or $null -eq $facts.lastWriteTimeUtc -or $facts.lastWriteTimeUtc -lt $t0.AddSeconds(-2)) {
            $why = if (-not $facts.exists) { 'does not exist' } elseif ($facts.size -le 0) { 'is empty' } else { "was not written by this call (last written $($facts.lastWriteTime))" }
            return (& $restoreAndFail 'not-written' "SaveAsLibrary returned, but '$FilePath' $why")
        }
        $data.saved = $true
        $data | Add-Member -NotePropertyName fileSize -NotePropertyValue $facts.size
        $data | Add-Member -NotePropertyName lastWriteTime -NotePropertyValue $facts.lastWriteTime
        New-TcResult -Success $true -Data $data
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_SAVE_FAILED' -Data $data -Operation 'Save-TcPlcLibrary'
        if ($null -ne $bak) { $res.data | Add-Member -NotePropertyName restore -NotePropertyValue (Restore-TcFileAside -FilePath $FilePath -BakPath $bak) -Force }
        return $res
    }
}
