## ADDED Requirements

### Requirement: Claude Code adapter
The system SHALL provide a Claude Code Skill adapter at `adapters/claude-code/` containing a `SKILL.md` that instructs Claude Code how to use the TwinCATAutomation module.

#### Scenario: Claude Code invokes a TwinCAT operation
- **WHEN** a user gives Claude Code a natural language TwinCAT command
- **THEN** Claude Code uses the SKILL.md context to determine the correct cmdlet and parameters, invokes it via Bash, and interprets the JSON result

#### Scenario: Skill references universal docs
- **WHEN** the Claude Code Skill needs operation details
- **THEN** it references the `docs/` directory for parameter schemas and examples rather than embedding them in SKILL.md

### Requirement: Codex adapter
The system SHALL provide a Codex adapter at `adapters/codex/` containing task/tool definitions in a format consumable by OpenAI Codex.

#### Scenario: Codex discovers available tools
- **WHEN** Codex loads the adapter configuration
- **THEN** it sees a list of TwinCAT operations as callable tools with parameter schemas

#### Scenario: Codex invokes a TwinCAT operation
- **WHEN** Codex calls a TwinCAT tool
- **THEN** the adapter routes to `Invoke-TwinCATAutomation.ps1` with the correct operation and params

### Requirement: Antigravity adapter
The system SHALL provide an Antigravity adapter at `adapters/antigravity/` containing plugin definitions in Antigravity's expected format.

#### Scenario: Antigravity loads plugin
- **WHEN** Antigravity scans for available plugins
- **THEN** it discovers the TwinCAT automation plugin with operation descriptions

#### Scenario: Antigravity invokes a TwinCAT operation
- **WHEN** Antigravity calls a TwinCAT plugin operation
- **THEN** the adapter routes to `Invoke-TwinCATAutomation.ps1` with the correct operation and params

### Requirement: Adapter independence from core
Adapters SHALL NOT contain business logic. All TwinCAT automation logic SHALL reside in the core PowerShell module.

#### Scenario: Core module update
- **WHEN** a new cmdlet is added to the core module
- **THEN** adapters only need to add a new tool/operation mapping, not implement any automation logic

#### Scenario: New AI tool support
- **WHEN** a new AI coding tool needs support
- **THEN** only a new adapter directory is needed; no changes to the core module
