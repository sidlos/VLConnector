# The verdict of a measured piece, computed from the raw control data that VLC_Evaluate.pwmacro writes
# (polyworks\Complete-Evaluation.ps1). Fail-closed: only PolyWorks' documented results inside the tolerance
# count as OK; anything missing, unknown, truncated or inconsistent is NOK or an error, never OK.
# Dot-source this file; it needs lib\KeyValueFile.ps1.

# PolyWorks' tolerance zone results (MEASURE CONTROL TEST TOLERANCE_ZONE_RESULT GET) and what they mean here.
$script:VlcToleranceResults = @{
    'Within positive safe zone'    = 'OK'
    'Within negative safe zone'    = 'OK'
    'Within upper warning zone'    = 'OK (warning)'
    'Within lower warning zone'    = 'OK (warning)'
    'Beyond upper tolerance limit' = 'NOK'
    'Beyond lower tolerance limit' = 'NOK'
}
$script:VlcControlKeys = 'CONTROL', 'NAME', 'NOMINAL', 'MEASURED', 'DEVIATION', 'UPPER_TOL', 'UPPER_WARN', 'LOWER_WARN', 'LOWER_TOL', 'RESULT'
$script:VlcControlsHeader = 'FORMAT', 'RUN', 'JOBID', 'PIECE', 'TEMPLATE', 'PROGRAM', 'OPERATOR', 'STL', 'STL_SHA256', 'REPORT_DIR', 'CSV',
    'ALIGN_STATUS', 'ALIGN_ERROR', 'EXTRACT_STATUS', 'EXTRACT_ERROR'

# OK, OK (warning), NOK, NOT MEASURED (no result) or UNKNOWN (a result PolyWorks does not document).
function Get-VlcControlVerdict([string]$Result) {
    if (-not $Result.Trim()) { return 'NOT MEASURED' }
    $verdict = $script:VlcToleranceResults[$Result.Trim()]
    if ($verdict) { return $verdict }
    return 'UNKNOWN'
}

# Reads the controls file of VLC_Evaluate: the header keys in a fixed order, then one record of ten lines per
# control (CONTROL, NAME, NOMINAL, ... RESULT) and END=<number of records>. Throws when anything is missing, out
# of order, or the file is cut off.
function Read-VlcControlsFile([string]$Path, [int]$MaxBytes = 16MB) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "The control data $Path is missing." }
    if ((Get-Item -LiteralPath $Path).Length -gt $MaxBytes) { throw "The control data $Path is larger than $MaxBytes bytes." }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { $text = (New-Object IO.StreamReader($fs, (New-Object Text.UTF8Encoding($false)), $true)).ReadToEnd() }
    finally { $fs.Dispose() }
    $lines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
    $pairs = foreach ($line in $lines) {
        $i = $line.IndexOf('=')
        if ($i -lt 1) { throw "The control data has a line without KEY=value: '$line'." }
        [pscustomobject]@{ Key = $line.Substring(0, $i); Value = $line.Substring($i + 1) }
    }
    $pairs = @($pairs)
    $header = [ordered]@{}
    $n = 0
    foreach ($key in $script:VlcControlsHeader) {
        if ($n -ge $pairs.Count -or $pairs[$n].Key -ne $key) { throw "The control data has no $key in line $($n + 1)." }
        $header[$key] = $pairs[$n].Value
        $n++
    }
    if ($header.FORMAT -ne 'VLC-CONTROLS-1') { throw "The control data has the unknown format '$($header.FORMAT)'." }
    $controls = [Collections.Generic.List[object]]::new()
    while ($n -lt $pairs.Count -and $pairs[$n].Key -ne 'END') {
        $record = [ordered]@{}
        foreach ($key in $script:VlcControlKeys) {
            if ($n -ge $pairs.Count -or $pairs[$n].Key -ne $key) { throw "The control data is incomplete at control $($controls.Count + 1): $key expected in line $($n + 1)." }
            $record[$key] = $pairs[$n].Value
            $n++
        }
        $controls.Add([pscustomobject]$record)
    }
    if ($n -ge $pairs.Count) { throw 'The control data is cut off (no END line).' }
    $end = 0
    if (-not [int]::TryParse($pairs[$n].Value, [ref]$end) -or $end -ne $controls.Count) { throw "The control data holds $($controls.Count) controls, but its END line says '$($pairs[$n].Value)'." }
    if ($n + 1 -ne $pairs.Count) { throw 'The control data has lines after its END line.' }
    return [pscustomobject]@{ Header = $header; Controls = $controls.ToArray() }
}

