# io: Read before scanning or linking I/O, or using the generic tree tools (IoScan, GetIoTree, SetVariableLink, ConsumeXml, CreateChild, DeleteChild).

## Steps
1. `IoScan` needs the target in Config mode (`IO_SCAN_REQUIRES_CONFIG` otherwise). Default only lists `data.devices`; `Apply=true` adds them.
2. `GetIoTree`: device tree with `disabled` / `disabledState`.
3. `SetVariableLink` PLC variable <-> I/O variable; read back.
4. `BuildProject` -> activate (GetGuide('deploy')): outputs switch on a real machine.

## Generic tree tools
`LookupTreeItem` / `ProduceXml` (read), `CreateChild` / `ConsumeXml` / `DeleteChild` / `ExportChild` / `ImportChild` (change). Use a dedicated tool when one exists. Changing tools dry-run by default: read `data.changes` / `data.plannedPath` first. Ask the user before deleting (`DeleteChild`, `RemoveVariableLink`). `data.verified=true` is success; `TREEITEM_VERIFY_FAILED` is not. Changes below TIPC record BUILD_REQUIRED.

## Tool reference
Full behaviour of the tools of this topic (their descriptions keep the short form).

### ConsumeXml
Generic tree tool that CHANGES the configuration: write an XML fragment into one tree item (ITcSmTreeItem.ConsumeXml, TE1000 v1.7.0 5.2.1.1). Prefer a dedicated tool when one exists. DryRun defaults to true: first call it without DryRun and read data.changes (path, current, planned, changed) and data.currentXml; then call again with DryRun=false. The fragment is sent as-is and XAE merges it (fields not in it keep their value; measured): root <TreeItem>, element paths exactly as in ProduceXml, only the fields to change, e.g. <TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem> (CycleTime unit 100 ns). XAE ignores unknown elements silently, so every leaf path must exist in the current XML, else XML_MERGE_FAILED (data.missingPaths, data.reason syntax / root / empty / paths-not-in-current-xml). Refused before sending because the XAE merge is not measured (XML_MERGE_FAILED): attributes-not-supported (only element values, no attributes; data.attributePaths), structure-mismatch (a value on an element that has child elements now, e.g. <TaskDef/> or <TaskDef>123</TaskDef>; data.structurePaths), repeated-count-mismatch (copy every repeated sibling, e.g. all CPU elements, in the current number; data.repeatedCountMismatches), derived-only (only TcModuleInstance Context / ParameterValues would change; data.derivedPaths). Known fields are validated by the module (TaskDef/CycleTime integer > 0, else TREEITEM_INVALID_VALUE). DryRun=false: ProduceXml backup (+ the node disk file such as <task>.TcTTO) to <solution dir>\.tcauto-backup\<yyyyMMdd-HHmmss>\ (data.backupPath, data.backupFiles, data.warnings), IDE_MODAL_DIALOG if a dialog is open (nothing sent), ConsumeXml, read back: every fragment leaf must have the planned value (derived fields excluded, data.mismatches expected / actual) and every other non-derived element / attribute of the whole XML must be unchanged (data.unexpectedChanges path / kind / before / after): data.verified=true, else TREEITEM_VERIFY_FAILED. Below TIPC records BUILD_REQUIRED code-changed.
