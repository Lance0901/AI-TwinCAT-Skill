## ADDED Requirements

### Requirement: 查詢 tree item
系統 SHALL 提供 `LookupTreeItem` 和 `ProduceXml` 兩個 tool,依完整 tree path 回傳節點的名稱、類型、子節點清單和 XML。這兩個都是唯讀操作。

#### Scenario: 讀取節點
- **WHEN** 呼叫 `ProduceXml Path="TIPC^AxisInterface"`
- **THEN** 回傳 success,`data.xml` 是該節點的 XML

#### Scenario: 路徑不存在
- **WHEN** 給的路徑不存在
- **THEN** 回 `TREEITEM_NOT_FOUND`,並在 hint 列出最接近的上層路徑和它的子節點名稱

### Requirement: 修改類操作預設 dry-run
`CreateChild`、`DeleteChild`、`ConsumeXml`、`ImportChild` SHALL 預設 `DryRun=true`。dry-run MUST NOT 呼叫任何會修改組態的 Automation Interface 方法，只回傳預定的改動。

#### Scenario: dry-run
- **WHEN** 呼叫 `ConsumeXml`,沒有帶 DryRun
- **THEN** 回傳 success、`data.dryRun=true`,帶目前值和預定值的 diff 摘要;再次 `ProduceXml` 讀到的內容不變

#### Scenario: 真的寫入
- **WHEN** 呼叫時帶 `DryRun=false`
- **THEN** 寫入前先備份原本的 XML,回傳 `data.backupPath`,再執行修改

### Requirement: 寫入後讀回驗證
修改類操作執行後 SHALL 重新 `ProduceXml`,確認預期的改動已經生效。

#### Scenario: 改動生效
- **WHEN** ConsumeXml 修改某個參數
- **THEN** 讀回的值等於預定的值，回傳 success,並帶 `data.verified=true`

#### Scenario: 改動被 XAE 忽略
- **WHEN** XAE 接受了 XML,但讀回的值沒有變
- **THEN** 回 `TREEITEM_VERIFY_FAILED`,並附上預定值和讀回值。MUST NOT 回 success

### Requirement: 刪除要明確確認
`DeleteChild` SHALL 要求完整路徑，並帶 `ConfirmName`,而且 `ConfirmName` 要和要刪除的節點名稱一致。路徑 MUST NOT 接受 wildcard。

#### Scenario: 名稱不符
- **WHEN** `ConfirmName` 和節點名稱不一致
- **THEN** 回 `TREEITEM_DELETE_NAME_MISMATCH`,不刪除任何東西

### Requirement: ConsumeXml 只接受要修改的片段
`ConsumeXml` SHALL 接受「要修改的節點片段」,不要求整份 XML。沒有出現在片段裡的欄位 MUST 保持原本的值。

#### Scenario: 只改一個欄位
- **WHEN** 片段只包含一個參數
- **THEN** 寫入後，該節點其他參數的值和寫入前完全一樣

#### Scenario: 片段無法合併
- **WHEN** 片段的結構對不上目前的 XML
- **THEN** 回 `XML_MERGE_FAILED`,不寫入

### Requirement: 匯出與匯入子樹
系統 SHALL 提供 `ExportChild` 和 `ImportChild`,把子樹匯出成檔案，或從檔案匯入。`ImportChild` 也適用上面的 dry-run 和讀回驗證規則。

#### Scenario: 匯出後再匯入
- **WHEN** 匯出一個 Task,再用另一個名稱匯入同一份檔案
- **THEN** 新節點存在，而且新節點的 XML(名稱除外)和原本的相同
