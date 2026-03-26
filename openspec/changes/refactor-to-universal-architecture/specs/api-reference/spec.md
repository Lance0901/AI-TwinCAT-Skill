## ADDED Requirements

### Requirement: Universal operation reference
The system SHALL maintain a `docs/operations.md` file documenting every available operation with its name, description, parameters (name, type, required/optional, default), and return schema.

#### Scenario: AI tool reads operation docs
- **WHEN** any AI tool needs to understand available TwinCAT operations
- **THEN** it reads `docs/operations.md` for a complete, tool-agnostic reference

#### Scenario: Operation doc stays in sync
- **WHEN** a new cmdlet is added or parameters change
- **THEN** `docs/operations.md` SHALL be updated in the same change

### Requirement: Getting started guide
The system SHALL provide a `docs/getting-started.md` with prerequisites, installation steps, and a first-use walkthrough that is not specific to any AI tool.

#### Scenario: New user setup
- **WHEN** a user wants to start using TwinCAT automation
- **THEN** `docs/getting-started.md` guides them through TwinCAT installation verification, module import, and a first connection test

### Requirement: Per-tool setup instructions
The system SHALL provide `docs/setup-claude-code.md`, `docs/setup-codex.md`, and `docs/setup-antigravity.md` with tool-specific setup steps.

#### Scenario: Claude Code user setup
- **WHEN** a Claude Code user wants to install the TwinCAT Skill
- **THEN** `docs/setup-claude-code.md` explains how to copy the adapter and configure the Skill

#### Scenario: Codex user setup
- **WHEN** a Codex user wants to configure TwinCAT tools
- **THEN** `docs/setup-codex.md` explains how to register the adapter as a Codex tool
