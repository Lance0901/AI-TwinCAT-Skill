<#
.SYNOPSIS
    Runs one AI behaviour eval case end to end: fixture copy -> headless Claude Code session with only the
    tcauto MCP server -> grade.ps1 over ADS -> close the IDEs the session opened -> score.ps1.
.DESCRIPTION
    Layout of one run (RunsRoot\<case>-<yyyyMMdd-HHmmss>\):
      <project files>          copy of FixtureRoot\<fixture> (read-only flags removed); the session works here
      _eval\prompt.txt         the prompt sent on stdin ({{SOLUTION_PATH}} replaced)
      _eval\mcp.json           MCP config: only tcauto, env TCAUTO_TRACE_FILE = _eval\trace.jsonl
      _eval\trace.jsonl        tool-call trace written by the tcauto server (docs/setup-mcp.md "Tool-call trace")
      _eval\stream.jsonl       claude -p --output-format stream-json (the session transcript)
      _eval\stderr.txt         claude stderr
      _eval\run.json           what the harness saw: times, exit code, IDE / UmRT snapshots, loaded context files
      _eval\grade.json         grade.ps1 result
      _eval\result.json, report.md   score.ps1 output

    TCAUTO_TRACE_FILE reaches the tcauto server both from the mcp-config "env" and from the environment of
    claude.exe (measured 2026-11-16, Claude Code 2.1.319, launcher runtime d3e8080); the harness sets both.

    The session runs with --strict-mcp-config (no other MCP server) in the run folder, which is outside
    this repository, so the repository CLAUDE.md is not loaded. The user's global ~/.claude (CLAUDE.md,
    settings hooks, skills, plugins, output style) still is: run.json records what was there.

    Safety: IDE processes running before the session are recorded as protected and never touched. After
    the session, only devenv / TcXaeShell processes that started after the session started are closed.
.PARAMETER Case
    Folder name below eval\cases (default 1.1-fb-axis).
.PARAMETER Model
    Model for the session (default claude-opus-5-5).
.PARAMETER FixtureRoot
    Folder with the read-only fixtures (default C:\Temp\eval\fixtures).
.PARAMETER RunsRoot
    Folder for the runs (default C:\Temp\eval\runs).
.PARAMETER TimeoutMin
    Deadline for the session; the claude process tree is killed after it (default 60).
.PARAMETER RunDir
    Re-use an existing run folder: skip copy and session, only grade (unless -SkipGrade), clean up and score.
.PARAMETER SkipGrade
    With -RunDir: keep the existing grade.json.
.PARAMETER ClaudePath
    claude executable (default: claude on PATH).
#>
[CmdletBinding()]
param(
    [string]$Case = '1.1-fb-axis',
    [string]$Model = 'claude-opus-5-5',
    [string]$FixtureRoot = 'C:\Temp\eval\fixtures',
    [string]$RunsRoot = 'C:\Temp\eval\runs',
    [int]$TimeoutMin = 60,
    [string]$RunDir,
    [switch]$SkipGrade,
    [string]$ClaudePath
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'lib\EvalCommon.ps1')

