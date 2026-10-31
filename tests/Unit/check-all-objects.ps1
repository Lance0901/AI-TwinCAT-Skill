# Unit: task 3.7 (complete-automation-interface phase 2): Test-TcPlcProject (MCP CheckAllObjects) and
# the Error List summary it shares with Build-TcProject (Get-TcErrorListSummary).
# No IDE / runtime: a mock '<Plc> Project' node whose CheckAllObjects() returns what XAE returned in the
# probe (verification/phase2-probe.md 3.7: True, or False without an exception), and a mocked
# Get-TcBuildErrors that returns Error List rows.
#   powershell.exe -NoProfile -File tests/Unit/check-all-objects.ps1
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

$PrjPath = 'TIPC^plc^plc Project'
$global:C = @{}
function New-Row($code, $desc, $file, $line) {
    [PSCustomObject]@{ severity = 'Error'; code = $code; description = $desc; project = 'plc'; file = $file; line = $line; column = 0 }
}
# rows as the probe saw them (phase2-probe.md 3.7)
$rowSyntax = { New-Row 'C0007' "Expression expected instead of ';'" 'FB_P2Probe.TcPOU@M_Two (Impl)' 1 }
$rowTask = { New-Row 'C0046' "Identifier 'NoSuchProg' not defined" 'PlcTask.TcTTO' 0 }
$rowStale = { New-Row '' "'TwinCAT Measurement' (Scope): Error creating Archive" '' $null }
$rowLib = { New-Row '' "Library 'Tc3_Foo' 1.0.0.0 has not been installed" 'plc.Library Manager' 0 }
# a compiler code without a file: category other, but not stale (it has a code)
$rowCodeNoFile = { New-Row 'C0077' 'Unknown type: FB_Gone' '' $null }
$warnRow = [PSCustomObject]@{ severity = 'Warning'; code = 'C0373'; description = 'unused variable'; project = 'plc'; file = 'MAIN.TcPOU'; line = 3; column = 0 }

function Reset-Mock {
    $global:C.Mode = 'true'; $global:C.Dialog = $null; $global:C.Calls = 0; $global:C.ElCalls = [System.Collections.ArrayList]::new()
    $global:C.Rows = @(); $global:C.Warnings = @($warnRow); $global:C.ElFails = $false
    $global:C.NoMethod = $false
}
function New-PrjNode {
    $n = [PSCustomObject]@{ Name = 'plc Project'; PathName = $PrjPath; ItemType = 600 }
    $n | Add-Member ScriptMethod CheckAllObjects {
        $global:C.Calls++
        switch ($global:C.Mode) {
            'true' { return $true }
            'false' { return $false }
            'throw' { throw [System.Runtime.InteropServices.COMException]::new('Error_CheckAllObjectsFailed', -2147467259) }
        }
    }
    $n
}
$global:C.Prj = New-PrjNode
$global:C.PrjNoMethod = [PSCustomObject]@{ Name = 'plc Project'; PathName = $PrjPath; ItemType = 600 }
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if ($p -ne 'TIPC^plc^plc Project') { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
    if ($global:C.NoMethod) { return , $global:C.PrjNoMethod }
    Write-Output -NoEnumerate $global:C.Prj
}
$global:C.Sm = $sm

& $mod {
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = 'C:\mock\Check.sln'
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:C.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:C.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    function script:Get-TcBuildErrors {
        [CmdletBinding()] param([int]$TimeoutSec = 30, [switch]$IncludeWarnings, [switch]$IncludeMessages)
        $null = $global:C.ElCalls.Add("$TimeoutSec|$IncludeWarnings")
        if ($global:C.ElFails) { return [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'ERRORLIST_UNAVAILABLE'; message = 'Error List window not found (mock)' } } }
        # fresh objects each read (Get-TcErrorListSummary adds 'category' to them)
        $errs = @($global:C.Rows | ForEach-Object { & $_ })
        [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ counts = [PSCustomObject]@{ errors = $errs.Count; warnings = @($global:C.Warnings).Count; messages = 0 }; errors = $errs; warnings = @($global:C.Warnings) } }
    }
}
function Get-BuildRequiredReason { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; [string]$e.reason } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }

