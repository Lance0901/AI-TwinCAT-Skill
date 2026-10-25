function Find-TcBlockedSolutionIde {
    <#
    .SYNOPSIS
        Among the busy / unreadable DTE candidates of Connect-TcIde, finds the IDE that has (or
        may have) -SolutionPath open but cannot answer COM (modal dialog / busy), without any
        DTE call.
    .DESCRIPTION
        A blocked IDE answers RPC_E_CALL_REJECTED (0x80010001) or an empty DTE.Version (measured
        2026-10-25, 4024 32-bit XAE Shell with a modal prompt up), so the solution it has open
        cannot be read through COM (issue #29). Evidence that needs no COM call:
          - module-state: the IDE this module was connected to (same pid AND start time) had
            this solution open (-PreviousProcessId / -PreviousStartTime / -PreviousSolution).
          - session-record (Get-TcIdeSolutionRecord): the last Connect-TcIde / Open-TcProject
            on this very process (pid + start time) recorded this solution; another solution
            rules the candidate out (unless a dialog path points into our folder, see below).
          - dialog-path: the dialog text (Get-TcIdeModalDialog, UI Automation with a timeout)
            names a project file (.sln/.tsproj/.plcproj/.TcPOU ...) inside the solution folder
            with no other .sln in between ('outside' when all named project files are elsewhere).
          - window-title: Process.MainWindowTitle (Win32 GetWindowText, not through the blocked
            message loop) starts with the solution name: XAE / VS show "<name> - TcXaeShell" /
            "<name> - Microsoft Visual Studio" (measured 2026-10-25, 4024 XAE Shell and 4026
            VS2022). Same-named copies in other folders look alike (measured 2026-10-25), so a
            title alone is weak.
        A record / module state can be stale (the solution was switched in the GUI), so it only
        counts as STRONG when nothing contradicts it AND a current fact agrees (title starts with
        the solution name, or a dialog path inside the folder): a dialog naming project files
        elsewhere ('outside'), a title that does not start with the solution name, a record of
        another solution, or no current fact at all (empty title, no dialog path) makes it weak. dialog-path is strong unless the title contradicts it. Weak matches are reported
        but never attached by Connect-TcIde.
        A candidate without a known pid is skipped; an unreadable (empty Version, not busy)
        candidate without a dialog is skipped too (most likely an IDE shutting down).
        Limits: 8.3 short names and UNC paths in the dialog text are compared as text after
        GetFullPath (no short-name expansion), so they may give 'none' or 'outside'.
    .PARAMETER Candidates
        Busy / unreadable candidates built by Connect-TcIde (properties pid, progId,
        displayName, Object, optional unreadable).
    .PARAMETER SolutionPath
        Full, normalised path of the .sln that Connect-TcIde was asked for.
    .PARAMETER DialogTimeoutSec
        Upper bound of each UI Automation scan. Default 5.
    .PARAMETER PreviousProcessId / PreviousStartTime / PreviousSolution
        The IDE the module was connected to before this Connect-TcIde (0 / $null = none).
    .OUTPUTS
        One PSCustomObject per matching candidate:
        @{ Candidate; Dialog; MatchedBy ('module-state' | 'session-record' | 'dialog-path' |
        'window-title'); Strong ([bool]); Contradiction ([string] or $null); WindowTitle },
        strong matches first.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [object[]]$Candidates = @(),

        [Parameter(Mandatory)]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$DialogTimeoutSec = 5,

        [Parameter()]
        [int]$PreviousProcessId = 0,

        [Parameter()]
        [object]$PreviousStartTime,

        [Parameter()]
        [string]$PreviousSolution
    )

    $slnName = [IO.Path]::GetFileNameWithoutExtension($SolutionPath)
    $slnDir = [IO.Path]::GetDirectoryName($SolutionPath).TrimEnd('\') + '\'
    $titlePattern = '^' + [regex]::Escape($slnName) + '(\s|$)'

    $hits = @()
    foreach ($c in @($Candidates)) {
        if ($null -eq $c) { continue }
        $cPid = 0
        try { $cPid = [int]$c.pid } catch { $cPid = 0 }
        if ($cPid -le 0) { continue }
        $proc = Get-Process -Id $cPid -ErrorAction SilentlyContinue
        if ($null -eq $proc) { continue }

        $title = ''
        try { $title = [string]$proc.MainWindowTitle } catch { $title = '' }
        $titleState = if ([string]::IsNullOrWhiteSpace($title)) { 'empty' } elseif ($title -match $titlePattern) { 'match' } else { 'mismatch' }

        $moduleSame = $false
        if ($PreviousProcessId -gt 0 -and $cPid -eq $PreviousProcessId -and $null -ne $PreviousStartTime -and
            [string]::Equals($PreviousSolution, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) {
            try { $moduleSame = ([DateTime]$proc.StartTime -eq [DateTime]$PreviousStartTime) } catch { $moduleSame = $false }
        }

        $recorded = Get-TcIdeSolutionRecord -ProcessId $cPid
        $recordVerdict = 'none'
        if (-not [string]::IsNullOrWhiteSpace($recorded)) {
            $recordVerdict = if ([string]::Equals($recorded, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) { 'same' } else { 'other' }
        }

        $dialog = Get-TcIdeModalDialog -ProcessId $cPid -TimeoutSec $DialogTimeoutSec
        $pathVerdict = 'none'
        if ($null -ne $dialog) {
            $paths = @(Get-TcDialogProjectPaths -Text ([string]$dialog.Text))
            if ($paths.Count -gt 0) {
                $inside = @($paths | Where-Object { Test-TcPathInSolution -Path $_ -SolutionDir $slnDir })
                $pathVerdict = if ($inside.Count -gt 0) { 'inside' } else { 'outside' }
            }
        }

        $contradiction = $null
        if ($pathVerdict -eq 'outside') { $contradiction = 'the dialog names project files outside the solution folder' }
        elseif ($titleState -eq 'mismatch') { $contradiction = "the window title '$title' does not start with '$slnName'" }

        $matchedBy = $null
        $strong = $false
        if ($moduleSame -or $recordVerdict -eq 'same') {
            $matchedBy = if ($moduleSame) { 'module-state' } else { 'session-record' }
            # The record of the other kind says another solution: contradiction too.
            if ($null -eq $contradiction -and $recordVerdict -eq 'other') { $contradiction = "the session record says '$recorded'" }
            # Strong only with a CURRENT fact that agrees (title or dialog path): a record /
            # module state alone may be stale (the solution was switched in the GUI).
            if ($null -eq $contradiction -and $titleState -ne 'match' -and $pathVerdict -ne 'inside') {
                $contradiction = 'no current evidence (window title empty, no dialog path) confirms the recorded solution'
            }
            $strong = ($null -eq $contradiction)
        }
        elseif ($recordVerdict -eq 'other') {
            # Recorded with another solution: only a dialog path into our folder keeps it, as weak.
            if ($pathVerdict -eq 'inside') { $matchedBy = 'dialog-path'; $contradiction = "the session record says '$recorded'" }
        }
        elseif ($pathVerdict -eq 'inside') {
            $matchedBy = 'dialog-path'
            $strong = ($titleState -ne 'mismatch')
        }
        elseif ($titleState -eq 'match' -and $pathVerdict -ne 'outside') {
            $matchedBy = 'window-title'
        }
        # An unreadable (not busy) DTE without a dialog is most likely an IDE shutting down.
        $unreadableProp = $c.PSObject.Properties['unreadable']
        if ($null -ne $unreadableProp -and [bool]$unreadableProp.Value -and $null -eq $dialog) { $matchedBy = $null }
        Write-Verbose "Blocked DTE pid=$cPid title='$title'($titleState) module=$moduleSame record=$recordVerdict dialog='$(if ($null -ne $dialog) { $dialog.Title })' paths=$pathVerdict -> $(if ($matchedBy) { "$matchedBy strong=$strong" } else { 'no match' })"
        if ($null -eq $matchedBy) { continue }

        $hits += [PSCustomObject]@{
            Candidate     = $c
            Dialog        = $dialog
            MatchedBy     = $matchedBy
            Strong        = $strong
            Contradiction = $(if ($strong) { $null } else { $contradiction })
            WindowTitle   = $title
        }
    }
    @($hits | Sort-Object -Property @{ Expression = { if ($_.Strong) { 0 } else { 1 } } })
}

function Get-TcDialogProjectPaths {
    <#
    .SYNOPSIS
        Absolute paths of project files (.sln, .tsproj, .plcproj, .TcPOU ...) in a dialog text,
        normalised with GetFullPath. A path never spans another drive letter, so two paths in
        one text are not glued together.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$Text = '')
    $pattern = '(?i)[A-Za-z]:\\(?:(?![A-Za-z]:\\)[^\r\n"''<>|?*])+?\.(?:sln|tsproj|tspproj|plcproj|tmc|xti|TcPOU|TcGVL|TcDUT|TcTTO|TcIO|TcVIS)(?![A-Za-z0-9])'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        try { [IO.Path]::GetFullPath($m.Value) } catch { $m.Value }
    }
}

function Test-TcPathInSolution {
    <#
    .SYNOPSIS
        $true when -Path lies inside -SolutionDir and no OTHER .sln sits in a folder between
        them (a nested copy of a solution, or another solution in a subfolder, is not ours).
        A solution folder that is a drive root never counts (every path would be "inside").
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SolutionDir)
    if ($SolutionDir -match '^[A-Za-z]:\\$') { return $false }
    if (-not $Path.StartsWith($SolutionDir, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    try {
        $dir = [IO.Path]::GetDirectoryName($Path)
        while ($null -ne $dir -and ($dir.TrimEnd('\') + '\').Length -gt $SolutionDir.Length) {
            if (Test-Path -LiteralPath $dir) {
                if (@(Get-ChildItem -LiteralPath $dir -Filter '*.sln' -File -ErrorAction SilentlyContinue).Count -gt 0) { return $false }
            }
            $dir = [IO.Path]::GetDirectoryName($dir)
        }
    }
    catch { return $false }
    $true
}
