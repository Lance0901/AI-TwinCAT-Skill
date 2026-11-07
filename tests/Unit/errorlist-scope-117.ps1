# Unit: Error List scope and readback (#117) and the Build-TcProject Error List budget (#107),
# no IDE / runtime needed.
#   A  scope detection of the real scan scriptblock ($script:TcUiaErrorListScan), its functions
#      Get-ScopeKind / Get-ComboSelectionName / Find-ScopeCombo extracted from the AST and run on a
#      MOCK UIA tree (PSCustomObjects with Current / FindAll / TryGetCurrentPattern):
#      A1 collapsed scope combo (no ListItem descendants) selected '目前專案' -> found, partial
#      A2 selection '整個方案' / 'Entire Solution' -> entire (no switch)
#      A3 other scopes ('目前文件', 'Open Documents', '目前的專案', 'Current Project') -> partial
#      A4 the 'Build + IntelliSense' combo is not taken for the scope combo
#      A5 combo without SelectionPattern: ValuePattern value is used; nothing readable -> $null
#   B  static: the scan reads GetSelection, emits Scope, reads the scope back after Select()
#   C  Get-TcBuildErrors with a mocked scan (Invoke-TcUiaScan replaced):
#      C1 #117 case: warnings 28 on the button, 0 rows read -> ERRORLIST_INCOMPLETE, not success
#      C2 errors 2, 1 row -> ERRORLIST_INCOMPLETE (errors)
#      C3 complete read -> success, data.scope carried
#      C4 scope stayed on '目前專案' (entire = $false), counts match -> ERRORLIST_INCOMPLETE
#      C5 -IncludeWarnings:$false: warnings not compared -> success
#      C6 severities not isolatable: total rows vs sum of totals
#      C7 Get-TcErrorListSummary / Get-TcErrorListReadState on ERRORLIST_INCOMPLETE (#138):
#         C7a only warnings short -> errorListError $null, warningsIncomplete, rows kept
#         C7b failed build + warnings short -> codeErrors listed (not empty)
#         C7c errors short -> errorListError ERRORLIST_INCOMPLETE, the rows read still listed
#         C7d severities not isolated (total) / Errors total unreadable -> errors not complete
#         C7e scope.entire = $false with every count matching, buttons 'X / Y' -> note only, not blocking
#         C7h same with single-number buttons -> stays incomplete (codeVerified = null, #138 N1)
#         C7f scope.entire = $false AND warnings short -> blocking
#      C8 the hint exists
#   E  Read-Grid (extracted from the scan AST, Read-Row stubbed) on a MOCK scrolling grid (#138):
#      E1 page overlap A,B,C / B,C,D -> 4 rows; E2 same-page duplicate A,A,B -> 3 rows + note;
#      E3 duplicate on page 1 and again on page 2 -> kept as 2; E4 copies split across pages
#      (documented limit) -> counted once
#   F  junk rows and stabilised reads (#138 F1, real-machine report pr138-e026472):
#      F1 a project:null row whose description is the accessible name is not counted (junkRows)
#      F2 junk row + one real row missing, grid never settles -> severity unstable
#      F3 grid realises the rows on the next read -> stable after 2 equal reads = total
#      F4 Get-TcBuildErrors: junk excluded + one missing -> ERRORLIST_INCOMPLETE; unstable severity
#         with a matching last read -> ERRORLIST_INCOMPLETE (unstable)
#      F5 a real row without location (build-summary) is NOT junk
#      F6 every read 0 rows with a total > 0 -> 'no rows read' / noRows, not unstable (#138 O5)
#   D  #107: Error List budget of Build-TcProject / Test-TcPlcProject
#      D1 $script:TcBuildErrorListTimeoutSec >= 30, no 8 s branch left in either cmdlet
#      D2 a scan that needs 17 s (simulated, no wait): times out with the old 8 s budget, reads
#         the list with the budget the cmdlets now pass
#   powershell.exe -NoProfile -File tests/Unit/errorlist-scope-117.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$tcUnit117OwnDir = $false
if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-117-{0}" -f [guid]::NewGuid().ToString('N'))
    $tcUnit117OwnDir = $true
}
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$ae = [System.Windows.Automation.AutomationElement]
$ct = [System.Windows.Automation.ControlType]
$scope = [System.Windows.Automation.TreeScope]

