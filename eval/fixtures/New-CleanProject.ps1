<#
.SYNOPSIS
    Builds the clean eval start project from the XAE templates: one TwinCAT XAE project + one Standard PLC
    project (MAIN + PlcTask), solution platform 'TwinCAT OS (x64)'. Test-environment setup only; the AI under
    test never runs this.
.DESCRIPTION
    Starts its own IDE through COM (default TcXaeShell.DTE.17.0 = 64-bit XAE Shell 4026), records the pid of the
    process that appeared, never touches an IDE that ran before, and quits / kills only that pid at the end.

    Automation Interface calls (TE1000 manual v1.7.0 chapters 5.1 / 5.2,
    https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf;
    InfoSys "Accessing TwinCAT configuration"
    https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html):
      Solution.Create(dir, name)
      Solution.AddFromTemplate(<TwinCAT3Dir>\Components\Base\PrjTemplate\TwinCAT Project.tsproj, dir, name)
      ITcSysManager.LookupTreeItem('TIPC').CreateChild(<plc>, 0, '', 'Standard PLC Template.plcproj')
      Project.Save(), Solution.SaveAs(sln)
    'Standard PLC Template.plcproj' as vInfo on 4026: measured in this repository (CreateChild TIPC,
    openspec/changes/complete-automation-interface/verification/issue104-realmachine.md).

    Output: OutDir\<Name>.sln, OutDir\<Name>\<Name>.tsproj, OutDir\<Name>\<Plc>\<Plc>.plcproj. Writes one JSON
    line 'NEW_CLEAN_PROJECT {...}' with the IDE pid, the solution platforms and the active configuration.
.PARAMETER OutDir
    Target folder; must not exist or be empty.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutDir,
    [string]$Name = 'EvalProject',
    [string]$PlcName = 'Plc',
    [string]$ProgId = 'TcXaeShell.DTE.17.0',
    [string]$Platform = 'TwinCAT OS (x64)'
)
$ErrorActionPreference = 'Stop'

