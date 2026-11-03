# Failure of a cycle step (#68): keeps the step's code, hint and data.lifecycleBlock; -Data (or a new
# object) gets steps.
function New-TcCycleStepFailure {
    param([object]$StepResult, [string]$Prefix, [string]$DefaultCode, [object[]]$Steps, [object]$Data)
    $code = $DefaultCode; $msg = ''; $hint = $null
    if ($null -ne $StepResult -and $null -ne $StepResult.error) {
        if (-not [string]::IsNullOrWhiteSpace([string]$StepResult.error.code)) { $code = [string]$StepResult.error.code }
        $msg = [string]$StepResult.error.message
        $hp = $StepResult.error.PSObject.Properties['hint']
        if ($null -ne $hp) { $hint = [string]$hp.Value }
    }
    if ([string]::IsNullOrWhiteSpace($hint)) { $hint = Get-TcErrorHint -Code $code }
    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    $Data | Add-Member -NotePropertyName 'steps' -NotePropertyValue @($Steps) -Force
    if ($null -ne $StepResult -and $null -ne $StepResult.data -and $null -ne $StepResult.data.PSObject.Properties['lifecycleBlock']) {
        $Data | Add-Member -NotePropertyName 'lifecycleBlock' -NotePropertyValue $StepResult.data.lifecycleBlock -Force
    }
    $p = @{ Success = $false; ErrorMessage = "${Prefix}: $msg"; ErrorCode = $code; Data = $Data }
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $p['Hint'] = $hint }
    New-TcResult @p
}
