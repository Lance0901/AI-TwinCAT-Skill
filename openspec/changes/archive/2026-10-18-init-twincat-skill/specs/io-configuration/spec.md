## ADDED Requirements

### Requirement: Scan EtherCAT devices
The system SHALL trigger an EtherCAT device scan in TwinCAT IDE and return the discovered device topology.

#### Scenario: Scan with connected devices
- **WHEN** the user requests an I/O scan and EtherCAT devices are connected
- **THEN** the system returns a JSON list of discovered devices with their names, types, and addresses

#### Scenario: Scan with no devices
- **WHEN** no EtherCAT devices are found
- **THEN** the system returns an empty device list with a message indicating no devices were detected

### Requirement: Link PLC variables to I/O
The system SHALL create variable links between PLC variables and I/O channels in the TwinCAT project.

#### Scenario: Link single variable
- **WHEN** the user specifies a PLC variable name and an I/O channel path
- **THEN** the system creates the variable link in the TwinCAT project

#### Scenario: Auto-link by naming convention
- **WHEN** the user requests auto-linking and PLC variable names match I/O channel names
- **THEN** the system automatically creates links for all matching pairs and reports the results

### Requirement: Read current I/O configuration
The system SHALL read and return the current I/O device tree and variable link mappings from an open TwinCAT project.

#### Scenario: Read I/O tree
- **WHEN** a project with I/O configuration is open
- **THEN** the system returns the complete I/O device tree as JSON including all terminals, channels, and existing links
