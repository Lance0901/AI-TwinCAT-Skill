## ADDED Requirements

### Requirement: Create new TwinCAT project
The system SHALL create a new TwinCAT XAE project with a PLC project configured with a default MAIN program.

#### Scenario: Create project with default settings
- **WHEN** the user requests a new TwinCAT project with a given name
- **THEN** the system creates a .sln with a TwinCAT XAE project containing one PLC project with a MAIN program in Structured Text

#### Scenario: Create project at specific path
- **WHEN** the user specifies a directory path for the new project
- **THEN** the system creates the project at that path

### Requirement: Open existing TwinCAT project
The system SHALL open an existing TwinCAT solution (.sln) or project (.tsproj) file in the connected IDE.

#### Scenario: Open solution file
- **WHEN** the user provides a path to a .sln file
- **THEN** the system opens it in TwinCAT IDE and returns the project structure as JSON

#### Scenario: File not found
- **WHEN** the provided path does not exist
- **THEN** the system returns an error indicating the file was not found

### Requirement: Read project structure
The system SHALL read and return the complete structure of an open TwinCAT project, including all POUs, GVLs, DUTs, Tasks, and library references.

#### Scenario: Read full project tree
- **WHEN** a TwinCAT project is open
- **THEN** the system returns a JSON tree of all PLC objects with their types, names, and paths

### Requirement: Add POU (Program Organization Unit)
The system SHALL add new POUs to an open PLC project. Supported POU types: Program, Function Block, Function.

#### Scenario: Add a Function Block
- **WHEN** the user requests a new Function Block named "FB_Motor" with specified interface (inputs/outputs)
- **THEN** the system creates the FB in the PLC project with the correct VAR_INPUT/VAR_OUTPUT declarations in Structured Text

#### Scenario: Add a Function
- **WHEN** the user requests a new Function with a return type
- **THEN** the system creates the Function with proper return type declaration

### Requirement: Add GVL (Global Variable List)
The system SHALL add new Global Variable Lists to an open PLC project.

#### Scenario: Add GVL with variables
- **WHEN** the user requests a new GVL with specified variable names and types
- **THEN** the system creates the GVL with all declared variables

### Requirement: Add DUT (Data Unit Type)
The system SHALL add new Data Unit Types (STRUCT, ENUM, ALIAS, UNION) to an open PLC project.

#### Scenario: Add a STRUCT
- **WHEN** the user requests a new STRUCT with specified fields
- **THEN** the system creates the DUT with all declared fields and types

### Requirement: Manage library references
The system SHALL add and remove library references in a PLC project.

#### Scenario: Add library reference
- **WHEN** the user requests to add a specific library (e.g., Tc2_Standard, Tc3_Module)
- **THEN** the system adds the library reference to the PLC project
