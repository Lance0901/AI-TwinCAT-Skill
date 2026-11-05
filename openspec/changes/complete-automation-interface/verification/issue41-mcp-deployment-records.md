# #41 TcAuto MCP 部署與連線真機紀錄

> 這份把原本只寫在 [#41](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/41) 留言裡的紀錄搬進 repo(#99),事實與日期照留言原樣,不重新詮釋;每筆標題下附原留言連結。#41 本身未結案,issue 不關。
>
> 留言沒有寫 XAE 版本的,下面不補;有寫 commit 的才記(只有 2026-10-26 那筆有)。

## 2026-10-25:第 1 點(重複註冊)本機處理

來源:[留言 issuecomment-6395758526](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/41#issuecomment-6395758526)(留言時間 2026-10-25T09:07:58Z)。

- 2026-10-25 本機已先處理第 1 點:user 範圍的 tcauto 改指向 OneDrive repo 的 `mcp-server/index.js`(不再用 `D:\Project\AI-TwinCAT-Skill`),並在 `~/.claude/settings.json` 用 `disabledMcpjsonServers: ["tcauto"]` 停用 repo `.mcp.json` 那份,所以這台電腦在任何資料夾開 Claude 都只會跑同一份。
- `claude mcp list` 的「multiple scopes」診斷仍會顯示(定義還在,只是 project 那份被停用)。
- repo 的 `.mcp.json` 保留給其他 clone 使用;要不要改成只靠安裝腳本註冊,留給 #41 決定。

## 2026-10-25:batch1(PR #52)觀察

來源:[留言 issuecomment-6396213029](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/41#issuecomment-6396213029)(留言時間 2026-10-25T09:57:07Z)。

- XAE 跳 modal 期間,註冊的 tcauto(master)`ConnectIde NoLaunch` 回 `IDE_NOT_FOUND`、`candidates=[]`(40 ms),但同一時間 PowerShell 直接列 ROT 看得到 3 個項目。之後恢復正常。疑似 bridge 端 ROT 列舉在 modal 期間拿不到 DTE 就整個略過,需要查。
- EnableConfig 遇到 XAE 的 fatal error dialog(license not found)時,modal probe 殺掉 bridge(`bridgeRestarted=true`)。設計行為,但使用者端看到的是 bridge 重啟、所有狀態遺失,hint 要講清楚。

## 2026-10-26 22:03~22:13:registered tcauto 真機驗證(master f7e41a4)

來源:[留言 issuecomment-6418206558](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/41#issuecomment-6418206558)(留言時間 2026-10-26T14:14:26Z)。

環境:master `f7e41a4`,bridge 22:00:59 重啟,本機 UmRT `199.5.42.250.1.1`。

- **A 組**(TcXaeShell.DTE.15.0,TcFestoNoVisu 複本):ConnectIde / GetIdeInfo / SetTarget(NoPlatformSwitch)/ EnableConfig Force / ConnectAds / ReadVariable×2 / GetStatus / DisconnectIde Quit 全部 success。SetTarget Platform='TwinCAT OS (x64)' 依預期回 PLATFORM_PROJECT_MISMATCH。BuildProject 回 LIBRARY_UNRESOLVED(libraryErrors=7)。
- **B 組**(VisualStudio.DTE.17.0,RobustDemo 複本):全部步驟 success,CycleCount 1001→2301。
- 這段時間 tcauto 沒有斷線;bridge 回得出 LIBRARY_UNRESOLVED / BUILD_REQUIRED,所以 bridge 跑的是新模組。

**schema 舊(這個 client)**:tool list 沒有 `CleanProject`,`BuildProject` 沒有 `AllowUnresolvedLibrary`。所以在缺 lib 的 A 組 Festo 複本上,透過 tcauto 沒辦法讓 BuildProject 回 success(+warningCode)。照規則記錄下來,沒有繞過。這是「bridge 重啟了,但 client 的 tool schema 要等 MCP server 重新註冊 / client 重連才會更新」的另一面:GetStatus 也看不出 client 跟 server 的 schema 差多少。建議:server 啟動時把 tools.json 的 hash/版本放進 GetStatus,讓呼叫端看得出 schema 是否過期。

另外發現 bridge 的 `stampOrder` 會丟掉陣列 data(GetSymbols、多路徑 ReadVariable 回空的 success):#57。
