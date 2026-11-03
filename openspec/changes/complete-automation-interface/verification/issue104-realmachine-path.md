# PR #105 真機驗證(f9d637c 路徑對應)

測的是主 checkout detached `4dbdd9f`(= `f9d637c` + docs commit),registered tcauto MCP。實測 2026-11-03 14:50–15:05,VS2022 Community 17.14.23(`VisualStudio.DTE.17.0`)+ 本機 UmRT_Default(`199.5.42.250.1.1`)。

## 結論

**全部 PASS,路徑對應在真機成立**:每次 BuildProject 都回 `disabledMatchBy="path"`,包括用 8.3 短名開 solution 的那次。

| 步驟 | 判定 |
|---|---|
| 1 CreateChild + ConsumeXml Disabled | PASS |
| 2 BuildProject(無 ExpectedProject) | **PASS**,`disabledMatchBy=path` |
| 3a ExpectedProject AxisInterface | **PASS**,`disabledMatchBy=path` |
| 3b ExpectedProject DisabledDemo | **PASS**,EXPECTED_PROJECT_DISABLED,`disabledMatchBy=path` |
| 4 8.3 短名重開 + BuildProject | **PASS**,`disabledMatchBy=path`(DTE 把短名正規化成長路徑，見下) |
| 收尾 | 副本還原，266 檔 SHA-256 diff 0;IDE 都是本 session 啟動並 Quit;主 checkout → origin/master `e2ceb22` |

## 路徑組法的資料(brief 要的「uniqueName + solution 目錄」假設)

| 來源 | 值 |
|---|---|
| DTE solution FullName | `C:\temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`(第二次 ConnectIde 傳短名 `C:\temp\VE569A~1\AXISIN~1.SLN`,回傳仍是這個長路徑;磁碟根是小寫 `C:\temp`) |
| coverage `uniqueName` | `AxisInterface_Type01_Library\DisabledDemo\DisabledDemo.plcproj` |
| 組出的 entry 路徑 | `C:\temp\Verify-4026-axis\` + uniqueName |
| PLC 節點 `PlcProjectDef/ProjectPath` | `C:\temp\Verify-4026-axis\AxisInterface_Type01_Library\DisabledDemo\DisabledDemo.plcproj` |
| `ProjectGUID` | `{5D1BA25C-A6F3-41F0-85FE-F6F3189DB5D8}`(.sln nested project 也是這個 GUID) |

兩邊一致，所以假設在這個環境成立(實測)。注意：步驟 4 沒有真的讓 8.3 短名進到比對 —— DTE `Solution.FullName` 在開檔時已經被 VS 正規化成長路徑，所以這次證明的是「用短名開 solution 不會讓 path 對應掉回 name」,不是「比對碼能處理短名」。

## 每步 tool call

| seq | tool call | 結果 |
|---|---|---|
| 1 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=<長路徑>` | **IDE_MODAL_DIALOG**:VS「Microsoft Visual Studio 帳戶設定 / 登入 Visual Studio」(dialogKind unknown,buttons []),devenv pid 87464(本 session 14:51:04 啟動)。停下回報，使用者手動按「關閉」 |
| — | `GetIdeModalDialog ProcessId=87464` | dialog null |
| 2 | `ConnectIde ... SolutionPath NoLaunch=true` | **IDE_NOT_FOUND**,candidates 有 pid 87464(solution 空)— 見「新發現 1」 |
| 3 | `ConnectIde ProgId NoLaunch=true`(不帶 SolutionPath) | success,first-instance,ownedBySession true,pid 87464 |
| 4 | `ConnectIde ... SolutionPath NoLaunch=true`(已連上之後) | 仍 IDE_NOT_FOUND,而且把既有連線清掉了(下一個 GetIdeInfo 回 NOT_CONNECTED) |
| 6 | `ConnectIde ProgId NoLaunch=true` | success,pid 87464 |
| 7 | `OpenProject <長路徑 sln>` | success,30 s,sysManagerAvailable true |
| 8 | `GetIdeInfo` | `Release|TwinCAT OS (x64)`,projectPlatform `TwinCAT OS (x64)` |
| 9 | `CreateChild TIPC DisabledDemo SubType=0 VInfo="Standard PLC Template.plcproj" DryRun=false` | success,verified,`TIPC^DisabledDemo` |
| 10 | `ConsumeXml TIPC^DisabledDemo <TreeItem><Disabled>true</Disabled></TreeItem> DryRun=false` | success,verified,false→true |
| 11 | `BuildProject` | success,completeBuild true,coverageComplete true,codeVerified true,`disabledProjects=["DisabledDemo"]`,**`disabledMatchBy="path"`**,skippedProjects [],無 warningCode / disabledCheckError;DisabledDemo `shouldBuild=false status=disabled disabled=true`;errors 0,warnings 26,9.3 s |
| 12 | `BuildProject ExpectedProject=["AxisInterface"]` | success,completeBuild true,**`disabledMatchBy="path"`**,同上 |
| 13 | `BuildProject ExpectedProject=["DisabledDemo"]` | `EXPECTED_PROJECT_DISABLED`「Build not started」,0.5 s,AxisInterface `pending`,**`disabledMatchBy="path"`** |
| — | 磁碟檢查(Quit 前) | .tsproj 已有 `<Project Disabled="true" GUID="{5D1BA25C-...}" Name="DisabledDemo" ...>`;.sln 當時還沒有 DisabledDemo 的列 |
| 14 | `DisconnectIde Quit=true` | success,pid 87464 結束。Quit 後 .sln 出現 `{5D1BA25C-...}` 各 config 列，`Release|TwinCAT OS (x64)` 只有 ActiveCfg、沒有 Build.0(其他平台有 Build.0,與上一輪 XAE 自動拿掉 Build.0 一致) |
| — | `cmd /c for %I in ("<sln>") do @echo %~sI` | `C:\temp\VE569A~1\AXISIN~1.SLN`(Git Bash 的 cmd 引號會壞，要用 PowerShell 跑) |
| 15 | `ConnectIde ProgId=VisualStudio.DTE.17.0 SolutionPath=C:\temp\VE569A~1\AXISIN~1.SLN` | success,launched,pid 121524,38.6 s,solution 回長路徑,amsNetId 199.5.42.250.1.1;這次沒有登入框 |
| 16 | `BuildProject` | success,completeBuild true,**`disabledMatchBy="path"`**,disabledProjects [DisabledDemo],skippedProjects [],9.7 s |
| 17 | `ProduceXml TIPC^DisabledDemo` | `Disabled=true`,ProjectPath / GUID 見上表 |
| 18 | `DisconnectIde Quit=true` | success,pid 121524 結束 |

