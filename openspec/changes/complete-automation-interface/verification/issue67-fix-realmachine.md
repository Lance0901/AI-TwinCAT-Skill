# #67 修正真機驗證(fix/67-build-selection-on-platform-switch `2dae858`)

> 實測 2026-11-03 22:06–22:13,本機 UmRT_Default(`199.5.42.250.1.1`,`TcSystemServiceUm.exe` 3.1.0.2649,pid 87120),registered tcauto MCP(bridge 本 session 首次呼叫時載入 `2dae858`)。

環境
- 主 checkout 開工前 `git log -1` = `2dae858`;收尾 `git fetch` + `git checkout --detach origin/master` → `6b672fe`,status 只有原本的 `?? openspec/changes/add-scope-integration/`
- VS2022 `VisualStudio.DTE.17.0` pid 121392(本 session 啟動,launched,ownedBySession true,48 s),22:06–22:09
- 64-bit XAE Shell `TcXaeShell.DTE.17.0` pid 39012(本 session 啟動,140.5 s),22:09–22:13
- 副本 `C:\Temp\Verify-4026-axis`;備份 `C:\Temp\Verify-4026-axis.bak-67v`,清單 `C:\Temp\Verify-4026-axis.sha256-67v.txt`(266 檔)
- watcher pid 62568,log `tests\Integration\logs\runtime-watch-67v.jsonl`:**0 個 event**(無 crash、無 UmRT 重啟)
- 全程 `GetIdeModalDialog` = null,無任何對話框

## 總結