# --- mock UIA tree ---
# Element: Current.Name / Current.ControlType, Kids, Patterns (ProgrammaticName -> pattern object).
# FindAll(TreeScope, PropertyCondition(ControlTypeProperty)) walks the kids; every other
# condition matches all. TryGetCurrentPattern(pattern, [ref]out) answers from Patterns.
function New-MockEl {
    param([string]$Name, $ControlType, [object[]]$Kids = @(), [hashtable]$Patterns = @{})
    $el = [PSCustomObject]@{
        Current  = [PSCustomObject]@{ Name = $Name; ControlType = $ControlType; ClassName = '' }
        Kids     = @($Kids)
        Patterns = $Patterns
    }
    $el | Add-Member ScriptMethod TryGetCurrentPattern {
        param($Pattern, $Out)
        $p = $this.Patterns[$Pattern.ProgrammaticName]
        if ($null -eq $p) { return $false }
        $Out.Value = $p
        return $true
    }
    $el | Add-Member ScriptMethod FindAll {
        param($TreeScope, $Condition)
        $want = $null
        if ($Condition -is [System.Windows.Automation.PropertyCondition] -and $Condition.Property -eq [System.Windows.Automation.AutomationElement]::ControlTypeProperty) {
            $want = $Condition.Value
        }
        $hits = [System.Collections.Generic.List[object]]::new()
        $stack = [System.Collections.Generic.Stack[object]]::new()
        foreach ($k in $this.Kids) { $stack.Push($k) }
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            $ctId = $n.Current.ControlType.Id
            if ($null -eq $want -or $want -eq $ctId -or $want -eq $n.Current.ControlType) { $hits.Add($n) }
            if ($TreeScope -eq [System.Windows.Automation.TreeScope]::Descendants) { foreach ($k in $n.Kids) { $stack.Push($k) } }
        }
        $global:MockFindAll.Add("$($Condition.Value)") | Out-Null
        , $hits.ToArray()
    }
    $el
}
function New-SelectionPattern([object[]]$Selected) {
    $cur = [PSCustomObject]@{ Sel = @($Selected) }
    $cur | Add-Member ScriptMethod GetSelection { , $this.Sel }
    [PSCustomObject]@{ Current = $cur }
}
function New-ValuePattern([string]$Value) { [PSCustomObject]@{ Current = [PSCustomObject]@{ Value = $Value } } }
$selKey = [System.Windows.Automation.SelectionPattern]::Pattern.ProgrammaticName
$valKey = [System.Windows.Automation.ValuePattern]::Pattern.ProgrammaticName
$ecpKey = [System.Windows.Automation.ExpandCollapsePattern]::Pattern.ProgrammaticName

# Collapsed scope combo: the selected item is reachable only through SelectionPattern, the
# combo has NO ListItem descendants (as measured in #117).
function New-ScopeCombo([string]$Selected, [switch]$NoSelectionPattern, [string]$Value) {
    $item = New-MockEl -Name $Selected -ControlType $ct::ListItem
    $pat = @{ $ecpKey = [PSCustomObject]@{ Current = [PSCustomObject]@{ ExpandCollapseState = 'Collapsed' } } }
    if (-not $NoSelectionPattern) { $pat[$selKey] = New-SelectionPattern @($item) }
    if ($PSBoundParameters.ContainsKey('Value')) { $pat[$valKey] = New-ValuePattern $Value }
    New-MockEl -Name '' -ControlType $ct::ComboBox -Patterns $pat
}
function New-ToolRoot([object[]]$Combos) {
    $tb = New-MockEl -Name 'Error List' -ControlType $ct::ToolBar -Kids (@($Combos) + @(
        (New-MockEl -Name '0 / 2 錯誤' -ControlType $ct::Button),
        (New-MockEl -Name '0 / 28 警告' -ControlType $ct::Button)))
    New-MockEl -Name '錯誤清單 - 目前的專案 (AxisInterface)' -ControlType $ct::Pane -Kids @($tb)
}
$global:MockFindAll = [System.Collections.ArrayList]::new()

# --- extract the scope functions and patterns from the real scan scriptblock ---
$scanSb = & $mod { $script:TcUiaErrorListScan }
$fnNames = @('Get-UiaName', 'Get-UiaPattern', 'Get-ScopeKind', 'Get-ComboSelectionName', 'Find-ScopeCombo')
$fnAsts = @($scanSb.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $fnNames -contains $a.Name }, $true))
$varAsts = @($scanSb.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -match '^\$scope(Entire|Partial)Pattern$' }, $true))
Check 'A0 scan defines the scope functions and patterns' ($fnAsts.Count -eq $fnNames.Count -and $varAsts.Count -eq 2) "functions $($fnAsts.Count)/$($fnNames.Count), patterns $($varAsts.Count)/2"
foreach ($v in $varAsts) { . ([scriptblock]::Create($v.Extent.Text)) }
foreach ($f in $fnAsts) { . ([scriptblock]::Create($f.Extent.Text)) }

