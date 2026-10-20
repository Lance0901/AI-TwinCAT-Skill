# Watch-TcVariable sample builder. Keep this file ASCII only.

function New-TcWatchSample {
    # One Watch sample from a Read-TcVariable data object: value plus ms/ns/unix (time types) or name (enum).
    param($Data)
    $sample = [ordered]@{
        timestamp = [DateTime]::Now.ToString('o')
        value     = $Data.value
    }
    foreach ($k in 'ms', 'ns', 'unix') {
        if ($null -ne $Data.PSObject.Properties[$k]) { $sample[$k] = $Data.$k }
    }
    if ($null -ne $Data.PSObject.Properties['name']) { $sample.name = $Data.name }
    return [PSCustomObject]$sample
}