$caseDir = Join-Path $PSScriptRoot "cases\$Case"
$caseDef = [System.IO.File]::ReadAllText((Join-Path $caseDir 'case.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Write-Step([string]$Text) { Write-Output ("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Text) }

$reuse = [bool]$RunDir
if (-not $reuse) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $RunDir = Join-Path $RunsRoot "$Case-$stamp"
}
$evalDir = Join-Path $RunDir '_eval'
$runJsonPath = Join-Path $evalDir 'run.json'

if ($reuse) {
    $run = [System.IO.File]::ReadAllText($runJsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    # run.json of the first pilot run nested protectedIdes one level deeper ([[...]]): flatten
    $run.protectedIdes = @($run.protectedIdes | ForEach-Object { $_ })
} else {
    # --- 1. fixture copy ---------------------------------------------------------------------------
    $fixture = Join-Path $FixtureRoot $caseDef.fixture
    if (-not (Test-Path -LiteralPath $fixture)) { throw "fixture not found: $fixture" }
    New-Item -ItemType Directory -Force -Path $evalDir | Out-Null
    Write-Step "copy $fixture -> $RunDir"
    $null = & robocopy.exe $fixture $RunDir /E /A-:R /XD _Boot _CompileInfo .vs .tcauto-backup /XF '*.~u' /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed with exit code $LASTEXITCODE" }
    Get-ChildItem -LiteralPath $RunDir -Recurse -File | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    $solution = Join-Path $RunDir $caseDef.solution

    # --- 2. prompt, MCP config ------------------------------------------------------------------------
    $promptText = [System.IO.File]::ReadAllText((Join-Path $caseDir $caseDef.prompt), [System.Text.Encoding]::UTF8)
    $promptText = $promptText.Replace('{{SOLUTION_PATH}}', $solution)
    $promptFile = Join-Path $evalDir 'prompt.txt'
    [System.IO.File]::WriteAllText($promptFile, $promptText, [System.Text.UTF8Encoding]::new($false))

    $traceFile = Join-Path $evalDir 'trace.jsonl'
    $userCfg = [System.IO.File]::ReadAllText((Join-Path $env:USERPROFILE '.claude.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $tc = $userCfg.mcpServers.tcauto
    if ($null -eq $tc) { throw 'no user-scope tcauto MCP server registered (claude mcp add ... tcauto)' }
    $mcp = [ordered]@{ mcpServers = [ordered]@{ tcauto = [ordered]@{
        type    = 'stdio'
        command = [string]$tc.command
        args    = @($tc.args)
        env     = [ordered]@{ TCAUTO_TRACE_FILE = $traceFile }
    } } }
    $mcpFile = Join-Path $evalDir 'mcp.json'
    Write-EvalJson -InputObject $mcp -Path $mcpFile

    # --- 3. snapshots before -------------------------------------------------------------------------
    $claudeHome = Join-Path $env:USERPROFILE '.claude'
    $contextFiles = @()
    foreach ($f in @((Join-Path $claudeHome 'CLAUDE.md'))) {
        if (Test-Path -LiteralPath $f) { $contextFiles += [ordered]@{ path = $f; scope = 'user'; bytes = (Get-Item -LiteralPath $f).Length; sha256 = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash } }
    }
    $d = Get-Item -LiteralPath $RunDir
    while ($null -ne $d) {
        foreach ($n in 'CLAUDE.md', 'CLAUDE.local.md', 'AGENTS.md') {
            $p = Join-Path $d.FullName $n
            if (Test-Path -LiteralPath $p) { $contextFiles += [ordered]@{ path = $p; scope = 'project-or-parent'; bytes = (Get-Item -LiteralPath $p).Length } }
        }
        $d = $d.Parent
    }
    $hooks = $null
    try { $hooks = ([System.IO.File]::ReadAllText((Join-Path $claudeHome 'settings.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json).hooks } catch { }
    $hookSummary = @()
    if ($null -ne $hooks) {
        foreach ($ev in $hooks.PSObject.Properties) {
            foreach ($h in @($ev.Value)) { foreach ($hh in @($h.hooks)) { $hookSummary += ('{0} [{1}] {2}' -f $ev.Name, $h.matcher, $hh.command) } }
        }
    }

    $runtimeCommit = $null
    try { $runtimeCommit = ([System.IO.File]::ReadAllText((Join-Path $env:LOCALAPPDATA 'TwinCATAutomation\runtime\current.json')) | ConvertFrom-Json).commit } catch { }

    $run = [ordered]@{
        case               = $Case
        model              = $Model
        runDir             = $RunDir
        solution           = $solution
        fixture            = $fixture
        tcautoRuntime      = $runtimeCommit
        umrtAmsNetId       = (Get-EvalUmRtAmsNetId -Name $caseDef.runtime)
        protectedIdes      = @(Get-EvalIdeProcesses)
        umrtBefore         = @(Get-Process TcSystemServiceUm -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ pid = $_.Id; startTime = $_.StartTime.ToString('o') } })
        contextFiles       = $contextFiles
        userHooks          = $hookSummary
        sessionStartedAt   = $null
        sessionFinishedAt  = $null
        sessionExitCode    = $null
        sessionTimedOut    = $false
        idesAfter          = @()
        idesClosed         = @()
        protectedIdesAlive = $null
        umrtAfter          = @()
        gradeExitCode      = $null
        notes              = @()
    }

    # --- 4. session ------------------------------------------------------------------------------------
    if (-not $ClaudePath) { $ClaudePath = (Get-Command claude -ErrorAction Stop).Source }
    $claudeArgs = @('-p', '--model', $Model, '--permission-mode', 'bypassPermissions', '--strict-mcp-config',
        '--mcp-config', "`"$mcpFile`"", '--output-format', 'stream-json', '--verbose')
    $env:TCAUTO_TRACE_FILE = $traceFile
    $run.sessionStartedAt = (Get-Date).ToString('o')
    Write-EvalJson -InputObject $run -Path $runJsonPath
    Write-Step "session start: $ClaudePath $($claudeArgs -join ' ') < prompt.txt (timeout $TimeoutMin min)"
    $proc = Start-Process -FilePath $ClaudePath -ArgumentList $claudeArgs -WorkingDirectory $RunDir -NoNewWindow -PassThru `
        -RedirectStandardInput $promptFile -RedirectStandardOutput (Join-Path $evalDir 'stream.jsonl') -RedirectStandardError (Join-Path $evalDir 'stderr.txt')
    $run.sessionPid = $proc.Id
    if (-not $proc.WaitForExit($TimeoutMin * 60 * 1000)) {
        $run.sessionTimedOut = $true
        Write-Step "session timeout: killing process tree $($proc.Id)"
        & taskkill.exe /T /F /PID $proc.Id | Out-Null
        $proc.WaitForExit(30000) | Out-Null
    }
    $run.sessionFinishedAt = (Get-Date).ToString('o')
    try { $run.sessionExitCode = $proc.ExitCode } catch { }
    Remove-Item Env:\TCAUTO_TRACE_FILE -ErrorAction SilentlyContinue
    Write-Step "session end: exit $($run.sessionExitCode)"

    # copy Claude Code's own transcript of the session, when it can be found
    try {
        $sid = $null
        foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $evalDir 'stream.jsonl'), [System.Text.Encoding]::UTF8)) {
            if ($line -match '"session_id":"([0-9a-f-]{36})"') { $sid = $Matches[1]; break }
        }
        if ($sid) {
            $t = Get-ChildItem (Join-Path $claudeHome 'projects') -Recurse -Filter "$sid.jsonl" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($t) { Copy-Item -LiteralPath $t.FullName -Destination (Join-Path $evalDir 'session-transcript.jsonl'); $run.notes += "transcript copied from $($t.FullName)" }
        }
    } catch { $run.notes += "transcript copy failed: $($_.Exception.Message)" }
    Write-EvalJson -InputObject $run -Path $runJsonPath
}

# --- 5. grade -------------------------------------------------------------------------------------------
if (-not $SkipGrade) {
    Write-Step 'grade'
    $gradeOut = & $psExe -NoProfile -File (Join-Path $caseDir $caseDef.grade) -AmsNetId $run.umrtAmsNetId -OutFile (Join-Path $evalDir 'grade.json') 2>&1
    $run.gradeExitCode = $LASTEXITCODE
    [System.IO.File]::WriteAllLines((Join-Path $evalDir 'grade.log'), [string[]]@($gradeOut | ForEach-Object { "$_" }), [System.Text.UTF8Encoding]::new($false))
    Write-Step "grade exit $($run.gradeExitCode): $(@($gradeOut)[-1])"
}

# --- 6. clean up: IDEs started during the session --------------------------------------------------------
$protectedPids = @($run.protectedIdes | ForEach-Object { [int]$_.pid })
$started = [datetime]::Parse([string]$run.sessionStartedAt)
$after = @(Get-EvalIdeProcesses)
$run.idesAfter = $after
$closed = @()
foreach ($p in $after) {
    if ($protectedPids -contains $p.pid) { continue }
    if ([datetime]::Parse($p.startTime) -lt $started) { continue }
    # an IDE another tool opened meanwhile (e.g. AiDesk's TcXaeShell /RootSuffix AiPoc) is never ours
    if ($p.commandLine -match '/RootSuffix') { $run.notes += "left IDE $($p.pid) alone (RootSuffix): $($p.commandLine)"; continue }
    Write-Step "closing IDE started by the session: $($p.name) pid $($p.pid)"
    try { Stop-Process -Id $p.pid -Force -ErrorAction Stop; $closed += $p } catch { $run.notes += "could not stop $($p.pid): $($_.Exception.Message)" }
}
$run.idesClosed = $closed
$alive = @()
foreach ($p in $run.protectedIdes) {
    $live = Get-Process -Id ([int]$p.pid) -ErrorAction SilentlyContinue
    $alive += [ordered]@{ pid = [int]$p.pid; name = $p.name; alive = ($null -ne $live) }
}
$run.protectedIdesAlive = $alive
$run.umrtAfter = @(Get-Process TcSystemServiceUm -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ pid = $_.Id; startTime = $_.StartTime.ToString('o') } })
Write-EvalJson -InputObject $run -Path $runJsonPath

# --- 7. score --------------------------------------------------------------------------------------------
Write-Step 'score'
& $psExe -NoProfile -File (Join-Path $PSScriptRoot 'score.ps1') -RunDir $RunDir
Write-Step "done: $RunDir"
