# UI Automation scan of the IDE "Error List" tool window. Runs INSIDE a separate STA
# runspace (Invoke-TcUiaScan), so it must be self-contained: no module functions, no
# $script: state. Same pattern as $script:TcUiaDialogScan (Find-TcIdeModalDialog).
#
# Arguments: target process id, wanted severities (bool Errors/Warnings/Messages),
# max rows per severity, settle time in ms after a toggle/scroll.
# Emits ONE PSCustomObject:
#   Found        - $false when no Error List with a data grid was found in the process
#   Counts       - @{ errors; warnings; messages } parsed from the summary buttons
#                  ("9 Errors", "8 Warnings", "0 of 10 Messages": second number = total;
#                  counts also parsed from zh-TW button names: "3 個錯誤", "1 個警告", "2 則訊息",
#                  and the zh-TW VS2022 "shown / total" form "0 / 2 錯誤", "0 / 1 訊息")
#
# zh-TW VS2022 (XAE 4026.22, 2026-10-21): pane Name '錯誤清單' or '錯誤清單 - 目前的專案 (<proj>)'
# (class GenericPane), grid ControlType.Table ClassName ListView, same English header
# AutomationIds. The scope ComboBox defaults to '目前專案' (Current Project), which hides
# the rows of other projects; the scan reads the combo's selection (SelectionPattern, works
# while collapsed, #117) and switches it to '整個方案' (Entire Solution) first
# (note 'scope switched to entire solution') and leaves it there.
#   Rows         - [PSCustomObject]@{ severity; description; project; file; line; column; code; raw }
#   Truncated    - $true when the grid has no ScrollPattern (only visible rows read)
#                  or MaxRows was hit
#   Headers      - column AutomationIds seen in the header row
#   ToggleUsed   - $true when the severity buttons were toggled to isolate severities
#   Scope        - @{ before; after; entire; switched }: scope filter read from the scope
#                  ComboBox's own selection (#117); entire $true = Entire Solution confirmed,
#                  $false = another scope that could not be switched (rows filtered), $null = unknown
#   Notes        - diagnostic strings
#
# Error List structure of TcXaeShell 15.0 (VS2017 shell), 2026-10-18:
#   Pane 'Error List' (ViewPresenter)
#     ToolBar 'Error List' : Button '9 Errors' / '8 Warnings' / '0 of 10 Messages' (Toggle)
#     Pane 'Error List' (GenericPane) > Custom (WrapListView)
#       DataGrid 'Tracking List View' (Scroll, Grid, Table patterns)
#         Header 'Header Row' > HeaderItem aid=detailsexpander|errorseverity|text|projectname|documentname|line
#         DataItem Name=<description> (ListViewItem, virtualised)
#           Custom (ContentPresenter, GridItem/TableItem) > Image (severity icon, name useless)
#           Custom > Text <description>  /  Text <project>  /  Text <file>  /  Text <line>
# The severity icon has no readable name and no Code column is shown, so severity is
# isolated by toggling the summary buttons (restored afterwards) and the TwinCAT error
# code (Cxxxx) is parsed from the description by the caller when present.
$script:TcUiaErrorListScan = {
    param([int]$TargetPid, [bool]$WantErrors, [bool]$WantWarnings, [bool]$WantMessages, [int]$MaxRows, [int]$SettleMs)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

    $ae = [System.Windows.Automation.AutomationElement]
    $ct = [System.Windows.Automation.ControlType]
    $scope = [System.Windows.Automation.TreeScope]
    $notes = [System.Collections.Generic.List[string]]::new()

    function Get-UiaName {
        param($el)
        try { return [string]$el.Current.Name } catch { return '' }
    }

    function Get-UiaPattern {
        param($el, $pattern)
        $p = $null
        try {
            if ($el.TryGetCurrentPattern($pattern, [ref]$p)) { return $p }
        }
        catch { }
        return $null
    }

    # --- 1. top-level windows of the IDE process (main window + floating tool windows) ---
    # EnumWindows filtered by the pid + AutomationElement.FromHandle (TcAutomation.UiaScanWindows,
    # compiled by Initialize-TcUiaScanTypes before this scan runs), not RootElement.FindAll
    # (Children, ProcessId): that one queries every top-level window on the desktop and stalls
    # ~3 s on an unresponsive window of any other process (#24 / #42, measured 2026-10-25, see
    # Find-TcIdeModalDialog.ps1). The desktop FindAll is only the fallback when the type is missing.
    $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    function Get-IdeTopLevelWindows {
        $list = [System.Collections.Generic.List[object]]::new()
        if (([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanWindows').Type) {
            foreach ($wh in [TcAutomation.UiaScanWindows]::TopLevelOf([uint32]$TargetPid)) {
                try { $we = $ae::FromHandle($wh); if ($null -ne $we) { $list.Add($we) } } catch { }
            }
            return , $list
        }
        $notes.Add('TcAutomation.UiaScanWindows not loaded: desktop-wide FindAll used')
        try { foreach ($we in $ae::RootElement.FindAll($scope::Children, $pidCond)) { $list.Add($we) } } catch { }
        return , $list
    }
    $windows = Get-IdeTopLevelWindows
    if ($null -eq $windows -or $windows.Count -eq 0) {
        $notes.Add("no top-level window for pid $TargetPid")
        return [PSCustomObject]@{ Found = $false; Counts = $null; Rows = @(); Truncated = $false; Headers = @(); ToggleUsed = $false; Notes = $notes.ToArray() }
    }

    # --- 2. the Error List content pane: Name 'Error List' with a DataGrid/List descendant ---
    function New-TypeOr {
        param([object[]]$Types)
        # OrCondition(params Condition[]) - New-Object needs the array as ONE argument
        $conds = [System.Windows.Automation.Condition[]]@($Types | ForEach-Object {
            New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $_) })
        New-Object System.Windows.Automation.OrCondition -ArgumentList (, $conds)
    }
    $gridCond = New-TypeOr @($ct::DataGrid, $ct::List, $ct::Table)
    # Pane name: 'Error List' (English XAE / VS) or, in a zh-TW VS2022, '錯誤清單' /
    # '錯誤清單 - 目前的專案 (<project>)' (the scope filter is appended to the name).
    $paneNamePattern = '^(Error List|錯誤清單)'
    $paneCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Pane)
    $pane = $null
    $grid = $null
    foreach ($w in $windows) {
        try { if ($w.Current.ClassName -eq '#32770') { continue } } catch { continue }
        $hits = $null
        try { $hits = $w.FindAll($scope::Descendants, $paneCond) } catch { continue }
        if ($null -eq $hits) { continue }
        foreach ($h in $hits) {
            if ((Get-UiaName $h) -notmatch $paneNamePattern) { continue }
            $g = $null
            try { $g = $h.FindFirst($scope::Descendants, $gridCond) } catch { $g = $null }
            if ($null -ne $g) {
                $pane = $h
                $grid = $g
                $cls = ''
                try { $cls = [string]$h.Current.ClassName } catch { }
                $notes.Add("pane class=$cls grid=" + (Get-UiaName $g) + " type=" + $g.Current.ControlType.ProgrammaticName)
                break
            }
        }
        if ($null -ne $grid) { break }
    }
    if ($null -eq $grid) {
        $notes.Add("no 'Error List' / '錯誤清單' pane with a data grid found in $($windows.Count) window(s)")
        return [PSCustomObject]@{ Found = $false; Counts = $null; Rows = @(); Truncated = $false; Headers = @(); ToggleUsed = $false; Notes = $notes.ToArray() }
    }

    # --- 3. summary / filter buttons ---
    # Labels: "9 Errors", "8 Warnings", "0 of 10 Messages" (XAE), "3 個錯誤", "2 則訊息",
    # "0 / 2 錯誤", "0 / 1 訊息" (zh-TW VS2022: "shown / total"). Count = the total, i.e.
    # the second number when two are given. Returns @{ Severity; Count } or $null.
    function ConvertFrom-CountLabel {
        param([string]$Label)
        $m = [regex]::Match($Label, '^\s*(\d+)(?:\s*(?:of|/)\s*(\d+))?\s*(Errors?|個錯誤|錯誤|Warnings?|個警告|警告|Messages?|則訊息|個訊息|訊息)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $m.Success) { return $null }
        $word = $m.Groups[3].Value
        $sevName = 'Message'
        if ($word -match '^(Errors?|個錯誤|錯誤)$') { $sevName = 'Error' }
        elseif ($word -match '^(Warnings?|個警告|警告)$') { $sevName = 'Warning' }
        $num = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { [int]$m.Groups[1].Value }
        return [PSCustomObject]@{ Severity = $sevName; Count = $num; TwoNumbers = [bool]$m.Groups[2].Success }
    }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Button)
    function Find-CountButtons {
        param($Root)
        $found = @{}
        $twoNumbers = $false
        $cnt = [ordered]@{ errors = $null; warnings = $null; messages = $null }
        $all = $null
        try { $all = $Root.FindAll($scope::Descendants, $btnCond) } catch { $all = $null }
        if ($null -ne $all) {
            foreach ($b in $all) {
                $parsed = ConvertFrom-CountLabel (Get-UiaName $b)
                if ($null -eq $parsed) { continue }
                switch ($parsed.Severity) {
                    'Error'   { $cnt.errors = $parsed.Count }
                    'Warning' { $cnt.warnings = $parsed.Count }
                    'Message' { $cnt.messages = $parsed.Count }
                }
                $found[$parsed.Severity] = $b
                if ($parsed.TwoNumbers) { $twoNumbers = $true }
            }
        }
        # TwoNumbers: at least one button reads "X / Y" / "X of Y" (shown / total). Only then is the
        # number a total that does not depend on the scope filter (#138 N1); a single number may be
        # the count of the filtered list.
        return [PSCustomObject]@{ Buttons = $found; Counts = $cnt; TwoNumbers = $twoNumbers }
    }

    # The buttons (and the scope ComboBox) live in the tool window's toolbar: under the
    # matched pane in the XAE, possibly under a parent of it when only the inner content
    # pane carries the name. Walk up at most two levels.
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $toolRoot = $pane
    $cb = Find-CountButtons $pane
    if ($cb.Buttons.Count -eq 0) {
        $up = $pane
        for ($lvl = 1; $lvl -le 2; $lvl++) {
            try { $up = $walker.GetParent($up) } catch { $up = $null }
            if ($null -eq $up) { break }
            $cbUp = Find-CountButtons $up
            if ($cbUp.Buttons.Count -gt 0) {
                $toolRoot = $up
                $cb = $cbUp
                $notes.Add("count buttons found $lvl level(s) above the pane")
                break
            }
        }
    }

    # --- 3b. scope filter: VS2022 defaults the Error List to "Current Project" (目前專案),
    # hiding the rows of the other projects (scope filter of the Error List window:
    # https://learn.microsoft.com/en-us/visualstudio/ide/error-list-window, "Filter the list by
    # scope and source": Entire Solution, Open Documents, Current Project, Current Document).
    # Switch the ComboBox to "Entire Solution" (整個方案) whenever it shows anything else.
    # The current scope is read from the ComboBox ITSELF (SelectionPattern.GetSelection(), else
    # ValuePattern): while the drop-down is collapsed the combo has no ListItem descendants, so
    # looking for the scope names among ListItems found nothing and the filtered rows were read
    # as the whole list (#117, 實測 2026-11-05, zh-TW VS2022 4026: scope 目前專案 -> warnings 28,
    # 0 rows read; GetSelection() on the collapsed combo returned the selected item).
    # Result in $scopeInfo (emitted as Scope): before / after = selected scope name, entire =
    # $true (Entire Solution confirmed by readback), $false (another scope and the switch did not
    # take: the rows are filtered), $null (no scope ComboBox recognised: unknown).
    # Known scope names: the four of the Microsoft Learn page above (zh-TW 整個方案 / 目前專案 實測
    # 2026-11-05; the other zh-TW names are inferred) plus 'Changed Documents' / '已變更的文件'
    # (not on that page, added defensively, not measured). A combo showing a name OUTSIDE this list
    # is not recognised as the scope combo (scope unknown, entire = $null): then only the
    # rows-vs-count readback of Get-TcBuildErrors protects the result.
    $scopeEntirePattern = '^(整個方案|Entire Solution)$'
    $scopePartialPattern = '^(目前的?專案|目前的?文件|開啟的?文件|已變更的?文件|Current Project|Current Document|Open Documents|Changed Documents)$'
    function Get-ScopeKind {
        param([string]$Name)
        if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
        $n = $Name.Trim()
        if ($n -match $scopeEntirePattern) { return 'entire' }
        if ($n -match $scopePartialPattern) { return 'partial' }
        return $null
    }
    # Name of the selected item of a ComboBox: SelectionPattern first (readable while collapsed),
    # then the ValuePattern value; $null when neither is readable.
    function Get-ComboSelectionName {
        param($Combo)
        $sp = Get-UiaPattern $Combo ([System.Windows.Automation.SelectionPattern]::Pattern)
        if ($null -ne $sp) {
            try {
                foreach ($s in @($sp.Current.GetSelection())) {
                    $nm = Get-UiaName $s
                    if (-not [string]::IsNullOrWhiteSpace($nm)) { return $nm.Trim() }
                }
            }
            catch { }
        }
        $vp = Get-UiaPattern $Combo ([System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $vp) {
            try {
                $v = [string]$vp.Current.Value
                if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
            }
            catch { }
        }
        return $null
    }
    # The scope ComboBox among the ComboBoxes of the tool window: the one whose selection is a
    # known scope name (the other combo, 'Build + IntelliSense', is not a scope). $null if none.
    function Find-ScopeCombo {
        param($Root)
        $comboCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::ComboBox)
        $combos = $null
        try { $combos = $Root.FindAll($scope::Descendants, $comboCond) } catch { $combos = $null }
        if ($null -eq $combos) { return $null }
        foreach ($c in $combos) {
            $sel = Get-ComboSelectionName $c
            $kind = Get-ScopeKind $sel
            if ($null -ne $kind) { return [PSCustomObject]@{ Combo = $c; Selected = $sel; Kind = $kind } }
        }
        return $null
    }

    $scopeInfo = [ordered]@{ before = $null; after = $null; entire = $null; switched = $false }
    $listItemCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::ListItem)
    $scopeHit = Find-ScopeCombo $toolRoot
    if ($null -eq $scopeHit) {
        # Fallback (old detection): an EXPANDED drop-down lists its items as ListItems; walk up
        # from a partial-scope item to its ComboBox. Only reached when no combo selection is readable.
        $scopeItem = $null
        try {
            foreach ($li in $toolRoot.FindAll($scope::Descendants, $listItemCond)) {
                if ((Get-ScopeKind (Get-UiaName $li)) -eq 'partial') { $scopeItem = $li; break }
            }
        }
        catch { $scopeItem = $null }
        if ($null -ne $scopeItem) {
            try {
                $up = $scopeItem
                for ($lvl = 1; $lvl -le 4; $lvl++) {
                    $up = $walker.GetParent($up)
                    if ($null -eq $up) { break }
                    if ($up.Current.ControlType -eq $ct::ComboBox) {
                        $scopeHit = [PSCustomObject]@{ Combo = $up; Selected = (Get-UiaName $scopeItem); Kind = 'partial' }
                        break
                    }
                }
            }
            catch { $scopeHit = $null }
        }
    }
    if ($null -eq $scopeHit) {
        $notes.Add('scope: no Error List scope ComboBox with a readable selection; scope unknown')
    }
    elseif ($scopeHit.Kind -eq 'entire') {
        $scopeInfo.before = $scopeHit.Selected
        $scopeInfo.after = $scopeHit.Selected
        $scopeInfo.entire = $true
        $notes.Add("scope: '$($scopeHit.Selected)' (entire solution, no switch)")
    }
    else {
        $scopeName = $scopeHit.Selected
        $scopeInfo.before = $scopeName
        $scopeInfo.entire = $false
        $combo = $scopeHit.Combo
        $ecp = $null
        try {
            $ecp = Get-UiaPattern $combo ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
            if ($null -eq $ecp) { throw 'scope ComboBox has no ExpandCollapsePattern' }
            $ecp.Expand()
            Start-Sleep -Milliseconds ([Math]::Max(300, $SettleMs))
            # The popup can be a separate top-level window of the process: search the
            # ComboBox first, then every top-level window of the IDE (re-listed).
            # And/OrCondition(params Condition[]): New-Object needs the array as ONE argument
            $entireNames = [System.Windows.Automation.Condition[]]@(
                (New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, '整個方案')),
                (New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, 'Entire Solution')))
            $entireNameCond = New-Object System.Windows.Automation.OrCondition -ArgumentList (, $entireNames)
            $entireParts = [System.Windows.Automation.Condition[]]@($listItemCond, $entireNameCond)
            $entireCond = New-Object System.Windows.Automation.AndCondition -ArgumentList (, $entireParts)
            $candidates = [System.Collections.Generic.List[object]]::new()
            try { foreach ($c in $combo.FindAll($scope::Descendants, $entireCond)) { $candidates.Add($c) } } catch { }
            # The drop-down is a popup window; a WPF ComboBox popup is likely an OWNED window
            # (inferred, not measured), which TopLevelOf skips. So every visible window of the pid,
            # owned ones included (UiaScanPidWindows.VisibleOf), is searched; with no candidate
            # the desktop-wide FindAll is tried once when no selectable item was found (#42 review;
            # needs a real-machine check on the zh-TW VS2022 Error List).
            $winsNow = [System.Collections.Generic.List[object]]::new()
            if (([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanPidWindows').Type) {
                foreach ($wh in [TcAutomation.UiaScanPidWindows]::VisibleOf([uint32]$TargetPid)) {
                    try { $we = $ae::FromHandle($wh); if ($null -ne $we) { $winsNow.Add($we) } } catch { }
                }
            }
            else { try { foreach ($we in Get-IdeTopLevelWindows) { $winsNow.Add($we) } } catch { } }
            foreach ($wn in $winsNow) {
                try { foreach ($c in $wn.FindAll($scope::Descendants, $entireCond)) { $candidates.Add($c) } } catch { }
            }
            $selectable = @($candidates | Where-Object { $null -ne (Get-UiaPattern $_ ([System.Windows.Automation.SelectionItemPattern]::Pattern)) }).Count
            if ($selectable -eq 0) {
                $notes.Add("scope popup: no selectable 'Entire Solution' item in the IDE windows; desktop-wide FindAll fallback")
                # windows already searched above are skipped (by native handle)
                $searched = @{}
                foreach ($wn in $winsNow) { try { $searched[[long]$wn.Current.NativeWindowHandle] = $true } catch { } }
                try {
                    foreach ($wn in $ae::RootElement.FindAll($scope::Children, $pidCond)) {
                        $nh = [long]0
                        try { $nh = [long]$wn.Current.NativeWindowHandle } catch { $nh = 0 }
                        if ($nh -ne 0 -and $searched.ContainsKey($nh)) { continue }
                        try { foreach ($c in $wn.FindAll($scope::Descendants, $entireCond)) { $candidates.Add($c) } } catch { }
                    }
                }
                catch { }
            }
            $selected = $false
            foreach ($c in $candidates) {
                # Two '整個方案' items exist after expanding; only one supports SelectionItemPattern.
                $sip = Get-UiaPattern $c ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if ($null -eq $sip) { continue }
                try { $sip.Select(); $selected = $true; break } catch { }
            }
            if (-not $selected) { throw "no selectable 'Entire Solution' item among $($candidates.Count) candidate(s)" }
            Start-Sleep -Milliseconds 1000
            try {
                if ($ecp.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ecp.Collapse() }
            }
            catch { }
            # Readback: the switch counts only when the combo now reports Entire Solution.
            # A combo whose selection is not readable at all (only reachable through the ListItem
            # fallback) cannot be confirmed: entire stays $null (unknown) and the row-count
            # readback of Get-TcBuildErrors decides.
            $after = Get-ComboSelectionName $combo
            $scopeInfo.after = $after
            if ($null -eq $after) {
                $scopeInfo.entire = $null
                $scopeInfo.switched = $true
                $notes.Add("scope: 'Entire Solution' selected (was '$scopeName'), selection not readable back; scope unknown")
            }
            elseif ((Get-ScopeKind $after) -ne 'entire') {
                throw "scope readback after Select() is '$after', not Entire Solution"
            }
            else {
                $scopeInfo.entire = $true
                $scopeInfo.switched = $true
                $notes.Add("scope switched to entire solution (was '$scopeName')")
            }
            # Re-read the grid and the counts for the new scope.
            $g2 = $null
            try { $g2 = $pane.FindFirst($scope::Descendants, $gridCond) } catch { $g2 = $null }
            if ($null -ne $g2) { $grid = $g2 }
            $cb = Find-CountButtons $toolRoot
        }
        catch {
            # entire stays $false: the rows read below are filtered; Get-TcBuildErrors fails closed.
            $notes.Add("scope switch to entire solution failed (scope '$scopeName'): $($_.Exception.Message); the visible rows are filtered")
            if ($null -ne $ecp) {
                try {
                    if ($ecp.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ecp.Collapse() }
                }
                catch { }
            }
        }
    }

    $sevButtons = $cb.Buttons
    $counts = $cb.Counts
    $notes.Add("buttons: errors=$($counts.errors) warnings=$($counts.warnings) messages=$($counts.messages)")

    # --- 4. header row -> column ids ---
    $headerIds = [System.Collections.Generic.List[string]]::new()
    $headerCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::HeaderItem)
    $headerItems = $grid.FindAll($scope::Descendants, $headerCond)
    foreach ($hi in $headerItems) {
        $id = ''
        try { $id = [string]$hi.Current.AutomationId } catch { }
        if ([string]::IsNullOrWhiteSpace($id)) { $id = Get-UiaName $hi }
        $headerIds.Add($id)
    }

    function Resolve-Field {
        param([string]$id)
        switch -Regex ($id) {
            '^(text|description)$'        { return 'description' }
            '^(projectname|project)$'     { return 'project' }
            '^(documentname|file)$'       { return 'file' }
            '^line$'                      { return 'line' }
            '^column$'                    { return 'column' }
            '^(errorcode|code)$'          { return 'code' }
            '^(errorseverity|severity)$'  { return 'severity' }
            default                       { return $null }
        }
    }

    # Column ids in header order WITHOUT the details expander (rows have no cell for it).
    $cellOrder = @($headerIds | Where-Object { $_ -ne 'detailsexpander' })

    function Read-Cell {
        param($cell)
        # value: first Text descendant, else Edit value, else own name
        $textCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Text)
        $t = $null
        try { $t = $cell.FindFirst($scope::Descendants, $textCond) } catch { }
        if ($null -ne $t) { return (Get-UiaName $t) }
        $vp = Get-UiaPattern $cell ([System.Windows.Automation.ValuePattern]::Pattern)
        if ($null -ne $vp) { try { return [string]$vp.Current.Value } catch { } }
        return (Get-UiaName $cell)
    }

    function Read-Row {
        param($row, [string]$severity)
        $desc = Get-UiaName $row
        $fields = @{ severity = $severity; description = $desc; project = $null; file = $null; line = $null; column = $null; code = $null }
        $cells = $null
        try { $cells = $row.FindAll($scope::Children, [System.Windows.Automation.Condition]::TrueCondition) } catch { }
        if ($null -ne $cells) {
            $idx = 0
            foreach ($cell in $cells) {
                $colId = $null
                # Preferred: TableItemPattern -> header item of this cell
                $tip = Get-UiaPattern $cell ([System.Windows.Automation.TableItemPattern]::Pattern)
                if ($null -ne $tip) {
                    try {
                        $hdrs = $tip.Current.GetColumnHeaderItems()
                        if ($null -ne $hdrs -and $hdrs.Count -gt 0) {
                            $colId = [string]$hdrs[0].Current.AutomationId
                            if ([string]::IsNullOrWhiteSpace($colId)) { $colId = Get-UiaName $hdrs[0] }
                        }
                    }
                    catch { }
                }
                # Fallback: GridItemPattern column index into header list
                if ([string]::IsNullOrWhiteSpace($colId)) {
                    $gip = Get-UiaPattern $cell ([System.Windows.Automation.GridItemPattern]::Pattern)
                    if ($null -ne $gip) {
                        try {
                            $c = [int]$gip.Current.Column
                            if ($c -ge 0 -and $c -lt $headerIds.Count) { $colId = $headerIds[$c] }
                        }
                        catch { }
                    }
                }
                # Last resort: positional (header order without the details expander)
                if ([string]::IsNullOrWhiteSpace($colId) -and $idx -lt $cellOrder.Count) { $colId = $cellOrder[$idx] }
                $idx++
                $field = Resolve-Field $colId
                if ($null -eq $field) { continue }
                $val = Read-Cell $cell
                if ($field -eq 'severity') {
                    if ($val -match '(?i)^(error|warning|message)$') { $fields.severity = (Get-Culture).TextInfo.ToTitleCase($val.ToLower()) }
                    continue
                }
                if ($field -eq 'description' -and [string]::IsNullOrWhiteSpace($val)) { continue }
                $fields[$field] = $val
            }
        }
        [PSCustomObject]$fields
    }

    # Read every row of the (virtualised) grid for one severity, scrolling page by page.
    # Junk rows (#138 F1, 實測 2026-11-06, 4026 zh-TW VS2022, report pr138-e026472 F1): right after
    # the scope was switched to 整個方案 a row was read with project / file / line all null and the
    # row's whole accessible name as description ("<text> : 警告. 專案: AxisInterface. 檔案:
    # AxisInterface.plcproj. 行: 1"), apparently a row whose cells were not realised yet. It was
    # counted as a row (22/25 with only 21 real ones, then 26/25 -> success): an unrealised row plus a
    # missed row would match the total (fail open). A junk row is NOT a row: empty description, or no
    # project / file / line / code AND the description has that accessible-name tail. The English
    # tail (": Warning. Project: ...") is inferred, not measured. Rows without a location but with a
    # plain description (XAE build-summary rows) stay real rows: they are part of the button totals.
    $junkTailPattern = '\s:\s*(警告|錯誤|訊息|Warning|Error|Message)\.\s*(專案|Project)\s*:'
    function Test-JunkRow {
        param($Item)
        if ([string]::IsNullOrWhiteSpace([string]$Item.description)) { return $true }
        $noLoc = [string]::IsNullOrWhiteSpace([string]$Item.project) -and [string]::IsNullOrWhiteSpace([string]$Item.file) -and
                 [string]::IsNullOrWhiteSpace([string]$Item.line) -and [string]::IsNullOrWhiteSpace([string]$Item.code)
        return ($noLoc -and ([string]$Item.description) -match $junkTailPattern)
    }

    function Read-Grid {
        param([string]$severity, $seen, $out)
        $truncated = $false
        $rowCond = New-TypeOr @($ct::DataItem, $ct::ListItem)
        $sp = Get-UiaPattern $grid ([System.Windows.Automation.ScrollPattern]::Pattern)
        $scrollable = $false
        if ($null -ne $sp) { try { $scrollable = [bool]$sp.Current.VerticallyScrollable } catch { $scrollable = $false } }
        if ($scrollable) {
            try { $sp.SetScrollPercent([System.Windows.Automation.ScrollPattern]::NoScroll, 0) } catch { }
            Start-Sleep -Milliseconds $SettleMs
        }
        $guard = 0
        $pageNo = 0
        while ($true) {
            $rows = $null
            try { $rows = $grid.FindAll($scope::Children, $rowCond) } catch { $rows = $null }
            if ($null -eq $rows -or $rows.Count -eq 0) {
                try { $rows = $grid.FindAll($scope::Descendants, $rowCond) } catch { $rows = $null }
            }
            if ($null -ne $rows) {
                # De-duplication across scroll pages (a row seen on two pages is one row), but a
                # row listed N times on ONE page is N rows: $seen keeps the highest number of
                # copies of a key seen on a single page, so genuine duplicates are not dropped
                # and do not trip the rows-vs-count readback of Get-TcBuildErrors (#117).
                # Limit: identical rows split ACROSS a page boundary (one copy on each page) look like
                # a scroll overlap and are counted once, so the read can fall short of the button
                # total; the per-page duplicate counts are written to the notes to explain it.
                $pageNo++
                $pageKeys = @{}
                foreach ($r in $rows) {
                    $item = Read-Row $r $severity
                    if (Test-JunkRow $item) { $junkCount.n++; continue }
                    $key = ($item.description + '|' + $item.project + '|' + $item.file + '|' + $item.line + '|' + $item.column)
                    $pageKeys[$key] = 1 + [int]$pageKeys[$key]
                    if ($pageKeys[$key] -le [int]$seen[$key]) { continue }
                    $seen[$key] = $pageKeys[$key]
                    $out.Add($item)
                    if ($out.Count -ge $MaxRows) { $truncated = $true; break }
                }
                $dupKeys = @($pageKeys.Keys | Where-Object { $pageKeys[$_] -gt 1 })
                if ($dupKeys.Count -gt 0) {
                    $dupRows = 0
                    foreach ($k in $dupKeys) { $dupRows += $pageKeys[$k] - 1 }
                    $notes.Add("rows '$severity' page ${pageNo}: $($dupKeys.Count) key(s) listed more than once on the page ($dupRows extra row(s), counted as separate rows; copies split across a page boundary are counted once)")
                }
            }
            if ($truncated) { break }
            if (-not $scrollable) {
                if ($null -eq $sp) { $truncated = $true }
                break
            }
            $before = -1.0
            try { $before = [double]$sp.Current.VerticalScrollPercent } catch { break }
            if ($before -ge 100.0) { break }
            try { $sp.ScrollVertical([System.Windows.Automation.ScrollAmount]::LargeIncrement) } catch { break }
            Start-Sleep -Milliseconds $SettleMs
            $after = -1.0
            try { $after = [double]$sp.Current.VerticalScrollPercent } catch { break }
            if ($after -le $before) { break }
            $guard++
            if ($guard -gt 500) { $truncated = $true; break }
        }
        return $truncated
    }

    function Get-Toggle {
        param($btn)
        $tp = Get-UiaPattern $btn ([System.Windows.Automation.TogglePattern]::Pattern)
        if ($null -eq $tp) { return $null }
        try { return ($tp.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) } catch { return $null }
    }
    function Set-Toggle {
        param($btn, [bool]$on)
        $tp = Get-UiaPattern $btn ([System.Windows.Automation.TogglePattern]::Pattern)
        if ($null -eq $tp) { return $false }
        for ($i = 0; $i -lt 3; $i++) {
            $cur = $null
            try { $cur = ($tp.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) } catch { return $false }
            if ($cur -eq $on) { return $true }
            try { $tp.Toggle() } catch { return $false }
            Start-Sleep -Milliseconds $SettleMs
        }
        return $false
    }

    $wanted = @()
    if ($WantErrors) { $wanted += 'Error' }
    if ($WantWarnings) { $wanted += 'Warning' }
    if ($WantMessages) { $wanted += 'Message' }

    # Read one severity. After a scope switch, or when a junk row was seen, a single read is not
    # trusted (#138 F1: the grid is still realising rows): the severity is read again, one settle
    # interval ($SettleMs) apart, until two consecutive reads give the same count AND that count is
    # the button total; at most $StableMaxReads reads and $StableMaxSec seconds. Not reached -> the
    # severity is listed in $unstable (Get-TcBuildErrors: ERRORLIST_INCOMPLETE) and the last read is kept.
    $StableMaxReads = 4
    $StableMaxSec = 10
    $junkCount = @{ n = 0 }
    $unstable = [System.Collections.Generic.List[string]]::new()
    # Severities where every read returned 0 rows while the button total is > 0 (#138 O5): not
    # "unstable" (the count never moved), reported on its own; still incomplete (fail closed).
    $noRows = [System.Collections.Generic.List[string]]::new()
    function Read-SeverityStable {
        param([string]$Sev, $Total, [bool]$RequireStable, $Out)
        $junkBefore = $junkCount.n
        $first = [System.Collections.Generic.List[object]]::new()
        $trunc = Read-Grid $Sev @{} $first
        $need = $RequireStable -or ($junkCount.n -gt $junkBefore)
        if (-not $need -or $null -eq $Total) {
            foreach ($x in $first) { $Out.Add($x) }
            return $trunc
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $last = $first
        $readCounts = [System.Collections.Generic.List[int]]::new()
        $readCounts.Add($first.Count)
        $stable = $false
        for ($i = 2; $i -le $StableMaxReads -and $sw.Elapsed.TotalSeconds -lt $StableMaxSec; $i++) {
            Start-Sleep -Milliseconds $SettleMs
            $cur = [System.Collections.Generic.List[object]]::new()
            $trunc = Read-Grid $Sev @{} $cur
            $readCounts.Add($cur.Count)
            $prevCount = $last.Count
            $last = $cur
            if ($cur.Count -eq $prevCount -and $cur.Count -eq [int]$Total) { $stable = $true; break }
        }
        foreach ($x in $last) { $Out.Add($x) }
        $allZero = (@($readCounts | Where-Object { $_ -ne 0 }).Count -eq 0) -and [int]$Total -gt 0
        $verdict = if ($stable) { 'stable' } elseif ($allZero) { 'no rows read' } else { 'NOT stable' }
        $notes.Add("rows '$Sev' stability reads: $($readCounts -join ', ') of $Total; $verdict")
        if (-not $stable) { if ($allZero) { $noRows.Add($Sev) } else { $unstable.Add($Sev) } }
        return $trunc
    }

    $rowsOut = [System.Collections.Generic.List[object]]::new()
    $truncatedAny = $false
    $toggleUsed = $false
    $original = @{}
    $canToggle = ($sevButtons.Count -eq 3)
    foreach ($k in @($sevButtons.Keys)) {
        $st = Get-Toggle $sevButtons[$k]
        if ($null -eq $st) { $canToggle = $false } else { $original[$k] = $st }
    }

    try {
        if ($canToggle) {
            $toggleUsed = $true
            foreach ($sev in $wanted) {
                $total = switch ($sev) { 'Error' { $counts.errors } 'Warning' { $counts.warnings } 'Message' { $counts.messages } }
                if ($null -ne $total -and $total -eq 0) { continue }
                # show only this severity
                $ok = $true
                foreach ($k in @('Error', 'Warning', 'Message')) {
                    if (-not (Set-Toggle $sevButtons[$k] ($k -eq $sev))) { $ok = $false }
                }
                if (-not $ok) { $notes.Add("toggle to '$sev' only failed; rows of this pass may carry a wrong severity") }
                Start-Sleep -Milliseconds $SettleMs
                if (Read-SeverityStable $sev $total ([bool]$scopeInfo.switched) $rowsOut) { $truncatedAny = $true }
            }
        }
        else {
            # Cannot isolate: read whatever is shown; severity is known only when exactly
            # one filter button is on.
            $on = @($original.Keys | Where-Object { $original[$_] })
            $sev = if ($on.Count -eq 1) { [string]$on[0] } else { 'Unknown' }
            $notes.Add("severity buttons not toggleable; reading visible rows as '$sev'")
            $seen = @{}
            if (Read-Grid $sev $seen $rowsOut) { $truncatedAny = $true }
        }
    }
    finally {
        # Restore the filter buttons. Runs also when the runspace is being stopped
        # (PipelineStoppedException on timeout): no module helpers, no Start-Sleep (a
        # cmdlet call would re-throw the stop), every button in its own try/catch so
        # a failure on the first one does not leave the others toggled.
        if ($toggleUsed) {
            foreach ($k in @($original.Keys)) {
                try {
                    $tpr = $null
                    if (-not $sevButtons[$k].TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$tpr)) { continue }
                    $isOn = ($tpr.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On)
                    if ($isOn -ne [bool]$original[$k]) {
                        $tpr.Toggle()
                        [System.Threading.Thread]::Sleep($SettleMs)
                    }
                }
                catch { }
            }
        }
    }

    if ($junkCount.n -gt 0) { $notes.Add("junkRows: $($junkCount.n) row(s) without location whose description is the row's accessible name, not counted (#138 F1)") }
    [PSCustomObject]@{
        Found      = $true
        Counts     = [PSCustomObject]@{ errors = $counts.errors; warnings = $counts.warnings; messages = $counts.messages }
        Rows       = $rowsOut.ToArray()
        Truncated  = $truncatedAny
        Headers    = $headerIds.ToArray()
        ToggleUsed = $toggleUsed
        CountsTotalForm = [bool]$cb.TwoNumbers
        Unstable   = $unstable.ToArray()
        NoRows     = $noRows.ToArray()
        JunkRows   = [int]$junkCount.n
        Scope      = [PSCustomObject]$scopeInfo
        Notes      = $notes.ToArray()
    }
}

