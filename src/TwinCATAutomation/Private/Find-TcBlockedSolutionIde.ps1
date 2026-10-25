function Find-TcBlockedSolutionIde {
    <#
    .SYNOPSIS
        Among the busy / unreadable DTE candidates of Connect-TcIde, finds the IDE that has (or
        may have) -SolutionPath open but cannot answer COM (modal dialog / busy), without any
        DTE call.
    .DESCRIPTION
        A blocked IDE answers RPC_E_CALL_REJECTED (0x80010001) or an empty DTE.Version (measured
        2026-10-25, 4024 32-bit XAE Shell with a modal prompt up), so the solution it has open
        cannot be read through COM (issue #29). Evidence that needs no COM call, strongest first:
          1. session record (Get-TcIdeSolutionRecord): an earlier Connect-TcIde connected to this
             very process (pid + start time) with a solution. Same solution -> 'session-record'
             (strong); another solution -> ruled out.
          2. dialog text (Get-TcIdeModalDialog, UI Automation in a runspace with a timeout):
             prompts such as the XAE "The project file '<path>.plcproj' has been modified
             outside of TwinCAT XAE" carry absolute paths. A path inside the solution folder ->
             'dialog-path' (strong); paths that are all outside it -> ruled out.
          3. main window title (Process.MainWindowTitle, Win32 GetWindowText, not through the
             blocked message loop): XAE / VS show "<solution name> - TcXaeShell" /
             "<solution name> - Microsoft Visual Studio" (measured 2026-10-25, 4024 XAE Shell and
             4026 VS2022). Only the NAME is in the title: two copies of the same .sln in
             different folders look alike (measured 2026-10-25: a same-named copy in another
             folder, blocked by the same runtime dialog, matched), so -> 'window-title' is WEAK.
        A candidate without a known pid is skipped. A candidate marked unreadable (empty Version,
        not busy) without a dialog is skipped too: most likely an IDE that is shutting down.
    .PARAMETER Candidates
        Busy / unreadable candidates built by Connect-TcIde (properties pid, progId,
        displayName, Object, optional unreadable).
    .PARAMETER SolutionPath
        Full, normalised path of the .sln that Connect-TcIde was asked for.
    .PARAMETER DialogTimeoutSec
        Upper bound of each UI Automation scan. Default 5.
    .OUTPUTS
        One PSCustomObject per matching candidate:
        @{ Candidate; Dialog (Get-TcIdeModalDialog hashtable or $null); MatchedBy
        ('session-record' | 'dialog-path' | 'window-title'); Strong ([bool]); WindowTitle },
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
        [string]$PreviousSolution
    )

    $slnName = [IO.Path]::GetFileNameWithoutExtension($SolutionPath)
    $slnDir = [IO.Path]::GetDirectoryName($SolutionPath).TrimEnd('\') + '\'
    $projectFilePattern = '(?i)[A-Za-z]:\\[^\r\n"''<>|?*]+?\.(sln|tsproj|tspproj|plcproj|tmc|xti|TcPOU|TcGVL|TcDUT|TcTTO|TcIO|TcVIS)(?![A-Za-z0-9])'
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
        $titleMatch = $title -match $titlePattern

        $recorded = Get-TcIdeSolutionRecord -ProcessId $cPid
        $recordVerdict = 'none'
        if (-not [string]::IsNullOrWhiteSpace($recorded)) {
            $recordVerdict = if ([string]::Equals($recorded, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) { 'same' } else { 'other' }
        }

        $dialog = Get-TcIdeModalDialog -ProcessId $cPid -TimeoutSec $DialogTimeoutSec
        $pathVerdict = 'none'
        if ($null -ne $dialog) {
            # Only project files count (a generic path such as C:\TwinCAT\3.1\... says nothing).
            $paths = @([regex]::Matches([string]$dialog.Text, $projectFilePattern) | ForEach-Object { $_.Value })
            if ($paths.Count -gt 0) {
                $inside = @($paths | Where-Object { Test-TcPathInSolution -Path $_ -SolutionDir $slnDir })
                $pathVerdict = if ($inside.Count -gt 0) { 'inside' } else { 'outside' }
            }
        }

        $matchedBy = $null
        if ($PreviousProcessId -gt 0 -and $cPid -eq $PreviousProcessId -and [string]::Equals($PreviousSolution, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) { $matchedBy = 'module-state' }
        elseif ($recordVerdict -eq 'same') { $matchedBy = 'session-record' }
        elseif ($recordVerdict -eq 'other') { $matchedBy = $null }
        elseif ($pathVerdict -eq 'inside') { $matchedBy = 'dialog-path' }
        elseif ($titleMatch -and $pathVerdict -ne 'outside') { $matchedBy = 'window-title' }
        # An unreadable (not busy) DTE without a dialog is most likely an IDE shutting down.
        $unreadableProp = $c.PSObject.Properties['unreadable']
        if ($null -ne $unreadableProp -and [bool]$unreadableProp.Value -and $null -eq $dialog) { $matchedBy = $null }
        Write-Verbose "Blocked DTE pid=$cPid title='$title' record=$recordVerdict dialog='$(if ($null -ne $dialog) { $dialog.Title })' paths=$pathVerdict -> $(if ($matchedBy) { $matchedBy } else { 'no match' })"
        if ($null -eq $matchedBy) { continue }

        $hits += [PSCustomObject]@{
            Candidate   = $c
            Dialog      = $dialog
            MatchedBy   = $matchedBy
            Strong      = ($matchedBy -ne 'window-title')
            WindowTitle = $title
        }
    }
    @($hits | Sort-Object -Property @{ Expression = { if ($_.Strong) { 0 } else { 1 } } })
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