function Add-TcLibrary {
    <#
    .SYNOPSIS
        Adds a library reference to the PLC project (ITcPlcLibraryManager.AddLibrary).
    .DESCRIPTION
        The References node of the PLC project (TIPC^<Plc>^<Plc> Project^References) is used as
        ITcPlcLibraryManager and AddLibrary(name, version, distributor) is called (TE1000 v1.7.0
        §6.5.14 "Managing PLC libraries and placeholders", p.241-243: LookupTreeItem of the
        References node, PowerShell sample $references.AddLibrary("Tc2_MDP", "*",
        "Beckhoff Automation GmbH"); §5.25.1.10 ITcPlcLibraryManager::AddLibrary, p.118). The old
        CreateChild("<lib>, * (...)", 0) on TIPC.Child(1).LookupChild('References') failed with
        0x98510001 (#80): on 4026 that lookup itself throws 0x98510001, the References node is
        below '<Plc> Project' (measured 2026-10-28, 4026 VisualStudio.DTE.17.0).
        Already referenced: the names of ITcPlcLibraryManager.References (§5.25.1, p.113;
        ITcPlcLibRef.Name §5.24.1, p.112; placeholders are listed as '#<name>', measured) are
        checked first. A reference named -Name or '#<Name>' -> success with data.alreadyPresent =
        true, AddLibrary is not called, the project file is still saved and read back, and no
        BUILD_REQUIRED is recorded. AddLibrary on a library that is already referenced throws
        ArgumentException 0x80070057 "Managed Library '...' already contained!" (manual: "Library
        or placeholder is already included"; measured 2026-10-28, 4026); that error is mapped to
        the same alreadyPresent result.
        Not installed: AddLibrary throws TSM_E_ITEMNOTFOUND ("Managed/default library not found",
        §5.25.1.10), measured as 0x98510001 "Managed Library '<name>, * (...)' not found!"
        (2026-10-28, 4026). -> LIBRARY_ADD_FAILED with data.notInstalled = true and a hint to
        install the library; nothing is saved, so the .plcproj is not modified (measured: same
        SHA256), and no BUILD_REQUIRED is recorded (AddLibrary is a transaction, §5.25.1.10; the
        References list was unchanged after the failure, measured).
    .PARAMETER Name
        Library name (e.g., Tc2_Standard, Tc3_Module).
    .PARAMETER Version
        Library version. Default '*' = newest installed (the manual sample uses '*'; the
        project file then gets <LibraryReference Include="<name>,newest,<vendor>">, measured).
    .PARAMETER Vendor
        Distributor / company. Default 'Beckhoff Automation GmbH'.
    .PARAMETER PlcProjectPath
        PLC name or tree path ('TIPC^<Plc>^<Plc> Project') when the solution has more than one
        PLC project (otherwise PLC_PROJECT_AMBIGUOUS).
    .NOTES
        Project file (#76): the library reference is stored in the .plcproj, which AddLibrary
        only changes in XAE memory. The project file is saved (Save-TcPlcProject) and read back
        from disk: success only when it lists a library reference named -Name
        (PlaceholderReference / LibraryReference Include, Namespace or DefaultResolution;
        data.projectSaved), otherwise PROJECT_SAVE_FAILED (or PROJECT_SAVE_TIMEOUT /
        IDE_MODAL_DIALOG / IDE_*). What else Project.Save writes (measured 2026-10-28, 4026
        VisualStudio.DTE.17.0): a dirty plain text document was NOT saved; whether unsaved content
        of a PLC editor (a POU edited in the GUI) is written was NOT verified.
        BUILD_REQUIRED (#65): after AddLibrary was called (success, or failing for another reason
        than not installed / already referenced) the solution is recorded as 'code-changed'
        (Register-TcCodeChange): Enable-TcConfig and Enter-TcPlcOnline refuse until a complete
        Build-TcProject. data.buildRequired / data.stateWarning as in Build-TcProject.
        data: library, version, vendor, referencesPath, alreadyPresent, existingReference,
        projectSaved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Version = '*',

        [Parameter()]
        [string]$Vendor = 'Beckhoff Automation GmbH',

        [Parameter()]
        [string]$PlcProjectPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $addCalled = $false
    $change = "Add-TcLibrary $Name (version $Version)"
    try {
        # --- PLC project -> References node path (same lookup as Enter-/Exit-TcPlcOnline)
        $plcList = @(Get-TcPlcProjectList -SysManager $sm)
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            try { $PlcProjectPath = Resolve-TcPlcProjectPath -SysManager $sm -RequireSingle }
            catch {
                if ($_.Exception.Message -match '^(PLC_PROJECT_NOT_FOUND|PLC_PROJECT_AMBIGUOUS)') {
                    $code = $Matches[1]
                    return New-TcResult -Success $false -ErrorMessage ($_.Exception.Message -replace '^PLC_PROJECT_[A-Z_]+:\s*', '') `
                        -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) -Data ([PSCustomObject]@{ plcProjects = $plcList })
                }
                throw
            }
        }
        else {
            $plcEntry = Find-TcPlcProject -List $plcList -Spec $PlcProjectPath
            if ($null -eq $plcEntry) {
                return New-TcResult -Success $false `
                    -ErrorMessage "PLC project '$PlcProjectPath' not found. PLC projects: $(($plcList | ForEach-Object { $_.projectPath }) -join ', ')" `
                    -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND') `
                    -Data ([PSCustomObject]@{ plcProjects = $plcList })
            }
            $PlcProjectPath = $plcEntry.projectPath
        }
        $refsPath = "$PlcProjectPath^References"

        # The References item is a tree item (enumerable): not returned through Invoke-TcComRetry
        # (the pipeline would unroll it), looked up directly.
        $refs = $null
        try { $refs = $sm.LookupTreeItem($refsPath) }
        catch {
            if ((ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'OTHER') -ne 'TREEITEM_NOT_FOUND') { throw }
            $refs = $null
        }
        if ($null -eq $refs) {
            return New-TcResult -Success $false -ErrorMessage "Cannot find References node '$refsPath' in PLC project." -ErrorCode 'REFS_NOT_FOUND'
        }

        # --- already referenced? (ITcPlcLibraryManager.References, placeholders are '#<name>')
        $existing = Invoke-TcComRetry -OperationName 'References names' -ScriptBlock {
            $__n = [System.Collections.Generic.List[string]]::new()
            foreach ($__r in $refs.References) { $__n.Add([string]$__r.Name) }
            Write-Output -NoEnumerate $__n.ToArray()
        }
        $match = @($existing | Where-Object { $_ -ieq $Name -or $_ -ieq "#$Name" }) | Select-Object -First 1
        $alreadyPresent = $null -ne $match

        if (-not $alreadyPresent) {
            $addCalled = $true   # #65: the References may change from here on
            try {
                Invoke-TcComRetry -OperationName "AddLibrary $Name" -ScriptBlock { $null = $refs.AddLibrary($Name, $Version, $Vendor) }
            }
            catch {
                $text = Get-TcLibraryErrorText -ErrorRecord $_
                if ($text -match 'already contained|already included') {
                    $alreadyPresent = $true; $addCalled = $false; $match = $Name
                }
                elseif ($text -match '0x98510001|ITEMNOTFOUND|not found') {
                    $hint = "library '$Name' (version $Version, $Vendor) 沒有安裝在這台電腦的 library repository(AddLibrary 回 TSM_E_ITEMNOTFOUND)。.plcproj 沒有被修改。下一步：在 XAE 的 PLC > Library Repository 安裝該 library(或從 TwinCAT Package Manager 裝對應套件),確認名稱 / 版本 / 廠商拼字(-Version '*' = 最新版),再重跑 Add-TcLibrary"
                    return New-TcResult -Success $false -ErrorMessage "Failed to add library: $text" -ErrorCode 'LIBRARY_ADD_FAILED' -Hint $hint `
                        -Data ([PSCustomObject]@{ library = $Name; version = $Version; vendor = $Vendor; referencesPath = $refsPath; notInstalled = $true; projectSaved = $null })
                }
                else { throw }
            }
        }

        # #76: the reference lives in the .plcproj; save it and read it back from disk
        $what = if ($alreadyPresent) { "Library reference '$Name' (already referenced)" } else { "Library reference '$Name'" }
        $save = Invoke-TcPlcObjectSave -ObjectPath $refsPath -ExpectLibrary $Name -What $what
        if ($null -ne $save.Error) {
            if ($addCalled) { return Register-TcCodeChange -Result $save.Error -Change "$change [added, project file not saved]" }
            return $save.Error
        }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            library           = $Name
            version           = $Version
            vendor            = $Vendor
            referencesPath    = $refsPath
            alreadyPresent    = $alreadyPresent
            existingReference = $(if ($alreadyPresent) { [string]$match } else { $null })
            projectSaved      = $save.Saved
        })
        if ($alreadyPresent) { return $ok }
        Register-TcCodeChange -Result $ok -Change $change
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_ADD_FAILED' -MessagePrefix 'Failed to add library'
        # conservative (#65): AddLibrary was called, the reference may have been added
        if ($addCalled) { return Register-TcCodeChange -Result $res -Change "$change [failed after AddLibrary]" }
        $res
    }
}

