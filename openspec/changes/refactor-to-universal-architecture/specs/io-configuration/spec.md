## MODIFIED Requirements

### Requirement: Scan EtherCAT devices
The system SHALL trigger an I/O device scan using `ITcSysManager` and return the discovered device topology. The scan SHALL navigate the `TIID` (I/O Devices) subtree via `ITcSmTreeItem`.

#### Scenario: Scan and discover devices
- **WHEN** the user calls `Invoke-TcIoScan`
- **THEN** the system uses `ITcSysManager` to scan for connected EtherCAT devices and returns the topology as a JSON tree under the `TIID` tree item

#### Scenario: No devices found
- **WHEN** no EtherCAT devices are connected
- **THEN** the system returns `{"success": true, "data": {"devices": []}}` with an empty device list

### Requirement: Read I/O device tree
The system SHALL read the current I/O device tree by navigating `ITcSmTreeItem` items under `TIID`.

#### Scenario: Read I/O tree
- **WHEN** the user calls `Get-TcIoTree`
- **THEN** the system walks `ITcSmTreeItem` children under `TIID` and returns all devices, terminals, and channels as a nested JSON tree

### Requirement: Link PLC variable to I/O channel
The system SHALL create variable links between PLC variables and I/O channels using `ITcSmTreeItem` properties.

#### Scenario: Link variable to channel
- **WHEN** the user calls `Set-TcVariableLink -PlcVariable "MAIN.bInput1" -IoChannel "TIID^Device 1^Term 1^Channel 1"`
- **THEN** the system creates the variable link via the TwinCAT Automation Interface and confirms the link as JSON