# Compiler code <- description pattern (Beckhoff InfoSys "Compiler errors" titles).
# Only codes whose message text is unambiguous are listed; everything else stays $null.
$script:TcCompilerCodePatterns = [ordered]@{
    'C0046' = "^Identifier '.+' not defined$"
    'C0018' = "^'.+' is no valid assignment target$"
    'C0032' = "^Cannot convert type '.+' to type '.+'$"
    'C0035' = '^Program name, function or function block instance expected'
    'C0037' = "^'.+' is no input of '.+'$"
    'C0077' = "^Unknown type: '.+'$"
    'C0080' = "^Function block '.+' must be instantiated"
}

function ConvertTo-TcErrorListItem {
    <#
    .SYNOPSIS
        Normalises one raw Error List row (from the UIA scan) into the public item shape:
        severity, code, description, project, file, line, column.
    .DESCRIPTION
        code: the IDE "Code" column when shown, else the first TwinCAT compiler code
        (Cxxxx) or static-analysis code (SAxxxx) found in the description, else $null.
        line / column are [int] or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $desc = [string]$Row.description
    $code = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.code)) { $code = ([string]$Row.code).Trim() }
    if ($null -eq $code) {
        # The XAE Error List has no "Code" column (2026-10-18, TcXaeShell 15.0: only
        # Severity/Description/Project/Project Rank/Path/File/Line/Column/Source), so the
        # compiler code is inferred from the message text: first the known message
        # patterns, then a bare Cxxxx / SAxxxx token in the text OUTSIDE quoted
        # identifiers (a variable called 'C1000_Axis' is not a compiler code).
        foreach ($k in $script:TcCompilerCodePatterns.Keys) {
            if ($desc -match $script:TcCompilerCodePatterns[$k]) { $code = $k; break }
        }
        if ($null -eq $code) {
            $unquoted = $desc -replace "'[^']*'", ' ' -replace '"[^"]*"', ' '
            if ($unquoted -match '\b(C\d{4}|SA\d{4})(?![\w])') { $code = $Matches[1] }
        }
    }

    $line = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.line)) {
        $n = 0
        if ([int]::TryParse(([string]$Row.line).Trim(), [ref]$n)) { $line = $n }
    }
    $column = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.column)) {
        $n = 0
        if ([int]::TryParse(([string]$Row.column).Trim(), [ref]$n)) { $column = $n }
    }

    $file = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.file)) { $file = ([string]$Row.file).Trim() }
    $project = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$Row.project)) { $project = ([string]$Row.project).Trim() }

    [PSCustomObject]@{
        severity    = [string]$Row.severity
        code        = $code
        description = $desc
        project     = $project
        file        = $file
        line        = $line
        column      = $column
    }
}

