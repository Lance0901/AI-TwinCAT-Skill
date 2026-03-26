# Getting Started

## Prerequisites

- **Windows 10/11**
- **TwinCAT 3 XAE** (Build 4024 or later) — either:
  - Standalone TwinCAT XAE Shell, OR
  - Visual Studio 2022 with TwinCAT XAE integration
- **PowerShell 5.1+** (included with Windows) or **PowerShell 7+**

## Verify TwinCAT Installation

```powershell
# Check if TwinCAT COM is registered
$type = [Type]::GetTypeFromProgID('TcXaeShell.DTE.17.0')
if ($type) { Write-Host "TwinCAT XAE Shell found" } else { Write-Host "Not found - check installation" }
```

## Import the Module

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1
```

## First Connection

```powershell
# Open TwinCAT XAE Shell first, then:
$result = Connect-TcIde
$result | ConvertTo-Json

# If no IDE is running, it will launch one automatically
```

## Create Your First Project

```powershell
# Create project
New-TcProject -Name "TestProject" -Path "C:\TcProjects"

# Add a Function Block
Add-TcPou -Name "FB_Counter" -Type FunctionBlock

# Write code
Write-TcPouCode -PouName "FB_Counter" -Declaration @"
FUNCTION_BLOCK FB_Counter
VAR_INPUT
    bEnable : BOOL;
END_VAR
VAR_OUTPUT
    nCount : INT;
END_VAR
VAR
    nInternal : INT;
END_VAR
"@ -Implementation @"
IF bEnable THEN
    nInternal := nInternal + 1;
END_IF
nCount := nInternal;
"@

# Build
Build-TcProject
```

## Run Automated Tests

```powershell
# Connect ADS to running PLC
Connect-TcAds

# Define a test
$test = New-TcTestCase -Name "Counter increments" `
    -Setup @(@{Path="MAIN.fbCounter.bEnable"; Value=$true}) `
    -WaitMs 2000 `
    -Assertions @(@{Path="MAIN.fbCounter.nCount"; Operator="GreaterThan"; Expected=0}) `
    -Teardown @(@{Path="MAIN.fbCounter.bEnable"; Value=$false})

# Run full cycle
Invoke-TcTestCycle -TestCases @($test)
```

## CLI Usage (for AI tools)

```bash
pwsh Invoke-TwinCATAutomation.ps1 --operation ListOperations
pwsh Invoke-TwinCATAutomation.ps1 --operation ConnectIde
pwsh Invoke-TwinCATAutomation.ps1 --operation NewProject --params '{"Name":"MyProject"}'
```
