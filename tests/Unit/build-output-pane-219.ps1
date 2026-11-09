# Unit: the build pane of the Output window is found by its GUID, not by its localized name (#219), and
# Build-TcProject returns buildPaneStatus / buildPaneName / buildPaneMessages / warningLines (#218).
# No IDE needed: the DTE Output window is mocked; the real Get-TcBuildOutputPane, Get-TcBuildWarningLines
# and Build-TcProject run. Covers: English pane name, zh-TW pane name ("建置", 實測 2026-11-09 VS2022),
# no pane with the build GUID (not-found), Output window unreadable / Guid unreadable / text unreadable,
# a pane named "Build" with another GUID is NOT taken, warning line filter, and the Build-TcProject fields.
#   powershell.exe -NoProfile -File tests/Unit/build-output-pane-219.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-219-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $stateRoot
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$buildGuid = '{1BD8A850-02D1-11D1-BEE7-00A0C913D1F8}'
# build pane text, verbatim lines of the zh-TW VS2022 4026 build (實測 2026-11-09, AxisInterface copy):
# the UI lines are localized, the compiler's "warning:" is not
$zhText = @(
    '組建已在 9:56 PM 開始...'
    '------ Build started: Application: AxisInterface_Type01_Library.AxisInterface -------'
    'C:\temp\Verify-4026-axis\AxisInterface\Main.TcPOU@ExtendSlotTest(10) : warning: C0139: The code ''arAxisCtrl_gb[1].SyncMode.SyncProfile.CamProfile;'
    '      '
    'C:\temp\Verify-4026-axis\AxisInterface\FB_Json_Converter.TcPOU@JsonStrToObj : warning: C0297: Possible Stack Overflow.'
    'Generate code...'
    '========= 組建: 成功或已更新 2 個，失敗 0 個，略過 0 個=========='
) -join "`r`n"

# --- DTE mock: Windows.Item(vsWindowKindOutput).Object.OutputWindowPanes
function New-Pane([string]$Name, $Guid, [string]$Text, [switch]$GuidThrows, [switch]$TextThrows) {
    $p = [PSCustomObject]@{ Name = $Name; UtText = $Text; UtGuid = $Guid; UtGuidThrows = [bool]$GuidThrows; UtTextThrows = [bool]$TextThrows }
    # a throwing ScriptProperty getter is swallowed by PowerShell, so the unreadable cases use methods via Get-TcComMember's mock path
    $p | Add-Member -MemberType ScriptProperty -Name Guid -Value { if ($this.UtGuidThrows) { $null } else { $this.UtGuid } }
    $doc = [PSCustomObject]@{ Pane = $p; StartPoint = $null; EndPoint = 'END' }
    $start = [PSCustomObject]@{ Pane = $p }
    $start | Add-Member -MemberType ScriptMethod -Name CreateEditPoint -Value {
        $ep = [PSCustomObject]@{ Pane = $this.Pane }
        $ep | Add-Member -MemberType ScriptMethod -Name GetText -Value { param($end) if ($this.Pane.UtTextThrows) { throw 'unit: E_FAIL' }; $this.Pane.UtText }
        $ep
    }
    $doc.StartPoint = $start
    $p | Add-Member -NotePropertyName TextDocument -NotePropertyValue $doc
    $p
}
function New-Dte([object[]]$Panes, [switch]$WindowThrows) {
    $coll = [PSCustomObject]@{ Panes = @($Panes) }
    $coll | Add-Member -MemberType ScriptProperty -Name Count -Value { @($this.Panes).Count }
    $coll | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) $this.Panes[[int]$i - 1] }
    $ow = [PSCustomObject]@{ OutputWindowPanes = $coll }
    $win = [PSCustomObject]@{ Object = $ow; Caption = 'Output' }
    $windows = [PSCustomObject]@{ Win = $win; Throws = [bool]$WindowThrows }
    $windows | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param($kind)
        if ($this.Throws) { throw 'unit: Windows.Item failed' }
        if ($kind -ne '{34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3}') { throw "unit: unexpected window kind $kind" }
        $this.Win
    }
    # ToolWindows $null like VS2022 out of process (實測 2026-11-09)
    [PSCustomObject]@{ Windows = $windows; ToolWindows = $null }
}
function Read-Pane($Dte) { & $mod { param($d) Get-TcBuildOutputPane -Dte $d } $Dte }

