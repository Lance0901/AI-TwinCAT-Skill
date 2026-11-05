# Test fixture (#41 review round 2): a module in the format of the branches opened BEFORE #41
# ($script:TcLifecycleBlockLocal / $script:TcBuildRequiredLocal exist, Get-TcLifecycleBlockLocalForReload
# and Merge-TcBuildRequiredEntry do not). Same body as reload-module\TwinCATAutomation.psm1.
$script:TcFixtureOldFormat = $true
. (Join-Path $PSScriptRoot '..\reload-module\fixture-body.ps1')
Export-ModuleMember -Function Connect-TcIde, Disconnect-TcIde, Disconnect-TcAds, Set-TcSystemState, Register-TcCodeChange
