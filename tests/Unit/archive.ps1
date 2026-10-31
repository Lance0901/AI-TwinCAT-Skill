# Unit: task 3.4 (complete-automation-interface phase 2): Save-TcPlcLibrary (MCP SaveAsLibrary) and
# Save-TcArchive (SaveArchive).
# No IDE / runtime: a mock '<Plc> Project' node with SaveAsLibrary, a mock ITcSysManager with
# SaveAsArchive (.tszip) and a mock DTE whose GetObject('TcArchivePersist') returns an object with
# SaveAsArchive (.tnzip). The archives are real ZIP files. As in the probe (verification/phase2-probe.md 3.4)
# a .tnzip can come back S_OK while the Error List gets "Error creating Archive"; Get-TcBuildErrors is mocked.
#   powershell.exe -NoProfile -File tests/Unit/archive.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 6 -Compress }

$Root = Join-Path $env:TEMP ("tcauto-unit-archive-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $Root -Force
$Sln = Join-Path $Root 'Arc.sln'
[System.IO.File]::WriteAllText($Sln, '')

function global:New-MockZip([string]$Path, [int]$Count) {
    $z = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        for ($i = 1; $i -le $Count; $i++) {
            $e = $z.CreateEntry("Arc/plc/POUs/F$i.TcPOU")
            $w = New-Object System.IO.StreamWriter($e.Open())
            try { $w.Write("entry $i") } finally { $w.Dispose() }
        }
    }
    finally { $z.Dispose() }
}
$global:A = @{}
function Reset-Mock {
    Get-ChildItem -LiteralPath $Root -File | Where-Object { $_.Name -ne 'Arc.sln' } | Remove-Item -Force
    $global:A.Mode = 'ok'; $global:A.Calls = [System.Collections.ArrayList]::new(); $global:A.Dialog = $null
    $global:A.Rows = @(); $global:A.ElReads = 0; $global:A.ElFail = @(); $global:A.Entries = 3
    $global:A.Unclassified = @(); $global:A.Truncated = $false
}
function New-Row($desc) { [PSCustomObject]@{ severity = 'Error'; code = ''; description = $desc; project = ''; file = ''; line = $null; column = 0 } }
$scopeRow = "'TwinCAT Measurement' (15:55:10.615): Error creating Archive -> an item with the same key has already been added"
$writeArchive = {
    param($path, [string]$Who)
    $global:A.Calls.Add("$Who|$path") | Out-Null
    switch ($global:A.Mode) {
        'throw' { throw [System.ArgumentException]::new('Archive file already exists!') }
        'nowrite' { return }
        'garbage' { [System.IO.File]::WriteAllText($path, 'not a zip'); return }
    }
    New-MockZip $path $global:A.Entries
    if ($global:A.Mode -eq 'scope-error') { $global:A.Rows = @($global:A.Rows) + @((New-Row $global:A.ScopeRow)) }
    if ($global:A.Mode -eq 'scope-unclassified') { $global:A.Unclassified = @($global:A.Unclassified) + @((New-Row $global:A.ScopeRow)) }
    if ($global:A.Mode -eq 'other-unclassified') { $global:A.Unclassified = @((New-Row 'some row without a severity')) }
    if ($global:A.Mode -eq 'truncate') { $global:A.Truncated = $true }
}
$global:A.Write = $writeArchive
$global:A.ScopeRow = $scopeRow
$prj = [PSCustomObject]@{ Name = 'plc Project'; PathName = 'TIPC^plc^plc Project'; ItemType = 600 }
$prj | Add-Member ScriptMethod SaveAsLibrary {
    param($path, $install)
    $global:A.Calls.Add("SaveAsLibrary|$path|$install") | Out-Null
    switch ($global:A.Mode) {
        'throw' { throw [System.ArgumentException]::new("File '$path' already exist. Cannot SaveAsLibrary!") }
        'nowrite' { return }
        'empty' { [System.IO.File]::WriteAllText($path, ''); return }
    }
    New-MockZip $path 2
}
$global:A.Prj = $prj
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if ($p -eq 'TIPC^plc^plc Project') { return , $global:A.Prj }
    throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001)
}
$sm | Add-Member ScriptMethod SaveAsArchive { param($path) & $global:A.Write $path 'sm' }
$global:A.Sm = $sm
$persist = New-Object PSObject
$persist | Add-Member ScriptMethod SaveAsArchive { param($path) & $global:A.Write $path 'persist' }
$dte = New-Object PSObject
$dte | Add-Member ScriptMethod GetObject { param($name) $global:A.Calls.Add("GetObject|$name") | Out-Null; if ($name -eq 'TcArchivePersist') { return , $global:A.Persist }; $null }
$global:A.Persist = $persist

