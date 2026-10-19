# NOTE: this file contains non-ASCII hint text and MUST be saved as UTF-8 with BOM
# so that Windows PowerShell 5.1 reads it correctly.

# Central hint table. Keys are error codes emitted by the module.
$script:TcErrorHints = @{
    'ADS_PORT_NOT_FOUND'   = 'PLC runtime port {port} 不存在:程式尚未下載或 PLC 未啟動。先 Enter-TcPlcOnline,再 Set-TcPlcState -State Run'
    'ADS_TARGET_NOT_FOUND' = 'AmsNetId 無回應:TwinCAT 可能正在重啟。等待 Set-TcSystemState 回到 Run 後重新 Connect-TcAds'
    'ADS_SYMBOL_NOT_FOUND' = '符號不存在:新程式尚未下載,或路徑拼錯。用 Get-TcSymbols 確認'
    'ADS_INVALID_STATE'    = 'PLC 狀態不允許此操作:順序應為 Enable-TcConfig → Enter-TcPlcOnline → Set-TcPlcState Run'
    'ADS_TIMEOUT'          = 'ADS 逾時:目標忙碌或網路問題,稍後重試'
    'IDE_BUSY'             = 'XAE 被 modal dialog 或 license 視窗擋住,關掉後重試'
    'IDE_MODAL_DIALOG'     = 'XAE/VS 有 modal 視窗(例如 Assertion Failed、VS 帳戶設定、Target system reports a fatal error),請手動處理後重試;模組無法自動關閉。若 dialog 關不掉,kill IDE 後重新 Connect-TcIde'
    'IDE_TIMEOUT'          = 'DTE 呼叫超過預期時間才返回:XAE 可能被 dialog 卡住或正在跑長操作;用 Get-TcIdeModalDialog 檢查,必要時 kill IDE 後重新 Connect-TcIde'
    'IDE_CRASHED'          = 'IDE 行程已消失(可能 OutOfMemory crash;查 Windows 事件 1026、%LOCALAPPDATA%\CrashDumps\TcXaeShell.exe.<pid>.dmp)。重新 Connect-TcIde -SolutionPath ...,再從 Build/Enable-TcConfig 開始'
    'IDE_LAUNCH_FAILED'    = 'IDE 啟動後 60 秒內 DTE 未就緒:確認 XAE 可手動開啟、沒有首次啟動精靈 / 帳戶登入視窗;可改用 -ProgId 指定另一個 IDE,或先手動開好 IDE 再 Connect-TcIde'
    'NOT_CONNECTED'        = '呼叫 Connect-TcAds;若剛做過 Enable-TcConfig,TwinCAT 已重啟,必須重連'
    'AMS_NETID_REQUIRED'   = '先 Connect-TcIde -SolutionPath <sln>,AmsNetId 會自動偵測'
    'PROJECT_OPEN_TIMEOUT' = 'Solution 開啟逾時:確認 .sln 內含 TwinCAT 專案,且 XAE 沒有被 dialog 擋住;可重跑 Connect-TcIde -SolutionPath <sln>'
    'SYSTEM_STATE_TIMEOUT' = 'TwinCAT 系統狀態未在時限內切換:用 Get-TcSystemState 確認目前狀態,檢查 XAE / TwinCAT System Service 是否有錯誤。若 target 是 UmRT 且剛 Activate 就停在 Config,常見原因是 license 不足(trial 未涵蓋專案用到的 TF),請在 XAE 的 License 節點確認'
    'PLC_NOT_LOADED'       = 'PLC 程式尚未下載(port 851 不存在或 AdsState=Invalid):先 Enter-TcPlcOnline(或 Enable-TcConfig -Force),再 Set-TcPlcState -State Run'
    'PLC_RUN_TIMEOUT'      = 'PLC 未在時限內進入 Run:用 Get-TcPlcState 看目前狀態;若為 Error/Stop,檢查 PLC 例外或 Build 錯誤後重新 Enter-TcPlcOnline'
    'CYCLE_TIMEOUT'        = 'Enable-TcConfig -Force 的 -TimeoutSec 總預算已用完:看 data.steps 卡在哪一步,加大 -TimeoutSec 或用 Get-TcSystemState / Get-TcPlcState 確認狀態'
    'ERRORLIST_UNAVAILABLE' = 'Error List 視窗讀不到:確認 XAE 視窗可見且 Error List 沒被 auto-hide;可手動 View > Error List 後重試。需要英文 UI(視窗名 ''Error List''、按鈕 ''N Errors''),其他語系的 XAE 讀不到'
    'BUILD_STATUS_UNKNOWN'  = 'Build 結果無法判定:LastBuildInfo 與 Error List 都讀不到,請看 XAE 的 Error List 後再決定;不要把這個結果當成 build 成功'
}
# Compile errors (Build-TcProject, only when the build really failed): generic BUILD_FAILED
# from a COM exception keeps no hint, so this one is looked up explicitly.
$script:TcErrorHints['BUILD_FAILED_COMPILE'] = '看 data.errorItems(code / description / file / line);修正後重跑 Build-TcProject'
# Legacy code kept by Read-TcVariable for a missing symbol: same hint as ADS_SYMBOL_NOT_FOUND
$script:TcErrorHints['SYMBOL_NOT_FOUND'] = $script:TcErrorHints['ADS_SYMBOL_NOT_FOUND']

