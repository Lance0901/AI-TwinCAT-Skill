# Execution-policy advice shared by scripts/check.ps1 (#25, #144). Same logic as
# mcp-server/scripts/check-execution-policy.mjs.
# A group policy (MachinePolicy / UserPolicy in Get-ExecutionPolicy -List) wins over
# Set-ExecutionPolicy -Scope CurrentUser, so for it the advice is "ask IT", not that command.

# No double quotes in it: they are lost when it is passed as a powershell.exe argument.
# Command run in a Windows PowerShell child: first line = effective policy, then "<Scope>=<Policy>" lines.
$script:TcPolicyCommand = 'Get-ExecutionPolicy; Get-ExecutionPolicy -List | ForEach-Object { (''{0}={1}'' -f $_.Scope, $_.ExecutionPolicy) }'

function Get-TcPolicyAdvice {
    [CmdletBinding()]
    param([string]$Effective, [string[]]$ListLines = @())
    if ($Effective -ne 'Restricted' -and $Effective -ne 'AllSigned') { return $null }
    $gpo = New-Object System.Collections.Generic.List[string]
    foreach ($line in $ListLines) {
        if ($line -match '^\s*(MachinePolicy|UserPolicy)\s*=\s*(\w+)\s*$' -and $Matches[2] -ne 'Undefined') { $gpo.Add("$($Matches[1])=$($Matches[2])") }
    }
    if ($gpo.Count -gt 0) {
        return "Windows PowerShell execution policy is $Effective, set by group policy ($($gpo -join ', ')): local scripts cannot run and Set-ExecutionPolicy cannot override it. Ask your IT administrator."
    }
    "Windows PowerShell execution policy is ${Effective}: local scripts cannot run. Run once: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}
