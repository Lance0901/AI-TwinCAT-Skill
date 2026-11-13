# #281: Connect-TcIde without -SolutionPath / -ProcessId / -TakeOverOrphan attaches only to an IDE
# TcAuto may work in: one this module (or an earlier module instance / bridge, launched-ides.json)
# launched (Test-TcLaunchedIde), or one the user agreed to - shown by an explicit
# Connect-TcIde -ProcessId <pid> earlier in this module instance (consent memory). Any other running
# IDE (the user may have opened it only to look at it) is reported as IDE_ATTACH_CONSENT_REQUIRED:
# nothing attached, no setter called (SilentMode, UserControl, Solution.Open), no state file written.
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

function Test-TcIdeAttachAllowed {
    <#
    .SYNOPSIS
        $true when Connect-TcIde without -SolutionPath / -ProcessId may attach IDE process -ProcessId:
        TcAuto launched it (Test-TcLaunchedIde) or it is in the consent memory. pid <= 0: $false.
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
    #>
    [CmdletBinding()]
    param(
        [Parameter()][object[]]$Candidates = @(),
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ProgId,
        [Parameter()][double]$ConnectSec = 0
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
    $data = [PSCustomObject]@{
        attached        = $false
        launched        = $false
        ownedBySession  = $false
        requestedProgId = $(if ([string]::IsNullOrWhiteSpace($ProgId)) { $null } else { $ProgId })
        connectSec      = [math]::Round($ConnectSec, 1)
        candidates      = @($list)
    }
    New-TcResult -Success $false -ErrorCode 'IDE_ATTACH_CONSENT_REQUIRED' -Hint (Get-TcErrorHint -Code 'IDE_ATTACH_CONSENT_REQUIRED') -Data $data `
        -ErrorMessage "IDE_ATTACH_CONSENT_REQUIRED: found $($list.Count) running IDE(s) not started by TcAuto ($pids). Nothing was attached and none of their settings were changed (SilentMode untouched)."
}
