---
name: TwinCAT-AutomationInterface
description: Use when the user asks to automate TwinCAT 3 IDE, build or deploy PLC programs, read or write PLC variables via ADS, modify Structured Text code, or run automated PLC tests. Requires Windows with TwinCAT 3 XAE installed.
---

# TwinCAT Automation Skill

Control TwinCAT 3 IDE and PLC runtime using the TwinCATAutomation PowerShell module.

Canonical repository: https://github.com/Lance0901/AI-TwinCAT-Skill. The installer records the source repo, version and commit in `tcauto-install-manifest.json` next to this file; `Get-TcAutomationVersion` reads it (include its output when reporting an issue).

## Setup

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

# 5. Login + Download (default -LoginMode Regular = flag 1, no SILENT flag; prompts answered by the global SilentMode from Connect-TcIde; creates the app on an empty runtime, attaches when one exists; no dialogs)
Enter-TcPlcOnline

# 6. Connect ADS (AFTER Login — port 851 needs program downloaded first)
Connect-TcAds -AmsNetId $amsNetId

# 7. Start PLC
Set-TcPlcState -State Run

# 8. Read/Write
Read-TcVariable -Path "MAIN.nCounter"
Write-TcVariable -Path "MAIN.bEnable" -Value $true
```

## All Commands

The cmdlet and parameter reference is generated from the module and lives in one place, so it is not repeated here: [adapters/claude-code/SKILL.md](https://github.com/Lance0901/AI-TwinCAT-Skill/blob/master/adapters/claude-code/SKILL.md) (section with the generated signature table). Offline: `Get-Command -Module TwinCATAutomation` and `Get-Help <cmdlet> -Full` after `Import-Module`.

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

# Full cycle
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

1. **AmsNetId is dynamic** — never hardcode. Auto-detected from IDE target via `Connect-TcIde` or `Connect-TcAds`.
2. **Lifecycle order matters**: Build -> Activate -> Login -> ADS Connect -> Start (ADS port 851 only exists after Login+Download)
3. **Don't reconnect IDE after Activate** — original COM reference survives TwinCAT XAR restart
4. **Write MAIN-level vars for FB testing** — PLC overwrites FB `VAR_INPUT` every scan cycle. Write standalone MAIN variables instead.
5. **Use -PouPath for Get/Write-TcPouCode** — format: `TIPC^<PlcName>^<PlcName> Project^POUs^<PouName>`
