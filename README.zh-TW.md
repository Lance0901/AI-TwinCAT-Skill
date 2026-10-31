繁體中文 | [English](README.md)

# AI TwinCAT Skill

一個 PowerShell 模組，讓**任何 AI 編碼工具**（Claude Code、Codex、Antigravity 等）都能完整自動化 TwinCAT 3 IDE 和 PLC 運行時 — 從專案建立到即時測試 — 全程零對話框。

## 為什麼需要這個

TwinCAT 3 有強大的 COM 自動化介面，但要寫腳本卻出了名的困難：模態對話框會阻擋自動化、COM 型別衝突會導致 PowerShell 當掉、而且生命週期有未文件化的順序要求。這個模組解決了所有問題，提供 45 個 cmdlet，讓任何 AI 工具都能自主建置、部署和測試 PLC 程式。

## 功能

| 類別 | 功能 |
|------|------|
| **IDE 自動化** | 連接 VS2022 / TwinCAT XAE Shell，支援 `-SolutionPath` 智慧選擇 |
| **專案管理** | 建立專案、新增 POU / GVL / DUT / 程式庫 |
| **PLC 程式碼讀寫** | 程式化讀寫任何 POU 的 Structured Text |
| **建置與部署** | 建置、啟動組態（ADS，無對話框）、登入 + 下載 |
| **運行控制** | 啟動 / 停止 / 重置 PLC，系統狀態管理 |
| **ADS 通訊** | 即時讀寫任何 PLC 變數，符號列舉 |
| **自動化測試** | 定義測試案例，執行完整的 Build-Deploy-Test 循環，產生 JSON 報告 |
| **I/O 組態** | 掃描 EtherCAT 裝置、讀取 I/O 樹、連結變數到通道 |

## 快速開始

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1 -Force

# 1. 連接 IDE（有需要會自動開啟解決方案）
Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"

# 1b. 平台由目標對象決定:solution platform 必須等於 target platform(UmRT = Usermode Runtime = 'TwinCAT OS (x64)'),否則 ACTIVATE_FAILED。
#     不帶 -Platform 時從 target 的 TARGETINFO 讀;runtime 回 ADS 0x702(例如 TwinCAT 3.1.4026.21~22 的 UmRT)會回 PLATFORM_UNKNOWN,所以帶上(或 Enable-TcConfig -Platform ...)
Set-TcTarget -AmsNetId <data.amsNetId> -Platform 'TwinCAT OS (x64)'

# 2. 建置
Build-TcProject

# 3. 一步啟動（Config -> Activate -> 等系統 Run -> Login+Download -> PLC Run，零對話框）
#    已包含 Enter-TcPlcOnline 與 Set-TcPlcState Run；每步輪詢到位，不需要 Start-Sleep
Enable-TcConfig -Force

# 4. 連接 ADS（AmsNetId 從 IDE 自動偵測）
Connect-TcAds

# 5. 讀寫變數
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

出錯了？先看 [docs/known-limitations.md](docs/known-limitations.md)(已知問題、繞過方式、真機驗證範圍)與 [docs/troubleshooting.md](docs/troubleshooting.md) — 錯誤碼表（`error.code` / `error.hint`）、Lifecycle 正確順序、環境矩陣、已知限制。需要真機的驗證腳本在 [tests/Integration](tests/Integration/README.md)。

### 自動化測試

```powershell
# 定義測試案例
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)

$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )

# 執行完整循環：Build -> Activate -> Login -> Start -> Test -> Stop
Invoke-TcTestCycle -TestCases @($test1, $test2)
```

### 程式化修改 PLC 程式碼

```powershell
# 讀取目前程式碼
$code = Get-TcPouCode -PouName "MAIN" -PouPath "TIPC^MyPLC^MyPLC Project^POUs^MAIN"

# 修改後寫回
$newDecl = $code.data.declaration -replace 'END_VAR', "    nCycleCount : UDINT;`nEND_VAR"
$newImpl = "nCycleCount := nCycleCount + 1;`n" + $code.data.implementation
Write-TcPouCode -PouName "MAIN" -PouPath "TIPC^MyPLC^MyPLC Project^POUs^MAIN" `
    -Declaration $newDecl -Implementation $newImpl
```