$tfs = New-Pane '原始檔控制 - Team Foundation' '{0EE13505-C0BC-40C3-8F1D-0F65A9F71616}' 'x' -TextThrows
$general = New-Pane 'General' '{3C24D581-5591-4884-A571-9FE89915CD64}' 'C:\p\plc.plcproj(1) : warning: The option'

# (1) English UI: pane "Build"
$r = Read-Pane (New-Dte @($tfs, (New-Pane 'Build' $buildGuid "line1`r`nline2"), $general))
Check 'English name: read by guid' ($r.status -eq 'read' -and $r.name -eq 'Build' -and $r.matchedBy -eq 'guid' -and $r.index -eq 2 -and $r.text -eq "line1`r`nline2") (J $r)

# (2) zh-TW UI: pane "建置", same GUID, measured order (Team Foundation pane first)
$r = Read-Pane (New-Dte @($tfs, (New-Pane '建置' $buildGuid $zhText), (New-Pane '建置順序' '{2032B126-7C8D-48AD-8026-0E0348004FC0}' 'order'), $general))
Check 'zh-TW name: read by guid' ($r.status -eq 'read' -and $r.name -eq '建置' -and $r.guid -eq $buildGuid -and $r.text -eq $zhText) (J $r)

# (2b) GUID compared case-insensitively, braces optional
$r = Read-Pane (New-Dte @((New-Pane 'Erstellen' '1bd8a850-02d1-11d1-bee7-00a0c913d1f8' 'de')))
Check 'guid lower case without braces still matches' ($r.status -eq 'read' -and $r.name -eq 'Erstellen') (J $r)

# (3) not found: no pane has the build GUID; a pane NAMED "Build" with another GUID is not taken
$r = Read-Pane (New-Dte @($tfs, (New-Pane 'Build' '{11111111-2222-3333-4444-555555555555}' 'other'), $general))
Check 'not-found: name "Build" with another guid is not taken' ($r.status -eq 'not-found' -and $null -eq $r.name -and $r.text -eq '' -and @($r.panes).Count -eq 3 -and $r.error -match 'build pane Guid') (J $r)

# (3b) no pane at all
$r = Read-Pane (New-Dte @())
Check 'not-found: Output window without panes' ($r.status -eq 'not-found' -and @($r.panes).Count -eq 0) (J $r)

# (4) unreadable: Output window cannot be read
$r = Read-Pane (New-Dte @() -WindowThrows)
Check 'unreadable: Windows.Item throws' ($r.status -eq 'unreadable' -and $r.error -match 'Output window not readable' -and $r.text -eq '') (J $r)

# (4b) unreadable: no pane returns its Guid (no fallback by index)
$r = Read-Pane (New-Dte @((New-Pane 'Build' $buildGuid 't' -GuidThrows), (New-Pane '建置' $buildGuid 't' -GuidThrows)))
Check 'unreadable: no Guid readable, no index fallback' ($r.status -eq 'unreadable' -and $null -eq $r.name -and $r.error -match 'Guid') (J $r)

# (4c) unreadable: build pane found but its text throws
$r = Read-Pane (New-Dte @((New-Pane '建置' $buildGuid 't' -TextThrows)))
Check 'unreadable: build pane text throws' ($r.status -eq 'unreadable' -and $r.name -eq '建置' -and $r.error -match 'not readable') (J $r)

# (4d) unreadable: no DTE
$r = & $mod { Get-TcBuildOutputPane -Dte $null }
Check 'unreadable: no DTE' ($r.status -eq 'unreadable') (J $r)

