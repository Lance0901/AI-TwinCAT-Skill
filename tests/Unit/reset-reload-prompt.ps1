# Unit: Reset-TcSolution handles a reload prompt BEFORE / WHILE it reads Solution.FullName (#87),
# no IDE needed. A mock DTE whose Solution.FullName answers $null while a (mock) modal dialog is up;
# Find-TcIdeModalDialog / Close-TcReloadPrompt / Connect-TcIde are replaced inside the module scope.
#   A1  prompt (project) already up, module solution path known      -> answered Yes, success
#   A2  prompt (project) already up, no solution path known (the path is read from the DTE)
#       -> the modal check runs before the first FullName read, answered Yes, success
#   B   no prompt at the start, FullName $null, the prompt appears while the guard polls
#       -> handled in the poll (Yes), success well below -TimeoutSec
#   C   another modal appears while the guard polls -> IDE_MODAL_DIALOG well below -TimeoutSec
#   D   a file reload prompt appears while the guard polls -> dismissed, close / reopen, success
#   E   guard reads fine, the prompt comes up during the project check (RPC_E_CALL_REJECTED) -> Yes, success
#   F   the project check reads back incomplete (PLC not located, no exception), prompt up -> Yes, success
#   G   the prompt comes up before Solution.Close (DTE.Solution answers $null) -> Yes, success
#   H   Solution.Close fails with another dialog up -> IDE_MODAL_DIALOG, not SOLUTION_CLOSE_FAILED
#   I   the modal scan does not complete (#42) -> MODAL_SCAN_INCOMPLETE, nothing closed
#   J   solution reload prompt (buttons 259 + 1412, #106) -> Ignore (1412), close / reopen, never Reload;
#       J2 Ignore fails -> WM_CLOSE; J3 both fail -> IDE_MODAL_DIALOG, nothing closed
#   K   project prompt, Yes fails twice -> No, close / reopen, WM_CLOSE never used (#135 F4);
#       K2 No fails too -> IDE_MODAL_DIALOG at once, recorded as code-changed (a Yes was sent);
#       K3 first Yes fails, second works; K4 after the Yes failures the next project prompt starts
#       at No; K5 every answer waits at most what is left of -TimeoutSec
#   L   readback before success (#135 F5): not loaded for a few polls -> success after them;
#       never loaded -> SOLUTION_RELOAD_INCOMPLETE within -TimeoutSec (last dialog scan first);
#       L3 a dialog during the wait; L4 IDE_CRASHED during the wait; L5 no .tsproj, no
#       ITcSysManager -> TIPC not required; L6-L9 expected PLCs from the .tsproj on disk (missing
#       for a few polls, never there, no names -> memory baseline, LookupTreeItem throws once)
#   J4/J5, K6/K7 (PR #173 review) Ignore / Yes reaches a disabled prompt (WmCommand not-posted-disabled):
#       no further answer to that hwnd; a nested dialog -> IDE_MODAL_DIALOG for it + possiblyReloaded,
#       none -> IDE_MODAL_DIALOG for the prompt
#   L10/L11 (PR #173 review) .sln without .tsproj: memory baseline -> TIPC required; none -> expectationSource none
#   N   step 5 / Yes-path Connect-TcIde answers MODAL_SCAN_INCOMPLETE -> retried at once (at most 3)
#   O   (#174) a Yes that closed the prompt: Close-TcReloadPrompt -NoFollowUpScan; the first DTE read after
#       the Yes comes after a complete no-modal scan (#181 review): O2 incomplete scans are waited out;
#       O3-O6 a modal right after the Yes is found by the scan, FullName never read under it (Yes path,
#       guard, path read); O7 full path: incomplete scan before Documents.CloseAll -> MODAL_SCAN_INCOMPLETE;
#       O8 every scan incomplete -> RESET_SOLUTION_UNVERIFIED
#   P   (#176) a reload prompt during the readback goes back to step 1: P1 Yes path, P2 after Solution.Open,
#       P3 no prompt before -> Yes-only path after the reopen; P4 / P5 another dialog -> IDE_MODAL_DIALOG;
#       P6 / P7 5 prompts handled already -> IDE_MODAL_DIALOG (Solution.Open site / Yes-path site)
#   M   classification by button control ids 259 + 1412 (language independent)
#   Every solution mock reports a loaded solution (IsOpen, Projects, SolutionBuild.ActiveConfiguration)
#   unless $global:W.NotLoaded > 0 (readback polls after Solution.Open that see Projects.Count 0 /
#   SolutionBuild $null).
#   powershell.exe -NoProfile -File tests/Unit/reset-reload-prompt.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-rrp-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
# CI TEMP may be an 8.3 short name (#43): use the long form the module compares with.
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $stateRoot
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 4 }