& $mod {
    param($s, $d)
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = $s; $script:TcDte = $d
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:A.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:A.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    function script:Get-TcBuildErrors {
        [CmdletBinding()] param([int]$TimeoutSec = 30, [switch]$IncludeWarnings, [switch]$IncludeMessages)
        $global:A.ElReads++
        if (@($global:A.ElFail) -contains $global:A.ElReads) { return [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'ERRORLIST_UNAVAILABLE'; message = 'Error List window not found (mock)' } } }
        $errs = @($global:A.Rows | ForEach-Object { [PSCustomObject]@{ severity = $_.severity; code = $_.code; description = $_.description; project = $_.project; file = $_.file; line = $_.line; column = 0 } })
        $d = [PSCustomObject]@{ counts = [PSCustomObject]@{ errors = $errs.Count; warnings = 0; messages = 0 }; errors = $errs; warnings = @(); truncated = [bool]$global:A.Truncated }
        if (@($global:A.Unclassified).Count -gt 0) { $d | Add-Member -NotePropertyName unclassified -NotePropertyValue @($global:A.Unclassified | ForEach-Object { [PSCustomObject]@{ severity = $null; code = $_.code; description = $_.description; project = $_.project; file = $_.file; line = $_.line; column = 0 } }) }
        [PSCustomObject]@{ success = $true; data = $d }
    }
} $Sln $dte
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
$dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }

