## MODIFIED Requirements

### Requirement: Create new TwinCAT project
The system SHALL create a new TwinCAT XAE project using `ITcSysManager` tree operations. The `New-TcProject` cmdlet SHALL create a solution, add a TwinCAT XAE project, and create a PLC project with a default MAIN program.

#### Scenario: Create project with default settings
- **WHEN** the user calls `New-TcProject -Name "MyProject"`
- **THEN** the system creates a .sln with a TwinCAT XAE project, adds a PLC project via `ITcSmTreeItem::CreateChild()`, and includes a MAIN program in Structured Text

#### Scenario: Create project at specific path
- **WHEN** the user calls `New-TcProject -Name "MyProject" -Path "C:\Projects"`
- **THEN** the system creates the project at the specified path

### Requirement: Open existing TwinCAT project
The system SHALL open an existing TwinCAT solution using the DTE interface and then obtain `ITcSysManager` from the loaded project.

#### Scenario: Open solution file
- **WHEN** the user calls `Open-TcProject -Path "C:\Projects\MyProject.sln"`
- **THEN** the system opens the solution, obtains `ITcSysManager`, and returns the project structure as JSON

#### Scenario: File not found
- **WHEN** the provided path does not exist
- **THEN** the system returns an error with code `FILE_NOT_FOUND`

### Requirement: Read project structure
The system SHALL read the TwinCAT project tree by navigating `ITcSmTreeItem` hierarchy and return a JSON representation of all PLC objects.

#### Scenario: Read full project tree
- **WHEN** `Get-TcProjectTree` is called with an open project
- **THEN** the system walks the `ITcSmTreeItem` tree and returns all POUs, GVLs, DUTs, Tasks, and library references as a nested JSON tree with item types, names, and paths

### Requirement: Add POU via ITcSmTreeItem
The system SHALL add new POUs using `ITcSmTreeItem::CreateChild()` with the appropriate POU sub-type GUID. The `Add-TcPou` cmdlet SHALL accept `-Name`, `-Type` (Program|FunctionBlock|Function), and optional `-ReturnType` for Functions.

#### Scenario: Add a Function Block
- **WHEN** the user calls `Add-TcPou -Name "FB_Motor" -Type FunctionBlock`
- **THEN** the system creates the FB via `ITcSmTreeItem::CreateChild()` under the PLC project POUs folder

#### Scenario: Add a Function with return type
- **WHEN** the user calls `Add-TcPou -Name "FC_Add" -Type Function -ReturnType "INT"`
- **THEN** the system creates the Function with the specified return type

### Requirement: Add GVL via ITcSmTreeItem
The system SHALL add new Global Variable Lists using tree item creation.

#### Scenario: Add GVL
- **WHEN** the user calls `Add-TcGvl -Name "GVL_Main"`
- **THEN** the system creates the GVL under the PLC project GVLs folder via `ITcSmTreeItem::CreateChild()`

### Requirement: Add DUT via ITcSmTreeItem
The system SHALL add new Data Unit Types using tree item creation.

#### Scenario: Add a STRUCT
- **WHEN** the user calls `Add-TcDut -Name "ST_MotorData" -DutType Struct`
- **THEN** the system creates the DUT under the PLC project DUTs folder via `ITcSmTreeItem::CreateChild()`

### Requirement: Manage library references
The system SHALL add library references using `ITcPlcProject` interface methods.

#### Scenario: Add library reference
- **WHEN** the user calls `Add-TcLibrary -Name "Tc2_Standard"`
- **THEN** the system adds the library reference via `ITcPlcProject` library management interface
