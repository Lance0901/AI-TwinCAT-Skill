# 真機測試 agent brief

派 agent 跑真機(XAE + 本機 UmRT 或實體 target)測試時,委派 prompt 指到這份即可;下面是每次都適用的共用規則。個別任務只需另外寫:要驗什麼、用哪個 solution 複本、完成條件。

## 環境

- **A 組(4024)**:32-bit XAE Shell,`Connect-TcIde -ProgId TcXaeShell.DTE.15.0`。4024 XAE 不檢查 solution platform,維持專案原本的 platform(`Set-TcTarget -NoPlatformSwitch`)。
- **B 組(4026)**:`VisualStudio.DTE.17.0`(VS2022)或 `TcXaeShell.DTE.17.0`(64-bit XAE Shell),同一套 XAE。對本機 UmRT 用 solution platform `TwinCAT OS (x64)`(`Set-TcTarget -Platform 'TwinCAT OS (x64)'`)。
- **UmRT** 是本機 TwinCAT runtime 的 user-mode 實例,只有一個、A / B 組共用(AmsNetId 199.5.42.250.1.1);它沒有自己的版本號,要寫版本就寫 TwinCAT / XAE 版本或 `TcSystemServiceUm.exe` 檔案版本。

## 規則

1. **只碰自己的 IDE**:用 `Connect-TcIde -SolutionPath <自己的複本>` 接自己的 IDE;結束用 `Disconnect-TcIde -Quit` 只關自己的(必要時 `-Kill`,只限本 session 啟動的)。**絕不** `Stop-Process` 別人的 XAE / VS。
2. **用複本**:測試前把 solution 複製到本機非 OneDrive 的工作目錄,只對複本操作,不動原專案。
3. **每步有 timeout,整體有 deadline**:每個 COM / ADS 步驟帶 `-TimeoutSec`(或外層 `Start-Process -PassThru` + 等待上限);整個任務另設總 deadline,到了就收尾回報。
4. **回報節奏**:**每完成一步或每 10 分鐘回報一行**(做了什麼、結果、耗時)。**任一步卡 10 分鐘先停下回報**,不要自己繼續猜。
5. **license**:出現 trial license 視窗(或 `SYSTEM_STATE_*` 的 hint 提到 license)就停下回報,不要自己點、不要自己啟用 trial。
6. **UmRT crash**(issue #21):`TcSystemServiceUm` 消失時記下時間與事件簽名(事件檢視器 Application log 的 faulting module / exception code / offset,dump 檔名),寫進回報,再復原。
7. **背景監看**:真機測試期間在背景跑 `tests/Integration/Watch-Runtime.ps1`(每秒記 UmRT pid、port 10000 AdsState、`TCNC.bootdata` 大小;pid 變化或 bootdata 變 0 byte 會多記 `event`),回報時附 log 路徑與 event 行:

   ```powershell
   Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
       '-File','tests\Integration\Watch-Runtime.ps1','-LogPath','tests\Integration\logs\runtime-watch.jsonl'
   ```

8. 不要加 `Start-Sleep` 盲等;cmdlet 本身會輪詢到目標狀態(見 `CLAUDE.md`)。

## UmRT 復原

UmRT 掛掉或卡在 ADS 0x502(Mailbox is full)時重啟(卡死的先 `Stop-Process` 舊的 `TcSystemServiceUm`,這是唯一允許 Stop 的 runtime 行程):

```powershell
Start-Process "$env:TWINCAT3DIR\Runtimes\bin\TcSystemServiceUm.exe" -ArgumentList '-t bin -i path -n "UmRT_Default" -c .\3.1' -WorkingDirectory 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default'
```

重啟後 runtime 停在 Config,要重新 `Enable-TcConfig -Force`。細節見 `docs/troubleshooting.md` 的 `SYSTEM_STATE_TIMEOUT` 與「已知限制」。
