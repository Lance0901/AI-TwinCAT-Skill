function Get-TcPlcNameFromPath {
    <#
    .SYNOPSIS
        PLC name of a tree path: 'TIPC^<Plc>^...' -> '<Plc>' ($null when the path is not below TIPC).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TreePath)
    $seg = $TreePath -split '\^'
    if ($seg.Count -ge 2 -and $seg[0] -ieq 'TIPC' -and -not [string]::IsNullOrWhiteSpace($seg[1])) { return $seg[1] }
    $null
}

function Get-TcPlcObjectRelativeFile {
    <#
    .SYNOPSIS
        Expected <Compile Include> of a top-level PLC object from its tree path:
        'TIPC^<Plc>^<Plc> Project^POUs^Sub^FB_X' + '.TcPOU' -> 'POUs\Sub\FB_X.TcPOU'.
    .DESCRIPTION
        PLC folders (ItemType 601) are folders on disk below the .plcproj folder and XAE writes
        <Compile Include="<folders>\<Name><ext>"> (measured 2026-10-28, 4026
        VisualStudio.DTE.17.0: AddPou in POUs -> 'POUs\FB_R76.TcPOU'). Returns only the file name
        when the path is not below '<Plc>^<Plc> Project' (format of 4024 and 4026).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TreePath,
        [Parameter(Mandatory)][string]$Extension
    )
    $seg = @($TreePath -split '\^')
    $leaf = $seg[-1] + $Extension
    if ($seg.Count -lt 4 -or $seg[0] -ine 'TIPC' -or $seg[2] -ine "$($seg[1]) Project") { return $leaf }
    if ($seg.Count -eq 4) { return $leaf }
    ((@($seg[3..($seg.Count - 2)]) + $leaf) -join '\')
}

function Get-TcPlcObjectFileExtension {
    <#
    .SYNOPSIS
        File extension XAE stores a top-level PLC object in, by ItemType ($null for other types).
    .DESCRIPTION
        602-604 POU -> .TcPOU, 605-607 / 623 DUT -> .TcDUT, 615 GVL -> .TcGVL, 618 ITF -> .TcIO.
        ItemType values: InfoSys "ITcSmTreeItem Item Types"
        (https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html); the
        extensions are the file names XAE writes into <Compile Include> (measured 2026-10-28,
        4026 VisualStudio.DTE.17.0 and 4024 TcXaeShell.DTE.15.0).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ItemType)
    switch ($ItemType) {
        { $_ -in 602, 603, 604 } { return '.TcPOU' }
        { $_ -in 605, 606, 607, 623 } { return '.TcDUT' }
        615 { return '.TcGVL' }
        618 { return '.TcIO' }
    }
    $null
}

