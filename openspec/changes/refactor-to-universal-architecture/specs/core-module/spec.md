## ADDED Requirements

### Requirement: PowerShell module structure
The system SHALL be packaged as a PowerShell module (`TwinCATAutomation`) with a `.psm1` manifest, exported public cmdlets, and internal private helper functions.

#### Scenario: Import module
- **WHEN** a user runs `Import-Module TwinCATAutomation`
- **THEN** all public cmdlets (Connect-TcIde, New-TcProject, Add-TcPou, etc.) are available in the session

#### Scenario: Module help
- **WHEN** a user runs `Get-Help Connect-TcIde`
- **THEN** the system returns parameter documentation, description, and usage examples

### Requirement: Unified CLI entry point
The system SHALL provide a single-file CLI wrapper (`Invoke-TwinCATAutomation.ps1`) that accepts an operation name and JSON parameters, and returns JSON output.

#### Scenario: Invoke operation via CLI
- **WHEN** a caller runs `pwsh Invoke-TwinCATAutomation.ps1 --operation NewProject --params '{"name":"MyProject"}'`
- **THEN** the system imports the module, calls the corresponding cmdlet, and returns the result as JSON to stdout

#### Scenario: Invalid operation name
- **WHEN** a caller provides an unrecognized operation name
- **THEN** the system returns `{"success": false, "error": {"message": "Unknown operation: <name>", "code": "INVALID_OPERATION"}}`

#### Scenario: List available operations
- **WHEN** a caller runs `pwsh Invoke-TwinCATAutomation.ps1 --operation ListOperations`
- **THEN** the system returns a JSON array of all available operations with their parameter schemas

### Requirement: Standardized JSON output format
All cmdlets SHALL return a PSCustomObject that serializes to JSON with at minimum a `success` boolean and either a `data` object or an `error` object.

#### Scenario: Successful operation
- **WHEN** any cmdlet completes successfully
- **THEN** the output is `{"success": true, "data": {...}}`

#### Scenario: Failed operation
- **WHEN** any cmdlet encounters an error
- **THEN** the output is `{"success": false, "error": {"message": "...", "code": "..."}}`

### Requirement: Module-scoped connection state
The system SHALL store active IDE connection references (DTE, ITcSysManager) in module-scoped variables so that subsequent cmdlet calls reuse the same connection.

#### Scenario: Connection persists across cmdlet calls
- **WHEN** `Connect-TcIde` succeeds and a user subsequently calls `New-TcProject`
- **THEN** `New-TcProject` uses the existing connection without requiring reconnection

#### Scenario: No active connection
- **WHEN** a cmdlet requiring a connection is called without a prior `Connect-TcIde`
- **THEN** the system returns an error with code `NOT_CONNECTED` and message indicating `Connect-TcIde` must be called first
