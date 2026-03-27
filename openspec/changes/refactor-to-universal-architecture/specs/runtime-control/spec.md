## ADDED Requirements

### Requirement: PLC runtime state control
The system SHALL control the PLC runtime state (Run, Stop, Reset) independently of the download operation. The `Set-TcPlcState` cmdlet SHALL accept a target state.

#### Scenario: Start PLC runtime
- **WHEN** the user calls `Set-TcPlcState -State Run`
- **THEN** the system sets the PLC to Run mode via ADS state control and confirms the new state

#### Scenario: Stop PLC runtime
- **WHEN** the user calls `Set-TcPlcState -State Stop`
- **THEN** the system sets the PLC to Stop mode and confirms the new state

#### Scenario: Reset PLC runtime
- **WHEN** the user calls `Set-TcPlcState -State Reset`
- **THEN** the system resets the PLC (clears all variables to initial values) and confirms the new state

### Requirement: Get PLC runtime state
The system SHALL read the current PLC runtime state. The `Get-TcPlcState` cmdlet SHALL return the current state as a named value.

#### Scenario: Query running PLC
- **WHEN** the user calls `Get-TcPlcState` while PLC is running
- **THEN** the system returns `{"success": true, "data": {"state": "Run", "adsState": 5}}`

#### Scenario: Query stopped PLC
- **WHEN** the user calls `Get-TcPlcState` while PLC is stopped
- **THEN** the system returns `{"success": true, "data": {"state": "Stop", "adsState": 6}}`

### Requirement: PLC Login and Logout
The system SHALL provide independent Login and Logout operations for the PLC runtime, separate from the program download. Login MUST suppress all dialog popups for headless automation.

**Implementation note (verified 2026-03-27):** Use `ITcSmTreeItem::Login(3)` on the PLC Project tree item (e.g., `TIPC^LoggerPLC^LoggerPLC Project`). Flag 3 = CompileBeforeLogin(1) + SuppressAllDialogs(2). This also auto-triggers Download if the runtime has no program loaded. Do NOT use `ITcPlcProject::Login()` via `.Object` — the COM interface is unreliable.

#### Scenario: Login to PLC
- **WHEN** the user calls `Enter-TcPlcOnline`
- **THEN** the system logs into the PLC runtime via `ITcSmTreeItem::Login(3)` and returns the online status (no dialog popups)

#### Scenario: Logout from PLC
- **WHEN** the user calls `Exit-TcPlcOnline`
- **THEN** the system logs out from the PLC runtime and confirms disconnection

#### Scenario: Login when already online
- **WHEN** `Enter-TcPlcOnline` is called while already logged in
- **THEN** the system returns success with a note that it was already online

### Requirement: TwinCAT system state control
The system SHALL control the TwinCAT system state (Config mode vs Run mode) via ADS WriteControl on port 10000. MUST NOT use `ITcSysManager::StartRestartTwinCAT()` which triggers dialog popups.

**Implementation note (verified 2026-03-27):** Use `TcAdsClient.Connect(amsNetId, 10000)` then `WriteControl` with AdsState=16 (Reconfig) for Config mode, AdsState=2 (Reset) for Run mode. AmsNetId MUST be auto-detected via `ITcSysManager::GetTargetNetId()`.

#### Scenario: Switch to Run mode
- **WHEN** the user calls `Set-TcSystemState -State Run`
- **THEN** the system sends ADS WriteControl (AdsState=Reset) to port 10000, switching TwinCAT to Run mode (no dialog)

#### Scenario: Switch to Config mode
- **WHEN** the user calls `Set-TcSystemState -State Config`
- **THEN** the system sends ADS WriteControl (AdsState=Reconfig) to port 10000, switching TwinCAT to Config mode (no dialog)

#### Scenario: Query current system state
- **WHEN** the user calls `Get-TcSystemState`
- **THEN** the system returns the current TwinCAT system state (Config/Run/Error)
