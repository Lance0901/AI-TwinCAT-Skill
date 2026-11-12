function Get-TcTimeScale {
    <#
    .SYNOPSIS
        #241: the factor a wait is scaled by, read from a module variable ($script:TcAdsWaitTimeScale,
        $script:TcResetTimeScale). 1.0 (real seconds) unless a unit test lowered it.
    .DESCRIPTION
        Only tests/Unit set these variables (& (Get-Module TwinCATAutomation) { $script:<name> = 0.25 })
        so a mocked timeout does not cost real seconds. Anything that is not a number in (0, 1] gives
        1.0: the product never waits longer, and a broken value cannot make it wait shorter than 0.
    .PARAMETER Value
        The value of the module variable ($null when it is not set).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    $s = 1.0
    if ($null -ne $Value) { try { $s = [double]$Value } catch { $s = 1.0 } }
    if (-not ($s -gt 0 -and $s -le 1)) { $s = 1.0 }
    $s
}
