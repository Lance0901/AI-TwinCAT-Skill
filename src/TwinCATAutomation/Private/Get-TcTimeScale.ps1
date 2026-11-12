function Get-TcTimeScale {
    <#
    .SYNOPSIS
        #241: the factor a wait is scaled by, read from a module variable ($script:TcAdsWaitTimeScale,
        $script:TcResetTimeScale). 1.0 (real seconds) unless a unit test lowered it.
    .DESCRIPTION
        Only tests/Unit set these variables (& (Get-Module TwinCATAutomation) { $script:<name> = 0.25 })
        so a mocked timeout does not cost real seconds. The value is converted to [double]; a result
        in (0, 1] is used as is (so also the string '0.5'; $true converts to 1), anything else ($null,
        unparsable, NaN, <= 0, > 1) gives 1.0. A test value can only shorten a wait, never lengthen
        it or make it zero (#251).
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