function Get-TcErrorListShortfall {
    <#
    .SYNOPSIS
        Severities whose rows read from the Error List are fewer than the total on their summary
        button (#117). Returns a List of @{ severity; expected; read } (empty = complete).
    .DESCRIPTION
        Only the requested severities are compared (errors always, warnings with -IncludeWarnings,
        messages with -IncludeMessages); a severity whose button total was not readable ($null) is
        not compared. When the severities were isolated by toggling the filter buttons
        (Scan.ToggleUsed) each one is compared on its own; otherwise all rows read (classified or
        not) are compared with the sum of the requested totals (severity 'total').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Scan,
        [int]$Errors, [int]$Warnings, [int]$Messages, [int]$Unclassified,
        [bool]$IncludeWarnings = $true, [bool]$IncludeMessages = $false
    )
    $out = [System.Collections.Generic.List[object]]::new()
    $c = $Scan.Counts
    if ($null -eq $c) { return , $out }
    # Severities whose repeated reads never settled on the button total (#138 F1): incomplete even
    # when the last read happens to match.
    $unstable = @()
    if ($null -ne $Scan.PSObject.Properties['Unstable']) { $unstable = @($Scan.Unstable) }
    $noRowsSev = @()
    if ($null -ne $Scan.PSObject.Properties['NoRows']) { $noRowsSev = @($Scan.NoRows) }
    $unstableMap = @{ Error = 'errors'; Warning = 'warnings'; Message = 'messages' }
    $pairs = @(
        [PSCustomObject]@{ name = 'errors'; want = $true; read = $Errors },
        [PSCustomObject]@{ name = 'warnings'; want = $IncludeWarnings; read = $Warnings },
        [PSCustomObject]@{ name = 'messages'; want = $IncludeMessages; read = $Messages })
    if ($Scan.ToggleUsed) {
        foreach ($p in $pairs) {
            if (-not $p.want) { continue }
            $expected = $c.($p.name)
            if ($null -eq $expected) { continue }
            $isUnstable = @($unstable | Where-Object { $unstableMap[[string]$_] -eq $p.name }).Count -gt 0
            $isNoRows = @($noRowsSev | Where-Object { $unstableMap[[string]$_] -eq $p.name }).Count -gt 0
            if ($p.read -lt [int]$expected -or $isUnstable -or $isNoRows) {
                $out.Add([PSCustomObject]@{ severity = $p.name; expected = [int]$expected; read = $p.read; unstable = $isUnstable; noRows = $isNoRows })
            }
        }
    }
    else {
        $expected = 0
        foreach ($p in $pairs) {
            if (-not $p.want) { continue }
            if ($null -ne $c.($p.name)) { $expected += [int]$c.($p.name) }
        }
        $read = $Errors + $Warnings + $Messages + $Unclassified
        if ($read -lt $expected) {
            $out.Add([PSCustomObject]@{ severity = 'total'; expected = $expected; read = $read })
        }
    }
    return , $out
}

