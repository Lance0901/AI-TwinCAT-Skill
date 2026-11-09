function Get-TcComMember {
    <#
    .SYNOPSIS
        Read a property or call a method of a DTE object through IDispatch (#219).
    .DESCRIPTION
        The PowerShell COM adapter does not see every DTE member out of process: measured 2026-11-09
        (VS2022 VisualStudio.DTE.17.0 zh-TW + TwinCAT 4026), $dte.ToolWindows is $null (a DTE2 member,
        IDispatch answers DISP_E_UNKNOWNNAME) and Window.Caption / Window.Object read back empty / $null,
        while Type.InvokeMember on the same objects returns them. A real COM object is therefore read
        with InvokeMember; any other object (unit-test mocks) with ordinary member access. The leading
        comma keeps a returned COM collection from being unrolled by the pipeline.
    #>
    param(
        [Parameter(Mandatory)] $Object,
        [Parameter(Mandatory)] [string]$Name,
        [object[]]$Arguments,
        [switch]$Method
    )
    if ($Object -is [System.__ComObject]) {
        $flags = if ($Method) { [Reflection.BindingFlags]::InvokeMethod } else { [Reflection.BindingFlags]::GetProperty }
        return , ([System.__ComObject].InvokeMember($Name, $flags, $null, $Object, $Arguments))
    }
    if ($Method) {
        return , ($Object.$Name.Invoke($Arguments))
    }
    return , ($Object.$Name)
}

function Get-TcBuildOutputPane {
    <#
    .SYNOPSIS
        Find the build pane of the Output window by its GUID and read its text (#219 / #218).
    .DESCRIPTION
        The pane is identified by its GUID, never by its name: the name is localized (English "Build",
        zh-TW "建置", 實測 2026-11-09 VS2022 zh-TW). Output window = DTE.Windows.Item(vsWindowKindOutput).Object
        (vsWindowKindOutput = {34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3},
        https://learn.microsoft.com/en-us/dotnet/api/envdte.constants.vswindowkindoutput); build pane =
        OutputWindowPane.Guid {1BD8A850-02D1-11D1-BEE7-00A0C913D1F8} (VSConstants.OutputWindowPaneGuid.BuildOutputPane_guid,
        https://learn.microsoft.com/en-us/dotnet/api/microsoft.visualstudio.vsconstants.outputwindowpaneguid.buildoutputpane_guid;
        the page gives no literal value, the value is 實測 2026-11-09 on VS2022 zh-TW).
        No fallback by pane index: the panes are not in a fixed order (measured: sorted by GUID, with
        "Source Control - Team Foundation" before the build pane), so an index would pick another pane.
        Returns status:
          read        the build pane was found and its text read (text, name, guid, index, matchedBy 'guid')
          not-found   the Output window was read but no pane has the build pane GUID (panes = what was seen)
          unreadable  the Output window, its panes or the build pane text could not be read (error)
    #>
    param($Dte = $script:TcDte)

    $result = [PSCustomObject]@{
        status    = 'unreadable'
        name      = $null
        guid      = $null
        index     = $null
        matchedBy = $null
        text      = ''
        panes     = @()
        error     = $null
    }
    if ($null -eq $Dte) { $result.error = 'no DTE connection'; return $result }

    try {
        $windows = Get-TcComMember -Object $Dte -Name 'Windows'
        $window = Get-TcComMember -Object $windows -Name 'Item' -Arguments @($script:TcVsWindowKindOutput) -Method
        $outputWindow = Get-TcComMember -Object $window -Name 'Object'
        if ($null -eq $outputWindow) { throw 'Output window object is null' }
        $panes = Get-TcComMember -Object $outputWindow -Name 'OutputWindowPanes'
        $count = [int](Get-TcComMember -Object $panes -Name 'Count')
    }
    catch {
        # busy / dead RPC must reach Invoke-TcComRetry (retry, IDE_BUSY / IDE_CRASHED), not become 'unreadable' (#184 helper)
        if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
        $result.error = "Output window not readable: $($_.Exception.Message)"
        return $result
    }

    $seen = [System.Collections.Generic.List[object]]::new()
    $buildPane = $null
    for ($i = 1; $i -le $count; $i++) {
        $pane = $null; $paneName = $null; $paneGuid = $null
        try {
            $pane = Get-TcComMember -Object $panes -Name 'Item' -Arguments @([object]$i) -Method
            $paneGuid = [string](Get-TcComMember -Object $pane -Name 'Guid')
            try { $paneName = [string](Get-TcComMember -Object $pane -Name 'Name') } catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw }; $paneName = $null }
            if ([string]::IsNullOrWhiteSpace($paneGuid)) { throw 'Guid read back empty' }
        }
        catch {
            if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
            $seen.Add([PSCustomObject]@{ index = $i; name = $paneName; guid = $null; error = $_.Exception.Message })
            continue
        }
        $seen.Add([PSCustomObject]@{ index = $i; name = $paneName; guid = $paneGuid; error = $null })
        $normalized = $paneGuid.Trim().Trim('{', '}')
        if ($null -eq $buildPane -and $normalized -ieq $script:TcBuildOutputPaneGuid.Trim('{', '}')) {
            $buildPane = $pane
            $result.name = $paneName
            $result.guid = $paneGuid
            $result.index = $i
            $result.matchedBy = 'guid'
        }
    }
    $result.panes = @($seen.ToArray())

    if ($null -eq $buildPane) {
        $guidsRead = @($seen | Where-Object { $null -ne $_.guid }).Count
        $unread = $count - $guidsRead
        if ($unread -gt 0) {
            # a pane whose Guid cannot be read may be the build pane: not 'not-found' (no fallback by index)
            $result.error = "$unread of $count Output window pane(s) returned no Guid, so the build pane cannot be ruled out ($guidsRead read, none has $script:TcBuildOutputPaneGuid)"
        }
        else {
            $result.status = 'not-found'
            $result.error = "no Output window pane has the build pane Guid $script:TcBuildOutputPaneGuid ($count pane(s) read)"
        }
        return $result
    }

    try {
        $textDoc = Get-TcComMember -Object $buildPane -Name 'TextDocument'
        $start = Get-TcComMember -Object $textDoc -Name 'StartPoint'
        $end = Get-TcComMember -Object $textDoc -Name 'EndPoint'
        $editPoint = Get-TcComMember -Object $start -Name 'CreateEditPoint' -Arguments @() -Method
        $result.text = [string](Get-TcComMember -Object $editPoint -Name 'GetText' -Arguments @($end) -Method)
        $result.status = 'read'
    }
    catch {
        if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
        $result.error = "build pane '$($result.name)' found but its text is not readable: $($_.Exception.Message)"
    }
    return $result
}

function Get-TcBuildWarningLines {
    <#
    .SYNOPSIS
        The warning lines of the build pane text (#218).
    .DESCRIPTION
        Compiler / build messages are "<file>(<line>) : warning: <code>: <text>" (TwinCAT PLC compiler) or
        "<file>(<line>,<col>): warning <code>: <text>" (MSBuild). The word "warning" there is written by the
        compiler, not by the VS UI: it stayed English in a zh-TW VS2022 (實測 2026-11-09, 4026), while the
        UI lines around it ("已開始建置", "組建: 成功或已更新") were localized. 實測 2026-11-09: zh-TW VS2022
        and English XAE 4024 both print the English "warning:"; other languages are not verified. A line matches
        when "warning" starts the line, or follows ")" + ":" (MSBuild) or " :" (compiler "<file> : warning:"); a
        compiler code is NOT required: the 4024 XAE (English, 實測 2026-11-09) writes
        "MAIN.TcPOU(41) : warning: The code 'LT_Read;" without one. "see docs: warning levels" does not count.
    #>
    param([string[]]$Lines)
    @($Lines | Where-Object { $_ -match '(?i)(^\s*warning\b|\)\s*:\s*warning\b|\s:\s*warning\b)' })
}

# vsWindowKindOutput, https://learn.microsoft.com/en-us/dotnet/api/envdte.constants.vswindowkindoutput
$script:TcVsWindowKindOutput = '{34E76E81-EE4A-11D0-AE2E-00A0C90FFFC3}'
# VSConstants.OutputWindowPaneGuid.BuildOutputPane_guid (value 實測 2026-11-09, VS2022 zh-TW; 英文 XAE 4024 32-bit 同值,實測 2026-11-09)
$script:TcBuildOutputPaneGuid = '{1BD8A850-02D1-11D1-BEE7-00A0C913D1F8}'
