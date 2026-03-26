<#
.SYNOPSIS
    Unified CLI entry point for TwinCATAutomation module.
.DESCRIPTION
    Routes operations to module cmdlets. Accepts operation name and JSON parameters,
    returns JSON output. Designed for AI tool integration.
.PARAMETER Operation
    The operation to execute (e.g., NewProject, ConnectIde, BuildProject).
.PARAMETER Params
    JSON string of parameters to pass to the operation.
.EXAMPLE
    pwsh Invoke-TwinCATAutomation.ps1 --operation NewProject --params '{"name":"MyProject","path":"C:\\Projects"}'
#>
param(
    [Parameter(Mandatory = $false)]
    [Alias('operation')]
    [string]$Op,

    [Parameter(Mandatory = $false)]
    [Alias('params')]
    [string]$P
)

$ErrorActionPreference = 'Stop'

# Import the module
$modulePath = Join-Path $PSScriptRoot 'src' 'TwinCATAutomation' 'TwinCATAutomation.psm1'
Import-Module $modulePath -Force

# Operation name to cmdlet mapping
$operationMap = @{
    # IDE Connection
    'ConnectIde'      = 'Connect-TcIde'
    'DisconnectIde'   = 'Disconnect-TcIde'
    'GetIdeInfo'      = 'Get-TcIdeInfo'
    # Project Management
    'NewProject'      = 'New-TcProject'
    'OpenProject'     = 'Open-TcProject'
    'GetProjectTree'  = 'Get-TcProjectTree'
    'AddPou'          = 'Add-TcPou'
    'AddGvl'          = 'Add-TcGvl'
    'AddDut'          = 'Add-TcDut'
    'AddLibrary'      = 'Add-TcLibrary'
    # PLC Code
    'WritePouCode'    = 'Write-TcPouCode'
    'GetPouCode'      = 'Get-TcPouCode'
    # I/O Configuration
    'IoScan'          = 'Invoke-TcIoScan'
    'GetIoTree'       = 'Get-TcIoTree'
    'SetVariableLink' = 'Set-TcVariableLink'
    # Build & Deploy
    'BuildProject'    = 'Build-TcProject'
    'SetTarget'       = 'Set-TcTarget'
    'EnableConfig'    = 'Enable-TcConfig'
    'SendPlcProgram'  = 'Send-TcPlcProgram'
    # ADS Communication
    'ConnectAds'      = 'Connect-TcAds'
    'DisconnectAds'   = 'Disconnect-TcAds'
    'ReadVariable'    = 'Read-TcVariable'
    'WriteVariable'   = 'Write-TcVariable'
    'WatchVariable'   = 'Watch-TcVariable'
    'GetSymbols'      = 'Get-TcSymbols'
    # Runtime Control
    'GetPlcState'     = 'Get-TcPlcState'
    'SetPlcState'     = 'Set-TcPlcState'
    'PlcLogin'        = 'Enter-TcPlcOnline'
    'PlcLogout'       = 'Exit-TcPlcOnline'
    'GetSystemState'  = 'Get-TcSystemState'
    'SetSystemState'  = 'Set-TcSystemState'
    # Automated Testing
    'NewTestCase'     = 'New-TcTestCase'
    'RunTest'         = 'Invoke-TcTest'
    'RunTestCycle'    = 'Invoke-TcTestCycle'
    # Meta
    'ListOperations'  = $null
}

function Invoke-Operation {
    param([string]$OperationName, [string]$ParamsJson)

    if ([string]::IsNullOrWhiteSpace($OperationName)) {
        return New-TcResult -Success $false -ErrorMessage 'No operation specified. Use --operation <name>.' -ErrorCode 'NO_OPERATION'
    }

    if ($OperationName -eq 'ListOperations') {
        $ops = $operationMap.Keys | Where-Object { $_ -ne 'ListOperations' } | Sort-Object | ForEach-Object {
            [PSCustomObject]@{ operation = $_; cmdlet = $operationMap[$_] }
        }
        return New-TcResult -Success $true -Data $ops
    }

    if (-not $operationMap.ContainsKey($OperationName)) {
        return New-TcResult -Success $false -ErrorMessage "Unknown operation: $OperationName" -ErrorCode 'INVALID_OPERATION'
    }

    $cmdletName = $operationMap[$OperationName]
    $cmdParams = @{}

    if (-not [string]::IsNullOrWhiteSpace($ParamsJson)) {
        try {
            $parsed = $ParamsJson | ConvertFrom-Json
            $parsed.PSObject.Properties | ForEach-Object {
                $cmdParams[$_.Name] = $_.Value
            }
        }
        catch {
            return New-TcResult -Success $false -ErrorMessage "Invalid JSON params: $_" -ErrorCode 'INVALID_PARAMS'
        }
    }

    try {
        & $cmdletName @cmdParams
    }
    catch {
        New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'EXECUTION_ERROR'
    }
}

$result = Invoke-Operation -OperationName $Op -ParamsJson $P
$result | ConvertTo-Json -Depth 10 -Compress