$sln = Join-Path $stateRoot 'Demo\Demo.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII
# #135 review S2/S5/S6: solutions that reference a .tsproj (format of the 4024 / 4026 copies, read 2026-11-07)
function New-TsSolution([string]$Name, [string[]]$Plcs) {
    $dir = Join-Path $stateRoot $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'Sys') -Force
    $plcXml = @($Plcs | ForEach-Object { "<Project GUID=`"{2CC04917-125B-4C19-BAC8-BF2C10A34957}`" Name=`"$_`" PrjFilePath=`"$_\$_.plcproj`" AmsPort=`"851`"/>" }) -join ''
    Set-Content -LiteralPath (Join-Path $dir 'Sys\Sys.tsproj') -Encoding ASCII -Value "<?xml version=`"1.0`"?><TcSmProject TcSmVersion=`"1.0`" TcVersion=`"3.1.4026.22`"><Project ProjectGUID=`"{10112974-92E6-3C4B-560E-B30614E05491}`"><Plc>$plcXml</Plc></Project></TcSmProject>"
    $slnPath = Join-Path $dir "$Name.sln"
    Set-Content -LiteralPath $slnPath -Encoding ASCII -Value @('Microsoft Visual Studio Solution File, Format Version 12.00', 'Project("{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}") = "Sys", "Sys\Sys.tsproj", "{10112974-92E6-3C4B-560E-B30614E05491}"', 'EndProject')
    $slnPath
}
$slnTs = New-TsSolution 'TsPlc1' @('PLC1')
$slnTs2 = New-TsSolution 'TsPlc2' @('PLC2')
$slnTsNoName = New-TsSolution 'TsNoName' @()

$projectDlg = @{ Title = 'TcXaeShell'; Text = "The project file 'Demo.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?"; Kind = 'reload-prompt'; ReloadTarget = 'project'; Hwnd = 0; Buttons = @() }
$fileDlg = @{ Title = 'TcXaeShell'; Text = 'MAIN.TcPOU has been changed outside the environment. Reload the new file?'; Kind = 'reload-prompt'; ReloadTarget = 'file'; Hwnd = 0; Buttons = @() }
$otherDlg = @{ Title = 'TcXaeShell'; Text = 'Assertion Failed (mock)'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 0; Buttons = @() }
# a dialog over the reload prompt (own window handle; the prompt mocks have Hwnd 0)
$nestedDlg = @{ Title = 'TcXaeShell'; Text = 'Nested modal (mock)'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 4711; Buttons = @() }
# #106: the VS2022 zh-TW solution prompt as measured 2026-11-03 (title / text as \u escapes)
$zhSolTitle = [regex]::Unescape('\u5075\u6e2c\u5230\u6a94\u6848\u4fee\u6539')
$zhSolText = [regex]::Unescape("\u65b9\u6848 'Demo' \u5df2\u5728\u74b0\u5883\u5916\u90e8\u4fee\u6539\u3002")
$solButtons = @(@{ Id = 259; Name = 'Reload(&R)' }, @{ Id = 1412; Name = 'Ignore(&I)' })
$solutionDlg = @{ Title = $zhSolTitle; Text = $zhSolText; Kind = 'reload-prompt'; ReloadTarget = 'solution'; Hwnd = 0; Buttons = $solButtons }

# World: Dialog = the modal that is up ($null = none); AppearAtRead = FullName read count at which
# AppearDialog comes up; FullName answers $null while a dialog is up. Log = call order.
$global:W = @{}
function Reset-World {
    param([object]$Dialog, [int]$AppearAtRead = 0, [object]$AppearDialog)
    $global:W = @{ Dialog = $Dialog; AppearAtRead = $AppearAtRead; AppearDialog = $AppearDialog; Reads = 0; Log = [System.Collections.Generic.List[string]]::new(); Closed = $false; Opened = $false
        NotLoaded = 0; FailAnswers = @{}; DialogAtLoadPoll = $null; FailSleep = $false; CrashOnLoad = $false; LookupThrow = 0; PlcMissing = 0; ConnectScanFail = 0; DisabledAnswers = @{}
        NoScanFlags = [System.Collections.Generic.List[string]]::new(); ScanIncomplete = 0; ScanIncompleteAfterYes = 0; ChainAfterYes = 0; AfterConnect = [System.Collections.Generic.List[object]]::new()
        AfterYes = [System.Collections.Generic.List[object]]::new(); ScanQueue = [System.Collections.Generic.List[string]]::new(); CleanScanSinceYes = $true; Violations = [System.Collections.Generic.List[string]]::new() }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
    & $mod { $script:TcBuildRequiredLocal = @{} }
}
# Load state of a solution mock (#135 F5): IsOpen, Projects (1 project, .Object $null so
# Get-TcSysManager finds none; Connect-TcIde (mock) sets the ITcSysManager), SolutionBuild with an
# ActiveConfiguration. After Solution.Open, W.NotLoaded polls see Projects.Count 0 and SolutionBuild
# $null (SolutionBuild counts the poll down); W.DialogAtLoadPoll comes up at the first of them.
function Add-LoadState {
    param([object]$Solution)
    $Solution | Add-Member -MemberType ScriptProperty -Name IsOpen -Value { $true }
    $Solution | Add-Member -MemberType ScriptProperty -Name Projects -Value {
        $n = if ($global:W.Opened -and $global:W.NotLoaded -gt 0) { 0 } else { 1 }
        $p = [PSCustomObject]@{ Count = $n }
        # a method, not a property: PowerShell drops exceptions of property getters (CrashOnLoad, review S4)
        $p | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) if ($global:W.Opened -and $global:W.CrashOnLoad) { $global:W.Log.Add('Projects.Item:crash'); throw 'IDE_CRASHED: the IDE process (pid 4242) no longer exists (mock)' }; [PSCustomObject]@{ Name = 'Demo'; UniqueName = 'Demo\Demo.tsproj'; Object = $null } }
        $p
    }
    $Solution | Add-Member -MemberType ScriptProperty -Name SolutionBuild -Value {
        if ($global:W.Opened -and $global:W.NotLoaded -gt 0) {
            $global:W.NotLoaded--
            $global:W.Log.Add('SolutionBuild:null')
            if ($null -ne $global:W.DialogAtLoadPoll) { $global:W.Dialog = $global:W.DialogAtLoadPoll; $global:W.DialogAtLoadPoll = $null }
            return $null
        }
        [PSCustomObject]@{ ActiveConfiguration = [PSCustomObject]@{ Name = 'Release' } }
    }
}
$sol = [PSCustomObject]@{ Mock = $true }
$sol | Add-Member -MemberType ScriptProperty -Name FullName -Value {
    # #181 review: a FullName read after a Yes before a complete scan found no modal is a violation;
    # with a dialog up it would block for ever on the real IDE (mock: 'blocked' instead of $null)
    if (-not $global:W.CleanScanSinceYes) {
        $global:W.Violations.Add("FullName read after a Yes before a complete no-modal scan (dialog up: $($null -ne $global:W.Dialog))")
        if ($null -ne $global:W.Dialog) { $global:W.Log.Add('FullName:BLOCKED'); throw 'blocked (mock: a modal dialog is up, the real DTE call would never return)' }
    }
    $global:W.Reads++
    if ($global:W.AppearAtRead -gt 0 -and $global:W.Reads -ge $global:W.AppearAtRead -and $null -ne $global:W.AppearDialog) {
        $global:W.Dialog = $global:W.AppearDialog; $global:W.AppearDialog = $null
    }
    $global:W.Log.Add("FullName:$(if ($null -ne $global:W.Dialog) { 'null' } else { 'sln' })")
    if ($null -ne $global:W.Dialog) { $null } else { $global:ResetSln }
}
$sol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:W.Log.Add('Solution.Close'); $global:W.Closed = $true }
$sol | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) $global:W.Log.Add('Solution.Open'); $global:W.Opened = $true }
Add-LoadState $sol
$docs = [PSCustomObject]@{ Count = 0 }
$docs | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($m) $global:W.Log.Add('Documents.CloseAll') }
$resetDte = [PSCustomObject]@{ Solution = $sol; Documents = $docs }
$global:ResetSln = $sln
$okSm = [PSCustomObject]@{ Mock = $true }
$okSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) [PSCustomObject]@{ Name = 'TIPC' } }
$global:OkSm = $okSm

$origFns = & $mod { @{ Dlg = ${function:Find-TcIdeModalDialog}; Rp = ${function:Close-TcReloadPrompt}; Conn = ${function:Connect-TcIde} } }
& $mod {
    # W.ScanIncomplete = n: the next n scans do not complete (#42 record, W.Dialog unchanged; #174)
    Set-Item -Path function:script:Find-TcIdeModalDialog -Value { param($ProcessId, $TimeoutSec)
        # W.ScanQueue: the next scans in order ('incomplete' = no result, anything else = a normal scan)
        if ($global:W.ScanQueue.Count -gt 0) { $q = $global:W.ScanQueue[0]; $global:W.ScanQueue.RemoveAt(0); if ($q -eq 'incomplete') { $global:W.Log.Add('Modal:scan-incomplete'); return $global:IncompleteScan } }
        elseif ($global:W.ScanIncomplete -gt 0) { $global:W.ScanIncomplete--; $global:W.Log.Add('Modal:scan-incomplete'); return $global:IncompleteScan }
        if ($null -eq $global:W.Dialog) { $global:W.CleanScanSinceYes = $true }
        $global:W.Log.Add("Modal:$(if ($null -ne $global:W.Dialog) { $global:W.Dialog.Kind } else { 'none' })"); $global:W.Dialog }
    # W.FailAnswers[<answer>] = n: the next n attempts with that answer leave the prompt up ('' = WM_CLOSE);
    # W.FailSleep: such an attempt takes its whole -TimeoutSec (like the real poll, review S1)
    Set-Item -Path function:script:Close-TcReloadPrompt -Value {
        param($Dialog, $Answer, $TimeoutSec, [switch]$NoFollowUpScan)
        $global:W.Log.Add("ClosePrompt:$Answer")
        $global:W.NoScanFlags.Add("$($Answer):$([bool]$NoFollowUpScan)")
        $key = [string]$Answer
        # W.DisabledAnswers[<answer>] = @{ Nested = <dialog or $null> }: the BM_CLICK reaches a disabled
        # prompt (Close-TcMessageBox WmCommand 'not-posted-disabled', #64); Nested comes up over it
        if ($global:W.DisabledAnswers.ContainsKey($key)) {
            $nd = $global:W.DisabledAnswers[$key].Nested
            $global:W.DisabledAnswers.Remove($key)
            if ($null -ne $nd) { $global:W.Dialog = $nd }
            return @{ Sent = $true; Dismissed = $false; NextDialog = $null; Reason = 'mock: dialog still shown'; Method = 'BM_CLICK'; ControlId = 6; BmClick = 'processed-still-open'; WmCommand = 'not-posted-disabled'; SendReason = 'mock: dialog disabled / nested modal, WM_COMMAND not posted' }
        }
        if ($global:W.FailAnswers.ContainsKey($key) -and $global:W.FailAnswers[$key] -gt 0) {
            $global:W.FailAnswers[$key]--
            if ($global:W.FailSleep) { Start-Sleep -Seconds ([int]$TimeoutSec) }
            return @{ Sent = $true; Dismissed = $false; NextDialog = $null; Reason = 'mock: dialog still shown'; Method = 'WM_COMMAND'; ControlId = 6; BmClick = 'processed-still-open'; WmCommand = 'posted-still-open'; SendReason = 'mock send' }
        }
        $global:W.Dialog = $null
        # W.ScanIncompleteAfterYes = n (#174): after a Yes the next n scans do not complete (XAE reloading)
        # W.ChainAfterYes = n: the next n Yes clicks close the prompt and the same prompt is up again at once
        if ($Answer -eq 'Yes' -and $global:W.ChainAfterYes -gt 0) { $global:W.ChainAfterYes--; $global:W.Dialog = $Dialog }
        if ($Answer -eq 'Yes' -and $global:W.ScanIncompleteAfterYes -gt 0) { $global:W.ScanIncomplete = $global:W.ScanIncompleteAfterYes; $global:W.ScanIncompleteAfterYes = 0 }
        # W.AfterYes (#181 review): per Yes click in order, @{ Dialog = <comes up right after it>; Scans = <W.ScanQueue> } (@{} = nothing)
        if ($Answer -eq 'Yes') {
            $global:W.CleanScanSinceYes = $false
            if ($global:W.AfterYes.Count -gt 0) {
                $ay = $global:W.AfterYes[0]; $global:W.AfterYes.RemoveAt(0)
                if ($ay.Contains('Dialog')) { $global:W.Dialog = $ay.Dialog }
                if ($ay.Contains('Scans')) { foreach ($x in $ay.Scans) { $global:W.ScanQueue.Add($x) } }
            }
        }
        @{ Sent = $true; Dismissed = $true; NextDialog = $null; Reason = 'mock'; Method = 'BM_CLICK'; ControlId = 0; BmClick = 'closed'; WmCommand = 'not-needed'; SendReason = 'mock send' }
    }
    # W.ConnectScanFail = n: the next n Connect-TcIde calls answer MODAL_SCAN_INCOMPLETE (4024, 2026-11-07)
    Set-Item -Path function:script:Connect-TcIde -Value { param($SolutionPath, $ProgId, [switch]$NoLaunch)
        if ($global:W.ConnectScanFail -gt 0) {
            $global:W.ConnectScanFail--; $global:W.Log.Add('Connect:scan-incomplete')
            return [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'MODAL_SCAN_INCOMPLETE'; message = 'mock: scan did not finish' }; data = [PSCustomObject]@{ scanComplete = $false } }
        }
        $global:W.Log.Add('Connect')
        # W.AfterConnect (#176): the next dialog comes up right after a successful reconnect, i.e. the readback sees it
        if ($global:W.AfterConnect.Count -gt 0) { $global:W.Dialog = $global:W.AfterConnect[0]; $global:W.AfterConnect.RemoveAt(0) }
        $script:TcSolutionPath = $SolutionPath; $script:TcSysManager = $global:OkSm; [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 0; selectedBy = 'solution-match'; sysManagerAvailable = $true; silentMode = $true } } }
}
function Start-Reset {
    param([string]$ModulePath, [hashtable]$Params = @{}, [int]$TimeoutSec = 10)
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $ModulePath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Reset-TcSolution -TimeoutSec $TimeoutSec @Params
    $global:LastSec = $sw.Elapsed.TotalSeconds
    $r
}
function Get-LogText { $global:W.Log -join ' > ' }

