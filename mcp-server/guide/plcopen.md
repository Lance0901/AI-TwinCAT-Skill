# plcopen: Read before exporting or importing PLCopen XML (ExportPlcOpen, ImportPlcOpen).

## Steps
- Export: `ExportPlcOpen` (objects or the whole PLC project); the file is read back and its objects listed. Does not change the project.
- Import: `ImportPlcOpen` dry-run first: it lists the objects of the file, conflicts with the project and what `Option` will do; then `DryRun=false`. Afterwards `BuildProject` and `LintProject` (GetGuide('change-code')).

Overwriting existing objects is a change of the user's code: tell the user which objects the conflict list names before `DryRun=false`.
