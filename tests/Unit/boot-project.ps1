# Unit: task 3.2 (complete-automation-interface phase 2): New-TcBootProject (MCP GenerateBootProject).
# No IDE / runtime: a mock PLC root 'TIPC^plc' whose GenerateBootProject($false) writes the boot files the
# probe saw (verification/phase2-probe.md 3.2: _Boot\<platform>\Plc\Port_851.app ... and _boot.tizip), or
# throws E_FAIL with a meaningless message as on a compile error; a mocked Get-TcBuildErrors returns the
# Error List rows. A temp solution folder holds the _Boot folder.
#   powershell.exe -NoProfile -File tests/Unit/boot-project.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 6 -Compress }

$Root = Join-Path $env:TEMP ("tcauto-unit-boot-{0}" -f [guid]::NewGuid().ToString('N'))
$TsDir = Join-Path $Root 'Boot'
$Platform = 'TwinCAT OS (x64)'
$BootDir = Join-Path $TsDir "_Boot\$Platform\Plc"
$null = New-Item -ItemType Directory -Path $BootDir -Force
$Sln = Join-Path $Root 'Boot.sln'
[System.IO.File]::WriteAllText($Sln, '')
$global:Tsproj = Join-Path $TsDir 'Boot.tsproj'
[System.IO.File]::WriteAllText($global:Tsproj, '<TcSmProject />')
$global:BootDir = $BootDir
# the module reports long path names (TEMP may be spelled with 8.3 short names, e.g. RUNNER~1 on CI)
$BootDirLong = & $mod { param($p) Get-TcLongPath $p } $BootDir

$global:B = @{}
function Reset-Mock {
    Get-ChildItem -LiteralPath $BootDir -File | Remove-Item -Force
    # an older boot project from an earlier run
    foreach ($n in 'Port_851.app', 'Port_851.crc', 'Port_852.app') {
        $p = Join-Path $BootDir $n
        [System.IO.File]::WriteAllText($p, 'old')
        (Get-Item -LiteralPath $p).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)
    }
    $global:B.Mode = 'ok'; $global:B.Calls = [System.Collections.ArrayList]::new(); $global:B.Dialog = $null
    $global:B.Platform = 'TwinCAT OS (x64)'; $global:B.TsprojThrows = $false; $global:B.NoMethod = $false
    $global:B.Rows = @(); $global:B.Unclassified = @(); $global:B.ProjectPlatform = $null; $global:B.AdsPort = 851; $global:B.TsprojEmpty = $false
}
function New-Row($code, $desc, $file, $line) {
    [PSCustomObject]@{ severity = 'Error'; code = $code; description = $desc; project = 'plc'; file = $file; line = $line; column = 0 }
}
$rootNode = [PSCustomObject]@{ Name = 'plc'; PathName = 'TIPC^plc'; ItemType = 56 }
$rootNode | Add-Member ScriptMethod GenerateBootProject {
    param($activate)
    $global:B.Calls.Add("TIPC^plc|$activate") | Out-Null
    switch ($global:B.Mode) {
        'compile' { throw [System.Runtime.InteropServices.COMException]::new('value out of range (mock, localized and meaningless)', -2147467259) }
        'nowrite' { return }
        'autostart-only' { [System.IO.File]::WriteAllText((Join-Path $global:BootDir 'Port_851.autostart'), 'new'); return }
        'project-platform' {
            $d = Join-Path (Split-Path -Parent (Split-Path -Parent $global:BootDir)) "$($global:B.ProjectPlatform)\Plc"
            $null = New-Item -ItemType Directory -Path $d -Force
            foreach ($n in 'Port_851.app', 'Port_851.crc') { [System.IO.File]::WriteAllText((Join-Path $d $n), "new $n") }
            return
        }
    }
    foreach ($n in 'Port_851.app', 'Port_851.autostart', 'Port_851.crc', 'Port_851_boot.tizip') { [System.IO.File]::WriteAllText((Join-Path $global:BootDir $n), "new $n") }
}
$global:B.Root = $rootNode
$global:B.RootNoMethod = [PSCustomObject]@{ Name = 'plc'; PathName = 'TIPC^plc'; ItemType = 56 }
$global:B.Prj = [PSCustomObject]@{ Name = 'plc Project'; PathName = 'TIPC^plc^plc Project'; ItemType = 600 }
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if ($p -eq 'TIPC^plc') { if ($global:B.NoMethod) { return , $global:B.RootNoMethod }; return , $global:B.Root }
    if ($p -eq 'TIPC^plc^plc Project') { return , $global:B.Prj }
    throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001)
}
$global:B.Sm = $sm

