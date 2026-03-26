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
The system SHALL provide independent Login and Logout operations for the PLC runtime, separate from the program download.

#### Scenario: Login to PLC
- **WHEN** the user calls `Enter-TcPlcOnline`
- **THEN** the system logs into the PLC runtime via `ITcPlcProject` and returns the online status

#### Scenario: Logout from PLC
- **WHEN** the user calls `Exit-TcPlcOnline`
- **THEN** the system logs out from the PLC runtime and confirms disconnection

#### Scenario: Login when already online
- **WHEN** `Enter-TcPlcOnline` is called while already logged in
- **THEN** the system returns success with a note that it was already online

### Requirement: TwinCAT system state control
The system SHALL control the TwinCAT system state (Config mode vs Run mode) via `ITcSysManager` or ADS.

#### Scenario: Switch to Run mode
- **WHEN** the user calls `Set-TcSystemState -State Run`
- **THEN** the system switches TwinCAT to Run mode (equivalent to green TwinCAT icon)

#### Scenario: Switch to Config mode
- **WHEN** the user calls `Set-TcSystemState -State Config`
- **THEN** the system switches TwinCAT to Config mode (equivalent to blue TwinCAT icon)

#### Scenario: Query current system state
- **WHEN** the user calls `Get-TcSystemState`
- **THEN** the system returns the current TwinCAT system state (Config/Run/Error)
