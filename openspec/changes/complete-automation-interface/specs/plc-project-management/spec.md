## ADDED Requirements

### Requirement: Library Manager 操作
系統 SHALL 透過 `ITcPlcLibraryManager` 提供以下操作:library 與 placeholder 的列出、加入、移除 reference、install、uninstall、freeze placeholder。所有修改都要存檔，並讀回 `.plcproj` 驗證。

#### Scenario: 列出 references
- **WHEN** 呼叫 `GetLibraries`
- **THEN** 回傳每個 reference 的名稱、版本、vendor,以及它是不是 placeholder

#### Scenario: 移除 reference
- **WHEN** 移除一個存在的 reference
- **THEN** 讀回的 `.plcproj` 裡已經沒有這個 reference

### Requirement: 產生 Boot project
系統 SHALL 提供 `GenerateBootProject`。產生後 MUST 確認 boot 檔已經寫到 target,而且和目前的 build 一致。

#### Scenario: 產生成功
- **WHEN** Build 完成(completeBuild=true)之後呼叫
- **THEN** 回傳 success 和 boot 檔清單，可以和 `BOOT_PACKAGE_MISMATCH` 的檢查邏輯互相對照

#### Scenario: 沒有 Build
- **WHEN** 這次 session 還沒有完整的 Build
- **THEN** 回 `BUILD_REQUIRED`,不產生 boot project

### Requirement: PLCopen 與 library、archive 匯出入
系統 SHALL 提供 PLCopen XML 匯出與匯入、SaveAsLibrary、archive 存取。匯入一律走 dry-run 和讀回驗證，規則同 tree-item-primitives。

#### Scenario: 匯出後再匯入
- **WHEN** 把一個 POU 匯出成 PLCopen XML,再匯入另一個 PLC project
- **THEN** 匯入後的宣告和實作與原本的 POU 相同

### Requirement: Task 與 program 的連結
系統 SHALL 提供：建立 Task(含週期與 priority),以及把 PLC program 連結到 Task。Activate 之後 MUST 能確認 Task 真的在循環。

#### Scenario: 新 Task 執行
- **WHEN** 建立 10 ms 的 Task,連結一個 program,然後 EnableConfig
- **THEN** 該 Task 的 `CycleCount` 會持續增加

### Requirement: POU 子物件
系統 SHALL 支援建立 Interface,以及 FB 底下的 Method、Property、Action,並能讀寫它們的宣告和實作。

#### Scenario: 加 Method
- **WHEN** 在 FB 底下加一個 Method,並寫入實作
- **THEN** Build 成功，並且可以用 `GetPouCode` 讀回這個 Method

### Requirement: CheckAllObjects
系統 SHALL 提供 `CheckAllObjects`。這是不下載、只檢查全部物件的編譯。結果格式和 `BuildProject` 的 errorItems 一致。

#### Scenario: 有未被引用的錯誤物件
- **WHEN** 專案裡有一個沒被任何地方引用、但有語法錯誤的 POU
- **THEN** `CheckAllObjects` 回報這個錯誤(一般 Build 可能不會報)
