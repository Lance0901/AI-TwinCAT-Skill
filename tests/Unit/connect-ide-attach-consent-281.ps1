# Unit: #280 -ProgId restricts the running candidates to that ProgID, #281 Connect-TcIde without
# -SolutionPath / -ProcessId / -TakeOverOrphan attaches only an IDE TcAuto may work in (launched by
# TcAuto, or bound with -ProcessId before = consent memory), no IDE needed.
# Everything that could reach a real IDE is mocked inside the module: the ROT (Get-AllComObjects),
# the GetActiveObject fallback (Get-ComObject), the launch choice (Resolve-TcLaunchProgId) and the
# launch itself (New-TcIdeInstance records the ProgID and throws), the pid lookup
# (Get-TcIdeProcessId), Get-Process for the fake pids 9000..9999, the modal-dialog scan,
# ITcSysManager, the solution platform read and Stop-Process. Mock basis: the ROT / DTE shapes are
# the ones of connect-ide-pid-210.ps1 / blocked-solution-ide.ps1; the setters of the fake DTE only
# record writes [inference: shape of EnvDTE / ITcAutomationSettings as used by Connect-TcIde].
#   A  #280: -ProgId X with X and Y running -> X; only Y -> X launched / -NoLaunch IDE_NOT_FOUND;
#      also with -SolutionPath (Y has the .sln open -> not used)
#   B  #281: only someone else's IDEs -> IDE_ATTACH_CONSENT_REQUIRED, nothing set / written;
#      the selected IDE (TC project first) decides: user IDE selected next to an own one -> consent
#      required, own IDE selected -> attached; GetActiveObject fallback gated too; no IDE -> launch
#   D  consent memory (-ProcessId) until Disconnect-TcIde releases the connection, pid reuse,
#      -SolutionPath unchanged, launch record after a bridge restart, Start-TcLifecycle
#   powershell.exe -NoProfile -File tests/Unit/connect-ide-attach-consent-281.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# #152 N1: the owner id of the (simulated) MCP server; D4 adopts a record of the same owner
$env:TCAUTO_OWNER_ID = 'owner-281'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 700) { $Detail = $Detail.Substring(0, 700) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$root = Join-Path $env:TEMP ("tcauto-unit-281-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$slnDir = Join-Path $root 'a'
New-Item -ItemType Directory -Path $slnDir | Out-Null
$slnFile = Join-Path $slnDir 'A.sln'
Set-Content -LiteralPath $slnFile -Value 'Microsoft Visual Studio Solution File, Format Version 12.00' -Encoding UTF8
$slnA = & $mod { param($x) Get-TcLongPath $x } $slnFile

$X = 'TcXaeShell.DTE.17.0'
$Y = 'VisualStudio.DTE.17.0'
$global:Rot281 = @()
$global:Procs281 = @{}            # fake pid -> @{ Name; StartTime; Title }
$global:Gao281 = @{}              # ProgID -> fake DTE returned by GetActiveObject
$global:Launches281 = [System.Collections.ArrayList]::new()
$global:Writes281 = [System.Collections.ArrayList]::new()   # every setter / Open call: "<what> <pid> <value>"
$global:Steps281 = [System.Collections.ArrayList]::new()    # Start-TcLifecycle steps after ConnectIde

function New-FakeDte([int]$ProcId, [string]$Solution = '', [bool]$TcProject = $false, [bool]$Busy = $false) {
    $projects = New-Object PSObject
    $projects | Add-Member NoteProperty Count $(if ($Solution) { 1 } else { 0 })
    $projects | Add-Member NoteProperty HasTc $TcProject
    $projects | Add-Member ScriptMethod Item { param($i) [PSCustomObject]@{ Object = $(if ($this.HasTc) { 'fake-sysmanager' } else { $null }) } }
    $sol = New-Object PSObject
    $sol | Add-Member NoteProperty FullName $Solution
    $sol | Add-Member NoteProperty IsOpen (-not [string]::IsNullOrEmpty($Solution))
    $sol | Add-Member NoteProperty Projects $projects
    $sol | Add-Member NoteProperty ProcId $ProcId
    $sol | Add-Member ScriptMethod Open { param($p) [void]$global:Writes281.Add("Solution.Open $($this.ProcId) $p"); $this.FullName = $p; $this.IsOpen = $true }
    $settings = New-Object PSObject
    $settings | Add-Member NoteProperty Store $false
    $settings | Add-Member NoteProperty ProcId $ProcId
    $settings | Add-Member ScriptProperty SilentMode { $this.Store } { param($v) [void]$global:Writes281.Add("SilentMode $($this.ProcId) $([bool]$v)"); $this.Store = [bool]$v }
    $o = New-Object PSObject
    $o | Add-Member NoteProperty Version '17.0'
    $o | Add-Member NoteProperty Solution $sol
    $o | Add-Member NoteProperty Busy $Busy
    $o | Add-Member NoteProperty ProcId $ProcId
    $o | Add-Member NoteProperty Settings $settings
    $o | Add-Member ScriptProperty UserControl { $true } { param($v) [void]$global:Writes281.Add("UserControl $($this.ProcId) $v") }
    $o | Add-Member ScriptProperty SuppressUI { $false } { param($v) [void]$global:Writes281.Add("SuppressUI $($this.ProcId) $v") }
    $o | Add-Member ScriptMethod GetObject { param($n) if ($n -eq 'TcAutomationSettings') { , $this.Settings } else { throw "unexpected GetObject('$n')" } }
    $o | Add-Member ScriptMethod Quit { [void]$global:Writes281.Add("Quit $($this.ProcId)") }
    $o
}
function Add-Proc([int]$ProcId, [string]$Name = 'devenv', [string]$Title = '') {
    $global:Procs281[$ProcId] = @{ Name = $Name; StartTime = ([DateTime]'2026-11-13T08:00:00').AddMinutes($ProcId - 9000); Title = $Title }
}
function Add-Ide([int]$ProcId, [string]$ProgId, [string]$Solution = '', [bool]$TcProject = $false, [bool]$Busy = $false, [string]$Title = '') {
    Add-Proc $ProcId $(if ($ProgId -like 'VisualStudio.*') { 'devenv' } else { 'TcXaeShell' }) $Title
    $o = New-FakeDte $ProcId $Solution $TcProject $Busy
    $global:Rot281 = @($global:Rot281) + @(@{ DisplayName = "!${ProgId}:$ProcId"; Object = $o; ProgId = $ProgId; ProcessId = $ProcId })
    $o
}

& $mod {
    $script:TcLaunchPendingWaitSec = 1
    $script:TcLaunchRotWaitSec = 0
    $script:TcSysManagerRetryMs = 20   # #241: Get-TcSysManager is mocked to $null: 10 probes 20 ms apart
    $script:UnitOrigComRetry = ${function:Invoke-TcComRetry}
    function script:Get-AllComObjects { [CmdletBinding()] param([switch]$IncludeDisplayName) $global:Rot281 }
    function script:Get-ComObject { [CmdletBinding()] param([string]$ProgId) if ($global:Gao281.ContainsKey($ProgId)) { return $global:Gao281[$ProgId] }; $null }
    function script:Resolve-TcLaunchProgId {
        [CmdletBinding()] param([string]$ProgId, [string]$SolutionPath)
        $out = [PSCustomObject]@{ progId = $null; selectedBy = $null; registered = @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0'); evidence = $null; remoteManagerInstall = $null; errorCode = $null; errorMessage = $null }
        if (-not [string]::IsNullOrWhiteSpace($ProgId)) { $out.progId = $ProgId; $out.selectedBy = 'explicit'; return $out }
        $out.errorCode = 'PROGID_REQUIRED'; $out.errorMessage = 'unit: several IDEs registered'
        $out
    }
    function script:New-TcIdeInstance { [CmdletBinding()] param([string]$ProgId) [void]$global:Launches281.Add($ProgId); throw 'unit: launching is not allowed in this test' }
    function script:Get-TcIdeProcessId {
        [CmdletBinding()] param([object]$Dte, [string]$ProgId, [int]$KnownPid = 0, [object]$StartedAfter)
        if ($KnownPid -gt 0) { return @{ ProcessId = $KnownPid; MainHwnd = [long]0; Source = 'known-pid' } }
        if ($null -ne $Dte -and $null -ne $Dte.PSObject.Properties['ProcId'] -and [int]$Dte.ProcId -gt 0) { return @{ ProcessId = [int]$Dte.ProcId; MainHwnd = [long]0; Source = 'main-window' } }
        @{ ProcessId = 0; MainHwnd = [long]0; Source = '' }
    }
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id, [string]$Name)
        if ($PSBoundParameters.ContainsKey('Name')) {
            return @($global:Procs281.Keys | Where-Object { $global:Procs281[$_].Name -eq $Name } | ForEach-Object { [PSCustomObject]@{ Id = $_; Name = $Name; ProcessName = $Name; StartTime = $global:Procs281[$_].StartTime } })
        }
        if ($global:Procs281.ContainsKey($Id)) {
            $f = $global:Procs281[$Id]
            return [PSCustomObject]@{ Id = $Id; Name = $f.Name; ProcessName = $f.Name; MainWindowTitle = $f.Title; MainWindowHandle = [IntPtr]::Zero; StartTime = $f.StartTime }
        }
        if ($Id -ge 9000 -and $Id -lt 10000 -and $Id -ne $PID) { throw "Cannot find a process with the process identifier $Id." }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0) $null }
    function script:Invoke-TcComRetry {
        [CmdletBinding()] param([Parameter(Position = 0)][scriptblock]$ScriptBlock, [int]$MaxRetries = 5, [string]$OperationName = 'COM call', [int]$TimeoutSec = 120)
        if ($OperationName -like 'Read DTE.Version / Solution.FullName*') {
            $o = (Get-Variable -Name obj -Scope 1 -ValueOnly)
            if ($o.PSObject.Properties['Busy'] -and $o.Busy) { throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001)." }
        }
        & $script:UnitOrigComRetry @PSBoundParameters
    }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $null }
    function script:Get-TcSolutionPlatform { [CmdletBinding()] param() @{ platform = $null; configuration = $null; projectPlatform = $null } }
    function script:Stop-Process { [CmdletBinding()] param([int]$Id, [switch]$Force) throw "unit: Stop-Process $Id is not allowed" }
    function script:Stop-TcLaunchedIde { [CmdletBinding()] param([object]$Dte, [string]$ProgId, [DateTime]$StartedAfter) , @() }
    # Start-TcLifecycle steps after ConnectIde (D5)
    function script:Build-TcProject { param([int]$TimeoutSec, [string[]]$ExpectedProject) [void]$global:Steps281.Add('Build'); [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ completeBuild = $true } } }
    function script:Enable-TcConfig { param([switch]$Force, [switch]$NoLogin, [int]$TimeoutSec, [string]$Platform, [string[]]$PlcProjectPath) [void]$global:Steps281.Add('Enable'); [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ loggedIn = $true; plcState = 'Run'; plcs = @([PSCustomObject]@{ name = 'PLC1'; projectPath = 'TIPC^PLC1^PLC1 Project'; adsPort = 851; loggedIn = $true; state = 'Run' }) } } }
    function script:Connect-TcAds { param([string]$AmsNetId, [int]$Port) [void]$global:Steps281.Add('Ads'); [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ amsNetId = '5.1.2.3.1.1'; port = 851 } } }
    function script:Get-TcPlcState { param() [void]$global:Steps281.Add('PlcState'); [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ state = 'Run'; adsState = 5 } } }
}

