# 真機測試 agent brief

派 agent 跑真機(XAE + 本機 UmRT 或實體 target)測試時,委派 prompt 指向這份即可;下面是每次都適用的共用規則。個別任務只需另外寫:要驗什麼、用哪個 solution 複本、完成條件。

## 環境

- **A 組(4024)**:32-bit XAE Shell,`Connect-TcIde -ProgId TcXaeShell.DTE.15.0`。A 組 Festo 專案沒有真正的 `TwinCAT OS (x64)` project platform(solution `Release|TwinCAT OS (x64)` 對到 project platform `TwinCAT OS (ARMT2)`),對 UmRT 指定 `-Platform 'TwinCAT OS (x64)'` 會回 `PLATFORM_PROJECT_MISMATCH`;要在 UmRT 跑就照專案目前的平台用 `Set-TcTarget -NoPlatformSwitch`(不帶 `-Platform`)。這是專案設定的限制,不是 XAE 版本的規則。(實測 2026-10-21 / 2026-10-22,見 troubleshooting「PLATFORM_PROJECT_MISMATCH」與「環境矩陣」)
- **B 組(4026)**:`VisualStudio.DTE.17.0`(VS2022)或 `TcXaeShell.DTE.17.0`(64-bit XAE Shell),兩者是同一套 XAE。對本機 UmRT 用 solution platform `TwinCAT OS (x64)`(`Set-TcTarget -Platform 'TwinCAT OS (x64)'`)。UmRT 的 platform 見 [InfoSys: Usermode Runtime, Runtime type (ADS)](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html);4026 XAE 在 platform 不符時回 `ACTIVATE_FAILED`(實測 2026-10-21,見 troubleshooting「ACTIVATE_FAILED」)。
- **UmRT** 是本機 TwinCAT runtime 的 user-mode 實例,只有一個,A / B 組共用。AmsNetId `199.5.42.250.1.1` 是**本機 UmRT_Default 測試環境專用**的值(AmsNetId 依機器而定,換機器要重查,模組的 `Connect-TcAds` 會自動偵測)。UmRT 沒有自己的版本號;要寫版本就寫 TwinCAT / XAE 版本,或寫 `TcSystemServiceUm.exe` 的檔案版本。

## 規則

1. **只碰自己的 IDE**:用 `Connect-TcIde -SolutionPath <自己的複本>` 接自己的 IDE;結束時用 `Disconnect-TcIde -Quit` 只關自己的(必要時加 `-Kill`,只限本 session 啟動的)。**絕不** `Stop-Process` 別人的 XAE / VS。例外只有兩個:自己用 `Start-Process -PassThru` 啟動的 watcher(規則 7,只停記下的那個 pid),以及「UmRT 復原」一節裡卡死的 `TcSystemServiceUm`。
2. **用複本**:測試前把 solution 複製到本機非 OneDrive 的工作目錄,只對複本操作,不動原專案。
3. **每步有 timeout,整體有 deadline**:每個 COM / ADS 步驟都帶 `-TimeoutSec`(或用外層 `Start-Process -PassThru` 加等待上限);整個任務另設總 deadline,時間到就收尾並回報。
4. **回報節奏**:**每完成一步或每 10 分鐘回報一行**(做了什麼、結果、耗時)。**任一步卡 10 分鐘就先停下回報**,不要自己繼續猜。
5. **license**:出現 trial license 視窗(或 `SYSTEM_STATE_*` 的 hint 提到 license)就停下回報。不要自己點,也不要自己啟用 trial。
6. **UmRT crash**(issue #21):`TcSystemServiceUm` 消失時,記下時間與事件簽名(事件檢視器 Application log 的 faulting module / exception code / offset,以及 dump 檔名),寫進回報後再復原。已知簽名見 troubleshooting「已知限制」。
7. **背景監看**:真機測試期間在背景跑 `tests/Integration/Watch-Runtime.ps1`。它每秒記一筆 UmRT 狀態:pid 集合、port 10000 AdsState、`TCNC.bootdata` 大小;pid 集合變化或 bootdata 變成 0 byte 時,會多記一行 `event`。`-DurationSec` 設成整體 deadline 的秒數,並記下 pid;收尾時只停這個 pid。回報時附上 log 路徑與 event 行:

   ```powershell
   $watch = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile',
       '-ExecutionPolicy','Bypass','-File','tests\Integration\Watch-Runtime.ps1',
       '-LogPath','tests\Integration\logs\runtime-watch.jsonl','-DurationSec','<整體 deadline 秒>'
   # ... 測試 ...
   Stop-Process -Id $watch.Id -ErrorAction SilentlyContinue   # 只停自己啟動的 watcher
   ```

8. 不要加 `Start-Sleep` 盲等;cmdlet 本身會輪詢到目標狀態(見 `CLAUDE.md`)。

## UmRT 復原

UmRT 掛掉,或每個 ADS 呼叫都回 0x502(Mailbox is full)時,重啟 `TcSystemServiceUm`:這是 0x502 唯一有效的解法(實測 2026-10-21,見 troubleshooting「SYSTEM_STATE_TIMEOUT」與「已知限制」)。行程卡死時,先 `Stop-Process` 舊的 `TcSystemServiceUm`,這是規則 1 允許的例外。啟動參數同樣出自實測 2026-10-21(見 troubleshooting「SYSTEM_STATE_TIMEOUT」):

```powershell
Start-Process "$env:TWINCAT3DIR\Runtimes\bin\TcSystemServiceUm.exe" -ArgumentList '-t bin -i path -n "UmRT_Default" -c .\3.1' -WorkingDirectory 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default'
```

重啟後 runtime 停在 Config,要重新 `Enable-TcConfig -Force`(實測 2026-10-21,見 troubleshooting「SYSTEM_STATE_TIMEOUT」)。