## 所有指令（45 個）

### 連線
| 指令 | 說明 |
|------|------|
| `Connect-TcIde` | 連接 TwinCAT IDE（可用 `-SolutionPath` 一步連接） |
| `Disconnect-TcIde` | 斷開 IDE 連線 |
| `Reset-TcSolution` | 關掉 reload 提示、關閉所有文件（不存檔）、在同一個 IDE 關閉再重開 solution（約 20~25 s），讓 XAE 重新載入磁碟上改過的專案檔；只有改過的 `.TcPOU` 開在 XAE 編輯器時才需要（沒開的話 XAE 約 5 s 自動吃到） |
| `Connect-TcAds` | 連接 ADS（AmsNetId 從 IDE 自動偵測） |
| `Disconnect-TcAds` | 斷開 ADS 連線 |

### 專案管理
| 指令 | 說明 |
|------|------|
| `New-TcProject` | 建立新 TwinCAT 專案 |
| `Open-TcProject` | 開啟現有解決方案 |
| `Add-TcPou` | 新增 POU（Program / FB / Function） |
| `Add-TcGvl` | 新增全域變數列表 |
| `Add-TcDut` | 新增資料型別（struct/enum/union） |
| `Add-TcLibrary` | 新增程式庫參考 |

### 程式碼操作
| 指令 | 說明 |
|------|------|
| `Get-TcPouCode` | 讀取 POU 的宣告 + 實作 |
| `Write-TcPouCode` | 寫入 POU 的宣告 + 實作 |
| `Get-TcProjectTree` | 取得專案樹狀結構 |

### 建置與部署
| 指令 | 說明 |
|------|------|
| `Build-TcProject` | 建置（RPC 忙碌時自動重試；輪詢 `BuildState`，`-TimeoutSec` 預設 600，逾時 `BUILD_TIMEOUT`）；`data.errorItems[]` 為 Error List 的錯誤明細（description/file/line/category）；`data.errors` 只算 code error（#23，不再含 Library Manager 列）；缺 library 回 `LIBRARY_UNRESOLVED`，除非 `-AllowUnresolvedLibrary`（#45；這種 build 不算完整，Activate / Login 仍被擋，#61） |
| `Clear-TcProject` | Clean 整個 solution（`Clean($false)` + 輪詢 `BuildState`，`-TimeoutSec` 預設 300，逾時 `CLEAN_TIMEOUT`）；DTE 回 `$null` 的 `Solution` / `SolutionBuild` 會先等它出現（`data.nullReads`；#18，原因未確認）；只有 library 解析失敗時回 `LIBRARY_UNRESOLVED`（`-AllowUnresolvedLibrary` 才放行成 success + `data.warningCode`），LastBuildInfo 讀不到 `CLEAN_UNVERIFIED`，其他錯誤 `CLEAN_FAILED` |
| `Get-TcBuildErrors` | 用 UI Automation 讀 XAE Error List（錯誤、`-IncludeWarnings`、`-IncludeMessages`） |
| `Enable-TcConfig` | 透過 ADS 啟動組態（`-Force` 無對話框） |
| `Enter-TcPlcOnline` | 登入 + 下載程式（`-LoginMode Regular|Download|OnlineChange` = 1/4/2；提示框由全域 `SilentMode` 處理，預設不加 `SILENT` 旗標，`-SilentFlag` 才加） |
| `Exit-TcPlcOnline` | 登出 PLC |
| `Send-TcPlcProgram` | 上傳程式到 PLC |