## 新發現(建議開 issue)

1. **`ConnectIde SolutionPath + NoLaunch` 不接沒開 solution 的 IDE**:candidates 裡有本 session 啟動、solution 為空的 pid 87464,仍回 `IDE_NOT_FOUND`;而且在已連上的狀態再呼叫一次，會把既有連線清掉(之後 NOT_CONNECTED)。情境：第一次 ConnectIde 被 modal dialog 擋在 Solution.Open 前，使用者關掉後要接回 —— 這正是 IDE_MODAL_DIALOG hint 建議「關掉後重試」的路徑，結果重試不會成功。繞法：`ConnectIde ProgId NoLaunch`(不帶 SolutionPath)+ `OpenProject`。預期行為：SolutionPath + NoLaunch 應接 module-state / ownedBySession 的空 IDE 並開 solution。
2. **VS 帳戶登入框**(「Microsoft Visual Studio 帳戶設定」)是冷啟動 VS2022 時出現的 modal,模組判 `kind unknown`、`buttons []`(不是 Win32 MessageBox)。第二次冷啟動沒出現。只是記錄，不建議自動關。

## 環境 / 收尾

- 備份 `C:\Temp\Verify-4026-axis.bak-105`,清單 `C:\Temp\Verify-4026-axis.sha256-105.txt`(266 檔，比上一輪 259 多 7 檔，是上一輪之後副本已有的內容)。還原後 266 檔 diff 0,`.vs` Hidden 屬性補回。備份與清單沒刪。
- watcher pid 91416,log `tests\Integration\logs\runtime-watch-105.jsonl`(831 筆，**零 event**,UmRT `TcSystemServiceUm` pid 82512 全程沒變)。已停。
- 沒跑 EnableConfig(依 brief);沒改 .sln、沒改 repo 程式碼、沒 commit。
- 主 checkout:`git fetch` + `git checkout --detach origin/master` → `e2ceb22`;只剩原有的 `?? openspec/changes/add-scope-integration/`。
