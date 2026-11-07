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
          errorListError      why the list is missing / partial ($null when read completely)
          bootPackage         Get-TcBootPackageDiff (status match / mismatch / unavailable), $null
                              when the comparison threw
          modalScan           only when dialogScanComplete is $false (ConvertTo-TcModalScanInfo shape)
    .PARAMETER DialogScan
        A scan result the caller already has (a dialog record, an incomplete-scan record, or 'none'
        = scanned, no dialog); then no second scan is made (#42).
    .PARAMETER Deadline
        Overall deadline of the caller: the Error List read gets at most the time left (min 5 s);
        past it the list is skipped ('skipped: -TimeoutSec budget exhausted').
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
            $dlg = if ($null -ne $DialogScan) { if ($DialogScan -is [string] -and $DialogScan -eq 'none') { $null } else { $DialogScan } } else { Find-TcIdeModalDialog }
            # #42: an incomplete scan is reported as such (dialogScanComplete false), never as "no dialog"
            if (Test-TcModalScanIncomplete $dlg) { $diag.dialogScanComplete = $false; $diag['modalScan'] = ConvertTo-TcModalScanInfo -Scan $dlg }
            elseif ($null -ne $dlg) { $diag.dialog = [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } }
        } catch { $diag.dialogScanComplete = $false }
        if ($null -ne $Deadline -and (Get-Date) -ge $Deadline) {
            $diag.errorListError = 'skipped: -TimeoutSec budget exhausted'
        }
        elseif ($null -eq $diag.dialog) {
            try {
                # #107: the Error List budget of the build paths, capped by what is left of -TimeoutSec
                # (Get-TcBuildErrors accepts 5..600 s); an upper bound, the scan returns when done.
                $elBudget = [int]$script:TcBuildErrorListTimeoutSec
                if ($null -ne $Deadline) { $elBudget = [int][Math]::Min($elBudget, [Math]::Floor(($Deadline - (Get-Date)).TotalSeconds)) }
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
# localized PowerShell message). Same pattern as the Enable-TcConfig diagnostics.
$script:TcSymbolVersionPattern = '(?i)symbol description does not match|1809|0x711|symbol version'

function Get-TcStuckInConfigHint {
    <#
    .SYNOPSIS
        error.hint of Set-TcSystemState when the runtime stays in / falls back to Config (#194).
    .DESCRIPTION
        Decided from data.diagnostics (Get-TcRuntimeFailureDiagnostics) and data.licenses
        (Get-TcLicenseDiagnosis), in this order:
          1. dialog or Error List text with ADS 1809 / 0x711 / "symbol version" -> the
             ADS_SYMBOL_VERSION_INVALID explanation (Boot package and PLC .app differ; Build +
             Enable-TcConfig -Force), with the dialog text (cut to 300 chars).
             Measured 2026-11-08 (4026 64-bit XAE Shell + local UmRT, #194 / #40): the XAE dialog
             "Target system reports a fatal error" said "... AdsError: 1809 (0x711, ADS ERROR: symbol
             version invalid) << failed!" while every license was valid. 0x711 =
             ADSERR_DEVICE_SYMBOLVERSIONINVALID, InfoSys ADS Return Codes
             https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html
          2. another dialog / Error List row -> that text first.
          3. no dialog / row, license problem -> the license text (as before).
        A license text is only added when the license server reported an expired / invalid
        license; when it reported all licenses valid the hint never names a missing license.
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
    $licAllValid = ($null -ne $License -and $null -eq $licText)

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
        $boot = ''
        if ($null -ne $Diagnostics -and $null -ne $Diagnostics.bootPackage -and [string]$Diagnostics.bootPackage.status -eq 'mismatch') {
            $boot = " data.diagnostics.bootPackage 也比出不一致:$(@($Diagnostics.bootPackage.mismatches) -join ', ')。"
        }
        $h = "$src 回報 ADS 1809(0x711 ADSERR_DEVICE_SYMBOLVERSIONINVALID,symbol version invalid):「$(& $cut $symbol)」。runtime 啟動時 PLC 的 symbol description 與 application 不同版:target Boot 裡的 configuration package(CurrentConfig)與 PLC .app 不一致,所以退回 Config(實測 2026-11-08,#194)。${boot}下一步:Build-TcProject 後 Enable-TcConfig -Force(MCP:BuildProject、EnableConfig Force=true),讓 Activate 重寫 Boot;仍不一致見 docs/troubleshooting.md「ADS_SYMBOL_VERSION_INVALID」與「BOOT_PACKAGE_MISMATCH」。出處 https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html"
        if ($null -ne $licText) { $h = "$h $licText" }
        return $h
    }
    if ($all.Count -gt 0) {
        $what = if ($null -ne $dialogText) { "XAE dialog:「$(& $cut $dialogText)」" } else { "XAE Error List:「$(& $cut (@($rows | Select-Object -First 3) -join ' / '))」" }
        $h = "runtime 停在 Config,$what(data.diagnostics)。先依這段訊息處理(Get-TcIdeModalDialog / Get-TcBuildErrors 讀完整內容),再 Get-TcSystemState 確認狀態後 Enable-TcConfig -Force。"
        if ($null -ne $licText) { $h = "$h $licText" }
        elseif ($licAllValid) { $h = "$h target 授權伺服器回報的授權都有效(data.licenses)。" }
        return $h
    }
    if ($null -ne $licText) { return "$licText $base" }
    if ($licAllValid) {
        # every license valid: the generic hints name a missing license as a likely cause; drop that
        if ($Code -eq 'SYSTEM_STATE_TIMEOUT') {
            return 'TwinCAT 系統未在時限內切到 Run,停在 Config;target 授權伺服器回報的授權都有效(data.licenses)。看 data.diagnostics(XAE modal dialog、Error List、Boot package 比對;dialogScanComplete = false 或 errorListError 表示沒讀到),用 Get-TcIdeModalDialog / Get-TcBuildErrors 讀 XAE 的 fatal error,Get-TcSystemState 確認目前狀態,檢查 TwinCAT System Service 的錯誤。'
        }
        return 'TwinCAT 短暫進入要求的狀態後又退回 Config(data.stateTrace),target 授權伺服器回報的授權都有效(data.licenses):通常是 runtime 啟動失敗，例如 PLC 的 symbol description 與 application 不一致(ADS 1809 / 0x711)或 Boot 目錄的 CurrentConfig 是舊的。看 data.diagnostics(dialog、Error List、bootPackage),用 Get-TcIdeModalDialog / Get-TcBuildErrors 讀 fatal error,Boot 不一致時 Build-TcProject 後 Enable-TcConfig -Force'
    }
    return $base
}
