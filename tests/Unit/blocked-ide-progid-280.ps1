# Unit (#280 / #281 review 3): Connect-TcIde -ProgId X -SolutionPath S with only a blocked IDE of
# ANOTHER ProgID Y in the ROT (busy RPC_E_CALL_REJECTED, or unreadable = empty DTE.Version) that the
# #29 blocked-owner check would recognise as the owner of S (strong evidence: a modal dialog naming
# a file inside the solution folder, matchedBy dialog-path). -ProgId is strict: Y is not reported
# (no IDE_MODAL_DIALOG / IDE_BUSY for Y, nothing attached) and X is launched (mocked: the launch
# records the ProgID and throws). Control cases without -ProgId show the same ROT does produce the
# #29 answer for Y, so the evidence is effective.
# Everything that could reach a real IDE is mocked inside the module: the ROT (Get-AllComObjects),
# GetActiveObject (Get-ComObject), the launch choice (Resolve-TcLaunchProgId), the launch
# (New-TcIdeInstance), Get-TcIdeProcessId, Get-Process for the fake pids, the modal-dialog scan and
# Stop-Process. Mock shapes: tests/Unit/blocked-solution-ide.ps1 and connect-ide-attach-consent-281.ps1.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/blocked-ide-progid-280.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 700) { $Detail = $Detail.Substring(0, 700) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$root = Join-Path $env:TEMP ("tcauto-unit-280b-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$root = & $mod { param($x) Get-TcLongPath $x } $root
$slnFile = Join-Path $root 'Demo.sln'
Set-Content -LiteralPath $slnFile -Value 'Microsoft Visual Studio Solution File, Format Version 12.00' -Encoding UTF8
$sln = & $mod { param($x) Get-TcLongPath $x } $slnFile

$X = 'TcXaeShell.DTE.17.0'
$Y = 'VisualStudio.DTE.17.0'
$global:Rot280b = @()
$global:Ide280b = @{}   # fake pid -> @{ Title; Dialog }
$global:Launches280b = [System.Collections.ArrayList]::new()
# strong #29 evidence for $sln: the dialog names a file inside the solution folder (dialog-path)
$global:Reload280b = @{ Title = 'Microsoft Visual Studio'; Text = "The project file '$root\Demo\plc\plc.plcproj' has been modified outside of TwinCAT XAE.  Do you want to reload the project?"; Hwnd = 0; Buttons = @() }

& $mod {
    $script:TcLaunchPendingWaitSec = 1
    $script:TcLaunchRotWaitSec = 0
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot280b }
    function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) [void]$global:Launches280b.Add("GAO:$ProgId"); $null }
    function script:Resolve-TcLaunchProgId {
        [CmdletBinding()] param([string]$ProgId, [string]$SolutionPath)
        $out = [PSCustomObject]@{ progId = $null; selectedBy = $null; registered = @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0'); evidence = $null; remoteManagerInstall = $null; errorCode = $null; errorMessage = $null }
        if (-not [string]::IsNullOrWhiteSpace($ProgId)) { $out.progId = $ProgId; $out.selectedBy = 'explicit'; return $out }
        $out.errorCode = 'PROGID_REQUIRED'; $out.errorMessage = 'unit: several IDEs registered'
        $out
    }
    function script:New-TcIdeInstance { [CmdletBinding()] param([string]$ProgId) [void]$global:Launches280b.Add($ProgId); throw 'unit: launching is not allowed in this test' }
    function script:Get-TcIdeProcessId {
        [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
        if ($KnownPid -gt 0) { return @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = 'known-pid' } }
        @{ ProcessId = 0; MainHwnd = [long]0; Source = '' }
    }
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id, [string]$Name)
        if ($PSBoundParameters.ContainsKey('Name')) { return @() }
        if ($global:Ide280b.ContainsKey($Id)) {
            return [PSCustomObject]@{ Id = $Id; Name = 'devenv'; ProcessName = 'devenv'; MainWindowTitle = $global:Ide280b[$Id].Title; MainWindowHandle = [IntPtr]::Zero; StartTime = [DateTime]'2026-11-13T08:00:00' }
        }
        if ($Id -ge 9000 -and $Id -lt 10000 -and $Id -ne $PID) { throw "Cannot find a process with the process identifier $Id." }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) { $ProcessId = [int]$script:TcIdeProcessId }
        if ($global:Ide280b.ContainsKey($ProcessId)) { return $global:Ide280b[$ProcessId].Dialog }
        $null
    }
    function script:Invoke-TcComRetry {
        [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
        if ($OperationName -like 'Read DTE.Version / Solution.FullName*') {
            $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
            if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
        }
        & $script:UnitOrigComRetry @PSBoundParameters
    }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $null }
    function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) throw "unit: Stop-Process $Id is not allowed" }
    function script:Stop-TcLaunchedIde { [CmdletBinding()] param([object]$Dte, [string]$ProgId, [DateTime]$StartedAfter) , @() }
}

