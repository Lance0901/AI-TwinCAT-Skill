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
    'SOLUTION_RELOAD_INCOMPLETE' = 'Reset-TcSolution 已經處理 reload 提示 / 重開 solution,但在 -TimeoutSec 內讀回不到「solution 已載入完成」(data.loadCheck:last 是最後一次讀到的 FullName / IsOpen / projectCount / SolutionBuild / ActiveConfiguration / TIPC / PLC 名稱,lastError 是缺哪一項;baseline 是 Reset 前的專案數與 PLC 名稱)。磁碟上的檔案可能已經載入，所以已記成 code-changed(BUILD_REQUIRED)。先 Get-TcIdeModalDialog(MCP: GetIdeModalDialog)看有沒有 dialog 並處理，再重跑 Reset-TcSolution(MCP: ResetSolution;可加大 -TimeoutSec);成功後才 Build-TcProject。不要直接接 Build-TcProject:solution 還沒載完時 Build 可能丟 null 例外(#135 的推測,未在真機確認)'
    'RESET_SOLUTION_UNVERIFIED' = 'Reset-TcSolution 沒有動作(nothing closed):在 -TimeoutSec 內一直讀不到這個 IDE(data.previousIdeProcessId)開著的 solution(data.guardError),無法確認它是模組預期的 data.expectedSolution,所以不關。先 Get-TcIdeModalDialog -ProcessId <data.previousIdeProcessId>(MCP: GetIdeModalDialog ProcessId=<data.previousIdeProcessId>)看有沒有 dialog 並處理,等 XAE 不忙後重跑 Reset-TcSolution(MCP: ResetSolution;可加大 -TimeoutSec);仍讀不到就 Connect-TcIde -SolutionPath <sln>(MCP: ConnectIde SolutionPath=<sln>)重新連線再試'
    'IDE_BLOCKED_OWN'      = 'Connect-TcIde -SolutionPath 沒有另開 IDE,也沒有 attach:被擋住的 IDE(data.ideProcessId)是本 session 啟動的(data.launchedBySession = true),但證據不足以確認它開的就是這個 .sln(data.notAttachedReason)。先處理它的 dialog(data.dialog;Get-TcIdeModalDialog -ProcessId <data.ideProcessId>,MCP: GetIdeModalDialog ProcessId=<data.ideProcessId>)後重跑同一個 Connect-TcIde(MCP: ConnectIde SolutionPath=<sln>);卡死就 Stop-Process -Id <data.ideProcessId>(本 session 啟動的;MCP 沒有這個工具,要在 MCP 之外手動做)再重新 Connect-TcIde。不要用 -LaunchIfBlocked:那會另開一個 IDE 開同一個 .sln'
    'CLEAN_TIMEOUT'        = 'Clean 在 -TimeoutSec 內沒有完成(SolutionBuild.BuildState 沒有到 3 = Done):用 Get-TcIdeModalDialog 檢查有沒有 dialog,沒有就加大 -TimeoutSec 重跑 Clear-TcProject;XAE 沒反應就 kill IDE 後重新 Connect-TcIde -SolutionPath <sln>'
    'CLEAN_FAILED'         = 'Clean 沒有成功:data.failedProjects > 0(SolutionBuild.LastBuildInfo;看 data.errorItems,不只是 Library Manager 的錯誤)或 DTE 一直讀不到 Solution / SolutionBuild(data.nullReads)。看 XAE Output 視窗;剛 Connect-TcIde 完就重跑一次 Clear-TcProject,仍失敗就 Reset-TcSolution 後再試'
    'IDE_MODAL_DIALOG'     = 'XAE/VS 有 modal 視窗擋住 DTE 呼叫。先呼叫 Get-TcIdeModalDialog 看 kind:reload-prompt(檔案或 .plcproj 被磁碟上的工具改了)→ 直接 Reset-TcSolution;其他(例如 Assertion Failed、VS 帳戶設定、Target system reports a fatal error)模組無法自動關閉,請手動處理後重試,或 Disconnect-TcIde -Quit(本 session 啟動的 IDE 改用 Disconnect-TcIde -Quit -Kill),或 kill IDE 後重新 Connect-TcIde'
    'IDE_MODAL_DIALOG_RELOAD' = 'XAE 跳「File has been changed outside the environment. Reload the new file?」:開在編輯器裡的檔案(通常是 .TcPOU)被磁碟上的工具改了,DTE 呼叫被擋住;.plcproj 被改寫(內容相同也算)則跳「The project file ... has been modified outside of TwinCAT XAE. Do you want to reload the project?」,同樣算 reload-prompt(reloadTarget = project);.sln 被改寫時 VS2022 跳方案提示(按鈕 control id 259 重新載入 / 1412 忽略,reloadTarget = solution)。直接呼叫 Reset-TcSolution:project 提示它會按 Yes(依 control id,語系無關;失敗再按一次 Yes,再不行按 No 並 close/reopen)讓 XAE 自己 reload 專案再重連,不必 close/reopen;solution 提示它會按忽略(1412)再 close/reopen(不按重新載入:會再跳儲存 .tsproj 的對話框);檔案提示它會關掉提示(WM_CLOSE)、關閉所有文件、Solution.Close 後在同一個 IDE 重開 solution 並重連(約 20~25 s);關不掉就在 XAE 按 Yes,或 kill IDE 後重新 Connect-TcIde -SolutionPath <sln>。之後改磁碟檔案的規則:POU 沒開在編輯器 → 直接改,XAE 約 5 s 自動吃到;開著 → 改完立刻 Reset-TcSolution(它會順便關掉編輯器,之後就不會再跳);改用 Write-TcPouCode(走 COM 寫 IDE 編輯 buffer,存檔或 Build 時才落地)則不會跳框'
    'IDE_QUIT_FAILED'      = 'IDE 沒有被關掉,行程仍在(pid 見 data.ideProcessId):(a) 被 modal dialog 擋住(data.dialog,quit 沒有嘗試,data.disconnected = false:連線完整保留):kind = reload-prompt → Reset-TcSolution 處理後再 Disconnect-TcIde -Quit;其他 dialog → 本 session 啟動的 IDE(data.ownedBySession = true)用 Disconnect-TcIde -Quit -Kill,否則手動 Stop-Process -Id <data.ideProcessId>。(b) DTE.Quit 失敗(data.quitError,COM 參考已釋放但 pid 有保留):data.ownedBySession = true 就直接接 Disconnect-TcIde -Quit -Kill(不用重連);否則手動 Stop-Process -Id <data.ideProcessId>。不要以為 IDE 已經關掉,下一次 Connect-TcIde 會黏回同一個被擋住的 IDE'
    'IDE_NOT_OWNED'        = '這個 IDE 不是本 session 啟動的(data.selectedBy 不是 launched,例如 solution-match),模組不會 kill 使用者自己開的 IDE。確定要關就自己 Stop-Process -Id <data.ideProcessId>,再重新 Connect-TcIde'
    'PROJECT_SAVE_FAILED'   = '專案檔(.plcproj / .tsproj)沒存到磁碟或讀回沒有新項目:物件(data.objectPath)只在 XAE 記憶體裡,關 solution 不存檔(Reset-TcSolution -DiscardProjectChanges、Disconnect-TcIde -Quit)就會消失。第一步：先 Get-TcIdeModalDialog 看有沒有 dialog(有就處理),確認 .plcproj / .tsproj 不是唯讀 / 被鎖，再重跑同一個 Add-* 會回 *_CREATE_FAILED(exists),所以改跑 Reset-TcSolution -SaveProjectChanges(只存專案檔並讀回;磁碟也被改過時會拒絕)。第二步(仍失敗):請使用者在 XAE 手動存該 PLC 專案;或 Build-TcProject,但注意 Build 會一併存 editor buffer(可能蓋掉磁碟上的 .TcPOU 改動;實測 2026-10-28 .plcproj 的最後寫入時間 = 第一次 Build,#76)。最後 Get-TcProjectTree -PlcOnly 確認物件還在'
    'PROJECT_SAVE_TIMEOUT'  = 'DTE Project.Save() 在期限內沒返回(模組已放棄等待，XAE 內部可能仍在跑),專案檔可能沒存。看 data.saveDiagnostics:dialog 有值 → Get-TcIdeModalDialog 看內容並處理(模組不會替你按);readOnlyFiles 有值 → 解除 .plcproj / .tsproj 的唯讀屬性後 Reset-TcSolution -SaveProjectChanges;ideResponding = false → XAE 卡死,Disconnect-TcIde -Quit -Kill(只限本 session 啟動的)後重新 Connect-TcIde,未存的物件會遺失'
    'PROJECT_UNSAVED_CHANGES' = 'Reset-TcSolution 沒關 solution:XAE 記憶體有、磁碟 .plcproj 沒列的 PLC 物件(data.projectCheck.plcs[].missingOnDisk;只有 extraOnDisk = 磁碟有、XAE 沒有時不擋，重開就載入磁碟版本),模組分不出是「XAE 建了沒存」還是「有人在磁碟上刪 / 改了」,所以不替你選。三條路:(1) 保留 XAE 版本 → Reset-TcSolution -SaveProjectChanges(MCP:ResetSolution SaveProjectChanges=true;只存專案檔);但 data.saveRefused 有值時(處理過 reload 提示、物件檔在磁碟上不存在，或同一個 .tsproj 的任一 PLC 沒比對到 / 比對不完整 / extraOnDisk 非空;Project.Save 會寫整個 .tsproj 底下所有 .plcproj)它會拒絕存，表示磁碟被改過。(2) 以磁碟為準 → Reset-TcSolution -DiscardProjectChanges(丟掉 XAE 的版本)。(3) 兩邊都要 → 先在磁碟上補回需要的檔案 / <Compile Include>,再走 (1) 或 (2)。(4) data.dirtyDocuments 或 data.dirtyDocumentsError 有值(只在 Connect-TcIde -TakeOverOrphan 留下 reset-required 時檢查):XAE 有未存的編輯器文件(Document.Saved = false;dirtyDocumentsError = 讀不到文件狀態),Reset 的 Documents.CloseAll 會不存檔關掉它們，所以模組什麼都沒關。請使用者在 XAE 看過這些文件，要留的內容自己複製出來(直接存檔會把記憶體裡的舊內容寫回、蓋掉磁碟上的改動),確定不要了才 Reset-TcSolution -DiscardProjectChanges(MCP:ResetSolution DiscardProjectChanges=true)。不要用 Build-TcProject 解：它不會替你選邊(Build 會不會一併存 PLC editor buffer 是推論、未實測)'
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
    'ERRORLIST_INCOMPLETE'  = 'Error List 讀到的列比摘要按鈕上的總數少(data.missingRows:severity / expected / read),或 scope 篩選停在「目前專案 / 目前文件 / 開啟文件」等切不回「整個方案」(data.scope),讀到的只是一部分，不能拿來證明 0 errors。到 XAE 的 Error List 把 scope 下拉選成「整個方案」(Entire Solution)、Errors / Warnings / Messages 三個按鈕都按下、清空 Error List 的搜尋框，再重跑 Get-TcBuildErrors。Build-TcProject 只有 error 列不完整時才算未驗證(codeVerified = null、CODE_NOT_VERIFIED,要重跑 Build-TcProject 才會解除 BUILD_REQUIRED);只少 warnings 是 WARNINGS_INCOMPLETE。仍不符時看 data.notes,見 docs/troubleshooting.md ERRORLIST_INCOMPLETE'
    'WARNINGS_INCOMPLETE'   = 'Build-TcProject:Error List 的 error 列完整，但 warnings 讀到的比按鈕總數少(data.missingRows、data.errorListNote),data.warningItems 不是整份清單。不影響 codeVerified / completeBuild。要完整的 warning 清單：在 XAE 的 Error List 把 scope 選成「整個方案」、清空搜尋框後重跑 Get-TcBuildErrors;見 docs/troubleshooting.md WARNINGS_INCOMPLETE'
    'BUILD_TIMEOUT'         = 'Build 在 -TimeoutSec 內沒有完成(SolutionBuild.BuildState 沒有到 3 = Done):用 Get-TcIdeModalDialog 檢查有沒有 dialog,看 XAE Output 視窗的 Build 進度;大型專案加大 -TimeoutSec 後重跑 Build-TcProject,XAE 沒反應就 kill IDE 後重新 Connect-TcIde'
    'PLATFORM_NOT_FOUND'    = 'Solution 沒有這個 platform:用 data.availablePlatforms 裡的名稱重跑 Set-TcTarget -AmsNetId <id> -Platform <name>(Usermode Runtime(UmRT)/ TwinCAT/BSD target 是 ''TwinCAT OS (x64)'',Windows RT target 是 ''TwinCAT RT (x64)'')'
    'PLATFORM_UNKNOWN'      = 'target 不支援 TARGETINFO(ADS 0x702),請用 -Platform ''<平台>'' 指定;UmRT / TwinCAT/BSD 為 ''TwinCAT OS (x64)''(Windows RT target 為 ''TwinCAT RT (x64)'')。只要改 target NetId 就加 -NoPlatformSwitch(NetId 已經設好了,data.targetSet = true)。平台由目標對象決定(不是 XAE 版本);solution platform 名稱可能對到別的 project platform,模組切換前會檢查 .tsproj 的 project platform,不符就回 PLATFORM_PROJECT_MISMATCH(看 data.platformMap)。TARGETINFO 說明:https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html'
    'PLATFORM_MISMATCH'     = 'Active solution platform 與 target platform 不一致,Activate 會失敗(Check config failed)。執行 Set-TcTarget -AmsNetId <id> -Platform ''<platform>'' 後重跑 Build-TcProject 與 Enable-TcConfig,或拿掉 -NoPlatformFix 讓 Enable-TcConfig 自己切換並重新 Build'
    'PLATFORM_PROJECT_MISMATCH' = 'Solution platform 名稱對了,但它底下的 TwinCAT 專案(.tsproj)被編給另一個 project platform,切過去也不會為這個 target 編譯,所以沒有切換。到 XAE 的 Build > Configuration Manager,讓該 solution platform 底下的 TwinCAT 專案(.tsproj)與 PLC 專案對到正確的 project platform(沒有就在 Platform 欄 <New...> 新增)並勾 Build,存檔後重跑 Set-TcTarget -AmsNetId <id> -Platform ''<platform>'';或改選 data.platformMap 裡 project platform 正確的 solution platform。專案平台不能改時:Set-TcTarget -NoPlatformSwitch 只設 NetId,Enable-TcConfig 不帶 -Platform(target 有 TARGETINFO 時 Enable-TcConfig 仍會擋下,只能修專案設定)。說明:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html'
    'BUILD_SELECTION_CHANGED' = '切換 solution platform 會改變 PLC project 是否參與 Build,所以沒有切換(切換後才讀到改變的，已切回原平台，看 data.restored)。data.buildSelectionChanges 列出每個會改變的 PLC:current(目前 active configuration 的 shouldBuild / disabled)與 target(目標 configuration 的 shouldBuild)。PLC 的 Disabled 就是 active configuration 有沒有該 PLC 的 Build.0(實測 2026-11-03,4026),在一個平台停用的 PLC 換平台後會被 build、download、Run。到 XAE 的 Build > Configuration Manager 選目標 configuration(data.buildSelectionChanges[].configuration),讓每個 PLC 的 Build 勾選與目前一致，存檔後重跑;確定要改 build 範圍，就先在目前平台調整(停用 / 啟用 PLC)再切。ShouldBuild 是 per configuration:https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html'
    'BUILD_SELECTION_UNKNOWN' = '切換 solution platform 前(或切換後讀回時)無法比對每個 PLC project 的 build selection:SolutionContexts 的 ShouldBuild 讀不到、PLC 樹(TIPC)讀不到，或 PLC 節點對不到唯一的 .plcproj,所以沒有切換(fail closed;切換後讀回失敗時已切回原平台，看 data.restored)。看 error.message:IDE 忙就重試;PLC 名稱與 .plcproj 檔名不同、又讀不到 PlcProjectDef/ProjectPath 時，讓兩者一致;或在 XAE 手動切平台，確認 Configuration Manager 每個 PLC 的 Build 勾選後再 Build-TcProject'
    'PLATFORM_SET_FAILED'  = 'Solution platform 沒有切換成功:用 Get-TcIdeInfo 看 solutionPlatform,檢查 XAE 有沒有 dialog(Get-TcIdeModalDialog);必要時在 XAE 工具列的 Solution Platforms 下拉手動選,再重跑 Set-TcTarget -Platform'
    'ACTIVATE_FAILED'       ='ActivateConfiguration() 回來了但 XAE 的 Check config 失敗(Output 視窗「Check config failed!」),target 上什麼都沒寫。最常見原因:active solution platform 跟 target platform 不一致(target 不支援 TARGETINFO 時 Enable-TcConfig 無法事先比對)。執行 Set-TcTarget -AmsNetId <id> -Platform ''TwinCAT OS (x64)''(Usermode Runtime / UmRT;Windows RT target 用 ''TwinCAT RT (x64)''),再重跑 Build-TcProject 與 Enable-TcConfig;或直接 Enable-TcConfig -Platform ''TwinCAT OS (x64)'',它會先切換並重新 Build'
    'TYPE_MISMATCH'        = 'Write-TcVariable 依 symbol 型別轉換值。支援:BOOL、SINT/USINT/BYTE/INT/UINT/WORD/DINT/UDINT/DWORD/LINT/ULINT/LWORD(整數)、REAL/LREAL、STRING、TIME/TOD(IEC 字面 T#6s、T#1m30s500ms、TOD#12:30:00;整數 ms 也收)、LTIME/LTOD(LTIME#1us;整數 ns 也收)、DATE/DT(D#2026-10-20、DT#2026-10-20-12:30:00 或 ISO 8601;整數 UNIX 秒也收)、LDATE/LDT(LDT#…;整數 ns 也收)、enum(整數或成員名)。STRUCT/ARRAY 不能整筆寫,改寫個別成員(例如 stPar.fMax);用 Get-TcSymbols 看 type(enum 會列 enumValues)'
    'LIBRARY_UNRESOLVED'    = '先在 XAE 的 Library Manager 安裝缺的 library(data.libraryErrorItems 列出名稱與版本),再重跑 Build-TcProject;在那之前 build 成功不代表程式碼有被編譯。Build-TcProject -AllowUnresolvedLibrary 只讓這次 build 回 success + warningCode,不算完整 build(completeBuild = false),BUILD_REQUIRED 會保留，所以 Enable-TcConfig / Enter-TcPlcOnline 仍然拒絕 Activate / Login(#61):module 記錄到這種 build 之後不會 Activate / Download / Run(從未經 module build 的 solution 不擋，範圍見 BUILD_REQUIRED 與 docs/troubleshooting.md BUILD_REQUIRED)'
    'CODE_NOT_VERIFIED'     = 'Build-TcProject 回 success,但無法確認 PLC 程式碼有被編譯(Error List 讀不到、有沒有行號的 code 列、有 PLC project 被 active solution configuration 略過，或 LastBuildInfo 讀不到時 Error List 有 runtime / system log rows present(data.runtimeMessages,#66)):看 XAE 的 Error List;有 runtime / system log 列時先 Exit-TcPlcOnline,在 XAE 清掉 Error List 的舊 log 列，再 Build-TcProject(#66 實測過 Logout 後舊 TcUnit 列仍留在 Error List);Error List 讀不到時見 ERRORLIST_UNAVAILABLE,讀不完整時見 ERRORLIST_INCOMPLETE;被略過時(data.skippedProjects)見 PROJECT_SKIPPED_BY_CONFIGURATION,在 Configuration Manager 勾起 Build 後重跑 Build-TcProject -ExpectedProject <name>;solution 裡沒有 .plcproj(只有 I/O 或 NC)時，這個碼是預期結果，不需處理'
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
    'EXPECTED_PROJECT_DISABLED' = '-ExpectedProject 指定的 PLC project 在 TwinCAT 專案裡是 disabled(ITcSmTreeItem.Disabled,.tsproj <Project Disabled="true">),Activate 不會載入它(InfoSys https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html),不能當 expected project:從 -ExpectedProject 拿掉它;真的要用就先在 XAE 的 PLC 節點右鍵 Disable 取消(存檔)再 Build。data.disabledProjects / data.projects[].disabled 列出 disabled 的 project'
    'EXPECTED_PROJECT_NOT_FOUND' = '-ExpectedProject 給的名稱不是這個 solution 的 PLC project(比對 .plcproj 檔名,不含副檔名);data.projects 列出可用名稱'
    'BUILD_COVERAGE_UNKNOWN' = '無法確認指定的 PLC project 有參與 Build(SolutionContexts 讀不到,或 Build 失敗時 Error List 沒有該 project 的錯誤):看 data.projects / data.coverageError 與 XAE Error List,不要當成 Build 成功。data.unreadableProjects 有值時是某個 PLC project 的 ShouldBuild 讀不到(不論有沒有 -ExpectedProject,Build 都沒開始,#67):先重試(IDE 忙);持續讀不到就 Reset-TcSolution,或到 XAE 的 Build > Configuration Manager 確認該 PLC project 的 Build 勾選後存檔再 Build-TcProject'
    'SYSTEM_STATE_MISMATCH' = 'TwinCAT 短暫進入要求的狀態後又離開(data.stateTrace):通常是 runtime 啟動失敗退回 Config,例如 PLC 的 symbol description 與 application 不一致(ADS 1809 / 0x711)、license 不足或 Boot 目錄的 CurrentConfig 是舊的。用 Get-TcIdeModalDialog / XAE Error List 看 fatal error,Enable-TcConfig -Force 會回 data.bootPackage 比對 Boot 檔案'
    'RUNTIME_STATE_MISMATCH' = 'Enable-TcConfig 最後讀回的 system state 或某個 PLC port 不是 Run(data.finalCheck、data.plcs):看 data.diagnostics(modal dialog、Error List、bootPackage);Boot package 不一致時重新 Enable-TcConfig -Force(Activate 會重寫 Boot),仍不一致見 docs/troubleshooting.md「Boot package 不一致」'
    'BOOT_PACKAGE_MISMATCH' = 'Target 的 Boot 目錄與專案 _Boot\<platform> 的 CurrentConfig.xml / CurrentConfig.tszip / CurrentConfig\*.tpzip / Plc\Port_*.app 不一致(data.bootPackage.files 有 SHA-256 與時間):Activate 沒有把新的 configuration 寫到 target。先重跑 Enable-TcConfig -Force;仍不一致時手動備份 target Boot 目錄後,把 _Boot\<platform> 的這些檔案複製過去再 Activate(模組不會自動覆寫 target 檔案)'
    'ACTIVATE_TIMEOUT'     = 'ActivateConfiguration() 在 -ActivateTimeoutSec 內沒返回,模組已放棄等待(XAE 內部可能仍在跑)。看 data.activateDiagnostics:dialog 有值 → 處理該視窗(Get-TcIdeModalDialog);ideResponding = false → XAE 卡死,Disconnect-TcIde -Quit -Kill(本 session 啟動的)或手動結束後重新 Connect-TcIde;runtimeAlive = false → UmRT(TcSystemServiceUm)已停,依 docs/troubleshooting.md 重啟後再 Enable-TcConfig -Force;systemState unreachable → target 沒回應'
    'ADS_SYMBOL_VERSION_INVALID' = 'ADS 0x711(1809) ADSERR_DEVICE_SYMBOLVERSIONINVALID「Invalid symbol version」:PLC 的 symbol description 與 application 版本不同(online change 後或 Boot package 不一致)。Read-TcVariable / Write-TcVariable 已自動重開 ADS session 重試過一次(#26),仍失敗就用 Get-TcPlcState 看 PLC 狀態;若是 Activate 後才出現,檢查 Enable-TcConfig 的 data.bootPackage。出處 https://infosys.beckhoff.com/content/1033/tc3_c/374277003.html'
}
# #27: Start-TcLifecycle / MCP RunLifecycle, -AdsPort is not the port of a PLC selected with -PlcProjectPath
$script:TcErrorHints['PLC_PORT_MISMATCH'] = '-AdsPort 不是 -PlcProjectPath 選中的 PLC 的 ADS port(允許的 port 在 error.message;ConnectAds 步驟 result.data 的 allowedPorts / plcs),ADS 沒有連線。Enable-TcConfig 已成功：已 activate;沒有 -NoLogin 時也已 login / Run。不必重跑整個 lifecycle:Connect-TcAds -Port <allowedPorts 其中一個> 再 Get-TcPlcState 讀回(MCP:ConnectAds Port=<port>、GetPlcState);下次拿掉 -AdsPort 或改成允許的 port'
# Compile errors (Build-TcProject, only when the build really failed): generic BUILD_FAILED
# from a COM exception keeps no hint, so this one is looked up explicitly.
$script:TcErrorHints['BUILD_FAILED_COMPILE'] = '看 data.errorItems(code / description / file / line);修正後重跑 Build-TcProject'
# #66 / O9 (實測 2026-11-06, VS2022 4026 + local UmRT) and #188 (實測 2026-11-08, 4026 VS2022 + local UmRT):
# BUILD_FAILED with no error row while the PLC is logged in - XAE did not compile; Build-TcProject sets
# data.plcOnlineSuspected / plcOnlineEvidence ('login-state': IsLoggedIn / ProduceXml read back logged in;
# 'runtime-log': only runtime log rows, suspected) and uses this hint. Cmdlet names only, once each: the MCP
# server rewrites them to tool names (mcp-server/lib/tools.js rewriteHintCmdletNames -> PlcLogout / BuildProject).
$script:TcErrorHints['BUILD_FAILED_PLC_ONLINE'] = 'PLC is logged in (data.plcOnlineEvidence = login-state, read back from the IDE) or probably logged in (runtime-log: suspected from runtime log rows only, no compiler error row); XAE does not compile while logged in. Log out with Exit-TcPlcOnline, then run Build-TcProject again(PLC login 中 XAE 不編譯，真的編譯錯誤要 Logout 後重新 Build 才會出現在 Error List;data.plcLoginState 列出每個 PLC 的 login 狀態;Logout 後舊的 TcUnit / runtime log 列仍會留在 Error List,可在 XAE 手動清掉)'
# Legacy code kept by Read-TcVariable for a missing symbol: same hint as ADS_SYMBOL_NOT_FOUND
$script:TcErrorHints['SYMBOL_NOT_FOUND'] = $script:TcErrorHints['ADS_SYMBOL_NOT_FOUND']
# #60: Read-TcVariable with several paths, at least one failed (fail closed)
$script:TcErrorHints['PARTIAL_READ_FAILED'] = '多路徑讀取有 path 讀不到(頂層 failedPaths;每筆的 error / code / hint 在 data 的那一筆):讀到的值仍在 data 裡，但整筆結果不算成功。code 是 ADS_SYMBOL_NOT_FOUND → 用 Get-TcSymbols 確認路徑(新變數要先下載);是連線類錯誤(ADS_TARGET_NOT_FOUND / ADS_PORT_NOT_FOUND / ADS_TIMEOUT)→ 先 Get-TcPlcState 確認狀態再重讀。只重讀 failedPaths 即可'
# #139: Watch-TcVariable, a read failed in at least one sampling round (fail closed)
$script:TcErrorHints['WATCH_READ_FAILED'] = '監看期間有 path 讀不到(頂層 failedPaths;data.failedReads 是每個 path 失敗的輪數,data.lastErrors 是最後一次的 error / code / hint):samples 裡那些讀取是 null,不是 PLC 的值，整筆結果不算成功;Until 的 path 讀不到時 untilMet 不代表條件真的沒成立。code 是 SYMBOL_NOT_FOUND / ADS_SYMBOL_NOT_FOUND → 用 Get-TcSymbols 確認路徑(新變數要先下載);是連線類錯誤(ADS_TARGET_NOT_FOUND / ADS_PORT_NOT_FOUND / ADS_TIMEOUT)→ 先 Get-TcPlcState 確認狀態再重新監看'
# #47: Add-TcDut / Add-TcGvl read back a member order that differs from the input order
$script:TcErrorHints['MEMBER_ORDER_MISMATCH'] = 'DUT / GVL 已建立並存檔,但讀回的成員順序(data.actualOrder)與輸入(data.expectedOrder)不同:用 Write-TcPouCode -PouPath <data.path> -Declaration <依正確順序的 declaration> 改寫,再 Get-TcPouCode 確認後 Build-TcProject;不要沿用這個順序(STRUCT 記憶體配置會不同)'
# #70: New-TcProject refuses while the IDE has a solution open: Solution.Create closes it without
# a warning (實測 2026-10-28, #70: 4026.22 XAE in VS2022 / 4024 32-bit XAE Shell, registered tcauto)
$script:TcErrorHints['SOLUTION_ALREADY_OPEN'] = 'IDE 已開著 solution(data.openSolution),New-TcProject 不會建立:Solution.Create 會關掉目前的 solution 並丟掉未存的改動(#70)。建議在 XAE 手動建立新專案後用 Connect-TcIde -SolutionPath <新 .sln> 接上;要用 New-TcProject 就先在 XAE 存好、關掉目前的 solution 再呼叫。NewProject 目前不在 MCP 提供'
# #30: Get-TcAutomationVersion (install manifest written by TwinCATSetup-*.ps1)
$script:TcErrorHints['INSTALL_MANIFEST_NOT_FOUND'] = '這個模組不是安裝出來的副本(沒有 tcauto-install-manifest.json,data.source = source-tree),沒有東西可以 -Verify:不帶 -Verify 的 Get-TcAutomationVersion 看 data.commit / data.commitSource。舊版 installer 裝的 skill 也沒有 manifest:在來源 repo 重跑 TwinCATSetup-<工具>.ps1 後再驗證'
$script:TcErrorHints['INSTALL_MANIFEST_INVALID'] = 'tcauto-install-manifest.json 讀不出來(JSON 壞掉、缺 schemaVersion / files、比這個模組新的 schemaVersion,或 files[].path 指到安裝目錄外:..、絕對路徑、:、\):不要手動修改它，在來源 repo 重跑 TwinCATSetup-<工具>.ps1 重新安裝(會重寫 manifest)'
$script:TcErrorHints['INSTALL_MANIFEST_MISMATCH'] = '安裝的檔案與 manifest 記錄的 SHA256 不同(data.verify.mismatched / missing / extra / unreadable):有人改過、只更新了一部分，或檔案讀不到(被鎖住、沒有權限，看 unreadable[].error)。把 data.verify 回報給使用者，在來源 repo 重跑 TwinCATSetup-<工具>.ps1(或 -Verify 看與來源的差異)後再用；不要自己改回檔案'
$script:TcErrorHints['PROJECT_DIR_EXISTS'] = '<Path>\<Name> 資料夾已存在(data.path):New-TcProject 不會寫進既有資料夾,也沒有呼叫 Solution.Create,IDE 的 solution 沒動。換一個 -Name / -Path,或自己確認並刪除空的舊資料夾後重跑;見 docs/troubleshooting.md「PROJECT_DIR_EXISTS」'
$script:TcErrorHints['PROJECT_CREATE_UNVERIFIED'] = 'New-TcProject 的呼叫沒有丟錯,但讀回少了東西(data.missing:.sln / .tsproj / .plcproj 或 TIPC^<Name>_Plc 節點):不要當成成功。IDE 現在開著這個半成品 solution,模組已把 solution 路徑設為未知並記 BUILD_REQUIRED(<unknown>)。用 Get-TcIdeModalDialog 看有沒有 dialog,在 XAE 檢查 data.path,通常要刪掉該資料夾、關掉 solution 後重建;見 docs/troubleshooting.md「PROJECT_CREATE_UNVERIFIED」'
# #70: New-TcProject found no 'TwinCAT Project.tsproj' (InfoSys 242721803 passes it as the AddFromTemplate path)
$script:TcErrorHints['TEMPLATE_NOT_FOUND'] = '找不到 TwinCAT 專案 template(TwinCAT Project.tsproj,已查的路徑在 data.searched):New-TcProject 沒有呼叫 Solution.Create,IDE 的 solution 沒動。確認 TwinCAT XAE 已安裝(預設 <TwinCAT 目錄>\3.1\Components\Base\PrjTemplate),或把 TWINCAT3DIR 設成 TwinCAT 的 3.1 目錄後重試;見 docs/troubleshooting.md「TEMPLATE_NOT_FOUND」'

