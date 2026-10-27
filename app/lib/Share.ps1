# Shared network folder of the network scenario (PolyWorks on another PC). Dot-source this file.
#
# Layout of the shared folder (the path in the settings points to it, e.g. \\fileserver\metrology\VLConnector):
#   jobs\        new jobs from the scanner PCs (<JobId>.job + <JobId>.stl)
#   work\        jobs the station is evaluating
#   reports\     results for the scanner PCs (<JobId>.pdf, .csv, .result)
#   processed\   finished jobs        failed\   jobs that could not be evaluated
#   status\      station heartbeat    parts.csv   part -> PolyWorks template and VL program
# See docs\Protocol.md.

$script:ShareFolders = 'jobs', 'work', 'reports', 'processed', 'failed', 'status'

# Creates the folders and checks that this PC can write to them. Returns Ok (bool) and Text.
function Test-VlcShare([string]$Path) {
    if (-not $Path) { return [pscustomobject]@{ Ok = $false; Text = 'Enter the network path of the shared folder.' } }
    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+' -and $Path -notmatch '^[A-Za-z]:\\') {
        return [pscustomobject]@{ Ok = $false; Text = 'Use a full path, for example \\fileserver\metrology\VLConnector.' }
    }
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null }
        foreach ($f in $script:ShareFolders) {
            $dir = Join-Path $Path $f
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null }
            $probe = Join-Path $dir ("~vlc_test_{0}_{1}.tmp" -f $env:COMPUTERNAME, [guid]::NewGuid().ToString('N').Substring(0, 6))
            [IO.File]::WriteAllText($probe, 'test')
            [IO.File]::Delete($probe)
        }
        $note = if ($Path -match '^[A-Za-z]:\\') { ' (local folder: only for tests on one PC)' } else { '' }
        return [pscustomobject]@{ Ok = $true; Text = "Connected - all folders are writable$note." }
    }
    catch { return [pscustomobject]@{ Ok = $false; Text = "Not usable: $($_.Exception.Message)" } }
}

function Get-VlcPartsFile([string]$Share) { return Join-Path $Share 'parts.csv' }

# parts.csv: Part;Template;VlProgram;Options (semicolon separated, UTF-8 with BOM, first line = header).
function Get-VlcParts([string]$Share) {
    $file = Get-VlcPartsFile $Share
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $rows = @(Import-Csv -LiteralPath $file -Delimiter ';' -Encoding UTF8)
    return @($rows | Where-Object { $_.Part -and $_.Template } | ForEach-Object {
        [pscustomobject]@{ Part = $_.Part.Trim(); Template = $_.Template.Trim(); VlProgram = ([string]$_.VlProgram).Trim(); Options = ([string]$_.Options).Trim() }
    })
}

function Save-VlcParts([string]$Share, $Parts) {
    $file = Get-VlcPartsFile $Share
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Part;Template;VlProgram;Options')
    foreach ($p in $Parts) {
        foreach ($v in $p.Part, $p.Template, $p.VlProgram, $p.Options) {
            if ([string]$v -match '[;\r\n"]') { throw "The value '$v' must not contain ; or quotes." }
        }
        $lines.Add(('{0};{1};{2};{3}' -f $p.Part, $p.Template, $p.VlProgram, $p.Options))
    }
    $temp = "$file.part"
    [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
    [IO.File]::Move($temp, $file)
}