| 項 | 結論 | 重點 |
|---|---|---|
| V0 | **PASS** | 只有 AxisInterface 時 `BuildProject` completeBuild / codeVerified / coverageComplete 全 true,**沒有 BUILD_COVERAGE_UNKNOWN**(真實 COM 的 ShouldBuild 是 bool) |
| V1 | **PASS** | DisabledDemo 停用後 Build:completeBuild true,disabledProjects [DisabledDemo],status disabled,disabledMatchBy path(#104 沒回歸) |
| V2 | **PASS** | OS 下停用 → `SetTarget Platform='TwinCAT RT (x64)'` 回 `BUILD_SELECTION_CHANGED`,platformChanged false,讀回仍 OS,Disabled 仍 true |
| V3 | **PASS** | #67 Q4b 原始情境:`EnableConfig Force Platform='TwinCAT OS (x64)'` 回 `BUILD_SELECTION_CHANGED`,steps 只有 platform-fix(ok false,1 s),沒有 Build/Activate/Login,平台仍 RT,UmRT Boot 資料夾沒有任何新檔、Run 未中斷 |
| V4 | **PASS** | 兩邊都 enabled → 切 RT success,buildSelection after 讀回 shouldBuild true / disabled false,buildSelectionChanges [] |
| V5 | **PASS** | XAE Shell 重做 V0、V1、V2,結果與 VS2022 相同 |

master `6b672fe` 的 Q4b 結果是 success 並把 DisabledDemo 下載到 852 Run;`2dae858` 在同一情境擋下,什麼都沒做。

## V0–V4(VS2022)

| # | tool call | 回傳摘要 | 判定 |
|---|---|---|---|
| 1 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=<副本>` | success,launched,pid 121392,Release\|TwinCAT OS (x64),amsNetId 199.5.42.250.1.1 | — |
| 2 | `BuildProject`(V0) | success,projects [AxisInterface built shouldBuild true],completeBuild true,codeVerified true,errors 0,warnings 26,10.6 s | V0 PASS |
| 3 | `CreateChild TIPC DisabledDemo SubType 0 VInfo "Standard PLC Template.plcproj" DryRun=false` | success verified,GUID `{652D3D15-193D-43C7-B10A-8F919499239A}`,port 852 | — |
| 4 | `ConsumeXml TIPC^DisabledDemo <Disabled>true</Disabled> DryRun=false` | success verified | — |
| 5 | `BuildProject`(V1) | success,completeBuild true,DisabledDemo status disabled / shouldBuild false / disabled true,disabledProjects [DisabledDemo],skippedProjects [],disabledMatchBy path | V1 PASS |
| 6 | 磁碟 .sln(22:07:47) | DisabledDemo `Release\|TwinCAT RT (x64).Build.0` 有,`Release\|TwinCAT OS (x64).Build.0` 沒有 | — |
| 7 | `SetTarget AmsNetId=199.5.42.250.1.1 Platform='TwinCAT RT (x64)'`(V2) | **BUILD_SELECTION_CHANGED**,「nothing was switched」;platformChanged false,platform OS (x64);buildSelectionChanges = [DisabledDemo current OS shouldBuild false disabled true → target RT shouldBuild true,after null];AxisInterface changed false;platformMap source sln、9 個平台正常 | — |
| 8 | `GetIdeInfo` / `ProduceXml TIPC^DisabledDemo` / `GetIdeModalDialog` | solutionPlatform OS (x64);`<Disabled>true</Disabled>`;dialog null | V2 PASS |
| 9 | Boot 資料夾基準 | 最新檔都是 16:18(上一輪 Q4b 的 Port_851/852);UmRT pid 87120 | — |
| 10 | `ConsumeXml Disabled=false`(OS) | success verified | — |
| 11 | `SetTarget Platform='TwinCAT RT (x64)'`(V4) | **success**,OS→RT,projectCheck ok;buildSelection AxisInterface / DisabledDemo 都是 current true → target true → after {shouldBuild true, disabled false},changed false;buildSelectionChanges [] | V4 PASS |
| 12 | `ConsumeXml Disabled=true`(RT) | success verified | — |
| 13 | `BuildProject` | success,solutionConfiguration Release\|TwinCAT RT (x64),DisabledDemo disabled,completeBuild true | — |
| 14 | 磁碟(22:08:41) | .sln DisabledDemo 只剩 `Release\|TwinCAT OS (x64).Build.0`(RT 沒有);.tsproj `Disabled="true"` — 與上一輪 Q4b #5 相同 | — |
| 15 | `EnableConfig Force=true Platform='TwinCAT OS (x64)' TimeoutSec=180`(V3) | **BUILD_SELECTION_CHANGED**:「Automatic solution platform switch … failed … DisabledDemo shouldBuild false -> true (disabled true) … nothing was switched」。activated false、restarted false、loggedIn false、platformFixed false、restored null、plcs []、bootPackage null;**steps 只有 `platform-fix` ok=false 1017 ms** | — |
| 16 | `GetIdeInfo` / `GetSystemState` / `GetIdeModalDialog` | solutionPlatform 仍 RT (x64);UmRT Run(adsState 5);dialog null | — |
| 17 | UmRT Boot 資料夾、行程 | 21:00 之後**沒有任何新寫入的檔案**(Port_852.* 仍 16:18:38);TcSystemServiceUm pid 87120 未重啟;.tsproj 仍 `Disabled="true"` | V3 PASS |
| 18 | `DisconnectIde Quit=true` | success,pid 121392 結束 | — |

V3 的 852 判定說明:UmRT 上原本就有上一輪 Q4b 下載的 DisabledDemo 852(16:18),所以「852 不存在」無法當判據;改用 Boot 資料夾無新檔 + runtime 未重啟 + steps 沒有 activate/login 判定沒有下載。

## V5(64-bit XAE Shell)

副本先還原(SHA-256 266 檔 diff 0)。

| # | tool call | 回傳摘要 | 判定 |
|---|---|---|---|
| 1 | `ConnectIde ProgId=TcXaeShell.DTE.17.0 SolutionPath=<副本>` | success,launched,pid 39012,140.5 s,Release\|OS (x64) | — |
| 2 | `BuildProject` | success,AxisInterface built,completeBuild true,codeVerified true,27.5 s | V0 PASS |
| 3 | `CreateChild`(同上) | success verified | — |
| 4 | `ConsumeXml Disabled=true` | success verified | — |
| 5 | `BuildProject` | success,DisabledDemo disabled,disabledProjects [DisabledDemo],completeBuild true,disabledMatchBy path | V1 PASS |
| 6 | `SetTarget Platform='TwinCAT RT (x64)'` | **BUILD_SELECTION_CHANGED**,platformChanged false,buildSelectionChanges [DisabledDemo false→true] | — |
| 7 | `GetIdeInfo` / `GetIdeModalDialog` | solutionPlatform 仍 OS (x64);dialog null | V2 PASS |
| 8 | `DisconnectIde Quit=true` | success,pid 39012 結束 | — |

## 旁支發現

1. **platformMap 讀壞再現(上一輪「旁支發現」同一個)**:VS2022 #11(OS 下剛 `ConsumeXml Disabled=false`、.sln 未存檔時的 SetTarget)回 `availablePlatforms` 只有 7 個(少 CE7 (ARMV7)、OS (ARMT2))、platformMap 每項 `solutionPlatform: null` / `solutionPlatformSource: "unknown"`、出現 `"TwinCAT RT (x86) (#10)"`、`"TwinCAT RT (x86) (#17)"` key、`platformMatchedBy: "projectPlatform"`。切換結果與 buildSelection 仍正確。其他 4 次 SetTarget/EnableConfig 的 platformMap 都是 source sln、9 個平台。兩次都發生在「ConsumeXml 改 Disabled 之後、Build 存檔之前」→ 可穩定重現，建議開 issue(若尚未開)。
2. **新 .plcproj 的 project platform 對應怪**:platformMap 中 solution platform `TwinCAT OS (ARMT2)` 下 DisabledDemo.plcproj 對到 `TwinCAT OS (ARMV7-M)`(AxisInterface 對到 RT (x64))。是 XAE CreateChild 範本寫出的 .sln 對應，不影響本次驗證;只記錄。

## 未測

- guard / restore 失敗情境(依 brief 不做)
- BUILD_SELECTION_UNKNOWN 真機路徑(真機難造)

## 收尾

| 動作 | 結果 |
|---|---|
| DisconnectIde Quit=true ×2 | pid 121392、39012 都結束(皆本 session 啟動) |
| 還原副本 | robocopy /MIR 自 `.bak-67v`,`.vs` 補回 Hidden;SHA-256 266 檔 diff 0 |
| watcher | pid 62568 已停,0 event |
| UmRT | Run,pid 87120(16:16 啟動,本輪未重啟),仍跑上一輪 Q4b 下載的 AxisInterface 851 + DisabledDemo 852 |
| 主 checkout | detached `6b672fe`(origin/master),只有 `?? openspec/changes/add-scope-integration/` |
| 保留 | `C:\Temp\Verify-4026-axis.bak-67v`、`C:\Temp\Verify-4026-axis.sha256-67v.txt` 沒刪 |
