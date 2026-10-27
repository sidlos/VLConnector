# key=value files (markers, status, jobs and results). Dot-source this file (it has no param block).
# Format: UTF-8 without BOM, one "KEY=value" per line, keys in a fixed order. Files are written under a
# temporary name and renamed, so a reader never sees a half-written file.

# Values stay on one line and '=' becomes '-': PolyWorks macros (DATA_FILE READ LINE_FIELD) split a
# line at every '=', so a value must not contain one.
function ConvertTo-SafeValue([string]$Value) {
    if ($null -eq $Value) { return '' }
    return (($Value -replace '[\r\n]+', ' ') -replace '=', '-').Trim()
}

# $Pairs: ordered dictionary or array of 'KEY', value pairs in the order they must appear.
function Write-KeyValueFile([string]$Path, $Pairs) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($key in $Pairs.Keys) {
        $value = ConvertTo-SafeValue ([string]$Pairs[$key])
        $lines.Add(('{0}={1}' -f $key, $value))
    }
    $temp = "$Path.part"
    [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($temp, $Path)
}

# Returns an ordered dictionary; only keys made of letters, digits and '_' are accepted.
function Read-KeyValueFile([string]$Path, [int]$MaxBytes = 65536) {
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt $MaxBytes) { throw "File $Path is larger than $MaxBytes bytes." }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $text = (New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)))).ReadToEnd() }
    finally { $fs.Dispose() }
    foreach ($line in $text -split "`r?`n") {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { continue }
        $key = $line.Substring(0, $i)
        if ($key -notmatch '^[A-Za-z0-9_]{1,40}$') { continue }
        $result[$key] = $line.Substring($i + 1)
    }
    return $result
}