# (4e) a pane whose Guid is unreadable while others are read and none matches: unreadable, not not-found
$r = Read-Pane (New-Dte @($tfs, (New-Pane 'Build' $buildGuid 't' -GuidThrows), $general))
Check 'unreadable: some Guid null, no match -> not "not-found", error counts the panes' ($r.status -eq 'unreadable' -and $r.error -match '^1 of 3 ') (J $r)

# (4f) mixed: the build pane is among the unreadable ones but another pane matches -> read
$r = Read-Pane (New-Dte @((New-Pane 'x' $buildGuid 't' -GuidThrows), (New-Pane '建置' $buildGuid 'ok')))
Check 'mixed: one Guid null, the build pane readable -> read' ($r.status -eq 'read' -and $r.name -eq '建置' -and $r.text -eq 'ok') (J $r)

# (4g) all Guids read, none matches -> not-found (unchanged)
$r = Read-Pane (New-Dte @($general, $tfs))
Check 'not-found only when every Guid was read' ($r.status -eq 'not-found') (J $r)

# (4h) busy / dead RPC is rethrown so Invoke-TcComRetry can retry: first call 0x80010001, second succeeds
$script:UtBusyCalls = 0
$busyDte = New-Dte @((New-Pane 'Build' $buildGuid 'after retry'))
$busyDte.Windows | Add-Member -MemberType ScriptMethod -Name Item -Force -Value {
    param($kind)
    $global:UtBusyCalls++
    if ($global:UtBusyCalls -eq 1) { throw [System.Runtime.InteropServices.COMException]::new('unit: call rejected', [int]0x80010001) }
    $this.Win
}
$global:UtBusyCalls = 0
$r = & $mod { param($d) Invoke-TcComRetry -MaxRetries 3 -OperationName 'unit read pane' -ScriptBlock { Get-TcBuildOutputPane -Dte $d } } $busyDte
Check 'busy COM error is rethrown, retried by Invoke-TcComRetry, then read' ($r.status -eq 'read' -and $r.text -eq 'after retry' -and $global:UtBusyCalls -eq 2) ("calls=$global:UtBusyCalls " + (J $r))

# --- Get-TcBuildWarningLines
$lines = & $mod { param($t) Get-TcBuildWarningLines -Lines @($t -split "`r`n") } $zhText
Check 'warningLines: the two compiler warning lines' (@($lines).Count -eq 2 -and $lines[0] -match 'C0139' -and $lines[1] -match 'C0297') (J $lines)
$lines = @(& $mod { Get-TcBuildWarningLines -Lines @('Main.cs(3,5): warning CS0168: x', 'The word warning in a description', 'C:\p\MAIN.TcPOU(4) : error: C0046: x') })
Check 'warningLines: MSBuild form yes, bare word / error no' (@($lines).Count -eq 1 -and $lines[0] -match 'CS0168') (J $lines)
$lines = @(& $mod { Get-TcBuildWarningLines -Lines @('see the docs: warning levels are configurable', 'x.TcPOU(1) : warning: C0139: real') })
Check 'warningLines: ": warning" without a compiler code is not a warning line' (@($lines).Count -eq 1 -and $lines[0] -match 'C0139') (J $lines)

# --- Build-TcProject end to end with the mocked pane
$sln = Join-Path $stateRoot 'Demo219\Demo219.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII
& $mod {
    param($s)
    $script:TcSolutionPath = $s
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    function script:Get-TcBuildCoverage {
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @(
            [PSCustomObject]@{ name = 'plc'; uniqueName = 'Demo219\plc\plc.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
        ) }
    }
    function script:Get-TcPlcProjectList { @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    function script:Get-TcBuildErrors {
        [CmdletBinding()]
        param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
        New-TcResult -Success $true -Data ([PSCustomObject]@{ counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @() })
    }
    function script:Invoke-TcComRetry { param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock) & $ScriptBlock }
} $sln
function Set-Dte($Dte) {
    $sb = [PSCustomObject]@{ Polls = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $this.Polls = 0 }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $this.Polls++; if ($this.Polls -le 1) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { 0 }
    $Dte | Add-Member -NotePropertyName Solution -NotePropertyValue ([PSCustomObject]@{ SolutionBuild = $sb }) -Force
    & $mod { param($d) $script:TcDte = $d; $script:TcBuildRequiredLocal = @{} } $Dte
}

