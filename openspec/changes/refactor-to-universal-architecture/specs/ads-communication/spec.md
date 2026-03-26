## ADDED Requirements

### Requirement: Connect to ADS runtime
The system SHALL establish an ADS connection to a TwinCAT runtime using AMS Net ID and port number. The `Connect-TcAds` cmdlet SHALL support local (127.0.0.1.1.1) and remote targets, with default port 851 (PLC Runtime 1).

#### Scenario: Connect to local PLC runtime
- **WHEN** the user calls `Connect-TcAds` without parameters
- **THEN** the system connects to `127.0.0.1.1.1:851` and returns `{"success": true, "data": {"amsNetId": "127.0.0.1.1.1", "port": 851, "state": "Run"}}`

#### Scenario: Connect to remote PLC runtime
- **WHEN** the user calls `Connect-TcAds -AmsNetId "192.168.1.100.1.1" -Port 851`
- **THEN** the system connects to the remote runtime and returns the connection state

#### Scenario: Runtime not reachable
- **WHEN** the target ADS route is not reachable
- **THEN** the system returns an error with code `ADS_CONNECT_FAILED` and the ADS error code

### Requirement: Read PLC variables via ADS
The system SHALL read PLC variable values by symbol name using ADS symbol-based access. The `Read-TcVariable` cmdlet SHALL accept a variable path and return its current value and type.

#### Scenario: Read single variable
- **WHEN** the user calls `Read-TcVariable -Path "MAIN.nCounter"`
- **THEN** the system reads the variable via ADS and returns `{"success": true, "data": {"path": "MAIN.nCounter", "value": 42, "type": "INT"}}`

#### Scenario: Read multiple variables
- **WHEN** the user calls `Read-TcVariable -Path @("MAIN.nCounter", "MAIN.bRunning", "GVL.fTemperature")`
- **THEN** the system reads all variables in one call and returns an array of values

#### Scenario: Read structured variable
- **WHEN** the user calls `Read-TcVariable -Path "MAIN.stMotor"`
- **THEN** the system reads the entire struct and returns all fields as a nested JSON object

#### Scenario: Variable not found
- **WHEN** the specified variable path does not exist in the PLC symbol table
- **THEN** the system returns an error with code `SYMBOL_NOT_FOUND`

### Requirement: Write PLC variables via ADS
The system SHALL write values to PLC variables by symbol name. The `Write-TcVariable` cmdlet SHALL accept a variable path and a value.

#### Scenario: Write single variable
- **WHEN** the user calls `Write-TcVariable -Path "MAIN.nSetpoint" -Value 100`
- **THEN** the system writes the value via ADS and confirms with `{"success": true, "data": {"path": "MAIN.nSetpoint", "written": 100}}`

#### Scenario: Type mismatch
- **WHEN** the user writes a string value to an INT variable
- **THEN** the system returns an error with code `TYPE_MISMATCH`

### Requirement: Monitor PLC variables
The system SHALL support polling-based variable monitoring. The `Watch-TcVariable` cmdlet SHALL read specified variables at a given interval and return snapshots.

#### Scenario: Monitor variable for duration
- **WHEN** the user calls `Watch-TcVariable -Path "MAIN.nCounter" -IntervalMs 100 -DurationMs 2000`
- **THEN** the system reads the variable every 100ms for 2 seconds and returns an array of timestamped samples

#### Scenario: Monitor until condition met
- **WHEN** the user calls `Watch-TcVariable -Path "MAIN.bDone" -IntervalMs 50 -Until { $_.Value -eq $true } -TimeoutMs 5000`
- **THEN** the system polls until `bDone` becomes TRUE or timeout is reached, returning the final value and elapsed time

### Requirement: List PLC symbols
The system SHALL enumerate all available PLC symbols from the ADS symbol table. The `Get-TcSymbols` cmdlet SHALL return symbol names, types, and sizes.

#### Scenario: List all symbols
- **WHEN** the user calls `Get-TcSymbols`
- **THEN** the system returns a JSON array of all PLC symbols with path, type, size, and comment

#### Scenario: Filter symbols by pattern
- **WHEN** the user calls `Get-TcSymbols -Filter "MAIN.*"`
- **THEN** the system returns only symbols matching the pattern
