# Watch-TcVariable sample builder. Keep this file ASCII only.

function New-TcWatchSample {
    # One Watch sample from a Read-TcVariable data object: value plus text/name when present.
    param($Data)
    $sample = [ordered]@{
        timestamp = [DateTime]::Now.ToString('o')
        value     = $Data.value
    }
    if ($null -ne $Data.PSObject.Properties['text']) { $sample.text = $Data.text }
    if ($null -ne $Data.PSObject.Properties['name']) { $sample.name = $Data.name }
    return [PSCustomObject]$sample
}
