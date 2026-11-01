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
        'Reset-TcSolution',
        'Get-TcIdeInfo',
        'Get-TcIdeModalDialog',
        # Project Management
        'New-TcProject',
        'Open-TcProject',
        'Get-TcProjectTree',
        'Add-TcPou',
        'Add-TcGvl',
        'Add-TcDut',
        'Add-TcLibrary',
        'Add-TcInterface',
        'Add-TcPouMember',
        # Library Manager (ITcPlcLibraryManager)
        'Get-TcLibraries',
        'Add-TcLibraryPlaceholder',
        'Remove-TcLibraryReference',
        'Install-TcLibrary',
        'Uninstall-TcLibrary',
        'Lock-TcLibraryPlaceholder',
        # PLC tasks and program calls
        'Add-TcPlcTask',
        'Add-TcTaskProgram',
        'Remove-TcTaskProgram',
        # PLCopen XML
        'Export-TcPlcOpen',
        'Import-TcPlcOpen',
        # Library file and archives
        'Save-TcPlcLibrary',
        'Save-TcArchive',
        # PLC Code
        'Write-TcPouCode',
        'Get-TcPouCode',
        # I/O Configuration
        'Invoke-TcIoScan',
        'Get-TcIoTree',
        'Set-TcVariableLink',
        'Remove-TcVariableLink',
        # NC axes (phase 3, task 4.1)
        'Add-TcNcTask',
        'Add-TcNcAxis',
        'Set-TcNcAxisParameter',
        'Connect-TcNcAxisToPlc',
        # TcCOM modules (phase 3, task 4.2)
        'Add-TcComModule',
        'Get-TcComModuleParameter',
        'Set-TcComModuleParameter',
        'Set-TcComModuleContext',
        # Project variants (phase 3, task 4.3)
        'Get-TcProjectVariants',
        'Set-TcProjectVariantConfig',
        'Set-TcCurrentVariant',
        # Independent project file (phase 3, task 4.4)
        'Set-TcIndependentFile',
        # ADS routes (phase 3, task 4.5)
        'Get-TcAdsRoutes',
        'Find-TcAdsTarget',
        'Add-TcAdsRoute',
        # Generic tree items (LookupTreeItem / ProduceXml / CreateChild / ConsumeXml / DeleteChild / ExportChild / ImportChild)
        'Get-TcTreeItem',
        'Get-TcTreeItemXml',
        'New-TcTreeItem',
        'Set-TcTreeItemXml',
        'Remove-TcTreeItem',
        'Export-TcTreeItem',
        'Import-TcTreeItem',
        # Build & Deploy
        'Build-TcProject',
        'Clear-TcProject',
        'Test-TcPlcProject',
        'New-TcBootProject',
        'Get-TcBuildErrors',
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
