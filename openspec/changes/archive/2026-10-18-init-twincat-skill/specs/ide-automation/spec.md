## ADDED Requirements

### Requirement: Connect to TwinCAT IDE instance
The system SHALL connect to a running TwinCAT 3 IDE instance (VS2022 or XAE Shell) via the Windows Running Object Table (ROT). If no running instance is found, the system SHALL launch a new IDE instance.

#### Scenario: Connect to existing VS2022 with TwinCAT
- **WHEN** a VS2022 instance with TwinCAT XAE is running
- **THEN** the system connects via ROT and returns the IDE version and open solution name as JSON

#### Scenario: Connect to existing XAE Shell
- **WHEN** a standalone TwinCAT XAE Shell instance is running
- **THEN** the system connects via ROT and returns the IDE version and open solution name as JSON

#### Scenario: No IDE instance running
- **WHEN** no TwinCAT IDE instance is detected
- **THEN** the system launches a new XAE Shell instance and waits until it is ready (max 60 seconds)

#### Scenario: TwinCAT not installed
- **WHEN** TwinCAT 3 XAE is not installed on the machine
- **THEN** the system returns an error with installation guidance

### Requirement: List available IDE operations
The system SHALL provide a discoverable list of all supported IDE operations with their parameters and descriptions.

#### Scenario: Query available operations
- **WHEN** the user asks what TwinCAT operations are available
- **THEN** the Skill returns a categorized list of operations (project, PLC, I/O, build/deploy)

### Requirement: JSON-based communication
All PowerShell scripts SHALL output results as JSON objects containing at minimum a `success` boolean and either a `data` object or an `error` object with a `message` field.

#### Scenario: Successful operation
- **WHEN** a script completes successfully
- **THEN** the output is `{"success": true, "data": {...}}`

#### Scenario: Failed operation
- **WHEN** a script encounters an error
- **THEN** the output is `{"success": false, "error": {"message": "...", "code": "..."}}`
