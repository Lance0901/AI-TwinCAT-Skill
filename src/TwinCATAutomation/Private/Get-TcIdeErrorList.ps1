# UI Automation scan of the IDE "Error List" tool window. Runs INSIDE a separate STA
# runspace (Invoke-TcUiaScan), so it must be self-contained: no module functions, no
# $script: state. Same pattern as $script:TcUiaDialogScan (Get-TcIdeModalDialog).
#
# Arguments: target process id, wanted severities (bool Errors/Warnings/Messages),
# max rows per severity, settle time in ms after a toggle/scroll.
# Emits ONE PSCustomObject:
#   Found        - $false when no Error List with a data grid was found in the process
#   Counts       - @{ errors; warnings; messages } parsed from the summary buttons
#                  ("9 Errors", "8 Warnings", "0 of 10 Messages": last number = total)
#   Rows         - [PSCustomObject]@{ severity; description; project; file; line; column; code; raw }
#   Truncated    - $true when the grid has no ScrollPattern (only visible rows read)
#                  or MaxRows was hit
#   Headers      - column AutomationIds seen in the header row
#   ToggleUsed   - $true when the severity buttons were toggled to isolate severities
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
    $notes = New-Object System.Collections.Generic.List[string]

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
    $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    $windows = $ae::RootElement.FindAll($scope::Children, $pidCond)
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
    $nameCond = New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, 'Error List')
    $pane = $null
    $grid = $null
    foreach ($w in $windows) {
        try { if ($w.Current.ClassName -eq '#32770') { continue } } catch { continue }
        $hits = $null
        try { $hits = $w.FindAll($scope::Descendants, $nameCond) } catch { continue }
        if ($null -eq $hits) { continue }
        foreach ($h in $hits) {
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
        $notes.Add("no 'Error List' element with a data grid found in $($windows.Count) window(s)")
        return [PSCustomObject]@{ Found = $false; Counts = $null; Rows = @(); Truncated = $false; Headers = @(); ToggleUsed = $false; Notes = $notes.ToArray() }
    }

    # --- 3. summary / filter buttons ("9 Errors", "8 Warnings", "0 of 10 Messages") ---
    $btnCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Button)
    $buttons = $pane.FindAll($scope::Descendants, $btnCond)
    $sevButtons = @{}
    $counts = [ordered]@{ errors = $null; warnings = $null; messages = $null }
    foreach ($b in $buttons) {
        $n = Get-UiaName $b
        $sev = $null
        if ($n -match '^\s*\d+(\s+of\s+\d+)?\s+Errors?\s*$') { $sev = 'Error' }
        elseif ($n -match '^\s*\d+(\s+of\s+\d+)?\s+Warnings?\s*$') { $sev = 'Warning' }
        elseif ($n -match '^\s*\d+(\s+of\s+\d+)?\s+Messages?\s*$') { $sev = 'Message' }
        if ($null -eq $sev) { continue }
        $nums = @([regex]::Matches($n, '\d+') | ForEach-Object { [int]$_.Value })
        $total = $nums[$nums.Count - 1]
        switch ($sev) {
            'Error'   { $counts.errors = $total }
            'Warning' { $counts.warnings = $total }
            'Message' { $counts.messages = $total }
        }
        $sevButtons[$sev] = $b
    }
    $notes.Add("buttons: errors=$($counts.errors) warnings=$($counts.warnings) messages=$($counts.messages)")

    # --- 4. header row -> column ids ---
    $headerIds = New-Object System.Collections.Generic.List[string]
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
        while ($true) {
            $rows = $null
            try { $rows = $grid.FindAll($scope::Children, $rowCond) } catch { $rows = $null }
            if ($null -eq $rows -or $rows.Count -eq 0) {
                try { $rows = $grid.FindAll($scope::Descendants, $rowCond) } catch { $rows = $null }
            }
            if ($null -ne $rows) {
                foreach ($r in $rows) {
                    $item = Read-Row $r $severity
                    $key = ($item.description + '|' + $item.project + '|' + $item.file + '|' + $item.line + '|' + $item.column)
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                    $out.Add($item)
                    if ($out.Count -ge $MaxRows) { $truncated = $true; break }
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

    $rowsOut = New-Object System.Collections.Generic.List[object]
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
                $seen = @{}
                if (Read-Grid $sev $seen $rowsOut) { $truncatedAny = $true }
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

    [PSCustomObject]@{
        Found      = $true
        Counts     = [PSCustomObject]@{ errors = $counts.errors; warnings = $counts.warnings; messages = $counts.messages }
        Rows       = $rowsOut.ToArray()
        Truncated  = $truncatedAny
        Headers    = $headerIds.ToArray()
        ToggleUsed = $toggleUsed
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

# Abandoned UIA scans (timed out; the STA thread may still be stuck inside UIA).
# Invoke-TcUiaScan parks them here with BeginStop issued; Clear-TcUiaAbandonedScans
# disposes the ones that have since stopped. $script:TcErrorListScanBusy stays $true
# while any of them is still running.
$script:TcUiaAbandonedScans = New-Object System.Collections.Generic.List[object]
$script:TcErrorListScanBusy = $false

function Clear-TcUiaAbandonedScans {
    <#
    .SYNOPSIS
        Disposes timed-out UIA scan runspaces that have stopped since; returns the number
        still running (and keeps $script:TcErrorListScanBusy in sync).
    #>
    [CmdletBinding()]
    param()
    $still = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($script:TcUiaAbandonedScans)) {
        $running = $false
        try {
            $state = $entry.PowerShell.InvocationStateInfo.State
            $running = ($state -eq [System.Management.Automation.PSInvocationState]::Running -or
                        $state -eq [System.Management.Automation.PSInvocationState]::Stopping -or
                        $state -eq [System.Management.Automation.PSInvocationState]::NotStarted)
        }
        catch { $running = $false }
        if ($running) { $still.Add($entry); continue }
        try { $entry.PowerShell.Dispose() } catch { }
        try { $entry.Runspace.Dispose() } catch { }
        Write-Verbose "Clear-TcUiaAbandonedScans: disposed scan started $($entry.Started)."
    }
    $script:TcUiaAbandonedScans = $still
    $script:TcErrorListScanBusy = ($still.Count -gt 0)
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
