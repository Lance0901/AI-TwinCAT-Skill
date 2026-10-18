## Why

Across roughly two months of sessions (701 events analysed), failures in the build -> activate -> login -> run lifecycle clustered into three root causes:

- **COM call rejected by modal dialog (RPC_E_CALL_REJECTED): 29%** - the IDE shows a modal dialog and DTE calls fail instead of waiting.
- **Stale ADS connection after Activate: 41%** - Activate restarts TwinCAT, the cached ADS client becomes invalid and is never re-established.
- **Lifecycle ordering with no gating: 29%** - steps run in the wrong order or before the previous one has settled (e.g. Run before Login/download).

Additionally, TwinCAT 4024 with the 32-bit XAE (`TcXaeShell.DTE.15.0`) is currently not supported for automatic launch.

## What Changes

- **P0-1**: `Invoke-TcComRetry` wraps every DTE/COM call with retry on RPC_E_CALL_REJECTED / busy conditions.
- **P0-2**: `Ensure-TcAdsConnection` reconnects ADS automatically; `Wait-TcAdsState` replaces every ad-hoc `Start-Sleep`.
- **P0-3**: `Enable-TcConfig -Force` becomes Activate -> wait for 10000 Run -> Login -> wait for 851 -> reconnect -> Run. `Set-TcPlcState Run` first checks that the program has been downloaded.
- **P0-4**: ProgID resolution supports 15.0; multi-instance selection driven by SolutionPath; ADS DLL lookup includes the 4026 path.
- **P0-5**: `New-TcResult -Hint` and `ConvertTo-TcAdsErrorCode` give actionable error hints.
- **Docs**: SKILL.md Troubleshooting section, setup scripts written without BOM, `docs/troubleshooting.md`.

## Impact

- `src/TwinCATAutomation/Public/*` and `Private/*` (lifecycle cmdlets, result helper)
- `adapters/claude/SKILL.md`, `TwinCATSetup-*.ps1`, `docs/troubleshooting.md`
