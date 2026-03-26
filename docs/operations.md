# Operations Reference

All operations accept and return JSON. Use via PowerShell module (`Import-Module`) or CLI entry point (`Invoke-TwinCATAutomation.ps1`).

## IDE Connection

### Connect-TcIde / `ConnectIde`
Connects to a running TwinCAT 3 IDE instance.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| ProgId | string | No | TcXaeShell.DTE.17.0 | COM ProgID |
| NoLaunch | switch | No | false | Don't launch new instance if none found |

**Returns:** `{ progId, version, solution, sysManagerAvailable }`

### Disconnect-TcIde / `DisconnectIde`
Releases COM references and disconnects from IDE.

### Get-TcIdeInfo / `GetIdeInfo`
Returns IDE instance information.

**Returns:** `{ progId, version, edition, solution, sysManagerAvailable }`

---

## Project Management

### New-TcProject / `NewProject`
Creates new TwinCAT solution with PLC project.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| Name | string | Yes | - | Project name |
| Path | string | No | Current dir | Target directory |

**Returns:** `{ solution, project, plcProject, path }`

### Open-TcProject / `OpenProject`
Opens existing .sln file.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Path | string | Yes | Path to .sln or .tsproj |

### Get-TcProjectTree / `GetProjectTree`
Returns full project structure as JSON tree.

### Add-TcPou / `AddPou`
Adds a POU to the PLC project.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Name | string | Yes | POU name |
| Type | string | Yes | Program, FunctionBlock, or Function |
| ReturnType | string | No | Return type for Functions (default: BOOL) |

### Add-TcGvl / `AddGvl`
Adds a Global Variable List.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Name | string | Yes | GVL name |
| Variables | hashtable | No | Variable declarations (name = type) |

### Add-TcDut / `AddDut`
Adds a Data Unit Type.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Name | string | Yes | DUT name |
| DutType | string | Yes | Struct, Enum, Alias, or Union |
| Fields | hashtable | No | Field declarations |
| AliasType | string | No | Base type for Alias |

### Add-TcLibrary / `AddLibrary`
Adds a library reference.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Name | string | Yes | Library name (e.g., Tc2_Standard) |
| Version | string | No | Version (default: *) |

---

## PLC Code

### Write-TcPouCode / `WritePouCode`
Writes code into an existing POU.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| PouName | string | Yes | POU name |
| Declaration | string | No | VAR declaration section |
| Implementation | string | No | Code body |

### Get-TcPouCode / `GetPouCode`
Reads code from a POU.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| PouName | string | Yes | POU name |

**Returns:** `{ pou, declaration, implementation }`

---

## I/O Configuration

### Invoke-TcIoScan / `IoScan`
Triggers EtherCAT device scan.

**Returns:** `{ devices: [{ name, path, type }] }`

### Get-TcIoTree / `GetIoTree`
Reads I/O device tree.

### Set-TcVariableLink / `SetVariableLink`
Links PLC variable to I/O channel.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| PlcVariable | string | Yes | PLC variable path |
| IoChannel | string | Yes | I/O channel tree path |

---

## Build & Deploy

### Build-TcProject / `BuildProject`
Builds PLC project.

**Returns:** `{ errors, warnings, messages }`

### Set-TcTarget / `SetTarget`
Sets target AMS Net ID.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| AmsNetId | string | Yes | Target AMS Net ID |

### Enable-TcConfig / `EnableConfig`
Activates TwinCAT configuration.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Force | switch | No | Force TwinCAT restart if needed |

### Send-TcPlcProgram / `SendPlcProgram`
Downloads PLC program to runtime.

---

## ADS Communication

### Connect-TcAds / `ConnectAds`
Establishes ADS connection.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| AmsNetId | string | No | 127.0.0.1.1.1 | Target AMS Net ID |
| Port | int | No | 851 | ADS port |

### Disconnect-TcAds / `DisconnectAds`
Closes ADS connection.

### Read-TcVariable / `ReadVariable`
Reads PLC variable(s) by symbol name.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Path | string[] | Yes | Variable path(s) |

**Returns:** `{ path, value, type }` or array for multiple

### Write-TcVariable / `WriteVariable`
Writes value to PLC variable.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Path | string | Yes | Variable path |
| Value | object | Yes | Value to write |

### Watch-TcVariable / `WatchVariable`
Polls variable at intervals.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| Path | string | Yes | - | Variable path |
| IntervalMs | int | No | 100 | Polling interval |
| DurationMs | int | No | 2000 | Total duration |
| Until | scriptblock | No | - | Stop condition |
| TimeoutMs | int | No | 5000 | Condition timeout |

### Get-TcSymbols / `GetSymbols`
Lists PLC symbols.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Filter | string | No | Wildcard filter (e.g., "MAIN.*") |

---

## Runtime Control

### Get-TcPlcState / `GetPlcState`
Reads PLC runtime state.

**Returns:** `{ state, adsState, deviceState }`

### Set-TcPlcState / `SetPlcState`
Sets PLC state (Run/Stop/Reset).

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| State | string | Yes | Run, Stop, or Reset |

### Enter-TcPlcOnline / `PlcLogin`
Logs into PLC runtime.

### Exit-TcPlcOnline / `PlcLogout`
Logs out from PLC runtime.

### Get-TcSystemState / `GetSystemState`
Reads TwinCAT system state.

### Set-TcSystemState / `SetSystemState`
Switches TwinCAT system state.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| State | string | Yes | Run or Config |

---

## Automated Testing

### New-TcTestCase / `NewTestCase`
Defines a test case.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| Name | string | Yes | Test name |
| Setup | hashtable[] | No | Setup variable writes |
| Teardown | hashtable[] | No | Teardown variable writes |
| WaitMs | int | No | Wait before assertions (default: 1000) |
| Assertions | hashtable[] | Yes | Assertions with Path, Operator, Expected |

Supported operators: `Equal`, `NotEqual`, `GreaterThan`, `LessThan`, `GreaterThanOrEqual`, `LessThanOrEqual`, `Contains`, `IsTrue`, `IsFalse`

### Invoke-TcTest / `RunTest`
Executes a single test case.

### Invoke-TcTestCycle / `RunTestCycle`
Full cycle: Build -> Activate -> Login -> Run -> Test -> Report -> Stop.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| TestCases | object[] | Yes | Array from New-TcTestCase |
| SkipBuild | switch | No | Skip build step |
| KeepRunning | switch | No | Don't stop PLC after tests |
