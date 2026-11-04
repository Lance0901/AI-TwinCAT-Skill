# #110 platformMap 不可靠 真機驗證(commit 1fe1daa)

日期 2026-11-04 07:53–07:59,registered tcauto MCP(`mcp__tcauto__*`)。只驗 SetTarget 輸出，沒有 Activate / EnableConfig。

## 環境

| 項目 | 值 |
|---|---|
| 主 checkout | detached `origin/fix/110-platformmap-unsaved` = `1fe1daa`(驗證後已切回 `origin/master` 3a22080) |
| bridge | 第一次 SetTarget 就有 `platformMapReliable` / `platformMapReason` 欄位(載入的是 1fe1daa) |
| IDE | VS2022 `VisualStudio.DTE.17.0` pid 40756(launched, ownedBySession=true,connectSec 40.1);W5 64-bit XAE Shell `TcXaeShell.DTE.17.0` pid 63804(launched, owned,connectSec 110.7)。兩者都由本 session 啟動、收尾 Quit |
| 副本 | `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,備份 `C:\Temp\Verify-4026-axis.bak-110v`,SHA-256 清單 `C:\Temp\Verify-4026-axis.sha256-110v.txt`(259 檔) |
| Target | 本機 UmRT_Default 199.5.42.250.1.1(TARGETINFO 0x702) |
| UmRT | pid 52892 Run,全程未變、無 crash |
| watcher | pid 90408,`tests/Integration/logs/runtime-watch-110v.jsonl`(323 行，無 event 行),收尾已停 |
| dialog | 全程無 modal dialog(W2 後 `GetIdeModalDialog` dialog null) |

## 總結

| 項目 | 結果 | 摘要 |
|---|---|---|
| W1 基準(已存檔,VS2022) | **PASS** | reliable=true、reason null、9 個 key 都是真 solution platform 名稱(source sln)、availablePlatforms 9、platformMatchedBy solutionPlatform |
| W2 #110 重現 | **PASS** | reliable=false,**reason = unsaved**(`Solution.Saved read back False, so the .sln on disk may differ from the loaded solution; SolutionConfiguration2.PlatformName read back empty`);key `<unknown #9>`~`<unknown #17>`,無 `(#N)`;availablePlatforms `[]`;切換 OS→RT 成功 projectCheck ok;buildSelection 正常 |
| W3 存檔後恢復 | **PASS** | BuildProject 確實寫回 .sln(mtime = Build 開始時刻);之後 SetTarget reliable=true、9 個平台 |
| W4 hint | **未觸發** | 全程沒有 PLATFORM_NOT_FOUND / PLATFORM_PROJECT_MISMATCH,未硬造 |
| W5 XAE Shell 64-bit W1 | **PASS** | reliable=true、reason null、9 個 key、availablePlatforms 9 |

**根因確認**:`ConsumeXml <Disabled>false</Disabled>` 之後 `Solution.Saved = False`(模組讀回的 reason 是 unsaved,不是 anchor-mismatch / sln-mismatch)。troubleshooting「platformMap 不可靠」裡「推論，待真機確認」那句可以改成實測(2026-11-04,VS2022 + 4026,registered tcauto)。「Build 是否存檔未驗證」那句也可改成：BuildProject 會寫回 .sln,之後 SetTarget 回到 reliable=true(實測同上)。

## 每步紀錄(VS2022)