# Safety net: every Connect-TcIde below runs against the mocked ROT / GetActiveObject / launch only.
$mocked = & $mod { @('Get-AllComObjects', 'Get-ComObject', 'New-TcIdeInstance', 'Resolve-TcLaunchProgId', 'Find-TcIdeModalDialog') | ForEach-Object { (Get-Item -LiteralPath "function:$_").ScriptBlock.ToString() -match 'Rot280b|Launches280b|Ide280b|unit: several' } }
if (@($mocked | Where-Object { -not $_ }).Count -gt 0) { 'FAIL mocks not installed: refusing to call Connect-TcIde'; exit 1 }

function Set-BlockedY([int]$ProcId, [string]$Mode) {
    # Mode busy: DTE rejects every call; unreadable: empty DTE.Version (#29, measured 2026-10-25)
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version ''
    $o | Add-Member NoteProperty Busy ($Mode -eq 'busy')
    $global:Rot280b = @(@{ DisplayName = "!${Y}:$ProcId"; Object = $o; ProgId = $Y; ProcessId = $ProcId })
    $global:Ide280b = @{ $ProcId = @{ Title = 'Demo - Microsoft Visual Studio'; Dialog = $global:Reload280b } }
}
function Reset-State {
    $global:Rot280b = @(); $global:Ide280b = @{}; $global:Launches280b.Clear()
    & $mod {
        $script:TcIdeProcessId = $null; $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null
        $script:TcIdeStartTime = $null; $script:TcIdeSelectedBy = $null; $script:TcLaunchedIdes = @{}; $script:TcLaunchedIdeSolutions = @{}; $script:TcIdeConsentedIdes = @{}
    }
}
function Get-Conn { & $mod { [PSCustomObject]@{ connected = [bool]$script:TcIdeConnected; dteNull = ($null -eq $script:TcDte); pid = $script:TcIdeProcessId } } }

try {
    foreach ($mode in 'unreadable', 'busy') {
        # control: without -ProgId the #29 check recognises Y as the blocked owner of $sln
        # (#281 C: Y is TcAuto's own IDE here - a blocked IDE TcAuto did not launch would get
        # IDE_ATTACH_CONSENT_REQUIRED instead, connect-ide-attach-consent-281.ps1 C2)
        Reset-State
        Set-BlockedY 9501 $mode
        & $mod { Add-TcLaunchedIde -ProcessId 9501 }
        $r = Connect-TcIde -SolutionPath $sln
        Check "C-$mode control: no -ProgId, blocked Y ($mode) with a dialog-path dialog -> #29 IDE_MODAL_DIALOG for Y, nothing launched" ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.ideProcessId -eq 9501 -and $r.data.matchedBy -eq 'dialog-path' -and @($global:Launches280b | Where-Object { $_ -notlike 'GAO:*' }).Count -eq 0) (J $r)
        $null = Disconnect-TcIde

        # -ProgId X: Y is not a candidate, not reported, not attached; X is launched
        Reset-State
        Set-BlockedY 9501 $mode
        $r = Connect-TcIde -ProgId $X -SolutionPath $sln
        $c = Get-Conn
        $launched = @($global:Launches280b | Where-Object { $_ -notlike 'GAO:*' })
        Check "P-$mode -ProgId X -SolutionPath, only blocked Y ($mode) -> no IDE_MODAL_DIALOG / IDE_BUSY for Y, X launched (mock)" ((-not $r.success) -and $r.error.code -notin 'IDE_MODAL_DIALOG', 'IDE_BUSY', 'MODAL_SCAN_INCOMPLETE' -and $r.error.code -eq 'IDE_LAUNCH_FAILED' -and ($launched -join ',') -eq $X) "$(J $r) launches=$($global:Launches280b -join ',')"
        Check "P-$mode Y not attached (no connection, no pid)" (-not $c.connected -and $c.dteNull -and $null -eq $c.pid) (J $c)
        $null = Disconnect-TcIde

        # -ProgId X -NoLaunch: IDE_NOT_FOUND (requestedProgId X), still not Y's dialog
        Reset-State
        Set-BlockedY 9501 $mode
        $r = Connect-TcIde -ProgId $X -SolutionPath $sln -NoLaunch
        Check "N-$mode -ProgId X -NoLaunch, only blocked Y ($mode) -> IDE_NOT_FOUND, nothing launched or attached" ((-not $r.success) -and $r.error.code -eq 'IDE_NOT_FOUND' -and $r.data.requestedProgId -eq $X -and @($global:Launches280b | Where-Object { $_ -notlike 'GAO:*' }).Count -eq 0 -and -not (Get-Conn).connected) (J $r)
    }
}
finally {
    Reset-State
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Rot280b, Ide280b, Launches280b, Reload280b -Scope Global -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
