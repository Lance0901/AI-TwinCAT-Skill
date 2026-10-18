## 1. P0-1 COM retry

- [ ] 1.1 Add `Private/Invoke-TcComRetry.ps1` (retry on RPC_E_CALL_REJECTED / RPC_E_SERVERCALL_RETRYLATER)
- [ ] 1.2 Route all DTE / ITcSysManager calls through `Invoke-TcComRetry`

## 2. P0-2 ADS reconnect and state wait

- [ ] 2.1 Add `Ensure-TcAdsConnection` (auto reconnect when the client is invalid)
- [ ] 2.2 Add `Wait-TcAdsState` and replace every `Start-Sleep` in lifecycle cmdlets

## 3. P0-3 Lifecycle gating

- [ ] 3.1 Rework `Enable-TcConfig -Force`: Activate -> wait 10000 Run -> Login -> wait 851 -> reconnect -> Run
- [ ] 3.2 `Set-TcPlcState Run` checks that the program is downloaded before starting

## 4. P0-4 Environment compatibility

- [ ] 4.1 ProgID resolution supports 15.0 (`TcXaeShell.DTE.15.0`)
- [ ] 4.2 Multiple IDE instances: select by SolutionPath
- [ ] 4.3 ADS DLL lookup includes the 4026 path

## 5. P0-5 Error hints

- [ ] 5.1 `New-TcResult -Hint`
- [ ] 5.2 `ConvertTo-TcAdsErrorCode`

## 6. Docs

- [ ] 6.1 SKILL.md Troubleshooting section
- [ ] 6.2 Setup scripts: write without BOM
- [ ] 6.3 `docs/troubleshooting.md`

## 7. Verification

- [ ] 7.1 4026 + VS2022 + UmRT: full lifecycle (see `tests/Integration/full-cycle.ps1`)
- [ ] 7.2 4024 + 32-bit XAE: full lifecycle