function Get-TcErrorListReadState {
    <#
    .SYNOPSIS
        How complete a Get-TcBuildErrors result is, for the Build / Test / Clean paths (#117, #138).
    .DESCRIPTION
        Get-TcBuildErrors fails closed with ERRORLIST_INCOMPLETE on ANY shortfall. The build paths
        only need the ERROR rows to be complete; a list that is short of warnings only must not keep
        a build unverified forever. Returned PSCustomObject:
          usable              $true when rows can be taken from Result.data (success, or ERRORLIST_INCOMPLETE)
          errorsComplete      $true when the error rows are complete: success, or ERRORLIST_INCOMPLETE where
                              none of these holds:
                                - an 'errors' shortfall, or a 'total' shortfall (severities not isolated)
                                - the Errors button total was not readable (data.errorsTotalUnknown)
                                - data.scope.entire = $false AND (some shortfall, or no count button in the
                                  "X / Y" form: data.countsTotalForm, #138 N1)
          warningsIncomplete  $true when warnings were read short (data.missingRows has 'warnings')
          incomplete          $true for an ERRORLIST_INCOMPLETE result
          missingRows / scope data.missingRows / data.scope of the result (@() / $null)
          note                a short text for the non-blocking cases (warnings short, scope not Entire
                              Solution with every count matching), else $null
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$Result)
    $state = [PSCustomObject]@{ usable = $false; errorsComplete = $false; warningsIncomplete = $false; incomplete = $false; missingRows = @(); scope = $null; note = $null }
    if ($null -eq $Result) { return $state }
    $d = $Result.data
    if ($null -ne $d -and $null -ne $d.PSObject.Properties['scope']) { $state.scope = $d.scope }
    if ($Result.success) {
        $state.usable = $true
        $state.errorsComplete = $true
        return $state
    }
    $code = $null
    if ($null -ne $Result.error) { $code = [string]$Result.error.code }
    if ($code -ne 'ERRORLIST_INCOMPLETE' -or $null -eq $d -or $null -eq $d.PSObject.Properties['errors']) { return $state }
    $state.usable = $true
    $state.incomplete = $true
    if ($null -ne $d.PSObject.Properties['missingRows']) { $state.missingRows = @($d.missingRows) }
    $sevs = @($state.missingRows | ForEach-Object { [string]$_.severity })
    $errorsShort = ($sevs -contains 'errors') -or ($sevs -contains 'total')
    $totalUnknown = ($null -ne $d.PSObject.Properties['errorsTotalUnknown'] -and [bool]$d.errorsTotalUnknown)
    $scopeFiltered = ($null -ne $state.scope -and $state.scope.entire -eq $false)
    # A filtered scope whose counts all match is only relaxed to a note when the buttons showed
    # "X / Y" (data.countsTotalForm): then Y is the solution total. A single-number button may count
    # the filtered list only, so matching counts prove nothing: stays incomplete (#138 N1, fail closed).
    $totalForm = ($null -ne $d.PSObject.Properties['countsTotalForm'] -and [bool]$d.countsTotalForm)
    $state.errorsComplete = -not ($errorsShort -or $totalUnknown -or ($scopeFiltered -and ($state.missingRows.Count -gt 0 -or -not $totalForm)))
    $state.warningsIncomplete = ($sevs -contains 'warnings')
    if ($state.errorsComplete) {
        $parts = @()
        if ($state.warningsIncomplete) {
            $w = @($state.missingRows | Where-Object { $_.severity -eq 'warnings' })[0]
            $parts += "warnings: $($w.read) of $($w.expected) row(s) read"
        }
        if ($sevs -contains 'messages') {
            $m = @($state.missingRows | Where-Object { $_.severity -eq 'messages' })[0]
            $parts += "messages: $($m.read) of $($m.expected) row(s) read"
        }
        if ($scopeFiltered) { $parts += "scope filter '$($state.scope.after)' is not Entire Solution, but every count matches the rows read" }
        $state.note = "Error List read in part, error rows complete (" + ($parts -join '; ') + ')'
    }
    return $state
}

function Test-TcLibraryManagerItem {
    <#
    .SYNOPSIS
        $true when an Error List item is a "Library Manager" entry (missing / unresolved
        library: file like '*Library Manager', no line number) rather than a PLC code error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Item
    )
    if ($null -eq $Item) { return $false }
    $file = [string]$Item.file
    if ($file -notlike '*Library Manager') { return $false }
    $line = $Item.line
    if ($null -eq $line) { return $true }
    $n = 0
    if ([int]::TryParse(([string]$line).Trim(), [ref]$n)) { return ($n -le 0) }
    return $true
}

