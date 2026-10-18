# Integration scripts

These scripts need a real environment (TwinCAT XAE/IDE open plus UmRT or a real runtime) and a solution containing the expected PLC variables. They are manual diagnostics, not automated unit tests. Pass `-SolutionPath` to point at your own solution.

| Script | Purpose |
|---|---|
| `bool-write.ps1` | Compare BOOL write methods (`WriteAny` vs raw 1-byte ADS write) and monitor the result |
| `write-verify.ps1` | Show that an ADS write sticks on a standalone variable but not on an FB VAR_INPUT that MAIN rewrites each scan |
| `list-symbols.ps1` | List MAIN-level symbols to find writable variables (`Get-TcSymbols`) |
| `full-cycle.ps1` | Full build -> activate -> login -> ADS -> run -> test cycle |
