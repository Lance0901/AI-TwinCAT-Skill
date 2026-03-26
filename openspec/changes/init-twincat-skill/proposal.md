## Why

TwinCAT 3 IDE (integrated in VS2022 and standalone XAE Shell) is the primary development environment for Beckhoff PLC programming, but it lacks AI-assisted automation. Engineers spend significant time on repetitive IDE operations — creating POUs, configuring I/O, managing libraries, building and deploying projects. A Claude Code Skill that can directly operate TwinCAT 3 IDE would dramatically accelerate PLC development for both automation engineers and software engineers entering the PLC domain.

## What Changes

- Introduce a Claude Code Skill capable of controlling TwinCAT 3 IDE via its automation interfaces (DTE/COM automation, TcXaeShell API)
- Enable natural language commands to perform IDE operations: create projects, add POUs/GVLs/DUTs, configure PLC tasks, manage I/O mappings, build, activate configuration, and deploy
- Provide read capabilities to understand existing TwinCAT project structure, parse .tsproj/.plcproj files, and analyze current PLC programs
- Support both Visual Studio 2022 (with TwinCAT XAE integration) and standalone TwinCAT XAE Shell
- Target two user personas: experienced automation engineers seeking productivity gains, and software engineers unfamiliar with PLC who need guided assistance

## Capabilities

### New Capabilities
- `ide-automation`: Core capability to connect to and control TwinCAT 3 IDE instances (VS2022 / XAE Shell) via COM automation interfaces
- `project-management`: Create, open, read, and modify TwinCAT projects — manage POUs, GVLs, DUTs, Tasks, and library references
- `plc-code-generation`: Generate Structured Text (IEC 61131-3) code for Function Blocks, Functions, Programs, and data types based on natural language descriptions
- `io-configuration`: Configure TwinCAT I/O mappings, EtherCAT device scanning, and variable linking
- `build-deploy`: Build PLC projects, activate configurations, and manage deployment to TwinCAT runtime

### Modified Capabilities
<!-- No existing capabilities to modify — this is a greenfield project -->

## Impact

- **Dependencies**: Requires TwinCAT 3 XAE installed on the target machine; COM automation access to TwinCAT DTE
- **Platform**: Windows only (TwinCAT 3 is Windows-exclusive)
- **APIs**: TwinCAT Automation Interface (EnvDTE, TcXaeShell COM objects), potentially TwinCAT ADS protocol for runtime interaction
- **Security**: IDE automation requires elevated permissions; Skill must handle COM registration and access safely
- **Skill delivery**: Packaged as a Claude Code Skill (.claude/skills/) with supporting scripts/tools