Set-Dte (New-Dte @($tfs, (New-Pane '建置' $buildGuid $zhText), $general))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'Build zh-TW: buildPaneStatus read, buildPaneName 建置' ($r.success -and $d.buildPaneStatus -eq 'read' -and $d.buildPaneName -eq '建置') (J $d)
Check 'Build zh-TW: buildPaneMessages = messages, 6 non-empty lines without CR' (@($d.buildPaneMessages).Count -eq 6 -and (J $d.buildPaneMessages) -eq (J $d.messages) -and @($d.buildPaneMessages | Where-Object { $_ -match "`r" }).Count -eq 0) (J $d.buildPaneMessages)
Check 'Build zh-TW: warningLines = the 2 compiler warnings, no buildPaneError' (@($d.warningLines).Count -eq 2 -and $null -eq $d.PSObject.Properties['buildPaneError']) (J $d.warningLines)
Check 'Build zh-TW: fallback warning count from warningLines (Error List mocked empty -> 0 rows read)' ($null -ne $d.PSObject.Properties['warnings']) (J $d.warnings)

Set-Dte (New-Dte @($tfs, (New-Pane 'Build' $buildGuid "a`r`nb : warning: C0001: x"), $general))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'Build English: buildPaneName Build, 1 warning line' ($r.data.buildPaneStatus -eq 'read' -and $r.data.buildPaneName -eq 'Build' -and @($r.data.warningLines).Count -eq 1) (J $r.data)

Set-Dte (New-Dte @($tfs, $general))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'Build not-found: status not-found, buildPaneError + buildPanes, empty lists, build result unchanged' ($r.success -and $d.buildPaneStatus -eq 'not-found' -and $null -eq $d.buildPaneName -and $d.buildPaneError -match 'Guid' -and @($d.buildPanes).Count -eq 2 -and @($d.buildPaneMessages).Count -eq 0 -and @($d.warningLines).Count -eq 0) (J $d)

Set-Dte (New-Dte @() -WindowThrows)
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'Build unreadable: status unreadable with buildPaneError' ($r.data.buildPaneStatus -eq 'unreadable' -and $r.data.buildPaneError -match 'not readable' -and @($r.data.buildPaneMessages).Count -eq 0) (J $r.data)

# --- real samples (2026-11-09): 4026 VS2022 zh-TW has a code, 4024 XAE English has none
$s4026 = "C:\temp\Verify-4026-axis\AxisInterface\Main.TcPOU@LiftingPendulumCurveTest(17) : warning: C0139: The code 'arAxisCtrl_gb[1].SyncMode.SyncProfile.CamProfile;"
$s4024 = "MAIN.TcPOU(41) : warning: The code 'LT_Read;"
$lines = @(& $mod { param($a, $b) Get-TcBuildWarningLines -Lines @($a, $b, 'Generate code...', 'x: warning levels') } $s4026 $s4024)
Check 'warningLines: 4026 sample (C0139) and 4024 sample (no code) both match' (@($lines).Count -eq 2 -and $lines[0] -eq $s4026 -and $lines[1] -eq $s4024) (J $lines)
$lines = @(& $mod { Get-TcBuildWarningLines -Lines @('warning: The code x') })
Check 'warningLines: warning at line start matches' (@($lines).Count -eq 1) (J $lines)

