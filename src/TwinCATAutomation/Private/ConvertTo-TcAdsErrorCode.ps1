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
    'IDE_MODAL_DIALOG'     = 'XAE/VS 有 modal 視窗擋住 DTE 呼叫。先呼叫 Get-TcIdeModalDialog 看 kind:reload-prompt(檔案或 .plcproj 被磁碟上的工具改了)→ 直接 Reset-TcSolution;其他(例如 Assertion Failed、VS 帳戶設定、Target system reports a fatal error)模組無法自動關閉,請手動處理後重試,或 Disconnect-TcIde -Quit(本 session 啟動的 IDE 改用 Disconnect-TcIde -Quit -Kill),或 kill IDE 後重新 Connect-TcIde'
    'IDE_MODAL_DIALOG_RELOAD' = 'XAE 跳「File has been changed outside the environment. Reload the new file?」:開在編輯器裡的檔案(通常是 .TcPOU)被磁碟上的工具改了,DTE 呼叫被擋住;.plcproj 被改寫(內容相同也算)則跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」,同樣算 reload-prompt(reloadTarget = project)。直接呼叫 Reset-TcSolution:project 提示它會按 Yes(依 control id,語系無關)讓 XAE 自己 reload 專案再重連,不必 close/reopen;檔案提示它會關掉提示(WM_CLOSE)、關閉所有文件、Solution.Close 後在同一個 IDE 重開 solution 並重連(約 20~25 s);關不掉就在 XAE 按 Yes,或 kill IDE 後重新 Connect-TcIde -SolutionPath <sln>。之後改磁碟檔案的規則:POU 沒開在編輯器 → 直接改,XAE 約 5 s 自動吃到;開著 → 改完立刻 Reset-TcSolution(它會順便關掉編輯器,之後就不會再跳);改用 Write-TcPouCode(走 COM 寫 IDE 編輯 buffer,存檔或 Build 時才落地)則不會跳框'
    'IDE_QUIT_FAILED'      = 'IDE 沒有被關掉,行程仍在(pid 見 data.ideProcessId):(a) 被 modal dialog 擋住(data.dialog,quit 沒有嘗試,data.disconnected = false:連線完整保留):kind = reload-prompt → Reset-TcSolution 處理後再 Disconnect-TcIde -Quit;其他 dialog → 本 session 啟動的 IDE(data.ownedBySession = true)用 Disconnect-TcIde -Quit -Kill,否則手動 Stop-Process -Id <data.ideProcessId>。(b) DTE.Quit 失敗(data.quitError,COM 參考已釋放但 pid 有保留):data.ownedBySession = true 就直接接 Disconnect-TcIde -Quit -Kill(不用重連);否則手動 Stop-Process -Id <data.ideProcessId>。不要以為 IDE 已經關掉,下一次 Connect-TcIde 會黏回同一個被擋住的 IDE'
    'IDE_NOT_OWNED'        = '這個 IDE 不是本 session 啟動的(data.selectedBy 不是 launched,例如 solution-match),模組不會 kill 使用者自己開的 IDE。確定要關就自己 Stop-Process -Id <data.ideProcessId>,再重新 Connect-TcIde'
    'SOLUTION_CLOSE_FAILED' = 'Solution.Close 失敗:用 Get-TcIdeModalDialog 看 XAE 有沒有 dialog;必要時 Disconnect-TcIde -Quit(或 kill IDE)後重新 Connect-TcIde -SolutionPath <sln>'
    'NO_SOLUTION'          = '沒有開啟的 solution:先 Connect-TcIde -SolutionPath <sln> 或 Open-TcProject -Path <sln>'
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
    'ERRORLIST_UNAVAILABLE' = 'Error List 視窗讀不到:確認 XAE 視窗可見且 Error List 沒被 auto-hide;可手動 View > Error List(檢視 > 錯誤清單)後重試。支援英文 UI(''Error List''、按鈕 ''N Errors'')與繁中 VS2022(''錯誤清單''、按鈕 ''0 / 2 錯誤'');其他語系的視窗名讀不到'
    'BUILD_TIMEOUT'         = 'Build 在 -TimeoutSec 內沒有完成(SolutionBuild.BuildState 沒有到 3 = Done):用 Get-TcIdeModalDialog 檢查有沒有 dialog,看 XAE Output 視窗的 Build 進度;大型專案加大 -TimeoutSec 後重跑 Build-TcProject,XAE 沒反應就 kill IDE 後重新 Connect-TcIde'
    'PLATFORM_NOT_FOUND'    = 'Solution 沒有這個 platform:用 data.availablePlatforms 裡的名稱重跑 Set-TcTarget -AmsNetId <id> -Platform <name>(Usermode Runtime(UmRT)/ TwinCAT/BSD target 是 ''TwinCAT OS (x64)'',Windows RT target 是 ''TwinCAT RT (x64)'')'
    'PLATFORM_UNKNOWN'      = 'target 不支援 TARGETINFO(ADS 0x702),請用 -Platform ''<平台>'' 指定;UmRT / TwinCAT/BSD 為 ''TwinCAT OS (x64)''(Windows RT target 為 ''TwinCAT RT (x64)'')。只要改 target NetId 就加 -NoPlatformSwitch(NetId 已經設好了,data.targetSet = true)。平台由目標對象決定(不是 XAE 版本);solution platform 名稱可能對到別的 project platform,模組切換前會檢查 .tsproj 的 project platform,不符就回 PLATFORM_PROJECT_MISMATCH(看 data.platformMap)。TARGETINFO 說明:https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html'
    'PLATFORM_MISMATCH'     = 'Active solution platform 與 target platform 不一致,Activate 會失敗(Check config failed)。執行 Set-TcTarget -AmsNetId <id> -Platform ''<platform>'' 後重跑 Build-TcProject 與 Enable-TcConfig,或拿掉 -NoPlatformFix 讓 Enable-TcConfig 自己切換並重新 Build'
    'PLATFORM_PROJECT_MISMATCH' = 'Solution platform 名稱對了,但它底下的 TwinCAT 專案(.tsproj)被編給另一個 project platform,切過去也不會為這個 target 編譯,所以沒有切換。到 XAE 的 Build > Configuration Manager,讓該 solution platform 底下的 TwinCAT 專案(.tsproj)與 PLC 專案對到正確的 project platform(沒有就在 Platform 欄 <New...> 新增)並勾 Build,存檔後重跑 Set-TcTarget -AmsNetId <id> -Platform ''<platform>'';或改選 data.platformMap 裡 project platform 正確的 solution platform。專案平台不能改時:Set-TcTarget -NoPlatformSwitch 只設 NetId,Enable-TcConfig 不帶 -Platform(target 有 TARGETINFO 時 Enable-TcConfig 仍會擋下,只能修專案設定)。說明:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html'
    'PLATFORM_SET_FAILED'  = 'Solution platform 沒有切換成功:用 Get-TcIdeInfo 看 solutionPlatform,檢查 XAE 有沒有 dialog(Get-TcIdeModalDialog);必要時在 XAE 工具列的 Solution Platforms 下拉手動選,再重跑 Set-TcTarget -Platform'
    'ACTIVATE_FAILED'       ='ActivateConfiguration() 回來了但 XAE 的 Check config 失敗(Output 視窗「Check config failed!」),target 上什麼都沒寫。最常見原因:active solution platform 跟 target platform 不一致(target 不支援 TARGETINFO 時 Enable-TcConfig 無法事先比對)。執行 Set-TcTarget -AmsNetId <id> -Platform ''TwinCAT OS (x64)''(Usermode Runtime / UmRT;Windows RT target 用 ''TwinCAT RT (x64)''),再重跑 Build-TcProject 與 Enable-TcConfig;或直接 Enable-TcConfig -Platform ''TwinCAT OS (x64)'',它會先切換並重新 Build'
    'TYPE_MISMATCH'        = 'Write-TcVariable 依 symbol 型別轉換值。支援:BOOL、SINT/USINT/BYTE/INT/UINT/WORD/DINT/UDINT/DWORD/LINT/ULINT/LWORD(整數)、REAL/LREAL、STRING、TIME/TOD(IEC 字面 T#6s、T#1m30s500ms、TOD#12:30:00;整數 ms 也收)、LTIME/LTOD(LTIME#1us;整數 ns 也收)、DATE/DT(D#2026-10-20、DT#2026-10-20-12:30:00 或 ISO 8601;整數 UNIX 秒也收)、LDATE/LDT(LDT#…;整數 ns 也收)、enum(整數或成員名)。STRUCT/ARRAY 不能整筆寫,改寫個別成員(例如 stPar.fMax);用 Get-TcSymbols 看 type(enum 會列 enumValues)'
    'LIBRARY_UNRESOLVED'    = '先在 XAE 的 Library Manager 安裝缺的 library(data.libraryErrorItems 列出名稱與版本),再重跑 Build-TcProject;在那之前 build 成功不代表程式碼有被編譯。確定要接受時才用 Build-TcProject -AllowUnresolvedLibrary'
    'CODE_NOT_VERIFIED'     = 'Build-TcProject 回 success,但無法確認 PLC 程式碼有被編譯(Error List 讀不到,或有沒有行號的 code 列):看 XAE 的 Error List;Error List 讀不到時見 ERRORLIST_UNAVAILABLE,處理後重跑 Build-TcProject'
    'BUILD_REQUIRED'        = 'solution platform 切換後還沒有成功的 build,舊平台的產物不能 Activate:先 Build-TcProject 成功(缺 library 時先安裝,或確定接受才加 -AllowUnresolvedLibrary),再 Enable-TcConfig'
    'BUILD_STATUS_UNKNOWN'  = 'Build 結果無法判定:LastBuildInfo 與 Error List 都讀不到,請看 XAE 的 Error List 後再決定;不要把這個結果當成 build 成功'
    'POU_NOT_FOUND'         = 'POU 不存在或路徑不對:用 Get-TcProjectTree -PlcOnly(預設 -Depth 4)查完整路徑後給 -PouPath。路徑格式(4024/4026 相同)TIPC^<Plc>^<Plc> Project^POUs^<name>;DUT 在 ^DUTs^<name>,GVL 在 ^GVLs^<name>'
    'PLC_PROJECT_NOT_FOUND' = 'TIPC 下找不到 <Plc> Project 節點:確認 solution 內有 PLC 專案(Get-TcProjectTree -PlcOnly);剛 Activate / 重啟後可重試一次。-PlcProjectPath 可給 PLC 名稱(FrameworkUnitTest)或樹路徑(TIPC^FrameworkUnitTest^FrameworkUnitTest Project),候選見 data.plcProjects'
    'PLC_PROJECT_AMBIGUOUS' = 'Solution 有多個 PLC project,模組不會替你挑第一個:用 -PlcProjectPath <PLC 名稱或樹路徑> 指定(data.plcProjects 列出 name / projectPath / adsPort)'
    'PROJECT_SKIPPED_BY_CONFIGURATION' = '這個 PLC project 不在 active solution configuration 的 Build 清單(.sln 沒有 <guid>.<config>|<platform>.Build.0,DTE SolutionContext.ShouldBuild = false),solution Build 會略過它、仍回 Build succeeded,它的編譯產物是舊的。修正:XAE Configuration Manager 把該 project 的 Build 勾起來(或補上 Build.0)並存檔,再重跑 Build-TcProject -ExpectedProject <name>'
    'EXPECTED_PROJECT_NOT_FOUND' = '-ExpectedProject 給的名稱不是這個 solution 的 PLC project(比對 .plcproj 檔名,不含副檔名);data.projects 列出可用名稱'
    'BUILD_COVERAGE_UNKNOWN' = '無法確認指定的 PLC project 有參與 Build(SolutionContexts 讀不到,或 Build 失敗時 Error List 沒有該 project 的錯誤):看 data.projects / data.coverageError 與 XAE Error List,不要當成 Build 成功'
    'SYSTEM_STATE_MISMATCH' = 'TwinCAT 短暫進入要求的狀態後又離開(data.stateTrace):通常是 runtime 啟動失敗退回 Config,例如 PLC 的 symbol description 與 application 不一致(ADS 1809 / 0x711)、license 不足或 Boot 目錄的 CurrentConfig 是舊的。用 Get-TcIdeModalDialog / XAE Error List 看 fatal error,Enable-TcConfig -Force 會回 data.bootPackage 比對 Boot 檔案'
    'RUNTIME_STATE_MISMATCH' = 'Enable-TcConfig 最後讀回的 system state 或某個 PLC port 不是 Run(data.finalCheck、data.plcs):看 data.diagnostics(modal dialog、Error List、bootPackage);Boot package 不一致時重新 Enable-TcConfig -Force(Activate 會重寫 Boot),仍不一致見 docs/troubleshooting.md「Boot package 不一致」'
    'BOOT_PACKAGE_MISMATCH' = 'Target 的 Boot 目錄與專案 _Boot\<platform> 的 CurrentConfig.xml / CurrentConfig.tszip / CurrentConfig\*.tpzip / Plc\Port_*.app 不一致(data.bootPackage.files 有 SHA-256 與時間):Activate 沒有把新的 configuration 寫到 target。先重跑 Enable-TcConfig -Force;仍不一致時手動備份 target Boot 目錄後,把 _Boot\<platform> 的這些檔案複製過去再 Activate(模組不會自動覆寫 target 檔案)'
    'ACTIVATE_TIMEOUT'     = 'ActivateConfiguration() 在 -ActivateTimeoutSec 內沒返回,模組已放棄等待(XAE 內部可能仍在跑)。看 data.activateDiagnostics:dialog 有值 → 處理該視窗(Get-TcIdeModalDialog);ideResponding = false → XAE 卡死,Disconnect-TcIde -Quit -Kill(本 session 啟動的)或手動結束後重新 Connect-TcIde;runtimeAlive = false → UmRT(TcSystemServiceUm)已停,依 docs/troubleshooting.md 重啟後再 Enable-TcConfig -Force;systemState unreachable → target 沒回應'
    'ADS_SYMBOL_VERSION_INVALID' = 'ADS 0x711(1809) ADSERR_DEVICE_SYMBOLVERSIONINVALID「Invalid symbol version」:PLC 的 symbol description 與 application 版本不同(online change 後或 Boot package 不一致)。重新 Connect-TcAds 取新 handle;若是 Activate 後才出現,檢查 Enable-TcConfig 的 data.bootPackage。出處 https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html'
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
    # 0x711 (1809) ADSERR_DEVICE_SYMBOLVERSIONINVALID "Invalid symbol version"
    # https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html
    elseif ($text -match '(?i)\b0x0*711\b|symbol\s*version\s*invalid|invalid\s+symbol\s+version|\b1809\b' -or $numericCodes -contains 0x711) {
        $code = 'ADS_SYMBOL_VERSION_INVALID'
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

    $hint = Get-TcErrorHint -Code $code -Port $Port
    if ($code -eq 'IDE_MODAL_DIALOG') {
        # The reload prompt ("changed outside the environment") gets its own next-action
        # hint: either the message carries the dialog text (Invoke-TcComRetry watchdog) or
        # the last dialog record was classified as reload-prompt.
        $isReload = $false
        if ($null -ne $script:TcReloadPromptPattern -and $text -match $script:TcReloadPromptPattern) { $isReload = $true }
        if (-not $isReload -and $null -ne $script:TcLastModalDialog) {
            try { $isReload = ([string]$script:TcLastModalDialog.Kind -eq 'reload-prompt') } catch { $isReload = $false }
        }
        if ($isReload) { $hint = Get-TcErrorHint -Code 'IDE_MODAL_DIALOG_RELOAD' }
    }

    return @{
        Code    = $code
        Hint    = $hint
        Message = $message
    }
}