function Get-TcPlcProjectFile {
    <#
    .SYNOPSIS
        Finds the DTE project (.tsproj) that holds PLC -PlcName and the .plcproj file of that PLC.
    .DESCRIPTION
        Walks DTE Solution.Projects for projects whose FullName ends in .tsproj and reads each
        such file from disk: the PLC is the <Project Name="<Plc>" PrjFilePath="<rel>.plcproj">
        element (present in the .tsproj of 4024 and 4026, measured 2026-10-28), the path is
        relative to the .tsproj folder.
        Independent project file (the PLC stored in its own .xti, InfoSys "Enabling and disabling
        an Independent Project File",
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842602763.html): InfoSys
        does not say where the .xti lies nor what PrjFilePath is relative to there. Not verified
        (no such project here): when no .tsproj lists the PLC, only <tsproj folder>\_Config\PLC\*.xti
        (not recursive) is searched for the same element and PrjFilePath is tried relative to the
        .tsproj folder, then to the .xti folder; only an existing .plcproj is accepted (ResolvedVia
        'xti'). More than one candidate throws "save: locate: ..." (no guessing).
        Several .tsproj listing the same PLC name: the first is used and Warning says so.
        Throws "save: locate: ..." when nothing matches (a .tsproj that cannot be read is named).
        Returns @{ DteProject; TsProjFile; PlcProjFile; UniqueName; ResolvedVia ('tsproj' | 'xti');
        Warning ($null or text) }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlcName)

    $dte = $script:TcDte
    $projects = Invoke-TcComRetry -OperationName 'Solution.Projects (.tsproj)' -ScriptBlock {
        $__list = [System.Collections.Generic.List[object]]::new()
        $__all = $dte.Solution.Projects
        for ($__i = 1; $__i -le [int]$__all.Count; $__i++) {
            $__p = $__all.Item($__i)
            $__full = $null
            try { $__full = [string]$__p.FullName } catch {
                if ($_.Exception.ToString() -match '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER') { throw }
                $__full = $null
            }
            if (-not [string]::IsNullOrWhiteSpace($__full) -and $__full -match '(?i)\.tsproj$') {
                $__uniq = $null; try { $__uniq = [string]$__p.UniqueName } catch { $__uniq = $null }
                $__list.Add(@{ Project = $__p; FullName = $__full; UniqueName = $__uniq })
            }
        }
        Write-Output -NoEnumerate $__list.ToArray()
    }

    $found = [System.Collections.Generic.List[object]]::new()
    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($p in @($projects)) {
        if (-not (Test-Path -LiteralPath $p.FullName)) { $problems.Add("'$($p.FullName)' not found on disk"); continue }
        $xml = New-Object System.Xml.XmlDocument
        try { $xml.Load($p.FullName) } catch { $problems.Add("'$($p.FullName)' could not be read ($($_.Exception.Message))"); continue }
        foreach ($node in @($xml.SelectNodes('//Project[@PrjFilePath]'))) {
            if ([string]$node.GetAttribute('Name') -ine $PlcName) { continue }
            $rel = [string]$node.GetAttribute('PrjFilePath')
            if ($rel -notmatch '(?i)\.plcproj$') { continue }
            $plcproj = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($p.FullName)) $rel))
            $found.Add(@{ DteProject = $p.Project; TsProjFile = $p.FullName; PlcProjFile = $plcproj; UniqueName = $p.UniqueName; ResolvedVia = 'tsproj'; Warning = $null })
        }
    }
    if ($found.Count -eq 0) {
        # Independent project file (.xti): best effort, see .DESCRIPTION (not verified).
        # Only <tsproj folder>\_Config\PLC\*.xti (no recursive search); several candidates -> throw.
        foreach ($p in @($projects)) {
            if (-not (Test-Path -LiteralPath $p.FullName)) { continue }
            $tsDir = [IO.Path]::GetDirectoryName($p.FullName)
            $xtiDir = Join-Path $tsDir '_Config\PLC'
            if (-not (Test-Path -LiteralPath $xtiDir -PathType Container)) { continue }
            foreach ($xti in @(Get-ChildItem -LiteralPath $xtiDir -Filter '*.xti' -File -ErrorAction SilentlyContinue)) {
                $xml = New-Object System.Xml.XmlDocument
                try { $xml.Load($xti.FullName) } catch { $problems.Add("'$($xti.FullName)' could not be read ($($_.Exception.Message))"); continue }
                foreach ($node in @($xml.SelectNodes('//Project[@PrjFilePath]'))) {
                    if ([string]$node.GetAttribute('Name') -ine $PlcName) { continue }
                    $rel = [string]$node.GetAttribute('PrjFilePath')
                    if ($rel -notmatch '(?i)\.plcproj$') { continue }
                    foreach ($base in @($tsDir, $xti.DirectoryName)) {
                        $cand = [IO.Path]::GetFullPath((Join-Path $base $rel))
                        if (Test-Path -LiteralPath $cand) {
                            $found.Add(@{ DteProject = $p.Project; TsProjFile = $p.FullName; PlcProjFile = $cand; UniqueName = $p.UniqueName; ResolvedVia = 'xti'
                                Warning = "PLC '$PlcName' was found in '$($xti.FullName)' (independent project file); this lookup is not verified on a real project." })
                            break
                        }
                    }
                }
            }
        }
        if ($found.Count -gt 1) {
            $cands = @($found | ForEach-Object { $_.PlcProjFile }) -join ', '
            throw "save: locate: PLC '$PlcName' is not listed in a .tsproj and $($found.Count) independent project file candidates (_Config\PLC\*.xti) match it ($cands); not guessing which one to use."
        }
    }
    if ($found.Count -eq 0) {
        $detail = if ($problems.Count -gt 0) { " ($($problems -join '; '))" } else { '' }
        throw "save: locate: no .tsproj of the open solution lists PLC '$PlcName' with a .plcproj (<Project Name=""$PlcName"" PrjFilePath=...>)$detail; the project file could not be located."
    }
    $first = $found[0]
    if ($found.Count -gt 1) {
        $all = @($found | ForEach-Object { $_.TsProjFile }) -join ', '
        $w = "PLC '$PlcName' is listed in $($found.Count) project files ($all); the first one is used: '$($first.TsProjFile)' -> '$($first.PlcProjFile)'."
        $first.Warning = if ([string]::IsNullOrWhiteSpace([string]$first.Warning)) { $w } else { "$($first.Warning) $w" }
    }
    $first
}

function Get-TcPlcProjectContent {
    <#
    .SYNOPSIS
        Reads a .plcproj from disk: Compile Include paths and library references.
    .DESCRIPTION
        Returns @{ Compile = [string[]] Include values; CompileLeaf = HashSet of file names
        (case-insensitive); CompilePath = HashSet of Include values with '/' as '\'
        (case-insensitive); Libraries = HashSet of PlaceholderReference / LibraryReference
        Include values, Namespace and the library name of DefaultResolution / Resolution
        ('Tc2_Standard, * (Beckhoff Automation GmbH)' -> 'Tc2_Standard') }.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $xml = New-Object System.Xml.XmlDocument
    $xml.Load($Path)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('m', [string]$xml.DocumentElement.NamespaceURI)
    $pre = if ([string]::IsNullOrEmpty([string]$xml.DocumentElement.NamespaceURI)) { '' } else { 'm:' }
    $compile = [System.Collections.Generic.List[string]]::new()
    $leaf = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($xml.SelectNodes("//${pre}Compile[@Include]", $ns))) {
        $inc = [string]$n.GetAttribute('Include')
        $compile.Add($inc)
        $null = $leaf.Add([IO.Path]::GetFileName($inc))
        $null = $paths.Add($inc.Replace('/', '\'))
    }
    $libs = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in @($xml.SelectNodes("//${pre}PlaceholderReference | //${pre}LibraryReference", $ns))) {
        $inc = [string]$n.GetAttribute('Include')
        if (-not [string]::IsNullOrWhiteSpace($inc)) { $null = $libs.Add($inc.Split(',')[0].Trim()) }
        foreach ($child in @($n.ChildNodes)) {
            if ($child.LocalName -in 'Namespace', 'DefaultResolution', 'Resolution') {
                $v = ([string]$child.InnerText).Split(',')[0].Trim()
                if (-not [string]::IsNullOrWhiteSpace($v)) { $null = $libs.Add($v) }
            }
        }
    }
    @{ Compile = [string[]]$compile.ToArray(); CompileLeaf = $leaf; CompilePath = $paths; Libraries = $libs }
}

