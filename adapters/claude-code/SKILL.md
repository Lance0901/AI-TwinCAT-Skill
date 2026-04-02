---
name: TwinCAT-AutomationInterface
description: Control TwinCAT 3 IDE, manage PLC projects, build and deploy programs, read/write PLC variables via ADS, modify Structured Text code, and run automated PLC tests. Requires Windows with TwinCAT 3 XAE installed.
---

# TwinCAT Automation Skill

Control TwinCAT 3 IDE and PLC runtime using the TwinCATAutomation PowerShell module.

## Setup

Before any operation, import the module:
```powershell
Import-Module "<module-path>" -Force
```

## Full Lifecycle (Zero Dialogs)

```powershell
# 1. Connect (one-step with -SolutionPath)
$r = Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
$amsNetId = $r.data.amsNetId

# 2. Build
Build-TcProject

# 3. Activate (Config -> Run via ADS, no dialogs)
Enable-TcConfig -Force

# 4. Wait for TwinCAT restart
Start-Sleep -Seconds 5

# 5. Login + Download (Login(3), no dialogs)
Enter-TcPlcOnline

# 6. Connect ADS (AFTER Login — port 851 needs program downloaded first)
Connect-TcAds -AmsNetId $amsNetId

# 7. Start PLC
Set-TcPlcState -State Run

# 8. Read/Write
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

## All Commands (34)

### IDE Connection
- `Connect-TcIde [-SolutionPath <path>] [-ProgId <com>]` — Connect to IDE. With -SolutionPath: finds/launches IDE, opens solution, returns amsNetId
- `Disconnect-TcIde` — Disconnect from IDE
- `Get-TcIdeInfo` — Get IDE version, solution path, connection status

### Project Management
- `New-TcProject -Name <name> [-Path <dir>]` — Create new project with PLC and MAIN
- `Open-TcProject -Path <sln>` — Open existing solution
- `Get-TcProjectTree` — Get project tree as JSON
- `Add-TcPou -Name <name> -Type <Program|FunctionBlock|Function> [-ReturnType <t>]` — Add POU
- `Add-TcGvl -Name <name> [-Variables @{var=type}]` — Add GVL
- `Add-TcDut -Name <name> -DutType <Struct|Enum|Alias|Union>` — Add DUT
- `Add-TcLibrary -Name <lib>` — Add library reference

### PLC Code
- `Get-TcPouCode -PouName <name> [-PouPath <treePath>]` — Read declaration + implementation
- `Write-TcPouCode -PouName <name> [-PouPath <treePath>] [-Declaration <text>] [-Implementation <text>]` — Write code to POU

### Build & Deploy
- `Build-TcProject` — Build (auto-retry on RPC_E_CALL_REJECTED)
- `Enable-TcConfig [-Force]` — Activate config. -Force = ADS WriteControl (no dialogs)
- `Enter-TcPlcOnline [-PlcProjectPath <path>]` — Login + Download via Login(3) (no dialogs)
- `Exit-TcPlcOnline` — Logout from PLC
- `Send-TcPlcProgram` — Upload program to PLC
- `Set-TcTarget -AmsNetId <id>` — Set target system

### ADS Communication
- `Connect-TcAds [-AmsNetId <id>] [-Port <851>]` — Connect ADS. AmsNetId auto-detected if omitted
- `Disconnect-TcAds` — Disconnect ADS
- `Read-TcVariable -Path <varPath>` — Read variable by symbol path
- `Write-TcVariable -Path <varPath> -Value <val>` — Write variable (BOOL, INT, UINT, DINT, REAL, LREAL, STRING)
- `Watch-TcVariable -Path <varPath> -IntervalMs <ms> [-Condition <script>] [-TimeoutMs <ms>]` — Monitor with condition
- `Get-TcSymbols [-Filter <wildcard>]` — List symbols (e.g. "MAIN.*")

### Runtime Control
- `Set-TcPlcState -State <Run|Stop|Reset>` — Set PLC state via ADS
- `Get-TcPlcState` — Read PLC state
- `Set-TcSystemState -State <Run|Config> [-AmsNetId <id>]` — Set system state (no dialogs)
- `Get-TcSystemState [-AmsNetId <id>]` — Read system state

### I/O Configuration
- `Invoke-TcIoScan` — Scan for EtherCAT devices
- `Get-TcIoTree` — Read I/O device tree
- `Set-TcVariableLink -Variable <v> -Channel <c>` — Link PLC variable to I/O channel

### Testing
- `New-TcTestCase -Name <name> [-Setup @(...)] [-WaitMs <ms>] -Assertions @(...) [-Teardown @(...)]` — Define test case
- `Invoke-TcTest -TestCase <tc>` — Run single test
- `Invoke-TcTestCycle -TestCases @(...) [-SkipBuild] [-KeepRunning]` — Full Build->Deploy->Test->Stop cycle

## Testing Example

```powershell
$test1 = New-TcTestCase -Name "Initial state" -Assertions @(
    @{ Path = "MAIN.bReady"; Operator = "IsTrue"; Expected = $null }
    @{ Path = "MAIN.nCount"; Operator = "Equal"; Expected = [uint16]0 }
)

$test2 = New-TcTestCase -Name "Trigger and verify" `
    -Setup @( @{ Path = "MAIN.bStart"; Value = $true } ) `
    -WaitMs 2000 `
    -Assertions @(
        @{ Path = "MAIN.bDone"; Operator = "IsTrue"; Expected = $null }
    ) `
    -Teardown @( @{ Path = "MAIN.bStart"; Value = $false } )

Invoke-TcTestCycle -TestCases @($test1, $test2)
```

Assertion operators: `Equal`, `GreaterThan`, `LessThan`, `IsTrue`, `IsFalse`

## Output Format

All commands return JSON:
```json
{"success": true, "data": {"path": "MAIN.nCounter", "value": 42, "type": "UDINT"}}
{"success": false, "error": {"message": "Build failed", "code": "BUILD_FAILED"}}
```

## Critical Rules

1. **AmsNetId is dynamic** — never hardcode. Auto-detected from IDE target.
2. **Lifecycle order matters**: Build -> Activate -> Login -> ADS Connect -> Start (ADS port 851 only exists after Login+Download)
3. **Don't reconnect IDE after Activate** — original COM reference survives TwinCAT XAR restart.
4. **Write MAIN-level vars for FB testing** — PLC overwrites FB `VAR_INPUT` every scan cycle.
5. **Use -PouPath for Get/Write-TcPouCode** — format: `TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`
