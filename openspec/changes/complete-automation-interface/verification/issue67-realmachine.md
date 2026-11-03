# #67 真機重現(master 6b672fe)

環境：實測 2026-11-03,本機 UmRT_Default(`199.5.42.250.1.1`,`TcSystemServiceUm.exe` 3.1.0.2649),registered tcauto MCP。
- VS2022 `VisualStudio.DTE.17.0` pid 74652(本 session 啟動,16:12–16:19)
- 64-bit XAE Shell `TcXaeShell.DTE.17.0` pid 120916(本 session 啟動,16:19–16:22)
- 副本 `C:\Temp\Verify-4026-axis`,備份 `C:\Temp\Verify-4026-axis.bak-67`,清單 `C:\Temp\Verify-4026-axis.sha256-67.txt`(266 檔)
- watcher pid 105968,log `tests\Integration\logs\runtime-watch-67.jsonl`

## 總結

| 題 | 結論 |
|---|---|
| Q1 | .sln 有 Debug/Release × 9 個 solution platform;OS (x64)、RT (x64) 都對到同名 .tsproj project platform。原始只有 1 個 PLC(AxisInterface)+ A10_Scope(不 build) |
| Q2 | XAE Disable PLC 時**只拿掉 active configuration(Release\|OS x64)的 Build.0**;其他 17 個 configuration 的 Build.0 全部保留 |
| Q3 | **#67 重現**:切到 Release\|RT (x64) 後 `Disabled` 讀回 **false**、ShouldBuild true;切回 OS (x64) 又變 true。切換本身不寫磁碟。VS2022 與 XAE Shell 行為相同 |
| Q4 | 錯平台 Build:demo 一起被編，.tsproj 的 `Disabled="true"` 被拿掉寫回磁碟。EnableConfig 不帶 Platform → 正確回 `ACTIVATE_FAILED`(**沒有 false success**,無 modal)。**反向情境(使用者在 RT 停用,platform-fix 切到 OS)→ demo 被 enable、build、download 到 852 並 Run,回 success、無 warning** |
| Q5 | XAE Shell 17.0 重做 Q2/Q3:結果與 VS2022 完全一致 |

**機制(實測，非 InfoSys)**:4026 的 PLC `Disabled` 不是獨立屬性，是「active solution configuration 對該 .plcproj 有沒有 Build.0」的鏡像;.tsproj 的 `Disabled="true"` 只是存檔時依 active configuration 寫出來的。所以「使用者停用的 PLC」實際上只在當時那個 configuration 停用，換 configuration 就回來。

InfoSys 只有 [Setting the TwinCAT target platform](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html) 說明用 SolutionContexts `ShouldBuild` 對個別 sub-project 開關 build(per configuration);**沒找到** Disabled ↔ Build.0 綁定的說明，以上綁定行為標實測。

### 對修法的含意