function Test-TcPlcProjectHasFile {
    <#
    .SYNOPSIS
        True when the .plcproj content (Get-TcPlcProjectContent) lists -File: a relative path
        ('POUs\FB_X.TcPOU') must match a whole <Compile Include>, a bare file name any leaf.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Content, [Parameter(Mandatory)][string]$File)
    $f = $File.Replace('/', '\')
    if ($f.Contains('\')) { return $Content.CompilePath.Contains($f) }
    $Content.CompileLeaf.Contains($f)
}

function Invoke-TcProjectSaveWithDeadline {
    <#
    .SYNOPSIS
        DTE Project.Save() of the .tsproj project -TsProjFile with a real deadline (PROJECT_SAVE_TIMEOUT).
    .DESCRIPTION
        Same pattern as Invoke-TcActivateWithDeadline (CODING_STANDARDS.md rule 1): the call runs
        in a separate STA runspace on its own reference to the SAME IDE (DTE from the Running
        Object Table by the IDE pid, "!<ProgId>:<pid>", ComRotHelper); the project is the one of
        Solution.Projects whose FullName is -TsProjFile. RPC_E_CALL_REJECTED is retried inside the
        runspace (every 500 ms) until 1 s before the deadline and never after the caller set the
        shared cancel flag (on timeout), so no retried Save() starts after PROJECT_SAVE_TIMEOUT.
        The caller waits at most -TimeoutSec and looks
        for a modal dialog every 2 s ($script:TcLastModalDialog; never touches a window).
        On timeout the background call is abandoned (it cannot be cancelled; the IDE keeps
        working on it) and "PROJECT_SAVE_TIMEOUT: ..." is thrown; diagnostics in
        $script:TcLastProjectSaveDiagnostics: dialog (Title/Text), ideAlive, ideResponding,
        readOnlyFiles (-TsProjFile / -PlcProjFile with the ReadOnly attribute), elapsedSec.
        Errors of the call: IDE_CRASHED when the IDE process is gone, IDE_MODAL_DIALOG when a
        dialog is still up when the call returned (scanned again then; a dialog that is gone is
        only mentioned), otherwise "save: Project.Save of '<tsproj>' failed (<message>)".
    .PARAMETER TsProjFile
        Full path of the .tsproj (DTE Project.FullName).
    .PARAMETER PlcProjFile
        The .plcproj of the PLC (only for the diagnostics).
    .PARAMETER TimeoutSec
        Deadline for the call.
    .PARAMETER SaveScript
        Test hook: script text run in the background runspace instead of the real save
        (param($DtePid, $TsProj, $DeadlineSec, $Cancel)); used by tests/Unit/project-save.ps1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TsProjFile,
        [string]$PlcProjFile,
        [Parameter(Mandatory)][ValidateRange(1, 3600)][int]$TimeoutSec,
        [string]$SaveScript
    )

    $script:TcLastProjectSaveDiagnostics = $null
    $script:TcLastModalDialog = $null
    $idePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }

    $realScript = @'
param($DtePid, $TsProj, $DeadlineSec, $Cancel)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$entry = $null
foreach ($e in [ComRotHelper]::GetAllDteInstances()) {
    if ([string]$e['DisplayName'] -match (':' + $DtePid + '\s*$')) { $entry = $e; break }
}
if ($null -eq $entry) { throw "DTE of pid $DtePid not found in the Running Object Table" }
$dte = $entry['Object']
$want = [IO.Path]::GetFullPath($TsProj)
while ($true) {
    try {
        $proj = $null
        $all = $dte.Solution.Projects
        for ($i = 1; $i -le [int]$all.Count; $i++) {
            $p = $all.Item($i)
            $full = $null
            try { $full = [string]$p.FullName } catch { if ($_.Exception.ToString() -match '0x80010001|RPC_E_CALL_REJECTED') { throw } }
            if (-not [string]::IsNullOrWhiteSpace($full) -and [string]::Equals([IO.Path]::GetFullPath($full), $want, [StringComparison]::OrdinalIgnoreCase)) { $proj = $p; break }
        }
        if ($null -eq $proj) { throw "no project of the solution has FullName '$want'" }
        # the caller gave up (PROJECT_SAVE_TIMEOUT reported): never start a save after that
        if ($null -ne $Cancel -and $Cancel['Cancel']) { throw 'cancelled: the caller reported PROJECT_SAVE_TIMEOUT' }
        $proj.Save()
        'done'
        return
    }
    catch {
        if ($_.Exception.ToString() -match '0x80010001|RPC_E_CALL_REJECTED|0x8001010A|RPC_E_SERVERCALL_RETRYLATER' -and $sw.Elapsed.TotalSeconds -lt $DeadlineSec -and -not ($null -ne $Cancel -and $Cancel['Cancel'])) { Start-Sleep -Milliseconds 500; continue }
        throw
    }
}
'@
    $scriptText = if ([string]::IsNullOrWhiteSpace($SaveScript)) { $realScript } else { $SaveScript }
    if ([string]::IsNullOrWhiteSpace($SaveScript)) {
        if ($idePid -le 0) { throw "save: IDE process id unknown (Connect-TcIde first); cannot run Project.Save of '$TsProjFile' with a deadline." }
        $null = Get-AllComObjects   # loads ComRotHelper into this AppDomain (shared with the runspace)
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    # The background retry stops 1 s before the caller's deadline and on the shared cancel flag,
    # so no retried Save() starts after PROJECT_SAVE_TIMEOUT was reported (a Save() already
    # running when the deadline passes cannot be stopped; the message says so).
    $cancel = [hashtable]::Synchronized(@{ Cancel = $false })
    $retryDeadline = [Math]::Max(0, $TimeoutSec - 1)
    $null = $ps.AddScript($scriptText).AddArgument($idePid).AddArgument($TsProjFile).AddArgument($retryDeadline).AddArgument($cancel)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $async = $ps.BeginInvoke()
    $nextScan = 2.0
    $completed = $false
    try {
        while ($true) {
            if ($async.AsyncWaitHandle.WaitOne(250)) { $completed = $true; break }
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            if ($sw.Elapsed.TotalSeconds -ge $nextScan) {
                $nextScan = $sw.Elapsed.TotalSeconds + 2
                try {
                    $dlg = Get-TcIdeModalDialog
                    if ($null -ne $dlg) { $script:TcLastModalDialog = $dlg }
                } catch { }
            }
        }

        if ($completed) {
            $err = $null
            try { $null = $ps.EndInvoke($async) } catch { $err = $_.Exception }
            if ($null -eq $err -and $ps.HadErrors -and $ps.Streams.Error.Count -gt 0) { $err = $ps.Streams.Error[0].Exception }
            if ($null -ne $err) {
                # EndInvoke wraps the error of the runspace ("Exception calling EndInvoke ..."): report the inner one
                $msg = if ($null -ne $err.InnerException) { $err.InnerException.Message } else { $err.Message }
                $ideGone = $false
                if ($idePid -gt 0) { try { $null = Get-Process -Id $idePid -ErrorAction Stop } catch { $ideGone = $true } }
                if ($ideGone) {
                    $script:TcLastIdeCrash = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg"
                    $script:TcIdeConnected = $false
                    $script:TcSysManager = $null
                    $script:TcDte = $null
                    $script:TcIdeProcessId = $null
                    throw "IDE_CRASHED: the IDE process (pid $idePid) no longer exists after 'Project.Save' failed ($([int]$sw.Elapsed.TotalSeconds) s, original error: $msg). The XAE crashed; module IDE state was reset."
                }
                # A dialog seen during the call may be gone by now: scan again, only a dialog that
                # is still up makes it IDE_MODAL_DIALOG.
                $seen = $script:TcLastModalDialog
                $dlgNow = $null
                try { $dlgNow = Get-TcIdeModalDialog } catch { $dlgNow = $null }
                $script:TcLastModalDialog = $dlgNow
                if ($null -ne $dlgNow) {
                    $t = [string]$dlgNow.Text
                    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
                    throw "IDE_MODAL_DIALOG: $($dlgNow.Title) | $t (operation 'Project.Save', original error: $msg)"
                }
                $seenNote = if ($null -ne $seen) { "; a dialog '$($seen.Title)' was up during the call and is gone now" } else { '' }
                throw "save: Project.Save of '$TsProjFile' failed ($msg)$seenNote."
            }
            return
        }

        # --- deadline passed: stop the background retries, collect diagnostics, abandon the call ---
        $cancel['Cancel'] = $true
        $diag = [ordered]@{ dialog = $null; ideAlive = $null; ideResponding = $null; readOnlyFiles = @(); elapsedSec = [int]$sw.Elapsed.TotalSeconds }
        try {
            $dlg = Get-TcIdeModalDialog
            if ($null -eq $dlg) { $dlg = $script:TcLastModalDialog }
            if ($null -ne $dlg) { $script:TcLastModalDialog = $dlg; $diag.dialog = [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } }
        } catch { }
        if ($idePid -gt 0) {
            try { $proc = Get-Process -Id $idePid -ErrorAction Stop; $diag.ideAlive = $true; $diag.ideResponding = [bool]$proc.Responding }
            catch { $diag.ideAlive = $false }
        }
        $ro = [System.Collections.Generic.List[string]]::new()
        foreach ($f in @($TsProjFile, $PlcProjFile)) {
            if ([string]::IsNullOrWhiteSpace($f)) { continue }
            try { if ((Get-Item -LiteralPath $f -ErrorAction Stop).IsReadOnly) { $ro.Add($f) } } catch { }
        }
        $diag.readOnlyFiles = $ro.ToArray()
        $script:TcLastProjectSaveDiagnostics = [PSCustomObject]$diag
        $parts = @()
        if ($null -ne $diag.dialog) { $parts += "modal dialog '$($diag.dialog.title)'" }
        if ($diag.ideAlive -eq $false) { $parts += 'IDE process gone' }
        elseif ($diag.ideResponding -eq $false) { $parts += 'IDE not responding' }
        if ($ro.Count -gt 0) { $parts += "read-only: $($ro -join ', ')" }
        throw "PROJECT_SAVE_TIMEOUT: Project.Save of '$TsProjFile' did not return within $TimeoutSec s; the call was abandoned (it keeps running inside the IDE). $($parts -join '; ')"
    }
    finally {
        if ($completed) {
            try { $ps.Dispose() } catch { }
            try { $rs.Dispose() } catch { }
        }
        else {
            # Never block on a call that does not return: stop asynchronously and leave the runspace.
            try { $null = $ps.BeginStop($null, $null) } catch { }
        }
    }
}

function Save-TcPlcProject {
    <#
    .SYNOPSIS
        Saves only the project files (.tsproj + its .plcproj) of PLC -PlcName and reads
        the .plcproj back from disk (#76).
    .DESCRIPTION
        Objects created through the Automation Interface (CreateChild) are written to their
        own .TcPOU / .TcDUT / .TcGVL at once, but the .plcproj (<Compile Include>) only lives in XAE
        memory until the project is saved: Reset-TcSolution (Solution.Close without saving) then
        drops them (measured 2026-10-28, 4026 VisualStudio.DTE.17.0, issue #76).
        Save call: DTE Project.Save() on the .tsproj project, the call the InfoSys Automation
        Interface sample uses to persist a project ("Accessing TwinCAT configuration", C# sample
        project.Save(), https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html,
        checked 2026-10-28).
        Measured 2026-10-28 (4026 VisualStudio.DTE.17.0, C:\Temp\Verify-repro-axis): it writes
        the .tsproj and the nested .plcproj (with the new <Compile Include>) in ~0.2 s; a dirty
        plain text document open in the IDE was NOT saved. Whether it writes unsaved content of
        a PLC editor (a POU edited in the GUI and not saved) was NOT verified (no way to make one
        dirty without the GUI). DTE File.SaveAll also saved that text document;
        ITcSysManager.SaveConfiguration throws "SaveConfiguration only supported in Automation
        Legacy Mode! ...".
        Steps (each failure throws a message starting with 'save:', or PROJECT_SAVE_TIMEOUT /
        IDE_*):
          1. dialog   Get-TcIdeModalDialog: returns @{ ModalDialog = <dialog> } without saving
          2. locate   Get-TcPlcProjectFile ('save: locate: ...')
          3. before   the .plcproj on disk is read once: SHA256, LastWriteTimeUtc and which
                      -ExpectFile entries are already there (preExisting)
          4. save     Invoke-TcProjectSaveWithDeadline (-TimeoutSec, PROJECT_SAVE_TIMEOUT)
          5. verify   the .plcproj read back from disk lists every -ExpectFile (relative path
                      'POUs\FB_X.TcPOU' = whole <Compile Include>; bare file name = any leaf) and
                      every -ExpectLibrary. An entry that was already there before and a file
                      that did not change (hash) give a warning, not a failure.
        Returns @{ plc; tsproj; plcproj; dteProject; resolvedVia; savedFiles; verifiedFiles
        [{ file; preExisting }]; verifiedLibraries; plcprojChanged; lastWriteBefore;
        lastWriteAfter; saveSec; warning } (or @{ ModalDialog }).
    .PARAMETER PlcName
        PLC name (TIPC^<Plc>).
    .PARAMETER ExpectFile
        Entries that must appear as <Compile Include> after the save ('POUs\FB_Motor.TcPOU' or
        'FB_Motor.TcPOU').
    .PARAMETER ExpectLibrary
        Library names that must appear as a library reference after the save.
    .PARAMETER TimeoutSec
        Deadline of the save call (PROJECT_SAVE_TIMEOUT). Default 60.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PlcName,

        [Parameter()]
        [string[]]$ExpectFile = @(),

        [Parameter()]
        [string[]]$ExpectLibrary = @(),

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 60
    )

    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) { return @{ ModalDialog = $dialog } }

    $info = Get-TcPlcProjectFile -PlcName $PlcName
    $expect = @($ExpectFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    # --- before: what is on disk already ---
    $hashBefore = $null; $writeBefore = $null; $before = $null
    if (Test-Path -LiteralPath $info.PlcProjFile) {
        try {
            $hashBefore = (Get-FileHash -LiteralPath $info.PlcProjFile -Algorithm SHA256).Hash
            $writeBefore = (Get-Item -LiteralPath $info.PlcProjFile).LastWriteTimeUtc
            $before = Get-TcPlcProjectContent -Path $info.PlcProjFile
        } catch { $before = $null }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-TcProjectSaveWithDeadline -TsProjFile $info.TsProjFile -PlcProjFile $info.PlcProjFile -TimeoutSec $TimeoutSec
    $saveSec = [math]::Round($sw.Elapsed.TotalSeconds, 2)

    if (-not (Test-Path -LiteralPath $info.PlcProjFile)) { throw "save: Project.Save returned but '$($info.PlcProjFile)' does not exist." }
    $content = $null
    try { $content = Get-TcPlcProjectContent -Path $info.PlcProjFile }
    catch { throw "save: Project.Save returned but '$($info.PlcProjFile)' could not be read back ($($_.Exception.Message))." }
    $missing = @($expect | Where-Object { -not (Test-TcPlcProjectHasFile -Content $content -File $_) })
    if ($missing.Count -gt 0) {
        throw "save: Project.Save returned but '$($info.PlcProjFile)' read back from disk has no <Compile Include> for $($missing -join ', ')."
    }
    $missingLib = @($ExpectLibrary | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $content.Libraries.Contains($_) })
    if ($missingLib.Count -gt 0) {
        throw "save: Project.Save returned but '$($info.PlcProjFile)' read back from disk has no library reference for $($missingLib -join ', ')."
    }
    $hashAfter = $null; $writeAfter = $null
    try { $hashAfter = (Get-FileHash -LiteralPath $info.PlcProjFile -Algorithm SHA256).Hash; $writeAfter = (Get-Item -LiteralPath $info.PlcProjFile).LastWriteTimeUtc } catch { }
    $changed = if ($null -eq $hashBefore -or $null -eq $hashAfter) { $null } else { $hashBefore -ne $hashAfter }

    $verified = @($expect | ForEach-Object {
        $pre = $null
        if ($null -ne $before) { $pre = [bool](Test-TcPlcProjectHasFile -Content $before -File $_) }
        [PSCustomObject]@{ file = $_; preExisting = $pre }
    })
    $warnings = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string]$info.Warning)) { $warnings.Add([string]$info.Warning) }
    $preOnly = @($verified | Where-Object { $_.preExisting -eq $true })
    if ($preOnly.Count -gt 0) {
        $note = "$(@($preOnly | ForEach-Object { $_.file }) -join ', ') was already listed in the .plcproj before the save"
        if ($changed -eq $false) { $note += ' and the file did not change (same SHA256): the save is not what put it there' }
        $warnings.Add("$note.")
    }
    [ordered]@{
        plc               = $PlcName
        tsproj            = $info.TsProjFile
        plcproj           = $info.PlcProjFile
        dteProject        = $info.UniqueName
        resolvedVia       = $info.ResolvedVia
        savedFiles        = @($info.TsProjFile, $info.PlcProjFile)
        verifiedFiles     = $verified
        verifiedLibraries = @($ExpectLibrary)
        plcprojChanged    = $changed
        lastWriteBefore   = $(if ($null -ne $writeBefore) { $writeBefore.ToString('o') } else { $null })
        lastWriteAfter    = $(if ($null -ne $writeAfter) { $writeAfter.ToString('o') } else { $null })
        saveSec           = $saveSec
        warning           = $(if ($warnings.Count -gt 0) { $warnings -join ' ' } else { $null })
    }
}

