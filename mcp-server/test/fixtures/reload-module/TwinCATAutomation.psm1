# Test fixture (#41, no IDE): the smallest module the REAL bridge/bridge.ps1 can load to exercise
# op 'retire' (ReloadModule). It keeps an in-memory lifecycle block table under the same name as the
# real module ($script:TcLifecycleBlockLocal, Private/LifecycleBlock.ps1) and never writes a state
# file. Loaded by test/reload.test.js; the file name keeps the module name 'TwinCATAutomation'.

$script:TcLifecycleBlockLocal = @{}
$script:TcDte = $null
$script:TcAdsConnected = $false
$script:TcIdeProcessId = $null

function Connect-TcIde {
    <#
    .SYNOPSIS
        Fixture: marks the IDE as connected.
    #>
    [CmdletBinding()]
    param()
    $script:TcDte = [PSCustomObject]@{ fake = $true }
    $script:TcIdeProcessId = 4242
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 4242 } }
}

function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Fixture: releases the fake IDE reference.
    #>
    [CmdletBinding()]
    param()
    $script:TcDte = $null
    $script:TcIdeProcessId = $null
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{} }
}

function Disconnect-TcAds {
    <#
    .SYNOPSIS
        Fixture: drops the fake ADS connection.
    #>
    [CmdletBinding()]
    param()
    $script:TcAdsConnected = $false
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{} }
}

function Set-TcSystemState {
    <#
    .SYNOPSIS
        Fixture: records an in-memory lifecycle block and fails like a Set-TcSystemState that sent its request.
    .PARAMETER AmsNetId
        Target of the fake block.
    #>
    [CmdletBinding()]
    param([string]$AmsNetId = '5.1.2.3.1.1')
    $script:TcLifecycleBlockLocal[$AmsNetId.ToLowerInvariant()] = [PSCustomObject]@{ amsNetId = $AmsNetId; command = 'Set-TcSystemState'; errorCode = 'SYSTEM_STATE_TIMEOUT' }
    [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SYSTEM_STATE_TIMEOUT'; message = 'fixture: state not reached' } }
}

Export-ModuleMember -Function Connect-TcIde, Disconnect-TcIde, Disconnect-TcAds, Set-TcSystemState
