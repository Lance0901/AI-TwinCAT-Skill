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
#   powershell.exe -NoProfile -File tests/Unit/reset-reload-prompt.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-rrp-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
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

$projectDlg = @{ Title = 'TcXaeShell'; Text = "The project file 'Demo.plcproj' has been modified outside of TwinCAT XAE. Do you want to reload the project?"; Kind = 'reload-prompt'; ReloadTarget = 'project'; Hwnd = 0; Buttons = @() }
$fileDlg = @{ Title = 'TcXaeShell'; Text = 'MAIN.TcPOU has been changed outside the environment. Reload the new file?'; Kind = 'reload-prompt'; ReloadTarget = 'file'; Hwnd = 0; Buttons = @() }
$otherDlg = @{ Title = 'TcXaeShell'; Text = 'Assertion Failed (mock)'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 0; Buttons = @() }

# World: Dialog = the modal that is up ($null = none); AppearAtRead = FullName read count at which
# AppearDialog comes up; FullName answers $null while a dialog is up. Log = call order.
$global:W = @{}
function Reset-World {
    param([object]$Dialog, [int]$AppearAtRead = 0, [object]$AppearDialog)
    $global:W = @{ Dialog = $Dialog; AppearAtRead = $AppearAtRead; AppearDialog = $AppearDialog; Reads = 0; Log = [System.Collections.Generic.List[string]]::new(); Closed = $false; Opened = $false }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
    & $mod { $script:TcBuildRequiredLocal = @{} }
}
$sol = [PSCustomObject]@{ Mock = $true }
$sol | Add-Member -MemberType ScriptProperty -Name FullName -Value {
    $global:W.Reads++
    if ($global:W.AppearAtRead -gt 0 -and $global:W.Reads -ge $global:W.AppearAtRead -and $null -ne $global:W.AppearDialog) {
        $global:W.Dialog = $global:W.AppearDialog; $global:W.AppearDialog = $null
    }
    $global:W.Log.Add("FullName:$(if ($null -ne $global:W.Dialog) { 'null' } else { 'sln' })")
    if ($null -ne $global:W.Dialog) { $null } else { $global:ResetSln }
}
$sol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:W.Log.Add('Solution.Close'); $global:W.Closed = $true }
$sol | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) $global:W.Log.Add('Solution.Open'); $global:W.Opened = $true }
$docs = [PSCustomObject]@{ Count = 0 }
$docs | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($m) $global:W.Log.Add('Documents.CloseAll') }
$resetDte = [PSCustomObject]@{ Solution = $sol; Documents = $docs }
$global:ResetSln = $sln
$okSm = [PSCustomObject]@{ Mock = $true }
$okSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) [PSCustomObject]@{ Name = 'TIPC' } }
$global:OkSm = $okSm

$origFns = & $mod { @{ Dlg = ${function:Find-TcIdeModalDialog}; Rp = ${function:Close-TcReloadPrompt}; Conn = ${function:Connect-TcIde} } }
& $mod {
    Set-Item -Path function:script:Find-TcIdeModalDialog -Value { param($ProcessId, $TimeoutSec) $global:W.Log.Add("Modal:$(if ($null -ne $global:W.Dialog) { $global:W.Dialog.Kind } else { 'none' })"); $global:W.Dialog }
    Set-Item -Path function:script:Close-TcReloadPrompt -Value { param($Dialog, $Answer, $TimeoutSec) $global:W.Log.Add("ClosePrompt:$Answer"); $global:W.Dialog = $null; @{ Sent = $true; Dismissed = $true; NextDialog = $null; Reason = 'mock' } }
    Set-Item -Path function:script:Connect-TcIde -Value { param($SolutionPath, $ProgId, [switch]$NoLaunch) $global:W.Log.Add('Connect'); $script:TcSolutionPath = $SolutionPath; $script:TcSysManager = $global:OkSm; [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 0; selectedBy = 'solution-match'; sysManagerAvailable = $true; silentMode = $true } } }
}
function Start-Reset {
    param([string]$ModulePath, [hashtable]$Params = @{})
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $resetDte $ModulePath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Reset-TcSolution -TimeoutSec 10 @Params
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

    # --- regression: guard read stays $null without any dialog -> RESET_SOLUTION_UNVERIFIED after -TimeoutSec ---
    Reset-World -Dialog $null
    $stuck = [PSCustomObject]@{ Mock = $true }
    $stuck | Add-Member -MemberType ScriptProperty -Name FullName -Value { $global:W.Log.Add('FullName:null'); $null }
    $stuck | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:W.Closed = $true }
    & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } ([PSCustomObject]@{ Solution = $stuck; Documents = $docs }) $sln
    $r = Reset-TcSolution -TimeoutSec 5
    Check 'regression: FullName $null, no dialog -> RESET_SOLUTION_UNVERIFIED, nothing closed, modal checked in the poll' ((-not $r.success) -and $r.error.code -eq 'RESET_SOLUTION_UNVERIFIED' -and -not $global:W.Closed -and @($global:W.Log | Where-Object { $_ -eq 'Modal:none' }).Count -ge 2) ("{0} | {1}" -f (Get-LogText).Substring(0, [Math]::Min(200, (Get-LogText).Length)), (J $r.error))

    # --- E-H (#87 retest 2026-11-02): the prompt comes up AFTER the guard ---
    $origFns2 = & $mod { @{ Sm = ${function:Get-TcSysManager}; Up = ${function:Get-TcUnsavedPlcObject} } }
    & $mod {
        Set-Item -Path function:script:Get-TcSysManager -Value { param([switch]$Refresh) $global:OkSm }
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
        param([hashtable]$Set)
        Reset-World -Dialog $null
        foreach ($k in $Set.Keys) { $global:W[$k] = $Set[$k] }
        if (-not $global:W.ContainsKey('CheckMode')) { $global:W.CheckMode = 'clean' }
        & $mod { param($d, $s) $script:TcIdeConnected = $true; $script:TcDte = $d; $script:TcSolutionPath = $s; $script:TcIdeProcessId = $null; $script:TcProgId = $null; $script:TcSysManager = $null } $dteG $sln
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Reset-TcSolution -TimeoutSec 10
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

        $r = Start-ResetG -Set @{ CloseAppear = $true; LaterDialog = $projectDlg }
        # (no timing check: without an IDE pid there is no watchdog, so the rejected Close goes through
        # the Invoke-TcComRetry busy backoff, ~15 s, before the dialog check)
        Check 'G2 Solution.Close rejected while a project prompt comes up -> Yes, success' ($r.success -and $r.data.answeredYes -eq $true -and -not $global:W.Closed) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))

        $r = Start-ResetG -Set @{ CloseAppear = $true; LaterDialog = $otherDlg }
        Check 'H Solution.Close fails, other dialog up -> IDE_MODAL_DIALOG (not SOLUTION_CLOSE_FAILED)' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and $r.data.dialogKind -eq 'unknown' -and -not $global:W.Closed) ("{0:N1}s {1} | {2}" -f $global:LastSec, (Get-LogText), (J $r))
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
