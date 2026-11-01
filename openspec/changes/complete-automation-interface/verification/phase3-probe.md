# Phase 3 API 實測(實作前的設計確認):4.1–4.5

- 環境:**自建 client 實測 2026-11-01**,不是 registered tcauto(和 `mcp__tcauto__*` 的驗證分開)。
  - 4026:VS2022(`VisualStudio.DTE.17.0`),XAE 3.1.4026.22(取自本次 XAE 存檔寫出的 `.tsproj` 檔頭 `TcVersion="3.1.4026.22"`),副本 `C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln`,solution platform `TwinCAT OS (x64)`。
  - 4024:32-bit XAE Shell(`TcXaeShell.DTE.15.0`),XAE 3.1.4024.71(`BFH_1650.tsproj` 的 `TcVersion`),副本 `C:\Temp\Verify-4024-bfh\BFH-1650.sln`,solution platform `TwinCAT RT (x64)`。只做第 15、20 題和幾個建立動作的對照。
  - Runtime:本機 UmRT_Default(`TcSystemServiceUm.exe` 檔案版本 3.1.0.2649),AmsNetId `199.5.42.250.1.1`。開始時 UmRT 沒在跑，照 brief「UmRT 復原」的指令啟動(02:46:00,pid 102904),**沒有出現 license / trial / security code 對話框**。