# State (OK/ERROR), Verdict (OK/NOK, empty on ERROR), Summary, Count and Message of a piece. $StlHash: SHA-256
# of the STL now; it must match the hash recorded when the STL was made (when one was recorded).
function Get-VlcEvaluation($Data, [string]$StlHash) {
    $h = $Data.Header
    $count = @($Data.Controls).Count
    $result = [ordered]@{ State = 'ERROR'; Verdict = ''; Summary = ''; Count = $count; Message = ''; Rows = @() }
    if ($h.ALIGN_STATUS -eq 'Error') { $result.Message = "The alignment to the CAD failed: $($h.ALIGN_ERROR)"; return [pscustomobject]$result }
    if ($h.EXTRACT_STATUS -eq 'Error') { $result.Message = "The measurement of the features failed: $($h.EXTRACT_ERROR)"; return [pscustomobject]$result }
    if ($h.STL_SHA256 -and $StlHash -ne $h.STL_SHA256.ToLower()) { $result.Message = "The STL is not the one that was scanned (SHA-256 $StlHash, expected $($h.STL_SHA256))."; return [pscustomobject]$result }
    if (-not $count) { $result.Message = 'The template has no controls, so the piece cannot be judged. Add controls with tolerances to the template.'; return [pscustomobject]$result }
    $rows = foreach ($c in $Data.Controls) { [pscustomobject]@{ Control = $c; Verdict = Get-VlcControlVerdict $c.RESULT } }
    $rows = @($rows)
    $nok = @($rows | Where-Object { $_.Verdict -eq 'NOK' }).Count
    $missing = @($rows | Where-Object { $_.Verdict -eq 'NOT MEASURED' }).Count
    $unknown = @($rows | Where-Object { $_.Verdict -eq 'UNKNOWN' })
    $warn = @($rows | Where-Object { $_.Verdict -eq 'OK (warning)' }).Count
    $result.State = 'OK'
    $result.Rows = $rows
    if ($nok -or $missing -or $unknown.Count) {
        $result.Verdict = 'NOK'
        $parts = @("$nok of $count controls out of tolerance", "$missing not measured")
        if ($unknown.Count) {
            $names = @($unknown | Select-Object -First 3 | ForEach-Object { "$($_.Control.CONTROL) $($_.Control.NAME): '$($_.Control.RESULT)'" }) -join ', '
            $parts += "$($unknown.Count) with a result VL Connector does not know ($names)"
        }
        $result.Summary = $parts -join ', '
    }
    else {
        $result.Verdict = 'OK'
        $result.Summary = if ($warn) { "all $count controls within tolerance ($warn in the warning zone)" } else { "all $count controls within tolerance" }
    }
    return [pscustomobject]$result
}

# One CSV cell (separator ';'). Text that a spreadsheet would read as a formula gets a leading apostrophe;
# numbers stay as they are; cells with ';', '"' or a line break are quoted.
function ConvertTo-VlcCsvCell([string]$Text, [switch]$Number) {
    if ($null -eq $Text) { $Text = '' }
    $isNumber = $Number -and $Text -match '^[+-]?(\d+([.,]\d*)?|[.,]\d+)([eE][+-]?\d+)?$'
    if (-not $isNumber -and $Text -match '^[=+\-@\t\r]') { $Text = "'" + $Text }
    if ($Text -match '[;"\r\n]') { $Text = '"' + ($Text -replace '"', '""') + '"' }
    return $Text
}

# The CSV of a piece: UTF-8 with BOM (Excel reads names with accents correctly), ';' as separator.
function Write-VlcEvaluationCsv([string]$Path, $Data, $Evaluation, [string]$Version, [string]$StlHash) {
    $h = $Data.Header
    $cell = { param($Text, [switch]$Number) ConvertTo-VlcCsvCell $Text -Number:$Number }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add((@('Part', $h.PIECE, 'VL program', $h.PROGRAM, 'Operator', $h.OPERATOR) | ForEach-Object { & $cell $_ }) -join ';')
    $lines.Add((@('Template', $h.TEMPLATE, 'Alignment', 'Best-fit to CAD (automatic pre-alignment)', 'VL Connector', $Version) | ForEach-Object { & $cell $_ }) -join ';')
    $lines.Add((@('STL', [IO.Path]::GetFileName($h.STL), 'SHA-256', $StlHash) | ForEach-Object { & $cell $_ }) -join ';')
    $lines.Add('Object;Control;Nominal;Measured;Deviation;Upper tol.;Lower tol.;Result')
    foreach ($r in $Evaluation.Rows) {
        $c = $r.Control
        $lines.Add(((& $cell $c.CONTROL), (& $cell $c.NAME), (& $cell $c.NOMINAL -Number), (& $cell $c.MEASURED -Number), (& $cell $c.DEVIATION -Number),
            (& $cell $c.UPPER_TOL -Number), (& $cell $c.LOWER_TOL -Number), (& $cell $r.Verdict)) -join ';')
    }
    $lines.Add((@('RESULT', "$($Evaluation.Verdict) - $($Evaluation.Summary)") | ForEach-Object { & $cell $_ }) -join ';')
    $temp = "$Path.part"
    [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Delete($Path) }
    [IO.File]::Move($temp, $Path)
}
