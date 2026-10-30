# Shared network folder of the network scenario (PolyWorks on another PC). Dot-source this file; it loads
# lib\VlPrograms.ps1 itself (program names).
#
# Layout of the shared folder (the path in the settings points to it, e.g. \\fileserver\metrology\VLConnector):
#   jobs\        new jobs from the scanner PCs (<JobId>.job + <JobId>.stl); jobs\rejected\ files that are no jobs
#   work\        jobs a station is evaluating (<JobId>.job, .stl and .claim: which station, since when)
#   reports\     results for the scanner PCs (<JobId>.pdf, .csv, .result)
#   processed\   finished jobs        failed\   jobs that could not be evaluated
#   status\      station heartbeats   programs.csv   VL program -> PolyWorks workspace and template
# Rights a role needs (docs\IT-Review, access matrix): a scanner PC writes jobs\ and reads reports\, status\ and
# programs.csv; a station writes every folder. See docs\Protocol.md.

. (Join-Path $PSScriptRoot 'VlPrograms.ps1')

$script:ShareFolders = 'jobs', 'work', 'reports', 'processed', 'failed', 'status'

# Checks that this PC can do in the shared folder what its role needs, and creates missing folders where it may.
# Scanner: write and delete in jobs\, read reports\ and status\. Station: write and delete in every folder.
# Returns Ok (bool) and Text.
function Test-VlcShare([string]$Path, [ValidateSet('Scanner', 'Station')] [string]$Role = 'Station') {
    if (-not $Path) { return [pscustomobject]@{ Ok = $false; Text = 'Enter the network path of the shared folder.' } }
    if ($Path -notmatch '^\\\\[^\\]+\\[^\\]+' -and $Path -notmatch '^[A-Za-z]:\\') {
        return [pscustomobject]@{ Ok = $false; Text = 'Use a full path, for example \\fileserver\metrology\VLConnector.' }
    }
    $write = if ($Role -eq 'Station') { $script:ShareFolders } else { @('jobs') }
    $read = if ($Role -eq 'Station') { @() } else { @('reports', 'status') }
    $step = ''
    try {
        $step = 'open the folder'
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null }
        foreach ($f in @($write) + @($read)) {
            $dir = Join-Path $Path $f
            $step = "create $f\"
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null }
        }
        foreach ($f in $write) {
            $step = "write in $f\"
            $probe = Join-Path (Join-Path $Path $f) ("~vlc_test_{0}_{1}.tmp" -f $env:COMPUTERNAME, [guid]::NewGuid().ToString('N').Substring(0, 6))
            [IO.File]::WriteAllText($probe, 'test')
            $step = "delete in $f\"
            [IO.File]::Delete($probe)
        }
        foreach ($f in $read) {
            $step = "read $f\"
            [void]@(Get-ChildItem -LiteralPath (Join-Path $Path $f) -ErrorAction Stop)
        }
        $note = if ($Path -match '^[A-Za-z]:\\') { ' (local folder: only for tests on one PC)' } else { '' }
        $what = if ($Role -eq 'Station') { 'all folders are writable' } else { 'jobs can be sent, reports and status can be read' }
        return [pscustomobject]@{ Ok = $true; Text = "Connected - $what$note." }
    }
    catch { return [pscustomobject]@{ Ok = $false; Text = "Not usable (cannot $step): $($_.Exception.Message)" } }
}

function Get-VlcProgramsFile([string]$Share) { return Join-Path $Share 'programs.csv' }

