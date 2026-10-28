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
  "operation": "ConnectIde",
  "params": {
    "SolutionPath": "C:\\Projects\\MyProject\\MyProject.sln"
  }
}
```

`NewProject` only works on an IDE with no solution open; otherwise it returns `SOLUTION_ALREADY_OPEN` and creates nothing (#70). Create the project in XAE and connect with `ConnectIde` as above.

## Available Tools

See `adapters/codex/tools.json` for the full list of available tool definitions with parameter schemas.

See `docs/operations.md` for detailed parameter documentation.