function Get-TcErrorHint {
    <#
    .SYNOPSIS
        Returns the next-action hint for a module error code, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter()]
        [int]$Port = 0
    )
    if (-not $script:TcErrorHints.ContainsKey($Code)) { return $null }
    $hint = $script:TcErrorHints[$Code]
    # {port}: the ADS port the failing cmdlet actually used (default 851 = PLC runtime 1)
    if ($hint -match '\{port\}') {
        $p = if ($Port -gt 0) { $Port } else { 851 }
        $hint = $hint -replace '\{port\}', [string]$p
    }
    return $hint
}

function ConvertTo-TcAdsErrorCode {
    <#
    .SYNOPSIS
        Maps an ADS / COM exception to a module error code with a next-action hint.
    .DESCRIPTION
        Accepts an Exception, an ErrorRecord, or a plain message string. Inspects the
        message chain (including inner exceptions) and, when available, the numeric
        ErrorCode / HResult, and returns a hashtable:
            @{ Code = '<CODE>'; Hint = '<hint>'; Message = '<original message>' }
        Returns $null when the error is not a known ADS/COM condition so the caller
        can fall back to its own generic code.
    .PARAMETER InputObject
        Exception, ErrorRecord or string.
    .PARAMETER Port
        ADS port the failing call used; substituted into hints such as
        ADS_PORT_NOT_FOUND ("port {port}"). 0 = default 851.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter()]
        [int]$Port = 0
    )

    if ($null -eq $InputObject) { return $null }

    # --- Normalise input to (exception, message) ---
    $exception = $null
    $message = ''
    if ($InputObject -is [System.Management.Automation.ErrorRecord]) {
        $exception = $InputObject.Exception
        $message = $InputObject.ToString()
    }
    elseif ($InputObject -is [System.Exception]) {
        $exception = $InputObject
        $message = $InputObject.Message
    }
    else {
        $message = [string]$InputObject
    }

    # Collect the full message chain + numeric codes so that wrapped exceptions
    # (MethodInvocationException -> AdsErrorException / COMException) still match.
    $chain = @($message)
    $numericCodes = @()
    $ex = $exception
    while ($null -ne $ex) {
        if (-not [string]::IsNullOrWhiteSpace($ex.Message)) { $chain += $ex.Message }
        $errCodeProp = $ex.PSObject.Properties['ErrorCode']
        if ($null -ne $errCodeProp -and $null -ne $errCodeProp.Value) {
            try { $numericCodes += ([int64]$errCodeProp.Value -band 0xFFFFFFFF) } catch { }
        }
        $hresultProp = $ex.PSObject.Properties['HResult']
        if ($null -ne $hresultProp -and $null -ne $hresultProp.Value) {
            try { $numericCodes += ([int64]$hresultProp.Value -band 0xFFFFFFFF) } catch { }
        }
        $ex = $ex.InnerException
    }
    $text = ($chain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '

    $code = $null

    # Order matters: most specific patterns first.
    # NOT_CONNECTED (thrown by Ensure-TcAdsConnection) wins even when the message also
    # carries the underlying ADS error from a failed auto-reconnect attempt.
    if ($text -match '(?i)Not connected to TwinCAT ADS') {
        $code = 'NOT_CONNECTED'
    }
    # Thrown by Invoke-TcComRetry; checked before IDE_BUSY because their messages
    # also carry the original 0x80010001 text.
    elseif ($text -match 'IDE_MODAL_DIALOG') {
        $code = 'IDE_MODAL_DIALOG'
    }
    elseif ($text -match 'IDE_CRASHED') {
        $code = 'IDE_CRASHED'
    }
    elseif ($text -match 'IDE_TIMEOUT') {
        $code = 'IDE_TIMEOUT'
    }
    elseif ($text -match '(?i)0x80010001|RPC_E_CALL_REJECTED|0x8001010A|RPC_E_SERVERCALL_RETRYLATER|IDE_BUSY' -or
        $numericCodes -contains 0x80010001 -or $numericCodes -contains 0x8001010A) {
        $code = 'IDE_BUSY'
    }
    elseif ($text -match '(?i)\b0x0*710\b|symbol\s+not\s+found|symbol\s+could\s+not\s+be\s+found' -or $numericCodes -contains 0x710) {
        $code = 'ADS_SYMBOL_NOT_FOUND'
    }
    elseif ($text -match '(?i)\b0x0*712\b|invalid\s+state' -or $numericCodes -contains 0x712) {
        $code = 'ADS_INVALID_STATE'
    }
    elseif ($text -match '(?i)\b0x0*745\b|time\s*out|timed\s+out' -or $numericCodes -contains 0x745) {
        $code = 'ADS_TIMEOUT'
    }
    elseif ($text -match '(?i)\b0x0*6\b|target\s+port\s+(could\s+)?not\s+(be\s+)?found|port\s+not\s+found' -or $numericCodes -contains 6) {
        $code = 'ADS_PORT_NOT_FOUND'
    }
    elseif ($text -match '(?i)\b0x0*7\b|target\s+machine\s+(could\s+)?not\s+(be\s+)?found|machine\s+not\s+found' -or $numericCodes -contains 7) {
        $code = 'ADS_TARGET_NOT_FOUND'
    }

    if ($null -eq $code) { return $null }

    return @{
        Code    = $code
        Hint    = (Get-TcErrorHint -Code $code -Port $Port)
        Message = $message
    }
}
