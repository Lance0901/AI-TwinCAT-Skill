<#
.SYNOPSIS
    Points git at the repository hooks in .githooks (pre-commit runs scripts/check.ps1 -Fast).
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/install-hooks.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) '..')).ProviderPath
& git -C $repoRoot config core.hooksPath .githooks
if ($LASTEXITCODE -ne 0) { throw "git config core.hooksPath failed (exit $LASTEXITCODE)" }
Write-Host "core.hooksPath = $(& git -C $repoRoot config core.hooksPath)"
Write-Host 'pre-commit now runs scripts/check.ps1 -Fast; run scripts/check.ps1 (without -Fast) before opening a PR.'
