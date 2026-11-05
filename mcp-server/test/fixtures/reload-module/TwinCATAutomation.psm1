# Test fixture (#41): a module in the CURRENT format for bridge/bridge.ps1 op 'retire'
# (body: fixture-body.ps1, which dot-sources the real Private state code).
$script:TcFixtureOldFormat = $false
. (Join-Path $PSScriptRoot 'fixture-body.ps1')
Export-ModuleMember -Function Connect-TcIde, Disconnect-TcIde, Disconnect-TcAds, Set-TcSystemState, Register-TcCodeChange
