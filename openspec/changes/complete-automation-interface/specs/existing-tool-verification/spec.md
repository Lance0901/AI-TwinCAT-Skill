## ADDED Requirements

### Requirement: 每個 MCP tool 都有實測紀錄
每個 MCP tool 都 SHALL 有一筆用 registered tcauto 在真機(本機 UmRT 或 CX)上跑過的實測紀錄，內容包含日期、host(4024 XAE / 4026 XAE / VS2022)和結果。沒有實測紀錄的 tool MUST 列在 `docs/known-limitations.md` 的「未實測」清單。

#### Scenario: 新 tool 上線前要實測
- **WHEN** PR 新增或修改一個 MCP tool
- **THEN** PR 描述 MUST 附上該 tool 在至少一個 host 的實測結果，否則 MUST 把它加進 known-limitations 的未實測清單

#### Scenario: 每期結束時清點
- **WHEN** 一期結束，準備發 beta
- **THEN** known-limitations 的已實測和未實測兩份清單合計 MUST 等於 MCP tool 總數

### Requirement: I/O 掃描使用文件有記載的 API
`Invoke-TcIoScan` SHALL 只呼叫 TE1000 手冊或 InfoSys 有記載的方法，並在程式註解附上出處。掃描結果 MUST 從 I/O tree 讀回，用來確認裝置確實存在。

#### Scenario: 掃描成功
- **WHEN** target 有 I/O 裝置，並呼叫 `IoScan`
- **THEN** 回傳 success,`data.devices` 列出讀回的裝置。這些裝置 MUST 能從 `GetIoTree` 查到

#### Scenario: 沒有裝置
- **WHEN** target 上沒有 I/O 裝置(例如本機 UmRT)
- **THEN** 回傳 success、`data.devices` 為空陣列，並帶 warning。MUST NOT 回 success 卻附上不存在的裝置

### Requirement: 變數 link 使用文件有記載的 API
`Set-TcVariableLink` SHALL 使用 TE1000 有記載的 link 方法，例如 `ITcSysManager.LinkVariables`。建立 link 後 MUST 讀回 mapping,確認 link 確實存在。

#### Scenario: link 成功
- **WHEN** 呼叫 `SetVariableLink`,帶入有效的 PLC 變數路徑和 I/O channel 路徑
- **THEN** 回傳 success,讀回的 mapping 裡有這條 link

#### Scenario: 路徑錯誤
- **WHEN** 任一路徑不存在
- **THEN** 回 `TREEITEM_NOT_FOUND`,並在 hint 指出是哪一個路徑

### Requirement: AddLibrary 能加上已安裝的 library
`Add-TcLibrary` SHALL 透過 `ITcPlcLibraryManager` 加入 library reference,而且 MUST 保留 #76 的存檔與讀回 `.plcproj` 驗證。

#### Scenario: 加入已安裝的 library
- **WHEN** 對 4024 和 4026 各加一次 `Tc2_DataExchange`
- **THEN** 兩者都回 success,`.plcproj` 出現對應的 `LibraryReference`,之後 Build 的 completeBuild=true

#### Scenario: library 沒有安裝
- **WHEN** 加入一個不存在的 library
- **THEN** 回 `LIBRARY_ADD_FAILED`,hint 指出 library 沒有安裝。`.plcproj` MUST NOT 被修改

### Requirement: 測試框架不盲等
測試案例 SHALL 支援 `WaitUntil` 條件輪詢(Path / Operator / Expected / TimeoutMs)。條件成立時立刻進入 assertion;逾時就判 fail,並回傳最後讀到的值。

#### Scenario: 條件提早成立
- **WHEN** 條件在 timeout 之前成立
- **THEN** 立刻進入 assertion,總耗時明顯短於 TimeoutMs

#### Scenario: 逾時
- **WHEN** 到了 TimeoutMs 條件仍然不成立
- **THEN** 這個 test case 為 fail,結果帶 `waitTimedOut=true` 和最後讀到的值
