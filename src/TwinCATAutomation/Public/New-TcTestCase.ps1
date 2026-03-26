function New-TcTestCase {
    <#
    .SYNOPSIS
        Defines a test case for PLC automated testing.
    .PARAMETER Name
        Test case name.
    .PARAMETER Setup
        Array of hashtables with Path and Value for setup writes.
    .PARAMETER Teardown
        Array of hashtables with Path and Value for teardown writes.
    .PARAMETER WaitMs
        Wait duration in milliseconds before assertions.
    .PARAMETER Assertions
        Array of hashtables with Path, Operator, and Expected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [hashtable[]]$Setup,

        [Parameter()]
        [hashtable[]]$Teardown,

        [Parameter()]
        [int]$WaitMs = 1000,

        [Parameter(Mandatory)]
        [hashtable[]]$Assertions
    )

    [PSCustomObject]@{
        PSTypeName = 'TcTestCase'
        name       = $Name
        setup      = $Setup
        teardown   = $Teardown
        waitMs     = $WaitMs
        assertions = $Assertions
    }
}