try {
    # --- A: scope detection on the mock tree ---
    $root = New-ToolRoot @(New-ScopeCombo '目前專案')
    $global:MockFindAll.Clear()
    $listItems = @($root.FindAll($scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::ListItem))))
    $hit = Find-ScopeCombo $root
    Check 'A1 collapsed combo: no ListItem descendant (old detection found nothing)' ($listItems.Count -eq 0) "ListItems $($listItems.Count)"
    Check 'A1 collapsed combo selected 目前專案 -> scope combo found, partial (switch needed)' ($null -ne $hit -and $hit.Kind -eq 'partial' -and $hit.Selected -eq '目前專案') (J ($hit | Select-Object Selected, Kind))

    foreach ($n in @('整個方案', 'Entire Solution')) {
        $hit = Find-ScopeCombo (New-ToolRoot @(New-ScopeCombo $n))
        Check "A2 selection '$n' -> entire, no switch" ($null -ne $hit -and $hit.Kind -eq 'entire') (J ($hit | Select-Object Selected, Kind))
    }
    foreach ($n in @('目前文件', '開啟文件', 'Open Documents', '目前的專案', 'Current Project', 'Current Document')) {
        $hit = Find-ScopeCombo (New-ToolRoot @(New-ScopeCombo $n))
        Check "A3 selection '$n' (not Entire Solution) -> partial, switch" ($null -ne $hit -and $hit.Kind -eq 'partial' -and $hit.Selected -eq $n) (J ($hit | Select-Object Selected, Kind))
    }

    $root = New-ToolRoot @((New-ScopeCombo '建置 + IntelliSense'), (New-ScopeCombo '目前專案'))
    $hit = Find-ScopeCombo $root
    Check "A4 'Build + IntelliSense' combo skipped, scope combo taken" ($null -ne $hit -and $hit.Selected -eq '目前專案') (J ($hit | Select-Object Selected, Kind))
    $hit = Find-ScopeCombo (New-ToolRoot @(New-ScopeCombo 'Build + IntelliSense'))
    Check 'A4 only a source combo -> no scope combo ($null, scope unknown)' ($null -eq $hit) (J $hit)

    $hit = Find-ScopeCombo (New-ToolRoot @(New-ScopeCombo 'x' -NoSelectionPattern -Value '目前專案'))
    Check 'A5 no SelectionPattern: ValuePattern value used' ($null -ne $hit -and $hit.Kind -eq 'partial') (J ($hit | Select-Object Selected, Kind))
    $hit = Find-ScopeCombo (New-ToolRoot @(New-ScopeCombo 'x' -NoSelectionPattern))
    Check 'A5 nothing readable -> $null' ($null -eq $hit) (J $hit)
    Check 'A5 Get-ScopeKind of empty / unknown names -> $null' ($null -eq (Get-ScopeKind '') -and $null -eq (Get-ScopeKind 'Foo')) ''

    # --- B: static checks on the scan text (comments dropped) ---
    $tokens = $null; $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($scanSb.ToString(), [ref]$tokens, [ref]$errs)
    $code = (@($tokens | Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } | ForEach-Object { $_.Text }) -join ' ')
    Check 'B1 scan reads the combo selection (GetSelection) and emits Scope' ($code -match 'GetSelection' -and $code -match '\bScope\s*=') ''
    Check 'B2 scan reads the scope back after Select()' ($code -match 'after\s*=\s*Get-ComboSelectionName') ''

    # --- C: Get-TcBuildErrors readback with a mocked scan ---
    & $mod {
        $script:TcDte = [PSCustomObject]@{}
        $script:TcIdeConnected = $true
        $script:TcIdeProcessId = $PID
        function script:Invoke-TcComRetry { [CmdletBinding()] param([scriptblock]$ScriptBlock, [int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec) $null }
        function script:Initialize-TcUiaScanTypes { [CmdletBinding()] param([int]$TimeoutSec) $true }
        function script:Invoke-TcUiaScan {
            [CmdletBinding()] param([scriptblock]$Script, [object[]]$Arguments, [int]$TimeoutSec, [ref]$TimedOut, [ref]$ErrorOut)
            $global:ScanBudgets.Add($TimeoutSec) | Out-Null
            if ($null -ne $global:ScanNeedsSec -and $TimeoutSec -lt $global:ScanNeedsSec) {
                if ($null -ne $TimedOut) { $TimedOut.Value = $true }
                return $null
            }
            $global:ScanResult
        }
    }
    $global:ScanBudgets = [System.Collections.ArrayList]::new()
    $global:ScanNeedsSec = $null
    function Row([string]$Sev, [string]$Desc, [int]$Line = 1) {
        [PSCustomObject]@{ severity = $Sev; description = $Desc; project = 'Plc'; file = 'MAIN'; line = "$Line"; column = '1'; code = $null }
    }
    function Set-Scan([object[]]$Rows, $Errors, $Warnings, $Messages = 0, [bool]$Toggle = $true, $Scope = $null, [bool]$TotalForm = $true) {
        if ($null -eq $Scope) { $Scope = [PSCustomObject]@{ before = '整個方案'; after = '整個方案'; entire = $true; switched = $false } }
        $global:ScanResult = [PSCustomObject]@{
            Found = $true; Rows = @($Rows); Truncated = $false; ToggleUsed = $Toggle; Notes = @('mock'); Headers = @()
            Counts = [PSCustomObject]@{ errors = $Errors; warnings = $Warnings; messages = $Messages }
            Scope = $Scope
            CountsTotalForm = $TotalForm
        }
    }

    Set-Scan -Rows @() -Errors 0 -Warnings 28 -Scope ([PSCustomObject]@{ before = '目前專案'; after = '整個方案'; entire = $true; switched = $true })
    $r = Get-TcBuildErrors -TimeoutSec 30
    $mw = @($r.data.missingRows | Where-Object { $_.severity -eq 'warnings' })
    Check 'C1 #117: 28 warnings on the button, 0 rows -> not success, ERRORLIST_INCOMPLETE' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE') (J $r.error)
    Check 'C1 data.missingRows names warnings 28 / 0, counts kept' ($mw.Count -eq 1 -and $mw[0].expected -eq 28 -and $mw[0].read -eq 0 -and $r.data.counts.warnings -eq 28) (J $r.data)
    Check 'C1 hint present' (-not [string]::IsNullOrWhiteSpace([string]$r.error.hint)) ''

    Set-Scan -Rows @((Row 'Error' 'e1')) -Errors 2 -Warnings 0
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'C2 errors 2, 1 row read -> ERRORLIST_INCOMPLETE (errors), partial row kept in data' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and @($r.data.missingRows)[0].severity -eq 'errors' -and @($r.data.errors).Count -eq 1) (J $r)

    # two identical warning rows against a total of 2: both count (no de-duplication here)
    Set-Scan -Rows @((Row 'Error' 'e1'), (Row 'Warning' 'w1'), (Row 'Warning' 'w1')) -Errors 1 -Warnings 2
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'C3 complete read -> success, data.scope carried' ($r.success -and @($r.data.warnings).Count -eq 2 -and $r.data.scope.entire -eq $true -and $null -eq $r.data.PSObject.Properties['missingRows']) (J $r)

    Set-Scan -Rows @() -Errors 0 -Warnings 0 -Scope ([PSCustomObject]@{ before = '目前專案'; after = '目前專案'; entire = $false; switched = $false })
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check "C4 scope stayed '目前專案' (switch failed) -> ERRORLIST_INCOMPLETE even with 0 / 0" (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and $r.data.scope.entire -eq $false -and $r.error.message -match '目前專案') (J $r.error)

    Set-Scan -Rows @() -Errors 0 -Warnings 28 -Scope ([PSCustomObject]@{ before = $null; after = $null; entire = $null; switched = $false })
    $r = Get-TcBuildErrors -IncludeWarnings:$false -TimeoutSec 30
    Check 'C5 -IncludeWarnings:$false: warnings not compared -> success' ($r.success) (J $r)

    Set-Scan -Rows @((Row 'Unknown' 'a'), (Row 'Unknown' 'b'), (Row 'Unknown' 'c')) -Errors 1 -Warnings 2 -Toggle $false
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'C6 not isolatable, 3 rows for 1 + 2 -> success' ($r.success) (J $r.error)
    Set-Scan -Rows @((Row 'Unknown' 'a')) -Errors 1 -Warnings 2 -Toggle $false
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check "C6 not isolatable, 1 row for 1 + 2 -> ERRORLIST_INCOMPLETE 'total'" (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and @($r.data.missingRows)[0].severity -eq 'total' -and @($r.data.missingRows)[0].expected -eq 3) (J $r.data.missingRows)

    function Get-Summary([int]$Fallback = 0) { & $mod { param($f) Get-TcErrorListSummary -TimeoutSec 30 -FallbackErrorCount $f } $Fallback }
    function Sel($x) { J ($x | Select-Object errorListError, incomplete, warningsIncomplete, errorListNote, errorCount, missingRows) }

    Set-Scan -Rows @((Row 'Warning' 'w1')) -Errors 0 -Warnings 28
    $s = Get-Summary
    Check 'C7a summary, only warnings short: errorListError null (not blocking), warningsIncomplete, rows kept' ($null -eq $s.errorListError -and $s.incomplete -and $s.warningsIncomplete -and @($s.warningItems).Count -eq 1 -and $s.errorListNote -match 'warnings: 1 of 28') (Sel $s)

    Set-Scan -Rows @((Row 'Error' "Identifier 'x' not defined" 7), (Row 'Warning' 'w1')) -Errors 1 -Warnings 28
    $s = Get-Summary -Fallback 1
    Check 'C7b failed build + warnings short: codeErrors not empty, errorListError null' (@($s.codeErrors).Count -eq 1 -and $s.codeErrors[0].line -eq 7 -and $null -eq $s.errorListError -and $s.errorCount -eq 1) (Sel $s)

    Set-Scan -Rows @((Row 'Error' "Identifier 'x' not defined" 7)) -Errors 3 -Warnings 0
    $s = Get-Summary -Fallback 1
    Check 'C7c errors short: errorListError ERRORLIST_INCOMPLETE, codeErrors / errorItems still list the row read' ($s.errorListError -eq 'ERRORLIST_INCOMPLETE' -and @($s.codeErrors).Count -eq 1 -and @($s.errorItems).Count -eq 1 -and @($s.missingRows)[0].severity -eq 'errors') (Sel $s)

    Set-Scan -Rows @((Row 'Unknown' 'a')) -Errors 1 -Warnings 2 -Toggle $false
    $s = Get-Summary
    Check "C7d severities not isolated ('total' short) -> errors not complete" ($s.errorListError -eq 'ERRORLIST_INCOMPLETE') (Sel $s)
    Set-Scan -Rows @() -Errors $null -Warnings 28
    $s = Get-Summary
    Check 'C7d Errors total unreadable + warnings short -> errors not complete' ($s.errorListError -eq 'ERRORLIST_INCOMPLETE') (Sel $s)

    Set-Scan -Rows @((Row 'Warning' 'w1')) -Errors 0 -Warnings 1 -Scope ([PSCustomObject]@{ before = '目前專案'; after = '目前專案'; entire = $false; switched = $false })
    $r = Get-TcBuildErrors -TimeoutSec 30
    $s = Get-Summary
    Check "C7e scope '目前專案', counts match: Get-TcBuildErrors fails closed, summary only notes it" (-not $r.success -and $null -eq $s.errorListError -and -not $s.warningsIncomplete -and $s.errorListNote -match 'every count matches') (Sel $s)

    Set-Scan -Rows @((Row 'Warning' 'w1')) -Errors 0 -Warnings 1 -TotalForm $false -Scope ([PSCustomObject]@{ before = '目前專案'; after = '目前專案'; entire = $false; switched = $false })
    $s = Get-Summary
    Check "C7h scope '目前專案', counts match, single-number buttons -> ERRORLIST_INCOMPLETE (Build: codeVerified = null)" ($s.errorListError -eq 'ERRORLIST_INCOMPLETE' -and $null -eq $s.errorListNote) (Sel $s)

    Set-Scan -Rows @() -Errors 0 -Warnings 28 -Scope ([PSCustomObject]@{ before = '目前專案'; after = '目前專案'; entire = $false; switched = $false })
    $s = Get-Summary
    Check "C7f scope '目前專案' AND warnings short -> blocking (errors not proven complete)" ($s.errorListError -eq 'ERRORLIST_INCOMPLETE') (Sel $s)

    $st = & $mod { Get-TcErrorListReadState -Result ([PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'ERRORLIST_UNAVAILABLE' }; data = $null }) }
    Check 'C7g ERRORLIST_UNAVAILABLE -> not usable' (-not $st.usable -and -not $st.errorsComplete) (J $st)

    $hint = & $mod { Get-TcErrorHint -Code 'ERRORLIST_INCOMPLETE' }
    Check 'C8 hint for ERRORLIST_INCOMPLETE' (-not [string]::IsNullOrWhiteSpace([string]$hint) -and $hint -match '整個方案') ''

    # --- E: Read-Grid on a mock scrolling grid ---
    $rgNames = @('Get-UiaPattern', 'New-TypeOr', 'Read-Grid', 'Test-JunkRow', 'Read-SeverityStable')
    $rgAsts = @($scanSb.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $rgNames -contains $a.Name }, $true))
    Check 'E0 scan defines Read-Grid / New-TypeOr / Test-JunkRow / Read-SeverityStable' ($rgAsts.Count -eq 5) "$($rgAsts.Count)/5"
    foreach ($f in $rgAsts) { . ([scriptblock]::Create($f.Extent.Text)) }
    $rgVars = @($scanSb.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Left.Extent.Text -match '^\$(junkTailPattern|StableMaxReads|StableMaxSec)$' }, $true))
    foreach ($v in $rgVars) { . ([scriptblock]::Create($v.Extent.Text)) }
    # 'JUNK:<x>' = the unrealised row of the report: no project / file / line, accessible name as description
    # 'NOLOC:<x>' = a real row without location (build-summary row)
    function Read-Row($r, [string]$sev) {
        $d = [string]$r.Desc
        if ($d -like 'JUNK:*') { return [PSCustomObject]@{ severity = $sev; description = ($d.Substring(5) + ' : 警告. 專案: AxisInterface. 檔案: AxisInterface.plcproj. 行: 1'); project = $null; file = $null; line = $null; column = $null; code = $null } }
        if ($d -like 'NOLOC:*') { return [PSCustomObject]@{ severity = $sev; description = $d.Substring(6); project = $null; file = $null; line = $null; column = $null; code = $null } }
        [PSCustomObject]@{ severity = $sev; description = $d; project = 'P'; file = 'F'; line = '1'; column = '1'; code = $null }
    }
    $script:junkCount = @{ n = 0 }
    $script:unstable = [System.Collections.Generic.List[string]]::new()
    $spKey = [System.Windows.Automation.ScrollPattern]::Pattern.ProgrammaticName
    function New-MockGrid([object[][]]$Pages) {
        $state = [PSCustomObject]@{ Idx = 0; Pages = $Pages }
        $sp = [PSCustomObject]@{ State = $state }
        $sp | Add-Member ScriptProperty Current {
            $n = $this.State.Pages.Count
            [PSCustomObject]@{ VerticallyScrollable = ($n -gt 1); VerticalScrollPercent = $(if ($n -le 1) { 100.0 } else { [double]$this.State.Idx * 100.0 / ($n - 1) }) }
        }
        $sp | Add-Member ScriptMethod SetScrollPercent { param($h, $v) $this.State.Idx = 0 }
        $sp | Add-Member ScriptMethod ScrollVertical { param($a) if ($this.State.Idx -lt $this.State.Pages.Count - 1) { $this.State.Idx++ } }
        $g = [PSCustomObject]@{ State = $state; Patterns = @{ $spKey = $sp } }
        $g | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Out) $p = $this.Patterns[$Pattern.ProgrammaticName]; if ($null -eq $p) { return $false }; $Out.Value = $p; $true }
        $g | Add-Member ScriptMethod FindAll { param($TreeScope, $Condition) , @($this.State.Pages[$this.State.Idx] | ForEach-Object { [PSCustomObject]@{ Desc = $_ } }) }
        $g
    }
    function Invoke-ReadGrid([object[][]]$Pages) {
        $script:grid = New-MockGrid $Pages
        $script:junkCount = @{ n = 0 }
        $script:notes = [System.Collections.Generic.List[string]]::new()
        $script:MaxRows = 2000
        $script:SettleMs = 0
        $out = [System.Collections.Generic.List[object]]::new()
        $trunc = Read-Grid 'Warning' @{} $out
        [PSCustomObject]@{ Rows = @($out | ForEach-Object { $_.description }); Truncated = $trunc; Notes = @($script:notes) }
    }
    $g = Invoke-ReadGrid @(@('A', 'B', 'C'), @('B', 'C', 'D'))
    Check 'E1 page overlap A,B,C / B,C,D -> A,B,C,D, no duplicate note' (($g.Rows -join ',') -eq 'A,B,C,D' -and -not $g.Truncated -and @($g.Notes).Count -eq 0) (J $g)
    $g = Invoke-ReadGrid @(, @('A', 'A', 'B'))
    Check 'E2 same-page duplicate A,A,B -> 3 rows, note records the duplicate' (($g.Rows -join ',') -eq 'A,A,B' -and @($g.Notes | Where-Object { $_ -match "page 1: 1 key\(s\).*1 extra row" }).Count -eq 1) (J $g)
    $g = Invoke-ReadGrid @(@('A', 'A', 'B'), @('A', 'B', 'C'))
    Check 'E3 duplicate on page 1, one copy again on page 2 (overlap) -> A,A,B,C' (($g.Rows -join ',') -eq 'A,A,B,C') (J $g)
    $g = Invoke-ReadGrid @(@('A', 'B'), @('B', 'C'))
    Check 'E4 copies split across a page boundary look like overlap -> counted once (documented limit)' (($g.Rows -join ',') -eq 'A,B,C') (J $g)

    # --- F: junk rows and stabilised reads (#138 F1) ---
    $g = Invoke-ReadGrid @(, @('A', 'B', 'JUNK:C'))
    Check 'F1 project:null accessible-name row is not counted (A,B), junkRows 1' (($g.Rows -join ',') -eq 'A,B' -and $script:junkCount.n -eq 1) (J $g)
    $g = Invoke-ReadGrid @(, @('A', 'NOLOC:Project build failed', 'B'))
    Check 'F5 a real row without location (plain description) is kept' (@($g.Rows).Count -eq 3 -and $script:junkCount.n -eq 0) (J $g)

    # A single-page grid whose content changes per read: snapshot k is returned by the k-th FindAll.
    function New-SnapshotGrid([object[][]]$Snapshots) {
        $state = [PSCustomObject]@{ Calls = 0; Snaps = $Snapshots }
        $g = [PSCustomObject]@{ State = $state }
        $g | Add-Member ScriptMethod TryGetCurrentPattern { param($Pattern, $Out) $false }
        $g | Add-Member ScriptMethod FindAll {
            param($TreeScope, $Condition)
            $i = [Math]::Min($this.State.Calls, $this.State.Snaps.Count - 1)
            $this.State.Calls++
            , @($this.State.Snaps[$i] | ForEach-Object { [PSCustomObject]@{ Desc = $_ } })
        }
        $g
    }
    function Invoke-Stable([object[][]]$Snapshots, $Total, [bool]$RequireStable) {
        $script:grid = New-SnapshotGrid $Snapshots
        $script:junkCount = @{ n = 0 }
        $script:unstable = [System.Collections.Generic.List[string]]::new()
        $script:noRows = [System.Collections.Generic.List[string]]::new()
        $script:notes = [System.Collections.Generic.List[string]]::new()
        $script:MaxRows = 2000
        $script:SettleMs = 0
        $out = [System.Collections.Generic.List[object]]::new()
        $null = Read-SeverityStable 'Warning' $Total $RequireStable $out
        [PSCustomObject]@{ Rows = @($out | ForEach-Object { $_.description }); Unstable = @($script:unstable); NoRows = @($script:noRows); Reads = $script:grid.State.Calls; Notes = @($script:notes) }
    }
    $g = Invoke-Stable @(, @('A', 'B', 'JUNK:C')) 3 $false
    Check 'F2 junk row + C missing, never settles: junk triggers re-reads, Warning unstable, bounded reads' (@($g.Unstable) -contains 'Warning' -and @($g.Rows).Count -eq 2 -and $g.Reads -le $StableMaxReads -and $g.Reads -ge 2) (J $g)
    $g = Invoke-Stable @(@('A', 'JUNK:B', 'C'), @('A', 'B', 'C')) 3 $false
    Check 'F3 rows realised on the next read: two equal reads = total -> stable, A,B,C' (@($g.Unstable).Count -eq 0 -and ($g.Rows -join ',') -eq 'A,B,C' -and $g.Reads -eq 3) (J $g)
    $g = Invoke-Stable @(, @('A', 'B', 'C')) 3 $true
    Check 'F3 after a scope switch even a clean read is confirmed once more (2 reads)' (@($g.Unstable).Count -eq 0 -and $g.Reads -eq 2) (J $g)
    $g = Invoke-Stable @(, @('A', 'B', 'C')) 3 $false
    Check 'F3 no switch, no junk: a single read' ($g.Reads -eq 1) (J $g)
    $g = Invoke-Stable @(, @()) 3 $true
    Check "F6 every read 0 rows, total 3 -> 'no rows read' + noRows, not unstable (#138 O5)" (@($g.NoRows) -contains 'Warning' -and @($g.Unstable).Count -eq 0 -and @($g.Notes | Where-Object { $_ -match 'no rows read' }).Count -eq 1 -and @($g.Notes | Where-Object { $_ -match 'NOT stable' }).Count -eq 0) (J $g)
    Set-Scan -Rows @() -Errors 0 -Warnings 3
    $global:ScanResult | Add-Member -NotePropertyName NoRows -NotePropertyValue @('Warning')
    $r = Get-TcBuildErrors -TimeoutSec 30
    $mw = @($r.data.missingRows | Where-Object { $_.severity -eq 'warnings' })
    Check 'F6 Get-TcBuildErrors: missingRows noRows = true, unstable = false, still ERRORLIST_INCOMPLETE' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and $mw.Count -eq 1 -and $mw[0].noRows -and -not $mw[0].unstable) (J $r.data.missingRows)

    Set-Scan -Rows @((Row 'Warning' 'w1'), (Row 'Warning' 'w2')) -Errors 0 -Warnings 3
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'F4 junk excluded + one real row missing (2 of 3) -> ERRORLIST_INCOMPLETE' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE') (J $r.data.missingRows)
    Set-Scan -Rows @((Row 'Error' 'e1'), (Row 'Warning' 'w1'), (Row 'Warning' 'w2')) -Errors 1 -Warnings 2
    $global:ScanResult | Add-Member -NotePropertyName Unstable -NotePropertyValue @('Error')
    $r = Get-TcBuildErrors -TimeoutSec 30
    $s = Get-Summary
    $mr = @($r.data.missingRows | Where-Object { $_.severity -eq 'errors' })
    Check 'F4 errors unstable, last read matches the total -> ERRORLIST_INCOMPLETE, summary blocks (codeVerified null)' (-not $r.success -and $mr.Count -eq 1 -and $mr[0].unstable -and $s.errorListError -eq 'ERRORLIST_INCOMPLETE') (J $r.data.missingRows)

    # --- D: #107 Error List budget ---
    $budget = & $mod { $script:TcBuildErrorListTimeoutSec }
    $root = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
    $bad = @()
    foreach ($f in @('Build-TcProject.ps1', 'Test-TcPlcProject.ps1')) {
        $txt = [IO.File]::ReadAllText((Join-Path $root $f))
        if ($txt -match '\{\s*8\s*\}' -or $txt -notmatch 'Get-TcErrorListSummary\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec') { $bad += $f }
    }
    # #194: the Enable-TcConfig diagnostics live in the shared Private/Get-TcRuntimeFailureDiagnostics.ps1
    $ecTxt = [IO.File]::ReadAllText((Join-Path $root 'Enable-TcConfig.ps1')) + [IO.File]::ReadAllText((Join-Path $root '..\Private\Get-TcRuntimeFailureDiagnostics.ps1'))
    $clTxt = [IO.File]::ReadAllText((Join-Path $root 'Clear-TcProject.ps1'))
    if ($ecTxt -match 'Get-TcBuildErrors\s+-TimeoutSec\s+8\b' -or $ecTxt -notmatch 'TcBuildErrorListTimeoutSec') { $bad += 'Enable-TcConfig.ps1' }
    if ($clTxt -notmatch 'Get-TcBuildErrors\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec') { $bad += 'Clear-TcProject.ps1' }
    Check 'D1 budget >= 30 s on every path, no 8 s branch (Build / Test / Clean / Enable-TcConfig diagnostics)' ($budget -ge 30 -and $bad.Count -eq 0) "budget=$budget bad=$($bad -join ',')"

    Set-Scan -Rows @() -Errors 0 -Warnings 0
    $global:ScanNeedsSec = 17      # VS2022 measured 16.5-17.8 s (#107); simulated, nothing waits
    $old = & $mod { Get-TcErrorListSummary -TimeoutSec 8 }
    $new = & $mod { Get-TcErrorListSummary -TimeoutSec $script:TcBuildErrorListTimeoutSec }
    Check 'D2 slow scan: the old 8 s budget times out (ERRORLIST_UNAVAILABLE)' ($old.errorListError -eq 'ERRORLIST_UNAVAILABLE') "$($old.errorListError)"
    Check 'D2 slow scan: the cmdlet budget reads the list' ($null -eq $new.errorListError) "$($new.errorListError) budgets=$($global:ScanBudgets -join ',')"
    $global:ScanNeedsSec = $null
}
finally {
    if ($tcUnit117OwnDir -and (Test-Path -LiteralPath $env:TCAUTO_STATE_DIR) -and ((Split-Path -Leaf $env:TCAUTO_STATE_DIR) -like 'tcauto-unit-117-*')) {
        Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"failed: $fail"
exit $fail
