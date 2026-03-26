# Antigravity Setup

## Installation

1. Copy the adapter plugin definition:
   ```bash
   cp adapters/antigravity/plugin.yaml <your-antigravity-plugins-dir>/twincat.yaml
   ```

2. Ensure `Invoke-TwinCATAutomation.ps1` is accessible from the plugin's execution context.

## Usage

The plugin exposes TwinCAT operations as Antigravity actions. Each action routes to `Invoke-TwinCATAutomation.ps1`.

## Configuration

Update `plugin.yaml` with the correct path to `Invoke-TwinCATAutomation.ps1` if it differs from the default.

See `docs/operations.md` for detailed parameter documentation.
