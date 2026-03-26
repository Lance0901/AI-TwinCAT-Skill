## MODIFIED Requirements

### Requirement: Build PLC project
The system SHALL build PLC projects using `ITcPlcProject::BuildProject()` and return build results including errors and warnings.

#### Scenario: Successful build
- **WHEN** the user calls `Build-TcProject`
- **THEN** the system invokes `ITcPlcProject::BuildProject()`, parses the build output, and returns `{"success": true, "data": {"errors": 0, "warnings": 0, "messages": [...]}}`

#### Scenario: Build with errors
- **WHEN** the build encounters compilation errors
- **THEN** the system returns `{"success": false, "error": {"message": "Build failed", "code": "BUILD_FAILED"}, "data": {"errors": 2, "warnings": 1, "messages": [...]}}`

### Requirement: Set target system
The system SHALL set the target AMS Net ID for deployment using `ITcSysManager`.

#### Scenario: Set local target
- **WHEN** the user calls `Set-TcTarget -AmsNetId "127.0.0.1.1.1"`
- **THEN** the system configures the TwinCAT project to target the local runtime

#### Scenario: Set remote target
- **WHEN** the user calls `Set-TcTarget -AmsNetId "192.168.1.100.1.1"`
- **THEN** the system configures the TwinCAT project to target the remote runtime

### Requirement: Activate TwinCAT configuration
The system SHALL activate the TwinCAT configuration using `ITcSysManager::ActivateConfiguration()`.

#### Scenario: Activate configuration
- **WHEN** the user calls `Enable-TcConfig`
- **THEN** the system calls `ITcSysManager::ActivateConfiguration()` and returns the activation result as JSON

#### Scenario: Activation requires restart
- **WHEN** the configuration activation requires a TwinCAT restart
- **THEN** the system returns a warning indicating a restart is needed and includes a `-Force` parameter option to auto-restart

### Requirement: Download PLC program
The system SHALL download the compiled PLC program to the target runtime using `ITcPlcProject`.

#### Scenario: Download to target
- **WHEN** the user calls `Send-TcPlcProgram`
- **THEN** the system uses `ITcPlcProject` to log in and download the program to the target runtime, returning the result as JSON

#### Scenario: Target not reachable
- **WHEN** the target system is not reachable via ADS
- **THEN** the system returns an error with code `TARGET_UNREACHABLE`