& $mod {
    param($s)
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = $s
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:B.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:B.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = $global:B.AdsPort }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    function script:Get-TcSolutionPlatform { [CmdletBinding()] param() [PSCustomObject]@{ platform = $global:B.Platform; configuration = 'Release'; projectPlatform = $global:B.ProjectPlatform; platformSource = 'ActiveConfig' } }
    function script:Get-TcPlcProjectFile {
        [CmdletBinding()] param([string]$PlcName)
        if ($global:B.TsprojThrows) { throw "save: locate: no .tsproj of the open solution lists PLC '$PlcName' (mock)" }
        if ($global:B.TsprojEmpty) { return @{ TsProjFile = ''; PlcProjFile = 'x.plcproj' } }
        @{ TsProjFile = $global:Tsproj; PlcProjFile = 'x.plcproj' }
    }
    function script:Get-TcBuildErrors {
        [CmdletBinding()] param([int]$TimeoutSec = 30, [switch]$IncludeWarnings, [switch]$IncludeMessages)
        $errs = @($global:B.Rows | ForEach-Object { & $_ })
        $d = [PSCustomObject]@{ counts = [PSCustomObject]@{ errors = $errs.Count; warnings = 0; messages = 0 }; errors = $errs; warnings = @(); truncated = $false }
        if (@($global:B.Unclassified).Count -gt 0) { $d | Add-Member -NotePropertyName unclassified -NotePropertyValue @($global:B.Unclassified) }
        [PSCustomObject]@{ success = $true; data = $d }
    }
} $Sln
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
$dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }

