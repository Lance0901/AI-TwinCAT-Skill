# #281: Connect-TcIde without -SolutionPath / -ProcessId / -TakeOverOrphan attaches the IDE it
# selects (TwinCAT project loaded first, else the first, busy last) only when TcAuto may work in it:
# this module (or an earlier module instance / bridge, launched-ides.json) launched it
# (Test-TcLaunchedIde), or the user agreed to it - shown by an explicit Connect-TcIde -ProcessId <pid>
# earlier in this module instance that Disconnect-TcIde has not released since (consent memory).
# Otherwise (the user may have opened that IDE only to look at it) IDE_ATTACH_CONSENT_REQUIRED:
# nothing attached, no setter called (SilentMode, UserControl, Solution.Open). Nothing is recorded
# for a user's IDE (no launch record, no silent-originals / ide-solutions entry); the only file
# consulted is TcAuto's own launch record (launched-ides.json), which Test-TcLaunchedIde may claim
# for an IDE TcAuto itself launched.
# #281 C: with -SolutionPath (no -ProcessId / -TakeOverOrphan) the same check applies to the IDE
# that already has that .sln open (solution-match, and the #29 blocked IDE recognised by strong
# evidence): not allowed -> IDE_ATTACH_CONSENT_REQUIRED (data.reason 'solution-open-in-non-owned-ide')
# and no second IDE is launched (two IDEs with the same solution overwrite each other's files).
# The consent memory lives in module memory only ($script:TcIdeConsentedIdes, key pid + start time
# via Get-TcIdeProcessKey, so a recycled pid never matches); nothing can pre-fill it.

function Add-TcIdeAttachConsent {
    <#
    .SYNOPSIS
        Remembers (module memory only) that the caller chose IDE process -ProcessId explicitly
        (Connect-TcIde -ProcessId), so a later Connect-TcIde without parameters may attach it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return }
    if ($null -eq $script:TcIdeConsentedIdes) { $script:TcIdeConsentedIdes = @{} }
    $script:TcIdeConsentedIdes[$key] = $true
}

function Remove-TcIdeAttachConsent {
    <#
    .SYNOPSIS
        Forgets the consent for IDE process -ProcessId (Disconnect-TcIde released the connection):
        the next Connect-TcIde without parameters needs -ProcessId again. The key is pid + start
        time (Get-TcIdeProcessKey); when the start time is unreadable (process gone) every entry of
        that pid is removed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0 -or $null -eq $script:TcIdeConsentedIdes -or $script:TcIdeConsentedIdes.Count -eq 0) { return }
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -ne $key) { $script:TcIdeConsentedIdes.Remove($key); return }
    $prefix = "$ProcessId|"
    foreach ($k in @($script:TcIdeConsentedIdes.Keys)) {
        if ([string]$k -like "$prefix*") { $script:TcIdeConsentedIdes.Remove($k) }
    }
}

function Test-TcIdeAttachAllowed {
    <#
    .SYNOPSIS
        $true when Connect-TcIde without -ProcessId may attach IDE process -ProcessId (without
        -SolutionPath, and #281 C the IDE that already has -SolutionPath open): TcAuto launched it
        (Test-TcLaunchedIde) or it is in the consent memory. pid <= 0: $false.
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$ProcessId)
    $p = 0
    try { if ($null -ne $ProcessId) { $p = [int]$ProcessId } } catch { $p = 0 }
    if ($p -le 0) { return $false }
    $key = Get-TcIdeProcessKey -ProcessId $p
    if ($null -ne $key -and $null -ne $script:TcIdeConsentedIdes -and $script:TcIdeConsentedIdes.ContainsKey($key)) { return $true }
    [bool](Test-TcLaunchedIde -ProcessId $p)
}