# task 1.3 (complete-automation-interface): I/O scan and variable link (TE1000 v1.7.0 6.6.2, 5.1.1.2, 5.1.1.8, 5.1.3.4)
$script:TcErrorHints['IO_SCAN_REQUIRES_CONFIG'] = 'I/O scan 需要 TwinCAT 在 Config mode(TE1000 6.6.2 Requirements);data.state 是目前狀態。先 Set-TcSystemState -State Config 再重跑 Invoke-TcIoScan(本機 UmRT 切 Config 可能 crash,#21,見 troubleshooting「已知限制」);掃完用 Enable-TcConfig -Force 回 Run'
$script:TcErrorHints['MODAL_SCAN_INCOMPLETE'] = 'modal dialog 掃描沒有完成(data.modalScan.reason:timeout = UI Automation 掃描超過 -TimeoutSec;prepare-timeout = 載入 UIA / 編譯掃描用型別逾時;error = 掃描失敗),所以「IDE 有沒有 dialog」是未知，不是沒有;原本的操作沒有執行(或結果未驗證)。用 Get-TcIdeModalDialog -TimeoutSec 15(MCP:GetIdeModalDialog TimeoutSec=15)再掃一次:data.scanComplete = true 且 dialog = null 才代表沒有 dialog,有 dialog 依 kind 處理(reload-prompt → Reset-TcSolution);確認後重跑原本的指令。機器忙(CPU 滿載)時掃描會變慢，仍逾時就先等負載降下來。見 docs/troubleshooting.md「MODAL_SCAN_INCOMPLETE」'
# Caller-specific fragments appended to a hint (not hint keys, so no troubleshooting heading of
# their own; they extend MODAL_SCAN_INCOMPLETE / IDE_BLOCKED_*). Kept here so hint text stays in
# one language and in one file (#42 review). <pid> is replaced by the caller.
$script:TcHintFragments = @{
    'MODAL_SCAN_INCOMPLETE_QUIT'    = 'Disconnect-TcIde 的其他做法：不加 -Quit 只釋放 COM 參考(IDE 繼續開著);本 session 啟動的 IDE(data.ownedBySession = true)可用 Disconnect-TcIde -Quit -Kill 結束。'
    'IDE_BLOCKED_SCAN_INCOMPLETE'   = '先重掃:Get-TcIdeModalDialog -ProcessId <pid> -TimeoutSec 15(這個 IDE 的 dialog 掃描沒有完成,data.modalScan)。'
    # #196: other-session with hostState gone
    'IDE_LAUNCH_PENDING_ORPHAN'     = 'data.otherSession.hostState = gone:啟動這個 IDE(pid <pid>)的 TcAuto session 已經結束。先問使用者那個 IDE 有沒有人還在用(有沒有未存檔的修改);使用者同意接手後，重跑同一個 Connect-TcIde 加 -TakeOverOrphan(MCP:ConnectIde TakeOverOrphan=true),成功後本 session 擁有它(data.takenOver = true),可以 Disconnect-TcIde -Quit / -Quit -Kill。'
}
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
$script:TcErrorHints['TREEITEM_VERIFY_FAILED'] = '修改呼叫有返回,但讀回不符(data.mismatches 的 expected / actual;data.unexpectedChanges 是片段以外、或父節點裡不該變卻變了的欄位;data.missingChildren / addedChildren 是建立 / 匯入後子節點名稱不是「原有的加一個」;或節點建立後找不到、刪除後還在):不要當成功。看 data.backupPath(寫入前的 ProduceXml)與 data.backupFiles,用 ProduceXml 確認目前內容;要還原就用 ConsumeXml 送回備份裡對應的欄位(先 dry-run),刪錯的節點用 ImportChild 匯入 data.exportPath;備份裡的密碼欄位(password / passwd / pwd)一律是 ***,不能拿來還原密碼，要在 XAE 重新輸入'
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
    'secret-only'              = '片段裡有變動的欄位全是密碼欄位(名稱含 password / passwd / pwd,data.secretPaths):ProduceXml 一律把它顯示成 ***,寫入後無法讀回驗證，什麼都沒送。密碼請在 XAE 裡直接輸入;片段值是 *** 時更不能送(會把密碼改成 ***)'
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
$script:TcErrorHints['RUNTIME_CRASHED'] = '本機 UmRT(TcSystemServiceUm)在等待狀態切換時消失：開始等待時的行程(data.servicePidAtStart)已不在，且 port 10000 連續回 ADS 0x7 超過 10 s(data.crashDetectedBy = streak);或等到 -TimeoutSec 時最後一次讀取失敗、這個 runtime 已沒有任何 TcSystemServiceUm 行程(data.crashDetectedBy = deadline,診斷在 data.probeErrors、data.deadlineCheck)。這個 target 已記錄 lifecycle block(#68):停止，把 data(lastError、lastState、servicePidAtStart、runtimeName、crashDetectedBy)回報使用者，由使用者決定是否重啟 TcSystemServiceUm;不要自行重啟 service、Stop-Process 或操作 console。使用者處理並同意後才 Clear-TcLifecycleBlock(-Reason、-FallbackMethod、-AllowedSideEffects、-MaxVerifyLevel 都必填),再 Enable-TcConfig -Force(MCP:EnableConfig Force=true)。給使用者參考:UmRT 重啟方式見 docs/troubleshooting.md「SYSTEM_STATE_TIMEOUT」;crash 簽名(Windows 事件 1000 的 faulting module / exception、%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.<pid>.dmp)對照 docs/troubleshooting.md「已知限制」的 UmRT crash(#21)'
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
$script:TcErrorHints['LIBRARY_INVALID_ARGUMENT'] = '參數不合法，什麼都沒改(data.reason)。name / empty:名稱是空的;no-library-name:Add-TcLibraryPlaceholder 給了 -Version / -Distributor 卻沒給 -LibraryName;ambiguous:同名的 library 和 placeholder 都在，要移除 placeholder 就給 -Name ''#<name>''(或 -Kind Placeholder);ambiguous-library-not-measured:兩者並存時不支援只移除 library,請使用者在 XAE 的 Library Manager 手動移除;kind-conflict:-Name 帶 # 時不要給 -Kind Library;not-placeholder:Lock-TcLibraryPlaceholder 只能鎖 placeholder;target:Lock-TcLibraryPlaceholder 要給 -Placeholder 或 -All 其中一個;implicit-placeholder:這個 placeholder 沒有 <PlaceholderReference>,不能單獨鎖，改鎖其他的或用 -All(會跳過它);wildcard:Uninstall-TcLibrary 只接受完整的名稱 / 版本 / distributor,先用 Get-TcLibraries -Repository 查;path / extension / missing / repository:Install-TcLibrary 要給存在的 .library / .compiled-library 絕對路徑與 repository 名稱'
$script:TcErrorHints['LIBRARY_NOT_FOUND'] = '專案的 References 沒有這個 library / placeholder(或 XAE 回 not found),什麼都沒改。用 Get-TcLibraries 看 data.libraries[].name / placeholderName(placeholder 列成 #<name>),拼對名稱後重跑同一個 tool;要加 placeholder 用 Add-TcLibraryPlaceholder,要加 library 用 Add-TcLibrary'
$script:TcErrorHints['LIBRARY_VERIFY_FAILED'] = '寫入呼叫有返回，但讀回不符(data.step / data.reason:references、library、project-file、not-frozen、not-listed、still-installed),不要當成功。專案的改動：用 Get-TcLibraries 看目前狀態，寫入前的 .plcproj 在 data.backupFiles(Remove / Lock 才有);repository 的改動：用 Get-TcLibraries -Repository 確認。確認原因後再重跑同一個 tool'
$script:TcErrorHints['LIBRARY_BACKUP_FAILED'] = '寫入前的備份沒寫成(Remove-TcLibraryReference / Lock-TcLibraryPlaceholder:.plcproj;Uninstall-TcLibrary:repository 裡該版本的目錄，推不出位置時 data.repositoryFolder = null),或 solution 路徑不明、<solution 目錄>\.tcauto-backup 無法寫入，什麼都沒改。先 Connect-TcIde -SolutionPath <sln>(或 Open-TcProject)讓模組知道 solution,確認該目錄可寫，再重跑同一個 tool(先 -DryRun $true 看 data.projectFile / data.repositoryFolder 有值);Uninstall-TcLibrary 的目錄推不出來時請使用者在 XAE 的 Library Repository 手動處理'
$script:TcErrorHints['LIBRARY_REMOVE_FAILED'] = 'XAE 的 RemoveReference 呼叫時或之後失敗，看 error.message;reference 可能已經移除。用 Get-TcLibraries 確認，寫入前的 .plcproj 在 data.backupFiles;用 Get-TcIdeModalDialog 檢查 dialog 後重跑 Remove-TcLibraryReference'
$script:TcErrorHints['PLACEHOLDER_ADD_FAILED'] = 'Add-TcLibraryPlaceholder 失敗(data.reason)。default-library-not-installed:預設 library 沒有安裝，什麼都沒加，先用 Get-TcLibraries -Repository 確認名稱 / 版本 / distributor,沒裝就 Install-TcLibrary;no-device-placeholder:沒給 -LibraryName 時 XAE 找不到同名的 device placeholder,改給 -LibraryName;其他:看 error.message,用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcLibraries 確認 placeholder 有沒有被加上'
$script:TcErrorHints['PLACEHOLDER_FREEZE_FAILED'] = '用 Get-TcLibraries 看各 placeholder 的 effectiveResolution;是 null 的先用 Install-TcLibrary 裝上它的 library,或改用 Lock-TcLibraryPlaceholder -Placeholder <name> 只鎖其他的;要還原就照 data.restore:把 data.backupFiles 的 .plcproj 複製回 data.projectFile,再 Reset-TcSolution'
$script:TcErrorHints['LIBRARY_VERSION_CHANGED'] = '照 data.restore:把 data.backupFiles 的 .plcproj 複製回 data.projectFile,再 Reset-TcSolution;之後 Get-TcLibraries 確認 effectiveResolution 是 data.versionChanges[].before,再 Build-TcProject'
$script:TcErrorHints['LIBRARY_ALREADY_INSTALLED'] = '直接用 Add-TcLibrary / Add-TcLibraryPlaceholder 把它加進專案;要換成這個檔案，先 Uninstall-TcLibrary(先 dry-run)移除舊的，再 Install-TcLibrary'
$script:TcErrorHints['LIBRARY_NOT_INSTALLED'] = 'ScanLibraries 沒有完全符合 -LibraryName / -Version / -Distributor 的項目(大小寫要相同),什麼都沒移除。data.candidates 是同名(不分大小寫)已安裝的版本;用 Get-TcLibraries -Repository -Filter <name> 查正確的值後重跑 Uninstall-TcLibrary'
$script:TcErrorHints['LIBRARY_INSTALL_FAILED'] = 'XAE 的 InstallLibrary 呼叫失敗。data.reason = repository-not-found:-Repository 不存在(預設 System);其他看 error.message,用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcLibraries -Repository 確認有沒有裝上'
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
# save-verify failed and the rollback could not be confirmed on disk (data.diskState)
$script:TcErrorHints['TASK_VERIFY_FAILED_DISK'] = '先用 Get-TcProjectTree -PlcOnly 確認 data.plcTaskPath 已不在樹上(還在就照 data.rollback 刪掉),再用 Reset-TcSolution -SaveProjectChanges 把專案存回磁碟，確認 data.diskState.plcproj 已沒有 <Name>.TcTTO 後再重跑 Add-TcPlcTask'
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
# Phase 3 task 4.1: NC (Add-TcNcTask / Add-TcNcAxis / Set-TcNcAxisParameter / Connect-TcNcAxisToPlc)
$script:TcErrorHints['NC_TASK_NOT_FOUND'] = '專案沒有 NC task(或 -Task 不是 NC task):先 Add-TcNcTask -DryRun $false 建一個，再重跑;data.ncTasks 列出現有的 task'
$script:TcErrorHints['NC_TASK_AMBIGUOUS'] = '有多個 NC task:用 data.ncTasks 其中一個當 -Task 重跑'
$script:TcErrorHints['NC_TASK_ALREADY_EXISTS'] = '一個 TINC 只能有一個 NC task(實測 0x98510002):直接用 data.existingTasks 的 task,例如 Add-TcNcAxis -Name <axis> -Task <data.existingTasks[0]>'
$script:TcErrorHints['NC_TASK_VERIFY_FAILED'] = '建立後讀回不到 task 或它的 Axes 節點:看 data.rolledBack;false 時用 Remove-TcTreeItem -Path <data.taskPath> -ConfirmName <名稱> -DryRun $false 刪掉，再用 Get-TcTreeItem -Path TINC 確認後重跑'
$script:TcErrorHints['NC_AXIS_ALREADY_EXISTS'] = '同名的軸已經存在(XAE 不擋同名，模組擋):換一個 -Name 重跑 Add-TcNcAxis,或直接用現有的軸(Set-TcNcAxisParameter -Axis <名稱>)'
$script:TcErrorHints['NC_AXIS_NOT_FOUND'] = '找不到這支軸:用 data.ncAxes 裡的名稱或完整 tree path(TINC^<task>^Axes^<axis>)當 -Axis 重跑'
$script:TcErrorHints['NC_AXIS_AMBIGUOUS'] = '有多支同名的軸:改用 data.ncAxes 裡的完整 tree path 當 -Axis 重跑(或先把重複的軸改名 / 刪掉)'
$script:TcErrorHints['NC_AXIS_VERIFY_FAILED'] = '建立後讀回不符(data.mismatches):看 data.rolledBack;false 時用 Remove-TcTreeItem -Path <data.axisPath> -ConfirmName <名稱> -DryRun $false 刪掉再重跑 Add-TcNcAxis'
$script:TcErrorHints['NC_INVALID_SUBTYPE'] = '型別號碼 XAE 沒有名稱(data.allowedTypes 是可以用的值;寫入後 ItemSubTypeName 是空的就已送回原值，看 data.reverted):改用清單裡的號碼重跑 Set-TcNcAxisParameter'
$script:TcErrorHints['NC_AXIS_PARAM_NOT_FOUND'] = '這支軸的 ProduceXml 沒有這個欄位(data.missingFields),什麼都沒寫:用 Get-TcTreeItemXml -Path <data.axisPath> 確認 NcAxisDef 的結構'
$script:TcErrorHints['NC_AXIS_PARAM_WRITE_FAILED'] = 'ConsumeXml 被 XAE 拒絕:用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcTreeItemXml -Path <data.axisPath> 確認目前值後重跑;data.backupPath 是寫入前的 XML'
$script:TcErrorHints['NC_AXIS_PARAM_VERIFY_FAILED'] = '讀回值和要寫的不同(data.mismatches):不要當成功。用 Get-TcTreeItemXml -Path <data.axisPath> 看實際值;要還原就用 data.backupPath 的值再 Set-TcNcAxisParameter(先 dry-run)'
$script:TcErrorHints['NC_PLC_VARIABLE_NOT_FOUND'] = 'PLC 端找不到 AXIS_REF 的 NcToPlc / PlcToNc:確認 -PlcVariable 是 AXIS_REF 變數(例如 MAIN.axis),先 Build-TcProject 讓它出現在 <task> Inputs / Outputs 底下，再重跑 Connect-TcNcAxisToPlc'
# Phase 3 task 4.2: TcCOM (Add-TcComModule / Get-, Set-TcComModuleParameter / Set-TcComModuleContext)
$script:TcErrorHints['TCCOM_MODULE_ALREADY_EXISTS'] = '已有同名的 TcCOM 實例(data.existingModules;XAE 會自動改名成 _ObjN,模組先擋):換一個 -Name 重跑 Add-TcComModule,或直接用現有的實例'
$script:TcErrorHints['TCCOM_CLASS_NOT_FOUND'] = 'XAE 找不到這個 TcCOM class(0x98510009):確認 GUID / 型別名稱和 TMC 一致，且 module 放在 CustomConfig\Modules 或 TcModuleFolders.xml 列出的資料夾，再重跑 Add-TcComModule'
$script:TcErrorHints['TCCOM_VERIFY_FAILED'] = '建立後讀回的 class / 型別不符(data.mismatches):看 data.rolledBack;false 時用 Remove-TcTreeItem -Path <data.createdPath> -ConfirmName <data.createdName> -DryRun $false 刪掉再重跑'
$script:TcErrorHints['TCCOM_MODULE_NOT_FOUND'] = '找不到這個 TcCOM 實例:用 data.modules 的名稱，或 Get-TcTreeItem -Path ''TIRC^TcCOM Objects'' 查到的完整 tree path 當 -Module 重跑'
$script:TcErrorHints['TCCOM_PARAM_NOT_FOUND'] = '這個 module 沒有這個參數(data.parameters 列出名稱與 id):先 Get-TcComModuleParameter -Module <module> 看清單，再用正確的 -Name / -ParameterId 重跑'
$script:TcErrorHints['TCCOM_PARAM_INVALID_VALUE'] = '值不符合參數型別或範圍(什麼都沒寫):數字用 . 當小數點、BOOL 用 true / false、STRING 不能超過長度，改正後重跑'
$script:TcErrorHints['TCCOM_PARAM_UNSUPPORTED_TYPE'] = '這個參數的型別(data.paramType,message 有型別名稱與大小)不在可寫入的清單裡(BOOL、整數型別、REAL / LREAL、STRING(n)、TIME、module DataTypes 確認是 enum 的型別),例如 struct / array、LTIME / DATE 等沒支援的型別。用 Get-TcComModuleParameter 讀 rawHex;要改值請在 XAE 裡設定，或改寫它的成員參數(若 TMC 有獨立的成員參數)'
$script:TcErrorHints['TCCOM_PARAM_SIZE_MISMATCH'] = '送出的大小和參數大小不同(ADS_E_INVALIDSIZE 0x98110705):用 Get-TcComModuleParameter 看 bitSize / paramType,確認型別後重跑'
$script:TcErrorHints['TCCOM_PARAM_READ_FAILED'] = '讀參數失敗:用 Get-TcIdeModalDialog 檢查 dialog,再重跑 Get-TcComModuleParameter;-Online 時先確認 Get-TcSystemState 是 Run'
$script:TcErrorHints['TCCOM_PARAM_WRITE_FAILED'] = '寫參數被拒絕:用 Get-TcIdeModalDialog 檢查 dialog,Get-TcComModuleParameter 確認目前值後重跑;data.backupPath 是寫入前的備份'
$script:TcErrorHints['TCCOM_PARAM_VERIFY_FAILED'] = '寫入有返回但讀回的 bytes 不同(data.readbackHex / plannedHex):不要當成功。用 Get-TcComModuleParameter 確認，要還原就把 data.previousHex 對應的值再寫一次(先 dry-run)'
$script:TcErrorHints['TCCOM_OBJECT_NOT_FOUND'] = 'target 上沒有這個 object(0x9811071D):先 Enable-TcConfig -Force 讓組態 Activate 並 Run,再重跑 -Online'
$script:TcErrorHints['TCCOM_ONLINE_CONFIG_MISMATCH'] = 'target 上跑的不確定是這個專案的組態(data.bootPackage),什麼都沒寫:先 Build-TcProject、Enable-TcConfig -Force 讓組態一致，再重跑 Set-TcComModuleParameter -Online;遠端 target 無法比對，不支援 -Online 寫入'
$script:TcErrorHints['TCCOM_CONTEXT_INVALID'] = 'context id 或 task 不合法(data.contextIds 是 TMC 的 Context Id,不是 0;task 要是 TIRT / TINC 底下的 task):用 data.contextIds 其中一個當 -ContextId、Get-TcTreeItem 確認 -Task 後重跑'
$script:TcErrorHints['TCCOM_CONTEXT_WRITE_FAILED'] = 'SetModuleContext 被拒絕:用 Get-TcIdeModalDialog 檢查 dialog,再重跑 Set-TcComModuleContext;data.backupPath 是寫入前的備份'
$script:TcErrorHints['TCCOM_CONTEXT_VERIFY_FAILED'] = 'SetModuleContext 有返回但讀回的 task oid 不同(data.readbackOidHex):不要當成功。用 Get-TcTreeItemXml 看 module 的 Contexts,再重跑'
# Phase 3 task 4.3: project variants (Get-TcProjectVariants / Set-TcProjectVariantConfig / Set-TcCurrentVariant / Enable-TcConfig)
$script:TcErrorHints['VARIANT_NOT_SUPPORTED'] = '這個 XAE 讀不到 ITcSysManager14 的 variant 屬性(4024.71 / 4026.22 實測可以):更新 XAE 到 4024 以上，或在 XAE 的 Project Variants 工具列手動操作'
$script:TcErrorHints['VARIANT_CONFIG_INVALID'] = 'ProjectVariantConfig 不是 <ProjectVariants> 文件，或 XAE 拒絕新的文件(E_FAIL,原值不變):用 Get-TcProjectVariants 看 data.configXml,改正後再用 Set-TcProjectVariantConfig(先 dry-run)'
$script:TcErrorHints['VARIANT_ALREADY_EXISTS'] = '已有同名(不分大小寫)的 variant:換名稱重跑 Set-TcProjectVariantConfig -AddVariant <新名稱>'
$script:TcErrorHints['VARIANT_NOT_FOUND'] = 'variant / group 名稱不存在(大小寫要完全一樣，group 寫成 [Group1]):用 Get-TcProjectVariants 看 data.variants / data.groups,再用正確名稱重跑'
$script:TcErrorHints['VARIANT_IS_CURRENT'] = '要移除的是目前的 variant(或目前 group 會沒有成員):先 Set-TcCurrentVariant -Name <另一個 variant> -DryRun $false,再重跑 Set-TcProjectVariantConfig'
$script:TcErrorHints['VARIANT_VERIFY_FAILED'] = '寫入後讀回的 variant / group 和預期不同(data.readback vs data.after):不要當成功。用 Get-TcProjectVariants 確認;要還原就用 data.backupPath 的內容'
$script:TcErrorHints['VARIANT_SWITCH_FAILED'] = '切換後讀回的 CurrentProjectVariant 不同(data.current):用 Get-TcProjectVariants 確認，再重跑 Set-TcCurrentVariant'
$script:TcErrorHints['VARIANT_READ_FAILED'] = 'CurrentProjectVariant 讀取失敗(不是「沒有 variant」),什麼都沒做:用 Get-TcIdeModalDialog 檢查 dialog,Get-TcProjectVariants 確認讀得到，再重跑'
$script:TcErrorHints['VARIANT_GROUP_ACTIVE'] = '目前選的是 variant group,group 不能 Activate:先 Set-TcCurrentVariant -Name <variant> -DryRun $false,再 Build-TcProject,然後重跑 Enable-TcConfig'
# Phase 3 task 4.4: independent project file (Set-TcIndependentFile)
$script:TcErrorHints['INDEPENDENT_FILE_UNSUPPORTED'] = '這個節點不能獨立存檔(XAE 回 S_OK 但讀回不變;實測 PlcTask、Axes、TINC、TIRR 都是):改用它的上層或下層節點，例如 PLC project TIPC^<Plc>、NC 軸、NC task、TcCOM 實例'
$script:TcErrorHints['INDEPENDENT_FILE_WRITE_FAILED'] = 'SaveInOwnFile 被拒絕:用 Get-TcIdeModalDialog 檢查 dialog,再重跑 Set-TcIndependentFile;data.backupPath / backupFiles 是改之前的備份'
$script:TcErrorHints['INDEPENDENT_FILE_SAVE_FAILED'] = '設定已改但專案沒存成(改動還在 XAE 記憶體):用 Get-TcIdeModalDialog 檢查 dialog、確認 .tsproj 不是唯讀，再重跑 Set-TcIndependentFile 同樣的參數(會再存一次)'
$script:TcErrorHints['INDEPENDENT_FILE_TSPROJ_AMBIGUOUS'] = '模組決定不了改完要存哪個 .tsproj(依序看 DTE 載入的專案、.sln 參照的 .tsproj、solution 資料夾底下的 .tsproj;data.tsprojSource 是做決定的來源,data.tsprojFiles 是它列出的檔案),什麼都沒改。tsprojSource = dte / sln:solution 真的有多個 TwinCAT 專案，在 XAE 手動勾 Independent Project File;folder(DTE 與 .sln 都沒給):先 Connect-TcIde 連上開著這個 solution 的 IDE 再重跑 Set-TcIndependentFile,或把多餘的 .tsproj 移出 solution 資料夾'
$script:TcErrorHints['INDEPENDENT_FILE_VERIFY_FAILED'] = '讀回值對了但磁碟上的 .xti 不符(data.createdFiles / removedFiles / expectedFile):不要當成功。看 solution 資料夾的 _Config 目錄;要還原就從 data.backupFiles 複製回去再 Reset-TcSolution'
# Phase 3 task 4.5: ADS routes (Get-TcAdsRoutes / Find-TcAdsTarget / Add-TcAdsRoute)
$script:TcErrorHints['ROUTE_READ_FAILED'] = 'TIRR 的 ProduceXml 讀不到 RoutePrj:用 Get-TcIdeModalDialog 檢查 dialog,Get-TcTreeItem -Path TIRR 確認節點後重跑'
$script:TcErrorHints['ROUTE_SEARCH_REQUIRES_LOCAL_TARGET'] = 'XAE 只能從本機系統搜尋(實測 target = UmRT 也不行):先 Set-TcTarget -AmsNetId <本機 system 的 AmsNetId(data.localNetId)> -NoPlatformSwitch,再 Find-TcAdsTarget,做完再 Set-TcTarget 回原本的 target(data.target)'
$script:TcErrorHints['ROUTE_SEARCH_FAILED'] = '搜尋被 XAE 拒絕:用 Get-TcIdeModalDialog 檢查 dialog,確認 -Search 是 IPv4 或 host name 後重跑 Find-TcAdsTarget'
$script:TcErrorHints['ROUTE_ALREADY_EXISTS'] = '已經有到這個 NetId 的 route(data.existingRoutes):用 Get-TcAdsRoutes 確認，不需要再加'
$script:TcErrorHints['ROUTE_PASSWORD_MISSING'] = '先在執行模組的行程設定環境變數(MCP:在 client 設定的 server env 加),變數名稱一定要是 TCAUTO_ROUTE_PW 或 TCAUTO_ROUTE_PW_<後綴>(只讀 Process scope),再用 Add-TcAdsRoute -PasswordEnv TCAUTO_ROUTE_PW 重跑;不要把密碼當參數值傳'
$script:TcErrorHints['ROUTE_ADD_FAILED'] = 'AddRoute / AddProjectRoute 被 XAE 拒絕(訊息已去掉密碼與 XML):確認遠端 IP / NetId / 帳號，用 Get-TcIdeModalDialog 檢查 dialog,再用 Get-TcAdsRoutes 看目前的 route'
$script:TcErrorHints['ROUTE_VERIFY_FAILED'] = '指令有返回但 TIRR 讀回沒有這條 route:不要當成功。用 Get-TcAdsRoutes 看 data.target 的 route 表(TIRR 只顯示目前 target 的),必要時 Set-TcTarget 切到另一端再看'
# #68: fail-closed guard after a runtime-changing request whose readback did not reach the target state
# Stop instruction put in front of the hint of a result that just recorded a block (Add-TcLifecycleBlockResult);
# {target} = the AmsNetId. Not an error code (no troubleshooting heading needed).
$script:TcLifecycleStopPrefix = '已記錄 LIFECYCLE_BLOCKED'
$script:TcLifecycleStopMarker = '給使用者的診斷:'
# Side findings 3 / 4: replaces the hint of ADS_TARGET_NOT_FOUND / ADS_PORT_NOT_FOUND / NOT_CONNECTED ...
# while the target has a lifecycle block (New-TcResult, Get-TcLifecycleBlockAdvice). The usual hint
# follows after the marker, flagged as not to be followed.
$script:TcLifecycleReadOnlyPrefix = '此 target 有 LIFECYCLE_BLOCKED'
$script:TcLifecycleReadOnlyMarker = '原本的建議(使用者同意並 Clear 之前不要照做):'
$script:TcLifecycleReadOnlyText = '此 target 有 LIFECYCLE_BLOCKED(data.lifecycleBlock):不要依一般建議去 Set-TcSystemState、Enter-TcPlcOnline、Set-TcPlcState、Enable-TcConfig(都會被拒絕),也不要改用其他控制通道(raw ADS、COM、DTE、GUI、console)。把這個錯誤和 data.lifecycleBlock 回報使用者，只做唯讀診斷;使用者同意後才 Clear-TcLifecycleBlock -Reason ''<理由>'' -FallbackMethod ''<繼續的方法>'' -AllowedSideEffects ''<允許的副作用>'' -MaxVerifyLevel <驗證層級>。原本的建議(使用者同意並 Clear 之前不要照做):'
# S-1: appended (hint kept) when the failing call's target is unknown but some target is blocked.
$script:TcLifecycleOtherBlockNote = '(#68:另有 target 存在 lifecycle block;要對某個 target 做會改 runtime 的動作前，先確認它沒有 block。Clear-TcLifecycleBlock 只在使用者同意後呼叫，見 docs/troubleshooting.md「LIFECYCLE_BLOCKED」)'
$script:TcLifecycleStopText = '已記錄 LIFECYCLE_BLOCKED({target},data.lifecycleBlock):在這裡停止，其餘步驟標示 NOT RUN,把這個結果回報使用者。使用者同意並呼叫 Clear-TcLifecycleBlock(-Reason、-FallbackMethod、-AllowedSideEffects、-MaxVerifyLevel 都必填)之前，所有會改 runtime 的命令都會被拒絕;不要改用其他控制通道(raw ADS、COM、DTE、GUI、console)。給使用者的診斷:'
$script:TcErrorHints['LIFECYCLE_BLOCKED'] = '停止後續所有步驟(標示 NOT RUN),把 data.lifecycleBlock(command、errorCode、requestedState、reachedState、message、time)原樣回報給使用者，只做唯讀診斷(Get-TcSystemState、Get-TcPlcState、Get-TcIdeModalDialog、Get-TcBuildErrors)。不要自行改用其他控制通道:直接用 TcAdsClient 寫 ADS 狀態、COM/DTE 重啟或 TwinCAT 指令、GUI 點擊、TcSystemServiceUm console、改 Platform/Target/Route。使用者確認並同意後才呼叫 Clear-TcLifecycleBlock -Reason ''<使用者的理由>'' -FallbackMethod ''<使用者核准的繼續方法>'' -AllowedSideEffects ''<允許的副作用>''[,...] -MaxVerifyLevel None|SystemState|PlcState|VariableRead|TestObserved(四個都必填，照使用者的話填，不要自己編;預設目前 target,-AmsNetId 指定其他 target),再照核准的方法從頭重跑 lifecycle。見 docs/troubleshooting.md「LIFECYCLE_BLOCKED」'
# #113: Clear-TcLifecycleBlock without a complete structured receipt (nothing removed)
# #130 F1: appended to the hint when none of the three #113 fields was passed at all (data.possibleStaleSchema)
$script:TcLifecycleStaleSchemaText = '若透過 MCP 呼叫，可能是 server 的 tool schema 比模組舊(server 啟動於 #113 之前，送不出 FallbackMethod / AllowedSideEffects / MaxVerifyLevel);請重啟 MCP server(開新 session)再 Clear。不要只用 Reason 繞過。'
$script:TcErrorHints['LIFECYCLE_RECEIPT_INCOMPLETE'] = 'Clear-TcLifecycleBlock 沒有執行,block 還在(data.missing 是缺或空白的欄位,data.invalid 是不合法的值)。先問使用者，照使用者的話補齊四個欄位再呼叫一次:-Reason(為什麼可以解除)、-FallbackMethod(解除後用什麼方法繼續)、-AllowedSideEffects(允許的副作用，每項一個字串;都不允許時只給 none,不能和其他項並列)、-MaxVerifyLevel(清除後這次驗證會做到的最高層;結果不得宣稱超過它。data.allowedVerifyLevels 之一:None / SystemState / PlcState / VariableRead / TestObserved)。不要自己編內容。見 docs/troubleshooting.md「LIFECYCLE_RECEIPT_INCOMPLETE」'
# #72: Connect-TcIde without -ProgId never launches the first registered IDE any more
$script:TcErrorHints['PROGID_REQUIRED'] = 'Connect-TcIde 沒有啟動 IDE:沒給 -ProgId,而且無法確定該用哪個 IDE(data.solutionVersion.reason:沒給 -SolutionPath、某個 .tsproj 讀不到 TcVersion、多個 .tsproj 版本不同，或沒有任何 IDE 的 XAE 版本與 TcVersion 完全相等(含 revision;XAE 版本讀不到也算)),機器上又註冊了多個 IDE(data.registeredProgIds)。帶 -ProgId 重跑:4024 → TcXaeShell.DTE.15.0;4026 → TcXaeShell.DTE.17.0(TcXaeShell64)或 VisualStudio.DTE.17.0(VS2022)'
$script:TcErrorHints['IDE_VERSION_NOT_REGISTERED'] = 'Connect-TcIde 沒有啟動 IDE:.tsproj 的 TcVersion(data.solutionVersion.tsprojects)對應的 IDE 沒有註冊，或沒有確認到裝了 TwinCAT XAE 整合(data.registeredProgIds)。用別的版本的 XAE 開，專案可能被改寫 / 降版(#72),所以不會用猜的。確定要用某個 IDE 時帶 -ProgId 重跑;否則先安裝對應 build 的 XAE'
# #214: Get-TcProjectVersion (reads files only, no IDE)
$script:TcErrorHints['SOLUTION_NOT_FOUND'] = 'Get-TcProjectVersion 找不到這個 .sln(或路徑不是檔案):確認 -SolutionPath 是 .sln 的完整路徑(可用相對路徑,從目前工作目錄解析),再重跑;這個 cmdlet 只讀檔,不需要 IDE'
$script:TcErrorHints['TSPROJ_NOT_FOUND'] = '這個 .sln 沒有引用任何 TwinCAT 專案(.tsproj;只看 Project(...) 行裡的 .tsproj 路徑),所以沒有 TcVersion 可讀:確認 -SolutionPath 指到 TwinCAT 的 .sln,不是 PLC 專案或其他 solution'
$script:TcErrorHints['TCVERSION_UNKNOWN'] = '至少一個被引用的 .tsproj 讀不到 TcVersion(data.projects[].error 是原因,依它處理):file not found -> .sln 的 Project(...) 引用路徑不對或檔案被移走,修正 .sln 裡的引用;unreadable -> .tsproj 不是合法 XML(壞掉或被截斷),從版控還原;no TcVersion attribute on the root element 或 TcVersion 不是 3.1.<build>.<revision> -> 不要猜版本,也不要期待存檔會補上(這個行為沒有 InfoSys 說明也沒實測過);要用專案原本 build 的 XAE 開啟(#72)。在那之前 Connect-TcIde 要帶 -ProgId,先問使用者'
$script:TcProjectVersionLaunchHint = 'data.launch.errorCode 有值:代表 Connect-TcIde 不帶 -ProgId 時會回這個錯誤碼(TWINCAT_NOT_FOUND / IDE_VERSION_NOT_REGISTERED / PROGID_REQUIRED),這次沒有啟動任何東西。要指定 -ProgId,請比對 data.launch.wantedProgIds(建議的 ProgId)、data.launch.ide[].xaeVersion(每個已註冊 IDE 的 XAE 版本)與 data.projects[].tcVersion;用別的版本開啟專案可能升級或降級專案,選 ProgId 前先問使用者(#72),不要自己挑一個就呼叫 ConnectIde'
# #136: never a second IDE for a solution this session is still launching
$script:TcErrorHints['IDE_LAUNCH_PENDING'] = '本 session 已為這個 .sln 啟動過 IDE(pid <pid>),它可能還活著，所以沒有再開第二個。data.probe:not-in-rot / busy / unreadable / scan-incomplete = 還在啟動或被擋住(-NoLaunch 時也最多等 60 s);pid-unconfirmed = pid 無法確認，沒有 attach 也不算本 session 擁有;progid-mismatch = 它是用別的 ProgId 啟動的(data.progIdMismatch);other-session = 別的 TcAuto session 啟動的(data.otherSession):hostState = alive 是另一個仍在執行的 bridge;hostState = gone 只代表啟動它的 bridge 不在了，不代表那個 session 已結束，要看 data.otherSession.ownerState:gone 或 none = 那個 session 已結束(使用者確認沒人在用那個 IDE 後才能接管，做法見本 hint 開頭);alive 或 unverifiable = 那個 session 只是 bridge 重開過，可能還在用，不要接管。不 attach、不算本 session 擁有，也不能 -Kill。alive 而 data.otherSession.hostPid 是 powershell.exe、它所屬的 MCP server 已經不在(孤兒 bridge):請使用者確認後結束那個行程，再重跑 Connect-TcIde;hostState = gone 而 ownerState 是 alive / unverifiable，或那個 session 還在用：請使用者確認那個 IDE(pid <pid>)不再需要後自己關掉，再重跑 Connect-TcIde。Get-TcIdeModalDialog -ProcessId <pid> 看有沒有 dialog,關掉後重跑同一個 Connect-TcIde;還在啟動就稍後重跑。要換 ProgId 或 IDE 卡死:data.ownedBySession = true 時 Disconnect-TcIde -Quit -Kill(只殺這個 pid)後再 Connect-TcIde;pid-unconfirmed 時模組不殺任何行程：自己確認並關掉那個 IDE(或確定它已不在),再 Disconnect-TcIde -ForgetPendingLaunch(MCP:DisconnectIde ForgetPendingLaunch=true)清掉這筆啟動紀錄，然後重跑 Connect-TcIde'
$script:TcErrorHints['LAUNCH_RECORD_UNAVAILABLE'] = '啟動紀錄檔(<TCAUTO_STATE_DIR 或 %TEMP%\TwinCATAutomation>\launched-ides.json)讀不到或寫不進去(data.launchRecordWarning)。可能原因：鎖被另一個 TcAuto 行程佔用(等待上限 2 s)、權限不足、檔案被其他程式開著。Disconnect-TcIde -ForgetPendingLaunch:模組記憶體裡的紀錄已清掉，稍後重跑同一個指令。Connect-TcIde -TakeOverOrphan:沒有 attach、沒有接管(fail closed),稍後重跑同一個 Connect-TcIde -TakeOverOrphan。不要手動刪改這個檔案。'
# #196: Connect-TcIde -TakeOverOrphan refused
$script:TcErrorHints['ORPHAN_TAKEOVER_REFUSED'] = 'Connect-TcIde -TakeOverOrphan 沒有接管，也沒有 attach 或改任何紀錄。看 data.reason:solution-path-required = 要帶 -SolutionPath;no-launch-record = 沒有還活著的 IDE 的啟動紀錄是這個 .sln,不帶 -TakeOverOrphan 重跑 Connect-TcIde;owned-by-this-session = 本 session 自己啟動的，不帶 -TakeOverOrphan 重跑即可;host-alive = 啟動它的 TcAuto session 還在(data.otherSession.hostPid),不能接管，請使用者處理那個 session(見 IDE_LAUNCH_PENDING);owner-alive = 啟動它的 bridge 不在了，但它的 MCP server(data.otherSession.ownerPid)還在執行(bridge 重開過：BRIDGE_TIMEOUT / IDE_MODAL_DIALOG / ReloadModule),那個 session 仍擁有這個 IDE,不能接管;owner-unverifiable = 無法確認那個 MCP server 是否已結束(舊格式紀錄沒有 ownerPid,或讀不到它的 StartTime),不能接管：請使用者確認那個 session 已關閉、IDE 不再需要後自己關掉 IDE,再重跑 Connect-TcIde;pid-unconfirmed = pid 沒確認過，模組認不出是哪個 IDE:使用者自己關掉它後 Disconnect-TcIde -ForgetPendingLaunch;progid-mismatch = 拿掉 -ProgId 或給啟動時的 ProgId;not-in-rot / solution-mismatch / ide-busy = ROT 裡沒有那個 pid 開著這個 .sln 且可回應的 DTE:等它載入完或關掉 dialog(Get-TcIdeModalDialog -ProcessId <data.ideProcessId>)後重跑;record-changed / host-not-gone = 寫入時紀錄被別人改了(owner-alive / owner-unverifiable 也可能在寫入時才出現，處理同上)，重跑同一個 Connect-TcIde 看最新狀態;host-start-time-unreadable / owner-start-time-unreadable = 讀不到本行程(或本 MCP server 行程)的 StartTime,無法記錄新擁有者，重跑一次，還是失敗就回報。data.resetRequired 存在 = 這個 .sln 的 reload 提示已經被答成「不重新載入」(這次或之前的接管),模組已記下 reset-required:重跑接管成功後要先 Reset-TcSolution,Build / Enable / Login / 存專案檔才會放行(RESET_REQUIRED);data.reloadPromptAttempts 只是這次每一次嘗試的紀錄(含 sent = false 沒送出的),不能拿來判斷是否答過。不要手動改 launched-ides.json,也不要繞去 Stop-Process。'
# #201: Connect-TcIde -TakeOverOrphan stopped at a dialog: NOTHING is attached, so Reset-TcSolution /
# Disconnect-TcIde (the IDE_MODAL_DIALOG / _RELOAD next steps) answer NOT_CONNECTED - never point there
$script:TcErrorHints['IDE_MODAL_DIALOG_ORPHAN'] = 'Connect-TcIde -TakeOverOrphan 沒有接管，也沒有 attach(data.attached = false),所以 Reset-TcSolution、Disconnect-TcIde、Get-TcIdeInfo 都會回 NOT_CONNECTED,不要接著呼叫它們。模組只在這些條件都成立時才回答已知的 reload 提示(kind = reload-prompt,一律「不重新載入」:solution → 忽略 1412,project → No,file → WM_CLOSE):有 -SolutionPath、那個 .sln 有啟動紀錄、host 與 owner 行程都已結束、pid 已確認、-ProgId 相符、ROT 有那個 pid 的 DTE,而且 DTE 讀得到時開的就是這個 .sln,讀不到時 dialog 內文的路徑要全在 solution 資料夾裡，或內文沒有任何磁碟路徑但有加引號的 ''<solution 名稱>''。接管流程 attach 之後的 dialog 檢查也回這個 hint(attach 已釋放)。走到這裡代表：(a) kind = reload-prompt 但回答後提示還在(data.reloadPromptAttempts 看原因;solution 提示 Ignore 失敗不會改用 WM_CLOSE)或連續超過 5 個 → 請使用者在 XAE 按 Ignore / No 或關掉那個 IDE(pid 見 data.ideProcessId);(b) kind = reload-prompt 但 DTE 讀不到、dialog 內文又沒有這個 solution 的證據(data.reason = modal-dialog,data.reloadPromptAttempts 不存在)→ 模組沒按任何按鈕，請使用者確認那個 IDE 開的是這個 .sln 後在 XAE 處理;(c) 其他 dialog(kind = unknown,例如 license、Assertion Failed)→ 模組不會自動按，請使用者在 XAE 手動處理(license / security code 視窗一律由使用者處理)。處理完 Get-TcIdeModalDialog -ProcessId <data.ideProcessId>(MCP:GetIdeModalDialog ProcessId=<data.ideProcessId>)確認沒有 dialog,再重跑同一個 Connect-TcIde -TakeOverOrphan。data.resetRequired 存在 = 這個 .sln 的提示已經被答成「不重新載入」(這次或之前的接管),模組已記下 reset-required:接管成功後先 Reset-TcSolution 再 Build-TcProject(之前 Build / Enable / Login / 存專案檔會回 RESET_REQUIRED);data.reloadPromptAttempts 只是這次每一次嘗試的紀錄(含 sent = false 沒送出的),不能拿來判斷是否答過。不要 Stop-Process 那個 IDE:它還不屬於本 session。'
# #201: TakeOverOrphan answered a reload prompt 'do not reload': building / downloading the old in-memory solution is refused
$script:TcErrorHints['RESET_REQUIRED'] = 'Connect-TcIde -TakeOverOrphan 把孤兒 IDE 的 reload 提示答成「不重新載入」(data.resetRequired.reason),IDE 記憶體裡還是舊的 solution,磁碟上的檔案已經被改過。Build 會編譯、Activate / Login 會下載這份舊內容;Project.Save 會把記憶體裡舊的 .tsproj / .plcproj 寫回磁碟、蓋掉磁碟上的改動。所以 Build-TcProject、Enable-TcConfig、Enter-TcPlcOnline / Send-TcPlcProgram、New-TcBootProject、Save-TcPlcLibrary,以及會存專案檔的 Add-TcPou / Add-TcDut / Add-TcGvl / Add-TcInterface / Add-TcLibrary / Add-TcLibraryPlaceholder / Add-TcPlcTask / Import-TcPlcOpen / Lock-TcLibraryPlaceholder / Remove-TcLibraryReference / Set-TcIndependentFile(-DryRun $true 除外)都會在改動 XAE 之前拒絕。紀錄以 .sln 為 key,不分 IDE pid。下一步:Reset-TcSolution(MCP:ResetSolution)從磁碟重新開啟 solution:不能帶 -SaveProjectChanges(會回 PROJECT_UNSAVED_CHANGES 拒絕存檔);IDE 有未存的編輯器文件或讀不到文件狀態時它回 PROJECT_UNSAVED_CHANGES(data.dirtyDocuments / dirtyDocumentsError,什麼都沒關),請使用者先在 XAE 看過，確定要丟掉才 -DiscardProjectChanges。成功後這個標記自動清除，再 Build-TcProject。data.resetRequired.stateUnreadable = true = build-required.json 讀不到或損毀(fail closed):被其他行程鎖住就稍後重試;有 <corrupt> 項目照 docs/troubleshooting.md「BUILD_REQUIRED」處理。不再需要這個 IDE 就 Disconnect-TcIde -Quit(標記留著，下次開同一個 .sln 時一樣先 Reset-TcSolution)。除了 <corrupt> 的處理，不要手動改 build-required.json。'
$script:TcErrorHints['NC_AXIS_ALREADY_LINKED'] = '有一端已經 link 到別處(data.existingLinks):先用 Remove-TcVariableLink 解掉舊的 link,再重跑 Connect-TcNcAxisToPlc'

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
    # Thrown by Invoke-TcProjectSaveWithDeadline while reset-required applies (PR #209 review B1)
    elseif ($text -match '\bRESET_REQUIRED:') {
        $code = 'RESET_REQUIRED'
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
