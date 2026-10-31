# NOTE: this file contains non-ASCII hint text and MUST be saved as UTF-8 with BOM
# so that Windows PowerShell 5.1 reads it correctly.

# Central hint table. Keys are error codes emitted by the module.
$script:TcErrorHints = @{
    'ADS_PORT_NOT_FOUND'   = 'PLC runtime port {port} 不存在:程式尚未下載或 PLC 未啟動。先 Enter-TcPlcOnline,再 Set-TcPlcState -State Run'
    'ADS_TARGET_NOT_FOUND' = 'AmsNetId 無回應:TwinCAT 可能正在重啟。等待 Set-TcSystemState 回到 Run 後重新 Connect-TcAds'
    'ADS_SYMBOL_NOT_FOUND' = '符號不存在:新程式尚未下載,或路徑拼錯。用 Get-TcSymbols 確認'
    'ADS_INVALID_STATE'    = 'PLC 狀態不允許此操作:順序應為 Enable-TcConfig → Enter-TcPlcOnline → Set-TcPlcState Run'
    'ADS_TIMEOUT'          = 'ADS 逾時:目標忙碌或網路問題,稍後重試'
    'IDE_BUSY'             = 'XAE 拒絕 DTE 呼叫(RPC_E_CALL_REJECTED):多半被 modal dialog 或 license 視窗擋住。先 Get-TcIdeModalDialog -ProcessId <data.ideProcessId> 看是哪個視窗(reload-prompt → Reset-TcSolution),關掉後重跑同一個指令'
    'IDE_BLOCKED_SAME_NAME' = 'Connect-TcIde -SolutionPath 沒有另開 IDE,也沒有 attach:有個被擋住的 IDE(data.ideProcessId)可能開著這個 .sln,但證據不夠或互相矛盾(data.matchedBy、data.notAttachedReason:只有視窗標題同名、session record 與標題 / dialog 路徑矛盾、或兩個 IDE 都符合)。是你的 IDE → 關掉它的 dialog(data.dialog;Get-TcIdeModalDialog -ProcessId <data.ideProcessId>)後重跑同一個 Connect-TcIde;確定不是你的 → Connect-TcIde -SolutionPath <sln> -LaunchIfBlocked 另開一個'
    'CLEAN_UNVERIFIED'     = 'Clean 到了 Done,但 SolutionBuild.LastBuildInfo 讀不到,無法確認有沒有 project clean 失敗:用 Get-TcIdeModalDialog 檢查 dialog,重跑 Clear-TcProject;仍讀不到就 Reset-TcSolution 後再試'
    'CLEAN_LIBRARY_UNRESOLVED' = 'Clean 的錯誤全是解析不到的 library(data.libraryErrorItems):先在 XAE 的 Library Manager 安裝缺的 library 再重跑 Clear-TcProject;在那之前 Clean / Build 的成功都不代表程式碼有被編譯(#45)。確定要接受時才用 Clear-TcProject -AllowUnresolvedLibrary(MCP: CleanProject AllowUnresolvedLibrary=true)'
    'RESET_SOLUTION_MISMATCH' = 'Reset-TcSolution 沒有動作:這個 IDE(data.previousIdeProcessId)開著 data.openSolution,不是模組以為的 data.expectedSolution,關掉會動到別人的 solution。用 Connect-TcIde -SolutionPath <你的 sln> 重新連到正確的 IDE(找不到就加 -LaunchIfBlocked 另開),再 Reset-TcSolution'
    'RESET_SOLUTION_UNVERIFIED' = 'Reset-TcSolution 沒有動作(nothing closed):在 -TimeoutSec 內一直讀不到這個 IDE(data.previousIdeProcessId)開著的 solution(data.guardError),無法確認它是模組預期的 data.expectedSolution,所以不關。先 Get-TcIdeModalDialog -ProcessId <pid> 看有沒有 dialog 並處理,等 XAE 不忙後重跑 Reset-TcSolution(可加大 -TimeoutSec);仍讀不到就 Connect-TcIde -SolutionPath <sln> 重新連線再試'
    'IDE_BLOCKED_OWN'      = 'Connect-TcIde -SolutionPath 沒有另開 IDE,也沒有 attach:被擋住的 IDE(data.ideProcessId)是本 session 啟動的(data.launchedBySession = true),但證據不足以確認它開的就是這個 .sln(data.notAttachedReason)。先處理它的 dialog(data.dialog;Get-TcIdeModalDialog -ProcessId <data.ideProcessId>)後重跑同一個 Connect-TcIde;卡死就 Stop-Process -Id <data.ideProcessId>(本 session 啟動的)再重新 Connect-TcIde。不要用 -LaunchIfBlocked:那會另開一個 IDE 開同一個 .sln'
    'CLEAN_TIMEOUT'        = 'Clean 在 -TimeoutSec 內沒有完成(SolutionBuild.BuildState 沒有到 3 = Done):用 Get-TcIdeModalDialog 檢查有沒有 dialog,沒有就加大 -TimeoutSec 重跑 Clear-TcProject;XAE 沒反應就 kill IDE 後重新 Connect-TcIde -SolutionPath <sln>'
    'CLEAN_FAILED'         = 'Clean 沒有成功:data.failedProjects > 0(SolutionBuild.LastBuildInfo;看 data.errorItems,不只是 Library Manager 的錯誤)或 DTE 一直讀不到 Solution / SolutionBuild(data.nullReads)。看 XAE Output 視窗;剛 Connect-TcIde 完就重跑一次 Clear-TcProject,仍失敗就 Reset-TcSolution 後再試'
    'IDE_MODAL_DIALOG'     = 'XAE/VS 有 modal 視窗擋住 DTE 呼叫。先呼叫 Get-TcIdeModalDialog 看 kind:reload-prompt(檔案或 .plcproj 被磁碟上的工具改了)→ 直接 Reset-TcSolution;其他(例如 Assertion Failed、VS 帳戶設定、Target system reports a fatal error)模組無法自動關閉,請手動處理後重試,或 Disconnect-TcIde -Quit(本 session 啟動的 IDE 改用 Disconnect-TcIde -Quit -Kill),或 kill IDE 後重新 Connect-TcIde'
    'IDE_MODAL_DIALOG_RELOAD' = 'XAE 跳「File has been changed outside the environment. Reload the new file?」:開在編輯器裡的檔案(通常是 .TcPOU)被磁碟上的工具改了,DTE 呼叫被擋住;.plcproj 被改寫(內容相同也算)則跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」,同樣算 reload-prompt(reloadTarget = project)。直接呼叫 Reset-TcSolution:project 提示它會按 Yes(依 control id,語系無關)讓 XAE 自己 reload 專案再重連,不必 close/reopen;檔案提示它會關掉提示(WM_CLOSE)、關閉所有文件、Solution.Close 後在同一個 IDE 重開 solution 並重連(約 20~25 s);關不掉就在 XAE 按 Yes,或 kill IDE 後重新 Connect-TcIde -SolutionPath <sln>。之後改磁碟檔案的規則:POU 沒開在編輯器 → 直接改,XAE 約 5 s 自動吃到;開著 → 改完立刻 Reset-TcSolution(它會順便關掉編輯器,之後就不會再跳);改用 Write-TcPouCode(走 COM 寫 IDE 編輯 buffer,存檔或 Build 時才落地)則不會跳框'
    'IDE_QUIT_FAILED'      = 'IDE 沒有被關掉,行程仍在(pid 見 data.ideProcessId):(a) 被 modal dialog 擋住(data.dialog,quit 沒有嘗試,data.disconnected = false:連線完整保留):kind = reload-prompt → Reset-TcSolution 處理後再 Disconnect-TcIde -Quit;其他 dialog → 本 session 啟動的 IDE(data.ownedBySession = true)用 Disconnect-TcIde -Quit -Kill,否則手動 Stop-Process -Id <data.ideProcessId>。(b) DTE.Quit 失敗(data.quitError,COM 參考已釋放但 pid 有保留):data.ownedBySession = true 就直接接 Disconnect-TcIde -Quit -Kill(不用重連);否則手動 Stop-Process -Id <data.ideProcessId>。不要以為 IDE 已經關掉,下一次 Connect-TcIde 會黏回同一個被擋住的 IDE'
    'IDE_NOT_OWNED'        = '這個 IDE 不是本 session 啟動的(data.selectedBy 不是 launched,例如 solution-match),模組不會 kill 使用者自己開的 IDE。確定要關就自己 Stop-Process -Id <data.ideProcessId>,再重新 Connect-TcIde'
    'PROJECT_SAVE_FAILED'   = '專案檔(.plcproj / .tsproj)沒存到磁碟或讀回沒有新項目:物件(data.objectPath)只在 XAE 記憶體裡,關 solution 不存檔(Reset-TcSolution -DiscardProjectChanges、Disconnect-TcIde -Quit)就會消失。第一步：先 Get-TcIdeModalDialog 看有沒有 dialog(有就處理),確認 .plcproj / .tsproj 不是唯讀 / 被鎖，再重跑同一個 Add-* 會回 *_CREATE_FAILED(exists),所以改跑 Reset-TcSolution -SaveProjectChanges(只存專案檔並讀回;磁碟也被改過時會拒絕)。第二步(仍失敗):請使用者在 XAE 手動存該 PLC 專案;或 Build-TcProject,但注意 Build 會一併存 editor buffer(可能蓋掉磁碟上的 .TcPOU 改動;實測 2026-10-28 .plcproj 的最後寫入時間 = 第一次 Build,#76)。最後 Get-TcProjectTree -PlcOnly 確認物件還在'
    'PROJECT_SAVE_TIMEOUT'  = 'DTE Project.Save() 在期限內沒返回(模組已放棄等待，XAE 內部可能仍在跑),專案檔可能沒存。看 data.saveDiagnostics:dialog 有值 → Get-TcIdeModalDialog 看內容並處理(模組不會替你按);readOnlyFiles 有值 → 解除 .plcproj / .tsproj 的唯讀屬性後 Reset-TcSolution -SaveProjectChanges;ideResponding = false → XAE 卡死,Disconnect-TcIde -Quit -Kill(只限本 session 啟動的)後重新 Connect-TcIde,未存的物件會遺失'
    'PROJECT_UNSAVED_CHANGES' = 'Reset-TcSolution 沒關 solution:XAE 記憶體有、磁碟 .plcproj 沒列的 PLC 物件(data.projectCheck.plcs[].missingOnDisk;只有 extraOnDisk = 磁碟有、XAE 沒有時不擋，重開就載入磁碟版本),模組分不出是「XAE 建了沒存」還是「有人在磁碟上刪 / 改了」,所以不替你選。三條路:(1) 保留 XAE 版本 → Reset-TcSolution -SaveProjectChanges(MCP:ResetSolution SaveProjectChanges=true;只存專案檔);但 data.saveRefused 有值時(處理過 reload 提示、物件檔在磁碟上不存在，或同一個 .tsproj 的任一 PLC 沒比對到 / 比對不完整 / extraOnDisk 非空;Project.Save 會寫整個 .tsproj 底下所有 .plcproj)它會拒絕存，表示磁碟被改過。(2) 以磁碟為準 → Reset-TcSolution -DiscardProjectChanges(丟掉 XAE 的版本)。(3) 兩邊都要 → 先在磁碟上補回需要的檔案 / <Compile Include>,再走 (1) 或 (2)。不要用 Build-TcProject 解:Build 會一併存 editor buffer,可能蓋掉磁碟上的 .TcPOU 改動'
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
    'LIBRARY_UNRESOLVED'    = '先在 XAE 的 Library Manager 安裝缺的 library(data.libraryErrorItems 列出名稱與版本),再重跑 Build-TcProject;在那之前 build 成功不代表程式碼有被編譯。Build-TcProject -AllowUnresolvedLibrary 只讓這次 build 回 success + warningCode,不算完整 build(completeBuild = false),BUILD_REQUIRED 會保留，所以 Enable-TcConfig / Enter-TcPlcOnline 仍然拒絕 Activate / Login(#61):module 記錄到這種 build 之後不會 Activate / Download / Run(從未經 module build 的 solution 不擋，範圍見 BUILD_REQUIRED 與 docs/troubleshooting.md BUILD_REQUIRED)'
    'CODE_NOT_VERIFIED'     = 'Build-TcProject 回 success,但無法確認 PLC 程式碼有被編譯(Error List 讀不到、有沒有行號的 code 列,或有 PLC project 被 active solution configuration 略過):看 XAE 的 Error List;Error List 讀不到時見 ERRORLIST_UNAVAILABLE;被略過時(data.skippedProjects)見 PROJECT_SKIPPED_BY_CONFIGURATION,在 Configuration Manager 勾起 Build 後重跑 Build-TcProject -ExpectedProject <name>;solution 裡沒有 .plcproj(只有 I/O 或 NC)時，這個碼是預期結果，不需處理'
    'BUILD_REQUIRED'        = '這個 solution 在 solution platform 切換後、上一次 Build-TcProject 沒有完整成功之後(LIBRARY_UNRESOLVED、BUILD_FAILED、BUILD_STATUS_UNKNOWN、success 但 completeBuild = false,#56),或程式碼 / 專案被 Write-TcPouCode、Add-TcPou、Add-TcDut、Add-TcGvl、Add-TcLibrary、New-TcProject、Reset-TcSolution 改過之後(code-changed,#65;message 與 hint 開頭的 Recorded 寫是哪個 cmdlet 改了哪個物件),還沒有完整成功的 build:產物可能還是舊平台的(推論，未實測)、程式碼沒被證實有編譯，或改過的程式碼還沒編譯過，所以 Enable-TcConfig 不 Activate、Enter-TcPlcOnline 不 Login/Download(XAE 自己編譯的結果沒人檢查)。完整成功 = Build-TcProject 回 success 且 data.completeBuild = true(coverageComplete 且 codeVerified = true;加了 AllowUnresolvedLibrary 的 build 永遠不算,#61);message 會寫上一次 build 為什麼不算(codeVerified、coverageComplete、warningCodes)。下一步：先讓 Build-TcProject 完整成功(缺 library 時先在 XAE Library Manager 安裝;有 project 被跳過就在 Configuration Manager 勾回 Build;BUILD_FAILED 就先修程式碼),再 Enable-TcConfig 或 Enter-TcPlcOnline。Enable-TcConfig 自動切換平台後的那次 build 也一樣：回 success 但 completeBuild 不是 true 時直接回 BUILD_REQUIRED,不 Activate(#61)。永遠達不到完整成功的 solution(沒有 .plcproj、PLC 刻意不 build、Error List 一直讀不到):確定編譯產物對應目前的 solution platform 後，手動刪掉 %TEMP%\TwinCATAutomation\build-required.json 裡該 .sln 那一筆(或整個檔),見 docs/troubleshooting.md BUILD_REQUIRED'
    'BUILD_STATUS_UNKNOWN'  = 'Build 結果無法判定:LastBuildInfo 與 Error List 都讀不到,請看 XAE 的 Error List 後再決定;不要把這個結果當成 build 成功'
    'POU_NOT_FOUND'         = 'POU 不存在或路徑不對:用 Get-TcProjectTree -PlcOnly(預設 -Depth 4)查完整路徑後給 -PouPath。路徑格式(4024/4026 相同)TIPC^<Plc>^<Plc> Project^POUs^<name>;DUT 在 ^DUTs^<name>,GVL 在 ^GVLs^<name>;method / property / action 在 POU 底下 ^<POU>^<member>,accessor ^<POU>^<property>^Get。-PouName 也接受 FB_X.M_Run、FB_X.P_Value.Get'
    'POU_CREATE_FAILED'     = 'CreateChild 失敗,error.message 標出失敗步驟(exists / lookup / kind / language / declare,沒標就是 CreateChild 本身):exists = 專案裡已有同名物件(訊息帶 path),換 -Name 或用 Write-TcPouCode -PouPath <path> 改既有的;"not possible on parent node type" = 父節點不是 PLC folder,用 Get-TcProjectTree -PlcOnly 找 <Plc> Project^POUs 的 path,當 -PlcProjectPath <path> 重跑同一個 tool;0x98510001 = .plcproj 列了磁碟上不存在的檔案,修 .plcproj 後 Reset-TcSolution 再重試;lookup = 目標路徑讀不到,物件可能建在別處,Get-TcProjectTree -PlcOnly 找到後以 Write-TcPouCode 修正或在 XAE 刪除;kind / language / declare = 物件已建立、留在樹上,Get-TcPouCode -PouPath <path> 看內容後以 Write-TcPouCode -PouPath <path> 修正,或在 XAE 刪除後再 Add-TcPou'
    'DUT_CREATE_FAILED'     = 'DUT 建立失敗,error.message 標出失敗步驟(exists / lookup / kind / declare,沒標就是 CreateChild 本身):exists = 專案裡已有同名物件(訊息帶 path),換 -Name 或用 Write-TcPouCode -PouPath <path> -Declaration 改既有的;lookup = 目標路徑讀不到,物件可能建在別處,Get-TcProjectTree -PlcOnly 找到後以 Write-TcPouCode 修正或在 XAE 刪除;kind / declare = 物件已建立、留在樹上,Get-TcPouCode -PouPath <path> 看內容後以 Write-TcPouCode -PouPath <path> -Declaration 修正,或在 XAE 刪除後再 Add-TcDut;找不到 DUTs folder 時用 Get-TcProjectTree -PlcOnly 確認 <Plc> Project 結構'
    'GVL_CREATE_FAILED'     = 'GVL 建立失敗,error.message 標出失敗步驟(exists / lookup / kind / declare,沒標就是 CreateChild 本身):exists = 專案裡已有同名物件(訊息帶 path),換 -Name 或用 Write-TcPouCode -PouPath <path> -Declaration 改既有的;lookup = 目標路徑讀不到,物件可能建在別處,Get-TcProjectTree -PlcOnly 找到後以 Write-TcPouCode 修正或在 XAE 刪除;kind / declare = 物件已建立、留在樹上,Get-TcPouCode -PouPath <path> 看內容後以 Write-TcPouCode -PouPath <path> -Declaration 修正,或在 XAE 刪除後再 Add-TcGvl;找不到 GVLs folder 時用 Get-TcProjectTree -PlcOnly 確認 <Plc> Project 結構'
    'POU_READ_FAILED'       = '物件找到了但讀不出內容(COM 例外,或 DeclarationText 讀回 null):用 Get-TcIdeModalDialog 看 XAE 有沒有 dialog,沒有就重試 Get-TcPouCode -PouPath <path>;仍失敗就 Reset-TcSolution 後再讀'
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
# #47: Add-TcDut / Add-TcGvl read back a member order that differs from the input order
$script:TcErrorHints['MEMBER_ORDER_MISMATCH'] = 'DUT / GVL 已建立並存檔,但讀回的成員順序(data.actualOrder)與輸入(data.expectedOrder)不同:用 Write-TcPouCode -PouPath <data.path> -Declaration <依正確順序的 declaration> 改寫,再 Get-TcPouCode 確認後 Build-TcProject;不要沿用這個順序(STRUCT 記憶體配置會不同)'
# #70: New-TcProject refuses while the IDE has a solution open: Solution.Create closes it without
# a warning (實測 2026-10-28, #70: 4026.22 XAE in VS2022 / 4024 32-bit XAE Shell, registered tcauto)
$script:TcErrorHints['SOLUTION_ALREADY_OPEN'] = 'IDE 已開著 solution(data.openSolution),New-TcProject 不會建立:Solution.Create 會關掉目前的 solution 並丟掉未存的改動(#70)。建議在 XAE 手動建立新專案後用 Connect-TcIde -SolutionPath <新 .sln> 接上;要用 New-TcProject 就先在 XAE 存好、關掉目前的 solution 再呼叫。NewProject 目前不在 MCP 提供'

# task 1.3 (complete-automation-interface): I/O scan and variable link (TE1000 v1.7.0 6.6.2, 5.1.1.2, 5.1.1.8, 5.1.3.4)
$script:TcErrorHints['IO_SCAN_REQUIRES_CONFIG'] = 'I/O scan 需要 TwinCAT 在 Config mode(TE1000 6.6.2 Requirements);data.state 是目前狀態。先 Set-TcSystemState -State Config 再重跑 Invoke-TcIoScan(本機 UmRT 切 Config 可能 crash,#21,見 troubleshooting「已知限制」);掃完用 Enable-TcConfig -Force 回 Run'
$script:TcErrorHints['IO_SCAN_FAILED'] = 'TIID.ProduceXml(false) / CreateChild / ConsumeXml 失敗:確認 target 在 Config、硬體已接上並上電、遠端 target 已 Set-TcTarget;用 Get-TcIdeModalDialog 看 XAE 有沒有 dialog'
$script:TcErrorHints['IO_SCAN_VERIFY_FAILED'] = '-Apply 建立的 device 讀回 I/O tree 時找不到(data.devices[].path):用 Get-TcIoTree 看實際內容,不要把這次掃描當成成功'
$script:TcErrorHints['LIBRARY_ADD_FAILED'] = 'ITcPlcLibraryManager.AddLibrary 失敗。data.notInstalled = true:library 沒有安裝(TSM_E_ITEMNOTFOUND,.plcproj 沒被修改),先在 XAE 的 PLC > Library Repository 安裝，確認名稱 / 版本 / 廠商後重跑 Add-TcLibrary;其他情況看 error.message,用 Get-TcIdeModalDialog 檢查 dialog。已有同名 reference 不是錯誤(success + data.alreadyPresent)。見 docs/troubleshooting.md「LIBRARY_ADD_FAILED」'
$script:TcErrorHints['TREEITEM_NOT_FOUND'] = 'LookupTreeItem 找不到這個路徑(TSM_E_ITEMNOTFOUND,0x98510001)。通用 tree tool(LookupTreeItem / ProduceXml / CreateChild / ConsumeXml / DeleteChild / ExportChild / ImportChild)的 hint 會直接列出最接近的上層路徑和它的子節點(data.nearestPath / nearestChildren),照著改路徑或用 Get-TcTreeItem 往下查。SetVariableLink / RemoveVariableLink:兩端都要完整 tree path,用 ^ 分隔:PLC 端 TIPC^<Plc>^<Plc> Instance^PlcTask Inputs^MAIN.bIn(AT %I* 變數,要先 Build),I/O 端到 variable 那層,例如 TIID^<Device>^<Box>^<Term>^Channel 1^Input。用 Get-TcIoTree / Get-TcProjectTree 查路徑'
# Generic tree item tools (complete-automation-interface phase 1, tasks 2.2-2.7). TE1000 v1.7.0 5.2.1.x;
# ConsumeXml behaviour measured 2026-10-30 (4026 VS2022, task 2.1, verification/phase1-2.1-consumexml.md).
$script:TcErrorHints['TREEITEM_PATH_INVALID'] = 'Path 要是完整 tree path(用 ^ 分隔,例如 TIRT^PlcTask),不接受 * 或 ?、不能有空段;DeleteChild 不能刪頂層節點(TIPC / TIID ...)。先用 Get-TcTreeItem 或 Get-TcProjectTree 查到確切路徑再重試,什麼都沒改'
$script:TcErrorHints['TREEITEM_READ_FAILED'] = 'LookupTreeItem 之後讀節點(Name / Child / ProduceXml)失敗,什麼都沒改:用 Get-TcIdeModalDialog 檢查 XAE 有沒有 dialog,再重跑同一個 tool;一直失敗就用 GetProjectTree 確認節點還在'
$script:TcErrorHints['TREEITEM_ALREADY_EXISTS'] = '同名的子節點已經存在,什麼都沒建立 / 匯入:換一個 Name,或確定要取代時先 DeleteChild(帶 ConfirmName,先 dry-run)再重試'
$script:TcErrorHints['TREEITEM_CREATE_FAILED'] = 'CreateChild 被 XAE 拒絕(例如 E_NOTIMPL:這個節點不支援新增子節點;E_ACCESSDENIED:檔案不能編輯),什麼都沒建立(data.backupPath 是父節點的備份)。確認 Path 是父節點、SubType / VInfo 是手冊(TE1000)或 InfoSys 寫的值;有專用 tool(AddPou / AddDut / AddGvl / IoScan)就改用它'
$script:TcErrorHints['TREEITEM_VERIFY_FAILED'] = '修改呼叫有返回,但讀回不符(data.mismatches 的 expected / actual;data.unexpectedChanges 是片段以外、或父節點裡不該變卻變了的欄位;data.missingChildren / addedChildren 是建立 / 匯入後子節點名稱不是「原有的加一個」;或節點建立後找不到、刪除後還在):不要當成功。看 data.backupPath(寫入前的 ProduceXml)與 data.backupFiles,用 ProduceXml 確認目前內容;要還原就用 ConsumeXml 送回備份裡對應的欄位(先 dry-run),刪錯的節點用 ImportChild 匯入 data.exportPath'
$script:TcErrorHints['TREEITEM_DELETE_NAME_MISMATCH'] = 'ConfirmName 和要刪的節點名稱不一致(data.nodeName,大小寫要相同),什麼都沒刪。先用 LookupTreeItem 確認 Path 指到的就是要刪的節點,再把 ConfirmName 設成 data.nodeName 重試(先 dry-run)'
$script:TcErrorHints['TREEITEM_DELETE_FAILED'] = 'DeleteChild 被 XAE 拒絕(E_NOTIMPL:父節點不支援刪除;E_ACCESSDENIED:檔案不能編輯),節點還在。data.backupPath / exportPath 是刪除前的備份。用 Get-TcIdeModalDialog 檢查 dialog;有專用 tool 就改用它。data.reason = parent-mismatch:節點回報的 PathName 上層和 Path 推算的父節點不同,沒有呼叫 DeleteChild;用 LookupTreeItem 確認實際路徑(data.itemParentPath)後用那個路徑重跑'
$script:TcErrorHints['TREEITEM_INVALID_VALUE'] = '片段裡已知欄位的值不合法(data.invalidFields:path / value / rule),什麼都沒寫。XAE 自己不檢查(實測 2026-10-30:TaskDef/CycleTime 給 0、負數、文字都會寫入，文字變 0),所以由模組擋。改成合法的值(CycleTime 是大於 0 的整數，單位 100 ns,20000 = 2 ms)再重試'
$script:TcErrorHints['TREEITEM_BACKUP_FAILED'] = '寫入前的備份沒寫成(solution 路徑不明，或 <solution 目錄>\.tcauto-backup 無法寫入),什麼都沒改。先 Connect-TcIde -SolutionPath <sln>(或 Open-TcProject)讓模組知道 solution,確認該目錄可寫，再重試。DeleteChild 的 data.reason = export-failed / export-missing:刪除前的 ExportChild 備份(.xti;TIPC 底下一律用 .zip,實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測)沒產生，沒有刪除;先用 ExportChild 試匯出同一個節點找原因，確定只靠 ProduceXml(recursive)備份也可以時才加 AllowNoExport=true 重跑'
$script:TcErrorHints['TREEITEM_EXPORT_FAILED'] = 'ExportChild 沒有產生檔案(data.reason:not-absolute / invalid-path / plc-requires-zip / file-exists / folder-missing / file-not-written,或 XAE 拒絕)。FilePath 要是含檔名的絕對路徑(不能是 C:\ 這種根目錄、不能有 < > | " * ? 等字元)、資料夾要存在、檔案不能已存在(TE1000 5.2.1.4);PLC folder(ItemType 601)要用 .zip 檔名(XAE 對 .xti 回 "doesn''t specify a zip archive",實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測，交給 XAE 回錯),其他節點用 .xti;換一個新檔名重試'
$script:TcErrorHints['TREEITEM_IMPORT_FAILED'] = 'ImportChild 沒有匯入(data.reason:not-absolute / invalid-path / file-missing,或 XAE 拒絕:NTE_NOT_FOUND 沒有可匯入的項目、E_FAIL 載入 / 類別檢查 / 插入失敗,TE1000 5.2.1.6)。確認檔案是 ExportChild 匯出的 .xti(PLC folder 是 .zip,實測 2026-10-30 4026 VS2022 僅 PLC folder;其他 TIPC 節點未測)、Path 是能放這種節點的父節點(例如 Task 放 TIRT),必要時先 dry-run'
$script:TcErrorHints['XML_MERGE_FAILED'] = 'ConsumeXml 片段沒有送出或被 XAE 拒絕,什麼都沒寫(送出後失敗時 data.backupPath 有備份)。data.reason:syntax(XML 語法錯)/ root(根元素要是 <TreeItem>)/ empty / paths-not-in-current-xml(data.missingPaths 的元素在目前的 XML 不存在;XAE 對未知元素會靜默忽略，實測 2026-10-30)/ structure-mismatch / repeated-count-mismatch / attributes-not-supported / derived-only(這四種是 XAE 怎麼合併未實測，模組先擋)。先 ProduceXml 看實際結構，只送要改的欄位，路徑照抄，例如 <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>'
# XML_MERGE_FAILED: next action per data.reason for the checks added in the review of tasks 2.2-2.7
# (none of these cases is measured on XAE, so the fragment is refused before anything is sent).
$script:TcXmlMergeReasonHints = @{
    'structure-mismatch'       = '片段裡的最底層元素在目前的 ProduceXml 是有子元素的節點，或片段在有子元素的地方放了文字(data.structurePaths),什麼都沒送。值只能放在最底層元素：先 ProduceXml,把片段往下寫到真正的欄位，例如 <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>,不要送 <TaskDef/> 或 <TaskDef>123</TaskDef>'
    'repeated-count-mismatch'  = '片段裡同名重複元素的數量和目前的 XML 不同(data.repeatedCountMismatches:path / fragmentCount / currentCount),什麼都沒送;XAE 怎麼合併數量不同的重複元素未實測。先 ProduceXml,把那一組重複元素全部照目前的數量和順序抄進片段，只改要改的值'
    'attributes-not-supported' = '片段裡有 XML attribute(data.attributePaths),什麼都沒送。目前只支援 element 值(XAE 怎麼合併 attribute 未實測):拿掉所有 attribute(包含 xmlns),只送元素和它的文字值'
    'derived-only'             = '片段裡有變動的欄位全部是衍生欄位(TcModuleInstance 底下的 Context / ParameterValues,data.derivedPaths),XAE 會依來源欄位自己重算，寫入後也無法讀回驗證，什麼都沒送。改送來源欄位，例如改 TaskDef/CycleTime 而不是 Context/CycleTime'
}
# PLC_LOGGED_IN raised inside a generic tree tool: {operation} = the operation of New-TcTreeItemErrorResult.
$script:TcTreeItemPlcLoggedInHint = 'PLC 正在 login(online)中,XAE 拒絕修改組態，什麼都沒改。先 Exit-TcPlcOnline,再重跑同一個 tool({operation})'
$script:TcErrorHints['LINK_INVALID_ITEM_TYPE'] = 'TSM_E_INVALIDITEMTYPE:至少一端不是 variable(例如給了 Channel 節點而不是 Channel 1^Input)。兩端都要指到變數'
$script:TcErrorHints['LINK_TYPE_MISMATCH'] = 'TSM_E_MISMATCHINGITEMS:兩個變數的型別或大小不相容(例如 PLC INT 對 BOOL input)。改 PLC 變數型別,或連到相同大小的 I/O 變數'
$script:TcErrorHints['LINK_FAILED'] = 'LinkVariables 失敗，原因不在已知 TSM_E_* 內:看 error.message,用 Get-TcIdeModalDialog 檢查 dialog;確認兩端都是完整 tree path 的變數'
$script:TcErrorHints['UNLINK_FAILED'] = 'UnlinkVariables 失敗：看 error.message,用 Get-TcIdeModalDialog 檢查 dialog;確認兩端都是完整 tree path 的變數'
# task 1.8 (complete-automation-interface, phase0-1.7 findings 2 and 4)
# RUNTIME_CRASHED: Set-TcSystemState / Wait-TcAdsState -DetectRuntimeCrash, local UmRT only
$script:TcErrorHints['RUNTIME_CRASHED'] = '本機 UmRT(TcSystemServiceUm)在等待狀態切換時消失：開始等待時的行程(data.servicePidAtStart)已不在，且 port 10000 連續回 ADS 0x7 超過 10 s。重試同一步沒有用，先重啟 UmRT:行程已不在就直接啟動 TcSystemServiceUm(指令見 docs/troubleshooting.md「SYSTEM_STATE_TIMEOUT」的 UmRT 重啟指令;還有殘留行程才先 Stop-Process),重啟後 runtime 停在 Config,再 Enable-TcConfig -Force(MCP:EnableConfig Force=true)。crash 簽名(Windows 事件 1000 的 faulting module / exception、%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.<pid>.dmp)對照 docs/troubleshooting.md「已知限制」的 UmRT crash(#21);簽名不同就記下 dump 開 issue'
# PLC_LOGGED_IN: XAE refuses CreateChild while logged in ("Cannot add an object because it affects a
# device you are currently logged into", measured 2026-10-29, 4026 XAE in VS2022). English key words only.
$script:TcPlcLoggedInPattern = '(?i)affects\s+a\s+device\s+you\s+are\s+currently\s+logged\s+in|cannot\s+add\s+an\s+object\b.*\blogged\s+in'
$script:TcErrorHints['PLC_LOGGED_IN'] = 'PLC 正在 login(online)中,XAE 不允許新增物件，什麼都沒建立。先 Exit-TcPlcOnline 再重試同一個 Add-TcPou / Add-TcDut / Add-TcGvl / Add-TcInterface / Add-TcPouMember;Enable-TcConfig -Force 與 Invoke-TcTestCycle 結束時會保持 login。新增後 Build-TcProject,再 Enable-TcConfig -Force 或 Enter-TcPlcOnline 下載'
# task 3.6 (complete-automation-interface phase 2): Add-TcPouMember / Add-TcInterface, member paths
$script:TcErrorHints['POU_MEMBER_INVALID'] = 'Add-TcPouMember 的參數或父節點不合法，什麼都沒建立(data.reason:name / access / language / return-type / parent-kind)。Access 只能是 PUBLIC / PRIVATE / PROTECTED / INTERNAL(XAE 收到其他值會靜默當成 PUBLIC,所以模組先擋);Property 要給 -ReturnType;Get / Set 的 -ParentPath 要是 property,Method / Property / Action 的要是 PROGRAM、FUNCTION_BLOCK 或 INTERFACE(Interface 沒有 action)。照 error.hint 修正參數後重跑 Add-TcPouMember'
$script:TcErrorHints['POU_MEMBER_UNSUPPORTED'] = '什麼都沒建立、沒讀、沒寫，原因在 error.message(data.reason)。itf-property-accessor:改在實作該 interface 的 FB 裡用 Add-TcPouMember -ParentPath <FB path>^<property> -Kind Get / Set 建 accessor,再用 Get-TcPouCode / Write-TcPouCode -PouPath <FB path>^<property>^Get 讀寫;method-no-return-type:給 -ReturnType,或拿掉 -Access / -Language;accessor-not-measured:拿掉 -Access / -Language(只支援 PUBLIC + ST),之後用 Write-TcPouCode 改 accessor'
$script:TcErrorHints['POU_MEMBER_EXISTS'] = '父節點底下已經有同名的子物件(data.existingPath,名稱不分大小寫),什麼都沒建立。換一個 -Name;要改既有的就用 Write-TcPouCode -PouPath <data.existingPath>;Get / Set 已存在時直接寫它的實作'
$script:TcErrorHints['POU_MEMBER_CREATE_FAILED'] = 'Add-TcPouMember 在 CreateChild 時或之後失敗,error.message 標出步驟(沒標就是 CreateChild 本身,XAE 拒絕、什麼都沒建立):lookup = 目標路徑讀不到，用 Get-TcProjectTree -PlcOnly 找;kind / language / declare = 子物件已建立、留在樹上，用 Get-TcPouCode -PouPath <path> 看內容，以 Write-TcPouCode -PouPath <path> 修正，或在 XAE 刪除後再 Add-TcPouMember'
$script:TcErrorHints['POU_AMBIGUOUS'] = '這個名稱有多個物件(data.candidates 列出完整路徑，例如兩個 FB 都有 M_Run),模組不替你挑，什麼都沒讀 / 沒改。從 data.candidates 選一個當 -PouPath(Add-TcPouMember 是 -ParentPath),或用 Parent.Member 寫法(FB_X.M_Run)'
$script:TcErrorHints['POU_WRITE_FAILED'] = 'Write-TcPouCode 沒寫成(data.reason):empty-not-supported = -Declaration 是空字串，清空 declaration 不支援，給完整的 declaration 或不要給 -Declaration;empty-not-applied = -Implementation 空字串寫入後讀回不是空的，用 Get-TcPouCode -PouPath <path> 確認;其他 = COM 例外(檔案唯讀、物件保護、非 ST 物件寫 ImplementationText),用 Get-TcIdeModalDialog 看 XAE 有沒有 dialog 後重試'
$script:TcErrorHints['LINK_VERIFY_FAILED'] = 'Link / Unlink 呼叫有返回，但 ProduceMappingInfo 讀回的 mapping 不符(data.remainingLinks,或讀不到 mapping):不要當成功。到 XAE 看該變數的 link,或重跑一次'
# task 3.1 (complete-automation-interface phase 2): Library Manager cmdlets. TE1000 v1.7.0 5.25.1 / 6.5.14;
# behaviour measured 2026-10-31 4026 VS2022 (self-built client, verification/phase2-probe.md 3.1).
$script:TcErrorHints['LIBRARY_READ_FAILED'] = 'Get-TcLibraries 讀 References / ScanLibraries 失敗，什麼都沒改。用 Get-TcIdeModalDialog 檢查 XAE 有沒有 dialog,確認 solution 有 PLC project(多個時加 -PlcProjectPath),再重跑 Get-TcLibraries'
$script:TcErrorHints['LIBRARY_INVALID_ARGUMENT'] = '參數不合法，什麼都沒改(data.reason)。name / empty:名稱是空的;no-library-name:Add-TcLibraryPlaceholder 給了 -Version / -Distributor 卻沒給 -LibraryName;ambiguous:同名的 library 和 placeholder 都在，要移除 placeholder 就給 -Name ''#<name>''(或 -Kind Placeholder);ambiguous-library-not-measured:兩者並存時不支援只移除 library,請使用者在 XAE 的 Library Manager 手動移除;kind-conflict:-Name 帶 # 時不要給 -Kind Library;not-placeholder:Lock-TcLibraryPlaceholder 只能鎖 placeholder;target:Lock-TcLibraryPlaceholder 要給 -Placeholder 或 -All 其中一個;wildcard:Uninstall-TcLibrary 只接受完整的名稱 / 版本 / distributor,先用 Get-TcLibraries -Repository 查;path / extension / missing / repository:Install-TcLibrary 要給存在的 .library / .compiled-library 絕對路徑與 repository 名稱'
$script:TcErrorHints['LIBRARY_NOT_FOUND'] = '專案的 References 沒有這個 library / placeholder(或 XAE 回 not found),什麼都沒改。用 Get-TcLibraries 看 data.libraries[].name / placeholderName(placeholder 列成 #<name>),拼對名稱後重跑同一個 tool;要加 placeholder 用 Add-TcLibraryPlaceholder,要加 library 用 Add-TcLibrary'
$script:TcErrorHints['LIBRARY_VERIFY_FAILED'] = '寫入呼叫有返回，但讀回不符(data.step / data.reason:references、library、project-file、not-frozen、not-listed、still-installed),不要當成功。專案的改動：用 Get-TcLibraries 看目前狀態，寫入前的 .plcproj 在 data.backupFiles(Remove / Lock 才有);repository 的改動：用 Get-TcLibraries -Repository 確認。確認原因後再重跑同一個 tool'
$script:TcErrorHints['LIBRARY_BACKUP_FAILED'] = '寫入前的備份沒寫成(Remove-TcLibraryReference / Lock-TcLibraryPlaceholder:.plcproj;Uninstall-TcLibrary:repository 裡該版本的目錄，推不出位置時 data.repositoryFolder = null),或 solution 路徑不明、<solution 目錄>\.tcauto-backup 無法寫入，什麼都沒改。先 Connect-TcIde -SolutionPath <sln>(或 Open-TcProject)讓模組知道 solution,確認該目錄可寫，再重跑同一個 tool(先 -DryRun $true 看 data.projectFile / data.repositoryFolder 有值);Uninstall-TcLibrary 的目錄推不出來時請使用者在 XAE 的 Library Repository 手動處理'
$script:TcErrorHints['LIBRARY_REMOVE_FAILED'] = 'Remove-TcLibraryReference 在 RemoveReference 時或之後失敗，看 error.message;reference 可能已經移除。用 Get-TcLibraries 確認，寫入前的 .plcproj 在 data.backupFiles;用 Get-TcIdeModalDialog 檢查 dialog 後重跑 Remove-TcLibraryReference'
$script:TcErrorHints['PLACEHOLDER_ADD_FAILED'] = 'Add-TcLibraryPlaceholder 失敗(data.reason)。default-library-not-installed:預設 library 沒有安裝，什麼都沒加，先用 Get-TcLibraries -Repository 確認名稱 / 版本 / distributor,沒裝就 Install-TcLibrary;no-device-placeholder:沒給 -LibraryName 時 XAE 找不到同名的 device placeholder,改給 -LibraryName;其他:看 error.message,用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcLibraries 確認 placeholder 有沒有被加上'
$script:TcErrorHints['PLACEHOLDER_FREEZE_FAILED'] = '用 Get-TcLibraries 看各 placeholder 的 effectiveResolution;是 null 的先用 Install-TcLibrary 裝上它的 library,或改用 Lock-TcLibraryPlaceholder -Placeholder <name> 只鎖其他的;要還原就把 data.backupFiles 的 .plcproj 複製回去(先關 solution)'
$script:TcErrorHints['LIBRARY_VERSION_CHANGED'] = '專案已用 data.versionChanges[].after 的版本存檔。要回到凍結前的版本：照 data.restore 把備份的 .plcproj 複製回去再 Reset-TcSolution,或請使用者在 XAE 的 Library Manager 把 data.versionChanges[].placeholder 設回 before 的版本;之後 Get-TcLibraries 確認 effectiveResolution,再 Build-TcProject'
$script:TcErrorHints['LIBRARY_ALREADY_INSTALLED'] = '直接用 Add-TcLibrary / Add-TcLibraryPlaceholder 把它加進專案;要換成這個檔案，先 Uninstall-TcLibrary(先 dry-run)移除舊的，再 Install-TcLibrary'
$script:TcErrorHints['LIBRARY_NOT_INSTALLED'] = 'ScanLibraries 沒有完全符合 -LibraryName / -Version / -Distributor 的項目(大小寫要相同),什麼都沒移除。data.candidates 是同名(不分大小寫)已安裝的版本;用 Get-TcLibraries -Repository -Filter <name> 查正確的值後重跑 Uninstall-TcLibrary'
$script:TcErrorHints['LIBRARY_INSTALL_FAILED'] = 'Install-TcLibrary 的 InstallLibrary 失敗。data.reason = repository-not-found:-Repository 不存在(預設 System);其他看 error.message,用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcLibraries -Repository 確認有沒有裝上'
$script:TcErrorHints['LIBRARY_UNINSTALL_FAILED'] = '用 Get-TcLibraries -Repository 確認這個版本還在不在;還在就改正 -Repository(預設 System)後重跑 Uninstall-TcLibrary;用 Get-TcIdeModalDialog 檢查 XAE 有沒有 dialog'
# CheckAllObjects (complete-automation-interface task 3.7)
$script:TcErrorHints['CHECK_FAILED'] = '依 data.errorItems 的 file / line 修正程式碼(Get-TcPouCode -PouPath <路徑> 讀、Write-TcPouCode -PouPath <路徑> 改),再重跑 Test-TcPlcProject;data.errorItems 是空的就用 Get-TcBuildErrors 讀 Error List'
$script:TcErrorHints['CHECK_UNAVAILABLE'] = '改用 Build-TcProject(它只編譯有被引用的物件)'
# PLC task and program links (complete-automation-interface task 3.5)
$script:TcErrorHints['TASK_ALREADY_EXISTS'] = '<Plc> Project 底下已有這個名稱:要用這個 PLC task 就直接 Add-TcTaskProgram -ProgramName <program> -PlcTask <Name>;要新的 task 就換一個 -Name 重跑 Add-TcPlcTask'
# only TIRT has the name (data.existingIn = TIRT): there is no PLC task to reuse
$script:TcErrorHints['TASK_ALREADY_EXISTS_TIRT'] = '換一個 -Name 重跑 Add-TcPlcTask'
$script:TcErrorHints['TASK_NOT_FOUND'] = '用 data.plcTasks 裡的名稱當 -PlcTask 重跑;要新的 task 先 Add-TcPlcTask -Name <Name> -CycleTimeUs <us> -DryRun $false'
$script:TcErrorHints['TASK_PROGRAM_INVALID'] = 'data.reason = not-found:先 Add-TcPou -Name <Name> -Type Program 建 PROGRAM;not-a-program:改給一個 PROGRAM 的名稱;case-mismatch:改用 -ProgramName <data.actualName>。再重跑 Add-TcTaskProgram'
$script:TcErrorHints['TASK_PROGRAM_ALREADY_LINKED'] = '不用再連;要換 task 先 Remove-TcTaskProgram -ProgramName <data.existingLink> -PlcTask <舊 task> -DryRun $false,再 Add-TcTaskProgram -ProgramName <data.existingLink> -PlcTask <新 task>'
$script:TcErrorHints['TASK_PROGRAM_NOT_LINKED'] = '用 data.linkedPrograms 裡的名稱(大小寫完全相同)當 -ProgramName 重跑 Remove-TcTaskProgram'
$script:TcErrorHints['TASK_CREATE_FAILED'] = 'data.rolledBack = true:排除 data.stepError 的原因後重跑 Add-TcPlcTask;false:先刪 PLC task(data.rollback 裡 code 不是 SKIPPED_DEPENDENT、removed = false 的 path),再刪 SKIPPED_DEPENDENT 的 TIRT task,都用 Remove-TcTreeItem -Path <path> -ConfirmName <Name> -DryRun $false -AllowNoExport,再重跑 Add-TcPlcTask'
$script:TcErrorHints['TASK_VERIFY_FAILED'] = '先看 data.mismatches(field / expected / actual);data.rolledBack = false 時先刪 PLC task,再刪 SKIPPED_DEPENDENT 的 TIRT task(Remove-TcTreeItem -Path <data.rollback 留下的 path> -ConfirmName <Name> -DryRun $false -AllowNoExport),再重跑 Add-TcPlcTask'
# PLCopen XML (complete-automation-interface task 3.3)
$script:TcErrorHints['PLCOPEN_FAILED'] = '依 data.reason 修正後重跑同一個 tool:invalid-selection = -Selection 每個元素一個物件、資料夾層級用 . 分隔(-Selection ''POUs.FB_A'',''DUTs.ST_B''),不要用 ^ 或分號;member-selection = 改成 data.memberSelection.suggestedSelection(method / property / action 只能跟著所屬物件匯出);selection-not-found = 用 Get-TcProjectTree -PlcOnly 查正確的資料夾與名稱;not-absolute / invalid-path / folder-missing / file-missing = 給存在資料夾內的絕對路徑;invalid-file / no-objects = 改給 PLCopen XML 檔(例如 Export-TcPlcOpen 產生的);overwrite-move-failed = 確認舊檔沒被鎖住;import-failed / export-failed / invalid-argument = 看 data.xaeMessage,用 Get-TcIdeModalDialog 檢查 dialog 後重跑'
$script:TcErrorHints['PLCOPEN_FILE_EXISTS'] = '換一個 -FilePath,或加 -Overwrite 重跑 Export-TcPlcOpen(舊檔會先改名成 <檔名>.bak)'
$script:TcErrorHints['PLCOPEN_CONFLICT'] = '依 data.conflicts 選一個 -Option 重跑 Import-TcPlcOpen(先 -DryRun $true 看預告):Skip 保留專案裡的物件、Rename 匯入成 <名稱>_1、Replace 整個覆蓋(會刪掉檔案裡沒有的子物件，先看 data.willReplace[].deletedChildren)'
$script:TcErrorHints['PLCOPEN_VERIFY_FAILED'] = 'Export:看 data.reason(file-not-written / invalid-file / selection-missing)與 data.missingSelections,用 Get-TcProjectTree -PlcOnly 確認名稱後重跑 Export-TcPlcOpen。Import:skip-changed = 用 data.skipped 看哪個檔案變了，先備份再決定要不要用 -Option Rename 重跑;missing = 用 Get-TcProjectTree -PlcOnly 看 data.missing 的物件在不在、data.added 多了哪些;Replace 的原物件要還原就執行 data.backup.restore(Import-TcPlcOpen -FilePath <data.backup.xmlPath> -Option Replace -DryRun $false)'
$script:TcErrorHints['PLCOPEN_BACKUP_FAILED'] = '確認 solution 路徑已知(Connect-TcIde -SolutionPath <sln> 或 Open-TcProject)且 <solution 目錄>\.tcauto-backup 可寫;data.reason = index-incomplete 時用 Get-TcProjectTree -PlcOnly 找出讀不到的資料夾;disk-backup-failed 時確認該物件的 .TcIO / .TcPOU 在 solution 目錄底下只有一份;plcopen-backup-failed 時先用 Export-TcPlcOpen -Selection <data.backupObject 的物件> -FilePath <新的 .xml> 試匯出找原因，再重跑 Import-TcPlcOpen -Option Replace -DryRun $false;不需要覆蓋就改用 -Option Rename'
# Boot project (complete-automation-interface task 3.2)
$script:TcErrorHints['BOOTPROJECT_FAILED'] = '依 data.errorItems 的 file / line 修正程式碼(Get-TcPouCode -PouPath <路徑> 讀、Write-TcPouCode -PouPath <路徑> 改),再重跑 New-TcBootProject;data.errorItems 是空的就用 Get-TcBuildErrors 讀 Error List,或先 Build-TcProject 看錯誤;data.reason = no-method 時改用 Build-TcProject 加 Enable-TcConfig -Force'
$script:TcErrorHints['BOOTPROJECT_VERIFY_FAILED'] = '用 Get-TcIdeInfo 確認 solutionPlatform,再看 data.bootFiles 列出的檔案;重跑 New-TcBootProject 一次;仍沒更新就改用 Build-TcProject 加 Enable-TcConfig -Force'
# SaveAsLibrary / archive (complete-automation-interface task 3.4)
$script:TcErrorHints['LIBRARY_SAVE_FILE_EXISTS'] = '換一個 -FilePath,或加 -Overwrite 重跑 Save-TcPlcLibrary(舊檔會先改名成 <檔名>.bak)'
$script:TcErrorHints['LIBRARY_SAVE_FAILED'] = '依 data.reason 修正後重跑 Save-TcPlcLibrary:extension = 檔名改成 .library 或 .compiled-library;not-absolute / invalid-path / folder-missing = 給存在資料夾內的絕對路徑;save-failed = 看 data.xaeMessage,用 Get-TcIdeModalDialog 檢查 dialog,必要時先 Build-TcProject;not-written = 確認磁碟空間與資料夾權限;overwrite-move-failed = 確認舊檔沒被鎖住'
$script:TcErrorHints['ARCHIVE_FILE_EXISTS'] = '換一個 -FilePath,或加 -Overwrite 重跑 Save-TcArchive(舊檔會先改名成 <檔名>.bak)'
$script:TcErrorHints['ARCHIVE_FAILED'] = '依 data.reason 修正後重跑 Save-TcArchive:extension = -Kind Solution 用 .tnzip、Configuration 用 .tszip;not-absolute / invalid-path / folder-missing = 給存在資料夾內的絕對路徑;save-failed / no-archive-object = 看 data.xaeMessage,用 Get-TcIdeModalDialog 檢查 dialog;not-written / not-a-zip = 確認磁碟空間後重跑;overwrite-move-failed = 確認舊檔沒被鎖住'
$script:TcErrorHints['ARCHIVE_INCOMPLETE'] = '看 data.errorItems 是哪個專案沒打包進去(例如 Scope 專案);只要 TwinCAT 專案時改用 Save-TcArchive -Kind Configuration -FilePath <.tszip>;要完整的 solution 就先在 XAE 修好或移除那個專案，再 Save-TcArchive -Overwrite 重跑'
$script:TcErrorHints['ARCHIVE_UNVERIFIED'] = '確認 XAE 的 Error List 視窗可見(View > Error List、視窗夠大不被截斷)後用 Get-TcBuildErrors 讀，找 "Error creating Archive" 的列;沒有就可以用 data.filePath 的檔案，有就照 ARCHIVE_INCOMPLETE 處理'
# IDE not connected (Assert-TcConnection failed) in the task 3.2-3.4 cmdlets
$script:TcErrorHints['NOT_CONNECTED_IDE'] = '先 Connect-TcIde(要開特定 solution 加 -SolutionPath <sln>),再重跑同一個 tool'

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
    # Thrown by Invoke-TcProjectSaveWithDeadline; before the TIMEOUT / time out patterns below.
    elseif ($text -match 'PROJECT_SAVE_TIMEOUT') {
        $code = 'PROJECT_SAVE_TIMEOUT'
    }
    # Thrown by New-TcPlcObject when XAE refused CreateChild while the PLC is logged in (task 1.8)
    elseif ($text -match '\bPLC_LOGGED_IN:') {
        $code = 'PLC_LOGGED_IN'
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
    # The raw XAE text (not wrapped by New-TcPlcObject), after the IDE_* classifications
    elseif ($text -match $script:TcPlcLoggedInPattern) {
        $code = 'PLC_LOGGED_IN'
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