| # | 呼叫 | 結果 | .sln 磁碟 mtime / size |
|---|---|---|---|
| 0 | 開工 | — | 11/01 15:39:21(原始副本) |
| 1 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=<副本>` | launched pid 40756,OS (x64),amsNetId 199.5.42.250.1.1 | — |
| 2 | `SetTarget Platform='TwinCAT OS (x64)'`(**W1**) | reliable true / reason null;9 key(CE7 (ARMV7)、OS (ARMT2)、OS (ARMV7-A)、OS (ARMV7-M)、OS (ARMV8-A)、OS (x64)、OS (x64-E)、RT (x64)、RT (x86)),全部 source sln;availablePlatforms 同 9 個;platformMatchedBy solutionPlatform;platformChanged false;buildSelection AxisInterface changed false | — |
| 3 | `CreateChild TIPC DisabledDemo SubType 0 VInfo "Standard PLC Template.plcproj" DryRun=false` | verified,createdPath TIPC^DisabledDemo | — |
| 4 | `BuildProject` | success,2 PLC built,completeBuild true,10.6 s | 07:54:53 / 15195 |
| 5 | `ConsumeXml TIPC^DisabledDemo <Disabled>true</Disabled>` | verified | — |
| 6 | `BuildProject` | success,DisabledDemo disabled(shouldBuild false),disabledMatchBy path,completeBuild true | 07:55:23 / 15093(少一行 Build.0) |
| 7 | `ConsumeXml <Disabled>false</Disabled>`(不存檔) | verified | 07:55:23 / 15093(未寫) |
| 8 | `SetTarget Platform='TwinCAT RT (x64)'`(**W2**) | 見下 | 07:55:23 / 15093(未寫) |
| 9 | `GetIdeInfo` / `GetIdeModalDialog` | solutionPlatform RT (x64);dialog null。GetIdeInfo **沒有 Solution.Saved 欄位**(無法用 tool 直接讀;Saved=False 是從 platformMapReason 讀到的) | — |
| 10 | `BuildProject`(RT) | success,2 PLC built,completeBuild true,3.0 s | **07:56:01 / 15195**(Build 寫回) |
| 11 | `SetTarget Platform='TwinCAT RT (x64)'`(**W3**) | reliable true / reason null,9 key source sln,availablePlatforms 9,platformMatchedBy solutionPlatform,platformChanged false | — |
| 12 | `SetTarget Platform='TwinCAT OS (x64)'`(切回) | success,platformChanged true,reliable **true**,9 key —— 平台切換本身不會讓 map 變不可靠 | — |
| 13 | `DisconnectIde Quit=true` | quit,pid 40756 | — |

### W2 回傳細節(step 8)
- `success: true`,`platform` / `projectPlatform` = TwinCAT RT (x64),`previousPlatform` OS (x64),`platformChanged: true`,`projectCheck: ok`。
- `platformMapReliable: false`;`platformMapReason: "Solution.Saved read back False, so the .sln on disk may differ from the loaded solution; SolutionConfiguration2.PlatformName read back empty"`。
- `platformMatchedBy: "projectPlatform"`;`availablePlatforms: []`(符合 doc「只列讀得到的，可能是空的」)。
- `platformMap` key:`<unknown #9>`、`<unknown #10>`、`<unknown #11>`、`<unknown #12>`、`<unknown #13>`、`<unknown #14>`、`<unknown #15>`、`<unknown #16>`、`<unknown #17>`(9 個，全部 `solutionPlatform: null`、`solutionPlatformSource: "unknown"`)。**沒有任何 `(#N)` key、也沒有用 project platform 名稱當 key**。各項 `projectPlatform` = 第一個 context(.tsproj)的 project platform,例 #9 / #10 / #17 都是 RT (x86)、#16 是 RT (x64)。
- `buildSelection`:AxisInterface / DisabledDemo 都是 current {OS (x64), shouldBuild true, disabled false} → target true → after {true, false},changed false;`buildSelectionChanges: []`(#67 行為正常)。

## W5(64-bit XAE Shell)
- 副本先從備份 robocopy /MIR 還原(乾淨基準，沒有 DisabledDemo)。
- `ConnectIde ProgId=TcXaeShell.DTE.17.0` → launched pid 63804,OS (x64),110.7 s。
- `SetTarget Platform='TwinCAT OS (x64)'` → reliable true、reason null、9 key、availablePlatforms 9、platformMatchedBy solutionPlatform、buildSelection AxisInterface changed false。
- `DisconnectIde Quit=true` → quit。

## 旁支發現(只記錄，未處理)
1. **XAE Shell 的 `solutionPlatformSource` 也是 `sln`**:troubleshooting 說「TcXaeShell 讀得到 `PlatformName`,不受影響」,但 W5 的 9 項 source 都是 `sln`,不是代表 PlatformName 的來源值。可能是模組一律先用 .sln、或 source 標示方式不同；沒讀 code,不確定。若 doc 的意思是 XAE Shell 走 PlatformName,這裡值得對一下。
2. GetIdeInfo 不回 `Solution.Saved`;要直接觀察只能靠 SetTarget 的 platformMapReason。若之後需要，可考慮在 GetIdeInfo 加 `solutionSaved`(建議，未開 issue)。
3. issue 舊觀察仍在：DisabledDemo.plcproj 在 solution platform `TwinCAT OS (ARMT2)` 下對到 project platform `TwinCAT OS (ARMV7-M)`(W3 map),是 CreateChild 範本寫的 .sln,無影響。

## 收尾
- `SetTarget` 回到 `TwinCAT OS (x64)`(step 12;W5 也是 OS (x64))。兩個 IDE 都 `DisconnectIde Quit=true`,收尾後無 devenv / TcXaeShell 行程。
- 副本 robocopy /MIR 從備份還原,SHA-256 diff 0(259/259)。備份保留。
- watcher 90408 已停，無 event 行;UmRT pid 52892 仍在。
- 主 checkout `git fetch` + `git checkout --detach origin/master` → 3a22080。
- 沒有 commit、沒改 code、沒動 ADS route / library repository。
