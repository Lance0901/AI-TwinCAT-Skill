## ADDED Requirements

### Requirement: NC 模擬軸
系統 SHALL 能建立 NC axis(模擬軸)、設定主要參數，並把它 link 到 PLC 的 AXIS_REF。Activate 之後 MUST 能讀到軸的狀態。

#### Scenario: 建立並啟用
- **WHEN** 建立一個模擬軸，link 到 PLC,再 EnableConfig
- **THEN** 用 ADS 讀 AXIS_REF 可以讀到軸狀態，而且沒有 error

#### Scenario: UmRT 不支援
- **WHEN** 實測發現 UmRT 跑不起模擬軸
- **THEN** 列進 known-limitations,寫明實測日期和環境，不用推論去修

### Requirement: TcCOM module
系統 SHALL 能建立 TcCOM module 實例，並讀寫 online 參數(`ITcModuleManager`)。

#### Scenario: 讀寫 online 參數
- **WHEN** 寫入一個 module 的 online 參數
- **THEN** 讀回的值等於寫入的值

### Requirement: Variant management
系統 SHALL 能列出、建立、切換 project variant。切換後 MUST 能讀回目前生效的 variant。

#### Scenario: 切換 variant
- **WHEN** 切換到另一個 variant
- **THEN** 讀回的目前 variant 是新的那一個，Build 用的也是新 variant 的設定

### Requirement: Independent project file
系統 SHALL 能把 tree item 存成獨立的專案檔，或改回內嵌。存檔後 MUST 讀回確認檔案確實存在。

#### Scenario: 存成獨立檔
- **WHEN** 把 PLC project 設為 independent project file
- **THEN** 磁碟上出現對應的檔案,`.tsproj` 改成引用這個檔案

### Requirement: ADS route
系統 SHALL 能用 broadcast search 列出網路上的 target,並建立和刪除 ADS route。輸入的密碼 MUST NOT 寫進 log 或回傳結果。

#### Scenario: 沒有第二台 target
- **WHEN** 測試環境沒有第二台 target
- **THEN** 只跑單元測試，並在 known-limitations 標為未實測

#### Scenario: 密碼不外洩
- **WHEN** 建立 route 時帶了密碼
- **THEN** 回傳 JSON 和任何 log 都不包含這個密碼
