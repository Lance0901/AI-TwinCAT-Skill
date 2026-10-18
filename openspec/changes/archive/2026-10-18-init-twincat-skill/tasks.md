## 1. Project Setup & Skill Scaffold

- [ ] 1.1 Create Claude Code Skill directory structure: `.claude/skills/twincat/SKILL.md` and `scripts/` folder
- [ ] 1.2 Write SKILL.md with skill metadata, description, and prompt instructions for TwinCAT IDE operations
- [ ] 1.3 Create shared PowerShell module `scripts/TcCommon.psm1` with JSON output helpers and error handling utilities

## 2. IDE Automation (Connect & Discover)

- [ ] 2.1 Create `scripts/Connect-TcIde.ps1` — connect to running TwinCAT IDE via ROT, detect VS2022 vs XAE Shell, launch new instance if needed
- [ ] 2.2 Create `scripts/Get-TcIdeInfo.ps1` — return IDE version, type, and current solution info as JSON
- [ ] 2.3 Test connection against both VS2022 and XAE Shell environments

## 3. Project Management

- [ ] 3.1 Create `scripts/New-TcProject.ps1` — create new TwinCAT solution with PLC project and default MAIN program
- [ ] 3.2 Create `scripts/Open-TcProject.ps1` — open existing .sln or .tsproj file
- [ ] 3.3 Create `scripts/Get-TcProjectTree.ps1` — read and return full project structure as JSON tree
- [ ] 3.4 Create `scripts/Add-TcPou.ps1` — add Program, Function Block, or Function with declaration section
- [ ] 3.5 Create `scripts/Add-TcGvl.ps1` — add Global Variable List with variable declarations
- [ ] 3.6 Create `scripts/Add-TcDut.ps1` — add Data Unit Type (STRUCT, ENUM, ALIAS, UNION)
- [ ] 3.7 Create `scripts/Add-TcLibrary.ps1` — add library reference to PLC project

## 4. PLC Code Generation

- [ ] 4.1 Create `scripts/Write-TcPouCode.ps1` — write declaration and implementation code into an existing POU via COM
- [ ] 4.2 Add ST code generation templates/patterns in SKILL.md for common patterns: state machines, FB interfaces, error handling
- [ ] 4.3 Add Beckhoff library awareness — document common Tc2/Tc3 library functions and usage patterns in SKILL.md

## 5. I/O Configuration

- [ ] 5.1 Create `scripts/Invoke-TcIoScan.ps1` — trigger EtherCAT device scan and return discovered topology as JSON
- [ ] 5.2 Create `scripts/Get-TcIoTree.ps1` — read current I/O device tree and variable links
- [ ] 5.3 Create `scripts/Set-TcVariableLink.ps1` — link PLC variable to I/O channel

## 6. Build & Deploy

- [ ] 6.1 Create `scripts/Build-TcProject.ps1` — trigger PLC build and return results (success/errors) as JSON
- [ ] 6.2 Create `scripts/Set-TcTarget.ps1` — set target system (local or remote AMS Net ID)
- [ ] 6.3 Create `scripts/Enable-TcConfig.ps1` — activate TwinCAT configuration with user confirmation
- [ ] 6.4 Create `scripts/Send-TcPlcProgram.ps1` — download PLC program to target runtime

## 7. Integration & Testing

- [ ] 7.1 Create end-to-end test: connect → create project → add FB → write code → build
- [ ] 7.2 Test all scripts with both VS2022 and XAE Shell
- [ ] 7.3 Write usage examples in SKILL.md showing common workflows
- [ ] 7.4 Document prerequisites (TwinCAT version, PowerShell policy) in README or SKILL.md