### 運行控制
| 指令 | 說明 |
|------|------|
| `Set-TcPlcState` | 啟動 / 停止 / 重置 PLC |
| `Get-TcPlcState` | 讀取 PLC 狀態 |
| `Set-TcSystemState` | 設定 TwinCAT 系統狀態（Config/Run） |
| `Get-TcSystemState` | 讀取系統狀態 |
| `Set-TcTarget` | 設定目標系統（本機/遠端）；solution platform 跟著 target(TARGETINFO)或 `-Platform`（UmRT：`'TwinCAT OS (x64)'`）；`-NoPlatformSwitch` 只設 NetId |
| `Get-TcIdeInfo` | 取得 IDE 版本與連線資訊 |

### ADS 變數
| 指令 | 說明 |
|------|------|
| `Read-TcVariable` | 依符號路徑讀取變數 |
| `Write-TcVariable` | 依符號路徑寫入變數 |
| `Watch-TcVariable` | 條件式監控變數 |
| `Get-TcSymbols` | 列舉所有 PLC 符號（支援萬用字元） |

### I/O
| 指令 | 說明 |
|------|------|
| `Invoke-TcIoScan` | 掃描 EtherCAT 裝置 |
| `Get-TcIoTree` | 讀取 I/O 裝置樹 |
| `Set-TcVariableLink` | 連結 PLC 變數到 I/O 變數(完整 tree path,ProduceMappingInfo 讀回確認) |
| `Remove-TcVariableLink` | 移除 PLC 與 I/O 變數的 link(讀回確認) |

### 通用 tree 操作(先 dry-run,有專用指令就用專用的)
| 指令 | 說明 |
|------|------|
| `Get-TcTreeItem` | LookupTreeItem:一個 tree item 的名稱、類型、子節點(唯讀) |
| `Get-TcTreeItemXml` | ProduceXml:一個 tree item 的 XML(唯讀) |
| `New-TcTreeItem` | CreateChild:預設 dry-run;備份父節點、建立、讀回 |
| `Set-TcTreeItemXml` | ConsumeXml:送 `<TreeItem>` 片段;預設 dry-run,檢查路徑、備份、讀回比對 |
| `Remove-TcTreeItem` | DeleteChild:要帶 `-ConfirmName`;預設 dry-run;備份(XML + .xti)、讀回 |
| `Export-TcTreeItem` | ExportChild:把 tree item 匯出成 .xti |
| `Import-TcTreeItem` | ImportChild:匯入 .xti;預設 dry-run;備份、讀回 |

### 測試
| 指令 | 說明 |
|------|------|
| `New-TcTestCase` | 定義測試案例（setup / assertions / teardown） |
| `Invoke-TcTest` | 執行單一測試 |
| `Invoke-TcTestCycle` | 完整循環：Build -> Deploy -> Test -> Report |

## 架構

```
src/TwinCATAutomation/          # 核心 PowerShell 模組（工具無關）
  TwinCATAutomation.psm1        # 模組載入器
  Public/                       # 45 個匯出的 cmdlet
  Private/                      # 內部輔助函式（COM、ADS、斷言）
Invoke-TwinCATAutomation.ps1    # 統一 CLI 進入點（JSON 輸入/輸出）
adapters/
  claude-code/                  # Claude Code SKILL.md 適配器
  codex/                        # OpenAI Codex tools.json
  antigravity/                  # Antigravity plugin.yaml
```

所有指令回傳結構化 JSON：
```json
{ "success": true, "data": { "path": "MAIN.nCounter", "value": 42, "type": "UDINT" } }
{ "success": false, "error": { "message": "Build failed", "code": "BUILD_FAILED" } }
```

## 先決條件

- Windows 10/11
- TwinCAT 3 XAE（Build 4024+）或 Visual Studio 2022 含 TwinCAT 整合
- PowerShell 5.1+ 或 PowerShell 7+
- .NET Framework（TwinCAT.Ads.dll 所需）

## 重要注意事項

