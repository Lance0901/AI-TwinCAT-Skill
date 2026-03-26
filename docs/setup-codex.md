# Codex Setup

## Installation

1. Copy the adapter to your Codex configuration:
   ```bash
   cp adapters/codex/tools.json <your-codex-config-dir>/twincat-tools.json
   ```

2. Register the tools in your Codex environment configuration.

## Usage

All operations are exposed as tools that Codex can invoke. Each tool maps to `Invoke-TwinCATAutomation.ps1` with the appropriate operation and parameters.

Example tool invocation:
```json
{
  "operation": "NewProject",
  "params": {
    "Name": "MyProject",
    "Path": "C:\\Projects"
  }
}
```

## Available Tools

See `adapters/codex/tools.json` for the full list of available tool definitions with parameter schemas.

See `docs/operations.md` for detailed parameter documentation.
