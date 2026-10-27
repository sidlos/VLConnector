# key=value files (markers, status, jobs, macro parameters and results). Dot-source this file (it has no param block).
# Format: one "KEY=value" per line, keys in a fixed order. Written as UTF-8 with BOM: PolyWorks macros
# (DATA_FILE READ) read non-ASCII text correctly only from UTF-8 with BOM or UTF-16, and the result files
# that PolyWorks writes itself are UTF-16; the reader accepts all three. Files are written under a
# temporary name and renamed, so a reader never sees a half-written file.

# Values stay on one line and '=' becomes '-': PolyWorks macros (DATA_FILE READ LINE_FIELD) split a
# line at every '=', so a value must not contain one.
function ConvertTo-SafeValue([string]$Value) {
    if ($null -eq $Value) { return '' }
    return (($Value -replace '[\r\n]+', ' ') -replace '=', '-').Trim()
}

# $Pairs: ordered dictionary in the order the keys must appear.
function Write-KeyValueFile([string]$Path, $Pairs) {
    $lines = New-Object Collections.Generic.List[string]
    foreach ($key in $Pairs.Keys) {
        $value = ConvertTo-SafeValue ([string]$Pairs[$key])
        $lines.Add(('{0}={1}' -f $key, $value))
    }
    $temp = "$Path.part"
    [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($temp, $Path)
}

# Returns an ordered dictionary; only keys made of letters, digits and '_' are accepted.
# The encoding comes from the byte order mark (UTF-8 or UTF-16); without one, UTF-8 is assumed.
function Read-KeyValueFile([string]$Path, [int]$MaxBytes = 65536) {
    $result = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -gt $MaxBytes) { throw "File $Path is larger than $MaxBytes bytes." }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { $text = (New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)), $true)).ReadToEnd() }
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