- **AmsNetId 是動態的** — 不要寫死。`Connect-TcAds` 會從 IDE 目標自動偵測。
- **零對話框** — `Enable-TcConfig -Force` 使用 ADS WriteControl，`Connect-TcIde` 開啟全域 `ITcAutomationSettings.SilentMode`（XAE 用預設答案回應提示）。`Enter-TcPlcOnline` 的 Login 旗標**預設不** OR SILENT：空 runtime 實測 `Login(257)` 會跳過建 app 而不是答 Yes；`-SilentFlag` 才加。
- **Solution platform** — 平台由目標對象決定:active solution platform 必須等於 target platform（UmRT / Usermode Runtime = `TwinCAT OS (x64)`，Windows RT = `TwinCAT RT (x64)`），否則 `Enable-TcConfig` 回 `ACTIVATE_FAILED`（XAE「Check config failed!」，target 上什麼都沒寫；實測 2026-10-21，4026 XAE）。solution platform 底下的 .tsproj 對到別的 project platform 時,切換前就回 `PLATFORM_PROJECT_MISMATCH`（[InfoSys](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html)）。`Set-TcTarget` 與 `Enable-TcConfig` 從 target 的 TARGETINFO（ADS port 200、IG 0x700，[InfoSys](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html)）讀 platform 並自動切換（`Enable-TcConfig` 另會重新 Build）；TwinCAT 3.1.4026.21~22 的 runtime 對它回 ADS 0x702，所以要帶 `-Platform 'TwinCAT OS (x64)'`（`Set-TcTarget` 不帶會回 `PLATFORM_UNKNOWN`，`Enable-TcConfig` 警告後照舊 Activate；`-NoPlatformFix` 讓不一致改回 `PLATFORM_MISMATCH`）。MCP：`SetTarget` / `EnableConfig` / `RunLifecycle` 的 `Platform`。見 `docs/troubleshooting.md`。
- **測試 FB 時寫 MAIN 層級變數** — PLC 每個掃描週期都會覆寫 `VAR_INPUT`（參見 Decision #17）。

## Claude Code 安裝

一行指令將 TwinCAT 技能全域安裝到 Claude Code（安裝後任何專案都可用）：

```powershell
pwsh ./TwinCATSetup-Claude.ps1
```

檢查先決條件後安裝技能 + PowerShell 模組到 `~/.claude/skills/twincat-automation/`。

解除安裝：`pwsh ./TwinCATSetup-Claude.ps1 -Uninstall`

## Codex 安裝

一行指令將 TwinCAT 技能全域安裝到 Codex（安裝後任何專案都可用）：

```powershell
pwsh ./TwinCATSetup-Codex.ps1
```

會檢查先決條件（Windows、TwinCAT、ADS DLL、IDE、模組）並安裝：
- `~/.agents/skills/twincat/TwinCATAutomation/` — PowerShell 模組（所有 cmdlet）
- `~/.agents/skills/twincat/SKILL.md` — Codex 技能，完整 API 參考
- `~/.codex/AGENTS.md` — 全域專案指引

解除安裝：`pwsh ./TwinCATSetup-Codex.ps1 -Uninstall`

## Antigravity 安裝

一行指令將 TwinCAT 技能全域安裝到 Google Antigravity：

```powershell
pwsh ./TwinCATSetup-Antigravity.ps1
```

檢查先決條件後安裝技能 + PowerShell 模組到 `~/.gemini/antigravity/skills/twincat-automation/`。

解除安裝：`pwsh ./TwinCATSetup-Antigravity.ps1 -Uninstall`

## MCP Server 安裝(Claude Desktop / 任何 MCP client)

