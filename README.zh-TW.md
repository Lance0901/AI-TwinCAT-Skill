繁體中文 | [English](README.md)

# AI TwinCAT Skill

一個 PowerShell 模組，讓**任何 AI 編碼工具**（Claude Code、Codex、Antigravity 等）都能完整自動化 TwinCAT 3 IDE 和 PLC 運行時 — 從專案建立到即時測試 — 全程零對話框。

## 為什麼需要這個

TwinCAT 3 有強大的 COM 自動化介面，但要寫腳本卻出了名的困難：模態對話框會阻擋自動化、COM 型別衝突會導致 PowerShell 當掉、而且生命週期有未文件化的順序要求。這個模組解決了所有問題，提供 34 個 cmdlet，讓任何 AI 工具都能自主建置、部署和測試 PLC 程式。

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

# 2. 建置
Build-TcProject

# 3. 啟動 + 運行（Config -> Run，透過 ADS，零對話框）
Enable-TcConfig -Force

# 4. 登入 + 下載程式（Login(3) 抑制所有對話框）
Enter-TcPlcOnline

# 5. 連接 ADS（AmsNetId 從 IDE 自動偵測）
Connect-TcAds

# 6. 啟動 PLC
Set-TcPlcState -State Run

# 7. 讀寫變數
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

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

## 所有指令（34 個）

### 連線
| 指令 | 說明 |
|------|------|
| `Connect-TcIde` | 連接 TwinCAT IDE（可用 `-SolutionPath` 一步連接） |
| `Disconnect-TcIde` | 斷開 IDE 連線 |
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
| `Build-TcProject` | 建置（RPC 忙碌時自動重試） |
| `Enable-TcConfig` | 透過 ADS 啟動組態（`-Force` 無對話框） |
| `Enter-TcPlcOnline` | 登入 + 下載程式（Login(3)，無對話框） |
| `Exit-TcPlcOnline` | 登出 PLC |
| `Send-TcPlcProgram` | 上傳程式到 PLC |

### 運行控制
| 指令 | 說明 |
|------|------|
| `Set-TcPlcState` | 啟動 / 停止 / 重置 PLC |
| `Get-TcPlcState` | 讀取 PLC 狀態 |
| `Set-TcSystemState` | 設定 TwinCAT 系統狀態（Config/Run） |
| `Get-TcSystemState` | 讀取系統狀態 |
| `Set-TcTarget` | 設定目標系統（本機/遠端） |
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
| `Set-TcVariableLink` | 連結 PLC 變數到 I/O 通道 |

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
  Public/                       # 34 個匯出的 cmdlet
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
- **零對話框** — `Enable-TcConfig -Force` 使用 ADS WriteControl，`Enter-TcPlcOnline` 使用 `Login(3)`。
- **測試 FB 時寫 MAIN 層級變數** — PLC 每個掃描週期都會覆寫 `VAR_INPUT`（參見 Decision #17）。

## Claude Code 安裝

一行指令將 TwinCAT 技能全域安裝到 Claude Code（安裝後任何專案都可用）：

```powershell
pwsh ./TwinCATSetup-Claude.ps1
```

檢查先決條件後安裝技能到 `~/.claude/skills/twincat-automation/SKILL.md`。

解除安裝：`pwsh ./TwinCATSetup-Claude.ps1 -Uninstall`

## Codex 安裝

一行指令將 TwinCAT 技能全域安裝到 Codex（安裝後任何專案都可用）：

```powershell
pwsh ./TwinCATSetup-Codex.ps1
```

會檢查先決條件（Windows、TwinCAT、ADS DLL、IDE、模組）並安裝：
- `~/.agents/skills/twincat/SKILL.md` — Codex 技能，完整 API 參考
- `~/.codex/AGENTS.md` — 全域專案指引

解除安裝：`pwsh ./TwinCATSetup-Codex.ps1 -Uninstall`

## 更新日誌

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

- **零對話框生命週期**：`Enable-TcConfig -Force`（ADS）、`Enter-TcPlcOnline` 搭配 `Login(3)` — 完整 Build->Activate->Login->Run->Read 循環，零彈窗
- **跨工具適配器**：Claude Code SKILL.md、Codex tools.json、Antigravity plugin.yaml
- **CLAUDE.md**：AI 工具專案指南

### 2026-03-26

- **初始發布**：34 個 PowerShell cmdlet，涵蓋 IDE 自動化、專案管理、程式碼讀寫、建置部署、ADS 通訊、運行控制、I/O 組態、自動化測試
- **OpenSpec 開發流程**：完整設計文件與架構決策

## 授權

MIT