# Library-resolution messages listed without a code location. Measured 2026-10-18 (TcXaeShell
# 15.0, GantryCylinder project, English UI): "Could not open library '#System_VisuElemTrace' ..."
# and "Library '#IecSfc' 3.4.2.0 has not been installed" rows with file 'plc.Library Manager' and
# line 0; see docs/troubleshooting.md "BUILD_FAILED". Other UI languages are not measured.
$script:TcLibraryErrorPattern = '(?i)\bCould not open library\b|\bhas not been installed\b'

function Add-TcBuildWarning {
    <#
    .SYNOPSIS
        Adds a warning to a Build-TcProject result: data.warningCodes[] (all, in order),
        data.warningCode / data.warning (the first one) and Write-Warning.
    #>
    [CmdletBinding()]
    param([object]$Data, [string]$Code, [string]$Text)
    if ($null -eq $Data.PSObject.Properties['warningCodes']) {
        $Data | Add-Member -NotePropertyName 'warningCodes' -NotePropertyValue @()
    }
    $Data.warningCodes = @($Data.warningCodes) + $Code
    if ($null -eq $Data.PSObject.Properties['warningCode']) {
        $Data | Add-Member -NotePropertyName 'warningCode' -NotePropertyValue $Code
        $Data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $Text
    }
    Write-Warning $Text
}

