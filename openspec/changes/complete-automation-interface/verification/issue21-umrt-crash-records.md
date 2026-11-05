# #21 UmRT(TcSystemServiceUm.exe)crash 真機紀錄

> 這份把原本只寫在 [#21](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21) 留言裡的真機紀錄搬進 repo(#99),事實與日期照留言原樣,不重新詮釋;每筆標題下附原留言連結。另加 #68 真機驗證(`issue68-realmachine.md`、`issue68-reverify-077d51e.md`)期間自然撞到的兩次。#21 本身未修,issue 不關。
>
> - 通用環境:本機 UmRT_Default `199.5.42.250.1.1`,`TcSystemServiceUm.exe` 3.1.0.2649(檔案版本 3.1.4026.21;UmRT 本身沒有版本),Windows 11。
> - 留言沒有寫 commit 的,下面不補;有寫的才記。
> - **編號說明**:issue 本文「2026-10-18 ~ 10-20 共 6 次」;留言裡的 7、8、9 是 10-20/21 三次。之後的留言多數沒編號;`issue68-realmachine.md`、`issue68-reverify-077d51e.md` 把 2026-11-04 兩次稱為「第 9 次」「第 10 次 #21」,與留言的 9 重號。下表兩種編號都照原樣標出,以日期時間為準。

## 總表

| # | 時間 | 簽名 | pid | dump | 觸發 | 來源 |
|---|---|---|---|---|---|---|
| 1~6 | 2026-10-18 ~ 10-20 | TcOsSys.dll 3.1.0.1 c0000005 @0x589534,bucket 1526877736441380629 | 未記 | 未記 | `Set-TcSystemState Config` 或 `ActivateConfiguration()` | issue 本文 |
| 7 | 2026-10-20 22:09:40 | 同上 | 86180 | `TcSystemServiceUm.exe.86180.dmp` | VS2022 4026 專案 Activate 之後 | 留言 1 |
| 8 | 2026-10-21 00:57:15 | 同上 | 58132 | `TcSystemServiceUm.exe.58132.dmp` | 64-bit XAE `Enable-TcConfig -Force` set-config | 留言 1 |
| 9(留言編號) | 2026-10-21 05:13:14 | **ntdll.dll 10.0.26100.9711 c00000fd(stack overflow)@0x1cfa6**,bucket 1933478616089317403 | 未記 | `TcSystemServiceUm.exe.24876.dmp` | 平台設錯 `Enable-TcConfig -Force` | 留言 2 |
| 無編號 | 2026-10-27 01:14:24 | TcOsSys.dll c0000005 @0x589534 | 41244 | `TcSystemServiceUm.exe.41244.dmp` | B 組 EnableConfig Force set-config | 留言 3 |
| 無編號 | 2026-10-27 22:57:51 | 同上 | 85724 | 未記 | PR #71 驗證,EnableConfig -Force set-config | 留言 4 |
| 無編號 | 2026-10-28 18:19:23 | 同上 | 未記 | WER dump(路徑未記) | #47 驗證,EnableConfig Force set-config | 留言 5 |
| 無編號 | 2026-10-28 22:50:45 | 同上,bucket 1526877736441380629 | 45976 | `TcSystemServiceUm.exe.45976.dmp` | `Set-TcSystemState -State Config` | 留言 6 |
| 無編號 | 2026-10-29 11:57:26 | **ntdll.dll c00000fd @0x1cfa8**,bucket 1957946794227469818 | 未記 | `TcSystemServiceUm.exe.122620.dmp` | EnableConfig Force set-config | 留言 7 |
| 無編號 | 2026-11-03 14:20:37 | TcOsSys.dll c0000005 @0x589534 | 102904 | `TcSystemServiceUm.exe.102904.dmp` | #104 驗證,EnableConfig -Force set-config | 留言 8 |
| 9(#68 檔編號) | 2026-11-04 00:57:15 | TcOsSys.dll c0000005 @0x589534,bucket 1526877736441380629 | 87120 | `TcSystemServiceUm.exe.87120.dmp` | #68 驗證,EnableConfig Force set-config | issue68-realmachine.md |
| 10(#68 檔編號) | 2026-11-04 21:13:31 | 同上 | 52892 | `TcSystemServiceUm.exe.52892.dmp` | #68 重驗,SetSystemState Config | issue68-reverify-077d51e.md |

## 2026-10-18 ~ 10-20:前 6 次(issue 本文)

來源:[#21 本文](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21)。

- 現象:`Set-TcSystemState Config` 或 `ActivateConfiguration()` 時 UmRT 間歇消失,ADS 回 0x7。
- 2026-10-18 ~ 10-20 共 6 次,簽名完全相同:Windows 事件 1000/1001,Fault bucket 1526877736441380629,`TcOsSys.dll` 3.1.0.1,c0000005,offset 0x589534。間隔從 3 小時到 2 天;正常啟動、未動 Boot 的 UmRT 也會。與呼叫路徑無關(PowerShell 與 MCP 都撞到)。

## 2026-10-20/21:第 7、8 次與 ADS 卡死(B 組驗證期間,#16)

來源:[留言 issuecomment-6296840399](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6296840399)(留言時間 2026-10-20T17:20:48Z)。

簽名與前六次完全相同:`TcOsSys.dll` c0000005,offset 0x589534,Fault bucket 1526877736441380629。

| 次 | 時間 | 情境 | UmRT 已執行時間 | dump |
|---|---|---|---|---|
| 7 | 2026-10-20 22:09:40 | VS2022 4026 專案(平台 RT (x64),config 帶 `NonWinCpus=63`)Activate 之後 | 約 8 h | `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.86180.dmp` |
| 8 | 2026-10-21 00:57:15 | 64-bit XAE `Enable-TcConfig -Force` 的 set-config(port 10000 切 Config);平台 OS (x64),config 正常 | 約 1 h | `TcSystemServiceUm.exe.58132.dmp` |

**新線索**:兩次 crash 前 6 到 9 s,`Boot\TCNC.bootdata` 都先被清成 0 byte。
- 第 7 次:22:09:31 清空,22:09:40 crash。
- 第 8 次:00:57:09 清空,00:57:15 crash。
- 這兩個專案都含 NC 軸,A 組的 Festo 專案也有。下次蒐證時把 TCNC.bootdata 的時間戳一起記錄。

**新的失效模式:ADS 卡死但行程沒死**(2026-10-21 約 01:02,UmRT 重啟後約 2 min,第二次 `Enable-TcConfig -Force`)
- `TcSystemServiceUm.exe` 還在,回應正常,CPU 幾乎是 0。
- 對 199.5.42.250.1.1 的每個 ADS 呼叫都回 `0x502 Mailbox is full`;本機 TcSysSrv 正常(回 Config)。
- 沒有任何 Windows 事件。模組最後回 `SYSTEM_STATE_TIMEOUT`(180 s)。
- 復原方式:砍掉並重啟 TcSystemServiceUm,然後重新跑 `Enable-TcConfig -Force`。之後同一套 smoke 35/35 PASS。

模組端的待辦補一條:`SYSTEM_STATE_TIMEOUT` 之外,也要能分辨「行程消失(crash)」和「ADS 一直回 0x502(卡死)」這兩種情況。

## 2026-10-21 05:13:14:第 9 次(留言編號),不同簽名 ntdll c00000fd

來源:[留言 issuecomment-6301805483](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6301805483)(留言時間 2026-10-20T21:24:28Z)。

簽名不同:`ntdll.dll` 10.0.26100.9711,`c00000fd`(stack overflow),offset 0x1cfa6,Fault bucket 1933478616089317403,dump 為 `TcSystemServiceUm.exe.24876.dmp`。`TcSystemServiceUm.exe` 版本同為 3.1.0.2649。

- 情境:VS2022 + RobustSolutionFrameworkDemo,solution platform 故意設成錯的 `TwinCAT RT (x64)`,執行 `Enable-TcConfig -Force`(PR #31 的 skipped 路線,不帶 -Platform)。
- 前兆:05:12:56 `Boot\TCNC.bootdata` 被清成 0 byte,18 s 後 crash。這是 #7、#8、#9 第三次看到同樣的前兆。
- 平台不符(RT 對 UmRT)的 Activate 已經觸發 #7 和 #9,#8 則是平台正確時的 Config 切換。
- 復原:照 troubleshooting 的指令重啟。之後平台正確的整套流程(自動切平台與 lifecycle-smoke 35/35)都正常。

## 2026-10-27 01:14:24:crash 再現(驗 PR #62)

來源:[留言 issuecomment-6422673460](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6422673460)(留言時間 2026-10-26T17:19:25Z)。留言標「實測 2026-10-27,registered tcauto 驗 PR #62 時」。

- 時間 2026-10-27 01:14:24(+08:00),pid 41244(UmRT 已跑約 32 h,起於 10/25 17:09)
- 簽名:TcSystemServiceUm.exe 3.1.0.2649 / TcOsSys.dll 3.1.0.1 / c0000005 / offset 0x589534,WER bucket 1526877736441380629
- dump:`%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.41244.dmp`
- 觸發:B 組(VS2022 4026,RobustSolutionFrameworkDemo)EnableConfig Force 的 set-config(port 10000 → Config)
- watcher:01:14:24 同一秒 bootdata 220 → 0 bytes,並多出第二個 pid 83432;01:14:30 兩個 pid 都消失。和 #7/#8「bootdata 先截成 0 再 crash 6~9 s」不同,這次同一秒(1 s 取樣)。
- 模組回 SYSTEM_STATE_TIMEOUT(ADS 0x7),沒有誤報成功。照 agent brief 重啟 TcSystemServiceUm 後 EnableConfig Force 正常。

## 2026-10-27 22:57:51:PR #71 真機驗證

來源:[留言 issuecomment-6445439404](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6445439404)(留言時間 2026-10-27T15:02:30Z)。

- 環境:4026 + VS2022,B 組 RobustSolutionFrameworkDemo。
- 第一次 EnableConfig -Force 的 set-config 階段。TcSystemServiceUm.exe 3.1.0.2649,TcOsSys.dll 3.1.0.1,0xc0000005,offset 0x589534(與先前同簽章),faulting pid 85724。
- 模組回 SYSTEM_STATE_TIMEOUT(Ads 0x7)。依 brief 重啟 TcSystemServiceUm(新 pid 70028)後重跑通過。

## 2026-10-28 18:19:23:beta-prep #47 真機驗證

來源:[留言 issuecomment-6466485200](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6466485200)(留言時間 2026-10-28T10:22:46Z)。

- 環境:本機 UmRT `199.5.42.250.1.1`,TcSystemServiceUm.exe 3.1.0.2649;4026 VS2022(`VisualStudio.DTE.17.0`),副本 `C:\Temp\Verify-repro-axis`,registered tcauto。
- `EnableConfig Force=true` 在 set-config 階段 UmRT crash。事件時間 18:19:23,faulting module `TcOsSys.dll` 3.1.0.1,`0xc0000005`,offset `0x589534`,有 WER dump。模組回 `SYSTEM_STATE_TIMEOUT`(ADS 0x7),沒有誤報 success。
- 重啟 `TcSystemServiceUm` 後,第二次 EnableConfig 的 9 個 steps 全部 ok,ReadVariable 正常。

## 2026-10-28 22:50:45:openspec complete-automation-interface task 1.3 探索

來源:[留言 issuecomment-6472642830](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6472642830)(留言時間 2026-10-28T15:06:57Z)。環境:本機 UmRT,4026 XAE in VS2022。

- 觸發:`Set-TcSystemState -State Config`(送 Reconfig,ADS port 10000)
- `TcSystemServiceUm`(pid 45976)crash:`TcOsSys.dll` c0000005,offset 0x589534,bucket 1526877736441380629
- dump:`%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.45976.dmp`
- crash 前 `TCNC.bootdata` 從 396 byte 變成 0;模組回 `SYSTEM_STATE_TIMEOUT`(ADS 0x7)
- 重啟 `TcSystemServiceUm` 之後恢復正常

簽名跟之前記錄的一樣。同一天 23:05,用 registered tcauto 再做一次 `SetSystemState State=Config` 就沒有 crash,所以這個問題是間歇性的。

## 2026-10-29 11:57:26:第二種 crash 簽名(ntdll c00000fd)

來源:[留言 issuecomment-6487701546](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6487701546)(留言時間 2026-10-29T04:11:50Z)。環境:本機 UmRT,TcSystemServiceUm.exe 3.1.0.2649,Windows 11 26200,4026 VS2022。

| 項目 | 值 |
|---|---|
| 觸發 | EnableConfig Force 的 set-config(port 10000 Run → Config) |
| Faulting module | `ntdll.dll` 10.0.26100.9711 |
| Exception | **0xc00000fd(stack overflow)**,offset 0x1cfa8 |
| WER bucket | 1957946794227469818 |
| Dump | `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.122620.dmp` |
| 前兆 | 11:57:13 `TCNC.bootdata` 396 → 0 bytes(和第一種簽名一樣) |

和先前的 `TcOsSys.dll` c0000005 offset 0x589534 不同。當時 runtime 上跑的 4026 程式 Build 有 `C0297 Possible Stack Overflow`(FB_Json_Converter.JsonStrToObj,101032 of 49152),是否相關未證實。重啟 UmRT 後重跑 RunLifecycle 成功。

模組端的配套:目前 Set-TcSystemState 在 runtime 消失後仍等滿 TimeoutSec(300 s)才回 SYSTEM_STATE_TIMEOUT,task 1.8 改為偵測 TcSystemServiceUm 消失 + 連續 ADS 0x7 時提早回 `RUNTIME_CRASHED`。

## 2026-11-03 14:20:37:#104 真機驗證

來源:[留言 issuecomment-6597331428](https://github.com/Lance0901/AI-TwinCAT-Skill/issues/21#issuecomment-6597331428)(留言時間 2026-11-03T06:48:43Z)。環境:4026 VS2022,本機 UmRT,registered tcauto。

| 項目 | 值 |
|---|---|
| 觸發 | `EnableConfig -Force` set-config(AdsState Reconfig=16 from Run);PLC count 剛從 1 變 2(第二個 disabled) |
| Faulting app | TcSystemServiceUm.exe 3.1.0.2649,pid 102904 |
| Faulting module | TcOsSys.dll 3.1.0.1,c0000005,offset 0x589534(同先前簽名) |
| Report Id | c620ea1b-cf04-41f0-9a25-41ad84947b00 |
| Dump | `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.102904.dmp` |
| Watcher | 14:20:36.8 bootdata 484 -> 0,pid 14:20:43 消失 |

重啟 TcSystemServiceUm;第三次 EnableConfig(手動啟用 trial license 之後)走到 PLC Run。

## 2026-11-04 00:57:15:第 9 次(#68 檔編號,pid 87120)

來源:[issue68-realmachine.md](issue68-realmachine.md)「V1 第一次 → 變成 V2」(commit 1b32f71,registered tcauto,4026,副本 `C:\Temp\Verify-4026-axis`,Target 本機 UmRT_Default 199.5.42.250.1.1,`SetTarget Platform='TwinCAT OS (x64)'`)。此筆目前尚未貼進 #21 留言。

- UmRT pid 87120(Run)到 00:57 crash,07:46:46 重啟為 pid 52892。該檔旁支 6 記為「跑了很久(約 8.5 h)的 UmRT 做 set-config」。
- 觸發:`EnableConfig Force=true` → `success=false`,`RUNTIME_CRASHED`,55 s;steps 只有 `set-config` ok=false(「UmRT 'UmRT_Default' disappeared while waiting for 'Config'… pid 87120 no longer exists… ADS 0x7 for 10 s」)。
- 簽名:事件 1000 00:57:15,`TcSystemServiceUm.exe` 3.1.0.2649,faulting module `TcOsSys.dll` 3.1.0.1,c0000005,offset 0x589534;事件 1001 bucket 1526877736441380629;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.87120.dmp`(2,301,068 B,00:57:19)。
- watcher:00:57:14.784 `bootdata-empty`(396→0)、pid 集合 [87120]→[87120,88860],00:57:20 → []。同樣 bootdata 先截成 0、同樣是長時間跑著的 UmRT 做 set-config。
- 模組行為:`data.lifecycleBlock` command Enable-TcConfig、errorCode RUNTIME_CRASHED、step set-config、time 2026-11-04 00:57:30;`lifecycle-block.json` 落地,key `199.5.42.250.1.1`。
- 重啟:依 #68 hint 未自行重啟,使用者同意後用 agent-brief UmRT 復原指令重啟(07:46:46,pid 52892),未清 block。重啟後的新 UmRT 做兩次 set-config(V4、V5)都沒事。

## 2026-11-04 21:13:31:第 10 次(#68 檔編號,pid 52892)

來源:[issue68-reverify-077d51e.md](issue68-reverify-077d51e.md)「R1」(commit 077d51e,registered tcauto,4026,副本 `C:\Temp\Verify-4026-axis`,本機 UmRT_Default 199.5.42.250.1.1,solution platform `TwinCAT OS (x64)`)。此筆目前尚未貼進 #21 留言。

- UmRT pid 52892(07:46:46 起,跑了約 13.5 h),Run → 21:13:31 crash。
- 觸發:`SetSystemState State=Config`。模組回 `SYSTEM_STATE_TIMEOUT`、requestSent=true、block 落地 key 199.5.42.250.1.1。reachedState=Run(runtime 已死),應判 RUNTIME_CRASHED 卻沒判(該檔旁支 1、2)。
- 簽名:事件 1000 21:13:31,`TcSystemServiceUm.exe` 3.1.0.2649,faulting module `TcOsSys.dll` 3.1.0.1,c0000005,offset 0x589534;事件 1001 bucket 1526877736441380629;dump `%LOCALAPPDATA%\CrashDumps\TcSystemServiceUm.exe.52892.dmp`(2,267,128 B,21:13:37)。
- watcher(pid 55748):21:12:45–21:13:30 一直讀到 Run(Reconfig 送出後約 39 s 都沒離開 Run);21:13:31.554 `bootdata-empty`(396→0)、pid 集合 [52892]→[52892,100972](WER);21:13:37.923 → `[]`;之後 unreachable(0x7)。與上一輪(00:57,pid 87120)完全相同:長時間跑著的 UmRT 收到 Reconfig、bootdata 先截成 0。
- 恢復:bootdata 0 byte 所以不先 SetSystemState Run;BuildProject → EnableConfig Force 10 steps 全 ok、851 Run、bootPackage match → ReadVariable OK(該檔 R5 PASS)。
