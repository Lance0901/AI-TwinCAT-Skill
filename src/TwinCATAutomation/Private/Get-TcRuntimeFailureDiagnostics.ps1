function Get-TcRuntimeFailureDiagnostics {
    <#
    .SYNOPSIS
        data.diagnostics of a runtime that did not come up (Enable-TcConfig after Activate,
        Set-TcSystemState stuck in Config, #194): modal dialog, XAE Error List rows, Boot package.
    .DESCRIPTION
        Never throws: every item that cannot be collected is marked, never reported as "nothing found".
          dialog              @{ title; text } of the modal dialog of the connected IDE, else $null
          dialogScanComplete  $false when the scan did not complete (#42; modalScan then says why)
                              or there is no IDE connection (-NoIde: modalScan.reason = 'no-ide')
          errorList           first 10 error descriptions of the XAE Error List (not read while a
                              dialog is up; #138: the rows of an incomplete read are listed too)
          errorListError      why the list is missing / partial ($null when read completely);
                              a dialog is up -> 'unavailable: not read while a modal dialog is up
                              ...' (#198: an empty list then never reads as "no errors")
          bootPackage         Get-TcBootPackageDiff (status match / mismatch / unavailable), $null
                              when the comparison threw
          modalScan           only when dialogScanComplete is $false (ConvertTo-TcModalScanInfo shape)
    .PARAMETER DialogScan
        A scan result the caller already has (a dialog record, an incomplete-scan record, or 'none'
        = scanned, no dialog); then no second scan is made (#42).
    .PARAMETER Deadline
        Overall deadline of the caller ([DateTime]). The dialog scan (when no -DialogScan is given)
        runs inside the time left (Find-TcIdeModalDialogWithin); the Error List read gets at most
        the time left and is skipped when less than 5 s are left (Get-TcBuildErrors accepts
        5..600 s; 'skipped: -TimeoutSec budget exhausted'). Without -Deadline: unbounded scan
        (Find-TcIdeModalDialog) and the full Error List budget, as before.
    .PARAMETER NoIde
        No IDE connection (Set-TcSystemState used over ADS only): dialog and Error List are not
        read and marked unavailable (dialogScanComplete $false, modalScan.reason 'no-ide',
        errorListError 'unavailable: no IDE connection'). Find-TcIdeModalDialog would return $null
        without an IDE pid, which reads as "no dialog".
    .NOTES
        -SolutionPath, -Platform, -AmsNetId, -AdsPorts and -Variant are passed to
        Get-TcBootPackageDiff (empty platform / solution -> status 'unavailable'); a comparison
        that throws (e.g. no -AmsNetId) leaves bootPackage $null.
    #>
    [CmdletBinding()]
    param(
        [object]$DialogScan,
        [object]$Deadline,
        [switch]$NoIde,
        [string]$SolutionPath,
        [string]$Platform,
        [string]$AmsNetId,
        [int[]]$AdsPorts,
        [string]$Variant
    )
    $diag = [ordered]@{ dialog = $null; dialogScanComplete = $true; errorList = @(); errorListError = $null; bootPackage = $null }
    if ($NoIde) {
        $diag.dialogScanComplete = $false
        $diag['modalScan'] = ConvertTo-TcModalScanInfo -Scan @{ Reason = 'no-ide'; Message = 'no IDE connection (Connect-TcIde): the modal dialog was not scanned' }
        $diag.errorListError = 'unavailable: no IDE connection'
    }
    else {
        try {
            $dlg = if ($null -ne $DialogScan) { $DialogScan } else { Get-TcDiagnosticsDialogScan -Deadline $Deadline }
            if (Test-TcDiagnosticsDialogClear $dlg) { $dlg = $null }
            # #42: an incomplete scan is reported as such (dialogScanComplete false), never as "no dialog"
            if (Test-TcModalScanIncomplete $dlg) { $diag.dialogScanComplete = $false; $diag['modalScan'] = ConvertTo-TcModalScanInfo -Scan $dlg }
            elseif ($null -ne $dlg) { $diag.dialog = [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } }
        } catch { $diag.dialogScanComplete = $false }
        # time left for the Error List; less than 5 s (Get-TcBuildErrors minimum) -> not read (PR #200 review)
        $elBudget = [int]$script:TcBuildErrorListTimeoutSec
        if ($null -ne $Deadline) { $elBudget = [int][Math]::Min($elBudget, [Math]::Floor((([DateTime]$Deadline) - (Get-Date)).TotalSeconds)) }
        if ($null -ne $diag.dialog) {
            # #198: deliberately not read (the Error List is opened through DTE, which the dialog blocks);
            # say so instead of an empty list with errorListError $null (reads as "no errors")
            $diag.errorListError = 'unavailable: not read while a modal dialog is up (the Error List is opened through the IDE, which the dialog blocks); see data.diagnostics.dialog'
        }
        elseif ($null -ne $Deadline -and $elBudget -lt 5) {
            $diag.errorListError = 'skipped: -TimeoutSec budget exhausted'
        }
        else {
            try {
                # #107: the Error List budget of the build paths, capped by what is left of the deadline
                # (Get-TcBuildErrors accepts 5..600 s); an upper bound, the scan returns when done.
                $elBudget = [Math]::Max(5, $elBudget)
                $el = Get-TcBuildErrors -TimeoutSec $elBudget
                $elState = Get-TcErrorListReadState -Result $el
                # #138: the rows of an incomplete read are listed too; errorListError still says it was partial
                if ($elState.usable) { $diag.errorList = @(@($el.data.errors) | Select-Object -First 10 | ForEach-Object { [string]$_.description }) }
                if (-not $el.success -and -not $elState.errorsComplete) { $diag.errorListError = [string]$el.error.code }
            } catch { $diag.errorListError = $_.Exception.Message }
        }
    }
    try { $diag.bootPackage = Get-TcBootPackageDiff -SolutionPath $SolutionPath -Platform $Platform -AmsNetId $AmsNetId -AdsPorts $AdsPorts -Variant $Variant } catch { }
    [PSCustomObject]$diag
}

# ADS 1809 / 0x711 in dialog or Error List text (ASCII fragments of the XAE / ADS message, never a
# localized PowerShell message). Shared with the Enable-TcConfig diagnostics. A bare "1809" is not
# enough (a line number / port / timestamp can contain it): only "AdsError: 1809" as XAE writes it
# (measured 2026-11-08, see Get-TcStuckInConfigHint), the hex code or the two English texts.
$script:TcSymbolVersionPattern = '(?i)AdsError:\s*1809|0x711|symbol version invalid|symbol description does not match'

function Get-TcDiagnosticsDialogScan {
    <#
    .SYNOPSIS
        Modal dialog scan of the failure diagnostics (PR #200 review): the dialog record, the
        incomplete-scan record, or 'none' (scanned, no dialog). Never throws.
    .DESCRIPTION
        Run BEFORE any DTE read of a diagnostics path: a DTE call blocked by a modal dialog may never
        return. Callers read DTE only when the result is 'none' (Test-TcDiagnosticsDialogClear) and
        pass the result on as Get-TcRuntimeFailureDiagnostics -DialogScan, so the scan runs once.
        With -Deadline the scan fits in the time left (Find-TcIdeModalDialogWithin; less than 2 s ->
        incomplete record 'no-budget', never "no dialog"); without it Find-TcIdeModalDialog as before.
    .PARAMETER Deadline
        [DateTime] overall deadline of the caller, or $null.
    #>
    [CmdletBinding()]
    param([object]$Deadline)
    $dlg = $null
    try {
        $dlg = if ($null -ne $Deadline) { Find-TcIdeModalDialogWithin -BudgetSec ([double](([DateTime]$Deadline) - (Get-Date)).TotalSeconds) } else { Find-TcIdeModalDialog }
    }
    catch { $dlg = New-TcModalScanIncomplete -Reason 'error' -Message "dialog scan failed: $($_.Exception.Message)" }
    if ($null -eq $dlg) { return 'none' }
    $dlg
}

function Get-TcCachedSolutionPlatform {
    <#
    .SYNOPSIS
        Platform for the _Boot comparison from the last Get-TcSolutionPlatform read of the current
        solution (Connect-TcIde, Set-TcTarget, Build-TcProject ...; $script:TcLastSolutionPlatform),
        without a DTE call (#198: used while a modal dialog may be up). projectPlatform when known,
        else the solution platform; $null when nothing was read for the current solution.
    #>
    $c = $script:TcLastSolutionPlatform
    if ($null -eq $c) { return $null }
    if ([string]$c.solutionPath -ne [string]$script:TcSolutionPath) { return $null }
    if (-not [string]::IsNullOrWhiteSpace([string]$c.projectPlatform)) { return [string]$c.projectPlatform }
    if (-not [string]::IsNullOrWhiteSpace([string]$c.platform)) { return [string]$c.platform }
    $null
}

function Set-TcHintAfterStopText {
    <#
    .SYNOPSIS
        Replaces -OldHint at the end of error.hint by -NewHint, keeping what Add-TcLifecycleBlockResult
        put in front (the stop text). Used when the hint is refined after the lifecycle block was
        written (PR #200 review: the block is written first, the diagnostics come after it).
    #>
    param([object]$Result, [string]$OldHint, [string]$NewHint)
    if ($null -eq $Result -or $null -eq $Result.error -or [string]::IsNullOrWhiteSpace($NewHint) -or $NewHint -eq $OldHint) { return }
    $hp = $Result.error.PSObject.Properties['hint']
    $cur = if ($null -ne $hp) { [string]$hp.Value } else { '' }
    $new = if (-not [string]::IsNullOrEmpty($OldHint) -and $cur.EndsWith($OldHint)) { ($cur.Substring(0, $cur.Length - $OldHint.Length).TrimEnd() + ' ' + $NewHint).Trim() }
           elseif ([string]::IsNullOrWhiteSpace($cur)) { $NewHint }
           else { "$cur $NewHint" }
    $Result.error | Add-Member -NotePropertyName 'hint' -NotePropertyValue $new -Force
}

function Test-TcDiagnosticsDialogClear {
    <#
    .SYNOPSIS
        $true when a Get-TcDiagnosticsDialogScan result is 'none' (scan complete, no dialog): only
        then may a diagnostics path read DTE.
    #>
    param([object]$Scan)
    return ($Scan -is [string] -and $Scan -eq 'none')
}

function Get-TcStuckInConfigHint {
    <#
    .SYNOPSIS
        error.hint of Set-TcSystemState when the runtime stays in / falls back to Config (#194).
    .DESCRIPTION
        Decided from data.diagnostics (Get-TcRuntimeFailureDiagnostics) and data.licenses
        (Get-TcLicenseDiagnosis), in this order:
          1. dialog or Error List text matching $script:TcSymbolVersionPattern -> the
             ADS_SYMBOL_VERSION_INVALID explanation (Build + Enable-TcConfig -Force), with the
             dialog text (cut to 300 chars). The cause follows bootPackage.status: 'mismatch' ->
             stated (Boot CurrentConfig and PLC .app differ, files listed); 'match' -> not a stale
             CurrentConfig on the target; unavailable / missing -> "可能是" only.
             Measured 2026-11-08 (4026 64-bit XAE Shell + local UmRT, #194 / #40): the XAE dialog
             "Target system reports a fatal error" said "... AdsError: 1809 (0x711, ADS ERROR: symbol
             version invalid) << failed!" while every license was valid. 0x711 =
             ADSERR_DEVICE_SYMBOLVERSIONINVALID, InfoSys ADS Return Codes
             https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html
          2. another dialog / Error List row -> that text first.
          3. no dialog / row, license problem -> the license text (as before).
        A license text is only added when the license server reported an expired / invalid
        license; when it reported at least one license and all of them valid the hint never names
        a missing license and says "已讀到的 N 個授權都有效" (licenses not listed are not judged).
        No license read at all is not "all valid".
        License server unreadable and no dialog: the unchanged hint of -Code.
    .PARAMETER Code
        SYSTEM_STATE_TIMEOUT or SYSTEM_STATE_MISMATCH.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [object]$Diagnostics,
        [object]$License
    )
    $base = Get-TcErrorHint -Code $Code
    $licText = if ($null -ne $License -and -not [string]::IsNullOrWhiteSpace([string]$License.text)) { [string]$License.text } else { $null }
    # PR #200 review: "every license valid" only when at least one license was read; nothing read is
    # not "all valid"
    $licCount = if ($null -ne $License) { @(@($License.licenses) | Where-Object { $null -ne $_ }).Count } else { 0 }
    $licAllValid = ($null -ne $License -and $null -eq $licText -and $licCount -gt 0)
    $licValidText = "target 授權伺服器回報，已讀到的 $licCount 個授權都有效;沒列出的 TF 授權不在這次判斷範圍內(data.licenses)。"

    $dialogText = $null
    if ($null -ne $Diagnostics -and $null -ne $Diagnostics.dialog) {
        $dialogText = ("$([string]$Diagnostics.dialog.title) | $([string]$Diagnostics.dialog.text)" -replace '\s+', ' ').Trim(' ', '|')
    }
    $rows = @()
    if ($null -ne $Diagnostics) { $rows = @(@($Diagnostics.errorList) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_ -replace '\s+', ' ').Trim() }) }
    $cut = { param([string]$t) if ($t.Length -gt 300) { $t.Substring(0, 300) + '...' } else { $t } }

    $all = @($dialogText) + $rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $symbol = @($all | Where-Object { $_ -match $script:TcSymbolVersionPattern }) | Select-Object -First 1
    if ($null -ne $symbol) {
        $src = if ($null -ne $dialogText -and $dialogText -eq $symbol) { 'XAE dialog' } else { 'XAE Error List' }
        # PR #200 review: the cause is only stated as fact when the Boot comparison found a mismatch
        $bp = if ($null -ne $Diagnostics) { $Diagnostics.bootPackage } else { $null }
        $bpStatus = if ($null -ne $bp) { [string]$bp.status } else { '' }
        $cause = switch ($bpStatus) {
            'mismatch' { "target Boot 裡的 configuration package(CurrentConfig)與 PLC .app 不一致:data.diagnostics.bootPackage 比出不一致的檔案 $(@($bp.mismatches) -join ', '),所以 runtime 啟動時退回 Config。" }
            'match' { "data.diagnostics.bootPackage 比對一致(專案 _Boot 與 target Boot 的 CurrentConfig / PLC .app 相同),所以這次不是 target 上 CurrentConfig 舊版造成;原因要看上面這段訊息全文(Get-TcIdeModalDialog / Get-TcBuildErrors)。" }
            default {
                $why = if ($null -ne $bp -and -not [string]::IsNullOrWhiteSpace([string]$bp.reason)) { "Boot 未比對:$([string]$bp.reason)" } else { 'Boot 未比對' }
                "可能是 target Boot 裡的 configuration package(CurrentConfig)與 PLC .app 不一致($why)。"
            }
        }
        $h = "$src 回報 ADS 1809(0x711 ADSERR_DEVICE_SYMBOLVERSIONINVALID,symbol version invalid):「$(& $cut $symbol)」。runtime 啟動時 PLC 的 symbol description 與 application 版本不符。${cause}下一步:Build-TcProject 後 Enable-TcConfig -Force(MCP:BuildProject、EnableConfig Force=true),讓 Activate 重寫 Boot;仍失敗見 docs/troubleshooting.md「ADS_SYMBOL_VERSION_INVALID」與「BOOT_PACKAGE_MISMATCH」。出處 https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html"
        if ($null -ne $licText) { $h = "$h $licText" }
        return $h
    }
    if ($all.Count -gt 0) {
        $what = if ($null -ne $dialogText) { "XAE dialog:「$(& $cut $dialogText)」" } else { "XAE Error List:「$(& $cut (@($rows | Select-Object -First 3) -join ' / '))」" }
        $h = "runtime 停在 Config,$what(data.diagnostics)。先依這段訊息處理(Get-TcIdeModalDialog / Get-TcBuildErrors 讀完整內容),再 Get-TcSystemState 確認狀態後 Enable-TcConfig -Force。"
        if ($null -ne $licText) { $h = "$h $licText" }
        elseif ($licAllValid) { $h = "$h $licValidText" }
        return $h
    }
    if ($null -ne $licText) { return "$licText $base" }
    if ($licAllValid) {
        # every license read is valid: the generic hints name a missing license as a likely cause; drop that
        if ($Code -eq 'SYSTEM_STATE_TIMEOUT') {
            return "TwinCAT 系統未在時限內切到 Run,停在 Config;$licValidText 看 data.diagnostics(XAE modal dialog、Error List、Boot package 比對;dialogScanComplete = false 或 errorListError 表示沒讀到),用 Get-TcIdeModalDialog / Get-TcBuildErrors 讀 XAE 的 fatal error,Get-TcSystemState 確認目前狀態，檢查 TwinCAT System Service 的錯誤。"
        }
        # PR #200 review: no general claim; the 1809 case is one measured example (2026-11-08, 4026 64-bit
        # XAE Shell + local UmRT, #194)
        return "TwinCAT 短暫進入要求的狀態後又退回 Config(data.stateTrace);$licValidText runtime 啟動失敗會這樣，例如實測過(2026-11-08,4026 64-bit XAE Shell + 本機 UmRT)PLC 的 symbol description 與 application 不一致(ADS 1809 / 0x711),原因也可能是 Boot 目錄的 CurrentConfig 是舊的。看 data.diagnostics(dialog、Error List、bootPackage),用 Get-TcIdeModalDialog / Get-TcBuildErrors 讀 fatal error,bootPackage 比出不一致時 Build-TcProject 後 Enable-TcConfig -Force"
    }
    return $base
}
