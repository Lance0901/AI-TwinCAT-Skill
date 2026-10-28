function Invoke-TcIoScan {
    <#
    .SYNOPSIS
        Scans the target for I/O devices (ProduceXml(false) on TIID); with -Apply adds them to the I/O tree.
    .DESCRIPTION
        Follows TE1000 Automation Interface manual v1.7.0, 6.6.2 "Performing a device scan" (p.247-248):
        ITcSmTreeItem.ProduceXml($false) on the TIID node scans and returns the found devices under
        TreeItem/DeviceGrpDef/FoundDevices/Device (ItemSubType, AddressInfo). Without -Apply nothing
        in the I/O tree is changed: data.devices lists what the scan found.
        -Apply then does, per found device: TIID.CreateChild("Device_<n>", ItemSubType, "", $null),
        ConsumeXml(<TreeItem><DeviceDef>AddressInfo</DeviceDef></TreeItem>) and
        ConsumeXml(<ScanBoxes>1</ScanBoxes>) (a ScanBoxes failure is only a warning, as in the manual),
        and reads every created device back with LookupTreeItem (IO_SCAN_VERIFY_FAILED otherwise).
        The manual requires TwinCAT in Config mode: the system state (ADS port 10000) is read first
        and anything else returns IO_SCAN_REQUIRES_CONFIG without scanning.
        No device found: success, data.devices = @() and data.warning.
    .PARAMETER Apply
        Add the found devices to the I/O tree (CreateChild + AddressInfo + ScanBoxes) and read them back.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Apply
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    # Requirement "TwinCAT is in Config mode" (TE1000 6.6.2, p.247). ProduceXml(false) in Run mode
    # returned an empty FoundDevices without an error (實測 2026-10-28, 4026 XAE in VS2022, UmRT),
    # so without this check a Run-mode scan would look like "no devices".
    $state = Get-TcSystemState
    if (-not $state.success) {
        return New-TcResult -Success $false -ErrorCode 'IO_SCAN_REQUIRES_CONFIG' `
            -ErrorMessage "Cannot read the TwinCAT system state before the I/O scan: $($state.error.message)" `
            -Hint (Get-TcErrorHint -Code 'IO_SCAN_REQUIRES_CONFIG') `
            -Data ([PSCustomObject]@{ state = $null; stateError = $state.error.code })
    }
    if ($state.data.state -ne 'Config') {
        return New-TcResult -Success $false -ErrorCode 'IO_SCAN_REQUIRES_CONFIG' `
            -ErrorMessage "I/O scan requires TwinCAT in Config mode; target $($state.data.amsNetId) is in $($state.data.state)." `
            -Hint (Get-TcErrorHint -Code 'IO_SCAN_REQUIRES_CONFIG') `
            -Data ([PSCustomObject]@{ state = $state.data.state; amsNetId = $state.data.amsNetId })
    }

    try {
        # Not through Invoke-TcComRetry: an ITcSmTreeItem is enumerable (its children), so pipeline
        # output would unroll it (an empty TIID came back as $null, 實測 2026-10-28).
        $ioDevicesItem = $sm.LookupTreeItem('TIID')
        # TE1000 6.6.2 (p.247): "The scan is triggered on the I/O node via ProduceXml(false)"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $xml = Invoke-TcComRetry -OperationName 'TIID.ProduceXml(false)' -ScriptBlock { $ioDevicesItem.ProduceXml($false) }
        $scanMs = $sw.ElapsedMilliseconds
        $found = @(ConvertFrom-TcIoScanXml -Xml ([string]$xml))
    }
    catch {
        return New-TcResult -Success $false -ErrorMessage "I/O scan failed: $($_.Exception.Message)" -ErrorCode 'IO_SCAN_FAILED' `
            -Hint (Get-TcErrorHint -Code 'IO_SCAN_FAILED')
    }

    $devices = @($found | ForEach-Object {
            [PSCustomObject]@{ index = $_.index; name = $_.name; itemSubType = $_.itemSubType; addressInfo = $_.addressInfoXml; path = $null; created = $false }
        })
    $data = [PSCustomObject]@{
        devices = $devices
        applied = $false
        scanMs  = $scanMs
        state   = $state.data.state
    }
    if ($devices.Count -eq 0) {
        $data | Add-Member -NotePropertyName warning -NotePropertyValue 'The scan found no I/O devices (TreeItem/DeviceGrpDef/FoundDevices is empty); the I/O tree was not changed. A Usermode Runtime target has no physical I/O.'
        return New-TcResult -Success $true -Data $data
    }
    if (-not $Apply) { return New-TcResult -Success $true -Data $data }

    # -Apply: TE1000 6.6.2 PowerShell sample (p.248)
    $warnings = @()
    $existing = @{}
    try { for ($i = 1; $i -le $ioDevicesItem.ChildCount; $i++) { $existing[$ioDevicesItem.Child($i).Name] = $true } } catch { }
    foreach ($d in $devices) {
        $n = $d.index
        $name = "Device_$n"
        while ($existing.ContainsKey($name)) { $n++; $name = "Device_$n" }
        $existing[$name] = $true
        try {
            $dev = $ioDevicesItem.CreateChild($name, [int]$d.itemSubType, '', $null)
            $d.created = $true
            $d.path = [string]$dev.PathName
            if (-not [string]::IsNullOrEmpty($d.addressInfo)) {
                $dev.ConsumeXml("<TreeItem><DeviceDef>$($d.addressInfo)</DeviceDef></TreeItem>")
            }
            try { $dev.ConsumeXml('<TreeItem><DeviceDef><ScanBoxes>1</ScanBoxes></DeviceDef></TreeItem>') }
            catch { $warnings += "ScanBoxes on $($d.path): $($_.Exception.Message)" }
        }
        catch {
            return New-TcResult -Success $false -ErrorCode 'IO_SCAN_FAILED' `
                -ErrorMessage "I/O scan -Apply failed at device $($d.index) (ItemSubType $($d.itemSubType)): $($_.Exception.Message)" `
                -Hint (Get-TcErrorHint -Code 'IO_SCAN_FAILED') -Data $data
        }
    }

    # Read back: every created device must be found in the I/O tree
    $missing = @()
    foreach ($d in $devices) {
        $err = Test-TcTreeItemExists -SysManager $sm -Path $d.path
        if ($null -ne $err) { $missing += $d.path; continue }
        $item = $sm.LookupTreeItem($d.path)
        $d | Add-Member -NotePropertyName boxCount -NotePropertyValue ([int]$item.ChildCount) -Force
    }
    $data.applied = $true
    if ($warnings.Count -gt 0) { $data | Add-Member -NotePropertyName warnings -NotePropertyValue $warnings }
    if ($missing.Count -gt 0) {
        return New-TcResult -Success $false -ErrorCode 'IO_SCAN_VERIFY_FAILED' `
            -ErrorMessage "Created devices are not in the I/O tree after -Apply: $($missing -join ', ')" `
            -Hint (Get-TcErrorHint -Code 'IO_SCAN_VERIFY_FAILED') -Data $data
    }
    New-TcResult -Success $true -Data $data
}
