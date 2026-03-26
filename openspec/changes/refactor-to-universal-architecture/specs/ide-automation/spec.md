## MODIFIED Requirements

### Requirement: Connect to TwinCAT IDE instance
The system SHALL connect to a running TwinCAT 3 IDE instance using TwinCAT Automation Interface. Connection SHALL obtain both the `EnvDTE` object and the `ITcSysManager` interface (via `$dte.Solution.Projects.Item(1).Object`). The `Connect-TcIde` cmdlet SHALL accept an optional `-ProgId` parameter (default: `TcXaeShell.DTE.17.0`, fallback: `VisualStudio.DTE.17.0`).

#### Scenario: Connect to existing XAE Shell
- **WHEN** a TwinCAT XAE Shell instance is running
- **THEN** the system connects via ROT using ProgID `TcXaeShell.DTE.17.0`, obtains `ITcSysManager`, and returns IDE version, ProgID, and open solution name as JSON

#### Scenario: Connect to existing VS2022 with TwinCAT
- **WHEN** a VS2022 instance with TwinCAT XAE is running and no XAE Shell is found
- **THEN** the system connects via ROT using ProgID `VisualStudio.DTE.17.0`, obtains `ITcSysManager`, and returns IDE version, ProgID, and open solution name as JSON

#### Scenario: Custom ProgID
- **WHEN** the user specifies `-ProgId "TcXaeShell.DTE.15.0"` for an older TwinCAT version
- **THEN** the system uses the specified ProgID for ROT lookup

#### Scenario: No IDE instance running
- **WHEN** no TwinCAT IDE instance is detected via ROT
- **THEN** the system launches a new XAE Shell instance using the default ProgID and waits until ready (max 60 seconds)

#### Scenario: TwinCAT not installed
- **WHEN** TwinCAT 3 XAE is not installed on the machine
- **THEN** the system returns an error with code `TWINCAT_NOT_FOUND` and installation guidance

#### Scenario: ITcSysManager not available
- **WHEN** the IDE is connected but no TwinCAT project is loaded (ITcSysManager cannot be obtained)
- **THEN** the system returns a partial connection (DTE only) with a warning that project-level operations are unavailable until a project is opened

### Requirement: JSON-based communication
All cmdlets SHALL output results as JSON objects containing at minimum a `success` boolean and either a `data` object or an `error` object with a `message` field and a `code` field.

#### Scenario: Successful operation
- **WHEN** a cmdlet completes successfully
- **THEN** the output is `{"success": true, "data": {...}}`

#### Scenario: Failed operation
- **WHEN** a cmdlet encounters an error
- **THEN** the output is `{"success": false, "error": {"message": "...", "code": "..."}}`
