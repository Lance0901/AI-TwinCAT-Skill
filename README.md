# AI TwinCAT Skill

A universal PowerShell module for automating TwinCAT 3 IDE operations, designed to work with any AI coding tool (Claude Code, Codex, Antigravity, etc.).

## What It Does

- **IDE Automation**: Connect to TwinCAT 3 XAE Shell / VS2022 and control it programmatically via TwinCAT Automation Interface (`ITcSysManager`, `ITcSmTreeItem`, `ITcPlcProject`)
- **Project Management**: Create projects, add POUs/GVLs/DUTs, manage libraries
- **PLC Code Writing**: Read and write Structured Text code in POUs
- **I/O Configuration**: Scan EtherCAT devices, read I/O tree, link variables to channels
- **Build & Deploy**: Build, activate configuration, download to PLC runtime
- **ADS Communication**: Read/write PLC variables at runtime via ADS protocol
- **Runtime Control**: Login/Logout, Run/Stop/Reset PLC, system state management
- **Automated Testing**: Define test cases, execute Build-Activate-Login-Run-Test cycles, generate test reports

## Architecture

```
src/TwinCATAutomation/       # Core PowerShell module (tool-agnostic)
  TwinCATAutomation.psm1
  Public/                    # Exported cmdlets
  Private/                   # Internal helpers
Invoke-TwinCATAutomation.ps1 # Unified CLI entry point (JSON in/out)
adapters/
  claude-code/               # Claude Code Skill adapter
  codex/                     # Codex tool definitions
  antigravity/               # Antigravity plugin
docs/                        # Universal documentation
openspec/                    # Development specs and change tracking
```

## Prerequisites

- Windows 10/11
- TwinCAT 3 XAE (Build 4024+)
- PowerShell 5.1+ or PowerShell 7+

## Quick Start

```powershell
Import-Module ./src/TwinCATAutomation/TwinCATAutomation.psm1

# Connect to TwinCAT IDE
Connect-TcIde

# Create a new project
New-TcProject -Name "MyProject" -Path "C:\TcProjects"

# Add a Function Block
Add-TcPou -Name "FB_Motor" -Type FunctionBlock

# Build and test
Invoke-TcTestCycle -TestCases $tests
```

Or via the CLI entry point (for AI tool integration):

```bash
pwsh Invoke-TwinCATAutomation.ps1 --operation NewProject --params '{"name":"MyProject"}'
```

## Development

This project uses [OpenSpec](https://github.com/openspec-dev/openspec) to track the development lifecycle. See `openspec/changes/` for current and past changes.

## License

MIT
