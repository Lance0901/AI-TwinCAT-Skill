# TE1200 Static Analysis Light 量測(tasks 1a.9,design.md D11)

- 日期:2026-11-13(實測)
- 環境:Windows 11 Home 10.0.26200;TwinCAT XAE 3.1.4026.22(Remote Manager 3.1.4026.22);host VS2022 Community 17(`VisualStudio.DTE.17.0`);專案 = `C:\Temp\Verify-4026-axis` 的副本 `C:\Temp\lint-ide\axis`;registered tcauto(master runtime)
- 授權(只讀,未啟用任何 trial):本機只有 `C:\ProgramData\Beckhoff\TwinCAT\3.1\License\TrialLicense.tclrs`(ExpireTime 2026-11-05,已過期),內含 TC1000 / TC1100 / TC1200 / TE1300 / TF5000 / TF5050 / TF5055,**沒有 TE1200** → 本機沒有 Static Analysis Full 授權。

## 結論

| D11 問題 | 結論 | 依據 |
|---|---|---|
| 1. 新專案 / 既有專案是否預設啟用 Light | **既有專案:沒有啟用的效果**。axis 的 `.plcproj` 把 7 條 Light 規則都明寫成 `bActive=False`;把整個 Static Analysis 設定節點刪掉(= 從沒設定過的專案)後 Build,Error List **沒有任何 SA 列**,而同一份程式在規則啟用時有 192 條。bfh(4024 建的專案)的 `.plcproj` 也沒有這個節點。**新專案**:tcauto 沒有建新 PLC 專案的 tool,未測。 | 實測 sa1 / sa2(下方) |
| 2. 違規會不會出現在 `BuildProject` 的 errorItems | **會進 XAE 的 Error List,而且是 Error 等級,但不讓 Build 失敗**:sa2 的 build pane 是 `0 errors`、`BuildProject` 回成功(Error List 第一次讀取逾時 → `CODE_NOT_VERIFIED`);之後 `GetBuildErrors` 讀到 192 條 Error:`SA0033` ×191(全專案的未使用變數)+ `SA0167 Temporary function block instance: 'tTmp'`(F_SaTemp 宣告第 3 行)。植入的 `FB_SaUnused.nUnused` 有一條 `SA0033`。 | 實測 sa2 |
| 3. `.plcproj` 怎麼控制 | `<ProjectExtensions><PlcProjectOptions><XmlArchive>` 內 OptionKey `{29BD8D0C-3586-4548-BB48-497B9A01693F}` → `Rules` → 每條規則一個子鍵(`"4"`、`"6"`、`"27"`、`"28"`、`"33"`、`"167"`、`"175"`),值 `bActive` = `True` / `False`。片段見下。沒有這個節點時等同全部不啟用(實測)。 | axis `.plcproj`、實測 sa1 |
| 4. 4026.22 能否經 Automation Interface 取 SARIF | InfoSys:`ExportToSarif(exportPath)` 自 **3.1.4026.20**,範例用 `ITcPlcIECProject7`;`RunStaticAnalysis(bCompile)` 在 `ITcPlcIECProject3`;頁面**沒寫** Light 能不能用、要不要授權。**未實測**:tcauto 沒有對應 tool,本次規定只用 tcauto 的 IDE 操作,沒有用 raw COM 去呼叫。本機沒有 TE1200 授權。 | InfoSys(下方) |

**對 linter 的影響**:
- 客戶專案很可能根本沒啟用 Light(axis 明寫 False、bfh 沒節點)→ SCAN-TEMPFB-001 等與 Light 重疊的規則照原計畫要做。
- 就算啟用,Light 違規只是 Error List 的列,**Build 仍成功**;`BuildProject` 目前把它們算不算進 errorItems 取決於 Error List 讀取(本次第一次讀逾時)→ tasks 2.9 的 PROJECT-SA-001(檢查專案是否啟用)有依據,但「啟用就等於 Build 擋下」不成立。

### `.plcproj` 片段(axis,規則 33;其他規則同形,只有編號不同)

```xml
<v>{29BD8D0C-3586-4548-BB48-497B9A01693F}</v>
<o>
  <v n="Name">"{29BD8D0C-3586-4548-BB48-497B9A01693F}"</v>
  <d n="SubKeys" t="Hashtable" ckt="String" cvt="OptionKey">
    <v>NamingConventions</v>
    <o> ... </o>
    <v>Rules</v>
    <o>
      <v n="Name">"Rules"</v>
      <d n="SubKeys" t="Hashtable" ckt="String" cvt="OptionKey">
        <v>33</v>
        <o>
          <v n="Name">"33"</v>
          <d n="SubKeys" t="Hashtable" />
          <d n="Values" t="Hashtable" ckt="String" cvt="Boolean">
            <v>bActive</v>
            <v>False</v>
          </d>
        </o>
        ...(167、175、27、28、4、6)
```

### 實測步驟

- sa1:刪掉整個 `{29BD8D0C-…}` 節點;加 `F_SaTemp`(FUNCTION 的 `VAR` 內 `tTmp : TON`,SA0167 例)、`FB_SaUnused`(未使用的 `nUnused`,SA0033 例),由 `PRG_LintSa` 呼叫、`Main` 呼叫 `PRG_LintSa`。`ResetSolution` → `BuildProject`:成功,0 errors;`GetBuildErrors`:沒有任何 SA00 列。
- sa2:同樣程式,節點保留,規則 33 / 167 改 `bActive=True`。`BuildProject`:成功,pane `0 errors`,`CODE_NOT_VERIFIED`(Error List 讀取逾時);`GetBuildErrors` 第二次:192 條 SA Error(如上)。

## InfoSys 出處

| 事實 | 出處 |
|---|---|
| Light 在「編譯成功之後」自動執行;編譯失敗就不跑;違規以 error 出現在 Error List;規則在 PLC 專案屬性的 Static Analysis 類別設定 | [Code analysis (Static Analysis Light)](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2527107467.html) |
| Light vs Full:Light 自動執行、不可設定為手動;Full 可設定 "Perform static analysis automatically" 或手動執行 | [Range of functions: Static Analysis Light vs. Full](https://infosys.beckhoff.com/content/1033/tc3_plc_intro/21574414603.html) |
| `RunStaticAnalysis(bCompile)` 在 `ITcPlcIECProject3`(頁面寫自 Build 4023.103) | [Running static code analysis](https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842487563.html) |
| `Save/LoadStaticAnalysisSettings` 在 `ITcPlcIECProject4`(自 4026);`ExportStandardMetrics` 在 `ITcPlcIECProject5`(自 4026.4);`ExportToSarif(exportPath)` 自 **3.1.4026.20**(範例用 `ITcPlcIECProject7`);頁面沒寫授權需求 | [TE1200 Automation Interface support](https://infosys.beckhoff.com/content/1033/te1200_tc3_plcstaticanalysis/6894897803.html) |
| GUI 指令 "Run static analysis and export to Sarif file" 自 3.1.4026.20,輸出 `*.sarif.json`;頁面沒寫 Light 能不能用 | [Command 'Run static analysis and export to Sarif file'](https://infosys.beckhoff.com/content/1033/te1200_tc3_plcstaticanalysis/19465352843.html) |