function Get-TcErrorItemCategory {
    <#
    .SYNOPSIS
        Category of one Error List item (#23):
          library  a Library Manager row (Test-TcLibraryManagerItem: file like
                   '*Library Manager', no line) or a "Could not open library" message
                   without a line number - a missing / unresolved library, not a code error
          code     any other row with a file - a PLC code error the compiler located
          other    rows without a file (e.g. XAE build-summary rows)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Item
    )
    if ($null -eq $Item) { return 'other' }
    if (Test-TcLibraryManagerItem $Item) { return 'library' }
    $n = 0
    $hasLine = [int]::TryParse(([string]$Item.line).Trim(), [ref]$n) -and $n -gt 0
    if (-not $hasLine -and ([string]$Item.description) -match $script:TcLibraryErrorPattern) { return 'library' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Item.file)) { return 'code' }
    return 'other'
}

# PLC runtime ADS log rows in the Error List (#66). Messages that the PLC application writes with
# ADSLOGSTR & co. are shown in TwinCAT XAE > Error List (InfoSys TF6500 "Debug messages in
# TwinCAT->Error List": the PLC application writes them "using the ADSLOGSTR ... functions",
# https://infosys.beckhoff.com/content/1033/tf6500_tc3_iec60870_5_10x/984578315.html), and
# ADSLOG_MSGTYPE_ERROR / _WARN set their type to error / warning (InfoSys Tc2_System ADSLOGSTR,
# https://infosys.beckhoff.com/content/1033/tcplclib_tc2_system/31033611.html), so they land among
# the Error / Warning rows next to the compiler messages. A compiler message names the File and Line
# that contain the problem (Microsoft Learn, Error List columns File / Line,
# https://learn.microsoft.com/en-us/visualstudio/ide/error-list-window); a runtime log row has none.
# The row text form "'<task>' (<ADS port>): <message>" is 實測 (issue #66, 2026-10-27, VS2022 4026,
# local UmRT, RobustSolutionFrameworkDemo with TcUnit: "'PlcTask' (350): | Successful tests: 6",
# no file, category other); other UI languages / XAE versions are not measured.
$script:TcRuntimeLogPrefixPattern = "^\s*'[^']+'\s*\(\d+\)\s*:"

