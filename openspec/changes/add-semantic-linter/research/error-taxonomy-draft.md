# PLC 錯誤分類清單 初版(待 owner 確認後凍結)

**狀態:待 owner 確認。** 這份清單用來在規則寫好之後計算召回率(design.md D7 第 1 點),所以必須在規則設計之前凍結,不能事後依規則增刪。owner 之後提供的「真實犯過的錯誤清單」(owner 決定 5)併入後凍結,凍結時記日期與 commit。

來源標記:`[issue]` = #252 本文;`[KB]` = 知識庫 `D:\ObsidianVault\LanceDateBase-2026\wiki\`(頁名附後);`[RS]` = Robust Solution 審核規格;`[docs]` = repo `docs/`;`[review2]` = PR #262 第二輪 review;`[corpus]` = 本次語料實測。每類只寫「錯誤長什麼樣」與「機台會怎樣」,不寫偵測方法(避免清單被規則牽著走)。

| # | 類別 | 錯誤 | 機台會怎樣 | 來源 |
|---|---|---|---|---|
| E01 | scan | Timer / Trigger 只在條件成立時呼叫 | 狀態停滯、超時不觸發或立刻觸發 | [issue] |
| E02 | scan | 宣告了 FB instance 卻沒有每個 scan 呼叫(只讀輸出) | 輸出永遠是舊值 | [issue] |
| E03 | scan | 有狀態 FB 宣告在 METHOD / FUNCTION 的 VAR | Timer 永不到、Trigger 每次都觸發 | [review2] |
| E04 | scan | 狀態機的等待狀態沒有 timeout / 錯誤狀態 / 回復路徑 | 機台卡住 | [issue] |
| E05 | scan | 狀態被設成沒有處理的值 | 機台卡住 | [review2] |
| E06 | scan | 狀態 timer 離開狀態時沒歸零 | 下次進入立刻超時 | [review2] |
| E07 | scan | 用 WHILE / REPEAT 等待輸入(busy-wait) | task 卡死、cycle overrun | [review2] |
| E08 | scan | FOR 計數器型別溢位 | 無窮迴圈 | [review2] |
| E09 | scan | 同一 PROGRAM / FB 每 cycle 被呼叫兩次 | Timer / Trigger 行為異常、並行存取 | [review2] |
| E10 | scan | PROGRAM 沒掛 task | 邏輯完全不跑 | [review2] [corpus] |
| E11 | scan | FB 的 cyclic 方法(`Execute()`、`M_UpdateService`)在條件分支內呼叫 | 狀態不更新 | [KB] Interlock 函式庫;[RS] PKML-014、ARCH-003 |
| E12 | scan | 只在初始化跑一次的方法(`Build()`)寫在 cyclic 內 | 每 cycle 重建 | [KB] Interlock 函式庫 |
| E13 | motion | MC FB 的 Execute 設 TRUE 後不歸零 / 只在條件內呼叫 | 下一次命令沒上升沿、命令不執行 | [review2] |
| E14 | motion | 狀態切走時沒停軸(Busy 中離開、沒 MC_Stop / MC_Halt) | 軸繼續動 | [review2];[KB] PackML Service FB 吃掉 Abort 與 Aborting 不停軸就釋放 Resource |
| E15 | motion | 錯誤後先撤 Execute 再 Reset,沒先 Stop 就釋放資源 | 軸在無人管理下動 | [KB] 同上 |
| E16 | 回傳值 | 命令方法的回傳值沒檢查(`RequestCommand`) | 命令被靜默丟掉 | [KB] 同上;[RS] PKML-008 |
| E17 | 回傳值 | R_TRIG 邊緣已用掉但命令沒送成功,下個 scan 不重送 | 命令遺失 | [KB] 同上 |
| E18 | 記憶體 | 陣列越界(0-based / 1-based 混淆) | 蓋到相鄰變數或 exception | [review2];TE1200 SA0172(Full) |
| E19 | 記憶體 | 除以零 | exception / PLC 停機 | TE1200 SA0040(Full) |
| E20 | 記憶體 | REFERENCE / POINTER 未初始化就解參照 | page fault、PLC 停機 | [review2];TE1200 SA0039 / 0145(Full) |
| E21 | 資料 | FB 以值傳遞 | 狀態遺失 | [review2] |
| E22 | 資料 | 同一輸出多處寫入 / 跨 task 寫入 | 前面的條件被覆蓋 | [review2];TE1200 SA0004 / 0006(Light) |
| E23 | 數值 | 浮點數用 `=` 比較 | 永遠等不到 | [review2] |
| E24 | 數值 | 整數除法後才轉 REAL | 比例 / 速度算錯 | [review2] |
| E25 | 安全 | 互鎖 / E-Stop 被後面的指派覆蓋 | 互鎖失效(本 linter 不是安全功能) | [review2] |
| E26 | 契約 | LLM 編造不存在的型別 / Method / Library API | Build 失敗(編譯器擋) | [issue] |
| E27 | 契約 | Interface 簽章與實作不一致 | Build 失敗(推論) | [issue] |
| E28 | 契約 | Public DUT 欄位順序 / Enum 值被改 | HMI / ADS client 讀錯、PERSISTENT 還原錯 | [issue] |
| E29 | 專案檔 | `.plcproj` Compile entry 遺漏 / 重複 / 指向不存在 | 新 POU 沒被編譯、專案載入異常 | [issue] [docs] |
| E30 | 專案檔 | XML 被手改壞(well-formed、CDATA、必要元素) | XAE 無法載入(行為未驗證) | owner 決定 6 |
| E31 | 專案檔 | GUID 缺 / 重複 / 格式錯(複製檔案沒換 Id) | 行為未驗證 | [issue];owner 決定 6 |
| E32 | 專案檔 | `.tsproj` / `.plcproj` / `.TcTTO` / `.sln` 參照不一致 | 行為未驗證 | owner 決定 6 |
| E33 | 專案檔 | library 用了但沒加 reference | Build 失敗 | [KB] TwinCAT 3 OOP 語法陷阱 #9 |
| E34 | 語法 | `VAR PROTECTED` / ABSTRACT method 有本體 / Method 名撞運算子 | Build 失敗 | [KB] TwinCAT 3 OOP 語法陷阱 |
| E35 | 語法 | C 語言式寫法(`==`、`&&`、`x = 5;`) | 多數 Build 失敗 | [issue](LLM hallucination) |
| E36 | 專案設定 | task cycle time 不是 base time 倍數、priority 超出範圍 | XAE 離線照收、無警告 | [docs] known-limitations「AddPlcTask」 |

待 owner 補充:現場真的出過事的案例(哪一類最常見、哪一類最貴)、是否有 git 歷史可做反向植入(design.md D7 第 5 點)。