1. 「Disabled」要以 per-configuration 看：模組切平台(SetTarget -Platform、EnableConfig platform-fix)前，要比對**目標 configuration** 下每個 PLC 的 ShouldBuild 與目前的 Disabled;目標 configuration 會讓目前 disabled 的 PLC 變成 build → 應 fail closed(#67 建議的 `BUILD_SELECTION_CHANGED`,帶 before/after)。資料其實已在 SetTarget 的 `data.platformMap`(每個 platform 的 projectPlatforms[].shouldBuild),目前只用來比 project platform。
2. 只比對 .tsproj `Disabled` 不夠：切換後 XAE 會依新 configuration 改寫它，before/after 必須在切換**前**從 platformMap 預判。
3. EnableConfig 回 success 的那條路(反向情境)是真實危害：使用者沒打算下載的 PLC 被 Activate + Login + Run。`skippedPlcs` 變空、`plcs` 多一個 852,但沒有任何 warning。
4. `ACTIVATE_FAILED` 路徑(錯平台直接 Activate)目前 master 已正確，#67 第 4 點的 false success 沒重現。

## Q1 盤點

| 來源 | 值 |
|---|---|
| .sln SolutionConfigurationPlatforms | Debug/Release × CE7 (ARMV7)、OS (ARMT2)、OS (ARMV7-A)、OS (ARMV7-M)、OS (ARMV8-A)、OS (x64)、OS (x64-E)、RT (x64)、RT (x86) |
| .tsproj `{10112974...}` 對應 | OS (x64)→OS (x64)、RT (x64)→RT (x64)、RT (x86)→RT (x86)、ARMV7-A/M、ARMV8-A、x64-E 同名;**CE7 (ARMV7)、OS (ARMT2) → RT (x86)** |
| AxisInterface `{289ACF00...}` | 全部有 Build.0;OS (ARMT2) → RT (x64) |
| A10_Scope | 全部只有 ActiveCfg(不 build) |
| ConnectIde(VS2022) | `solutionPlatform` TwinCAT OS (x64)、Release、projectPlatform OS (x64)、amsNetId 199.5.42.250.1.1,pid 74652 launched,50 s |
| SetTarget data.platformMap | 與 .sln 一致(Release configuration 下 9 個 platform 的 projectPlatforms + shouldBuild) |

## Q2 做出 disabled PLC(VS2022)

| # | tool call | 結果 |
|---|---|---|
| 1 | `CreateChild Path=TIPC Name=DisabledDemo SubType=0 VInfo="Standard PLC Template.plcproj" DryRun=false` | success,verified,GUID `{821E9EB1-6DF8-4F27-B57C-0859EF44FC1A}`,port 852 |
| 2 | `BuildProject`(基準) | success,兩個都 built / shouldBuild true |
| 3 | `ConsumeXml TIPC^DisabledDemo <Disabled>true</Disabled> DryRun=false` | success,verified |
| 4 | `BuildProject` | success,completeBuild true;DisabledDemo `status=disabled`、`shouldBuild=false`、`disabled=true`,`disabledMatchBy=path` |
| 5 | 磁碟 .sln(16:13:32 寫入)| DisabledDemo **只有 `Release\|TwinCAT OS (x64)` 少了 Build.0**;Build.0 共 17 行(Debug 9 + Release 8,含 `Release\|TwinCAT RT (x64).Build.0`) |
| 6 | 磁碟 .tsproj(16:13:34)| `<Project Disabled="true" GUID="{821E9EB1...}" Name="DisabledDemo" ... AmsPort="852">` |

每個 configuration 下兩個 PLC 的 ShouldBuild(SetTarget `data.platformMap`,Release):AxisInterface 9 個 platform 全 true;DisabledDemo 只有 OS (x64) false,其他 8 個 true。Debug configuration 從 .sln 看:DisabledDemo 9 個全有 Build.0。

## Q3 切平台(VS2022)

| # | tool call | 讀回 |
|---|---|---|
| 1 | `SetTarget AmsNetId=199.5.42.250.1.1 Platform='TwinCAT RT (x64)'` | success,previousPlatform OS (x64) → RT (x64),projectCheck ok;platformMap 中 RT (x64) 的 DisabledDemo shouldBuild **true** |
| 2 | `ProduceXml TIPC^DisabledDemo` | `<Disabled>false</Disabled>`(tree icon 也從灰變綠) |
| 3 | 磁碟 | .sln hash `F016F0757072`、.tsproj `E0343DBC01A1`,mtime 都沒變(切換只在記憶體) |
| 4 | `SetTarget ... Platform='TwinCAT OS (x64)'` | success,RT → OS |
| 5 | `ProduceXml TIPC^DisabledDemo` | `<Disabled>true</Disabled>` |

## Q4 錯平台 Build 與 EnableConfig(VS2022)

| # | tool call | 結果 |
|---|---|---|
| 1 | `SetTarget ... Platform='TwinCAT RT (x64)'` | success |
| 2 | `BuildProject`(不帶 ExpectedProject) | success,completeBuild true,solutionConfiguration `Release\|TwinCAT RT (x64)`;**DisabledDemo `shouldBuild=true`、`status=built`、`disabled=false`**,disabledProjects [] |
| 3 | 磁碟 .tsproj(16:14:41)| `<Project GUID="{821E9EB1...}" Name="DisabledDemo"` — **`Disabled` 屬性被拿掉**;.sln 沒動 |
| 4 | `GetSystemState` | Run |
| 5 | `EnableConfig Force=true TimeoutSec=180` | **RUNTIME_CRASHED**(#21,見下),steps 只有 set-config ok false 55 s |
| 6 | 重啟 UmRT(pid 87120,16:16:22)→ `GetSystemState` | Config |
| 7 | `EnableConfig Force=true TimeoutSec=180`(仍 RT,不帶 Platform) | **ACTIVATE_FAILED**:「XAE reported 1 failed project(s) ('Check config failed!')」;platformCheck skipped(0x702);steps set-config ok → activate ok false;activated false |
| 8 | `GetIdeModalDialog ProcessId=74652` | dialog null |
| 9 | `EnableConfig Force=true TimeoutSec=180 Platform='TwinCAT OS (x64)'` | success:platform-fix RT→OS → platform-fix-build(completeBuild true)→ … → verify 全 ok;plcs [AxisInterface 851 Run],**skippedPlcs [DisabledDemo]**;bootPackage match(`DisabledDemo.tpzip` oneSided,舊檔);.tsproj(16:16:58)`Disabled="true"` 寫回 |

### Q4b 反向情境(#67 原始形狀：使用者在錯平台停用)

| # | tool call | 結果 |
|---|---|---|
| 1 | `ConsumeXml TIPC^DisabledDemo <Disabled>false</Disabled>`(在 OS) | success → OS 加回 Build.0 |
| 2 | `SetTarget ... Platform='TwinCAT RT (x64)'` | success(副作用見「旁支發現」) |
| 3 | `ConsumeXml TIPC^DisabledDemo <Disabled>true</Disabled>`(在 RT) | success → RT 拿掉 Build.0 |
| 4 | `BuildProject` | success,RT 下 DisabledDemo disabled / shouldBuild false |
| 5 | 磁碟 .sln(16:18:10)| `Release\|TwinCAT OS (x64).Build.0` 有、`Release\|TwinCAT RT (x64).Build.0` 沒有;.tsproj `Disabled="true"` |
| 6 | `EnableConfig Force=true TimeoutSec=180 Platform='TwinCAT OS (x64)'` | **success**,message「PLC state port 851 Run, port 852 Run (verified by readback)」。steps:platform-fix RT→OS、platform-fix-build(completeBuild true、warningCodes [])、set-config、activate、boot-package(6 檔含 `Port_852.app`)、set-run、login「AxisInterface:851 … \| DisabledDemo:852 Logged into PLC runtime with program download」、set-plc-run 851/852、verify。**plcs 含 DisabledDemo 852 Run,skippedPlcs []**,沒有 warning |
| 7 | `ProduceXml TIPC^DisabledDemo` | `<Disabled>false</Disabled>` |
| 8 | 磁碟 .tsproj(16:18:29)| `Disabled` 屬性被拿掉 |

→ 使用者停用的 PLC 被模組的 platform-fix 下載並 Run,且回 success。這就是 #67 第 2 點，在 master 6b672fe 仍存在。原 issue 的 Build 失敗是因為 demo 專案本身有錯；這裡 demo 是空範本所以能編過，變成更糟的「靜默下載」。

### #21 crash 簽名(Q4 #5)

| 欄位 | 值 |
|---|---|
| 時間 | Event 1000 16:15:46;watcher 16:15:46.741 `bootdata-empty` 396→0、pid [82512]→[82512,110264];16:15:52 pid → [] |
| Faulting app | TcSystemServiceUm.exe 3.1.0.2649,0x69824f03,pid 0x14250(82512) |
| Module | TcOsSys.dll 3.1.0.1,0x69824839 |
| Exception / offset | 0xc0000005 / 0x0000000000589534(與已知 #21 相同) |
| Report Id | d5fa17bb-f60a-46d2-8b06-8ba260ee23fc |
| Dump | `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.82512.dmp`(2,253,711 bytes) |
| 情境 | set-config 送 Reconfig(16),原狀態 Run;solution platform RT (x64)、2 個 PLC 都 enabled |
| 復原 | 16:16:22 依 brief 重啟(pid 87120),之後無 crash、無 license 視窗 |

## Q5 64-bit XAE Shell(`TcXaeShell.DTE.17.0`)

副本先還原(SHA-256 diff 0)。

| # | tool call | 結果 |
|---|---|---|
| 1 | `ConnectIde ProgId=TcXaeShell.DTE.17.0 SolutionPath=<副本>` | success,launched,ownedBySession true,pid 120916,117.5 s,OS (x64) |
| 2 | `CreateChild`(同 Q2) | success,GUID `{267FADD3-DBE7-44FD-80F2-2F60B1EA1341}` |
| 3 | `ConsumeXml Disabled=true` | success,verified |
| 4 | `BuildProject` | success;DisabledDemo disabled / shouldBuild false,disabledMatchBy path |
| 5 | 磁碟 .sln(16:21:51)| 同 VS2022:只缺 `Release\|TwinCAT OS (x64).Build.0`,其他 17 行 Build.0 都在 |
| 6 | `SetTarget Platform='TwinCAT RT (x64)'` → `ProduceXml` | `Disabled` **false** |
| 7 | `SetTarget Platform='TwinCAT OS (x64)'` → `ProduceXml` | `Disabled` true |

Q5 沒跑 EnableConfig(避免再觸發 #21;機制已在 Q3 對照確認相同)。

## 旁支發現(建議另開 issue)

**SetTarget 的 platformMap / availablePlatforms 讀壞**:Q4b #2(VS2022,在 OS 下剛 `ConsumeXml Disabled=false`、.sln 尚未存檔時)SetTarget 回 `availablePlatforms` 只有 7 個(少 CE7 (ARMV7)、OS (ARMT2)),順序也亂;platformMap 每項 `solutionPlatform: null`、`solutionPlatformSource: "unknown"`,出現 `"TwinCAT RT (x86) (#10)"`、`"TwinCAT RT (x86) (#17)"` 這種 key,`platformMatchedBy` 變 `projectPlatform`。切換本身成功(RT (x64)、projectCheck ok)。其他 6 次 SetTarget 都正常(source `sln`、9 個 platform)。推測：模組讀磁碟 .sln 時跟 XAE 存檔撞到或 .sln 在記憶體 dirty,改用 DTE 的 SolutionConfigurations 名稱;未查 code、只觀察到一次。

## 收尾

| 動作 | 結果 |
|---|---|
| `DisconnectIde Quit=true`(VS2022) | success,pid 74652 結束 |
| `DisconnectIde Quit=true`(XAE Shell) | success,pid 120916 結束 |
| 還原副本 | 刪除後從 `.bak-67` 複製,`.vs` 補回 Hidden;SHA-256 266 檔 diff 0 |
| watcher | pid 105968 已停;events 4 筆，全部是 16:15:46–16:16:22 的 crash 與重啟 |
| 主 checkout | master `6b672fe`,只有原本的 `?? openspec/changes/add-scope-integration/` |
| UmRT | Run(pid 87120),跑的是 Q4b 下載的 AxisInterface 851 + DisabledDemo 852 |
| 保留 | 備份 `C:\Temp\Verify-4026-axis.bak-67` 與清單 `C:\Temp\Verify-4026-axis.sha256-67.txt` 沒刪 |
