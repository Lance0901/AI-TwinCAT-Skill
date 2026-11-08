繁體中文 | [English](README.md)

# AI TwinCAT Skill

讓 AI 編碼工具(Claude Code、Codex、Claude Desktop 或任何 MCP client)在 Windows 電腦上操作 TwinCAT 3 IDE 與 PLC runtime:開啟 solution、修改 PLC 程式碼、建置、啟動組態、下載、執行,並透過 ADS 讀寫變數,全程不跳對話框。本專案是一個 PowerShell 模組,提供 <!-- generated:cmdlet-count -->82<!-- /generated --> 個 cmdlet,安裝後以 **TcAuto MCP server** 的形式使用;也可以直接匯入模組呼叫。

狀態:beta。已知限制見[已知限制](#已知限制)與 [docs/known-limitations.md](docs/known-limitations.md)。

目錄:[需求](#需求) · [客戶安裝](#客戶安裝) · [第一次使用](#第一次使用) · [支援的 client](#支援的-client-與驗證狀態) · [升級與移除](#升級與移除) · [疑難排解](#疑難排解) · [v0.6.0-beta 的變更](#v060-beta-的變更) · [已知限制](#已知限制) · [開發者安裝](#開發者安裝checkout) · [直接使用 PowerShell 模組](#直接使用-powershell-模組) · [文件索引](#文件索引) · [舊版 skill 安裝器](#舊版-skill-安裝器不含-mcp)

## 需求

- Windows 10 或 11,以及 Windows PowerShell 5.1(Windows 內建)。MCP server 用 `powershell.exe` 5.1 執行模組。
- TwinCAT 3.1 XAE,版本 4024 或 4026:獨立的 XAE Shell,或整合 TwinCAT 的 Visual Studio 2022。安裝程式找不到 TwinCAT 時只會警告,仍會安裝;`ConnectIde` 需要它。
- 要執行的 target:本機 user-mode runtime(UmRT)、本機 Windows runtime,或可用 ADS 連到的遠端控制器。
- 支援 MCP(stdio)的 AI client:Claude Code、Claude Desktop、Codex 或其他([狀態表](#支援的-client-與驗證狀態))。
- 客戶電腦不需要其他東西。release zip 內建 Node.js;只有[開發者安裝](#開發者安裝checkout)需要 Node.js、npm 和 git。

## 客戶安裝

安裝包是 [GitHub Releases](https://github.com/Lance0901/AI-TwinCAT-Skill/releases) 頁面上的 `TcAuto-<version>.zip` 與 `TcAuto-<version>.zip.sha256`。推送 `v*` tag 時,`.github/workflows/release.yml` 會產生這兩個檔案並附到該 Release。**v0.6.0-beta 是第一個附 zip 的版本;v0.5.0-beta 以前的版本沒有安裝包。** 如果 Releases 頁面還看不到 zip,請改用[開發者安裝](#開發者安裝checkout)。

zip 內含官方 Node.js 24.22.2 `node.exe`(win-x64,SHA256 固定在 `scripts/Build-TcAutoRelease.ps1`)、launcher、`Install-TcAuto.ps1`,以及已經建置好的 runtime(含 `node_modules`,約 40 MB),所以電腦上不需要 Node.js、git 或 npm。

1. 下載 `TcAuto-<version>.zip` 與 `TcAuto-<version>.zip.sha256`,核對雜湊值。在一般 PowerShell 視窗執行(把 `0.6.0-beta` 換成你下載的版本):

   ```powershell
   cd "$HOME\Downloads"
   $zip = '.\TcAuto-0.6.0-beta.zip'
   (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()   # 必須等於下一行輸出的第一個字
   Get-Content "$zip.sha256"
   ```

2. 解除封鎖並解壓縮到本機資料夾(不要放在 OneDrive 這類雲端同步資料夾):

   ```powershell
   Unblock-File $zip
   Expand-Archive $zip -DestinationPath "$HOME\TcAuto-0.6.0-beta"
   ```

3. 關閉 Claude Code、Claude Desktop、Codex(Claude Code 執行中會改寫 `~\.claude.json`)。
4. **從一般 PowerShell 視窗**(開始功能表或 Windows Terminal)在解壓縮的資料夾執行安裝程式:

   ```powershell
   cd "$HOME\TcAuto-0.6.0-beta"
   powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1
   ```

   `-ExecutionPolicy Bypass` 只對這一個 `powershell.exe` 行程有效,不改任何設定;Windows 用戶端電腦的預設 execution policy 是 `Restricted`,連一支 script 都不能跑([about_Execution_Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)),解除封鎖並不會改變這一點。

   **不要在 Claude Desktop 的「Code」分頁,或任何 MSIX 套件內的 shell 執行安裝。** 套件內的行程寫入 `%LOCALAPPDATA%` 會被 Windows 重導到 `%LOCALAPPDATA%\Packages\<套件>\LocalCache\`,終端機裡的 Claude Code 與 Codex 看不到那些檔案。安裝程式偵測到時會回 `INSTALL_PACKAGED_CONTEXT` 並拒絕安裝,什麼都不寫(#170)。寫到 `%TEMP%` 不會被重導(實測 2026-11-08,Windows 11)。

5. 每個 client 各重開一次。client 只在 App 啟動時讀 MCP 註冊(實測 2026-11-07,Windows 11:Claude Desktop,以及 Claude Desktop「Code」分頁裡的 Claude Code,後者沒有 Reconnect 按鈕)。
6. 在 client 裡呼叫 `GetStatus`,再呼叫 `ConnectIde`。還沒 `ConnectIde` 之前,`GetStatus` 會回 `success: false`、`error.code` 為 `NOT_CONNECTED`(「IDE not connected」):這代表 Node 已啟動、`powershell.exe` 已啟動、模組已匯入。`data.bridge.runtime` 會顯示正在執行的 runtime(`version`、`commit`)。

安裝程式做的事:

- 把 `node\`、`launcher\`、`runtime\<version>\` 複製到 `%LOCALAPPDATA%\TwinCATAutomation\`,並把 `runtime\current.json` 切到新版本。保留最新的 3 個 runtime。
- 把一個 MCP server `tcauto` = `<安裝根目錄>\node\node.exe <安裝根目錄>\launcher\tcauto-launcher.mjs` 註冊到 Claude Code(user scope,`%USERPROFILE%\.claude.json`)、Claude Desktop(MSIX 版:`%LOCALAPPDATA%\Claude-Data\claude_*\claude_desktop_config.json`;標準版:`%APPDATA%\Claude\claude_desktop_config.json`)和 Codex(`%USERPROFILE%\.codex\config.toml`,`[mcp_servers.tcauto]` table)。設定檔或資料夾不存在的 client 會跳過並在結果裡回報。
- 只改 `tcauto` 這一項,改之前把每個設定檔複製成 `<檔名>.bak-<yyyyMMddTHHmmss>`。
- 最後執行 `-Verify`:用安裝好的 `node.exe` 啟動 launcher,送 MCP `initialize` 與 `tools/list`,回報 tool 數量與 runtime commit。不會連 IDE。

選項:`-Clients ClaudeCode,ClaudeDesktop,Codex`(預設三個都做)、`-Verify`(只檢查,不寫任何東西)、`-Uninstall`、`-NoVerify`、`-Keep <n>`、`-InstallRoot <dir>`,以及各 client 設定檔路徑的覆寫參數。最後一行 stdout 是 `TCAUTO_INSTALL_RESULT {json}`;安裝程式的錯誤碼見 [docs/troubleshooting.md](docs/troubleshooting.md)「安裝器錯誤碼」。完整說明、各 client 細節與 log 位置:[docs/setup-mcp.md](docs/setup-mcp.md)。

## 第一次使用

在 client 開一個新對話,用白話描述要做的 lifecycle,例如:

> 用 `C:\TcProjects\MyProject\MyProject.sln` 連接 TwinCAT IDE。target 是本機 user-mode runtime,platform 用 `TwinCAT OS (x64)`。建置專案,用 Force 啟動組態,然後讀兩次 `MAIN.nCounter`,告訴我它有沒有增加。

請換成你自己的 solution 路徑與 platform(見下表步驟 2)。client 會把這段話轉成 tool 呼叫。典型順序(MCP tool 名稱等於 CLI action 名稱):

| 步驟 | Tool | 做什麼 |
|---|---|---|
| 1 | `ConnectIde` | 找出已開啟該 solution 的 IDE,找不到就啟動一個,開啟 solution,啟用 `SilentMode`。回傳 `data.amsNetId` 與 solution platform。冷啟動可能超過一分鐘。 |
| 2 | `SetTarget` | 設定 target 的 AmsNetId 與 solution platform。platform 由 target 決定:4026 的 UmRT 要用 `TwinCAT OS (x64)`,Windows runtime 要用 `TwinCAT RT (x64)`(實測 2026-10-21;只提供 RT platform 的 4024 專案在 UmRT 上用 `TwinCAT RT (x64)` Activate 成功,見 [docs/troubleshooting.md](docs/troubleshooting.md)「環境矩陣」)。target 回報不出 platform(TwinCAT 3.1.4026.21~22 的 UmRT 對 ADS 0x702 回錯誤)時,不帶 `Platform` 會回 `PLATFORM_UNKNOWN`。 |
| 3 | `BuildProject` | 建置並等待。`BUILD_FAILED` 會帶 `data.errorItems`(從 XAE Error List 讀出的 description、file、line)。 |
| 4 | `EnableConfig`,`Force=true` | Config、Activate、等 Run、Login 與 download、等 PLC port、PLC Run,每一步都輪詢到目標狀態。 |
| 5 | `ConnectAds` | AmsNetId 自動從 IDE target 取得。 |
| 6 | `ReadVariable` / `WriteVariable` / `WatchVariable` | 透過 ADS 存取 symbol。之後再 Activate 會自動重連(`data.reconnected`)。 |

`RunLifecycle` 一次做完步驟 1 到 5 加上 PLC 狀態讀回,遇到第一個失敗的步驟就停(`data.steps[]`、`data.failedStep`)。solution 有多個 PLC project 時要給 `PlcProjectPath`;這時 `AdsPort` 必須是所選 PLC 的 port,否則回 `PLC_PORT_MISMATCH`。

模組遵守、你也應該要求 AI 遵守的規則:

- 只有目標狀態讀回確認後才會回 `success: true`。`success: false` 時 AI 要停下來,把 `data` 與 `error.hint` 回報給你,不能改走原始 ADS、COM 或 GUI。當機或 Activate 失敗後,模組會替該 target 記錄 lifecycle block,之後都回 `LIFECYCLE_BLOCKED`,直到你同意並用 `ClearLifecycleBlock` 附上原因清除。細節:[adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md)「Failure contract」。
- 啟動組態(Activate)會重啟 target 的 runtime,輸出會歸零。請在可以接受的 target 上操作。
- 長時間的呼叫(`ConnectIde`、`BuildProject`、`EnableConfig`、`RunLifecycle`)可能超過 client 自己的 request timeout(SDK 預設 60 秒),但 server 仍會繼續做完。Claude Code:用 `MCP_TOOL_TIMEOUT` 設定毫秒數(例如 `900000`)。細節:[mcp-server/README.md](mcp-server/README.md#client-request-timeout)。
- Codex 預設每次呼叫 MCP tool 都會先問你是否核准。要無人值守,在 `%USERPROFILE%\.codex\config.toml` 的 `[mcp_servers.tcauto]` table 加一行:

  ```toml
  default_tools_approval_mode = "approve"
  ```

  這樣模型呼叫 tcauto 的每個 tool 都不會再問你,包含 `EnableConfig`、`WriteVariable`、`SetPlcState`,下錯指令可能直接在真機上啟動、停止或 Reset PLC。只在測試用 target 上使用。`Install-TcAuto.ps1` 會整個重寫 `[mcp_servers.tcauto]` table(依 `scripts/lib/tcauto-client-config.mjs` 的程式碼判斷,沒有實際執行),所以每次安裝或升級後要重新加上這一行。

## 支援的 client 與驗證狀態

以 0.6.0-beta release candidate zip,在本機 UmRT 上驗證,涵蓋 4026(Visual Studio 2022)與 4024(32-bit XAE Shell),2026-11-08。

| Client | 安裝程式會註冊 | 驗證結果 | 備註 |
|---|---|---|---|
| Claude Code | 是,user scope | Opus 5.5 與 Sonnet 5.5:完整 lifecycle。Haiku 5.5:只驗過連線。 | 長時間呼叫要設 `MCP_TOOL_TIMEOUT`。 |
| Codex | 是,`config.toml` | codex-cli 0.167.0、模型 gpt-6.1-sol:完整 lifecycle。預設 tool timeout 下 `ConnectIde` 花 66 秒,沒有被中斷。 | 預設每次 tool 呼叫都要核准,見「第一次使用」。 |
| Claude Desktop | 是,寫入 MSIX 版設定檔(標準版資料夾存在時也寫) | 安裝與註冊:重開後 log 出現 `Connected to tcauto (85 tools)`(實測 2026-11-07,MSIX 4.23118.0.0)。在 Desktop 對話裡呼叫 tool **尚未完整驗證**。 | MSIX 版與標準版的設定檔位置不同,見 [docs/setup-mcp.md](docs/setup-mcp.md)。 |
| Antigravity | 否,不註冊 MCP | **未實測。** `adapters/antigravity/plugin.yaml` 由 tool 定義產生。 | 舊版 skill 安裝器見[下方](#舊版-skill-安裝器不含-mcp)。 |
| 其他 MCP client | 手動 | 未實測 | stdio server,command 為 `node`,args 為 `["<安裝根目錄>\\launcher\\tcauto-launcher.mjs"]`。 |

「完整 lifecycle」指 `ConnectIde`、`SetTarget`、`BuildProject`、`EnableConfig Force=true`、`ConnectAds`、`ReadVariable`,並且計數器持續增加。

## 升級與移除

**升級。** 下載新版 zip、核對雜湊值、解壓縮,用同樣方式執行新 zip 的 `Install-TcAuto.ps1`。註冊內容不變,所以不用重開 client:呼叫 MCP tool `ReloadRuntime`,再 `ConnectIde` 一次。模組持有 lifecycle block 或尚未存檔的 build-required 狀態時,`ReloadRuntime` 會拒絕(`RELOAD_LIFECYCLE_BLOCKED`、`RELOAD_BUILD_REQUIRED`);另一個呼叫還在跑時回 `RUNTIME_RELOAD_BUSY`。IDE 與 ADS 連線會釋放,IDE 本身繼續執行。新版 `node.exe` 要等 client 下次重開才會用到。之後 `GetStatus` 的 `data.bridge.runtime` 會顯示新的 commit。

**移除。** 關閉 client,然後在解壓縮的資料夾,從一般 PowerShell 視窗執行:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-TcAuto.ps1 -Uninstall
```

它會從 client 設定檔移除 `tcauto`(先備份),再移除安裝根目錄的 `node\`、`launcher\`、`runtime\`。同資料夾的其他檔案(`ide-solutions.json`)會保留。指令指向別處的 `tcauto` 不會動;如果 `tcauto` 是透過參數仍在用這份安裝(例如開發者的註冊),會以 `INSTALL_SHARED` 停下來,加 `-Force` 才會一併移除。

## 疑難排解

最常遇到的五種情況。每個 `error` 都有 `code`、`message`,通常還有 `hint`;完整的原因與下一步在 [docs/troubleshooting.md](docs/troubleshooting.md),安裝問題在 [docs/setup-mcp.md](docs/setup-mcp.md#troubleshooting)。

| 你看到的 | 意思 | 怎麼做 |
|---|---|---|
| 安裝程式停在 `INSTALL_PACKAGED_CONTEXT` | 安裝程式跑在 MSIX 套件內,典型是 Claude Desktop 的「Code」分頁。什麼都沒寫。 | 從一般 PowerShell 視窗重跑同一個指令,再重開 client。錯誤碼說明:[docs/troubleshooting.md](docs/troubleshooting.md)「安裝器錯誤碼」。 |
| client 約 60 秒後回報逾時,server 沒有給 `error.code` | client 自己的 request timeout 比呼叫短;server 仍會做完。 | Claude Code:`MCP_TOOL_TIMEOUT=900000`,再用 `GetStatus` 確認。[mcp-server/README.md](mcp-server/README.md#client-request-timeout) |
| `PLATFORM_UNKNOWN`,或 `ACTIVATE_FAILED`(「Check config failed」) | solution platform 和 target platform 不同,或 target 回報不出自己的 platform。 | 對 `SetTarget`、`EnableConfig` 或 `RunLifecycle` 帶 `Platform`(4026 的 UmRT 用 `TwinCAT OS (x64)`),再建置、Activate。細節:[docs/troubleshooting.md](docs/troubleshooting.md)「環境矩陣」「PLATFORM_UNKNOWN」「ACTIVATE_FAILED」。 |
| [`IDE_MODAL_DIALOG`](docs/troubleshooting.md#ide_modal_dialog--ide_modal_dialog_reload) | XAE 裡有對話框擋住呼叫。 | 用 `GetIdeModalDialog` 讀內容,在 IDE 裡處理或照 hint 做,再重試。不要盲目重試。 |
| [`RUNTIME_CRASHED`](docs/troubleshooting.md#runtime_crashed) 或 [`LIFECYCLE_BLOCKED`](docs/troubleshooting.md#lifecycle_blocked) | 本機 UmRT 的 `TcSystemServiceUm` 在 Config 或 Activate 期間消失(#21),或前一次失敗留下 block。 | 停下來,請 AI 回報 `data`。自己重啟 UmRT,同意後再 `ClearLifecycleBlock`,然後重跑 `EnableConfig Force=true`。 |

## v0.6.0-beta 的變更

- **安裝包。** release zip 內含固定版本的 `node.exe`、launcher 與預先建置好的 runtime;`Install-TcAuto.ps1` 註冊 Claude Code、Claude Desktop(MSIX 與標準版)和 Codex(#20、#162、#165)。`ReloadRuntime` 不用重開 client 就能換版。安裝程式在 MSIX 套件內會拒絕執行(#170)。
- **`RunLifecycle` / `Start-TcLifecycle`** 支援多個 PLC project:`PlcProjectPath`、`AdsPort`、`PLC_PORT_MISMATCH`(#27)。
- **`ConnectIde TakeOverOrphan=true`**:確認沒人在用之後,接管已結束的 session 啟動的 IDE(#196)。被拒絕時回 `ORPHAN_TAKEOVER_REFUSED`。
- **Tree tool。** `GetProjectTree`(I/O 段)、`LookupTreeItem`、`GetIoTree` 只列直接子節點,coupler 底下的 terminal 不再重複出現在 device 底下;節點帶 `disabled` 與 `disabledState` 欄位(#172、#177、#182、#186)。
- **`ResetSolution`** 會處理 Visual Studio 方案層級的 reload prompt,重開後讀回確認 solution 已載入完成(否則回 `SOLUTION_RELOAD_INCOMPLETE`),也會處理較晚才出現的 prompt(#106、#135、#174、#176、#180)。
- **`SetSystemState`** 停在 Config 時會附上 `data.diagnostics`(對話框、Error List、boot package),hint 也會指向真正的原因(#194)。
- **`ReadVariable` / `WriteVariable`** 遇到重新 download 後留下的舊 handle(ADS 0x711)時,會重開 ADS session 重試一次(`data.symbolsReloaded`,#26)。
- **更正舊說法。** 「UmRT 假 Run」與「Reset 會殺 `TcSystemServiceUm`」在 2026-11-08 實測未重現(#26),見下節。

## 已知限制

完整清單與繞過方式在 [docs/known-limitations.md](docs/known-limitations.md)。對多數使用者有影響的:

- **UmRT 在 Config/Activate 切換時間歇 crash(#21)。** `TcSystemServiceUm` 偶爾結束(faulting module `TcOsSys.dll`,c0000005)。模組回 `RUNTIME_CRASHED`、留下 lifecycle block,不會重試。本機 UmRT:重啟 service、讀回狀態,再用 `ClearLifecycleBlock` 附上原因清除。根因在 runtime 端。
- **舊版回報、實測未重現(#26)。** 舊紀錄說 UmRT 跑約 30 分鐘後 task 不再循環但 ADS 仍回 Run,以及 PLC Reset 會殺掉 `TcSystemServiceUm`。實測 2026-11-08,4026 Visual Studio 2022 + 本機 UmRT:跑 47 分鐘,cycle counter 每分鐘穩定增加約 25000;Reset 兩次,service 都還在,PLC 停在 Stop,下 `Run` 即恢復。更長時間沒測。
- **#175:** `ResetSolution` 會丟掉尚未存檔的 `.tsproj` 記憶體變更與 `WritePouCode` 的 editor buffer。先在 XAE 存檔。
- **#49:** `EnableConfig` 不會先檢查 target 的 license。license 過期時 target 回報 fatal error,所有連到該 target 的 XAE 都會跳出對話框。
- **#201:** 開著 reload 提示的孤兒 IDE 無法接管(`TakeOverOrphan` 因對話框被拒絕,hint 指向的 `ResetSolution` 又回 `NOT_CONNECTED`)。請在那個 IDE 按 Ignore,或手動關掉它。
- **#19:** 32-bit XAE 開含 Visu 的專案,在同一個 IDE 連續 Activate 可能記憶體不足。模組只能偵測(`IDE_CRASHED`、記憶體警告),不會自動重開 IDE。

## 開發者安裝(checkout)

需要 `PATH` 裡有 Node.js >= 22、npm 和 git,並在本機 clone 這個 repository。安裝後的目錄結構與客戶安裝相同。

1. 在 checkout 裡,切到要執行的 commit:

   ```powershell
   powershell -NoProfile -File scripts\Install-TcAutoRuntime.ps1
   ```

   `mcp-server\` 與 `src\TwinCATAutomation\` 底下有未 commit 的改動時會拒絕(`WORKTREE_DIRTY`;`-AllowDirty` 會裝成 `<commit>-dirty-<UTC 時間>`)。它把已 commit 的 runtime 複製到 `%LOCALAPPDATA%\TwinCATAutomation\runtime\<commit>\` 並執行 `npm ci --omit=dev`,切換 `current.json`,複製 launcher。
2. 註冊 launcher 一次(Claude Desktop 與 Codex:[docs/setup-mcp.md](docs/setup-mcp.md)「Register by hand」):

   ```powershell
   claude mcp add --scope user tcauto -- node "$env:LOCALAPPDATA\TwinCATAutomation\launcher\tcauto-launcher.mjs"
   ```

3. 重開 client 一次。
4. 升級:改碼、commit、重跑步驟 1、呼叫 `ReloadRuntime`(只改 PowerShell 模組時用 `ReloadModule`)。`GetStatus` 的 `data.bridge.runtime` 顯示目前執行的 commit。

不支援直接註冊 `mcp-server/index.js` 或專案的 `.mcp.json`。要打包自己 checkout 的 release zip:`powershell -NoProfile -File scripts\Build-TcAutoRelease.ps1`(輸出 `dist\TcAuto-<version>.zip`,工作目錄要乾淨,或加 `-AllowDirty`)。

檢查:每個 clone 執行一次 `powershell -File scripts/install-hooks.ps1`,之後 pre-commit hook 會跑 `scripts/check.ps1 -Fast`(語法與檔案編碼(PS 5.1)、文件裡的 cmdlet 數量是否一致、禁用字詞、錯誤碼是否有文件、`tools.json` 是否同步)。開 PR 前跑 `scripts/check.ps1`(多一個 `npm test`);CI 在 `windows-latest` 用 `-Strict` 執行。文件裡的數量與 cmdlet 簽章表夾在名為 `generated:KEY` 的 HTML 註解標記之間,不要手改,執行 `scripts/Update-GeneratedDocs.ps1`。不需 TwinCAT 的單元測試:`cd mcp-server; npm install; npm test`。審查規則:[CODING_STANDARDS.md](CODING_STANDARDS.md)。`scripts/check.ps1` 與 `npm run generate-tools` 不帶 `-ExecutionPolicy Bypass` 執行本機 `.ps1`;policy 是 `Restricted` 或 `AllSigned` 時先執行一次 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。

## 直接使用 PowerShell 模組

不用 MCP 也行:在 Windows PowerShell 5.1 或 PowerShell 7 匯入模組。如果 repository 是從 zip 或瀏覽器下載的,先執行一次 `Get-ChildItem -Recurse <repo> | Unblock-File`,否則 `RemoteSigned` policy 會拒絕這些 script。

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1 -Force

# 1. 連接 IDE(找已開啟該 solution 的 IDE,沒有就啟動一個)
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. 平台由 target 決定;4026 的 UmRT 要 'TwinCAT OS (x64)',否則 ACTIVATE_FAILED。
#     不帶 -Platform 時從 target 的 TARGETINFO 讀;runtime 回 ADS 0x702
#     (TwinCAT 3.1.4026.21~22 的 UmRT)會回 PLATFORM_UNKNOWN,所以要帶。
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. 建置
Build-TcProject

# 3. 一步完成:Config -> Activate -> 等 Run -> Login+Download -> PLC Run,零對話框,每步都輪詢
Enable-TcConfig -Force

# 4. 連接 ADS(AmsNetId 從 IDE target 自動取得)
Connect-TcAds

# 5. 讀寫變數
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

`Start-TcLifecycle` 一次做完步驟 1 到 4 並讀回狀態。整個 lifecycle 要在同一個常駐的 PowerShell session 裡跑:IDE 與 ADS 的狀態都存在那個 session 裡。所有指令都回傳 JSON:`{"success": true, "data": {...}}` 或 `{"success": false, "error": {"message": "...", "code": "...", "hint": "..."}}`。

自動化測試(Build、Activate、Login、Start、測試、Stop):

```powershell
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)
$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitUntil @{ Path = "MAIN.bDone"; Operator = "Equal"; Expected = $true } `
    -Assertions @( @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null } ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )
Invoke-TcTestCycle -TestCases @($test1, $test2)
```

測 function block 時要寫 `MAIN` 層級的變數:PLC 每個 scan cycle 都會覆寫 `VAR_INPUT`。

修改 PLC 程式碼:

```powershell
$code = Get-TcPouCode -PouName "MAIN"
$newDecl = $code.data.declaration -replace 'END_VAR', "    nCycleCount : UDINT;`nEND_VAR"
$newImpl = "nCycleCount := nCycleCount + 1;`n" + $code.data.implementation
Write-TcPouCode -PouName "MAIN" -Declaration $newDecl -Implementation $newImpl
```

`-PouPath` 可以省略(模組會依序找 `POUs`、專案根目錄);`Write-TcPouCode` 改的是 COM edit buffer,不需要 `Reset-TcSolution`。如果改成直接改磁碟上的專案檔,寫完要立刻呼叫 `Reset-TcSolution`([docs/troubleshooting.md](docs/troubleshooting.md)「磁碟改檔的正確做法」)。

### 所有指令（<!-- generated:cmdlet-count -->82<!-- /generated --> 個）

參數與 MCP tool 名稱:見 [adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md) 自動產生的表、[mcp-server/README.md](mcp-server/README.md),或匯入模組後用 `Get-Help <cmdlet>`。會改動專案或系統的 cmdlet,凡是該 cmdlet 說明有寫的,預設都是 dry-run。

| 分類 | Cmdlet |
|---|---|
| 連線 | `Connect-TcIde`, `Disconnect-TcIde`, `Reset-TcSolution`, `Connect-TcAds`, `Disconnect-TcAds`, `Get-TcIdeInfo`, `Get-TcIdeModalDialog`, `Get-TcAutomationVersion` |
| 專案 | `New-TcProject`, `Open-TcProject`, `Get-TcProjectTree`, `Add-TcPou`, `Add-TcGvl`, `Add-TcDut`, `Add-TcInterface`, `Add-TcPouMember` |
| 程式碼 | `Get-TcPouCode`, `Write-TcPouCode` |
| 程式庫 | `Get-TcLibraries`, `Add-TcLibrary`, `Add-TcLibraryPlaceholder`, `Remove-TcLibraryReference`, `Lock-TcLibraryPlaceholder`, `Install-TcLibrary`, `Uninstall-TcLibrary` |
| Task | `Add-TcPlcTask`, `Add-TcTaskProgram`, `Remove-TcTaskProgram` |
| 匯入 / 匯出 | `Export-TcPlcOpen`, `Import-TcPlcOpen`, `Save-TcPlcLibrary`, `Save-TcArchive` |
| 建置與部署 | `Build-TcProject`, `Clear-TcProject`, `Test-TcPlcProject`, `New-TcBootProject`, `Get-TcBuildErrors`, `Enable-TcConfig`, `Enter-TcPlcOnline`, `Exit-TcPlcOnline`, `Send-TcPlcProgram`, `Start-TcLifecycle` |
| 運行控制 | `Set-TcPlcState`, `Get-TcPlcState`, `Set-TcSystemState`, `Get-TcSystemState`, `Set-TcTarget`, `Clear-TcLifecycleBlock`, `New-TcIssueReport` |
| ADS 變數 | `Read-TcVariable`, `Write-TcVariable`, `Watch-TcVariable`, `Get-TcSymbols` |
| I/O | `Invoke-TcIoScan`, `Get-TcIoTree`, `Set-TcVariableLink`, `Remove-TcVariableLink` |
| 系統組態(預設 dry-run;只有單元測試,真機驗證待做) | `Add-TcNcTask`, `Add-TcNcAxis`, `Set-TcNcAxisParameter`, `Connect-TcNcAxisToPlc`, `Add-TcComModule`, `Get-TcComModuleParameter`, `Set-TcComModuleParameter`, `Set-TcComModuleContext`, `Get-TcProjectVariants`, `Set-TcProjectVariantConfig`, `Set-TcCurrentVariant`, `Set-TcIndependentFile`, `Get-TcAdsRoutes`, `Find-TcAdsTarget`, `Add-TcAdsRoute` |
| 通用 tree 操作(先 dry-run,有專用 cmdlet 就用專用的) | `Get-TcTreeItem`, `Get-TcTreeItemXml`, `New-TcTreeItem`, `Set-TcTreeItemXml`, `Remove-TcTreeItem`, `Export-TcTreeItem`, `Import-TcTreeItem` |
| 測試 | `New-TcTestCase`, `Invoke-TcTest`, `Invoke-TcTestCycle` |

### 架構

```
src/TwinCATAutomation/          # 核心 PowerShell 模組(與 AI 工具無關)
  TwinCATAutomation.psm1        # 模組載入器
  Public/                       # 82 個匯出的 cmdlet
  Private/                      # 內部 helper(COM、ADS、assertion)
Invoke-TwinCATAutomation.ps1    # 統一的 CLI 入口(JSON 進、JSON 出)
mcp-server/                     # TcAuto MCP server、launcher、tools.json
scripts/                        # Install-TcAuto.ps1、Install-TcAutoRuntime.ps1、Build-TcAutoRelease.ps1、check.ps1
adapters/
  claude-code/                  # Claude Code SKILL.md adapter
  codex/                        # OpenAI Codex tools.json
  antigravity/                  # Antigravity plugin.yaml
```

MCP server(stdio)從 <!-- generated:cmdlet-count -->82<!-- /generated --> 個 cmdlet 中提供 <!-- generated:mcp-tool-count -->79<!-- /generated --> 個以 tool 形式使用,再加上 <!-- generated:composite-count -->5<!-- /generated --> 個 composite tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`、`ReloadModule`)以及 launcher 的 `ReloadRuntime`。`NewProject` 暫時不透過 MCP 提供(#70);`Start-TcLifecycle` 對應 composite tool `RunLifecycle`(#27)。一個長駐的 Windows PowerShell 5.1 行程在多次 tool 呼叫之間保留 IDE 與 ADS 狀態。

## 文件索引

| 文件 | 用途 |
|---|---|
| [docs/setup-mcp.md](docs/setup-mcp.md) | 客戶與開發者安裝、各 client 設定檔、升級、移除、驗證、log |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 錯誤碼表(`error.code` / `error.hint`)、正確的 lifecycle 順序、環境矩陣、安裝器錯誤碼 |
| [docs/known-limitations.md](docs/known-limitations.md) | 已知問題、繞過方式、真機驗證範圍 |
| [mcp-server/README.md](mcp-server/README.md) | MCP tool 表、環境變數、client request timeout |
| [adapters/claude-code/SKILL.md](adapters/claude-code/SKILL.md) | Claude Code 的 skill 文字:lifecycle、failure contract、cmdlet 簽章表 |
| [docs/getting-started.md](docs/getting-started.md)、[docs/operations.md](docs/operations.md) | 模組層級的入門與操作參考 |
| [docs/testing-guide.md](docs/testing-guide.md)、[tests/Integration](tests/Integration/README.md) | 測試框架與 hardware-in-the-loop 檢查 |
| [docs/agent-brief-realmachine.md](docs/agent-brief-realmachine.md) | 在真機上測試的 agent 要遵守的規則 |
| [CODING_STANDARDS.md](CODING_STANDARDS.md)、[AGENTS.md](AGENTS.md)、[CLAUDE.md](CLAUDE.md) | 審查規則,以及在這個 repository 工作的 AI 工具指引 |

## 舊版 skill 安裝器(不含 MCP)

這些 script 早於 MCP 安裝:它們把 PowerShell 模組與 `SKILL.md` 複製給用 `Import-Module` 呼叫模組的 AI 工具。它們**不會**註冊 MCP server,也不會動任何 MCP 設定檔。要用 MCP 請走[客戶安裝](#客戶安裝)。這些 script 要在 checkout 裡執行。

| 工具 | 安裝 | 移除 | 安裝位置 |
|---|---|---|---|
| Claude Code | `pwsh ./TwinCATSetup-Claude.ps1` | `pwsh ./TwinCATSetup-Claude.ps1 -Uninstall` | `~/.claude/skills/twincat-automation/` |
| Codex | `pwsh ./TwinCATSetup-Codex.ps1` | `pwsh ./TwinCATSetup-Codex.ps1 -Uninstall` | `~/.agents/skills/twincat/`(模組與 `SKILL.md`)與 `~/.codex/AGENTS.md` |
| Antigravity | `pwsh ./TwinCATSetup-Antigravity.ps1` | `pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall` | `~/.gemini/antigravity/skills/twincat-automation/` |

每次安裝都會在安裝好的 `SKILL.md` 旁寫入 `tcauto-install-manifest.json`:來源 repository、模組版本、commit(或 release zip 的 `tcauto-source.json` 戳記)、安裝時間,以及每個安裝檔案的 SHA256。`Get-TcAutomationVersion`(MCP `GetAutomationVersion`)離線回報這些內容;`-Verify` 會用記錄的雜湊值檢查安裝的檔案(`INSTALL_MANIFEST_MISMATCH`)。`pwsh ./TwinCATSetup-<Claude|Codex|Antigravity>.ps1 -Verify` 會印出 manifest,並和 manifest 及這個 checkout 比對(exit 0 = 一致)。`-SkillDir <dir>` 安裝或驗證其他資料夾(Codex 的 `AGENTS.md` 用 `-CodexHome`);細節:[docs/troubleshooting.md](docs/troubleshooting.md)「安裝 manifest(#30)」。

## 版本之間的變更

見 [GitHub Releases](https://github.com/Lance0901/AI-TwinCAT-Skill/releases) 頁面與已 merge 的 pull request。本檔案原本的更新日誌停在 2026-04。

## 授權

MIT