function New-TcAttachConsentResult {
    <#
    .SYNOPSIS
        IDE_ATTACH_CONSENT_REQUIRED result for the IDEs in -Candidates (objects with pid, progId,
        solution, busy). Reads only Get-Process (start time, main window title): no COM call.
        -Reason: data.reason ('no-solution-path' = Connect-TcIde without -SolutionPath,
        'solution-open-in-non-owned-ide' = #281 C, -SolutionPath is open in the candidate(s));
        -Solution: data.solution (the normalized -SolutionPath, $null without); -HintCode: the hint
        key (IDE_ATTACH_CONSENT_REQUIRED or IDE_ATTACH_CONSENT_REQUIRED_SOLUTION); -Extra: further
        data fields (diagnostics such as the #29 dialog / matchedBy), added after the standard ones.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Candidates = @(),
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ProgId,
        [Parameter()][double]$ConnectSec = 0,
        [Parameter()][ValidateSet('no-solution-path', 'solution-open-in-non-owned-ide')][string]$Reason = 'no-solution-path',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Solution,
        [Parameter()][ValidateSet('IDE_ATTACH_CONSENT_REQUIRED', 'IDE_ATTACH_CONSENT_REQUIRED_SOLUTION')][string]$HintCode = 'IDE_ATTACH_CONSENT_REQUIRED',
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Extra
    )
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($Candidates)) {
        if ($null -eq $c) { continue }
        $p = 0
        try { if ($null -ne $c.pid) { $p = [int]$c.pid } } catch { $p = 0 }
        $isBusy = $false
        try { $isBusy = [bool]$c.busy } catch { $isBusy = $false }
        $sol = [string]$c.solution
        $solutionPath = $null
        if (-not $isBusy -and -not [string]::IsNullOrWhiteSpace($sol) -and $sol -notin '<busy>', '<unreadable>') { $solutionPath = $sol }
        $startTime = $null; $title = $null
        if ($p -gt 0) {
            try {
                $proc = Get-Process -Id $p -ErrorAction Stop
                try { if ($null -ne $proc.StartTime) { $startTime = ([DateTime]$proc.StartTime).ToUniversalTime().ToString('o') } } catch { $startTime = $null }
                try { if ($null -ne $proc.MainWindowTitle) { $title = [string]$proc.MainWindowTitle } } catch { $title = $null }
            }
            catch { $startTime = $null; $title = $null }
        }
        $list.Add([PSCustomObject]@{
                processId       = $p
                progId          = $(if ([string]::IsNullOrWhiteSpace([string]$c.progId)) { $null } else { [string]$c.progId })
                solutionPath    = $solutionPath
                startTime       = $startTime
                mainWindowTitle = $title
            })
    }
    $pids = @($list | ForEach-Object { if ($_.processId -gt 0) { "pid $($_.processId)" } else { 'pid unknown' } }) -join ', '
    $sln = if ([string]::IsNullOrWhiteSpace($Solution)) { $null } else { $Solution }
    $data = [PSCustomObject]@{
        attached        = $false
        launched        = $false
        ownedBySession  = $false
        reason          = $Reason
        solution        = $sln
        requestedProgId = $(if ([string]::IsNullOrWhiteSpace($ProgId)) { $null } else { $ProgId })
        connectSec      = [math]::Round($ConnectSec, 1)
        candidates      = @($list)
    }
    if ($null -ne $Extra) {
        foreach ($k in @($Extra.Keys)) {
            if ($null -eq $data.PSObject.Properties[[string]$k]) { $data | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue $Extra[$k] }
        }
    }
    $message = if ($Reason -eq 'solution-open-in-non-owned-ide') {
        "IDE_ATTACH_CONSENT_REQUIRED: '$sln' is already open in $($list.Count) running IDE(s) not launched by this TcAuto session ($pids). Nothing was attached, none of their settings were changed (SilentMode untouched) and no second IDE was launched."
    }
    else {
        "IDE_ATTACH_CONSENT_REQUIRED: found $($list.Count) running IDE(s) not launched by this TcAuto session ($pids). Nothing was attached and none of their settings were changed (SilentMode untouched)."
    }
    New-TcResult -Success $false -ErrorCode 'IDE_ATTACH_CONSENT_REQUIRED' -Hint (Get-TcErrorHint -Code $HintCode) -Data $data -ErrorMessage $message
}