try {
    # ===== CI: the solution folder spelled with 8.3 short names (TEMP = C:\Users\RUNNER~1\... on GitHub)
    $shortTs = $null
    try { $shortTs = (New-Object -ComObject Scripting.FileSystemObject).GetFile($global:Tsproj).ShortPath } catch { $shortTs = $null }
    if ($shortTs -and $shortTs -ne $global:Tsproj) {
        Reset-Mock; Reset-BuildRequired
        $saveTs = $global:Tsproj; $global:Tsproj = $shortTs
        $r = New-TcBootProject
        $global:Tsproj = $saveTs
        Check 'Boot: .tsproj given with 8.3 short names -> the updated Port_851.app is found, success, long paths reported' ($r.success -and $r.data.bootDir -eq $BootDirLong -and @($r.data.bootFiles | Where-Object { $_.path -eq (Join-Path $BootDirLong 'Port_851.app') -and $_.updated }).Count -eq 1) (J $r)
    }
    else { Check 'Boot: 8.3 short names not available on this volume (check skipped)' $true "$shortTs" }

    # ===== success
    Reset-Mock; Reset-BuildRequired
    & $mod { $null = Register-TcCodeChange -Result $null -Change 'Write-TcPouCode MAIN (earlier)' }
    $r = New-TcBootProject
    $app = @($r.data.bootFiles | Where-Object { $_.path -like '*\Port_851.app' })[0]
    Check 'Boot: called once on the PLC root with bActivate false' ($r.success -and $global:B.Calls.Count -eq 1 -and $global:B.Calls[0] -eq 'TIPC^plc|False') (J $global:B.Calls)
    Check 'Boot: boot folder <tsproj dir>\_Boot\<platform>\Plc, Port_851.app updated, Port_852 not listed' ($r.data.bootDirDerived -and $r.data.bootDir -eq $BootDirLong -and $app.updated -and $app.size -gt 0 -and @($r.data.bootFiles | Where-Object { $_.path -like '*Port_852*' }).Count -eq 0 -and @($r.data.bootFiles | Where-Object { $_.path -like '*Port_851_boot.tizip' -and $_.updated }).Count -eq 1) (J $r.data.bootFiles)
    Check 'Boot: data.warnings says it saves the project' (@($r.data.warnings | Where-Object { $_ -match 'saves the project' }).Count -eq 1) (J $r.data.warnings)
    Check 'Boot: BUILD_REQUIRED unchanged (the earlier reason stays, nothing new recorded)' ((Get-CodeChanged) -match 'Write-TcPouCode MAIN \(earlier\)' -and (Get-CodeChanged) -notmatch 'Boot' -and $null -eq $r.data.PSObject.Properties['buildRequired']) "$(Get-CodeChanged)"
    Reset-BuildRequired
    $r = New-TcBootProject
    Check 'Boot: no BUILD_REQUIRED recorded on a clean state' ($r.success -and $null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"

    # ===== readback: not updated
    Reset-Mock; $global:B.Mode = 'nowrite'
    $r = New-TcBootProject
    Check 'Boot: returns but Port_851.app is old -> BOOTPROJECT_VERIFY_FAILED not-updated' ($r.error.code -eq 'BOOTPROJECT_VERIFY_FAILED' -and $r.data.reason -eq 'not-updated' -and @($r.data.bootFiles | Where-Object { $_.path -like '*Port_851.app' -and -not $_.updated }).Count -eq 1) (J $r)

    # ===== compile error -> Error List
    Reset-Mock; $global:B.Mode = 'compile'
    $global:B.Rows = @({ New-Row 'C0046' "Identifier 'NoSuchProg' not defined" 'PlcTask.TcTTO' 0 }, { New-Row '' "'TwinCAT Measurement' (Scope): Error creating Archive" '' $null })
    $r = New-TcBootProject
    Check 'Boot: E_FAIL -> BOOTPROJECT_FAILED generate-failed with the Error List rows' ($r.error.code -eq 'BOOTPROJECT_FAILED' -and $r.data.reason -eq 'generate-failed' -and $r.data.hresult -eq '0x80004005' -and @($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].code -eq 'C0046' -and @($r.data.codeErrors).Count -eq 1) (J $r.data)
    Check 'Boot: stale rows (no file, no code) are separated, message lists the located error' (@($r.data.staleErrorItems).Count -eq 1 -and $r.error.message -match 'C0046' -and $r.error.message -match 'PlcTask\.TcTTO' -and $r.error.message -notmatch 'Error creating Archive') "$($r.error.message)"
    Check 'Boot: failure keeps the save warning (the project may be saved anyway)' (@($r.data.warnings | Where-Object { $_ -match 'saves the project' }).Count -eq 1) (J $r.data.warnings)
    $global:B.Rows = @()
    $r = New-TcBootProject
    Check 'Boot: E_FAIL and no error row -> BOOTPROJECT_FAILED, message says no row' ($r.error.code -eq 'BOOTPROJECT_FAILED' -and @($r.data.errorItems).Count -eq 0 -and $r.error.message -match 'no error row') "$($r.error.message)"

    # ===== no method / dialog
    Reset-Mock; $global:B.NoMethod = $true
    $r = New-TcBootProject
    Check 'Boot: PLC root without GenerateBootProject -> BOOTPROJECT_FAILED no-method (by error id)' ($r.error.code -eq 'BOOTPROJECT_FAILED' -and $r.data.reason -eq 'no-method') (J $r)
    Reset-Mock; $global:B.Dialog = $dialog
    $r = New-TcBootProject
    Check 'Boot: modal dialog -> IDE_MODAL_DIALOG, not called, no save warning' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:B.Calls.Count -eq 0 -and $null -eq $r.data.PSObject.Properties['warnings']) (J $r.data)

    # ===== boot folder cannot be derived -> search below the solution folder
    Reset-Mock; $global:B.Platform = $null
    $r = New-TcBootProject
    Check 'Boot: platform unknown -> files found below the solution folder, success with a warning' ($r.success -and -not $r.data.bootDirDerived -and @($r.data.bootFiles | Where-Object { $_.path -like '*Port_851.app' -and $_.updated }).Count -eq 1 -and @($r.data.warnings | Where-Object { $_ -match 'could not be derived' -and $_ -match 'solution platform is not known' }).Count -eq 1) (J $r.data)
    Reset-Mock; $global:B.TsprojThrows = $true; $global:B.Mode = 'nowrite'
    $r = New-TcBootProject
    Check 'Boot: .tsproj unknown and nothing newer -> BOOTPROJECT_VERIFY_FAILED boot-dir-unknown' ($r.error.code -eq 'BOOTPROJECT_VERIFY_FAILED' -and $r.data.reason -eq 'boot-dir-unknown' -and $r.error.message -match '\.tsproj') (J $r.error)

    # ===== S1: solution platform and project platform differ -> both folders are looked at
    Reset-Mock; $global:B.ProjectPlatform = 'TwinCAT RT (x64)'; $global:B.Mode = 'project-platform'
    $r = New-TcBootProject
    Check 'Boot (S1): .app written in the project platform folder -> success, data.bootDirs has both folders' ($r.success -and @($r.data.bootDirs).Count -eq 2 -and @($r.data.bootDirs)[1] -like '*\_Boot\TwinCAT RT (x64)\Plc' -and @($r.data.bootFiles | Where-Object { $_.path -like '*TwinCAT RT (x64)\Plc\Port_851.app' -and $_.updated }).Count -eq 1 -and $r.data.projectPlatform -eq 'TwinCAT RT (x64)') (J $r.data)
    Reset-Mock; $global:B.ProjectPlatform = 'TwinCAT OS (x64)'
    $r = New-TcBootProject
    Check 'Boot (S1): same project platform -> one folder' ($r.success -and @($r.data.bootDirs).Count -eq 1) (J $r.data.bootDirs)

    # ===== S2: the fallback needs an updated Port_*.app
    Reset-Mock; $global:B.Platform = $null; $global:B.Mode = 'autostart-only'
    $r = New-TcBootProject
    Check 'Boot (S2): fallback, only .autostart newer -> BOOTPROJECT_VERIFY_FAILED boot-dir-unknown' ($r.error.code -eq 'BOOTPROJECT_VERIFY_FAILED' -and $r.data.reason -eq 'boot-dir-unknown' -and @($r.data.bootFiles | Where-Object { $_.path -like '*Port_851.autostart' -and $_.updated }).Count -eq 1) (J $r)
    Reset-Mock; $global:B.Mode = 'autostart-only'
    $r = New-TcBootProject
    Check 'Boot (S2): derived folder, only .autostart newer -> not-updated' ($r.error.code -eq 'BOOTPROJECT_VERIFY_FAILED' -and $r.data.reason -eq 'not-updated') (J $r.error)
    Reset-Mock; $global:B.AdsPort = $null
    $r = New-TcBootProject
    Check 'Boot (S2): ADS port unknown -> fallback, data.bootPorts lists 851 (the updated .app)' ($r.success -and -not $r.data.bootDirDerived -and (@($r.data.bootPorts) -join ',') -eq '851') (J $r.data)

    # ===== S6: rows of unknown severity on a failure
    Reset-Mock; $global:B.Mode = 'compile'
    $global:B.Unclassified = @([PSCustomObject]@{ severity = $null; code = 'C0046'; description = "Identifier 'X' not defined"; project = 'plc'; file = 'MAIN.TcPOU'; line = 3; column = 0 })
    $r = New-TcBootProject
    Check 'Boot (S6): no error row but unclassified rows -> data.unclassified, message names them' ($r.error.code -eq 'BOOTPROJECT_FAILED' -and @($r.data.unclassified).Count -eq 1 -and $r.error.message -match 'unknown severity' -and $r.error.message -match "Identifier 'X'") "$($r.error.message)"

    # ===== N7: an empty .tsproj path gives a reason
    Reset-Mock; $global:B.TsprojEmpty = $true
    $r = New-TcBootProject
    Check 'Boot (N7): empty TsProjFile -> fallback with a reason in the warning' ($r.success -and -not $r.data.bootDirDerived -and @($r.data.warnings | Where-Object { $_ -match 'returned no \.tsproj path' }).Count -eq 1) (J $r.data.warnings)

    # ===== Compare-TcBootFileSet
    $t0 = (Get-Date).ToUniversalTime().AddMinutes(-5); $t1 = (Get-Date).ToUniversalTime()
    $cmp = & $mod {
        param($t0, $t1)
        $before = @{ 'a' = [PSCustomObject]@{ exists = $true; size = 1; lastWriteTimeUtc = $t0; lastWriteTime = 'x' }; 'gone' = [PSCustomObject]@{ exists = $true; size = 1; lastWriteTimeUtc = $t0; lastWriteTime = 'x' } }
        $after = @{ 'a' = [PSCustomObject]@{ exists = $true; size = 2; lastWriteTimeUtc = $t0; lastWriteTime = 'x' }; 'new' = [PSCustomObject]@{ exists = $true; size = 3; lastWriteTimeUtc = $t1; lastWriteTime = 'y' } }
        Compare-TcBootFileSet -Before $before -After $after
    } $t0 $t1
    $byPath = @{}; foreach ($c in $cmp) { $byPath[$c.path] = $c }
    Check 'Compare-TcBootFileSet: same time = not updated, new file = updated, removed file listed' (-not $byPath['a'].updated -and $byPath['new'].updated -and $null -eq $byPath['gone'].size -and -not $byPath['gone'].updated) (J $cmp)

    # ===== hints / tools.json
    $codes = @('BOOTPROJECT_FAILED', 'BOOTPROJECT_VERIFY_FAILED')
    $missing = @($codes | Where-Object { [string]::IsNullOrWhiteSpace((& $mod { param($c) Get-TcErrorHint -Code $c } $_)) })
    Check 'hints exist for the BOOTPROJECT_* codes' ($missing.Count -eq 0) ($missing -join ',')
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $t = @($tools | Where-Object { $_.name -eq 'GenerateBootProject' })[0]
    Check 'tools.json GenerateBootProject: New-TcBootProject, 600 s, not destructive, no Activate parameter' ($null -ne $t -and $t.cmdlet -eq 'New-TcBootProject' -and $t.timeoutMs -eq 600000 -and $t.annotations.destructiveHint -eq $false -and $null -eq $t.inputSchema.properties.PSObject.Properties['Activate'] -and $t.description -match 'SAVES the project') (J $t)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
