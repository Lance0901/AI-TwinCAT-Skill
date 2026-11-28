# The two Visual Studio options that make a build bring tool windows up (PR #332 round 3, A-3: a minimized VS2022 was restored and got
# the foreground on the FIRST BuildProject of a session, not on later ones; the screenshot after it shows the Error List with the 6
# errors in front). Tools > Options > Projects and Solutions > General:
#   ShowOutputWindowBeforeBuild  "Show Output window when build starts"
#   ShowTaskListAfterBuild       "Always show Error List if build finishes with errors"
# DTE.Properties('Environment', 'ProjectsAndSolution') (https://learn.microsoft.com/en-us/visualstudio/extensibility/internals/
# options-page-reference or the "Determining the names of property items on Options pages" list, page Environment / ProjectsAndSolution).
# 初判 (not reproduced on a visible minimized IDE by the author): the first build shows those windows because they are not on screen
# yet; showing a tool window restores the main frame. Build-TcProject turns both off for the build and puts the user's values back
# afterwards (read back), so the build does not touch the window. A host without the page (property read fails) is left as it is.

$script:TcBuildAutoShowNames = @('ShowOutputWindowBeforeBuild', 'ShowTaskListAfterBuild')

function Get-TcProjectsAndSolutionProperties {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dte)
    # DTE.Properties is a parameterized property: GetProperty with two arguments through IDispatch (read and written on VS2022 17,
    # 實測 2026-11-28); a unit-test mock has it as a script method
    if ($Dte -is [System.__ComObject]) { return , (Get-TcComMember -Object $Dte -Name 'Properties' -Arguments @('Environment', 'ProjectsAndSolution')) }
    return , ($Dte.Properties('Environment', 'ProjectsAndSolution'))
}

function Disable-TcBuildAutoShow {
    <#
    .SYNOPSIS
        Turns ShowOutputWindowBeforeBuild / ShowTaskListAfterBuild off for one build. Returns
        @{ read; before = @{ name = bool }; changed = @(names); error }; pass it to Restore-TcBuildAutoShow.
        Never throws (an RPC failure / dead IDE rethrows through Test-TcComMustRethrow).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dte)
    $state = [PSCustomObject]@{ read = $false; before = [ordered]@{}; changed = @(); error = $null }
    try {
        $props = Get-TcProjectsAndSolutionProperties -Dte $Dte
        foreach ($n in $script:TcBuildAutoShowNames) {
            $item = Get-TcComMember -Object $props -Name 'Item' -Arguments @($n) -Method
            $v = [bool](Get-TcComMember -Object $item -Name 'Value')
            $state.before[$n] = $v
        }
        $state.read = $true
        foreach ($n in $script:TcBuildAutoShowNames) {
            if (-not $state.before[$n]) { continue }
            $item = Get-TcComMember -Object $props -Name 'Item' -Arguments @($n) -Method
            Set-TcComValue -Object $item -Value $false
            $state.changed = @($state.changed) + $n
        }
    }
    catch {
        if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
        $state.error = $_.Exception.Message
    }
    return $state
}

function Restore-TcBuildAutoShow {
    <#
    .SYNOPSIS
        Writes back what Disable-TcBuildAutoShow changed and reads it back: @{ restored; changed; error }.
        restored = $true when nothing was changed or every changed option reads back its old value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Dte, [AllowNull()]$State)
    $out = [PSCustomObject]@{ restored = $true; changed = @(); error = $null }
    if ($null -eq $State -or @($State.changed).Count -eq 0) { return $out }
    $out.changed = @($State.changed)
    try {
        $props = Get-TcProjectsAndSolutionProperties -Dte $Dte
        foreach ($n in @($State.changed)) {
            $item = Get-TcComMember -Object $props -Name 'Item' -Arguments @($n) -Method
            Set-TcComValue -Object $item -Value ([bool]$State.before[$n])
            if ([bool](Get-TcComMember -Object $item -Name 'Value') -ne [bool]$State.before[$n]) { $out.restored = $false }
        }
    }
    catch {
        if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
        $out.restored = $false
        $out.error = $_.Exception.Message
    }
    return $out
}

function Set-TcComValue {
    # Property.Value = <v> through IDispatch (a real COM object), ordinary assignment otherwise (unit-test mocks)
    param([Parameter(Mandatory)]$Object, $Value)
    if ($Object -is [System.__ComObject]) {
        [void][System.__ComObject].InvokeMember('Value', [Reflection.BindingFlags]::SetProperty, $null, $Object, @($Value))
        return
    }
    $Object.Value = $Value
}