function Get-TcRuntimeLogKind {
    <#
    .SYNOPSIS
        'runtime' / 'ambiguous' / $null for one Error List row (#66).
    .DESCRIPTION
        runtime    the description starts with "'<task>' (<port>):" ($script:TcRuntimeLogPrefixPattern)
                   AND the row has no file, no line (> 0) and no compiler code: a PLC runtime ADS log
                   row (TcUnit, ADSLOGSTR), not a build message.
        ambiguous  the description has that prefix but the row ALSO has a file, a line or a compiler
                   code: it cannot be told apart, so it stays a build row (fail closed) and gets a note.
        $null      anything else (no prefix): the row is classified as before (Get-TcErrorItemCategory).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Item
    )
    if ($null -eq $Item) { return $null }
    if (([string]$Item.description) -notmatch $script:TcRuntimeLogPrefixPattern) { return $null }
    $n = 0
    $hasLine = [int]::TryParse(([string]$Item.line).Trim(), [ref]$n) -and $n -gt 0
    $hasFile = -not [string]::IsNullOrWhiteSpace([string]$Item.file)
    $hasCode = -not [string]::IsNullOrWhiteSpace([string]$Item.code)
    if ($hasFile -or $hasLine -or $hasCode) { return 'ambiguous' }
    return 'runtime'
}

# Abandoned UIA scans (timed out; the STA thread may still be stuck inside UIA).
# Invoke-TcUiaScan parks them here with BeginStop issued; Clear-TcUiaAbandonedScans
# disposes the ones that have since stopped. $script:TcErrorListScanBusy stays $true
# while any of them is still running.
# Error List budget of Build-TcProject / Test-TcPlcProject on EVERY path (#107): an upper bound for
# Get-TcBuildErrors -TimeoutSec, not a wait (the scan returns when it has read the list). The
# success path used to get 8 s; the reporter measured 16.5-17.8 s for the scan on a 4026 VS2022 XAE
# (實測, issue #107), so a successful build came back CODE_NOT_VERIFIED.
$script:TcBuildErrorListTimeoutSec = 30