同一個模組也能以 TcAuto MCP server(stdio)提供:45 個 cmdlet 中的 44 個(`NewProject` 暫時不在 MCP 提供,#70)加 4 個複合 tool(`RunLifecycle`、`QuickRead`、`GetStatus`、`GetIdeModalDialog`)。單一常駐的 Windows PowerShell 5.1 子程序保存 IDE/ADS 連線狀態,跨 tool 呼叫不用重連。

```powershell
cd mcp-server
npm install
npm test          # 不需要 TwinCAT
```

Claude Code 會自動讀取 repo 的 `.mcp.json`;Claude Desktop 設定見 [docs/setup-mcp.md](docs/setup-mcp.md) 與 [mcp-server/README.md](mcp-server/README.md)。

## 更新日誌

### 2026-04-02

- **修復安裝腳本**：三個安裝器（Claude、Codex、Antigravity）現在會將完整的 `TwinCATAutomation` PowerShell 模組連同 SKILL.md 一起複製。之前只安裝了技能說明文件，導致 AI 工具在其他專案中找不到實際模組。
- **多實例 IDE 偵測**：`Connect-TcIde` 現在透過 Running Object Table (ROT) 列舉所有運行中的 VS2022/XAE Shell 實例，取代只能回傳一個的 `GetActiveObject`。當多個 IDE 同時開啟時，能正確找到已開啟目標 solution 的實例，避免不必要地啟動新 IDE。
- **修復 TcAdsHelper 載入**：重寫 `Initialize-TcAdsHelper`，使用 3 種回退策略（明確路徑 → 已載入組件 → 常見安裝路徑）確保 C# helper 可靠編譯。在 `Get-TcSymbols`、`Read-TcVariable`、`Write-TcVariable` 加入懶載入保護。`Connect-TcAds` 現在會在 helper 編譯失敗時發出警告。

### 2026-03-29

- **Codex 桌面版整合**：`TwinCATSetup-Codex.ps1` 安裝器 — 檢查先決條件並將 skill + AGENTS.md 安裝到使用者層級（`~/.agents/skills/`、`~/.codex/`），讓 Codex 在任何專案都能使用 TwinCAT 自動化
- **AGENTS.md**：Codex 專案指引（在 repo 和使用者層級自動發現）
- **.agents/skills/twincat/SKILL.md**：完整 34 指令 API 參考，作為 Codex 技能
- **修復 Test 2 根本原因**：ADS 寫入 FB `VAR_INPUT` 會被 PLC 每個掃描週期覆寫。必須改寫 MAIN 層級的獨立變數（Decision #17）
- **修復完整自動化測試循環**：正確的生命週期順序是 Build -> Activate -> Login -> ADS -> Start -> Test（ADS 連線必須在 Login+Download 之後）
- **修復 `Enter-TcPlcOnline`**：使用 `LookupTreeItem` 搭配建構的路徑，取代子項列舉（TwinCAT 重啟後 Project 子項會隱藏）
- **修復 `Build-TcProject`**：新增重試迴圈（5 次）處理 `RPC_E_CALL_REJECTED`
- **修復 `Invoke-TcTestCycle`**：在 Activate 前快取 AmsNetId；重啟後不重新連接 IDE（原始 COM 參考在 XAR 重啟後仍然有效）

### 2026-03-28

- **智慧 IDE 連線**：`Connect-TcIde -SolutionPath` 一步連接 — 尋找或啟動 IDE、開啟解決方案、回傳 AmsNetId
- **修復 `Write-TcVariable`**：C# 輔助程式（`TcAdsHelper`）繞過 PowerShell CLS 合規性問題

### 2026-03-27

- **零對話框生命週期**：`Enable-TcConfig -Force`（ADS）、`Enter-TcPlcOnline -LoginMode`（提示框由全域 `SilentMode` 處理；2026-10-19 起預設拿掉 `SILENT` 旗標，因 `Login(257)` 會跳過建 app） — 完整 Build->Activate->Login->Run->Read 循環，零彈窗
- **跨工具適配器**：Claude Code SKILL.md、Codex tools.json、Antigravity plugin.yaml
- **CLAUDE.md**：AI 工具專案指南

### 2026-03-26

- **初始發布**：34 個 PowerShell cmdlet，涵蓋 IDE 自動化、專案管理、程式碼讀寫、建置部署、ADS 通訊、運行控制、I/O 組態、自動化測試
- **OpenSpec 開發流程**：完整設計文件與架構決策

## 授權

MIT
