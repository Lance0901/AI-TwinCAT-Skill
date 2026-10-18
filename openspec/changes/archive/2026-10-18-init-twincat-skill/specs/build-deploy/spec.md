## ADDED Requirements

### Requirement: Build PLC project
The system SHALL trigger a build (compile) of the PLC project in TwinCAT IDE and return the build results.

#### Scenario: Successful build
- **WHEN** the user requests a build and the code has no errors
- **THEN** the system returns build success with warnings count (if any)

#### Scenario: Build with errors
- **WHEN** the build fails due to compilation errors
- **THEN** the system returns the error list with file, line number, and error message for each error

### Requirement: Activate TwinCAT configuration
The system SHALL activate the TwinCAT configuration to transition from Config mode to Run mode.

#### Scenario: Activate on local runtime
- **WHEN** the user requests activation and a local TwinCAT runtime is available
- **THEN** the system activates the configuration and confirms the runtime state transition

#### Scenario: Activation with restart prompt
- **WHEN** activation requires a TwinCAT system restart
- **THEN** the system informs the user and requests confirmation before proceeding

### Requirement: Set target system
The system SHALL allow setting the target TwinCAT runtime system (local or remote via AMS Net ID).

#### Scenario: Set local target
- **WHEN** the user specifies local target
- **THEN** the system sets the target to the local TwinCAT runtime

#### Scenario: Set remote target
- **WHEN** the user provides an AMS Net ID
- **THEN** the system sets the target to the specified remote system and verifies connectivity

### Requirement: Download PLC program
The system SHALL download (deploy) the compiled PLC program to the target runtime.

#### Scenario: Download after successful build
- **WHEN** the project has been built successfully and the user requests download
- **THEN** the system deploys the PLC program to the target runtime and confirms completion

#### Scenario: Download without prior build
- **WHEN** the user requests download but the project has not been built
- **THEN** the system triggers a build first, then proceeds with download if build succeeds