function Invoke-Com([scriptblock]$Block, [int]$Tries = 60) {
    for ($i = 1; ; $i++) {
        try { return & $Block }
        catch {
            # RPC_E_CALL_REJECTED 0x80010001 / RPC_E_SERVERCALL_RETRYLATER 0x8001010A: IDE busy, try again
            $h = $_.Exception.HResult; if ($_.Exception.InnerException) { $h = $_.Exception.InnerException.HResult }
            if ($i -ge $Tries -or ($h -ne -2147418111 -and $h -ne -2147417846)) { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

if ((Test-Path -LiteralPath $OutDir) -and (Get-ChildItem -LiteralPath $OutDir -Force | Select-Object -First 1)) { throw "OutDir not empty: $OutDir" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$template = Join-Path $env:TWINCAT3DIR 'Components\Base\PrjTemplate\TwinCAT Project.tsproj'
if (-not (Test-Path -LiteralPath $template)) { throw "template not found: $template" }

$before = @(Get-Process TcXaeShell, devenv -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
$dte = New-Object -ComObject $ProgId
$ide = @(Get-Process TcXaeShell, devenv -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.Id })
if ($ide.Count -ne 1) { throw "expected exactly one new IDE process, found $($ide.Count); nothing done (check the IDE processes by hand)" }
$idePid = $ide[0].Id
Write-Output "IDE started: $($ide[0].ProcessName) pid $idePid"
$result = [ordered]@{ ideProcessId = $idePid; progId = $ProgId }
try {
    Invoke-Com { $dte.SuppressUI = $true } | Out-Null
    Invoke-Com { $dte.MainWindow.Visible = $false } | Out-Null
    $step = 'Solution.Create'
    # a cold XAE Shell answers DTE calls before it has loaded: wait until Solution is there (cold start up to ~150 s)
    $deadline = (Get-Date).AddSeconds(300); $sol = $null
    while ($null -eq $sol -and (Get-Date) -lt $deadline) {
        try { $sol = $dte.Solution } catch { }
        if ($null -eq $sol) { Start-Sleep -Seconds 2 }
    }
    if ($null -eq $sol) { throw 'DTE.Solution still null after 300 s' }
    Invoke-Com { $sol.Create($OutDir, $Name) } | Out-Null
    $projDir = Join-Path $OutDir $Name
    $step = 'AddFromTemplate'
    Invoke-Com { $sol.AddFromTemplate($template, $projDir, $Name, $false) } | Out-Null
    # AddFromTemplate returns null for a project template in VS-based shells: read the project back from the solution
    $proj = Invoke-Com { $sol.Projects.Item(1) }
    if ($null -eq $proj) { throw 'no project in the solution after AddFromTemplate' }
    $step = 'CreateChild PLC'
    # Project.Object (ITcSysManager) can be null for a moment after the project was added (the module retries too)
    $sysMan = $null
    for ($i = 0; $i -lt 30 -and $null -eq $sysMan; $i++) { try { $sysMan = $proj.Object } catch { }; if ($null -eq $sysMan) { Start-Sleep -Seconds 1 } }
    if ($null -eq $sysMan) { throw 'Project.Object (ITcSysManager) still null after 30 s' }
    # ITcSmTreeItem is enumerable (its children): returned through a script block / pipeline PowerShell unrolls it
    # (TIPC without children -> $null), so tree items are read with direct calls
    $tipc = $sysMan.LookupTreeItem('TIPC')
    $null = $tipc.CreateChild($PlcName, 0, '', 'Standard PLC Template.plcproj')
    $plc = $sysMan.LookupTreeItem("TIPC^$PlcName")
    $result.plcPath = Invoke-Com { $plc.PathName }
    $step = 'save / platform'
    Invoke-Com { $proj.Save() } | Out-Null
    $slnPath = Join-Path $OutDir "$Name.sln"
    Invoke-Com { $sol.SaveAs($slnPath) } | Out-Null

    # Solution platform: the active one is kept per user in .vs\...\.suo, which the eval copy does not carry
    # (run-case.ps1 skips .vs), so the session selects it with SetTarget / RunLifecycle Platform. Here: check that
    # every project of the .sln builds in Debug|<Platform>.
    $step = 'platform check'
    $slnText = [System.IO.File]::ReadAllText($slnPath)
    $result.solutionPlatforms = @([regex]::Matches($slnText, '(?m)^\s*(Debug\|[^=]+?) = ') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $projGuids = @([regex]::Matches($slnText, '(?m)^Project\("[^"]+"\) = "[^"]+", "[^"]+", "(\{[^}]+\})"') | ForEach-Object { $_.Groups[1].Value })
    $missing = @($projGuids | Where-Object { $slnText -notmatch [regex]::Escape("$_.Debug|$Platform.Build.0") })
    if ($result.solutionPlatforms -notcontains "Debug|$Platform" -or $missing.Count -gt 0) { throw "Debug|$Platform missing or not built for $($missing -join ', ')" }
    $result.solution = $slnPath
    $result.success = $true
} catch {
    $result.success = $false
    $result.error = $_.Exception.Message
    $result.failedStep = $step
    $result.errorLine = $_.InvocationInfo.ScriptLineNumber; $result.errorText = $_.InvocationInfo.Line.Trim()
} finally {
    try { Invoke-Com { $sol.Close($false) } 5 | Out-Null } catch { }
    try { Invoke-Com { $dte.Quit() } 5 | Out-Null } catch { }
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($dte) | Out-Null
    $p = Get-Process -Id $idePid -ErrorAction SilentlyContinue
    if ($p -and -not $p.WaitForExit(30000)) { Stop-Process -Id $idePid -Force; $result.ideKilled = $true; $null = $p.WaitForExit(10000) }
    $result.ideClosed = $null -eq (Get-Process -Id $idePid -ErrorAction SilentlyContinue)
}
Write-Output ('NEW_CLEAN_PROJECT ' + ($result | ConvertTo-Json -Compress -Depth 4))
if (-not $result.success) { exit 1 }
