# Integration scripts

These scripts need a real environment (TwinCAT XAE/IDE open plus UmRT or a real runtime) and a solution containing the expected PLC variables. They are manual diagnostics, not automated unit tests. Pass `-SolutionPath` to point at your own solution.

| Script | Purpose |
|---|---|
| `bool-write.ps1` | Compare BOOL write methods (`WriteAny` vs raw 1-byte ADS write) and monitor the result |
| `write-verify.ps1` | Show that an ADS write sticks on a standalone variable but not on an FB VAR_INPUT that MAIN rewrites each scan |
| `list-symbols.ps1` | List MAIN-level symbols to find writable variables (`Get-TcSymbols`) |
| `full-cycle.ps1` | Full build -> activate -> login -> ADS -> run -> test cycle |
| `build-errors.ps1` | Inject an undefined identifier into a POU, `Build-TcProject` must return `BUILD_FAILED` with `buildSucceeded=false` and `codeErrors` (file/line from the XAE Error List via `Get-TcBuildErrors`), restore, build again (`buildSucceeded=true`, `codeErrors` empty). **It modifies the POU file on disk** (XAE saves before build): the switch `-IUnderstandThisModifiesTheProject` is mandatory (exit 2 without it), a solution under OneDrive is refused (exit 3), and the POU is copied to `<POU>.TcPOU.bak-<timestamp>` before the injection and restored from it by file copy in a `finally` block (the .bak is deleted once the restore verified). Run it only against a local COPY of a solution; run under an outer deadline (e.g. `Start-Process powershell.exe -PassThru` + 300 s) because a full compile can pop the XAE "Assertion Failed" box (if the deadline kills the script the .bak stays next to the POU for a manual restore), and pass `-CleanCompileInfo` to delete `plc\_CompileInfo` first |
