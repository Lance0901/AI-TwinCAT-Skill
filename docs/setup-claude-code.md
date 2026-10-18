# Claude Code Setup

## Installation

Run the installer from the repo root. It checks prerequisites, copies the module and `adapters/claude-code/SKILL.md` (with `<module-path>` substituted) to `~/.claude/skills/twincat-automation/`, written as UTF-8 without BOM:

```powershell
pwsh ./TwinCATSetup-Claude.ps1
```

Check whether the installed copy still matches the repo (read-only, exit code 0 = match, 1 = mismatch):

```powershell
pwsh ./TwinCATSetup-Claude.ps1 -Verify
```

Uninstall: `pwsh ./TwinCATSetup-Claude.ps1 -Uninstall`

When something fails, read `docs/troubleshooting.md` first (error code table, lifecycle order, environment matrix).

## Usage

Once installed, Claude Code can:

- Create TwinCAT projects: "Create a new TwinCAT project called MotorControl"
- Add POUs: "Add a Function Block called FB_Valve with bOpen input and bState output"
- Write PLC code: "Write a state machine in FB_Valve"
- Build and test: "Build the project and run the tests"
- Read runtime data: "Read the value of MAIN.nCounter from the PLC"

## How It Works

The Claude Code Skill (`SKILL.md`) instructs Claude to:
1. Import the `TwinCATAutomation` PowerShell module
2. Use the appropriate cmdlet for each operation
3. Parse JSON results and report to the user

All automation logic lives in the core module — the Skill only provides context and routing.