function Get-TcUnsavedPlcObject {
    <#
    .SYNOPSIS
        Compares the PLC objects in XAE memory with the .plcproj on disk, per PLC project (#76).
    .DESCRIPTION
        DTE Project.Saved / IsDirty and Solution.Saved / IsDirty all stay True / False after a
        CreateChild that XAE has not saved (measured 2026-10-28, 4026 VisualStudio.DTE.17.0), so
        they cannot tell whether a project is dirty. Instead, for every PLC (Get-TcPlcProjectList)
        the tree below TIPC^<Plc>^<Plc> Project is walked like Find-TcPlcNameConflict (PLC
        folders, ItemType 601, are entered; POU children such as methods are not) and every
        top-level object with a file (Get-TcPlcObjectFileExtension) gives an expected file
        <Name><ext> and relative path (Get-TcPlcObjectRelativeFile). The .plcproj on disk
        (Get-TcPlcProjectContent) is compared with that list:
          missingOnDisk  objects in XAE memory without a <Compile Include> (by file name):
                         name, path, file, relativePath, fileExists (the object file is on disk
                         at relativePath below the .plcproj folder; a file of the same name in
                         another folder does not count; false = it was deleted on disk)
          extraOnDisk    <Compile Include> .TcPOU/.TcDUT/.TcGVL/.TcIO entries whose file name is
                         no object file of the walk. Folder names are not used; a node of an
                         ItemType without a known extension (e.g. a type not in the table) with
                         the same base name is not counted, so an unknown object kind cannot
                         make a false extra (only meaningful when complete is true)
          complete       the walk saw every node (none skipped, not over -MaxNodes / -MaxSec);
                         reason says why not
          checked        false when this PLC could not be compared (its .plcproj could not be
                         located or read, e.g. an independent project file): reason; the PLC is
                         then skipped, not an error
        Only object structure is compared: unsaved library references, tasks or I/O settings
        are not detected (known limit).
        IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT are thrown.
        Returns @{ Plcs = [ordered[]] @{ plc; projectPath; checked; reason; plcproj; tsproj;
        dteProject; warning; missingOnDisk; extraOnDisk; complete; visited; skipped }; Visited; Sec }.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER MaxNodes
        Node limit per PLC project (default 5000).
    .PARAMETER MaxSec
        Time limit of the tree walk per PLC project in seconds (default 60).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter()]
        [int]$MaxNodes = 5000,

        [Parameter()]
        [double]$MaxSec = 60
    )

    $sm = $SysManager
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $retryPattern = '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|RPC_E_SERVERCALL_RETRYLATER|IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $result = [System.Collections.Generic.List[object]]::new()
    $total = 0
    foreach ($plc in @(Get-TcPlcProjectList -SysManager $sm)) {
        $projPath = [string]$plc.projectPath
        $plcName = [string]$plc.name
        $walk = Invoke-TcComRetry -OperationName "Object list below $projPath" -ScriptBlock {
            $__objs = [System.Collections.Generic.List[object]]::new()
            $__other = [System.Collections.Generic.List[string]]::new()
            $__visited = 0; $__skipped = 0; $__over = $null
            $__wsw = [System.Diagnostics.Stopwatch]::StartNew()
            $__queue = New-Object System.Collections.Queue
            $__queue.Enqueue($sm.LookupTreeItem($projPath))
            while ($__queue.Count -gt 0 -and $null -eq $__over) {
                $__node = $__queue.Dequeue()
                $__cnt = 0
                try { $__cnt = [int]$__node.ChildCount }
                catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++; continue }
                for ($__j = 1; $__j -le $__cnt; $__j++) {
                    $__visited++
                    if ($__visited -gt $MaxNodes) { $__over = "over the node limit ($MaxNodes)"; break }
                    if ($__wsw.Elapsed.TotalSeconds -gt $MaxSec) { $__over = "over the time limit ($MaxSec s)"; break }
                    try {
                        $__c = $__node.Child($__j)
                        $__t = [int]$__c.ItemType
                        if ($__t -eq 601) { $__queue.Enqueue($__c); continue }
                        $__ext = Get-TcPlcObjectFileExtension -ItemType $__t
                        if ($null -ne $__ext) { $__objs.Add(@{ Name = [string]$__c.Name; Path = [string]$__c.PathName; Ext = $__ext }) }
                        else { $__other.Add([string]$__c.Name) }
                    }
                    catch { if ($_.Exception.ToString() -match $retryPattern) { throw }; $__skipped++ }
                }
            }
            @{ Objects = $__objs.ToArray(); Other = $__other.ToArray(); Visited = $__visited; Skipped = $__skipped; Over = $__over }
        }
        $total += [int]$walk.Visited
        $entry = [ordered]@{
            plc = $plcName; projectPath = $projPath; checked = $false; reason = $null; plcproj = $null; tsproj = $null; dteProject = $null; warning = $null
            missingOnDisk = @(); extraOnDisk = [string[]]@(); complete = $false; visited = [int]$walk.Visited; skipped = [int]$walk.Skipped
        }
        $file = $null; $content = $null
        try {
            $file = Get-TcPlcProjectFile -PlcName $plcName
            $content = Get-TcPlcProjectContent -Path $file.PlcProjFile
        }
        catch {
            if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
            $entry.reason = "project file not compared: $($_.Exception.Message)"
            if ($null -ne $file) { $entry.plcproj = $file.PlcProjFile; $entry.tsproj = $file.TsProjFile; $entry.dteProject = $file.UniqueName }
            $result.Add($entry)
            continue
        }
        $entry.checked = $true
        $entry.plcproj = $file.PlcProjFile; $entry.tsproj = $file.TsProjFile; $entry.dteProject = $file.UniqueName; $entry.warning = $file.Warning
        $plcDir = [IO.Path]::GetDirectoryName($file.PlcProjFile)
        $modelFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $otherNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($n in @($walk.Other)) { $null = $otherNames.Add($n) }
        $missing = [System.Collections.Generic.List[object]]::new()
        foreach ($o in @($walk.Objects)) {
            $leaf = [string]$o.Name + [string]$o.Ext
            $null = $modelFiles.Add($leaf)
            if ($content.CompileLeaf.Contains($leaf)) { continue }
            $rel = Get-TcPlcObjectRelativeFile -TreePath ([string]$o.Path) -Extension ([string]$o.Ext)
            # Only the file at relativePath counts: a file with the same name elsewhere is another object.
            $exists = Test-Path -LiteralPath (Join-Path $plcDir $rel) -PathType Leaf
            $missing.Add([PSCustomObject]@{ name = [string]$o.Name; path = [string]$o.Path; file = $leaf; relativePath = $rel; fileExists = [bool]$exists })
        }
        $extra = @($content.Compile | Where-Object {
            $_ -match '(?i)\.(TcPOU|TcDUT|TcGVL|TcIO)$' -and -not $modelFiles.Contains([IO.Path]::GetFileName($_)) -and
            -not $otherNames.Contains([IO.Path]::GetFileNameWithoutExtension($_))
        })
        $entry.missingOnDisk = $missing.ToArray()
        $entry.extraOnDisk = [string[]]$extra
        $entry.complete = ($null -eq $walk.Over -and [int]$walk.Skipped -eq 0)
        if ($null -ne $walk.Over) { $entry.reason = "incomplete: $($walk.Over)" }
        elseif ([int]$walk.Skipped -gt 0) { $entry.reason = "incomplete: $($walk.Skipped) node(s) could not be read" }
        $result.Add($entry)
    }
    @{ Plcs = $result.ToArray(); Visited = $total; Sec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

function Invoke-TcPlcObjectSave {
    <#
    .SYNOPSIS
        Add-TcPou / Add-TcDut / Add-TcGvl / Add-TcLibrary: saves the project file of the PLC that
        contains -ObjectPath and verifies the new entry on disk (#76).
    .DESCRIPTION
        Wraps Save-TcPlcProject. An -ExpectFile without a folder is turned into the relative path
        of the object (Get-TcPlcObjectRelativeFile: 'TIPC^P^P Project^POUs^FB_X' -> 'POUs\FB_X.TcPOU')
        so the <Compile Include> is checked with its folder.
        Returns @{ Saved = <Save-TcPlcProject result>; Error = $null } or
        @{ Saved = $null; Error = <failed New-TcResult> }: IDE_MODAL_DIALOG (a dialog was up, nothing
        saved), PROJECT_SAVE_TIMEOUT (data.saveDiagnostics), PROJECT_SAVE_FAILED (save, locate or
        readback failed; a .plcproj that cannot be located gets its own hint), or the IDE_* code of
        the COM call. Error data: objectPath, plc, createdInMemory = $true, savedToDisk = $false.
    .PARAMETER ObjectPath
        Tree path of the new object (TIPC^<Plc>^...), or of the References node for a library.
    .PARAMETER ExpectFile
        File name that must appear as <Compile Include> (e.g. FB_Motor.TcPOU).
    .PARAMETER ExpectLibrary
        Library name that must appear as a library reference.
    .PARAMETER What
        Short text for the messages, e.g. "POU 'FB_Motor'".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ObjectPath,

        [Parameter()]
        [string]$ExpectFile,

        [Parameter()]
        [string]$ExpectLibrary,

        [Parameter(Mandatory)]
        [string]$What
    )

    $plc = Get-TcPlcNameFromPath -TreePath $ObjectPath
    $errData = [PSCustomObject]@{ objectPath = $ObjectPath; plc = $plc; createdInMemory = $true; savedToDisk = $false }
    $prefix = "$What was created in XAE ('$ObjectPath') but the project file (.plcproj) was not saved, so closing the solution without saving would drop it"
    $locateHint = "物件已建在 XAE 記憶體，但模組找不到這個 PLC 的 .plcproj(error.message 說明找過哪些 .tsproj;獨立專案檔 .xti 的位置規則 InfoSys 沒寫，未驗證)。下一步：請使用者在 XAE 的 Solution Explorer 對該 PLC 專案按右鍵 Save(或 File > Save All,會一併存其他未存文件),再 Get-TcProjectTree -PlcOnly 確認物件還在;不要 Reset-TcSolution -DiscardProjectChanges 或 Disconnect-TcIde -Quit(會丟掉這個物件)"
    if ($null -eq $plc) {
        return @{ Saved = $null; Error = (New-TcResult -Success $false -ErrorMessage "${prefix}: '$ObjectPath' is not below TIPC^<Plc>, the PLC project cannot be located." `
            -ErrorCode 'PROJECT_SAVE_FAILED' -Hint $locateHint -Data $errData) }
    }
    $saveParams = @{ PlcName = $plc }
    if (-not [string]::IsNullOrWhiteSpace($ExpectFile)) {
        $ef = $ExpectFile
        if (-not $ef.Contains('\') -and -not $ef.Contains('/')) {
            $ext = [IO.Path]::GetExtension($ef)
            $leafPath = Get-TcPlcObjectRelativeFile -TreePath $ObjectPath -Extension $ext
            if ([IO.Path]::GetFileName($leafPath) -ieq $ef) { $ef = $leafPath }
        }
        $saveParams['ExpectFile'] = @($ef)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectLibrary)) { $saveParams['ExpectLibrary'] = @($ExpectLibrary) }
    try {
        $saved = Save-TcPlcProject @saveParams
        if ($saved.Contains('ModalDialog')) {
            return @{ Saved = $null; Error = (New-TcModalDialogResult -Dialog $saved.ModalDialog -Operation "Project.Save after creating $What (created in XAE, project file NOT saved)" -Data $errData) }
        }
        return @{ Saved = [PSCustomObject]$saved; Error = $null }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '^save: locate:') {
            return @{ Saved = $null; Error = (New-TcResult -Success $false -ErrorMessage "${prefix}: $msg" -ErrorCode 'PROJECT_SAVE_FAILED' -Hint $locateHint -Data $errData) }
        }
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_SAVE_FAILED' -MessagePrefix $prefix -Data $errData
        if ($res.error.code -eq 'PROJECT_SAVE_TIMEOUT' -and $null -ne $script:TcLastProjectSaveDiagnostics) {
            $res.data | Add-Member -NotePropertyName 'saveDiagnostics' -NotePropertyValue $script:TcLastProjectSaveDiagnostics -Force
        }
        return @{ Saved = $null; Error = $res }
    }
}