# --- JSON shape: warningLines / messages / buildPaneMessages are always arrays (an if-expression used to unroll them)
foreach ($case in @(
    @{ n = 0; text = "a`r`nb"; wl = '[]' },
    @{ n = 1; text = "a`r`n$s4024"; wl = $null })) {
    Set-Dte (New-Dte @((New-Pane 'Build' $buildGuid $case.text)))
    $r = Build-TcProject -WarningAction SilentlyContinue
    $json = $r.data | ConvertTo-Json -Depth 6 -Compress
    $back = $json | ConvertFrom-Json
    $isArr = { param($v) $v -is [object[]] }
    $okShape = (& $isArr $back.warningLines) -and (& $isArr $back.messages) -and (& $isArr $back.buildPaneMessages) -and @($back.warningLines).Count -eq $case.n
    Check ("Build JSON: $($case.n) warning line(s) -> warningLines is an array of $($case.n)") ($okShape -and $json -match '"warningLines":\[' ) ($json.Substring([Math]::Max(0, $json.IndexOf('"warningLines"')), 60))
}
Set-Dte (New-Dte @($tfs, $general))
$r = Build-TcProject -WarningAction SilentlyContinue
$json = $r.data | ConvertTo-Json -Depth 6 -Compress
Check 'Build JSON: not-found pane -> empty lists are [] not {}' ($json -match '"messages":\[\]' -and $json -match '"buildPaneMessages":\[\]' -and $json -match '"warningLines":\[\]') ''

# --- truncation: 1000 lines (500 warnings) -> last 400 lines kept, warnings filtered from the FULL text then capped at 200
$bigLines = @(1..1000 | ForEach-Object { if ($_ % 2 -eq 0) { "f$_.TcPOU($_) : warning: C0139: w$_" } else { "line $_" } })
Set-Dte (New-Dte @((New-Pane 'Build' $buildGuid ($bigLines -join "`r`n"))))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'Build long: 400 last lines kept, flags + line count before the cap' ($d.buildPaneTruncated -eq $true -and $d.buildPaneLineCount -eq 1000 -and @($d.buildPaneMessages).Count -eq 400 -and $d.buildPaneMessages[-1] -eq 'f1000.TcPOU(1000) : warning: C0139: w1000' -and $d.buildPaneMessages[0] -eq 'line 601' -and @($d.messages).Count -eq 400) ("trunc=$($d.buildPaneTruncated) count=$($d.buildPaneLineCount) n=$(@($d.buildPaneMessages).Count)")
Check 'Build long: warningLines from the full pane (500), capped at 200 with flags' ($d.warningLinesTruncated -eq $true -and $d.warningLinesCount -eq 500 -and @($d.warningLines).Count -eq 200 -and $d.warningLines[0] -match 'w2$') ("n=$(@($d.warningLines).Count) total=$($d.warningLinesCount)")

# the character cap: 100 lines of 1000 chars -> 31 lines fit in 32000 chars
$wide = @(1..100 | ForEach-Object { ('{0:D3}' -f $_) + ('x' * 997) })
Set-Dte (New-Dte @((New-Pane 'Build' $buildGuid ($wide -join "`r`n"))))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
$chars = (@($d.buildPaneMessages) | ForEach-Object { $_.Length + 1 } | Measure-Object -Sum).Sum
Check 'Build wide: 32000-character cap reached first, last line kept' ($d.buildPaneTruncated -eq $true -and $d.buildPaneLineCount -eq 100 -and @($d.buildPaneMessages).Count -eq 31 -and $chars -le 32000 -and $d.buildPaneMessages[-1].StartsWith('100')) ("n=$(@($d.buildPaneMessages).Count) chars=$chars")

# a short pane is not flagged
Set-Dte (New-Dte @((New-Pane 'Build' $buildGuid "a`r`nb")))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'Build short: no truncation flags' ($null -eq $r.data.PSObject.Properties['buildPaneTruncated'] -and $null -eq $r.data.PSObject.Properties['warningLinesTruncated']) (J $r.data.buildPaneMessages)

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
exit [Math]::Min($fail, 255)