$script:TcUiaAbandonedScans = [System.Collections.Generic.List[object]]::new()
$script:TcErrorListScanBusy = $false
# Set by Clear-TcUiaAbandonedScans when it had to drop entries it could not handle;
# Get-TcBuildErrors reports it as data.scanCleanupWarning (#75).
$script:TcUiaCleanupWarning = $null
# Set by Clear-TcUiaAbandonedScans when a dropped entry may still be running (its state could
# not be read, or the whole list was reset). Get-TcBuildErrors then does NOT start a new scan in
# that call (ERRORLIST_UNAVAILABLE): a second scan would race the old thread for the
# Errors / Warnings / Messages filter buttons and could read a list with the Errors filter off,
# i.e. errors = 0 on a failed build (false success, CODING_STANDARDS section 2). The next call scans
# normally: the old thread is no longer tracked then, so a residual race remains possible but
# only after one call has already been refused (#75).
$script:TcUiaCleanupMayBeRunning = $false

function Clear-TcUiaAbandonedScans {
    <#
    .SYNOPSIS
        Disposes timed-out UIA scan runspaces that have stopped since; returns the number
        still running (and keeps $script:TcErrorListScanBusy in sync).
    .DESCRIPTION
        Never leaves the list or the busy flag stuck (#75): an entry whose state cannot be
        read or that fails to dispose is dropped (not retried on every call), and if the
        list itself cannot be walked it is reset. Either case is written to Write-Verbose
        and kept in $script:TcUiaCleanupWarning for the caller to report.
        $script:TcUiaCleanupMayBeRunning is $true when a dropped entry may still be running
        (state unreadable / list reset); a dispose failure after the state was read as stopped
        does not set it.
    #>
    [CmdletBinding()]
    param()
    $script:TcUiaCleanupWarning = $null
    $script:TcUiaCleanupMayBeRunning = $false
    $still = [System.Collections.Generic.List[object]]::new()
    $dropped = 0
    try {
        # .ToArray(), not @(): @() on a List[object] built with New-Object threw
        # ArgumentException in PS 5.1.26100 and left this function stuck forever (#75).
        foreach ($entry in $script:TcUiaAbandonedScans.ToArray()) {
            $running = $false
            try {
                $state = $entry.PowerShell.InvocationStateInfo.State
                if ($null -eq $state) { throw 'InvocationStateInfo.State is not available' }
                $running = ($state -eq [System.Management.Automation.PSInvocationState]::Running -or
                            $state -eq [System.Management.Automation.PSInvocationState]::Stopping -or
                            $state -eq [System.Management.Automation.PSInvocationState]::NotStarted)
            }
            catch {
                # State unknown: the thread may still be inside UIA.
                $dropped++
                $script:TcUiaCleanupMayBeRunning = $true
                Write-Verbose "Clear-TcUiaAbandonedScans: dropped scan started $($entry.Started), state unreadable ($($_.Exception.Message))."
                continue
            }
            if ($running) { $still.Add($entry); continue }
            # Stopped: dispose each part on its own so one failure does not skip the other.
            $failed = $false
            try { $entry.PowerShell.Dispose() }
            catch { $failed = $true; Write-Verbose "Clear-TcUiaAbandonedScans: PowerShell.Dispose failed ($($_.Exception.Message))." }
            try { $entry.Runspace.Dispose() }
            catch { $failed = $true; Write-Verbose "Clear-TcUiaAbandonedScans: Runspace.Dispose failed ($($_.Exception.Message))." }
            if ($failed) { $dropped++ }
            else { Write-Verbose "Clear-TcUiaAbandonedScans: disposed scan started $($entry.Started)." }
        }
        if ($dropped -gt 0) {
            $script:TcUiaCleanupWarning = "$dropped abandoned Error List scan(s) could not be inspected or disposed and were dropped (#75)."
        }
    }
    catch {
        $script:TcUiaCleanupMayBeRunning = $true
        $script:TcUiaCleanupWarning = "abandoned Error List scan list could not be walked and was reset; a timed-out UIA thread may still be running ($($_.Exception.Message)) (#75)."
        Write-Verbose "Clear-TcUiaAbandonedScans: $script:TcUiaCleanupWarning"
    }
    finally {
        $script:TcUiaAbandonedScans = $still
        $script:TcErrorListScanBusy = ($still.Count -gt 0)
    }
    return $still.Count
}
function Invoke-TcUiaScan {
    <#
    .SYNOPSIS
        Runs a self-contained UI Automation scriptblock in a new STA runspace with a hard
        timeout. Returns the script output (array) or $null on timeout / failure.
    .DESCRIPTION
        UIA calls can block on the IDE message loop (modal dialog, busy IDE), so they are
        never executed on the caller's thread. On timeout BeginStop is issued (no wait)
        and the PowerShell/Runspace pair is parked in $script:TcUiaAbandonedScans with
        $script:TcErrorListScanBusy = $true; Clear-TcUiaAbandonedScans disposes it once
        the thread has actually stopped (a scriptblock AsyncCallback cannot run on the
        pool thread in PS 5.1 - no default runspace - so disposal is deferred to the
        next call instead). Never throws; errors of the script are reported through
        -ErrorOut (ref) and Write-Verbose.
    .PARAMETER Script
        Scriptblock to run (its ToString() is re-parsed inside the runspace).
    .PARAMETER Arguments
        Positional arguments for the script.
    .PARAMETER TimeoutSec
        Hard timeout.
    .PARAMETER TimedOut
        [ref] bool set to $true when the timeout hit.
    .PARAMETER ErrorOut
        [ref] string receiving the first error of the script, if any.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Script,

        [Parameter()]
        [object[]]$Arguments = @(),

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30,

        [Parameter()]
        [ref]$TimedOut,

        [Parameter()]
        [ref]$ErrorOut
    )

    if ($null -ne $TimedOut) { $TimedOut.Value = $false }
    $ps = $null
    $rs = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($Script.ToString())
        foreach ($a in $Arguments) { $null = $ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
            Write-Verbose "Invoke-TcUiaScan: UIA script did not finish within $TimeoutSec s."
            if ($null -ne $TimedOut) { $TimedOut.Value = $true }
            # Do not block on Stop(): the thread may be stuck inside UIA. Ask it to stop
            # and park the objects; they are disposed by Clear-TcUiaAbandonedScans once
            # the invocation state is no longer Running/Stopping.
            try { $null = $ps.BeginStop($null, $null) } catch { }
            $script:TcUiaAbandonedScans.Add([PSCustomObject]@{ PowerShell = $ps; Runspace = $rs; Started = (Get-Date).ToString('s') })
            $script:TcErrorListScanBusy = $true
            $ps = $null
            $rs = $null
            return $null
        }
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) {
            $err = $ps.Streams.Error[0]
            $msg = [string]$err
            try { if ($null -ne $err.InvocationInfo) { $msg += " (line $($err.InvocationInfo.ScriptLineNumber))" } } catch { }
            Write-Verbose "Invoke-TcUiaScan: script error: $msg"
            if ($null -ne $ErrorOut) { $ErrorOut.Value = $msg }
        }
        if ($null -eq $out) { return $null }
        return @($out)
    }
    catch {
        Write-Verbose "Invoke-TcUiaScan: $($_.Exception.Message)"
        if ($null -ne $ErrorOut) { $ErrorOut.Value = $_.Exception.Message }
        return $null
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
    }
}