# programs.csv: Program;Workspace;Template (';' separated, UTF-8 with BOM, first line = this header).
#   Program: the AI Replay program, i.e. the .vld4 file name without .vld4 (only that is removed: "Part.A" stays
#            "Part.A"). The STL of a scan is named after it and the job carries it.
#   Workspace, Template: the PolyWorks workspace file (full path on the station, .pwk) and the template project.
# Read with its problems: unusable lines are left out and named in Problems; a program listed twice is left out
# completely (which line is meant is not clear). Fatal: the file itself cannot be used; the station then pauses
# instead of failing every job. Workspaces on network paths only when the administrator allows them.
function Read-VlcProgramsList([string]$Share, [bool]$AllowUnc = $false) {
    $file = Get-VlcProgramsFile $Share
    $rows = [Collections.Generic.List[object]]::new()
    $problems = New-Object Collections.Generic.List[string]
    $result = { param($Fatal) [pscustomobject]@{ Rows = $rows.ToArray(); Problems = $problems.ToArray(); Fatal = $Fatal } }
    if (-not (Test-Path -LiteralPath $file)) { return & $result '' }
    try { $lines = [IO.File]::ReadAllLines($file) }
    catch { return & $result "The Measurement Programs List (programs.csv) cannot be read: $($_.Exception.Message)" }
    if (-not $lines.Count -or ($lines[0] -replace '\s', '') -ine 'Program;Workspace;Template') {
        return & $result 'The Measurement Programs List (programs.csv) must start with the line Program;Workspace;Template.'
    }
    $lineOf = @{}
    $twice = @{}
    for ($n = 1; $n -lt $lines.Count; $n++) {
        $line = $lines[$n]
        if (-not $line.Trim()) { continue }
        $at = "programs.csv line $($n + 1)"
        $f = @($line -split ';')
        if ($f.Count -ne 3) { $problems.Add("${at}: three values separated by ';' are needed (Program;Workspace;Template)."); continue }
        if ($line -match '[="]') { $problems.Add("${at}: '=' and quotes are not allowed."); continue }
        $program = Get-VlcProgramName $f[0]
        $workspace = $f[1].Trim()
        $template = $f[2].Trim()
        if (-not $program -or -not $template) { $problems.Add("${at}: the program and the template are needed."); continue }
        if ($workspace -notmatch '^([A-Za-z]:\\|\\\\)' -or $workspace -notmatch '\.pwk$') { $problems.Add("${at}: the workspace must be the full path of a .pwk file."); continue }
        if ($workspace -match '^\\\\' -and -not $AllowUnc) { $problems.Add("${at}: the workspace $workspace is on a network path; the administrator has not allowed that (network.allowUncWorkspaces)."); continue }
        $key = $program.ToLowerInvariant()
        if ($lineOf.ContainsKey($key)) { $problems.Add("${at}: program $program is listed twice (also line $($lineOf[$key])); neither line is used."); $twice[$key] = $true; continue }
        $lineOf[$key] = $n + 1
        $rows.Add([pscustomobject]@{ Program = $program; Workspace = $workspace; Template = $template })
    }
    foreach ($r in $rows.ToArray()) {
        $key = ([string]$r.Program).ToLowerInvariant()
        if ($twice.ContainsKey($key)) { [void]$rows.Remove($r) }
    }
    return & $result ''
}

function Get-VlcPrograms([string]$Share, [bool]$AllowUnc = $false) { return @((Read-VlcProgramsList $Share $AllowUnc).Rows) }

# The row of a VL program (path, file name or name; only a trailing .vld4 is ignored, case does not matter),
# $null if there is none.
function Find-VlcProgram([string]$Share, [string]$Program, [bool]$AllowUnc = $false) {
    $name = Get-VlcProgramName $Program
    if (-not $name) { return $null }
    return @(Get-VlcPrograms $Share $AllowUnc | Where-Object { [string]::Equals($_.Program, $name, [StringComparison]::OrdinalIgnoreCase) })[0]
}

function Save-VlcPrograms([string]$Share, $Programs) {
    $file = Get-VlcProgramsFile $Share
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('Program;Workspace;Template')
    foreach ($p in $Programs) {
        foreach ($v in $p.Program, $p.Workspace, $p.Template) {
            if ([string]$v -match '[;\r\n"=]') { throw "The value '$v' must not contain ; = or quotes." }
        }
        $lines.Add(('{0};{1};{2}' -f $p.Program, $p.Workspace, $p.Template))
    }
    $temp = "$file.part"
    [IO.File]::WriteAllLines($temp, [string[]]$lines, (New-Object Text.UTF8Encoding($true)))
    if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
    [IO.File]::Move($temp, $file)
}
