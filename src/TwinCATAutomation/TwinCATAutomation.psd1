@{
    RootModule        = 'TwinCATAutomation.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'Lance0901'
    Description       = 'PowerShell module for automating TwinCAT 3 IDE via TwinCAT Automation Interface. Supports project management, PLC code generation, I/O configuration, build/deploy, ADS communication, runtime control, and automated testing.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        # IDE Connection
        'Connect-TcIde',
        'Disconnect-TcIde',
        'Get-TcIdeInfo',
        # Project Management
        'New-TcProject',
        'Open-TcProject',
        'Get-TcProjectTree',
        'Add-TcPou',
        'Add-TcGvl',
        'Add-TcDut',
        'Add-TcLibrary',
        # PLC Code
        'Write-TcPouCode',
        'Get-TcPouCode',
        # I/O Configuration
        'Invoke-TcIoScan',
        'Get-TcIoTree',
        'Set-TcVariableLink',
        # Build & Deploy
        'Build-TcProject',
        'Set-TcTarget',
        'Enable-TcConfig',
        'Send-TcPlcProgram',
        # ADS Communication
        'Connect-TcAds',
        'Disconnect-TcAds',
        'Read-TcVariable',
        'Write-TcVariable',
        'Watch-TcVariable',
        'Get-TcSymbols',
        # Runtime Control
        'Get-TcPlcState',
        'Set-TcPlcState',
        'Enter-TcPlcOnline',
        'Exit-TcPlcOnline',
        'Get-TcSystemState',
        'Set-TcSystemState',
        # Automated Testing
        'New-TcTestCase',
        'Invoke-TcTest',
        'Invoke-TcTestCycle'
    )
    CmdletsToExport   = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('TwinCAT', 'Beckhoff', 'PLC', 'Automation', 'ADS')
            ProjectUri = 'https://github.com/Lance0901/AI-TwinCAT-Skill'
        }
    }
}
