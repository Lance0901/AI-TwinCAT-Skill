# Unit: Error List row categories of Build-TcProject (issue #23), no IDE / runtime needed.
# The full BuildProject result through the MCP bridge is covered by mcp-server/test/build-result.test.js.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/build-error-category.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$rows = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\mcp-server\test\fixtures\build-error-list.json') | ConvertFrom-Json
$cases = @(
    @{ Name = 'Library Manager, line 0'; Item = $rows.library[0]; Want = 'library' }
    @{ Name = 'Library Manager, line null ("has not been installed")'; Item = $rows.library[5]; Want = 'library' }
    @{ Name = 'C0046 in MAIN.TcPOU:12'; Item = $rows.code[0]; Want = 'code' }
    @{ Name = '"Could not open library" without file / line'; Item = [PSCustomObject]@{ description = "Could not open library 'Tc2_Foo'"; project = 'plc'; file = ''; line = $null }; Want = 'library' }
    @{ Name = '"Could not open library" text in a POU row with a line stays code'; Item = [PSCustomObject]@{ description = "Could not open library 'x'"; project = 'plc'; file = 'C:\p\MAIN.TcPOU'; line = 3 }; Want = 'code' }
    @{ Name = 'Library Manager row WITH a line is not a library row'; Item = [PSCustomObject]@{ description = 'x'; project = 'plc'; file = 'plc.Library Manager'; line = 4 }; Want = 'code' }
    @{ Name = '"has not been installed" without file / line'; Item = [PSCustomObject]@{ description = "Library 'Tc3_Foo' 1.0.0.0 has not been installed"; project = 'plc'; file = ''; line = $null }; Want = 'library' }
    @{ Name = 'no file (build-summary row)'; Item = [PSCustomObject]@{ description = "Build of project 'plc' failed"; project = ''; file = ''; line = $null }; Want = 'other' }
    @{ Name = 'null item'; Item = $null; Want = 'other' }
)
foreach ($c in $cases) {
    $got = & $mod { param($i) Get-TcErrorItemCategory -Item $i } $c.Item
    Check $c.Name ($got -eq $c.Want) "want $($c.Want), got $got"
}
exit [Math]::Min($fail, 255)