try {
    # ===== Save-TcPlcLibrary
    Reset-Mock; Reset-BuildRequired
    $lib = Join-Path $Root 'My.library'
    $r = Save-TcPlcLibrary -FilePath (Join-Path $Root 'My.txt')
    Check 'Library .txt -> LIBRARY_SAVE_FAILED extension, XAE not called' ($r.error.code -eq 'LIBRARY_SAVE_FAILED' -and $r.data.reason -eq 'extension' -and $global:A.Calls.Count -eq 0) (J $r.error)
    $r = Save-TcPlcLibrary -FilePath $lib
    Check 'Library: SaveAsLibrary(path, False) on <Plc> Project, saved, file read back' ($r.success -and $r.data.saved -and -not $r.data.installed -and $global:A.Calls[0] -eq "SaveAsLibrary|$lib|False" -and $r.data.fileSize -gt 0 -and $r.data.lastWriteTime) (J $r.data)
    Check 'Library: no BUILD_REQUIRED recorded' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"
    $r = Save-TcPlcLibrary -FilePath (Join-Path $Root 'My.compiled-library')
    Check 'Library .compiled-library accepted' ($r.success) (J $r.error)
    $n = $global:A.Calls.Count
    $r = Save-TcPlcLibrary -FilePath $lib
    Check 'Library existing file without -Overwrite -> LIBRARY_SAVE_FILE_EXISTS, XAE not called' ($r.error.code -eq 'LIBRARY_SAVE_FILE_EXISTS' -and $global:A.Calls.Count -eq $n) (J $r.error)
    $oldBytes = [System.IO.File]::ReadAllBytes($lib)
    $r = Save-TcPlcLibrary -FilePath $lib -Overwrite
    Check 'Library -Overwrite: old file kept as .bak, new file written' ($r.success -and $r.data.previousFile -eq "$lib.bak" -and (Test-Path -LiteralPath "$lib.bak") -and [System.IO.File]::ReadAllBytes("$lib.bak").Length -eq $oldBytes.Length -and (Test-Path -LiteralPath $lib)) (J $r.data)
    Remove-Item -LiteralPath "$lib.bak" -Force
    [System.IO.File]::WriteAllText($lib, 'previous library')
    $global:A.Mode = 'throw'
    $r = Save-TcPlcLibrary -FilePath $lib -Overwrite
    Check 'Library -Overwrite, XAE throws -> LIBRARY_SAVE_FAILED save-failed, previous file put back' ($r.error.code -eq 'LIBRARY_SAVE_FAILED' -and $r.data.reason -eq 'save-failed' -and $r.data.xaeMessage -match 'already exist' -and $r.data.restore.restored -and ([System.IO.File]::ReadAllText($lib)) -eq 'previous library' -and -not (Test-Path -LiteralPath "$lib.bak")) (J $r.data)
    $global:A.Mode = 'nowrite'
    $r = Save-TcPlcLibrary -FilePath (Join-Path $Root 'None.library')
    Check 'Library: returns but no file -> LIBRARY_SAVE_FAILED not-written' ($r.error.code -eq 'LIBRARY_SAVE_FAILED' -and $r.data.reason -eq 'not-written') (J $r.error)
    $global:A.Mode = 'empty'
    $r = Save-TcPlcLibrary -FilePath $lib -Overwrite
    Check 'Library -Overwrite: empty file written -> not-written, previous file back, empty one kept as .failed' ($r.error.code -eq 'LIBRARY_SAVE_FAILED' -and $r.data.reason -eq 'not-written' -and ([System.IO.File]::ReadAllText($lib)) -eq 'previous library' -and $r.data.restore.failedFile -eq "$lib.failed") (J $r.data.restore)
    Reset-Mock; $global:A.Dialog = $dialog
    $r = Save-TcPlcLibrary -FilePath (Join-Path $Root 'D.library')
    Check 'Library: modal dialog -> IDE_MODAL_DIALOG, XAE not called' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:A.Calls.Count -eq 0) (J $r.error)

    # ===== Save-TcArchive: checks
    Reset-Mock; Reset-BuildRequired
    $tn = Join-Path $Root 'Arc.tnzip'
    $ts = Join-Path $Root 'Arc.tszip'
    $r = Save-TcArchive -FilePath $ts
    Check 'Archive Kind Solution with .tszip -> ARCHIVE_FAILED extension, nothing called' ($r.error.code -eq 'ARCHIVE_FAILED' -and $r.data.reason -eq 'extension' -and $global:A.Calls.Count -eq 0) (J $r.error)
    $r = Save-TcArchive -FilePath $tn -Kind Configuration
    Check 'Archive Kind Configuration with .tnzip -> ARCHIVE_FAILED extension' ($r.error.code -eq 'ARCHIVE_FAILED' -and $r.data.reason -eq 'extension') (J $r.error)

    # ===== success, both kinds
    $global:A.Rows = @((New-Row $scopeRow))   # stale row from an earlier archive
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive Solution: TcArchivePersist.SaveAsArchive, entries listed, stale Error List row not counted' ($r.success -and $r.data.saved -and $global:A.Calls[0] -eq 'GetObject|TcArchivePersist' -and $global:A.Calls[1] -eq "persist|$tn" -and $r.data.entryCount -eq 3 -and @($r.data.entries).Count -eq 3 -and $r.data.entries[0].name -eq 'Arc/plc/POUs/F1.TcPOU' -and $r.data.entries[0].size -eq 7 -and -not $r.data.entriesTruncated -and @($r.data.errorItems).Count -eq 0) (J $r.data)
    Check 'Archive: Error List read before and after, warning says memory state' ($global:A.ElReads -eq 2 -and @($r.data.warnings | Where-Object { $_ -match 'state in XAE memory' }).Count -eq 1) (J $r.data.warnings)
    $r = Save-TcArchive -FilePath $ts -Kind Configuration
    Check 'Archive Configuration: ITcSysManager.SaveAsArchive with the .tszip path' ($r.success -and @($global:A.Calls | Where-Object { $_ -eq "sm|$ts" }).Count -eq 1) (J $global:A.Calls)
    Check 'Archive: no BUILD_REQUIRED recorded' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"
    $n = $global:A.Calls.Count
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive existing file without -Overwrite -> ARCHIVE_FILE_EXISTS, nothing called' ($r.error.code -eq 'ARCHIVE_FILE_EXISTS' -and $global:A.Calls.Count -eq $n) (J $r.error)

    # ===== S_OK but incomplete (Error List)
    Reset-Mock; $global:A.Mode = 'scope-error'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive S_OK + new "Error creating Archive" row -> ARCHIVE_INCOMPLETE, errorItems, file kept, warning' ($r.error.code -eq 'ARCHIVE_INCOMPLETE' -and @($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].description -match 'Error creating Archive' -and (Test-Path -LiteralPath $tn) -and $r.data.entryCount -eq 3 -and @($r.data.warnings | Where-Object { $_ -match 'INCOMPLETE' }).Count -eq 1) (J $r)
    Reset-Mock; $global:A.Mode = 'scope-error'; $global:A.ElFail = @(1)
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive baseline unreadable -> rows with "Error creating Archive" count, warning says so' ($r.error.code -eq 'ARCHIVE_INCOMPLETE' -and @($r.data.warnings | Where-Object { $_ -match 'could not be read before the call' }).Count -eq 1) (J $r.data.warnings)
    Reset-Mock; $global:A.ElFail = @(2)
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive Error List unreadable after the call -> ARCHIVE_UNVERIFIED, file kept' ($r.error.code -eq 'ARCHIVE_UNVERIFIED' -and (Test-Path -LiteralPath $tn) -and $r.data.errorListError -eq 'ERRORLIST_UNAVAILABLE') (J $r.error)

    # ===== S4: the same stale text once before, twice after -> one new row (count difference)
    Reset-Mock; $global:A.Mode = 'scope-error'; $global:A.Rows = @((New-Row $scopeRow))
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S4): same row once before, twice after -> ARCHIVE_INCOMPLETE with one new row' ($r.error.code -eq 'ARCHIVE_INCOMPLETE' -and @($r.data.errorItems).Count -eq 1) (J $r.data.errorItems)

    # ===== S3: truncated / unclassified rows
    Reset-Mock; $global:A.Mode = 'truncate'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S3): Error List truncated after the call -> ARCHIVE_UNVERIFIED, file kept' ($r.error.code -eq 'ARCHIVE_UNVERIFIED' -and $r.data.errorListTruncated -and (Test-Path -LiteralPath $tn)) (J $r.error)
    Reset-Mock; $global:A.Mode = 'other-unclassified'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S3): unclassified row without the archive text -> ARCHIVE_UNVERIFIED, data.unclassified' ($r.error.code -eq 'ARCHIVE_UNVERIFIED' -and @($r.data.unclassified).Count -eq 1) (J $r.data)
    Reset-Mock; $global:A.Mode = 'scope-unclassified'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S3): unclassified "Error creating Archive" row -> ARCHIVE_INCOMPLETE' ($r.error.code -eq 'ARCHIVE_INCOMPLETE' -and @($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].description -match 'Error creating Archive') (J $r.data.errorItems)
    Reset-Mock; $global:A.Unclassified = @((New-Row $scopeRow)); $global:A.Mode = 'scope-unclassified'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S3/S4): stale unclassified archive row once before, twice after -> one new row, INCOMPLETE' ($r.error.code -eq 'ARCHIVE_INCOMPLETE' -and @($r.data.errorItems).Count -eq 1) (J $r.data.errorItems)
    Reset-Mock; $global:A.Mode = 'ok'
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive (S3): nothing truncated, no unclassified -> success' ($r.success) (J $r.error)

    # ===== N6
    & $mod { function script:Assert-TcConnection { throw 'Not connected to TwinCAT IDE (mock)' } }
    $r = Save-TcArchive -FilePath (Join-Path $Root 'nc.tnzip')
    $r2 = Save-TcPlcLibrary -FilePath (Join-Path $Root 'nc.library')
    & $mod { function script:Assert-TcConnection { } }
    Check 'NOT_CONNECTED carries the Connect-TcIde hint (archive, library)' ($r.error.code -eq 'NOT_CONNECTED' -and $r.error.hint -match 'Connect-TcIde' -and $r2.error.hint -match 'Connect-TcIde') (J $r.error)

    # ===== entries truncated at 200
    Reset-Mock; $global:A.Entries = 250
    $r = Save-TcArchive -FilePath $tn
    Check 'Archive with 250 entries -> 200 listed, entriesTruncated, entryCount 250, note' ($r.success -and @($r.data.entries).Count -eq 200 -and $r.data.entriesTruncated -and $r.data.entryCount -eq 250 -and $r.data.entriesNote -match '200 of 250') "$($r.data.entryCount) $($r.data.entriesTruncated) $($r.data.entriesNote)"

    # ===== failures and restore
    Reset-Mock
    [System.IO.File]::WriteAllText($tn, 'previous archive')
    $global:A.Mode = 'garbage'
    $r = Save-TcArchive -FilePath $tn -Overwrite
    Check 'Archive -Overwrite, output not a ZIP -> ARCHIVE_FAILED not-a-zip, previous file back, new one .failed' ($r.error.code -eq 'ARCHIVE_FAILED' -and $r.data.reason -eq 'not-a-zip' -and ([System.IO.File]::ReadAllText($tn)) -eq 'previous archive' -and $r.data.restore.failedFile -eq "$tn.failed") (J $r.data)
    $global:A.Mode = 'throw'
    $r = Save-TcArchive -FilePath $tn -Overwrite
    Check 'Archive -Overwrite, XAE throws -> ARCHIVE_FAILED save-failed, previous file back' ($r.error.code -eq 'ARCHIVE_FAILED' -and $r.data.reason -eq 'save-failed' -and $r.data.hresult -eq '0x80070057' -and ([System.IO.File]::ReadAllText($tn)) -eq 'previous archive') (J $r.data)
    $global:A.Mode = 'nowrite'
    $r = Save-TcArchive -FilePath (Join-Path $Root 'None.tnzip')
    Check 'Archive: returns but no file -> ARCHIVE_FAILED not-written' ($r.error.code -eq 'ARCHIVE_FAILED' -and $r.data.reason -eq 'not-written') (J $r.error)
    Reset-Mock; $global:A.Dialog = $dialog
    $r = Save-TcArchive -FilePath (Join-Path $Root 'D.tnzip')
    Check 'Archive: modal dialog -> IDE_MODAL_DIALOG, nothing called' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:A.Calls.Count -eq 0) (J $r.error)

    # ===== Get-TcZipEntryList on a non-zip
    $z = & $mod { param($p) Get-TcZipEntryList -Path $p } $Sln
    Check 'Get-TcZipEntryList: a non-ZIP file gives Error, no throw' ($null -ne $z.Error -and $z.Count -eq 0) (J $z)

    # ===== hints / tools.json
    $codes = @('LIBRARY_SAVE_FILE_EXISTS', 'LIBRARY_SAVE_FAILED', 'ARCHIVE_FILE_EXISTS', 'ARCHIVE_FAILED', 'ARCHIVE_INCOMPLETE', 'ARCHIVE_UNVERIFIED')
    $missing = @($codes | Where-Object { [string]::IsNullOrWhiteSpace((& $mod { param($c) Get-TcErrorHint -Code $c } $_)) })
    Check 'hints exist for the new LIBRARY_SAVE_* / ARCHIVE_* codes' ($missing.Count -eq 0) ($missing -join ',')
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($t in $tools) { $byName[$t.name] = $t }
    $t = $byName['SaveAsLibrary']
    Check 'tools.json SaveAsLibrary: Save-TcPlcLibrary, not destructive, FilePath required, no Install / Encrypt parameter' ($null -ne $t -and $t.cmdlet -eq 'Save-TcPlcLibrary' -and $t.annotations.destructiveHint -eq $false -and @($t.inputSchema.required) -contains 'FilePath' -and $null -eq $t.inputSchema.properties.PSObject.Properties['Install'] -and $null -eq $t.inputSchema.properties.PSObject.Properties['Encrypt']) (J $t.inputSchema)
    $t = $byName['SaveArchive']
    Check 'tools.json SaveArchive: Save-TcArchive, Kind Solution|Configuration default Solution' ($null -ne $t -and $t.cmdlet -eq 'Save-TcArchive' -and $t.annotations.destructiveHint -eq $false -and $t.inputSchema.properties.Kind.default -eq 'Solution' -and (@($t.inputSchema.properties.Kind.enum) -join ',') -eq 'Solution,Configuration') (J $t.inputSchema)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null; $script:TcDte = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