# Safety net: every Connect-TcIde below runs against the mocked ROT / GetActiveObject / launch only.
$mocked = & $mod { @('Get-AllComObjects', 'Get-ComObject', 'New-TcIdeInstance', 'Resolve-TcLaunchProgId') | ForEach-Object { (Get-Item -LiteralPath "function:$_").ScriptBlock.ToString() -match 'Rot281|Gao281|Launches281|unit: several' } }
if (@($mocked | Where-Object { -not $_ }).Count -gt 0) { 'FAIL mocks not installed: refusing to call Connect-TcIde'; exit 1 }

function Reset-State {
    $global:Rot281 = @(); $global:Procs281 = @{}; $global:Gao281 = @{}
    $global:Launches281.Clear(); $global:Writes281.Clear(); $global:Steps281.Clear()
    & $mod {
        Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'launched-ides.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $script:TcLaunchedIdes = @{}; $script:TcLaunchedIdeSolutions = @{}; $script:TcIdeConsentedIdes = @{}
        $script:TcIdeProcessId = $null; $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null
        $script:TcIdeStartTime = $null; $script:TcIdeSelectedBy = $null; $script:TcAutomationSettings = $null; $script:TcSilentModeOriginal = $null
    }
}
function Get-Conn { & $mod { [PSCustomObject]@{ connected = [bool]$script:TcIdeConnected; dteNull = ($null -eq $script:TcDte); pid = $script:TcIdeProcessId; selectedBy = $script:TcIdeSelectedBy } } }
function Get-StateFiles { @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" } | Sort-Object) -join ';' }
function Own([int]$ProcId) { & $mod { param($p) Add-TcLaunchedIde -ProcessId $p } $ProcId }

try {
    # ================= A: #280 =================
    Reset-State
    $null = Add-Ide 9201 $X
    $null = Add-Ide 9202 $Y $slnA $true
    Own 9201
    $r = Connect-TcIde -ProgId $X
    Check 'A1 -ProgId X, X (own) and Y running -> X attached, progIdSelectedBy explicit' ($r.success -and $r.data.ideProcessId -eq 9201 -and $r.data.progId -eq $X -and $r.data.progIdSelectedBy -eq 'explicit' -and $global:Launches281.Count -eq 0) (J $r)
    $null = Disconnect-TcIde

    Reset-State
    $null = Add-Ide 9202 $Y $slnA $true
    $r = Connect-TcIde -ProgId $X
    $c = Get-Conn
    Check 'A2 -ProgId X, only Y running -> Y not used, X launched (mock)' ((-not $r.success) -and $r.error.code -eq 'IDE_LAUNCH_FAILED' -and (@($global:Launches281) -join ',') -eq $X -and -not $c.connected -and @($global:Writes281 | Where-Object { $_ -like '* 9202 *' }).Count -eq 0) "$(J $r) launches=$($global:Launches281 -join ',') writes=$($global:Writes281 -join ',')"

    Reset-State
    $null = Add-Ide 9202 $Y $slnA $true
    $r = Connect-TcIde -ProgId $X -NoLaunch
    Check 'A3 -ProgId X -NoLaunch, only Y running -> IDE_NOT_FOUND, requestedProgId X, Y not attached' ((-not $r.success) -and $r.error.code -eq 'IDE_NOT_FOUND' -and $r.data.requestedProgId -eq $X -and @($r.data.candidates).Count -eq 1 -and $global:Launches281.Count -eq 0 -and -not (Get-Conn).connected -and $global:Writes281.Count -eq 0) (J $r)

    Reset-State
    $null = Add-Ide 9202 $Y $slnA $true
    $r = Connect-TcIde -ProgId $X -SolutionPath $slnA
    Check 'A4 -ProgId X -SolutionPath, Y has that .sln open -> not used (no fall back), X launched' ((-not $r.success) -and (@($global:Launches281) -join ',') -eq $X -and -not (Get-Conn).connected -and @($global:Writes281 | Where-Object { $_ -like '* 9202 *' }).Count -eq 0) "$(J $r) launches=$($global:Launches281 -join ',')"

    # ================= B: #281 =================
    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true $false 'A - Microsoft Visual Studio'
    $null = Add-Ide 9102 $X '' $false $true 'TcXaeShell'
    $before = Get-StateFiles
    $r = Connect-TcIde
    $after = Get-StateFiles
    $c = Get-Conn
    $c1 = @($r.data.candidates | Where-Object { $_.processId -eq 9101 }) | Select-Object -First 1
    $c2 = @($r.data.candidates | Where-Object { $_.processId -eq 9102 }) | Select-Object -First 1
    Check 'B1a only user IDEs -> IDE_ATTACH_CONSENT_REQUIRED, message prefix, hint set' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and $r.error.message.StartsWith('IDE_ATTACH_CONSENT_REQUIRED: ') -and -not [string]::IsNullOrWhiteSpace($r.error.hint) -and $r.error.hint -match 'ProcessId') (J $r.error)
    Check 'B1b data: attached / launched / ownedBySession false, requestedProgId null, connectSec, 2 candidates' ($r.data.attached -eq $false -and $r.data.launched -eq $false -and $r.data.ownedBySession -eq $false -and $null -eq $r.data.requestedProgId -and $null -ne $r.data.connectSec -and @($r.data.candidates).Count -eq 2) (J $r.data)
    Check 'B1c candidate with solution: processId int, progId, solutionPath, startTime UTC o, mainWindowTitle' ($null -ne $c1 -and $c1.processId -is [int] -and $c1.progId -eq $Y -and $c1.solutionPath -eq $slnA -and $c1.startTime -eq ([DateTime]'2026-11-13T08:00:00').AddMinutes(101).ToUniversalTime().ToString('o') -and $c1.mainWindowTitle -eq 'A - Microsoft Visual Studio') (J $c1)
    Check 'B1d busy candidate: solutionPath null, progId, startTime, title' ($null -ne $c2 -and $c2.progId -eq $X -and $null -eq $c2.solutionPath -and -not [string]::IsNullOrWhiteSpace($c2.startTime) -and $c2.mainWindowTitle -eq 'TcXaeShell') (J $c2)
    Check 'B1e nothing set in the IDEs (SilentMode / UserControl / Solution.Open), nothing launched' ($global:Writes281.Count -eq 0 -and $global:Launches281.Count -eq 0) "writes=$($global:Writes281 -join ',')"
    Check 'B1f no connection: TcDte null, TcIdeConnected false, no pid' ($c.dteNull -and -not $c.connected -and $null -eq $c.pid -and $null -eq $c.selectedBy) (J $c)
    Check 'B1g no state file written (launched-ides / silent-originals / ide-solutions)' ($before -eq $after) "before=$before after=$after"
    $mem = & $mod { "$($script:TcLaunchedIdes.Count)|$($script:TcIdeConsentedIdes.Count)|$(if ($null -eq $script:TcSilentOriginals) { 0 } else { $script:TcSilentOriginals.Count })" }
    Check 'B1h no module memory written (launched / consent / silent originals)' ($mem -eq '0|0|0') $mem

    $r = Connect-TcIde -ProgId $Y
    Check 'B1i -ProgId Y (user IDE of that ProgID) -> IDE_ATTACH_CONSENT_REQUIRED, requestedProgId Y, only that candidate' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and $r.data.requestedProgId -eq $Y -and @($r.data.candidates).Count -eq 1 -and @($r.data.candidates)[0].processId -eq 9101 -and $global:Writes281.Count -eq 0 -and $global:Launches281.Count -eq 0) (J $r)

    # Owner spec: the IDE the selection picks (TwinCAT project first, else first, busy last) is not
    # TcAuto's -> not attached; the pool is not narrowed to own IDEs first (#281 review 1)
    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $null = Add-Ide 9203 $Y ''
    Own 9203
    $r = Connect-TcIde
    $c = Get-Conn
    Check 'B2a user IDE with TC project + own empty IDE -> the user one is selected -> IDE_ATTACH_CONSENT_REQUIRED, candidates = only the user IDE, nothing set' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and @($r.data.candidates).Count -eq 1 -and @($r.data.candidates)[0].processId -eq 9101 -and $global:Writes281.Count -eq 0 -and $global:Launches281.Count -eq 0 -and -not $c.connected -and $c.dteNull) "$(J $r) writes=$($global:Writes281 -join ',')"

    Reset-State
    $null = Add-Ide 9101 $Y ''
    $null = Add-Ide 9203 $Y $slnA $true
    Own 9203
    $r = Connect-TcIde
    Check 'B2b own IDE with TC project + user empty IDE -> the own one selected and attached, user IDE untouched' ($r.success -and $r.data.ideProcessId -eq 9203 -and $r.data.selectedBy -eq 'twincat-project-loaded' -and $r.data.ownedBySession -eq $true -and @($global:Writes281 | Where-Object { $_ -like '* 9101 *' }).Count -eq 0) "$(J $r) writes=$($global:Writes281 -join ',')"
    $null = Disconnect-TcIde

    Reset-State
    $null = Add-Ide 9203 $Y ''
    Own 9203
    $r = Connect-TcIde
    Check 'B3 only the own IDE -> attached as before, SilentMode set' ($r.success -and $r.data.ideProcessId -eq 9203 -and $r.data.silentMode -eq $true -and @($global:Writes281) -contains 'SilentMode 9203 True') "$(J $r) writes=$($global:Writes281 -join ',')"
    $null = Disconnect-TcIde

    Reset-State
    Add-Proc 9301 'devenv' 'B - Microsoft Visual Studio'
    $global:Gao281[$Y] = New-FakeDte 9301 $slnA $true
    $before = Get-StateFiles
    $r = Connect-TcIde
    $c = Get-Conn
    Check 'B4a ROT empty, GetActiveObject finds a user IDE -> IDE_ATTACH_CONSENT_REQUIRED, candidate pid 9301, nothing set' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and @($r.data.candidates).Count -eq 1 -and @($r.data.candidates)[0].processId -eq 9301 -and @($r.data.candidates)[0].progId -eq $Y -and @($r.data.candidates)[0].solutionPath -eq $slnA -and $global:Writes281.Count -eq 0 -and $global:Launches281.Count -eq 0 -and -not $c.connected -and $c.dteNull -and $before -eq (Get-StateFiles)) "$(J $r) writes=$($global:Writes281 -join ',')"
    $global:Gao281[$Y] = New-FakeDte 0 ''
    $r = Connect-TcIde
    Check 'B4b GetActiveObject DTE whose pid is unknown -> IDE_ATTACH_CONSENT_REQUIRED, processId 0' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and @($r.data.candidates)[0].processId -eq 0 -and $null -eq @($r.data.candidates)[0].startTime -and $global:Writes281.Count -eq 0) (J $r)
    $global:Gao281[$Y] = New-FakeDte 9301 $slnA $true
    Own 9301
    $r = Connect-TcIde
    Check 'B4c GetActiveObject finds an own IDE -> attached (selectedBy as before)' ($r.success -and $r.data.ideProcessId -eq 9301 -and $r.data.ownedBySession -eq $true) (J $r)
    $null = Disconnect-TcIde

    Reset-State
    $r = Connect-TcIde
    Check 'B5a no IDE at all, no -ProgId -> PROGID_REQUIRED as before (launch path), nothing launched' ((-not $r.success) -and $r.error.code -eq 'PROGID_REQUIRED' -and $global:Launches281.Count -eq 0) (J $r)
    $r = Connect-TcIde -ProgId $X
    Check 'B5b no IDE at all, -ProgId X -> X launched (mock) as before' ((-not $r.success) -and $r.error.code -eq 'IDE_LAUNCH_FAILED' -and (@($global:Launches281) -join ',') -eq $X) "$(J $r) launches=$($global:Launches281 -join ',')"
    $r = Connect-TcIde -NoLaunch
    Check 'B5c no IDE, -NoLaunch -> IDE_NOT_FOUND as before' ((-not $r.success) -and $r.error.code -eq 'IDE_NOT_FOUND' -and $null -eq $r.data.requestedProgId) (J $r)

    # ================= D: consent memory and unchanged paths =================
    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $null = Add-Ide 9102 $X '' $false $true
    $r = Connect-TcIde -ProcessId 9101
    Check 'D1 -ProcessId of a user IDE -> attached, selectedBy process-id, not owned' ($r.success -and $r.data.selectedBy -eq 'process-id' -and $r.data.ideProcessId -eq 9101 -and $r.data.ownedBySession -eq $false) (J $r)
    $global:Writes281.Clear()
    $r = Connect-TcIde
    Check 'D2a after D1 (connection not released), Connect-TcIde without parameters -> the same IDE (consent memory), not owned' ($r.success -and $r.data.ideProcessId -eq 9101 -and $r.data.ownedBySession -eq $false -and $r.data.selectedBy -ne 'process-id') (J $r)
    $global:Procs281[9101].StartTime = [DateTime]'2026-11-13T12:34:56'   # pid recycled by a new process
    $global:Writes281.Clear()
    $r = Connect-TcIde
    Check 'D2b same pid, other start time -> consent does not apply (IDE_ATTACH_CONSENT_REQUIRED, nothing set)' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and $global:Writes281.Count -eq 0) (J $r)

    # #281 review 2: Disconnect-TcIde that releases the connection forgets the consent
    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $r = Connect-TcIde -ProcessId 9101
    $d = Disconnect-TcIde
    $global:Writes281.Clear()
    $mem = & $mod { $script:TcIdeConsentedIdes.Count }
    $r = Connect-TcIde
    Check 'D2c -ProcessId -> Disconnect-TcIde -> Connect-TcIde without parameters -> IDE_ATTACH_CONSENT_REQUIRED (consent forgotten), nothing set' ($d.success -and $mem -eq 0 -and (-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and @($r.data.candidates)[0].processId -eq 9101 -and $global:Writes281.Count -eq 0 -and -not (Get-Conn).connected) "mem=$mem $(J $r)"

    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $r = Connect-TcIde -ProcessId 9101
    $d = Disconnect-TcIde -Quit
    $r = Connect-TcIde
    Check 'D2d Disconnect-TcIde -Quit refused (IDE_NOT_OWNED, connection kept) -> consent kept, Connect-TcIde attaches 9101' ((-not $d.success) -and $d.error.code -eq 'IDE_NOT_OWNED' -and $r.success -and $r.data.ideProcessId -eq 9101) "$(J $d.error) $(J $r)"
    $null = Disconnect-TcIde

    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $r = Connect-TcIde -ProcessId 9101
    $global:Procs281.Remove(9101)   # process gone: start time unreadable -> removed by pid prefix
    $d = Disconnect-TcIde
    $mem = & $mod { $script:TcIdeConsentedIdes.Count }
    Check 'D2e Disconnect-TcIde after the IDE process is gone -> consent removed by pid' ($d.success -and $mem -eq 0) "mem=$mem $(J $d)"

    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $r = Connect-TcIde -SolutionPath $slnA
    Check 'D3 -SolutionPath, user IDE has that .sln open -> solution-match attach as before, not owned' ($r.success -and $r.data.selectedBy -eq 'solution-match' -and $r.data.ideProcessId -eq 9101 -and $r.data.ownedBySession -eq $false -and $global:Launches281.Count -eq 0) (J $r)
    $null = Disconnect-TcIde

    # D4: bridge restart - module memory empty, launched-ides.json has a confirmed record of the IDE
    # whose host (bridge pid 9777) is gone, same owner id -> still TcAuto's IDE, attached
    Reset-State
    $null = Add-Ide 9401 $Y ''
    $saveErr = & $mod { Save-TcLaunchRecord -LaunchId 'unit281' -ProcessId 9401 -PidSource 'rot-identity' -ProgId 'VisualStudio.DTE.17.0' -Solution $null -LaunchTime (Get-Date) }
    $recFile = & $mod { Get-TcLaunchRecordPath }
    $recs = @((Get-Content -LiteralPath $recFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
    foreach ($rec in $recs) { $rec.hostPid = 9777; $rec.hostStartTime = '2026-11-13T07:00:00.0000000Z' }
    Set-Content -LiteralPath $recFile -Value (ConvertTo-Json -InputObject @($recs) -Depth 4) -Encoding UTF8
    & $mod { $script:TcLaunchedIdes = @{} }
    $r = Connect-TcIde
    Check 'D4 bridge restart: record of a gone host (same owner) -> no consent needed, attached, owned' ($null -eq $saveErr -and $recs.Count -eq 1 -and $r.success -and $r.data.ideProcessId -eq 9401 -and $r.data.ownedBySession -eq $true) "saveErr=$saveErr $(J $r)"
    $null = Disconnect-TcIde

    # D5: Start-TcLifecycle (ConnectIde without -SolutionPath)
    Reset-State
    $null = Add-Ide 9101 $Y $slnA $true
    $r = Start-TcLifecycle
    $names = @($r.data.steps | ForEach-Object { $_.name }) -join ','
    Check 'D5a Start-TcLifecycle, only a user IDE -> ConnectIde fails IDE_ATTACH_CONSENT_REQUIRED, no later step' ((-not $r.success) -and $r.error.code -eq 'IDE_ATTACH_CONSENT_REQUIRED' -and $r.data.failedStep -eq 'ConnectIde' -and $names -eq 'ConnectIde' -and $global:Steps281.Count -eq 0 -and $global:Writes281.Count -eq 0) "names=$names steps=$($global:Steps281 -join ',') $(J $r.error)"
    $r = Connect-TcIde -ProcessId 9101   # the user agreed; the connection is not released before the lifecycle
    $global:Steps281.Clear()
    $r = Start-TcLifecycle
    $names = @($r.data.steps | ForEach-Object { $_.name }) -join ','
    Check 'D5b after -ProcessId consent -> ConnectIde succeeds, later steps run' ($r.data.steps[0].success -eq $true -and $names -like 'ConnectIde,BuildProject,EnableConfig,*' -and ($global:Steps281 -join ',') -like 'Build,Enable,*') "names=$names steps=$($global:Steps281 -join ',') $(J $r.error)"
    $null = Disconnect-TcIde
}
finally {
    Reset-State
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Rot281, Procs281, Gao281, Launches281, Writes281, Steps281 -Scope Global -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