- 方式：PowerShell 5.1(Bash 叫起的 `powershell.exe`,zh-TW culture),每個步驟一個行程:`Import-Module` 本 repo 模組 → `Connect-TcIde -ProgId <id> -SolutionPath <副本>`(第一次 launched,之後 `-NoLaunch` reattach,並用記下的 pid 確認是自己啟動的那個)→ `& (Get-Module TwinCATAutomation) { Get-TcSysManager }` 拿 `ITcSysManager`,直接 late-bind 呼叫 COM。Build / Activate / ADS 讀值用模組 cmdlet(`Set-TcTarget`、`Build-TcProject`、`Enable-TcConfig -Force`、`Connect-TcAds`、`Read-TcVariable`),raw ADS 用模組的 `New-TcAdsClient`。
- 腳本、log、匯出檔:`C:\Users\aka09\AppData\Local\Temp\claude\C--Users-aka09-OneDrive----10-Works-Beckhoff-InternalProject-TwinCAT-AI-coding-2026-AI-TwinCAT-Skill\66b9dac0-362a-4d84-878b-a5abefe2d3ce\scratchpad\p3\`(`common.ps1`、`p00`–`p30*.ps1`;完整呼叫紀錄 `probe.log`;`out\` 放 ProduceXml 全文、TMC 匯出、`.tsproj` 快照;`runtime-watch.jsonl` 是 Watch-Runtime log)。
- 下文的耗時是單次呼叫的 wall time,取自 `probe.log`。HRESULT 是 COM 例外的 `HResult`。zh-TW 在地化訊息照原樣抄。
- 對照的研究文件:`research/phase3-api.md`(TE1000 手冊 v1.7.0 頁碼沿用該文件)。
- 4026 副本的前提(和研究文件的假設不同):**專案本來就有 `NC-Task 1 SAF` 和 4 支軸**(`Axis 1`–`Axis 4`),而且已經 link 到 PLC 的 `GVL_Motion.arAxisCtrl_gb[1..4].Admin.Axis`。沒有 I/O device(`TIID` 是空的)。

## 總覽

| # | 題目 | 結論 |
|---|---|---|
| 1 | TINC / 建 NC task | TINC 可 lookup(type 19,名稱 `MOTION`);兩個副本都已有 `NC-Task 1 SAF`,**第二個 NC task 一律 0x98510002 "Item already exists!"**(任何名稱) |
| 2 | 建 axis、子節點型別 | `CreateChild(name, 1)` OK;Enc=23/sub 1 **Simulation encoder**、Drive=24/sub 5 KL4XXX、Ctrl=25/sub 1 P;**同名 axis 會靜默建出第二支** |
| 3 | axis ProduceXml / ConsumeXml | `NcAxisDef` **就在 ProduceXml 裡**;速度 `AxisParam/Velo/Maximum`,加減速 `AxisParam/Dynamic/*`;改一個欄位只動那一個;**錯的值或錯的元素也回 S_OK**(`abc` → 0) |
| 4 | ChangeChildSubType | **E_NOTIMPL**;改用 ConsumeXml `Drive/DrvType`、`Encoder/EncType`、`Controller/CtrType` 可以切 |
| 5 | NC ↔ PLC link | NC 端 `Outputs^ToPlc` / `Inputs^FromPlc` 確認;`LinkVariables` **整個 struct 一次 link** 成功、兩端順序都可以;`Get-TcMappingLinks` 解析得出 NC owner |
| 6 | Run 時讀 NcToPlc | `Read-TcVariable ...NcToPlc.ActPos` 等純量都讀得到;`DcTimeStamp` 持續增加(NC 在跑);沒有下 MC_Power,軸沒動 |
| 7 | NC raw ADS | port 500 和 501 都回;`0x4101+?` 要用 `0x4100 + AxisId`,`0x4001`/IO 2 回軸名稱 |
| 8 | 不需授權的 TcCOM | `TcNtpExternalTimeProvider`(Base,TMC 無 `<License>`)可建、可 Activate、online 可讀寫 |
| 9 | 建立 TcCOM 實例 | GUID(有無大括號、`[guid]` 物件)、名稱 + subType 0、名稱 + subType 1 **全部都可以**;名稱會被改成 `Name (TypeName)` |
| 10 | module ProduceXml | 值在 `ParameterValues/Value/{Name, Value \| EnumText \| String}`;pid 在 `Parameters/Parameter/PTCID` |
| 11 | ModuleManager / Get/SetModulePara | `Modules.Item(i)` 可列舉(`foreach` 不行);LREAL / UDINT / BOOL 讀寫 + 讀回 OK;大小不符 0x98110705 |
| 12 | Set/GetModuleContext | index 是 **TMC 的 Context Id**(NTP 是 1,不是 0);`GetModuleContext(id, [ref]$o)` 可用 |
| 13 | online 參數 | `GetOnlineModulePara` / `SetOnlineModulePara` OK;raw ADS **port 10**(IG=oid、IO=pid)結果一致;online 寫入不改專案 |
| 14 | ExportTmc / ReloadTmc | 都可用;ReloadTmc 保留參數值和 context;錯路徑會報錯，錯 `Mode` 不會 |
| 15 | 4024 late-bind variant | **4024.71 可以**(讀、寫 ProjectVariantConfig、切 variant 都 OK) |
| 16 | 沒有 variant 時的原值 | 4026:四個屬性都是空字串;4024:`ProjectVariantConfig` / `ProjectVariantItems` 是 `$null` |
| 17 | 寫入 / 覆蓋 | **整份覆蓋**;沒有自動加 `[All]`,也沒有多出 build settings |
| 18 | 錯名稱 / group / Activate | 不存在的名稱、大小寫錯、`[All]` → E_FAIL;`[Group1]` 可以設;**有 variant 時 `Enable-TcConfig` 一律誤報 `BOOT_PACKAGE_MISMATCH`(模組 bug)**;存放位置 `.tsproj` 根的 `TcProjectVariant` attribute + `<Variants>` |
| 19 | PvDisable 切換 | 只在設的那個 variant 生效，切回來會還原;`ProjectVariantItems` 反映出來 |
| 20 | SaveInOwnFile | PLC、NC axis、NC task、TcCOM、I/O device(4024)可以;PlcTask、Axes、TINC、TIRR 回 S_OK 但讀回 false;**設 true 立刻寫 `.xti`(不用 Save)**;關掉 + Save 會刪 `.xti` |
| 21 | ProduceXml 欄位 / mapping 位置 | ProduceXml 沒有對應欄位;PLC 開了 independent file 後 mapping 移到 `_Config\PLC\<Plc>.xti` 的 `<Mappings>` |
| 22 | TIRR ProduceXml | **沒有密碼欄位**;有 `ActualRoutes` / `StaticRoutes`(含 Address、Flags)、`ProjectRoutes`、`TargetList` |
| 23 | Broadcast / Search | **target 不是本機時直接失敗**;target 設本機後每次約 4.05 s 同步返回，本次一台都沒找到 |
| 24 | AddRoute 假密碼 | **未實測：改本機 route 表，留待有第二台 target** |
| 25 | AddProjectRoute | **未實測：改本機 route 表，留待有第二台 target** |
| 26 | StaticRoutes.xml 路徑 | XAR:`C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml`(Users 只有讀);UmRT:`C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Target\StaticRoutes.xml`(Users FullControl) |
| 27 | 第二台 target 的 AddRoute / Remove | **未實測：改本機 route 表，留待有第二台 target** |

---

## 4.1 NC 模擬軸

### 1. TINC 與 NC task

- 結論:`LookupTreeItem('TINC')` 成功(4026 / 4024 都是 `ItemType 19`,`Name = MOTION`)。兩個副本都已經有 `TINC^NC-Task 1 SAF`(`ItemType 1`、`ObjectId #x05000010`、`TaskDef/AmsPort 501`、`CycleTime 20000`)。`TINC.CreateChild(<name>, 1)` 試了 `NC-Task 2`、`NcProbeTask`、`NC-Task 3`,4026 和 4024 都回 **`0x98510002 Item already exists!`**(約 100 ms)。也就是說,`CreateChild(…, 1)` 建的是「NC/PTP configuration」,一個 TINC 只能有一個;已經有的時候就不能再建。所以這次**沒有看到從零建出來的 task 名稱**,只看到既有的 `NC-Task 1 SAF`(有 SAF 後綴，和手冊 C# 註解一致)。
- 授權:NC 軸在 UmRT 上 Activate 成功、DcTimeStamp 持續更新(第 6 題),沒有出現 license 對話框。
- 出處：實測 2026-11-01 4026 VS2022 / 4024 XAE Shell(`probe.log` p03、p30)。
- 對 cmdlet 設計的影響:
  - `Add-TcNcTask` 先查 `TINC.ChildCount`;已經有 task 就回 `NC_TASK_ALREADY_EXISTS`(帶既有 task 的 `PathName`),不要呼叫 CreateChild。0x98510002 也對應到這個錯誤碼。
  - `Add-TcNcAxis -Task` 省略時用唯一的那個 task;「多個 task 時回 `NC_TASK_AMBIGUOUS`」在本機無法重現(建不出第二個),保留但標未實測。
  - task 名稱一律讀回 `PathName`(SAF 後綴)。`get_Child(1).LookupChild('Axes')` 可用(17 ms)。

### 2. 建 axis

- 結論:`<task>^Axes.CreateChild('Axis A', 1, $null, $null)` 成功(43 ms),回傳 item 的 `PathName = TINC^NC-Task 1 SAF^Axes^Axis A`,名稱不變。子節點固定三個:

| 子節點 | ItemType | ItemSubType | ItemSubTypeName |
|---|---|---|---|
| Enc | 23 | 1 | Simulation encoder |
| Drive | 24 | 5 | Drive (KL4XXX/KL2502-30K/KL2521/IP2512/EL4XXX/EL2521) |
| Ctrl | 25 | 1 | Position controller P |

  - 既有的 4 支軸和新建的軸完全相同(Continuous Axis + Simulation encoder + KL4XXX drive)。NC 的「模擬軸」就是 **Enc = Simulation encoder、Drive 沒有 link 到 I/O**;TC3 的 drive 型別清單裡沒有「simulation drive」(第 4 題的列舉)。這個預設在 UmRT 上可以 Activate、NC 有在跑(第 6 題)。
  - 其他 subType:`2` Discrete Axis (two speed)、`3` Low Cost Stepper Axis (dig. I/O)、`5` Encoder Axis 可以建;`0`、`8` 回 `0x98510003 Invalid item sub type`。
  - **同名**:第二次 `CreateChild('Axis A', 1)` **成功**,樹上出現兩支 `Axis A`(ItemId 不同)。XAE 不擋同名。
  - 資料夾:`CreateChild('Folder1', -1)` 回 type 0;`CreateChild('Axis F', 1, 'Folder1/')` 建出的 PathName 是 `...^Axes^Axis F`(**不含資料夾**),而且 `Axes` 的子節點列舉裡看不到 `Folder1`,`Axis F` 排在第一個。資料夾在 tree path 上是透明的。
  - 4024:`Axes.CreateChild('Axis 1', 1)` 同樣成功、子節點相同(4024 專案已有 `Axis 1`,這次也建出同名的第二支)。
- 出處：實測 2026-11-01 4026 VS2022(p03)、4024 XAE Shell(p30)。
- 對 cmdlet 設計的影響:
  - **`Add-TcNcAxis` 一定要自己先檢查同名**(`New-TcTreeItem` 已有的 `TREEITEM_ALREADY_EXISTS` 要確認在 NC axis 也會觸發，不能靠 XAE 的例外)。
  - `-Simulation` 參數其實不需要另外設定：預設就是 simulation。改成回傳讀回的 `encoderType` / `driveType`,並在 `-Simulation:$false` 時才需要換型別(見第 4 題)。
  - `-Folder` 不影響 path,data 裡 `createdPath` 照讀回的值，不要自己拼資料夾。

### 3. axis ProduceXml 與 ConsumeXml

- 結論:axis 的 ProduceXml(約 6.4 KB,全文 `out\ax-existing-Axis1.xml`、`out\ax-new-AxisA.xml`)**包含完整的 `<NcAxisDef>`**,研究文件「NcAxisDef 是命令型片段、不在 ProduceXml 裡」的推論是錯的。結構摘要:

```xml
<TreeItem><ItemName>Axis 1</ItemName><PathName>TINC^NC-Task 1 SAF^Axes^Axis 1</PathName>
  <ItemType>22</ItemType><ItemId>1</ItemId><ObjectId>#x05010010</ObjectId>
  <ItemSubType>1</ItemSubType><ItemSubTypeName>Continuous Axis</ItemSubTypeName> ...
  <NcAxisDef>
    <AxisType>1</AxisType>
    <AxisParam>
      <Unit>mm</Unit>
      <Dynamic><Acceleration>50</Acceleration><Deceleration>50</Deceleration><Jerk>2250</Jerk>
               <AccelerationMaximum>50</AccelerationMaximum><DecelerationMaximum>50</DecelerationMaximum> ...</Dynamic>
      <Velo><RefSearch>30</RefSearch><RefSync>30</RefSync><SlowManual>100</SlowManual>
            <FastManual>600</FastManual><Fast>2000</Fast><Maximum>2000</Maximum></Velo>
      <PositionAreaControl/>, <MotionControl/>, <Loop/>, <TargetPosControl/>, <PEHControl/>, <BacklashCompensation/>, <OtherSettings/> ...
    </AxisParam>
    <Encoder><EncType>1</EncType><EncParam><ScaleFactorNumerator>0.0001</ScaleFactorNumerator> ... <Sim><RandScale>0</RandScale></Sim> ...</EncParam></Encoder>
    <Drive><DrvType>5</DrvType><DrvParam> ... <Analog><VeloReferenz>2200</VeloReferenz> ...</Analog> ...</DrvParam></Drive>
    <Controller><CtrType>1</CtrType><CtrParam> ... </CtrParam></Controller>
  </NcAxisDef>
</TreeItem>
```

  - 新建軸的預設值和既有軸只差：加減速(新軸 1500 / 1500,Maximum 15000)、`TaskDelayCycles`(0 vs 1)、名稱和 Id。Discrete Axis(subType 2)的 `Velo/Maximum` 預設 100。
  - `AxisId`:axis ProduceXml 的 `ItemId`(Axis 1 = 1、Axis 4 = 4、新建的 Axis A = 5);Run 時 `NcToPlc.AxisId` 也是 1(第 6 題)。`ObjectId` 是 `#x0501nnn0`。
  - ConsumeXml `<TreeItem><NcAxisDef><AxisParam><Velo><Maximum>1234</Maximum></Velo><Dynamic><Acceleration>77</Acceleration></Dynamic></AxisParam></NcAxisDef></TreeItem>`(54 ms)後逐元素比對：只有 `Velo/Maximum` 100→1234、`Dynamic/Acceleration` 1500→77 兩個欄位變了，**沒有連帶改動**。
  - **錯誤輸入一律 S_OK**:不存在的元素 `<Velo><NoSuch>1</NoSuch></Velo>` → OK(被忽略);`<Maximum>abc</Maximum>` → OK,讀回 **0**。`<AxisType>2/3/5</AxisType>` → OK,但 `ItemSubType` 不變(AxisType 不能用 ConsumeXml 改)。
- 出處：實測 2026-11-01 4026 VS2022(p02、p04、p05)。手冊 §6.10.1 p.294 只寫了「ProduceXml 當範本、ConsumeXml 寫回」。
- 對 cmdlet 設計的影響:
  - 速度 / 加減速可以直接走通用的 `Set-TcTreeItemXml`(元素已在 ProduceXml、沒有 attribute)。`Add-TcNcAxis -MaxVelocity/-Acceleration/-Deceleration/-Jerk` 可以開放，對應 `AxisParam/Velo/Maximum`、`AxisParam/Dynamic/Acceleration|Deceleration|Jerk`。
  - **一定要讀回比對**(`Set-TcTreeItemXml` 已有讀回)。數值參數要在送出前驗證型別(`abc` 會變 0、不會報錯)。這是 #28 類的誤報風險。
  - 軸型別(Continuous / Discrete / Stepper / Encoder axis)只能在 CreateChild 時用 subType 決定，事後改 `AxisType` 無效 → `-AxisType` 只放在建立時。

### 4. ChangeChildSubType 與型別切換

- 結論:`ITcSmTreeItem.ChangeChildSubType('Drive'|'Enc', n, $false, $null)` 對所有試過的值(Drive 0–6、10、18,Enc 0、2、3、10)都回 **`0x80004001 E_NOTIMPL`**(1–50 ms)。**用 ConsumeXml 改型別欄位可以**,而且子節點的 `ItemSubType` 跟著變:
  - Drive:`<NcAxisDef><Drive><DrvType>n</DrvType></Drive></NcAxisDef>`。0–24 的名稱:0→5(不接受 0,變成 5)、1–4 M2400 DAC 1–4、5 KL4XXX、6 KL4XXX (non linear)、7 Two speed drive、8 Stepper drive、9 SERCOS、10 KL5051、11 AX2xxx-B200、12 ProfiDrive、13 universal、14 DAC of NC Backplane、15 Lenze-CANopen、16 CANopen DS402/MDP 742、17 AX2xxx-B900、20 Stepper (KL2531/KL2541)、21 DC (KL2532/…)、22 TcCom Drive、23 MDP 733 (EL7332/…)、24 MDP 703 (EL7031/…)。
  - Encoder:`<Encoder><EncType>n</EncType></Encoder>`。0 和 1 都是 Simulation encoder;2–8、10–21、24–29 有名稱(例如 4 = KL5101/…/MDP 511、5 = SSI、19 = CANopen DS402/MDP 513、28 = TcCom Encoder、29 = DS402/MDP 513 64bit)。
  - Controller:`<Controller><CtrType>n</CtrType></Controller>`。1–3、5–14 有名稱(1 = Position controller P,14 = TcCom Controller)。
  - **不存在的值(Drive 18、19、25–40;Enc 9、22、23、30–40;Ctrl 0、4、15–40)也回 S_OK**,`ItemSubType` 變成那個數字，`ItemSubTypeName` 是空字串。
  - 最後用 ConsumeXml 改回 Drive 5 / Enc 1 / Ctrl 1,讀回正確。
- 出處：實測 2026-11-01 4026 VS2022(p04、p05)。手冊 §5.2.2 p.62 只寫了「SubType switching」。
- 對 cmdlet 設計的影響:不要用 ChangeChildSubType。換 encoder / drive 型別用 ConsumeXml 的 `DrvType` / `EncType` / `CtrType`,**送出後檢查讀回的 `ItemSubTypeName` 不是空字串**,空字串就回錯誤(例如 `NC_INVALID_SUBTYPE`)並還原。第 3 期只需要 simulation(預設值),型別切換可以延後。

### 5. NC ↔ PLC link(AXIS_REF)

- 結論:
  - 既有 mapping(`ProduceMappingInfo`,建置前就有)直接證明了 NC 端名稱:

```xml
<VarLinks><OwnerA Name="TIPC^AxisInterface^AxisInterface Instance">
  <OwnerB Name="TINC^NC-Task 1 SAF^Axes^Axis 1">
    <Link VarA="PlcTask Inputs^GVL_Motion.arAxisCtrl_gb[1].Admin.Axis.NcToPlc" VarB="Outputs^ToPlc"/>
    <Link VarA="PlcTask Outputs^GVL_Motion.arAxisCtrl_gb[1].Admin.Axis.PlcToNc" VarB="Inputs^FromPlc"/>
  </OwnerB> ... (Axis 2–4 同樣)
</OwnerA></VarLinks>
```

  - NC axis 子節點:`<axis>^Inputs`(type 8 sub 1)底下只有 `FromPlc`(type 7,19 個成員：ControlDWord、Override、AxisModeRequest、…、ExtTorque);`<axis>^Outputs`(type 8 sub 2)底下只有 `ToPlc`(type 7,42 個成員：StateDWord、ErrorCode、AxisState、…、ActPos、…、DcTimeStamp、UserData)。`ToPlc` 的 ProduceXml 有 `VarType = MC.NCTOPLC_AXIS_REF`、`VarBitSize 2048`、`AdsInfo`(AmsPort 501、IG 0xF030)和 **`<LinkedWith>`**(另一端的完整 path)。
  - PLC 端 `TIPC^AxisInterface^AxisInterface Instance^PlcTask Inputs^GVL_Motion.arAxisCtrl_gb[4].Admin.Axis.NcToPlc` 可以 lookup(type 7,42 個成員)。
  - 實驗:`UnlinkVariables` 解掉 Axis 4 兩條(34 / 17 ms)→ mapping 裡 Axis 4 消失;`LinkVariables(PLC NcToPlc, 'TINC^...^Axis A^Outputs^ToPlc')`(PLC 在前，27 ms)和 `LinkVariables('TINC^...^Axis A^Inputs^FromPlc', PLC PlcToNc)`(NC 在前，25 ms)**都成功，一次 link 整個 struct**。mapping 讀回 `<OwnerB Name="TINC^NC-Task 1 SAF^Axes^Axis A">` 兩條 Link,和既有軸格式相同。
  - 錯誤:input 接 input → `0x98510004 '...NcToPlc' and '...Inputs^FromPlc' do not match`;NC 端名稱打錯 → `0x98510001 Item '...^Outputs^NoSuch' (NoSuch failed) not found`。
  - 模組的 `Get-TcMappingLinks -SysManager` 正確解析出 NC owner 的 link(`a` = PLC 完整 path、`b` = `TINC^NC-Task 1 SAF^Axes^Axis A^Outputs^ToPlc`)。
  - 注意：專案裡同時有兩支 `Axis A`(第 2 題)時,link 接到其中一支，從 path 分不出是哪一支。
- 出處：實測 2026-11-01 4026 VS2022(p02、p06、p06b)。手冊 §5.1.1.2 p.38(LinkVariables)、§6.3.14 p.217(NC axes 可以 mapping)。
- 對 cmdlet 設計的影響:
  - `Set-TcNcAxisLink` 照研究文件的設計可以做：NC 端固定 `<axis>^Outputs^ToPlc` / `<axis>^Inputs^FromPlc`,PLC 端 `<Instance>^PlcTask Inputs^<var>.NcToPlc` / `PlcTask Outputs^<var>.PlcToNc`,struct 一次 link,讀回用既有的 `Get-TcMappingLinks`。
  - PLC 端的 task 名稱(`PlcTask Inputs`)要從 instance 的子節點找，不要寫死(這個專案剛好叫 PlcTask)。
  - 已經 link 到別支軸時要先 Unlink 或回錯誤(LinkVariables 對已 link 的變數的行為這次沒測)。

### 6. Run 時讀 NcToPlc

- 結論:乾淨副本 + `NtpOnline` 模組(第 13 題)→ `Set-TcTarget -Platform 'TwinCAT OS (x64)'` → `Build-TcProject`(17.5 s,成功)→ `Enable-TcConfig -Force`(21.9 s,`activated/restarted/loggedIn` true、`plcState Run`)→ `Connect-TcAds`(851 Run)。`Read-TcVariable` 讀 `GVL_Motion.arAxisCtrl_gb[1].Admin.Axis.NcToPlc.<成員>`:

| 成員 | 值 | type |
|---|---|---|
| ActPos | 0 | LREAL |
| ErrorCode | 0 | UDINT |
| StateDWord | `[133,0,0,2]` | MC.NCTOPLC_AXIS_REF_STATE(回傳 bytes,不是數字) |
| AxisState | 0 | UDINT |
| AxisId | 1 | UDINT |
| DcTimeStamp | 961581632 → 1037581632(相隔約 80 ms) | UDINT |
| SetVelo | 0 | LREAL |

  - `DcTimeStamp` 持續增加 → NC SAF task 在 UmRT 上真的在跑、NcToPlc 有在更新。
  - 讀整個 struct `...NcToPlc` 成功，但回的是 256 個 byte 的陣列(沒有解成欄位)。
  - **這次沒有下 MC_Power / MC_MoveAbsolute**(專案的 PLC 程式沒有現成的觸發點，寫 PLC 變數去觸發 motion 不在 probe 範圍),所以「模擬軸會不會移動」沒有實測。
- 出處：實測 2026-11-01 4026 VS2022 + 本機 UmRT(p20、p21)。
- 對 cmdlet 設計的影響:
  - `Get-TcNcAxisState` 用做法 A(PLC symbol)可以：逐成員 `Read-TcVariable`。`StateDWord` 這類 struct-of-bits 型別回 bytes,tool 要自己解或只回 raw。
  - 軸移動的驗證要留給實作後的 registered tcauto 測試(需要一個有 MC_Power / MC_MoveAbsolute 的測試 POU)。

### 7. NC raw ADS

- 結論(Run 中，`New-TcAdsClient` 連 `199.5.42.250.1.1`):

| port | IG | IO | 結果 |
|---|---|---|---|
| 500 / 501 | 0x4101 | 0x00000001 | 4 bytes = 0(Axis 1 ErrState) |
| 500 / 501 | 0x4101 | 0x00000002 | 8 bytes = 0 |
| 500 / 501 | 0x4101 | 0x00010002 | 8 bytes = 0 |
| 500 / 501 | 0x4101 | 0x00000000 | ADS 0x705 Parameter size is incorrect(64 bytes 太小) |
| 500 / 501 | 0x4001 | 0x00000001 | 4 bytes = 1(AxisId) |
| 500 / 501 | 0x4001 | 0x00000002 | 7 bytes = `Axis 1\0`(軸名稱) |
| 500 / 501 | 0x4001 | 0x00010002 | 4 bytes = `Enc\0` |
| 500 / 501 | 0x4201 | * | ADS 0x702 IndexGroup is invalid |

  - port 500 和 501 回的完全相同。axis 的 IG 是 `0x4100 + AxisId`(AxisId = ProduceXml 的 `ItemId`)。
  - 軸沒動，所以 0x00000002 / 0x00010002 是不是 ActPos 從值上分不出來;只確認了 offset 存在、長度 8。
- 出處:IG 規則 [InfoSys tc3_ads_intro 713094155](https://infosys.beckhoff.com/content/1033/tc3_ads_intro/713094155.html);port 行為實測 2026-11-01 4026 + UmRT(p21)。
- 對 cmdlet 設計的影響:做法 B 可行(port 500 即可),但值的語意要對照 InfoSys 的 offset 表再開放。第 3 期維持做法 A。

---

## 4.2 TcCOM module

### 8. 不需授權的內建 module

- 結論:`Config\Io\TcModuleFolders.xml` 列出搜尋路徑(`Config\Io`、`Config\Modules`、`CustomConfig\Modules`、`Rts`、`nc`、`Safety`、repository 等)。`Program Files (x86)\Beckhoff\TwinCAT\3.1` 底下共 76 個 `.tmc`。TMC 裡沒有 `<Licenses>` 的 module 中，挑了三個:

| module | GUID | 檔案 | context | 參數範例 |
|---|---|---|---|---|
| TcNtpExternalTimeProvider | `{7e6d2fda-2d37-4998-a31f-36958d3a2c8a}` | `Components\Base\Build_4026.22\Config\Modules\TcExternalTimeProvider.tmc` | Id 1 | TimeType DINT `#x03150001`、ClientEnable BOOL `#x03150101`、PollInterval UDINT `#x03150105` |
| Conveyor Tracking | `{DDD9731E-D08B-4ECC-BD79-E4AB77071DAD}` | `Config\Modules\TcNcKin.tmc` | Id 0,`DependOn ParentObject` | Velocity LREAL `#x05093009` |
| TcJobPool | `{0102000C-0000-0000-f000-000000000064}` | `Config\Modules\TcJobPool.tmc` | 無 | PoolId UDINT |

  - TMC 沒寫 License 不保證 runtime 不檢查授權。**只有 `TcNtpExternalTimeProvider` 有 Activate 過**(第 13 題,UmRT 上無 license 對話框、online 可讀寫)。NTP 預設 `ClientEnable = TRUE`、`ServerName = ntp.beckhoff-cloud.com`,Activate 前我把 ClientEnable 設成 FALSE,避免 UmRT 對外連線。
  - Conveyor Tracking 需要 parent object(NC group),只做離線測試。
- 出處：實測 2026-11-01 本機 TMC 檔(TcModuleFolders.xml 的路徑和手冊 §6.7.1 p.274 一致)。
- 對 cmdlet 設計的影響：整合測試用 `TcNtpExternalTimeProvider`,而且測試前要先把 `ClientEnable` 設 FALSE。

### 9. 建立 TcCOM 實例

- 結論(`TIRC^TcCOM Objects`,type 49):

| 呼叫 | 結果 |
|---|---|
| `CreateChild('NtpProbe', 0, '', '{7e6d2fda-…}')` | OK 163 ms,`PathName = TIRC^TcCOM Objects^NtpProbe (TcNtpExternalTimeProvider)`,type 48 sub -1 |
| GUID 大寫、無大括號 | OK |
| `[guid]` 物件 | OK |
| `CreateChild('NtpByName0', 0, '', 'TcNtpExternalTimeProvider')` | OK |
| `CreateChild('NtpByName1', 1, '', 'TcNtpExternalTimeProvider')` | OK |
| 不存在的 GUID | `0x98510009 TCOM Module / TCOM Configuration with GUID '%s' not found!`(訊息裡的 `%s` 沒有被替換) |
| 同名 `NtpProbe` 再建一次 | OK,自動改名成 `NtpProbe_Obj8 (TcNtpExternalTimeProvider)`(不報錯) |
| 4024:第一次就建 `NtpProbe` | OK,名稱是 `NtpProbe_Obj1 (TcNtpExternalTimeProvider)`(**4024 沒有同名也加 `_ObjN`**) |

  - 名稱一律被加上 ` (<ModuleTypeName>)` 後綴;`LookupTreeItem('TIRC^TcCOM Objects^NtpProbe')`(不帶後綴)→ `0x98510001 not found`。
  - 手冊矛盾(subType 0 vs 1):**兩個都可以**,4026 上沒有差別。
  - `CreateChild` 回傳的物件在 PowerShell 被當成集合列舉(印出的是 module 的 `Outputs` / `Diagnostic` 子節點),要用回傳值的話要包 `Write-Output -NoEnumerate` 或直接 `LookupTreeItem`。
- 出處：實測 2026-11-01 4026 VS2022(p07)、4024 XAE Shell(p30)。手冊 §6.7.1 p.274–275。
- 對 cmdlet 設計的影響:
  - `Add-TcComModule` 的 `data.createdPath` / `createdName` 一定要從讀回取得(後綴和 `_ObjN` 都不可預測)。`New-TcTreeItem` 已有讀回和「名稱不同時加 warning」,可以直接用。
  - 同名不會報錯而是改名 → 要自己先檢查;或接受改名但在 warnings 裡說明。
  - 錯誤碼 `TCCOM_CLASS_NOT_FOUND` 對應 0x98510009。

### 10. module ProduceXml

- 結論(全文 `out\tccom-*.xml`;NTP 23.6 KB、Conveyor 8.4 KB、JobPool 3.3 KB):

```xml
<TreeItem><ItemName>ConvProbe (Conveyor Tracking)</ItemName> ... <ItemType>48</ItemType><ItemId>16842800</ItemId><ObjectId>#x01010030</ObjectId> ...
  <TcModuleInstance><DataTypes>…</DataTypes>
    <Module KeepUnrestoredVarLinks="2" GUID="{DDD9731E-…}"><Name>Conveyor Tracking</Name>
      <CLSID ClassFactory="TcNcKin">{0501011A-…}</CLSID> <InitSequence>SO</InitSequence>
      <Contexts><Context><Id>0</Id><DependOn>ParentObject</DependOn></Context></Contexts>
      <Parameters>
        <Parameter Group="Slave Dynamics"><Name>Velocity</Name><BitSize>64</BitSize>
          <BaseType GUID="{18071995-…000E}">LREAL</BaseType><Default><Value>2000</Value></Default><PTCID>#x05093009</PTCID></Parameter> ...
      </Parameters> ...
      <ParameterValues>
        <Value><Name>Velocity</Name><Value>9.25</Value></Value>
        <Value><Name>Default Tracking Behavior</Name><EnumText>mcTrackingBehaviorDynLimited</EnumText></Value> ...
      </ParameterValues>
```

  - 參數的 pid 在 `Parameters/Parameter/PTCID`(16 進位字串，大小寫不一,例如 `#x0509300a`);目前值在 `ParameterValues/Value`,依型別是 `<Value>`、`<EnumText>` 或 `<String>`(NTP 的 `ServerName` 是 `<String>ntp.beckhoff-cloud.com</String>`);struct 成員是 `ServerPara.bEnable` 這種點號名稱。
  - Context 設定後:`<Contexts><Context><Id>1</Id><ManualConfig><OTCID>#x02010030</OTCID></ManualConfig></Context></Contexts>`。
  - `ExportXml($false)` 回 `<TcModuleInstance>` 根(21.8 KB),和 ProduceXml 的 `TcModuleInstance` 段相同結構。
- 出處：實測 2026-11-01 4026 VS2022(p08)。
- 對 cmdlet 設計的影響:`Get-TcComParameter -Name` 可以做:`Parameters/Parameter[Name]` → `PTCID`(轉 uint32)、`BaseType`、`BitSize`;值從 `ParameterValues` 讀做顯示，**寫入一律走 SetModulePara**(研究文件的結論不變)。

### 11. ModuleManager 與 Get/SetModulePara

- 結論:
  - `$sm.GetModuleManager()` OK(20 ms),`ModuleCount = 9`、`Modules.Count = 9`(包含 PLC instance `AxisInterface Instance` oid `0x08502000`)。
  - **`foreach ($mi in $mm)` 列舉不到東西**(每筆屬性都是空的)。`for ($i = 0; $i -lt $mm.Modules.Count; $i++) { $mm.Modules.Item($i) }` 可以(index 從 0 開始),每筆有 `ModuleInstanceName`、`ModuleTypeName`、`oid`、`ParentOID`;**`ClassID` 全部是空的**,PLC instance 的 `ModuleTypeName` 也是空的。
  - `LookupModule('TcNtpExternalTimeProvider')` → late binding 選到 v1 的 `LookupModule(UInt32 oid, …)` 簽名，字串無法轉換;`TryLookupModule` 找不到 3 參數的多載。**v2 的 by-type lookup 在 PowerShell late binding 叫不到**,要用 `Modules.Item(i)` 自己比對 `ModuleTypeName`。
  - module tree item 上可以直接呼叫 `GetModulePara` 等方法(`Get-Member` 只看得到 `PvParameter` / `PvSParameter`,但呼叫可以成功):

| 呼叫 | 結果 |
|---|---|
| `GetModulePara(0x05093009)`(Velocity) | `byte[]` 8 bytes `0000000000409F40` = 2000.0 |
| `GetTypeOfModulePara(0x05093009).Name` | `LREAL`(還有 `ByteSize`、`BaseType`、`IecDeclaration` 等屬性) |
| `GetModuleParaDWORD(0x05093009)`(8 bytes) | `0x80070057` 值未落在預期的範圍內 |
| `GetModulePara(0x0BADBAD0)` | `0x80004005 E_FAIL` |
| `SetModulePara(pid, [byte[]]BitConverter(123.5))` | OK,讀回 123.5 |
| `SetModulePara(pid, [byte[]](1,2,3,4))`(大小不符) | `0x98110705`(ADS_E_INVALIDSIZE) |
| `SetModulePara(pid, [double]9.25)` | OK,讀回 9.25(離線 Set 接受 8-byte scalar) |
| NTP `GetModuleParaDWORD(TimeType)` / `SetModuleParaDWORD(…, 2)` | 3 → 2,ParameterValues 變 `<EnumText>Medium</EnumText>` |
| NTP `GetTypeOfModulePara(TimeType).Name` | `TimeType`(enum 型別名，不是 DINT) |
| NTP ClientEnable(BOOL) | `GetModulePara` 1 byte `01`;`SetModulePara([byte[]](0))` → `00` |

  - Set 之後 `ProduceXml` 的 `ParameterValues` 立刻反映。離線 Set **不寫任何檔**(只有 `.~u` 變動),要 Save 才進 `.tsproj` / `.xti`。
- 出處：實測 2026-11-01 4026 VS2022(p08、p20)。手冊 §5.31–5.33。
- 對 cmdlet 設計的影響:
  - `Get-TcComModule` 用 `Modules.Item(i)`,不要用 foreach / LookupModule(v2)。`classId` 從 tree item ProduceXml 的 `Module/@GUID` 取，因為 ModuleManager 的 `ClassID` 是空的。
  - `Set-TcComParameter` 一律轉成 `byte[]`(依 `BitSize` / `GetTypeOfModulePara`)再 SetModulePara,讀回比對 bytes;0x98110705 → `TCCOM_PARAM_SIZE_MISMATCH`,E_FAIL → `TCCOM_PARAM_NOT_FOUND`。
  - enum 參數 `GetTypeOfModulePara.Name` 是 enum 名稱，轉換前要用 `Parameters/Parameter/BitSize` 決定大小。
  - 離線寫入後記錄 BUILD_REQUIRED / 未存檔狀態。

### 12. Set/GetModuleContext

- 結論:
  - `SetModuleContext(0, PlcTaskOid)`、`GetModuleContext(0, [ref]$o)` 對 NTP 都回 `0x80070057 Context ObjectId not found`。**index 是 TMC 的 Context `Id`**:NTP 的 context Id 是 1,`SetModuleContext(1, 0x02010030)` OK(39 ms),`GetModuleContext(1, [ref]$o)` 讀回 `0x02010030`。
  - PowerShell 呼叫方式:`$o = [uint32]0; $item.GetModuleContext(1, [ref]$o)` 可用;單參數 retval 形式找不到多載。
  - NC SAF task 的 oid `0x05000010` 也可以設;不存在的 oid `0x01234567`、axis oid `0x05010010` → `0x80004005 E_FAIL`(和手冊 p.141「oid 不是合法 task」一致)。
  - task oid 從 task ProduceXml `TreeItem/ObjectId`(`#x02010030`)轉 16 進位。
- 出處：實測 2026-11-01 4026 VS2022(p08、p09)。手冊 §5.33.2 p.140–141。
- 對 cmdlet 設計的影響:`Add-TcComModule -Task` 不能寫死 index 0;要從 ProduceXml `Module/Contexts/Context/Id` 取第一個(或唯一)context Id,沒有 context 的 module(TcJobPool)要回錯誤或忽略 `-Task`。0x80070057 → `TCCOM_CONTEXT_INVALID`(index 錯),E_FAIL → 同碼但訊息說 task oid 不合法。

### 13. Online 參數(Run)

- 結論(NTP `NtpOnline`,oid `0x01010010`,ClientEnable FALSE、PollInterval 離線設 4321、context = PlcTask;Activate 後 PLC Run):

| 呼叫 | 結果 |
|---|---|
| `$mm.GetOnlineModulePara(oid, 0x03150105, 1024)` | 4 bytes = 4321 |
| 其他 pid(TraceLevelMax、TimeType、ClientEnable、ClientDiag 80 B、ServerInfo 88 B) | 都讀得到，長度 = 實際大小(maxData 可以給大) |
| pid 0 / 1 | `0x98110703`(ADS 0x703 IndexOffset invalid) |
| `GetOnlineModulePara(…, maxData 2)`(太小) | `0x98110705` |
| 不存在的 oid | `0x9811071D` |
| `SetOnlineModulePara(oid, pid, [uint32]5555)` | OK,online 讀回 5555 |
| `SetOnlineModulePara(oid, pid, [byte[]]…6666)` | OK |
| `SetOnlineModuleParaDWORD(oid, pid, 7777)` | OK |
| `SetOnlineModulePara(… [byte[]](1,2))` / `[double]1.5` | `0x98110705`(大小不符;**8-byte scalar online 不接受**) |
| online 寫入後的離線值 / ProduceXml | 仍是 4321(online 寫入不改專案) |
| raw ADS **port 10**,IG = oid、IO = pid | 讀到 7777,和 ModuleManager 一致 |
| raw ADS port 10,IG = PlcTask / NC task oid,IO = `0x02001001`(CycleTime) | 2000000(ModuleManager 也一樣) |

  - 其他 port 試 IG = oid:11、350 回 0x703,20 回 0x6(port 不存在),100、300 回 0x701,200 回 0x702。
  - 最後把 online 值寫回 4321。
- 出處:port 10 = TCom server:[InfoSys ADS device identification](https://infosys.beckhoff.com/content/1033/tc3_grundlagen/116159883.html)、[AmsPort Enumeration(R0_TComServer = 10)](https://infosys.beckhoff.com/content/1031/tcadsnetref/7313155211.html);手冊 §5.31.1.1 p.130(IG = oid、IO = pid);呼叫結果實測 2026-11-01 4026 + UmRT(p22)。
- 對 cmdlet 設計的影響:
  - `AMSPORT_R0_TCOMSERVER = 10` 確認。`Get-TcComParameter -Online` 兩條路都可行;建議走 ADS port 10(不需要 IDE,和 repo 的 ADS client 一致)。
  - online 寫入大小要剛好等於參數大小(scalar 最多 4 bytes 的手冊說法在 Set 上成立),一律轉 `byte[]`。
  - 0x98110703 → `TCCOM_PARAM_NOT_FOUND`、0x9811071D → `TCCOM_OBJECT_NOT_FOUND`(新碼候選)、0x98110705 → `TCCOM_PARAM_SIZE_MISMATCH`。
  - **probe 過程的教訓**:PowerShell 的 `$pid` 是唯讀自動變數(目前行程 id),腳本裡用 `$pid` 當參數 id 會被靜默忽略。第一輪 online 結果因此無效、已重測。cmdlet 實作的參數名稱不要用 `Pid`/`$pid`(用 `ParameterId`)。

### 14. ExportTmc / ReloadTmc

- 結論(4026 XAE 3.1.4026.22,離線):
  - `ConsumeXml('<TreeItem><ExportTmc Path="<scratch>\ntp-export.tmc"/></TreeItem>')` OK(57 ms),檔案 25,380 bytes。
  - `ConsumeXml('<TreeItem><ReloadTmc>true</ReloadTmc></TreeItem>')` OK(37 ms);reload 後 TimeType(先前設 2)和 context(NC task oid)都保留。
  - `<ReloadTmc Path="<匯出的 tmc>" Mode="warm">true</ReloadTmc>` OK。
  - `Path="C:\nope\x.tmc"` → `0x80004005 ConsumeXml '...' failed. Couldn't reload tmc! Error parsing: TreeItem/ReloadTmc`。
  - `Mode="bogus"` → **OK**(不驗證 Mode)。
  - 都不寫專案檔(只有 `.~u`)。
- 出處：手冊 §6.7.3 p.280(4024.10 起);結果實測 2026-11-01 4026 VS2022(p09)。4024 沒測。
- 對 cmdlet 設計的影響:`Update-TcComTmc -Mode` 要自己用 `ValidateSet('warm','cold','origin')` 檢查;ExportTmc 備份可以照研究文件做。

---

## 4.3 Variant management

### 15. 4024 late-bind

- 結論:**4024.71 的 32-bit XAE Shell 可以 late-bind** `CurrentProjectVariant`、`ProjectVariantConfig`、`ProjectVariantItems`、`PinnedTcVersion`;寫入 `ProjectVariantConfig`(93 ms)和 `CurrentProjectVariant = 'V4024'`(191 ms)都成功、讀回正確。
  - 版本：專案 `TcVersion="3.1.4024.71"`。本機 GAC 有 `TCatSysManagerLib` 2.1.0.0 / 3.1.0.0 / 3.2.0.0 / 3.3.0.0;`Components\TcBlockDiagram\Common\TCatSysManagerLib.dll` 是 assembly 3.4.0.0(file 3.4.1.24)。COM late binding 走 IDispatch,看不出 4024 XAE 實際實作的介面版本，只能確認「4024.71 能呼叫」。
- 出處:4024 起支援:VM 手冊 p.7、[InfoSys Variant management Concept](https://infosys.beckhoff.com/content/1033/variant_management/6325752587.html);§6.12.1 p.296(ITcSysManager14);呼叫結果實測 2026-11-01 4024 XAE Shell(p30)。
- 對 cmdlet 設計的影響:`Get-TcProjectVariant` 的 `supported` 在 4024.71 / 4026.22 都是 true;late-bind 失敗(更舊的 4024 sub-build)才回 `VARIANT_NOT_SUPPORTED`。

### 16. 沒有 variant 時的原值

- 結論:
  - 4026.22:`CurrentProjectVariant`、`ProjectVariantConfig`、`ProjectVariantItems`、`PinnedTcVersion` 都是**空字串**(len 0)。
  - 4024.71:`CurrentProjectVariant`、`PinnedTcVersion` 是空字串，**`ProjectVariantConfig`、`ProjectVariantItems` 是 `$null`**。
  - 有 variant config 之後 `ProjectVariantItems` 是 `<?xml version="1.0"?><ProjectVariants/>`。
- 出處：實測 2026-11-01 4026 VS2022(p10)、4024 XAE Shell(p30)。
- 對 cmdlet 設計的影響:`Get-TcProjectVariant` 要把 `$null` 和空字串都當成「沒有 variant」。

### 17. 寫入與覆蓋

- 結論:
  - 寫入手冊範例(1 個 group、3 個 variant)後讀回**和寫入的字串完全相同**:沒有自動加 `[All]` group,沒有 build settings 相關元素。寫入後 `CurrentProjectVariant` 仍是空字串(不會自動選第一個)。
  - 再寫一份只有 `OnlyOne` 的 XML → 讀回只剩 `OnlyOne`:**整份覆蓋**。
  - **覆蓋後 `CurrentProjectVariant` 仍是 `Variant1`**(已經不在 config 裡的名稱，沒有被清掉)。
  - 不合法 XML(`<ProjectVariants><Variant>`)、錯的根(`<Foo/>`)→ `0x80004005 E_FAIL`,原值不變。
- 出處：實測 2026-11-01 4026 VS2022(p10)。手冊 §6.12.1 p.296 沒寫覆蓋或合併。
- 對 cmdlet 設計的影響:
  - `Add-TcProjectVariant` 照研究文件做「讀出 → 加一筆 → 整份寫回 → 讀回」。
  - 移除 variant 時，如果被移除的是 current,要自己把 current 改掉(XAE 不會)。
  - `[All]` 不是自動 group(和 VM p.7 寫的「建第一個 variant 時自動加入 [All]」不同;可能是 XAE UI 才會加)。

### 18. 錯誤名稱、group、Activate、存放位置

- 結論:
  - `CurrentProjectVariant = 'NoSuch'` → E_FAIL;`'variant2'`(大小寫錯)→ E_FAIL(**大小寫敏感**);`'[All]'` → E_FAIL;`'[Group1]'` → OK,讀回 `[Group1]`;`''` → OK,讀回空字串;`'Variant2'` → OK。每次切換 85–230 ms。
  - **group 狀態下**:`Build-TcProject` 成功(6.1 s,errors 0,coverage complete);`Enable-TcConfig -Force -NoLogin` → XAE 的 Activate **沒有拋例外**(`activated = true`),XAE 寫出 `_Boot\[Group1]\TwinCAT OS (x64)\...` 一整套 boot 檔;模組回 `BOOT_PACKAGE_MISMATCH`,runtime 停在 Config。沒有 dialog。group 的 boot 包有沒有寫到 target:之後的 Variant1 Activate 覆蓋了 target,這次分不出來(未確認)。
  - **對照組(Variant1,不是 group)也一樣失敗**:`Enable-TcConfig -Force`(11.8 s)→ `BOOT_PACKAGE_MISMATCH`,runtime 停在 Config。檢查磁碟後確認是**模組誤報**(見下方 bug)。
  - 存放位置(存檔後的 `.tsproj`):根元素多一個 attribute `TcProjectVariant="Variant1"`,`<Project>` 裡多一段:

```xml
<Variants SpecificLocalBootFolder="true">
  <Group><Name>Group1</Name><Member>Variant1</Member><Member>Variant2</Member></Group>
  <Variant><Name>Variant1</Name></Variant> ...
</Variants>
```

  - item 層的 variant 設定存在**該 item 所在的檔**:這次 NC 開了 independent file,`Axis 3` 的設定存在 `_Config\NC\NC.xti` 的 `<ProjectVariant PvUseDisable="true" PvUseParameter="true"><Variant><Name>Variant1</Name>…</Variant>…</ProjectVariant>`。
- **Bug(模組):專案有 variant 時 `Enable-TcConfig` 必定誤報 `BOOT_PACKAGE_MISMATCH`**
  - 原因:`Variants SpecificLocalBootFolder="true"` 時，XAE 把 boot 包寫到 `_Boot\<Variant>\<Platform>\`(group 時是 `_Boot\[Group1]\<Platform>\`),模組仍比對 `_Boot\<Platform>\`(舊的)。實測 target `Boot\CurrentConfig.xml`、`CurrentConfig.tszip`、`Plc\Port_851.app` 的 SHA-256 前 12 碼 `A9067E84869F`、`2616CC852FA2`、`C8743D6BD7CF`,**和 `_Boot\Variant1\TwinCAT OS (x64)\` 完全相同**,和 `_Boot\TwinCAT OS (x64)\` 不同。target 其實是對的。
  - 影響：模組在 boot 比對失敗後停下,**不做 restart / login**,runtime 停在 Config(`restarted = false`)。
  - 重現:4026 副本 → `$sm.ProjectVariantConfig = '<ProjectVariants><Variant><Name>Variant1</Name></Variant></ProjectVariants>'` → `$sm.CurrentProjectVariant = 'Variant1'` → `Build-TcProject` → `Enable-TcConfig -Force` → `BOOT_PACKAGE_MISMATCH`;`Get-TcSystemState` = Config。
  - 修法方向:boot 比對的本機目錄要依 `CurrentProjectVariant` 決定(`_Boot\<variant>\<platform>`),或讀 `.tsproj` 的 `Variants/@SpecificLocalBootFolder`。這要另開 issue,第 3 期 variant 做之前必須先修。
- 出處:group 不能 activate:VM p.7;其餘實測 2026-11-01 4026 VS2022 + UmRT(p10、p11、p23、p24)。
- 對 cmdlet 設計的影響:
  - `Set-TcProjectVariant` 讀回比對要**大小寫敏感**;E_FAIL 回 `VARIANT_NOT_FOUND`(名稱不在 config)。
  - `VARIANT_GROUP_ACTIVE` 前置檢查一定要做:XAE 自己**不擋** group 狀態的 Build / Activate。
  - 先修上面的 boot 目錄 bug,否則 variant 專案無法用 `Enable-TcConfig`。
  - D2 備份要備份 `.tsproj`(config / current)和 item 所在的 `.xti`(item 層設定)。

### 19. PvDisable 切換

- 結論(`TINC^NC-Task 1 SAF^Axes^Axis 3`,4026 沒有 I/O device,改用 NC axis):
  - 初始 `PvDisable/PvParameter/PvLink = False`、`Disabled = 0`。`PvDisable = $true`(162 ms)→ 在 Variant1 設 `Disabled = 1` → 切 Variant2 讀到 `Disabled = 0` → 切回 Variant1 讀到 `Disabled = 1`。
  - `ProjectVariantItems`:`<ProjectVariants><Item Name="TINC^NC-Task 1 SAF^Axes^Axis 3" PvUseDisable="true"><Variant><Name>Variant1</Name><Disable>true</Disable></Variant><Variant><Name>Variant2</Name><Name>Variant3</Name><Disable>false</Disable></Variant></Item></ProjectVariants>`(同值的 variant 合併成一個 `<Variant>` 多個 `<Name>`)。
  - axis ProduceXml 只有 `<Disabled>true</Disabled>`,看不到 Pv 旗標。
  - `PvParameter = $true` 後，用 ConsumeXml 改 `Velo/Maximum` 為 111,切到 Variant2 讀到的**也是 111**:NC axis 參數透過 ConsumeXml 改時**不是**依 variant 分開存(PvParameter 對 NC axis 參數的實際作用這次沒查清楚)。`ProjectVariantItems` 只多了 `PvUseParameter="true"`。
- 出處:用法:手冊 §6.12.1 p.296;結果實測 2026-11-01 4026 VS2022(p10)。
- 對 cmdlet 設計的影響:variant 相關 tool 第 3 期只做 `Disabled`(PvDisable);variant 參數(PvParameter)行為不明，不要開放。I/O item 的 PvDisable 沒測(4026 沒 I/O,4024 沒做)。

---

## 4.4 Independent project file

### 20. SaveInOwnFile

- 結論(4026,getter 初值全部 False):

| item | set true 讀回 | 寫出的檔 |
|---|---|---|
| PLC project `TIPC^AxisInterface` | True | `_Config\PLC\AxisInterface.xti` |
| NC axis `...^Axis 1` | True | `_Config\NC\Axes\Axis 1.xti` |
| NC task `TINC^NC-Task 1 SAF` | True | `_Config\NC\NC.xti` |
| TcCOM `...^NtpProbe (TcNtpExternalTimeProvider)` | True | `_Config\TcCOM Objects\NtpProbe (TcNtpExternalTimeProvider).xti` |
| task `TIRT^PlcTask` | **False**(setter S_OK) | 無 |
| `...^Axes`、`TINC`、`TIRR` | **False**(setter S_OK) | 無 |
| 4024:I/O device `TIID^Device 1 (EtherCAT)` | True | `_Config\IO\Device 1 (EtherCAT).xti` |
| 4024:task `TIRT^PlcTask` | False | 無 |

  - **set true 的當下就寫出 `.xti`**(還沒 Save 就出現在磁碟上;4024 的 I/O device 也是)。之後 `Project.Save()`(310 ms)改寫這些 `.xti`、`.tsproj`,並產生 `.xti.bak` / `.tsproj.bak`。
  - `.tsproj` 改成參照:`<Module File="NtpProbe (TcNtpExternalTimeProvider).xti"/>`、`<NC File="NC.xti"/>`、`<Project File="AxisInterface.xti"/>`。
  - 對 NC axis、TcCOM 設回 False + Save(81 ms)→ **`Axis 1.xti`、`NtpProbe ….xti` 和它們的 `.bak` 被刪除**,內容回到 `NC.xti` / `.tsproj`。
  - 沒有出現「Enable Multiple Files」相關 dialog(全域選項狀態沒查)。
- 出處:「setter 對不支援的 item 回 S_OK」:手冊 §5.2.4 p.62(實測吻合);PLC / NC axis / I/O device 可以獨立存檔:[InfoSys Source control Project settings](https://infosys.beckhoff.com/content/1033/tc3_sourcecontrol/767894795.html);寫檔時機與刪檔行為實測 2026-11-01 4026 VS2022(p11)、4024 XAE Shell(p30)。
- 對 cmdlet 設計的影響:
  - `Set-TcIndependentFile` 讀回 getter 不變 → `INDEPENDENT_FILE_UNSUPPORTED`(task、Axes、TINC、TIRR 是實例)。
  - **D2 備份要在設定之前做**:setter 本身就改磁碟，不是等 Save。
  - 關閉時 XAE 會刪 `.xti`:tool 的 data 要列出 `removedFiles`;`Find-TcTreeItemDiskFile` 要能處理「檔案已經不在」。
  - 不需要 `Reset-TcSolution`(XAE 自己寫的檔)。

### 21. ProduceXml 欄位與 mapping 位置

- 結論:
  - PLC project 和 NC axis 的 ProduceXml 裡**沒有** SaveInOwnFile / independent 之類的欄位(只有 `CopyBootFiles`、`TmcFileCopy`、`FileArchiveSettings` 等無關元素)→ 不能用 `Set-TcTreeItemXml`。
  - PLC 開了 independent file 之後，PLC instance 的 mapping 從 `.tsproj` 移到 `_Config\PLC\AxisInterface.xti` 的 `<Mappings><OwnerA Name="AxisInterface Instance">…`(baseline `.tsproj` 有 2 個 `OwnerA`,存檔後 0 個)。`ProduceMappingInfo` 不受影響。
- 出處:「PLC links 改存在 PLC 的 XTI」:[InfoSys Command Independent project file](https://infosys.beckhoff.com/content/1033/tc3_userinterface/7738192779.html)(實測吻合);實測 2026-11-01 4026 VS2022(p11)。
- 對 cmdlet 設計的影響:`GetTreeItem` 擴充 `saveInOwnFile` 要讀 COM 屬性，不是 XML。D2 備份 mapping 時要看 PLC 是否 independent,決定備份 `.tsproj` 還是 `<Plc>.xti`。

---

## 4.5 ADS route(只做唯讀)

### 22. TIRR ProduceXml

- 結論:`LookupTreeItem('TIRR')` → `ItemName = Routes`(手冊寫「Route Settings」)、`ItemType 31`、`ChildCount 0`。ProduceXml **沒有任何 Password / Pwd 元素**(用 regex `(?i)<[^>]*(pass|pwd)[^>]*>` 檢查，target 為 UmRT 和本機兩種情況都是 false)。內容依 target 不同:

```xml
<!-- target = UmRT 199.5.42.250.1.1 -->
<RoutePrj><Target>199.5.42.250.1.1</Target><UseRelativeNetIds>false</UseRelativeNetIds>
  <ActualRoutes/><StaticRoutes/><ProjectRoutes/>
  <TargetList><BroadcastSearch>false</BroadcastSearch><Search></Search></TargetList></RoutePrj>

<!-- target = 本機(SetTargetNetId(""),NetId 192.168.50.168.1.1);名稱與 IP 換成 <…> -->
<RoutePrj><Target>192.168.50.168.1.1</Target><UseRelativeNetIds>false</UseRelativeNetIds>
  <ActualRoutes><Route><Name><route1></Name><NetId>169.254.215.73.1.1</NetId></Route><Route><Name><route2></Name><NetId>199.4.42.250.1.1</NetId></Route></ActualRoutes>
  <StaticRoutes><Route><Name><route1></Name><Address><ip></Address><NetId>169.254.215.73.1.1</NetId><Type>TCP_IP</Type><Flags>32</Flags></Route>
                <Route><Name><route2></Name><Address><ip></Address><NetId>199.4.42.250.1.1</NetId><Type>TCP_IP</Type></Route></StaticRoutes>
  <ProjectRoutes/><TargetList><BroadcastSearch>false</BroadcastSearch><Search></Search></TargetList></RoutePrj>
```

  - 讀到的是**目前 target**(SetTargetNetId)的 route 表:UmRT 的 route 表是空的。`StaticRoutes` 的內容和 XAR 的 `StaticRoutes.xml` 一致(第 26 題),多了 `Flags`。
  - TIRR 的 XML 和 `StaticRoutes.xml` 都沒有 static / temporary 的欄位;`Flags` 可能是相關的位元(未查)。
- 出處:實測 2026-11-01 4026 VS2022(p12、p13)。手冊 §6.3.17 p.221 的 `<Route>` 範例只有 Name / Address / NetId / Type。
- 對 cmdlet 設計的影響:
  - `Get-TcAdsRoute` 可以直接用 TIRR ProduceXml(`ActualRoutes` + `StaticRoutes` + `ProjectRoutes`),而且要讓呼叫端知道它讀的是目前 target(`data.target`)。
  - 本機讀到的 TIRR 沒有密碼，但 AddRoute 之後會不會讀回密碼沒測(第 24 題),所以研究文件的統一遮罩照樣要做。
  - `TreeItemPath.ps1` 補 `TIRR` 時，顯示名稱是 `Routes`。

### 23. Broadcast search / Search

- 結論:
  - target = UmRT(`199.5.42.250.1.1`)時:`<BroadcastSearch>true</BroadcastSearch>` → `0x80004005 ConsumeXml 'TIRR' failed. Broadcast search only works on local target system. Please change target system to local system! Error parsing: TreeItem/RoutePrj/TargetList/BroadcastSearch`(27 ms);`<Search>…</Search>` 同樣失敗("Search only works on local target system")。
  - `SetTargetNetId('')`(498 ms,變成本機 `192.168.50.168.1.1`)之後:BroadcastSearch **同步執行約 4.06 s** 回 S_OK;`Search` 127.0.0.1 / 本機 hostname / 不存在的 `192.0.2.123` 都是約 4.05 s 回 S_OK。**之後 ProduceXml 的 `TargetList` 仍是空的**(`<BroadcastSearch>false</BroadcastSearch><Search></Search>`),沒有任何 `<Target>`,連本機 / UmRT 都沒有。
  - 搜尋完用 `SetTargetNetId('199.5.42.250.1.1')` 還原(566 ms)。
  - 結果是空的可能是本機網路或防火牆，也可能 UmRT 不回 broadcast;這次沒辦法區分(需要第二台 target)。
- 出處:4020.10 起支援 Search:手冊 §6.3.11 p.212;結果實測 2026-11-01 4026 VS2022(p12、p13)。
- 對 cmdlet 設計的影響:
  - `Find-TcAdsTarget` 要先把 target 切到本機、做完切回原本的 target(用 finally),或在 target 不是本機時回明確錯誤碼(例如 `ROUTE_SEARCH_REQUIRES_LOCAL_TARGET`)。
  - 搜尋是同步的、固定約 4 s,不需要輪詢;`-TimeoutSec` 給 4 s 以上的餘裕。
  - **空結果不是錯誤**,但不能拿來證明「網路上沒有 target」;data 要寫 `targets: []` 並附註。

### 24. AddRoute 假密碼

- **未實測：改本機 route 表，留待有第二台 target。** 依指示沒有送 AddRoute。

### 25. AddProjectRoute

- **未實測：改本機 route 表，留待有第二台 target。** 依指示沒有送 AddProjectRoute。

### 26. StaticRoutes.xml 路徑與權限

- 結論(只讀、不改):

| 路徑 | 存在 | 內容 | 一般使用者權限 |
|---|---|---|---|
| `C:\TwinCAT\3.1\Target\StaticRoutes.xml`(手冊寫的路徑) | 否 | – | – |
| `C:\ProgramData\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml` | 否 | – | – |
| `%TWINCAT3DIR%\Target\StaticRoutes.xml` = `C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Target\StaticRoutes.xml`(XAR / TcSysSrv) | 是,548 bytes | 2 條 `<Route>`(Name / Address / NetId / Type / 其中一條有 Flags 32),**沒有密碼欄位** | SYSTEM、Administrators FullControl;**Users 只有 ReadAndExecute**;非管理員開 ReadWrite → 拒絕 |
| `C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\UmRT_Default\3.1\Target\StaticRoutes.xml`(UmRT) | 是,226 bytes | `<RemoteConnections>` 空的 | **Users FullControl**;非管理員開 ReadWrite 成功(只開不寫,mtime 沒變) |
| `...\Runtimes\UmRT_Template\3.1\Target\StaticRoutes.xml` | 是,226 bytes | 空的(範本) | – |

  - 4024 / 4026 在這台機器共用同一套 XAR(TwinCAT 3.1,`Components\Base` 有 4024.59 / 4024.71 / 4026.19 / 4026.20 / 4026.22),所以只有一份 XAR 的 StaticRoutes.xml。
  - 這次 PowerShell 不是系統管理員(`IsInRole(Administrator) = False`)。
- 出處:UmRT 的 Target 目錄路徑和 [InfoSys TF6310 UmRT 範例](https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/15569027467.html) 一致(研究文件引用);XAR 路徑與權限實測 2026-11-01 本機(TwinCAT 3.1,Windows 11)。
- 對 cmdlet 設計的影響:
  - `Remove-TcAdsRoute` 的檔案路徑要依 target 決定：本機 XAR 用 `%TWINCAT3DIR%\Target\StaticRoutes.xml`(要 admin;一般使用者 → `ROUTE_REMOVE_ACCESS_DENIED`),UmRT 用 `C:\ProgramData\Beckhoff\TwinCAT\3.1\Runtimes\<name>\3.1\Target\StaticRoutes.xml`(一般使用者可寫)。手冊的 `C:\TwinCAT\3.1\Target\` 在這台不存在，不要寫死。
  - 遠端 target 的 StaticRoutes.xml 無法用本機檔案操作，要另外設計(第 4 期)。

### 27. 第二台 target 的 AddRoute → Remove

- **未實測：改本機 route 表，留待有第二台 target。**

---

## 會改變 `research/phase3-api.md` 設計建議的發現

1. **NcAxisDef 在 ProduceXml 裡**(第 3 題):速度 / 加減速可以用通用 `Set-TcTreeItemXml`,研究文件「NcAxisDef 是命令型片段」要改。但 ConsumeXml 對錯值、錯元素、錯型別都回 S_OK,一定要讀回比對 + 送出前驗證。
2. **新軸預設就是 simulation**(第 2 題);`ChangeChildSubType` 是 E_NOTIMPL(第 4 題),型別切換改用 ConsumeXml 的 `DrvType` / `EncType` / `CtrType`,並檢查 `ItemSubTypeName` 非空。
3. **一個 TINC 只能有一個 NC task**(第 1 題):`Add-TcNcTask` 要回 `NC_TASK_ALREADY_EXISTS`;`NC_TASK_AMBIGUOUS` 實際上不會發生。
4. **XAE 不擋同名**:NC axis 同名會建出第二支;TcCOM 同名會自動改名 `_ObjN`(4024 甚至第一次就加);TcCOM 名稱一律加 ` (TypeName)`。cmdlet 要自己檢查同名、讀回實際名稱。
5. **TcCOM context index = TMC Context Id**(第 12 題),不是 0。
6. **ModuleManager 要用 `Modules.Item(i)`**;`LookupModule`(v2)在 late binding 叫不到;`ClassID` 是空的(第 11 題)。
7. **`AMSPORT_R0_TCOMSERVER = 10`**,online 參數可以直接用 ADS port 10(第 13 題)。
8. **Variant 專案的 boot 目錄是 `_Boot\<Variant>\<Platform>`,`Enable-TcConfig` 現在會誤報 `BOOT_PACKAGE_MISMATCH` 並停在 Config**(第 18 題，模組 bug,要先修)。XAE 不擋 group 狀態的 Build / Activate,`VARIANT_GROUP_ACTIVE` 前置檢查是必要的。
9. **`ProjectVariantConfig` 是整份覆蓋、不會自動加 `[All]`、覆蓋後 current 不會清掉**;variant 名稱大小寫敏感;4024 無 variant 時回 `$null`(第 16–18 題)。
10. **SaveInOwnFile 的 setter 當下就寫 `.xti`**,關閉 + Save 會刪檔(第 20 題):D2 備份要在 setter 之前。
11. **Broadcast / Search 只能在 target = 本機時做**,同步約 4 s(第 23 題):`Find-TcAdsTarget` 要切 target 再切回，或回明確錯誤。
12. **StaticRoutes.xml 的實際路徑**是 `%TWINCAT3DIR%\Target\`(XAR,要 admin)和 `ProgramData\...\Runtimes\<name>\3.1\Target\`(UmRT,一般使用者可寫),不是手冊的 `C:\TwinCAT\3.1\Target\`(第 26 題)。
13. TIRR 的 ItemName 是 `Routes`,讀到的是目前 target 的 route 表(第 22 題)。

## 發現的 bug(要另開 issue)

1. **`Enable-TcConfig` 對有 variant 的專案誤報 `BOOT_PACKAGE_MISMATCH`**:重現步驟和證據見第 18 題。影響：任何用了 variant management 的專案都無法用 `Enable-TcConfig` 完成 lifecycle(Activate 其實成功，但模組不 restart / login)。

## 還原與確認

- 開始前用 robocopy 把兩個副本複製到 `C:\Temp\Verify-4026-axis-baseline-phase3\`、`C:\Temp\Verify-4024-bfh-baseline-phase3\`,並用 `Get-ChildItem -Recurse -File -Force` 記錄逐檔 SHA-256(`manifest-Verify-4026-axis.csv` 266 檔、`manifest-Verify-4024-bfh.csv` 302 檔,在 scratchpad)。4024 副本開始前確認 Device 1 / Device 5 都是 `Disabled="true"`。
- 4026 離線題做完後先用 baseline `/MIR` 還原，再做 online 題。結束時兩個副本都用 baseline `/MIR` 還原，逐檔比對:
  - `Verify-4026-axis`:266 / 266 檔,**SHA-256 全部相同**,沒有多出或少掉的檔。
  - `Verify-4024-bfh`:302 / 302 檔,**SHA-256 全部相同**;Device 1 / Device 5 仍是 `Disabled="true"`。
- IDE:我啟動的三個 IDE 都用 `Disconnect-TcIde -Quit` 正常結束(VS2022 pid 39816、VS2022 pid 51676、4024 XAE Shell pid 109924),結束時沒有任何 `devenv` / `TcXaeShell` 行程。沒有 attach 或操作其他 IDE。
- 背景監看:`tests/Integration/Watch-Runtime.ps1`(pid 69360)從 02:33 跑到 02:55,log `runtime-watch.jsonl`。只有一筆 event:`02:46:00 pid-changed [] → [102904]`(我啟動 UmRT)。沒有 crash、bootdata 沒有變 0 byte。結束時只停了這個 watcher。
- **UmRT 最後狀態**:`TcSystemServiceUm` pid 102904 仍在跑(02:46 由我啟動),**AdsState = Config**。最後一次 Activate 寫進的是 4026 副本 Variant1 的 configuration(含 `NtpOnline` TcCOM 實例，ClientEnable FALSE),因為第 18 題的 bug,模組沒有切到 Run。下一個測試要用 `Enable-TcConfig -Force` 重新 Activate 自己的專案。
- 留下的檔:scratchpad 的腳本、log、匯出檔;兩個 baseline 目錄。UmRT 的 `Boot` 目錄被這次的 Activate 改寫(預期內)。

## 仍然未知

1. 從零建 NC task 的名稱(兩個副本都已有 task,建不出來)。
2. 模擬軸實際移動(要有 MC_Power / MC_MoveAbsolute 的測試 POU)。
3. raw NC ADS 的 `0x4101` 各 offset 的值語意(軸沒動，分不出來)。
4. variant group 狀態下 Activate 是否真的把 `[Group1]` 包寫進 target(被下一次 Activate 覆蓋了)。
5. `PvParameter` 對 NC axis 參數的作用;I/O item 的 PvDisable。
6. `LinkVariables` 對已經 link 到別處的變數的行為。
7. ReloadTmc / ExportTmc、variant 寫入在 4024 的行為(4024 只測了 late-bind 讀寫)。
8. Broadcast search 為什麼一台都找不到(需要第二台 target 才能判斷)。
9. 第 24、25、27 題(AddRoute、AddProjectRoute、Remove)。
10. 全部是自建 client 結果;實作後要用 registered tcauto 在 4026 VS2022 / 64-bit XAE Shell / 4024 重測。
