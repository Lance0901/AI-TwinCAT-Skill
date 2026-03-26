## Why

The initial TwinCAT Skill design is tightly coupled to Claude Code (`.claude/skills/` packaging) and uses generic COM/DTE references instead of the proper TwinCAT Automation Interface API. This limits adoption to a single AI tool and misses the rich, purpose-built API that Beckhoff provides. Refactoring to a tool-agnostic core built on `ITcSysManager`/`ITcSmTreeItem` makes the project usable across Claude Code, Codex, Antigravity, and any future AI coding tool.

## What Changes

- **BREAKING**: Replace the Claude Code-only Skill packaging with a standalone PowerShell module (`TwinCATAutomation`) as the core layer, with no AI-tool dependencies
- Replace generic COM/DTE automation approach with explicit use of TwinCAT Automation Interface API (`ITcSysManager`, `ITcSmTreeItem`, `ITcPlcProject`, etc.)
- Introduce a thin adapter layer per AI tool: Claude Code Skill, Codex task definitions, Antigravity plugin
- Move all documentation to universal Markdown format (not embedded in SKILL.md) so any tool can consume it
- Add a unified CLI entry point (`Invoke-TwinCATAutomation.ps1`) that any AI tool can call with consistent JSON in/out

## Capabilities

### New Capabilities
- `core-module`: Standalone PowerShell module (`TwinCATAutomation.psm1`) wrapping TwinCAT Automation Interface API — connection management, project operations, I/O, build/deploy — with no AI-tool dependencies
- `tool-adapters`: Thin adapter layer for each AI coding tool (Claude Code, Codex, Antigravity) that translates tool-specific invocations into core module calls
- `api-reference`: Universal Markdown documentation of all available operations, parameters, and examples — consumable by any AI tool as context
- `ads-communication`: ADS protocol layer for reading/writing PLC variables at runtime using TcAdsClient — enables monitoring, diagnostics, and automated verification of running PLC programs
- `runtime-control`: PLC runtime lifecycle control — Login, Logout, Run, Stop, Reset via ITcPlcProject and ADS state control, independent of the download operation
- `automated-testing`: End-to-end test execution framework — write code, build, activate, login, run, read ADS variables, compare against expected values, and generate pass/fail test reports

### Modified Capabilities
- `ide-automation`: Switch from generic ROT/DTE connection to TwinCAT Automation Interface (`ITcSysManager` via `TcXaeShell.DTE.17.0` ProgID), with proper type library usage
- `project-management`: Use `ITcSmTreeItem` hierarchy and `ITcPlcProject` interface instead of generic DTE project manipulation
- `io-configuration`: Use `ITcSmTreeItem` I/O tree navigation and `ITcSysManager` device scanning APIs
- `build-deploy`: Use `ITcSysManager::ActivateConfiguration()` and proper build automation interfaces

## Impact

- **Code structure**: Moves from flat `scripts/` directory to a proper PowerShell module with `Public/`/`Private/` function layout
- **Dependencies**: Requires TwinCAT 3 XAE (Build 4024+); ADS communication requires TwinCAT ADS .NET library (`TwinCAT.Ads.dll`) or COM-based `TcAdsDll`
- **Breaking**: Existing script paths (`scripts/Connect-TcIde.ps1` etc.) will be replaced by module cmdlets (`Connect-TcIde`, `New-TcProject`, etc.)
- **AI tool integration**: Each supported tool gets its own adapter directory (`adapters/claude-code/`, `adapters/codex/`, `adapters/antigravity/`)
- **Documentation**: Single `docs/` directory with operation reference, getting started guide, and per-tool setup instructions