try {
    # ===== True: success, errorItems empty, warnings returned, Error List still read
    Reset-Mock; Reset-BuildRequired
    $r = Test-TcPlcProject
    Check 'True -> success, passed true' ($r.success -and $r.data.passed -eq $true -and $global:C.Calls -eq 1) (J $r)
    Check 'True -> errorItems is an empty array' ($null -ne $r.data.PSObject.Properties['errorItems'] -and @($r.data.errorItems).Count -eq 0 -and @($r.data.codeErrors).Count -eq 0) (J $r.data)
    Check 'True -> Error List read anyway (short timeout), warnings returned' ($global:C.ElCalls.Count -eq 1 -and $global:C.ElCalls[0] -eq '8|True' -and @($r.data.warningItems).Count -eq 1 -and $r.data.warnings -eq 1 -and @($r.data.codeWarnings).Count -eq 1) "$($global:C.ElCalls -join ';') $(J $r.data.warningItems)"
    Check 'True -> plcProjectPath, checkSec' ($r.data.plcProjectPath -eq $PrjPath -and $null -ne $r.data.checkSec) (J $r.data)

    Reset-Mock; $global:C.Rows = @($rowStale)
    $r = Test-TcPlcProject
    Check 'True with a leftover row -> success, row in staleErrorItems + warning' ($r.success -and @($r.data.errorItems).Count -eq 0 -and @($r.data.staleErrorItems).Count -eq 1 -and @($r.data.warningTexts).Count -eq 1) (J $r.data)

    # ===== False: CHECK_FAILED with the error rows
    Reset-Mock; $global:C.Mode = 'false'; $global:C.Rows = @($rowSyntax, $rowStale)
    $r = Test-TcPlcProject
    Check 'False -> CHECK_FAILED, passed false' ((-not $r.success) -and $r.error.code -eq 'CHECK_FAILED' -and $r.data.passed -eq $false) (J $r.error)
    Check 'False -> errorItems has the located row, the stale row is separate' (@($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].code -eq 'C0007' -and @($r.data.staleErrorItems).Count -eq 1 -and $r.data.errors -eq 1) (J $r.data)
    Check 'False -> message names the error, hint names the next cmdlet' ($r.error.message -match 'C0007' -and $r.error.message -match 'FB_P2Probe' -and $r.error.hint -match 'Test-TcPlcProject') "$($r.error.message) | $($r.error.hint)"
    Check 'False -> Error List read with the default timeout' ($global:C.ElCalls[0] -eq '0|True' -or $global:C.ElCalls[0] -eq '30|True') ($global:C.ElCalls -join ';')

    Reset-Mock; $global:C.Mode = 'false'; $global:C.Rows = @($rowTask, $rowLib)
    $r = Test-TcPlcProject
    Check 'False with a task row (line 0) and a library row -> both in errorItems, split into codeErrors / libraryErrorItems' ($r.error.code -eq 'CHECK_FAILED' -and @($r.data.errorItems).Count -eq 2 -and @($r.data.codeErrors).Count -eq 1 -and @($r.data.libraryErrorItems).Count -eq 1) (J $r.data)

    Reset-Mock; $global:C.Mode = 'false'; $global:C.Rows = @($rowCodeNoFile, $rowStale)
    $r = Test-TcPlcProject
    Check 'False: a row with a code but no file stays in errorItems; only the no-file no-code row is stale' (@($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].code -eq 'C0077' -and $r.data.errorItems[0].category -eq 'other' -and @($r.data.staleErrorItems).Count -eq 1 -and [string]::IsNullOrEmpty($r.data.staleErrorItems[0].code) -and $r.error.message -match 'C0077') (J $r.data)

    # ===== errorItems: the same shape and category rule as Build-TcProject (Get-TcErrorListSummary)
    Reset-Mock; $global:C.Mode = 'false'; $global:C.Rows = @($rowSyntax, $rowTask, $rowLib)
    $r = Test-TcPlcProject
    $s = & $mod { Get-TcErrorListSummary }
    $want = @('severity', 'code', 'description', 'project', 'file', 'line', 'column', 'category')
    $shapeOk = $true
    foreach ($it in @($r.data.errorItems)) { if ((Compare-Object $want @($it.PSObject.Properties.Name)).Count -ne 0) { $shapeOk = $false } }
    Check 'errorItems fields = Build errorItems fields (incl. category)' $shapeOk (J $r.data.errorItems)
    $catCheck = (J @($r.data.errorItems | ForEach-Object { "$($_.code)/$($_.category)" })) -eq (J @($s.errorItems | ForEach-Object { "$($_.code)/$($_.category)" }))
    Check 'categories equal the shared summary that Build-TcProject uses' $catCheck "$(J @($r.data.errorItems | ForEach-Object { $_.category })) vs $(J @($s.errorItems | ForEach-Object { $_.category }))"
    $catRule = @($s.errorItems | Where-Object { $_.category -ne (& $mod { param($i) Get-TcErrorItemCategory -Item $i } $_) }).Count -eq 0
    Check 'summary categories follow Get-TcErrorItemCategory' $catRule (J $s.errorItems)
    Check 'summary counts: code 2, library 1, errorCount 2' (@($s.codeErrors).Count -eq 2 -and @($s.libraryErrorItems).Count -eq 1 -and $s.errorCount -eq 2 -and $s.libraryErrorCount -eq 1) (J $s)
    $global:C.ElFails = $true
    $s = & $mod { Get-TcErrorListSummary -FallbackErrorCount 3 -FallbackWarningCount 2 }
    Check 'summary: unreadable Error List -> fallback counts, errorListError, libraryErrorCount null' ($s.errorListError -eq 'ERRORLIST_UNAVAILABLE' -and $s.errorCount -eq 3 -and $s.warningCount -eq 2 -and $null -eq $s.libraryErrorCount -and @($s.errorItems).Count -eq 0) (J $s)

    # ===== Error List not readable: the return value still decides
    Reset-Mock; $global:C.ElFails = $true
    $r = Test-TcPlcProject
    Check 'True + Error List unreadable -> success with errorListError + warning' ($r.success -and $r.data.errorListError -eq 'ERRORLIST_UNAVAILABLE' -and @($r.data.warningTexts).Count -eq 1) (J $r.data)
    Reset-Mock; $global:C.Mode = 'false'; $global:C.ElFails = $true
    $r = Test-TcPlcProject
    Check 'False + Error List unreadable -> CHECK_FAILED, message says so' ($r.error.code -eq 'CHECK_FAILED' -and $r.error.message -match 'could not be read' -and $null -eq $r.data.errors) (J $r)

    # ===== BUILD_REQUIRED is never changed
    Reset-Mock; Reset-BuildRequired
    $null = & $mod { Register-TcCodeChange -Result $null -Change 'Write-TcPouCode MAIN [implementation]' }
    $before = Get-BuildRequiredReason
    $r = Test-TcPlcProject
    $after = Get-BuildRequiredReason
    Check 'True does not clear BUILD_REQUIRED' ($r.success -and $null -ne $before -and $before -eq $after) "$before | $after"
    Reset-Mock; Reset-BuildRequired
    $global:C.Mode = 'false'; $global:C.Rows = @($rowSyntax)
    $r = Test-TcPlcProject
    Check 'False records nothing (no BUILD_REQUIRED, no data.buildRequired)' ($null -eq (Get-BuildRequiredReason) -and $null -eq $r.data.PSObject.Properties['buildRequired']) (J $r.data)
    $global:C.Mode = 'true'; $global:C.Rows = @()
    $r = Test-TcPlcProject
    Check 'True records nothing either' ($r.success -and $null -eq (Get-BuildRequiredReason) -and $null -eq $r.data.PSObject.Properties['buildRequired']) (J $r.data)

    # ===== modal dialog: nothing called
    Reset-Mock; $global:C.Dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }
    $r = Test-TcPlcProject
    Check 'modal dialog -> IDE_MODAL_DIALOG, CheckAllObjects not called' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $global:C.Calls -eq 0) (J $r.error)

    # ===== exception / method missing
    Reset-Mock; $global:C.Mode = 'throw'
    $r = Test-TcPlcProject
    Check 'exception -> CHECK_FAILED, passed null, callError' ($r.error.code -eq 'CHECK_FAILED' -and $null -eq $r.data.passed -and $r.data.callError -match 'Error_CheckAllObjectsFailed') (J $r)
    Reset-Mock; $global:C.NoMethod = $true
    $r = Test-TcPlcProject
    Check 'no CheckAllObjects method -> CHECK_UNAVAILABLE (decided by MethodNotFound, any UI language)' ($r.error.code -eq 'CHECK_UNAVAILABLE' -and $r.error.hint -match 'Build-TcProject') "$(J $r.error) uiCulture=$([System.Threading.Thread]::CurrentThread.CurrentUICulture.Name)"

    # ===== PLC project resolution
    Reset-Mock
    $r = Test-TcPlcProject -PlcProjectPath 'nosuchplc'
    Check 'unknown -PlcProjectPath -> PLC_PROJECT_NOT_FOUND, nothing called' ($r.error.code -eq 'PLC_PROJECT_NOT_FOUND' -and $global:C.Calls -eq 0) (J $r.error)
    $r = Test-TcPlcProject -PlcProjectPath 'plc'
    Check '-PlcProjectPath by PLC name' ($r.success -and $r.data.plcProjectPath -eq $PrjPath) (J $r.data)

    # ===== hint table / tools.json
    $hints = & $mod { @{ f = (Get-TcErrorHint -Code 'CHECK_FAILED'); u = (Get-TcErrorHint -Code 'CHECK_UNAVAILABLE') } }
    Check 'hints exist for CHECK_FAILED / CHECK_UNAVAILABLE' (-not [string]::IsNullOrWhiteSpace($hints.f) -and -not [string]::IsNullOrWhiteSpace($hints.u)) (J $hints)
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $t = @($tools | Where-Object { $_.name -eq 'CheckAllObjects' })[0]
    Check 'tools.json CheckAllObjects: Test-TcPlcProject, readOnly' ($null -ne $t -and $t.cmdlet -eq 'Test-TcPlcProject' -and $t.annotations.readOnlyHint -eq $true -and $null -ne $t.inputSchema.properties.PlcProjectPath) (J $t.annotations)
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
