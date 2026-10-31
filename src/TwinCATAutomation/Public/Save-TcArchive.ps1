function Save-TcArchive {
    <#
    .SYNOPSIS
        Saves the open solution (.tnzip) or the TwinCAT configuration (.tszip) as an archive of the state in XAE memory; checks the Error List, because a missing component is only reported there. Lists the archive entries.
    .DESCRIPTION
        Kind Solution: ITcArchivePersist.SaveAsArchive(path), object from DTE.GetObject("TcArchivePersist")
        (TE1000 Automation Interface manual v1.7.0, 5.44 p.156-157, 6.3.7 p.209), file .tnzip.
        Kind Configuration: ITcSysManager9.SaveAsArchive(path) on the System Manager (5.1.8 p.49-50,
        6.5.13 p.241), file .tszip.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client
        (openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.4):
          - both pack the state IN XAE MEMORY, not the files on disk (an object not saved yet to
            the project file was in the archive's .plcproj); neither saves the project.
          - .tnzip = the solution level: the .sln, the TwinCAT project below a folder of its name,
            and it tries the other projects of the solution (Scope ...). .tszip = only the TwinCAT
            project (.tsproj and its PLC projects with _Libraries), no .sln. 1.2-1.3 s each.
          - an existing file -> ArgumentException "Archive file already exists!".
          - the .tnzip of a solution with a Scope project came back S_OK without that project
            (A10_Scope missing); the only trace was an Error List row "'TwinCAT Measurement' (...):
            Error creating Archive -> ..." (twice). So the result is never decided by the return
            value alone.
        Steps: FilePath absolute, valid, '.tnzip' for Solution / '.tszip' for Configuration, folder
        exists (ARCHIVE_FAILED reason not-absolute / invalid-path / extension / folder-missing); an
        existing file -> ARCHIVE_FILE_EXISTS unless -Overwrite; IDE_MODAL_DIALOG when a dialog is
        open; the Error List is read (baseline); -Overwrite renames the old file to '<FilePath>.bak'
        (data.previousFile); SaveAsArchive; readback; the Error List is read again.
        Readback: the file exists, is not empty and was written during this call, else
        ARCHIVE_FAILED reason not-written; it opens as a ZIP (System.IO.Compression.ZipFile), else
        reason not-a-zip (both: the new file is renamed to '<FilePath>.failed' and the old one put
        back, data.restore). data.entries: name and size of each entry, at most 200 (data.entryCount
        is the total, data.entriesTruncated / data.entriesNote when cut).
        Error List: the rows are counted per code + description + file + project before and after
        the call (error rows and rows of unknown severity); every row more than before is new
        (the same text twice counts twice). A new error row -> ARCHIVE_INCOMPLETE with
        data.errorItems; the file is KEPT and data.warnings says it is incomplete. When the baseline
        could not be read, only rows with the measured text "Error creating Archive" count. When the
        Error List cannot be read after the call, or its rows were cut (data.errorListTruncated) or
        some rows have no severity (data.unclassified) -> ARCHIVE_UNVERIFIED (file kept):
        completeness cannot be checked; a new unclassified row with "Error creating Archive" is
        ARCHIVE_INCOMPLETE instead. Whether XAE adds the "Error creating Archive" row before
        SaveAsArchive returns (synchronously) or later (asynchronously) is not measured; the module
        reads the Error List once, right after the call.
        Only saving: loading an archive replaces the open solution and is not offered.
        The project is not changed: BUILD_REQUIRED is not touched.
        No deadline (CODING_STANDARDS.md section 1): a dialog is ruled out right before the call,
        Connect-TcIde turns on ITcAutomationSettings.SilentMode, the probe calls returned in 1.2-1.3 s;
        the MCP tool timeout bounds it from outside.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER FilePath
        Absolute path of the archive to write: .tnzip for -Kind Solution, .tszip for -Kind Configuration.
    .PARAMETER Kind
        Solution (default): the whole solution, .tnzip (ITcArchivePersist). Configuration: the TwinCAT
        project only, .tszip (ITcSysManager9.SaveAsArchive).
    .PARAMETER Overwrite
        Replace an existing file: it is renamed to '<FilePath>.bak' first and put back when saving fails.
    .EXAMPLE
        Save-TcArchive -FilePath 'C:\Temp\Machine.tnzip'
    .EXAMPLE
        Save-TcArchive -FilePath 'C:\Temp\Machine.tszip' -Kind Configuration -Overwrite
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [ValidateSet('Solution', 'Configuration')]
        [string]$Kind = 'Solution',

        [Parameter()]
        [switch]$Overwrite
    )

    $k = if ($Kind -ieq 'Configuration') { 'Configuration' } else { 'Solution' }
    $ext = if ($k -eq 'Solution') { '.tnzip' } else { '.tszip' }
    $data = [PSCustomObject]@{ filePath = $FilePath; kind = $k; overwrite = [bool]$Overwrite; saved = $false }
    $bad = Test-TcOutputFilePath -FilePath $FilePath -Extensions @($ext) -AllowExisting:$Overwrite
    if ($null -ne $bad) {
        $data | Add-Member -NotePropertyName reason -NotePropertyValue $bad.Reason
        if ($bad.Reason -eq 'file-exists') {
            return New-TcResult -Success $false -ErrorCode 'ARCHIVE_FILE_EXISTS' -Data $data `
                -ErrorMessage "$($bad.Message) (SaveAsArchive does not overwrite: ArgumentException 'Archive file already exists!', measured 2026-10-31); nothing was saved." -Hint (Get-TcErrorHint -Code 'ARCHIVE_FILE_EXISTS')
        }
        return New-TcResult -Success $false -ErrorCode 'ARCHIVE_FAILED' -Data $data -ErrorMessage "$($bad.Message); nothing was saved." -Hint (Get-TcErrorHint -Code 'ARCHIVE_FAILED')
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED_IDE')
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $warnings.Add('the archive holds the state in XAE memory, not the files on disk (measured 2026-10-31, phase2-probe.md 3.4); save the project first when the disk version is wanted')
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
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray() -Force
        New-TcResult -Success $false -ErrorCode 'ARCHIVE_FAILED' -Data $data -ErrorMessage $m -Hint (Get-TcErrorHint -Code 'ARCHIVE_FAILED')
    }
    $rowKey = { param($i) "$([string]$i.code)|$([string]$i.description)|$([string]$i.file)|$([string]$i.project)" }
    try {
        $dlg = Get-TcTreeItemDialogResult -Operation "SaveAsArchive '$FilePath'" -Data $data
        if ($null -ne $dlg) { return $dlg }
        $target = $null
        if ($k -eq 'Solution') {
            if ($null -eq $script:TcDte) { return New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'No DTE: Connect-TcIde first.' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED_IDE') }
            $dte = $script:TcDte
            $target = Invoke-TcComRetry -OperationName 'GetObject TcArchivePersist' -ScriptBlock { Write-Output -NoEnumerate $dte.GetObject('TcArchivePersist') }
            if ($null -eq $target) {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'no-archive-object'
                return New-TcResult -Success $false -ErrorCode 'ARCHIVE_FAILED' -Data $data -ErrorMessage "DTE.GetObject('TcArchivePersist') returned nothing; nothing was saved." -Hint (Get-TcErrorHint -Code 'ARCHIVE_FAILED')
            }
        }
        else { $target = $sm }

        # baseline: error rows already in the Error List (left over from earlier operations)
        $elBefore = Get-TcErrorListSummary
        $baseline = $null
        if ($null -eq $elBefore.errorListError) {
            $baseline = @{}
            foreach ($i in @(@($elBefore.errorItems) + @($elBefore.unclassified))) { $k0 = & $rowKey $i; $baseline[$k0] = 1 + $(if ($baseline.ContainsKey($k0)) { [int]$baseline[$k0] } else { 0 }) }
        }

        if ($Overwrite -and (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            try { $bak = Move-TcFileAside -FilePath $FilePath }
            catch {
                $data | Add-Member -NotePropertyName reason -NotePropertyValue 'overwrite-move-failed'
                return New-TcResult -Success $false -ErrorCode 'ARCHIVE_FAILED' -Data $data -ErrorMessage "-Overwrite: '$FilePath' could not be renamed to .bak ($($_.Exception.Message)); nothing was saved." -Hint (Get-TcErrorHint -Code 'ARCHIVE_FAILED')
            }
            $data | Add-Member -NotePropertyName previousFile -NotePropertyValue $bak
        }
        $t0 = (Get-Date).ToUniversalTime()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # No deadline: see .DESCRIPTION (dialog ruled out above, SilentMode, 1.2-1.3 s measured).
            Invoke-TcComRetry -OperationName "SaveAsArchive ($k)" -ScriptBlock { $target.SaveAsArchive($FilePath) } | Out-Null
        }
        catch {
            if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
            $info = Get-TcComErrorInfo -ErrorRecord $_
            $data | Add-Member -NotePropertyName xaeMessage -NotePropertyValue $info.message
            $data | Add-Member -NotePropertyName hresult -NotePropertyValue $info.hresultHex
            return (& $restoreAndFail 'save-failed' "SaveAsArchive '$FilePath' ($k) failed: $($info.message)")
        }
        $sw.Stop()
        $data | Add-Member -NotePropertyName saveSec -NotePropertyValue ([Math]::Round($sw.Elapsed.TotalSeconds, 2))

        $facts = Get-TcOutputFileFacts -Path $FilePath
        if (-not $facts.exists -or $facts.size -le 0 -or $null -eq $facts.lastWriteTimeUtc -or $facts.lastWriteTimeUtc -lt $t0.AddSeconds(-2)) {
            $why = if (-not $facts.exists) { 'does not exist' } elseif ($facts.size -le 0) { 'is empty' } else { "was not written by this call (last written $($facts.lastWriteTime))" }
            return (& $restoreAndFail 'not-written' "SaveAsArchive returned, but '$FilePath' $why")
        }
        $data | Add-Member -NotePropertyName fileSize -NotePropertyValue $facts.size
        $data | Add-Member -NotePropertyName lastWriteTime -NotePropertyValue $facts.lastWriteTime
        $zip = Get-TcZipEntryList -Path $FilePath -Max 200
        if ($null -ne $zip.Error) { return (& $restoreAndFail 'not-a-zip' "SaveAsArchive returned, but '$FilePath' cannot be opened as a ZIP archive: $($zip.Error)") }
        $data | Add-Member -NotePropertyName entryCount -NotePropertyValue $zip.Count
        $data | Add-Member -NotePropertyName entries -NotePropertyValue $zip.Entries
        $data | Add-Member -NotePropertyName entriesTruncated -NotePropertyValue $zip.Truncated
        if ($zip.Truncated) { $data | Add-Member -NotePropertyName entriesNote -NotePropertyValue "only the first 200 of $($zip.Count) entries are listed" }
        $data.saved = $true

        # Error List after the call: a missing component is only reported there (measured)
        $elAfter = Get-TcErrorListSummary
        if ($null -ne $elAfter.errorListError) {
            $data | Add-Member -NotePropertyName errorListError -NotePropertyValue $elAfter.errorListError
            $warnings.Add("the Error List could not be read ($($elAfter.errorListError): $($elAfter.errorListMessage)); the archive file is kept, but whether every project is in it is not known")
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
            return New-TcResult -Success $false -ErrorCode 'ARCHIVE_UNVERIFIED' -Data $data `
                -ErrorMessage "SaveAsArchive wrote '$FilePath' ($($zip.Count) entries), but the Error List could not be read afterwards, so an incomplete archive (reported only there, measured 2026-10-31) cannot be ruled out." -Hint (Get-TcErrorHint -Code 'ARCHIVE_UNVERIFIED')
        }
        # count difference: a row more than before is new (S4)
        $newOf = {
            param($rows)
            $seen = @{}
            $out = [System.Collections.Generic.List[object]]::new()
            foreach ($i in @($rows)) {
                $k1 = & $rowKey $i
                $seen[$k1] = 1 + $(if ($seen.ContainsKey($k1)) { [int]$seen[$k1] } else { 0 })
                $had = if ($baseline.ContainsKey($k1)) { [int]$baseline[$k1] } else { 0 }
                if ($seen[$k1] -gt $had) { $out.Add($i) }
            }
            , $out.ToArray()
        }
        $unclassifiedAfter = @($elAfter.unclassified)
        if ($null -ne $baseline) {
            $new = & $newOf @($elAfter.errorItems)
            $newUnclassified = & $newOf $unclassifiedAfter
        }
        else {
            $warnings.Add("the Error List could not be read before the call ($($elBefore.errorListError)); only rows with the text 'Error creating Archive' are counted, also older ones")
            # XAE's own English text of the measured failure (phase2-probe.md 3.4)
            $new = @($elAfter.errorItems | Where-Object { ([string]$_.description).Contains('Error creating Archive') })
            $newUnclassified = $unclassifiedAfter
        }
        # an unclassified row with the measured text is an incomplete archive, not an unknown one (S3)
        $archiveRows = @($newUnclassified | Where-Object { ([string]$_.description).Contains('Error creating Archive') })
        if ($archiveRows.Count -gt 0) { $new = @($new) + $archiveRows }
        if ($new.Count -gt 0) {
            $data | Add-Member -NotePropertyName errorItems -NotePropertyValue $new
            $warnings.Add("the archive '$FilePath' is kept but INCOMPLETE: XAE reported $($new.Count) error(s) while writing it (data.errorItems)")
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
            $first = (@($new | Select-Object -First 3 | ForEach-Object { [string]$_.description }) -join '; ')
            return New-TcResult -Success $false -ErrorCode 'ARCHIVE_INCOMPLETE' -Data $data `
                -ErrorMessage "SaveAsArchive returned S_OK and wrote '$FilePath' ($($zip.Count) entries), but the Error List got $($new.Count) new error row(s): $first" -Hint (Get-TcErrorHint -Code 'ARCHIVE_INCOMPLETE')
        }
        if ($elAfter.truncated -or $unclassifiedAfter.Count -gt 0) {
            $data | Add-Member -NotePropertyName errorItems -NotePropertyValue @()
            $data | Add-Member -NotePropertyName errorListTruncated -NotePropertyValue ([bool]$elAfter.truncated)
            $data | Add-Member -NotePropertyName unclassified -NotePropertyValue $unclassifiedAfter
            $why = @()
            if ($elAfter.truncated) { $why += 'not every Error List row could be read (truncated)' }
            if ($unclassifiedAfter.Count -gt 0) { $why += "$($unclassifiedAfter.Count) row(s) have no severity (data.unclassified)" }
            $warnings.Add("the archive file is kept, but its completeness cannot be checked: $($why -join '; ')")
            $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
            return New-TcResult -Success $false -ErrorCode 'ARCHIVE_UNVERIFIED' -Data $data `
                -ErrorMessage "SaveAsArchive wrote '$FilePath' ($($zip.Count) entries), but the Error List cannot rule out an incomplete archive: $($why -join '; ')." -Hint (Get-TcErrorHint -Code 'ARCHIVE_UNVERIFIED')
        }
        $data | Add-Member -NotePropertyName errorItems -NotePropertyValue @()
        $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings.ToArray()
        New-TcResult -Success $true -Data $data
    }
    catch {
        $res = New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'ARCHIVE_FAILED' -Data $data -Operation "SaveAsArchive ($k)"
        if ($null -ne $bak) { $res.data | Add-Member -NotePropertyName restore -NotePropertyValue (Restore-TcFileAside -FilePath $FilePath -BakPath $bak) -Force }
        return $res
    }
}
