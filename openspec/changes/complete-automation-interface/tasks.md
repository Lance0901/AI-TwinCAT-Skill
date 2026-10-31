## 1. 第 0 期：修現有功能(→ v0.2.0-beta)

- [x] 1.1 查 TE1000 手冊與 InfoSys,確認 `ProduceScan` / `ScanDevices`、`LinkTo` / `LinkVariables` 的正確 API,附上出處
- [x] 1.2 在 UmRT 用 registered tcauto 實測現有 `IoScan`、`SetVariableLink`,記錄實際行為
- [x] 1.3 依 1.1 和 1.2 的結果修 `Invoke-TcIoScan`、`Set-TcVariableLink`,包括讀回驗證和 `TREEITEM_NOT_FOUND`
- [x] 1.4 `Add-TcLibrary` 改用 `ITcPlcLibraryManager.AddLibrary`,保留存檔與讀回驗證;在 4024 和 4026 各實測一次(#80)
- [x] 1.5 `New-TcTestCase` 新增 `WaitUntil`,`Invoke-TcTest` 改成輪詢;`WaitMs` 在 help 標為不建議使用;補單元測試
- [x] 1.6 實測剩下未實測的 tool:CleanProject、DisconnectAds、GetIdeInfo、GetIoTree、GetPlcState、GetSystemState、OpenProject、PlcLogout、SendPlcProgram、SetPlcState、SetSystemState、WatchVariable、GetIdeModalDialog
- [x] 1.7 實測 composite 和測試框架:RunLifecycle、NewTestCase、RunTest、RunTestCycle
- [x] 1.8 1.6 和 1.7 發現的問題：會擋住本期的就修，其他開 issue
- [x] 1.9 更新 known-limitations 實測清單(合計等於 tool 總數);跑兩個 host 的 smoke test;發 v0.2.0-beta

## 2. 第 1 期：通用 tree 操作(→ v0.3.0-beta)

- [x] 2.1 實測 ConsumeXml 是否接受部分 XML,並決定 D3 的實作方式
- [x] 2.2 新增 `Private/TreeItem/`:路徑解析、備份、XML 合併、讀回比對等共用函式;補單元測試
- [x] 2.3 唯讀 tool:`LookupTreeItem`、`ProduceXml`
- [x] 2.4 修改 tool:`CreateChild`、`ConsumeXml`,預設 dry-run、要備份、要讀回驗證
- [x] 2.5 `DeleteChild`,要帶 ConfirmName,不接受 wildcard
- [x] 2.6 `ExportChild`、`ImportChild`
- [x] 2.7 新錯誤碼寫進 hint 表和 troubleshooting;tools.json 重新產生，修改類 tool 標 destructiveHint
- [x] 2.8 實測：送錯誤的 XML、改一個欄位、匯出後再匯入、刪除時名稱不符;發 v0.3.0-beta

## 3. 第 2 期:PLC 補齊(→ v0.4.0-beta)

- [ ] 3.1 Library Manager:GetLibraries、AddPlaceholder、RemoveReference、Install/Uninstall、FreezePlaceholder
- [ ] 3.2 GenerateBootProject,沒有完整 Build 時回 `BUILD_REQUIRED`,並和 `BOOT_PACKAGE_MISMATCH` 對照
- [ ] 3.3 PLCopen import/export(import 要 dry-run)
- [ ] 3.4 SaveAsLibrary、archive 存取
- [ ] 3.5 Task 建立和 program 連結;用 CycleCount 驗證
- [ ] 3.6 Interface,以及 Method、Property、Action;GetPouCode 和 WritePouCode 支援子物件(已實作，待 3.8 registered 實測)
- [ ] 3.7 CheckAllObjects,結果格式和 errorItems 一致
- [ ] 3.8 文件、tools.json、cmdlet 數量同步(check.ps1 要過);兩個 host 實測;發 v0.4.0-beta

## 4. 第 3 期：系統組態(→ v0.5.0-beta)

- [ ] 4.1 NC 模擬軸：建立、設定參數、link 到 AXIS_REF;在 UmRT 實測
- [ ] 4.2 TcCOM module 實例與 online 參數讀寫
- [ ] 4.3 Variant management:列出、建立、切換(先查 4024 是否支援)
- [ ] 4.4 Independent project file
- [ ] 4.5 ADS route:broadcast search、新增、刪除。確認密碼不外洩;沒有第二台 target 時只做單元測試，並標未實測
- [ ] 4.6 文件同步、known-limitations 更新;兩個 host 實測;發 v0.5.0-beta