try {
    # --- A1: prompt already up, module path known ---
    Reset-World -Dialog $projectDlg
    $r = Start-Reset -ModulePath $sln
    Check 'A1 prompt up at the start (module path known) -> Yes, success, fast' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $false -and $r.data.reloadTarget -eq 'project' -and $r.data.dismissedReloadPrompt -eq $true -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # --- A2: prompt already up, the path must be read from the DTE ---
    Reset-World -Dialog $projectDlg
    $r = Start-Reset -ModulePath $null
    $log = @($global:W.Log)
    $firstModal = [array]::IndexOf($log, 'Modal:reload-prompt')
    $firstRead = -1; for ($i = 0; $i -lt $log.Count; $i++) { if ($log[$i] -like 'FullName:*') { $firstRead = $i; break } }
    Check 'A2 prompt up, no path known -> modal checked before the first FullName read' ($firstModal -ge 0 -and $firstRead -gt $firstModal) (Get-LogText)
    Check 'A2 prompt up, no path known -> Yes, success, solution read back, fast' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.solution -eq $sln -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # --- B: the prompt appears while the guard polls Solution.FullName ---
    Reset-World -Dialog $null -AppearAtRead 1 -AppearDialog $projectDlg
    $r = Start-Reset -ModulePath $sln
    Check 'B prompt appears during the guard -> answered Yes in the poll, success, well below -TimeoutSec' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reloadTarget -eq 'project' -and $r.data.reopenedSolution -eq $false -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))
    Check 'B nothing closed (Yes-only path)' (-not $global:W.Closed -and -not $global:W.Opened) (Get-LogText)

    # --- B2: the prompt appears on the 3rd read (FullName answers $null twice without a dialog first) ---
    Reset-World -Dialog $null -AppearAtRead 3 -AppearDialog $projectDlg
    # reads 1..2 answer $null without a dialog: model "busy, $null for a moment"
    $global:W.NullReads = 2
    $nullSol = [PSCustomObject]@{ Mock = $true }
    $nullSol | Add-Member -MemberType ScriptProperty -Name FullName -Value {
        $global:W.Reads++
        if ($global:W.Reads -ge $global:W.AppearAtRead -and $null -ne $global:W.AppearDialog) { $global:W.Dialog = $global:W.AppearDialog; $global:W.AppearDialog = $null }
        if ($global:W.Reads -le $global:W.NullReads -or $null -ne $global:W.Dialog) { $global:W.Log.Add('FullName:null'); return $null }
        $global:W.Log.Add('FullName:sln'); $global:ResetSln
    }
    $nullSol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:W.Closed = $true }
    $nullSol | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) $global:W.Opened = $true }
    Add-LoadState $nullSol
    $dteB2 = [PSCustomObject]@{ Solution = $nullSol; Documents = $docs }
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $dteB2 $sln
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Reset-TcSolution -TimeoutSec 10
    $sec = $sw.Elapsed.TotalSeconds
    Check 'B2 FullName $null twice, prompt on the 3rd poll -> handled, success, well below -TimeoutSec' ($r.success -and $r.data.answeredYes -eq $true -and $sec -lt 6) ("{0:N1}s {1} | {2}" -f $sec, (Get-LogText), (J $r))

    # --- C: another modal appears while the guard polls ---
    Reset-World -Dialog $null -AppearAtRead 1 -AppearDialog $otherDlg
    $r = Start-Reset -ModulePath $sln
    Check 'C other modal during the guard -> IDE_MODAL_DIALOG, nothing closed, well below -TimeoutSec' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and -not $global:W.Closed -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))
    Check 'C nothing recorded as code-changed (no reload happened)' ($null -eq $r.data.PSObject.Properties['buildRequired']) (J $r.data)

    # --- D: a file reload prompt appears while the guard polls -> dismissed, close / reopen ---
    Reset-World -Dialog $null -AppearAtRead 1 -AppearDialog $fileDlg
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    Check 'D file prompt during the guard -> dismissed, closed and reopened, success' ($r.success -and $r.data.dismissedReloadPrompt -eq $true -and $r.data.reloadTarget -eq 'file' -and $r.data.answeredYes -eq $false -and $r.data.reopenedSolution -eq $true -and $global:W.Closed -and $global:W.Opened -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))
    Check 'D the prompt was closed without Yes' (@($global:W.Log) -contains 'ClosePrompt:' -and @($global:W.Log) -notcontains 'ClosePrompt:Yes') (Get-LogText)

    # --- I (#42): the modal scan does not complete -> MODAL_SCAN_INCOMPLETE, nothing closed ---
    $incompleteScan = & $mod { New-TcModalScanIncomplete -ProcessId 4242 -Reason 'timeout' -TimeoutSec 5 -Message 'mock: scan did not finish' }
    Reset-World -Dialog $incompleteScan
    $r = Start-Reset -ModulePath $sln
    Check 'I incomplete modal scan at the start -> MODAL_SCAN_INCOMPLETE, nothing closed, not read as "no dialog"' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.data.scanComplete -eq $false -and $r.data.modalScan.reason -eq 'timeout' -and -not $global:W.Closed -and -not $global:W.Opened -and @($global:W.Log) -notcontains 'Documents.CloseAll') ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # --- regression: guard read stays $null without any dialog -> RESET_SOLUTION_UNVERIFIED after -TimeoutSec ---
    Reset-World -Dialog $null
    $stuck = [PSCustomObject]@{ Mock = $true }
    $stuck | Add-Member -MemberType ScriptProperty -Name FullName -Value { $global:W.Log.Add('FullName:null'); $null }
    $stuck | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:W.Closed = $true }
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } ([PSCustomObject]@{ Solution = $stuck; Documents = $docs }) $sln
    $r = Reset-TcSolution -TimeoutSec 5
    Check 'regression: FullName $null, no dialog -> RESET_SOLUTION_UNVERIFIED, nothing closed, modal checked in the poll' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_UNVERIFIED' -and -not $global:W.Closed -and @($global:W.Log | Where-Object { $_ -eq 'Modal:none' }).Count -ge 2) ("{0} | {1}" -f (Get-LogText).Substring(0, [Math]::Min(200, (Get-LogText).Length)), (J $r.error))

    # --- J (#106): solution reload prompt (buttons 259 + 1412) -> Ignore (1412), full close / reopen ---
    # (not Reload: measured 2026-11-07, 4026 VS2022 zh-TW, Reload brought up a "save changes" dialog)
    Reset-World -Dialog $solutionDlg
    $r = Start-Reset -ModulePath $sln
    $att = @($r.data.reloadPromptAttempts)
    Check 'J solution prompt -> Close-TcReloadPrompt -Answer Ignore, close / reopen, success, loaded' ($r.success -and $r.data.answeredYes -eq $false -and $r.data.reopenedSolution -eq $true -and $r.data.reloadTarget -eq 'solution' -and $r.data.dismissedReloadPrompt -eq $true -and $r.data.loadCheck.complete -eq $true -and $global:W.Closed -and $global:W.Opened -and $null -eq $r.data.PSObject.Properties['answeredReload']) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))
    Check 'J Ignore answered (log), never Reload, one attempt (target solution, answer Ignore, sent, dismissed)' ((@($global:W.Log) -contains 'ClosePrompt:Ignore') -and (@($global:W.Log) -notcontains 'ClosePrompt:Reload') -and $att.Count -eq 1 -and $att[0].target -eq 'solution' -and $att[0].answer -eq 'Ignore' -and $att[0].sent -eq $true -and $att[0].dismissed -eq $true) ("{0} | {1}" -f (Get-LogText), (J $att))
    Check 'J recorded as code-changed (solution reopened from disk); .sln without .tsproj -> expectedFrom none, TIPC not required' (([string]$r.data.buildRequired -like '*solution reopened from disk*') -and $r.data.loadCheck.expectedFrom -eq 'none' -and $r.data.loadCheck.expected.requireTipc -eq $false) (J $r.data)

    # --- J2: Ignore fails -> WM_CLOSE, full close / reopen ---
    Reset-World -Dialog $solutionDlg
    $global:W.FailAnswers = @{ Ignore = 1 }
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $att = @($r.data.reloadPromptAttempts)
    Check 'J2 Ignore fails -> WM_CLOSE, close / reopen, success' ($r.success -and $r.data.reopenedSolution -eq $true -and $global:W.Closed -and $global:W.Opened -and $att.Count -eq 2 -and $att[0].answer -eq 'Ignore' -and $att[0].dismissed -eq $false -and $att[0].bmClick -eq 'processed-still-open' -and $att[0].wmCommand -eq 'posted-still-open' -and $att[1].answer -eq 'Close' -and $r.data.loadCheck.complete -eq $true) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- J3: Ignore and WM_CLOSE fail -> IDE_MODAL_DIALOG, nothing closed ---
    Reset-World -Dialog $solutionDlg
    $global:W.FailAnswers = @{ Ignore = 1; '' = 1 }
    $r = Start-Reset -ModulePath $sln
    $answers = @($r.data.reloadPromptAttempts | ForEach-Object { $_.answer }) -join ','
    Check 'J3 Ignore and WM_CLOSE fail -> IDE_MODAL_DIALOG, nothing closed, not recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $answers -eq 'Ignore,Close' -and -not $global:W.Closed -and -not $global:W.Opened -and $null -eq $r.data.PSObject.Properties['buildRequired']) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- J4 / J5 (PR #173 review): Ignore reaches a disabled prompt (not-posted-disabled) -> no WM_CLOSE afterwards ---
    Reset-World -Dialog $solutionDlg
    $global:W.DisabledAnswers = @{ Ignore = @{ Nested = $nestedDlg } }
    $r = Start-Reset -ModulePath $sln
    $prompts = @($global:W.Log | Where-Object { $_ -like 'ClosePrompt:*' })
    Check 'J4 Ignore -> not-posted-disabled, nested dialog up -> IDE_MODAL_DIALOG (the nested one), no further answer, possiblyReloaded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogText -eq 'Nested modal (mock)' -and $prompts.Count -eq 1 -and $prompts[0] -eq 'ClosePrompt:Ignore' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $r.data.possiblyReloaded -eq $true -and -not $global:W.Closed -and -not $global:W.Opened) ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $solutionDlg
    $global:W.DisabledAnswers = @{ Ignore = @{ Nested = $null } }
    $r = Start-Reset -ModulePath $sln
    $prompts = @($global:W.Log | Where-Object { $_ -like 'ClosePrompt:*' })
    Check 'J5 Ignore -> not-posted-disabled, no nested dialog -> IDE_MODAL_DIALOG (the prompt), no further answer, nothing closed' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogReloadTarget -eq 'solution' -and $prompts.Count -eq 1 -and $prompts[0] -eq 'ClosePrompt:Ignore' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $r.data.possiblyReloaded -eq $false -and -not $global:W.Closed -and -not $global:W.Opened) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- K (#135 F4): project prompt, Yes fails twice -> No, close / reopen, WM_CLOSE never used ---
    Reset-World -Dialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 2 }
    $r = Start-Reset -ModulePath $sln
    $att = @($r.data.reloadPromptAttempts)
    $answers = @($att | ForEach-Object { $_.answer }) -join ','
    Check 'K Yes fails twice -> No, full close / reopen, success' ($r.success -and $r.data.answeredYes -eq $false -and $r.data.reopenedSolution -eq $true -and $r.data.dismissedReloadPrompt -eq $true -and $global:W.Closed -and $global:W.Opened -and $r.data.loadCheck.complete -eq $true) ("{0} | {1}" -f (Get-LogText), (J $r))
    Check 'K three attempts Yes,Yes,No; WM_CLOSE never used; possiblyReloaded (a Yes was sent)' ($att.Count -eq 3 -and $answers -eq 'Yes,Yes,No' -and $att[0].sent -eq $true -and $att[0].dismissed -eq $false -and $att[2].dismissed -eq $true -and @($global:W.Log) -notcontains 'ClosePrompt:' -and @($global:W.Log) -notcontains 'ClosePrompt:Close' -and $r.data.possiblyReloaded -eq $true) ("{0} | {1}" -f (Get-LogText), (J $att))

    # --- K2 (review N2 / S7): Yes, Yes and No fail -> IDE_MODAL_DIALOG at once (no WM_CLOSE), recorded as code-changed ---
    Reset-World -Dialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 2; No = 1 }
    $r = Start-Reset -ModulePath $sln
    $answers = @($r.data.reloadPromptAttempts | ForEach-Object { $_.answer }) -join ','
    Check 'K2 Yes x2 and No fail -> IDE_MODAL_DIALOG, no WM_CLOSE, nothing closed' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $answers -eq 'Yes,Yes,No' -and @($global:W.Log) -notcontains 'ClosePrompt:' -and -not $global:W.Closed -and -not $global:W.Opened) ("{0} | {1}" -f (Get-LogText), (J $r))
    Check 'K2 a Yes was sent -> the failure is recorded as code-changed (S7)' ($r.data.possiblyReloaded -eq $true -and [string]$r.data.buildRequired -like '*project reloaded from disk, then reload prompt dismissal failed*') (J $r.data)

    # --- K6 / K7 (PR #173 review): Yes reaches a disabled prompt (not-posted-disabled) -> no second Yes, no No ---
    Reset-World -Dialog $projectDlg
    $global:W.DisabledAnswers = @{ Yes = @{ Nested = $nestedDlg } }
    $r = Start-Reset -ModulePath $sln
    $prompts = @($global:W.Log | Where-Object { $_ -like 'ClosePrompt:*' })
    Check 'K6 Yes -> not-posted-disabled, nested dialog up -> IDE_MODAL_DIALOG (the nested one), no further answer, recorded as code-changed' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogText -eq 'Nested modal (mock)' -and $prompts.Count -eq 1 -and $prompts[0] -eq 'ClosePrompt:Yes' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and $r.data.possiblyReloaded -eq $true -and [string]$r.data.buildRequired -like '*reload prompt dismissal failed*' -and -not $global:W.Closed -and -not $global:W.Opened) ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $projectDlg
    $global:W.DisabledAnswers = @{ Yes = @{ Nested = $null } }
    $r = Start-Reset -ModulePath $sln
    $prompts = @($global:W.Log | Where-Object { $_ -like 'ClosePrompt:*' })
    Check 'K7 Yes -> not-posted-disabled, no nested dialog -> IDE_MODAL_DIALOG (the prompt), no further answer, nothing closed' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogReloadTarget -eq 'project' -and $prompts.Count -eq 1 -and $prompts[0] -eq 'ClosePrompt:Yes' -and @($r.data.reloadPromptAttempts).Count -eq 1 -and -not $global:W.Closed -and -not $global:W.Opened) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- K3: the first Yes fails, the second closes the prompt -> Yes-only path ---
    Reset-World -Dialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 1 }
    $r = Start-Reset -ModulePath $sln
    $answers = @($r.data.reloadPromptAttempts | ForEach-Object { $_.answer }) -join ','
    Check 'K3 Yes fails once, second Yes works -> answeredYes, no reopen' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $false -and $answers -eq 'Yes,Yes' -and -not $global:W.Closed) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- K4: after both Yes failed, the next project prompt starts at No ---
    Reset-World -Dialog $projectDlg -AppearAtRead 1 -AppearDialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 2 }
    $r = Start-Reset -ModulePath $sln
    $answers = @($r.data.reloadPromptAttempts | ForEach-Object { $_.answer }) -join ','
    Check 'K4 a second project prompt after the Yes failures is answered No at once' ($r.success -and $answers -eq 'Yes,Yes,No,No' -and $r.data.reopenedSolution -eq $true) ("{0} | {1}" -f (Get-LogText), (J $r.data.reloadPromptAttempts))

    # --- K5 (review S1): every answer waits at most what is left of -TimeoutSec ---
    Reset-World -Dialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 2; No = 1 }
    $global:W.FailSleep = $true
    $r = Start-Reset -ModulePath $sln -TimeoutSec 5
    $att = @($r.data.reloadPromptAttempts)
    Check 'K5 answers that wait their -TimeoutSec -> IDE_MODAL_DIALOG within the 5 s budget, attempts in data' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $att.Count -ge 1 -and @($att | Where-Object { $_.timeoutSec -gt 5 -or $_.timeoutSec -lt 1 }).Count -eq 0 -and $global:LastSec -lt 6.5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $att))

    # --- L (#135 F5): readback after the reopen ---
    Reset-World -Dialog $fileDlg
    $global:W.NotLoaded = 3
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    Check 'L Projects.Count 0 / SolutionBuild $null for 3 polls -> success only after loaded (polls > 1)' ($r.success -and $r.data.reopenedSolution -eq $true -and $r.data.loadCheck.complete -eq $true -and $r.data.loadCheck.polls -ge 4 -and $global:W.NotLoaded -eq 0 -and $r.data.loadCheck.last.projectCount -eq 1 -and $r.data.loadCheck.last.activeConfiguration -eq $true) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r.data.loadCheck))

    Reset-World -Dialog $fileDlg
    $global:W.NotLoaded = 1000000
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true } -TimeoutSec 5
    $lc = $r.data.loadCheck
    Check 'L2 never loaded -> SOLUTION_RELOAD_INCOMPLETE within -TimeoutSec, loadCheck in data' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_RELOAD_INCOMPLETE' -and -not [string]::IsNullOrWhiteSpace([string]$r.error.hint) -and $lc.complete -eq $false -and $lc.polls -gt 1 -and $lc.last.projectCount -eq 0 -and $lc.last.solutionBuild -eq $false -and -not [string]::IsNullOrWhiteSpace([string]$lc.lastError) -and $global:LastSec -lt 6) ("{0:N1}s | {1}" -f $global:LastSec, (J $r))
    Check 'L2 recorded as code-changed (files may have been reloaded); last dialog scan before giving up (N5)' (([string]$r.data.buildRequired -like '*solution reopened from disk*') -and (Get-LogText) -match 'SolutionBuild:null > Modal:none$') ("{0} | {1}" -f ((Get-LogText) -replace '^.*(.{120})$', '$1'), (J $r.data.buildRequired))

    Reset-World -Dialog $projectDlg
    $global:W.FailAnswers = @{ Yes = 2 }
    $global:W.NotLoaded = 5
    $global:W.DialogAtLoadPoll = $otherDlg
    $r = Start-Reset -ModulePath $sln
    Check 'L3 a dialog comes up while waiting for the load -> IDE_MODAL_DIALOG, loadCheck incomplete' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and $r.data.loadCheck.complete -eq $false -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # L4 (review S4): the IDE crashes during the readback -> IDE_CRASHED at once, recorded
    Reset-World -Dialog $fileDlg
    $global:W.CrashOnLoad = $true
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    Check 'L4 IDE_CRASHED during the readback -> IDE_CRASHED (not SOLUTION_RELOAD_INCOMPLETE), at once, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_CRASHED' -and $r.data.loadCheck.complete -eq $false -and $r.data.loadCheck.polls -eq 1 -and $global:LastSec -lt 3 -and [string]$r.data.buildRequired -like '*solution reopened from disk*') ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # L5 (review S2): a solution without a TwinCAT project (no .tsproj, no ITcSysManager) is not a regression
    Reset-World -Dialog $fileDlg
    $keepSm = $global:OkSm
    $global:OkSm = $null
    try { $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true } }
    finally { $global:OkSm = $keepSm }
    Check 'L5 .sln without .tsproj and no ITcSysManager -> success, TIPC not required' ($r.success -and $r.data.loadCheck.complete -eq $true -and $r.data.loadCheck.expectedFrom -eq 'none' -and $r.data.loadCheck.expectationSource -eq 'none' -and $r.data.loadCheck.expected.requireTipc -eq $false -and $r.data.loadCheck.last.tipc -eq $false) ("{0} | {1}" -f (Get-LogText), (J $r.data.loadCheck))

    # L11 (PR #173 review): Get-TcSolutionLoadExpectation for a .sln without a .tsproj
    $eMem = & $mod { param($p) Get-TcSolutionLoadExpectation -SolutionPath $p -MemoryBaseline ([PSCustomObject]@{ known = $true; plcs = @('PLC1', ''); error = $null }) } $sln
    Check 'L11 no .tsproj + known memory baseline -> from memory, requireTipc, PLC1' ($eMem.from -eq 'memory' -and $eMem.expectationSource -eq 'memory' -and $eMem.requireTipc -eq $true -and (@($eMem.plcs) -join ',') -eq 'PLC1' -and $eMem.minPlcCount -eq 1) (J $eMem)
    $eUnknown = & $mod { param($p) Get-TcSolutionLoadExpectation -SolutionPath $p -MemoryBaseline ([PSCustomObject]@{ known = $false; plcs = @('PLC1'); error = 'no ITcSysManager' }) } $sln
    $eNull = & $mod { param($p) Get-TcSolutionLoadExpectation -SolutionPath $p -MemoryBaseline $null } $sln
    Check 'L11 no .tsproj, memory baseline unknown / missing -> expectationSource none, TIPC not required' ($eUnknown.expectationSource -eq 'none' -and $eUnknown.requireTipc -eq $false -and $eNull.expectationSource -eq 'none' -and $eNull.requireTipc -eq $false -and @($eNull.plcs).Count -eq 0) ("{0} | {1}" -f (J $eUnknown), (J $eNull))
    $eDisk = & $mod { param($p) Get-TcSolutionLoadExpectation -SolutionPath $p -MemoryBaseline $null } $slnTs
    Check 'L11 .tsproj with PLC1 -> expectationSource disk' ($eDisk.from -eq 'disk' -and $eDisk.expectationSource -eq 'disk') (J $eDisk)

    # --- N (4024, 2026-11-07): step 5 Connect-TcIde answers MODAL_SCAN_INCOMPLETE -> retried at once ---
    Reset-World -Dialog $fileDlg
    $global:W.ConnectScanFail = 1
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $ra = @($r.data.reconnectAttempts)
    Check 'N1 reconnect MODAL_SCAN_INCOMPLETE once, then success -> Reset success, 2 reconnectAttempts' ($r.success -and $ra.Count -eq 2 -and $ra[0].code -eq 'MODAL_SCAN_INCOMPLETE' -and $ra[1].code -eq 'success' -and $ra[0].step -eq 'reopen' -and $r.data.loadCheck.complete -eq $true) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $ra))

    Reset-World -Dialog $fileDlg
    $global:W.ConnectScanFail = 1000
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true } -TimeoutSec 5
    $ra = @($r.data.reconnectAttempts)
    Check 'N2 reconnect always MODAL_SCAN_INCOMPLETE -> failure MODAL_SCAN_INCOMPLETE, 1 + 3 attempts, no sleep, within -TimeoutSec' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $ra.Count -eq 4 -and @($ra | Where-Object { $_.code -ne 'MODAL_SCAN_INCOMPLETE' }).Count -eq 0 -and $global:LastSec -lt 2) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    Reset-World -Dialog $projectDlg
    $global:W.ConnectScanFail = 1
    $r = Start-Reset -ModulePath $sln
    $ra = @($r.data.reconnectAttempts)
    Check 'N3 Yes-path reconnect MODAL_SCAN_INCOMPLETE once -> retried, success without reopen' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $false -and $ra.Count -eq 2 -and $ra[0].step -eq 'reload-path' -and $ra[1].code -eq 'success') ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $ra))

    # --- O (#174): no modal scan right after a Yes that closed the project prompt ---
    $global:IncompleteScan = $incompleteScan
    Reset-World -Dialog $projectDlg
    $r = Start-Reset -ModulePath $sln
    $log = @($global:W.Log)
    $iYes = [array]::IndexOf($log, 'ClosePrompt:Yes'); $iConn = [array]::IndexOf($log, 'Connect')
    $between = if ($iYes -ge 0 -and $iConn -gt $iYes) { @($log[($iYes + 1)..($iConn - 1)]) } else { @('order?') }
    Check 'O1 Yes -> Close-TcReloadPrompt -NoFollowUpScan; after the Yes the Yes-path wait scans first, then reads FullName; success' ($r.success -and $r.data.answeredYes -eq $true -and (@($global:W.NoScanFlags) -join ',') -eq 'Yes:True' -and ($between -join ',') -eq 'Modal:none,FullName:sln' -and $global:W.Violations.Count -eq 0) ("{0} | {1}" -f (Get-LogText), (J $r.data.reloadPromptAttempts))

    Reset-World -Dialog $fileDlg
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    Check 'O1b WM_CLOSE answer -> no -NoFollowUpScan (behaviour unchanged)' ($r.success -and (@($global:W.NoScanFlags) -join ',') -eq ':False') ("{0} | {1}" -f (Get-LogText), (@($global:W.NoScanFlags) -join ','))

    Reset-World -Dialog $projectDlg
    $global:W.ScanIncompleteAfterYes = 2
    $r = Start-Reset -ModulePath $sln
    $log = @($global:W.Log)
    $iYes = [array]::IndexOf($log, 'ClosePrompt:Yes'); $iRead = -1
    for ($i = $iYes + 1; $i -lt $log.Count; $i++) { if ($log[$i] -like 'FullName:*') { $iRead = $i; break } }
    $before = if ($iYes -ge 0 -and $iRead -gt $iYes) { (@($log[($iYes + 1)..($iRead - 1)]) -join ',') } else { 'order?' }
    Check 'O2 the 2 scans after the Yes do not complete (Yes-path wait) -> waited out without a FullName read, not MODAL_SCAN_INCOMPLETE, Yes-only path success' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $false -and $before -eq 'Modal:scan-incomplete,Modal:scan-incomplete,Modal:none' -and $global:W.Violations.Count -eq 0) ("{0} | {1}" -f (Get-LogText), (J $r))

    # --- O3 (#181 review): a modal comes up right after the Yes -> found by the scan, FullName never read under it ---
    Reset-World -Dialog $projectDlg
    $global:W.AfterYes.Add(@{ Dialog = $otherDlg })
    $r = Start-Reset -ModulePath $sln
    Check 'O3 Yes-only path: another modal right after the Yes -> IDE_MODAL_DIALOG from the scan, FullName not read before a clean scan, nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and $global:W.Violations.Count -eq 0 -and @($global:W.Log) -notcontains 'FullName:BLOCKED' -and -not $global:W.Closed -and -not [string]::IsNullOrWhiteSpace([string]$r.data.buildRequired)) ("{0} | {1} | {2}" -f (Get-LogText), ($global:W.Violations -join '; '), (J $r))

    # O4: the same with incomplete scans first (XAE reloading) -> still no read until the dialog is seen
    Reset-World -Dialog $projectDlg
    $global:W.AfterYes.Add(@{ Dialog = $otherDlg; Scans = @('incomplete', 'incomplete') })
    $r = Start-Reset -ModulePath $sln
    Check 'O4 Yes-only path: 2 incomplete scans then another modal -> IDE_MODAL_DIALOG, no FullName read after the Yes' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and $global:W.Violations.Count -eq 0 -and @($global:W.Log | Where-Object { $_ -eq 'Modal:scan-incomplete' }).Count -eq 2) ("{0} | {1}" -f (Get-LogText), ($global:W.Violations -join '; '))

    # O5: full path (a Yes after YesPathDone): another modal right after the Yes -> the guard scans first
    Reset-World -Dialog $projectDlg
    $global:W.AfterConnect.Add($projectDlg)
    $global:W.AfterYes.Add(@{}); $global:W.AfterYes.Add(@{ Dialog = $otherDlg; Scans = @('incomplete') })
    $r = Start-Reset -ModulePath $sln
    Check 'O5 full path: another modal right after the second Yes -> the guard scans before FullName, IDE_MODAL_DIALOG, nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and $global:W.Violations.Count -eq 0 -and @($global:W.Log) -notcontains 'Documents.CloseAll' -and -not $global:W.Closed -and -not [string]::IsNullOrWhiteSpace([string]$r.data.buildRequired)) ("{0} | {1} | {2}" -f (Get-LogText), ($global:W.Violations -join '; '), (J $r))

    # O6: path read from the DTE (no module path) right after a Yes -> scan first there too
    Reset-World -Dialog $projectDlg
    $global:W.AfterYes.Add(@{ Scans = @('incomplete') })
    $r = Start-Reset -ModulePath $null
    Check 'O6 path read after a Yes: incomplete scan waited out, FullName read only after a clean scan, success' ($r.success -and $r.data.solution -eq $sln -and $global:W.Violations.Count -eq 0) ("{0} | {1} | {2}" -f (Get-LogText), ($global:W.Violations -join '; '), (J $r))

    # O7 (#181 review): P1 path + incomplete scans after the second Yes. The guard waits through an
    # incomplete scan (no read, no failure); the scan right before Documents.CloseAll does not
    # tolerate one -> MODAL_SCAN_INCOMPLETE, fail closed, nothing closed, recorded.
    Reset-World -Dialog $projectDlg
    $global:W.AfterConnect.Add($projectDlg)
    $global:W.AfterYes.Add(@{}); $global:W.AfterYes.Add(@{ Scans = @('incomplete', 'none', 'incomplete') })
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    Check 'O7 full path, scan before Documents.CloseAll incomplete -> MODAL_SCAN_INCOMPLETE, nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and @($global:W.Log) -notcontains 'Documents.CloseAll' -and -not $global:W.Closed -and -not $global:W.Opened -and [string]$r.data.buildRequired -like '*project reloaded from disk*' -and $global:W.Violations.Count -eq 0) ("{0} | {1}" -f (Get-LogText), (J $r))

    # O8: P1 path + ScanIncompleteAfterYes (every scan after the second Yes incomplete) -> the guard
    # never reads: RESET_SOLUTION_UNVERIFIED within -TimeoutSec, nothing closed, recorded
    Reset-World -Dialog $projectDlg
    $global:W.AfterConnect.Add($projectDlg)
    $global:W.AfterYes.Add(@{}); $global:W.AfterYes.Add(@{ Scans = @(1..100 | ForEach-Object { 'incomplete' }) })
    $r = Start-Reset -ModulePath $sln -TimeoutSec 5
    $logText = Get-LogText; if ($logText.Length -gt 300) { $logText = $logText.Substring(0, 300) }
    Check 'O8 full path, every scan after the Yes incomplete -> RESET_SOLUTION_UNVERIFIED (no FullName read), nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_UNVERIFIED' -and -not $global:W.Closed -and [string]$r.data.buildRequired -like '*project reloaded from disk*' -and $global:W.Violations.Count -eq 0 -and $global:LastSec -lt 7) ("{0:N1}s {1} | {2}" -f $global:LastSec, $logText, (J $r.error))

    # --- P (#176): a reload prompt that comes up during the readback goes back to step 1 ---
    Reset-World -Dialog $projectDlg
    $global:W.AfterConnect.Add($projectDlg)
    $r = Start-Reset -ModulePath $sln
    $att = @($r.data.reloadPromptAttempts); $ra = @($r.data.reconnectAttempts)
    Check 'P1 Yes path: project prompt during the readback -> answered Yes, full guard / close / reopen, success' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $true -and $r.data.loadCheck.complete -eq $true -and $att.Count -eq 2 -and (@($att | ForEach-Object { $_.answer }) -join ',') -eq 'Yes,Yes' -and (@($ra | ForEach-Object { $_.step }) -join ',') -eq 'reload-path,reopen' -and $global:W.Closed -and $global:W.Opened -and -not [string]::IsNullOrWhiteSpace([string]$r.data.buildRequired)) ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $fileDlg
    $global:W.AfterConnect.Add($fileDlg)
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $att = @($r.data.reloadPromptAttempts); $ra = @($r.data.reconnectAttempts)
    $opens = @($global:W.Log | Where-Object { $_ -eq 'Solution.Open' }).Count
    Check 'P2 after Solution.Open: file prompt during the readback -> dismissed, closed / reopened again, success' ($r.success -and $r.data.reopenedSolution -eq $true -and $r.data.loadCheck.complete -eq $true -and $att.Count -eq 2 -and (@($ra | ForEach-Object { $_.step }) -join ',') -eq 'reopen,reopen' -and $opens -eq 2 -and [string]$r.data.buildRequired -like '*solution reopened from disk*') ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $null
    $global:W.AfterConnect.Add($projectDlg)
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $ra = @($r.data.reconnectAttempts)
    $opens = @($global:W.Log | Where-Object { $_ -eq 'Solution.Open' }).Count
    Check 'P3 no prompt before, project prompt during the readback after Solution.Open -> Yes, Yes-only path, success' ($r.success -and $r.data.answeredYes -eq $true -and (@($ra | ForEach-Object { $_.step }) -join ',') -eq 'reopen,reload-path' -and $opens -eq 1 -and $r.data.loadCheck.complete -eq $true) ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $projectDlg
    $global:W.AfterConnect.Add($otherDlg)
    $r = Start-Reset -ModulePath $sln
    Check 'P4 Yes path: another dialog during the readback -> IDE_MODAL_DIALOG, nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and -not $global:W.Closed -and [string]$r.data.buildRequired -like '*load check failed*') ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $fileDlg
    $global:W.AfterConnect.Add($otherDlg)
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $opens = @($global:W.Log | Where-Object { $_ -eq 'Solution.Open' }).Count
    Check 'P5 after Solution.Open: another dialog during the readback -> IDE_MODAL_DIALOG, no second reopen, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and $opens -eq 1 -and [string]$r.data.buildRequired -like '*solution reopened from disk*') ("{0} | {1}" -f (Get-LogText), (J $r))

    Reset-World -Dialog $fileDlg
    for ($i = 0; $i -lt 5; $i++) { $global:W.AfterConnect.Add($fileDlg) }
    $r = Start-Reset -ModulePath $sln -Params @{ DiscardProjectChanges = $true }
    $opens = @($global:W.Log | Where-Object { $_ -eq 'Solution.Open' }).Count
    Check 'P6 after Solution.Open: prompt during the 5th readback with 5 handled -> IDE_MODAL_DIALOG (reload prompt), no endless loop' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'reload-prompt' -and @($r.data.reloadPromptAttempts).Count -eq 5 -and $opens -eq 5 -and [string]$r.data.buildRequired -like '*solution reopened from disk*') ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r.error))

    Reset-World -Dialog $projectDlg
    $global:W.ChainAfterYes = 4
    $global:W.AfterConnect.Add($projectDlg)
    $r = Start-Reset -ModulePath $sln
    $ra = @($r.data.reconnectAttempts)
    Check 'P7 Yes path: prompt during the readback with 5 handled -> IDE_MODAL_DIALOG, nothing closed, recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'reload-prompt' -and @($r.data.reloadPromptAttempts).Count -eq 5 -and (@($ra | ForEach-Object { $_.step }) -join ',') -eq 'reload-path' -and -not $global:W.Closed -and -not $global:W.Opened -and [string]$r.data.buildRequired -like '*load check failed*') ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

    # --- M (#106): classification by button control ids 259 + 1412 ---
    $m = & $mod {
        param($t, $x, $b)
        $plainBtns = @(@{ Id = 1; Name = 'OK' }, @{ Id = 2; Name = 'Cancel' })
        $objBtns = @([PSCustomObject]@{ Id = 1412; Name = 'i' }, [PSCustomObject]@{ Id = 259; Name = 'r' })
        $yesNo = @(@{ Id = 6; Name = 'y' }, @{ Id = 7; Name = 'n' })
        $projText = "The project file 'Demo.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?"
        $fileText = 'MAIN.TcPOU has been changed outside the environment. Reload the new file?'
        $raw = Add-TcDialogKind -Dialog ([PSCustomObject]@{ Title = $t; Text = $x; Hwnd = 1; Buttons = $b })
        @{
            SolKind    = Get-TcModalDialogKind -Title $t -Text $x -Buttons $b
            SolTarget  = Get-TcReloadTarget -Title $t -Text $x -Buttons $b
            ObjKind    = Get-TcModalDialogKind -Title $t -Text $x -Buttons $objBtns
            ObjTarget  = Get-TcReloadTarget -Title $t -Text $x -Buttons $objBtns
            NoIdKind   = Get-TcModalDialogKind -Title $t -Text $x -Buttons $plainBtns
            NoIdTarget = Get-TcReloadTarget -Title $t -Text $x -Buttons $plainBtns
            OneIdKind  = Get-TcModalDialogKind -Title $t -Text $x -Buttons @(@{ Id = 259; Name = 'r' })
            NoBtnKind  = Get-TcModalDialogKind -Title $t -Text $x
            ProjKind   = Get-TcModalDialogKind -Title 'TcXaeShell' -Text $projText -Buttons $yesNo
            ProjTarget = Get-TcReloadTarget -Title 'TcXaeShell' -Text $projText -Buttons $yesNo
            FileKind   = Get-TcModalDialogKind -Title 'TcXaeShell' -Text $fileText
            FileTarget = Get-TcReloadTarget -Title 'TcXaeShell' -Text $fileText
            RawKind    = $raw.Kind
            RawTarget  = $raw.ReloadTarget
            Result     = New-TcModalDialogResult -Dialog $raw -Operation 'unit'
            ReloadHint = Get-TcErrorHint -Code 'IDE_MODAL_DIALOG_RELOAD'
        }
    } $zhSolTitle $zhSolText $solButtons
    Check 'M 259 + 1412 -> reload-prompt / solution (hashtable and object buttons, raw watchdog record)' ($m.SolKind -eq 'reload-prompt' -and $m.SolTarget -eq 'solution' -and $m.ObjKind -eq 'reload-prompt' -and $m.ObjTarget -eq 'solution' -and $m.RawKind -eq 'reload-prompt' -and $m.RawTarget -eq 'solution') (J $m)
    Check 'M same text without both ids -> unknown, no reload target' ($m.NoIdKind -eq 'unknown' -and $null -eq $m.NoIdTarget -and $m.OneIdKind -eq 'unknown' -and $m.NoBtnKind -eq 'unknown') (J $m)
    Check 'M project / file classification unchanged' ($m.ProjKind -eq 'reload-prompt' -and $m.ProjTarget -eq 'project' -and $m.FileKind -eq 'reload-prompt' -and $m.FileTarget -eq 'file') (J $m)
    Check 'M IDE_MODAL_DIALOG of a solution prompt: data.dialogReloadTarget solution, reload hint' ($m.Result.error.code -eq 'IDE_MODAL_DIALOG' -and $m.Result.data.dialogReloadTarget -eq 'solution' -and $m.Result.data.dialogKind -eq 'reload-prompt' -and $m.Result.error.hint -eq $m.ReloadHint) (J $m.Result)

    # --- E-H (#87 retest 2026-11-02): the prompt comes up AFTER the guard ---
    $origFns2 = & $mod { @{ Sm = ${function:Get-TcSysManager}; Up = ${function:Get-TcUnsavedPlcObject} } }
    & $mod {
        Set-Item -Path function:script:Get-TcSysManager -Value { param([switch]$Refresh) if ($Refresh) { $global:W.Log.Add('GetSysManager:Refresh') }; $global:OkSm }
        Set-Item -Path function:script:Get-TcUnsavedPlcObject -Value {
            param($SysManager)
            $global:W.Log.Add("ProjectCheck:$($global:W.CheckMode)")
            $plc = [PSCustomObject]@{ plc = 'AxisInterface'; checked = $true; reason = $null; plcproj = 'x.plcproj'; tsproj = 'x.tsproj'; warning = $null; missingOnDisk = @(); extraOnDisk = @(); complete = $true; visited = 3 }
            switch ($global:W.CheckMode) {
                'throw-appear' { $global:W.CheckMode = 'clean'; $global:W.Dialog = $global:W.LaterDialog; throw "IDE_MODAL_DIALOG: TcXaeShell | reload (operation 'TIPC.Child(1)', original error: Call was rejected by callee. (Exception from HRESULT: 0x80010001 (RPC_E_CALL_REJECTED)))" }
                'incomplete-appear' {
                    $global:W.CheckMode = 'clean'; $global:W.Dialog = $global:W.LaterDialog
                    $plc = [PSCustomObject]@{ plc = 'AxisInterface'; checked = $false; reason = "locate: no .tsproj of the open solution lists PLC 'AxisInterface'"; plcproj = $null; tsproj = $null; warning = $null; missingOnDisk = @(); extraOnDisk = @(); complete = $false; visited = 0 }
                }
            }
            [PSCustomObject]@{ Plcs = @($plc); Visited = 3; Sec = 0.1 }
        }
    }
    $solG = [PSCustomObject]@{ Mock = $true }
    $solG | Add-Member -MemberType ScriptProperty -Name FullName -Value { $global:W.Log.Add("FullName:$(if ($null -ne $global:W.Dialog) { 'null' } else { 'sln' })"); if ($null -ne $global:W.Dialog) { $null } else { $global:ResetSln } }
    $solG | Add-Member -MemberType ScriptMethod -Name Close -Value {
        param($s)
        if ($global:W.CloseAppear) { $global:W.CloseAppear = $false; $global:W.Dialog = $global:W.LaterDialog }
        if ($null -ne $global:W.Dialog) { $global:W.Log.Add('Solution.Close:blocked'); throw 'Call was rejected by callee. (Exception from HRESULT: 0x80010001 (RPC_E_CALL_REJECTED))' }
        $global:W.Log.Add('Solution.Close'); $global:W.Closed = $true
    }
    $solG | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) $global:W.Log.Add('Solution.Open'); $global:W.Opened = $true }
    Add-LoadState $solG
    $global:SolG = $solG
    $docsG = [PSCustomObject]@{ Count = 1 }
    $docsG | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($m) $global:W.Log.Add('Documents.CloseAll'); if ($global:W.CloseAllAppear) { $global:W.CloseAllAppear = $false; $global:W.Dialog = $global:W.LaterDialog } }
    $dteG = [PSCustomObject]@{ Documents = $docsG }
    # DTE.Solution answers $null while a dialog is up (2026-11-02: "cannot call a method on a null-valued expression")
    $dteG | Add-Member -MemberType ScriptProperty -Name Solution -Value {
        $global:W.SolReads++
        if ($global:W.SolAppearAtRead -gt 0 -and $global:W.SolReads -eq $global:W.SolAppearAtRead) { $global:W.Dialog = $global:W.LaterDialog }
        if ($null -ne $global:W.Dialog -and $global:W.SolNull) { $global:W.Log.Add('Solution:null'); $null } else { $global:SolG }
    }
    function Start-ResetG {
        param([hashtable]$Set, [string]$Sln = $sln, [int]$TimeoutSec = 10)
        Reset-World -Dialog $null
        foreach ($k in $Set.Keys) { $global:W[$k] = $Set[$k] }
        if (-not $global:W.ContainsKey('CheckMode')) { $global:W.CheckMode = 'clean' }
        & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $dteG $Sln
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Reset-TcSolution -TimeoutSec $TimeoutSec
        $global:LastSec = $sw.Elapsed.TotalSeconds
        $r
    }
    try {
        $r = Start-ResetG -Set @{ CheckMode = 'throw-appear'; LaterDialog = $projectDlg }
        Check 'E prompt during the project check (RPC_E_CALL_REJECTED) -> Yes, success, nothing closed' ($r.success -and $r.data.answeredYes -eq $true -and $r.data.reopenedSolution -eq $false -and -not $global:W.Closed -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        $r = Start-ResetG -Set @{ CheckMode = 'incomplete-appear'; LaterDialog = $projectDlg }
        Check 'F project check incomplete (PLC not located), prompt up -> Yes, success, nothing closed' ($r.success -and $r.data.answeredYes -eq $true -and -not $global:W.Closed -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        $r = Start-ResetG -Set @{ CloseAllAppear = $true; SolNull = $true; LaterDialog = $projectDlg }
        Check 'G prompt before Solution.Close (DTE.Solution $null) -> Yes, success, not SOLUTION_CLOSE_FAILED' ($r.success -and $r.data.answeredYes -eq $true -and -not $global:W.Closed -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        # read 1 = guard, read 2 = the one inside Solution.Close (after the pre-check): $null, prompt up
        $r = Start-ResetG -Set @{ SolReads = 0; SolAppearAtRead = 2; SolNull = $true; LaterDialog = $projectDlg }
        Check 'G1 DTE.Solution $null inside Solution.Close (prompt up) -> no method call on $null, Yes, success' ($r.success -and $r.data.answeredYes -eq $true -and -not $global:W.Closed -and (Get-LogText) -match 'Solution:null > Modal:reload-prompt' -and $global:LastSec -lt 5) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        # -TimeoutSec 30: the busy backoff (~15 s) must leave time to answer the prompt (#135 review S1)
        $r = Start-ResetG -Set @{ CloseAppear = $true; LaterDialog = $projectDlg } -TimeoutSec 30
        # (no timing check: without an IDE pid there is no watchdog, so the rejected Close goes through
        # the Invoke-TcComRetry busy backoff, ~15 s, before the dialog check)
        Check 'G2 Solution.Close rejected while a project prompt comes up -> Yes, success' ($r.success -and $r.data.answeredYes -eq $true -and -not $global:W.Closed) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        $r = Start-ResetG -Set @{ CloseAppear = $true; LaterDialog = $otherDlg }
        Check 'H Solution.Close fails, other dialog up -> IDE_MODAL_DIALOG (not SOLUTION_CLOSE_FAILED)' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and -not $global:W.Closed) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        # --- L6-L9 (#135 review S2/S3/S5/S6): the expected PLCs come from the .tsproj on disk ---
        $plcSm = [PSCustomObject]@{ Mock = $true }
        $plcSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
            param($p)
            if ($global:W.LookupThrow -gt 0 -and $global:W.Opened) { $global:W.LookupThrow--; $global:W.Log.Add('LookupTreeItem:throw'); throw 'System Manager already disposed! (mock)' }
            $t = [PSCustomObject]@{ Name = 'TIPC' }
            $t | Add-Member -MemberType ScriptProperty -Name ChildCount -Value { if ($global:W.Opened -and $global:W.PlcMissing -gt 0) { $global:W.PlcMissing--; $global:W.Log.Add('TIPC:empty'); 0 } else { 1 } }
            $t | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) [PSCustomObject]@{ Name = 'PLC1' } }
            $t
        }
        $keepSm = $global:OkSm
        $keepSln = $global:ResetSln
        $global:OkSm = $plcSm
        try {
            $global:ResetSln = $slnTs
            $r = Start-ResetG -Set @{ PlcMissing = 2 } -Sln $slnTs
            $lc = $r.data.loadCheck
            Check 'L6 .tsproj lists PLC1, missing below TIPC for 2 polls after the reopen -> success only when it is back (expectedFrom disk)' ($r.success -and $r.data.reopenedSolution -eq $true -and $lc.complete -eq $true -and $lc.expectedFrom -eq 'disk' -and (@($lc.expected.plcs) -join ',') -eq 'PLC1' -and $lc.expected.requireTipc -eq $true -and $lc.polls -ge 3 -and (@($lc.last.plcs) -join ',') -eq 'PLC1' -and $global:W.PlcMissing -eq 0) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $lc))

            $global:ResetSln = $slnTs2
            $r = Start-ResetG -Set @{} -Sln $slnTs2 -TimeoutSec 5
            $lc = $r.data.loadCheck
            Check 'L7 .tsproj lists PLC2, TIPC only has PLC1 -> SOLUTION_RELOAD_INCOMPLETE' ((-not $r.success) -and $r.error.code -eq 'SOLUTION_RELOAD_INCOMPLETE' -and $lc.expectedFrom -eq 'disk' -and (@($lc.expected.plcs) -join ',') -eq 'PLC2' -and $lc.lastError -match 'PLC2' -and $global:LastSec -lt 6.5) ("{0:N1}s | {1}" -f $global:LastSec, (J $lc))

            $global:ResetSln = $slnTsNoName
            $r = Start-ResetG -Set @{} -Sln $slnTsNoName
            $lc = $r.data.loadCheck
            Check 'L8 .tsproj without PLC names -> the memory baseline (PLC1 below TIPC before the reset)' ($r.success -and $lc.expectedFrom -eq 'memory' -and (@($lc.expected.plcs) -join ',') -eq 'PLC1' -and $lc.complete -eq $true) ("{0} | {1}" -f (Get-LogText), (J $lc))

            $global:ResetSln = $slnTs
            $r = Start-ResetG -Set @{ LookupThrow = 1 } -Sln $slnTs
            $lc = $r.data.loadCheck
            Check 'L9 LookupTreeItem throws once during the readback -> ITcSysManager dropped and taken fresh (Get-TcSysManager -Refresh), success' ($r.success -and $lc.complete -eq $true -and $lc.polls -ge 2 -and (Get-LogText) -match 'LookupTreeItem:throw > .*GetSysManager:Refresh') ("{0} | {1}" -f (Get-LogText), (J $lc))

            # L10 (PR #173 review): .sln without a .tsproj, but step 0 saw PLC1 below TIPC -> memory baseline, TIPC required
            $global:ResetSln = $sln
            $r = Start-ResetG -Set @{} -Sln $sln
            $lc = $r.data.loadCheck
            Check 'L10 .sln without .tsproj, memory baseline PLC1 -> expectedFrom memory, TIPC required' ($r.success -and $lc.complete -eq $true -and $lc.expectedFrom -eq 'memory' -and $lc.expectationSource -eq 'memory' -and $lc.expected.requireTipc -eq $true -and (@($lc.expected.plcs) -join ',') -eq 'PLC1') ("{0} | {1}" -f (Get-LogText), (J $lc))
        }
        finally { $global:OkSm = $keepSm; $global:ResetSln = $keepSln }
    }
    finally {
        & $mod { param($f) Set-Item -Path function:script:Get-TcSysManager -Value $f.Sm; Set-Item -Path function:script:Get-TcUnsavedPlcObject -Value $f.Up } $origFns2
    }
}
finally {
    & $mod { param($f) Set-Item -Path function:script:Find-TcIdeModalDialog -Value $f.Dlg; Set-Item -Path function:script:Close-TcReloadPrompt -Value $f.Rp; Set-Item -Path function:script:Connect-TcIde -Value $f.Conn } $origFns
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcSolutionPath = $null; $script:TcSysManager = $null }
}

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
