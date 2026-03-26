# Claude Code Setup

## Installation

1. Copy the adapter Skill to your project:
   ```bash
   cp -r adapters/claude-code/.claude/skills/twincat .claude/skills/twincat
   ```

2. Or symlink if working from this repo:
   ```bash
   ln -s $(pwd)/adapters/claude-code/.claude/skills/twincat .claude/skills/twincat
   ```

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
