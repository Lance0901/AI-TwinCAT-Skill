function Invoke-TcIoScan {
    <#
    .SYNOPSIS
        Triggers an EtherCAT device scan and returns discovered topology.
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        $ioDevices = $sm.LookupTreeItem('TIID')

        # Trigger scan - this uses the ITcSmTreeItem method
        $ioDevices.ProduceScan()

        # Read the resulting tree
        $devices = @()
        $childCount = $ioDevices.ChildCount
        for ($i = 1; $i -le $childCount; $i++) {
            try {
                $device = $ioDevices.Child($i)
                $devices += [PSCustomObject]@{
                    name = $device.Name
                    path = $device.PathName
                    type = try { $device.ItemSubType.ToString() } catch { '' }
                }
            }
            catch { continue }
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{ devices = $devices })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "I/O scan failed: $_" -ErrorCode 'IO_SCAN_FAILED'
    }
}
