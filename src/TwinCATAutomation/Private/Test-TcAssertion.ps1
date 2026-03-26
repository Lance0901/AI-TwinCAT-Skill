function Test-TcAssertion {
    <#
    .SYNOPSIS
        Evaluates an assertion against an actual value.
    .PARAMETER Actual
        The actual value from PLC.
    .PARAMETER Operator
        Comparison operator: Equal, NotEqual, GreaterThan, LessThan, GreaterThanOrEqual, LessThanOrEqual, Contains, IsTrue, IsFalse.
    .PARAMETER Expected
        The expected value to compare against.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        $Actual,

        [Parameter(Mandatory)]
        [ValidateSet('Equal', 'NotEqual', 'GreaterThan', 'LessThan', 'GreaterThanOrEqual', 'LessThanOrEqual', 'Contains', 'IsTrue', 'IsFalse')]
        [string]$Operator,

        [Parameter()]
        $Expected
    )

    switch ($Operator) {
        'Equal'              { return $Actual -eq $Expected }
        'NotEqual'           { return $Actual -ne $Expected }
        'GreaterThan'        { return $Actual -gt $Expected }
        'LessThan'           { return $Actual -lt $Expected }
        'GreaterThanOrEqual' { return $Actual -ge $Expected }
        'LessThanOrEqual'    { return $Actual -le $Expected }
        'Contains'           { return "$Actual" -like "*$Expected*" }
        'IsTrue'             { return [bool]$Actual -eq $true }
        'IsFalse'            { return [bool]$Actual -eq $false }
    }

    return $false
}
