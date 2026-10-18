## Context

TwinCAT 3 XAE (eXtended Automation Engineering) exposes a COM-based automation interface built on top of Visual Studio's EnvDTE model. This allows external programs to control the IDE programmatically — creating projects, adding PLC objects, modifying code, building, and deploying. Both VS2022 (with TwinCAT integration) and standalone XAE Shell share the same automation API.

Claude Code Skills execute as Markdown-defined prompts with access to Bash, file I/O, and other tools. To bridge Claude Code and TwinCAT IDE, we need helper scripts that invoke COM automation, since Claude Code cannot directly call COM objects. PowerShell is the natural choice on Windows for COM interop.

## Goals / Non-Goals

**Goals:**
- Enable Claude Code to perform common TwinCAT IDE operations via natural language
- Support both VS2022 + TwinCAT XAE and standalone TwinCAT XAE Shell
- Provide a modular set of PowerShell scripts for each IDE operation
- Make the Skill useful for both PLC-experienced automation engineers and PLC-novice software engineers
- Record all development decisions and progress via OpenSpec

**Non-Goals:**
- Ladder Diagram / FBD / CFC visual programming support (Structured Text only in v1)
- Real-time PLC debugging or online change during runtime
- Cross-platform support (TwinCAT is Windows-only)
- Replacing TwinCAT IDE entirely — this is an assistant, not a replacement
- TwinCAT 2 support

## Decisions

### 1. PowerShell as the COM bridge layer
**Decision**: Use PowerShell scripts to interface with TwinCAT COM automation.
**Rationale**: PowerShell has native COM interop support, is available on all Windows machines with TwinCAT, and can be invoked from Claude Code's Bash tool. Alternatives considered:
- **Python with pywin32**: Adds a dependency; not guaranteed to be installed on automation engineer workstations
- **C# console app**: Requires compilation step; harder to iterate during Skill development
- **Node.js with edge-js**: Complex setup, fragile COM bridging

### 2. Script-per-operation architecture
**Decision**: Each IDE operation is a standalone PowerShell script (e.g., `New-TcProject.ps1`, `Add-Pou.ps1`, `Build-TcProject.ps1`).
**Rationale**: Modular scripts are easier to test, debug, and extend independently. Claude Code can compose them as needed. A monolithic script would be harder to maintain and would require complex argument parsing.

### 3. JSON as the interchange format
**Decision**: All scripts output JSON for structured data exchange with Claude Code.
**Rationale**: Claude Code can parse JSON natively. Error conditions, project structure, build results — all return as JSON objects. This avoids fragile text parsing of console output.

### 4. Skill structure with SKILL.md + scripts/
**Decision**: Package as a Claude Code Skill with `SKILL.md` defining the prompt and `scripts/` containing PowerShell helpers.
**Rationale**: Standard Claude Code Skill packaging. The SKILL.md provides Claude with context about available operations and when to use them. Scripts are referenced and invoked by the Skill prompt.

### 5. IDE instance management via ROT (Running Object Table)
**Decision**: Connect to existing TwinCAT IDE instances via Windows ROT, with fallback to launching a new instance.
**Rationale**: Most users will already have TwinCAT IDE open. ROT lookup avoids creating duplicate instances. If no instance is found, the script launches one. This matches the workflow of both persona types.

## Risks / Trade-offs

- **COM registration varies by TwinCAT version** → Mitigation: Test against TwinCAT 3.1 Build 4024+ (current mainstream); document minimum version requirements
- **IDE automation is synchronous and slow** → Mitigation: Use timeouts and progress feedback; batch operations where possible
- **VS2022 vs XAE Shell have subtle API differences** → Mitigation: Abstract connection logic in a shared `Connect-TcIde.ps1` script that detects the environment
- **PowerShell execution policy may block scripts** → Mitigation: Document required policy settings; use `-ExecutionPolicy Bypass` flag per-invocation
- **User may not have TwinCAT installed** → Mitigation: Fail fast with clear error message and installation guidance
