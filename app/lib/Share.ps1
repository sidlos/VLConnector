# Shared network folder of the network scenario (PolyWorks on another PC). Dot-source this file.
#
# Layout of the shared folder (the path in the settings points to it, e.g. \\fileserver\metrology\VLConnector):
#   jobs\        new jobs from the scanner PCs (<JobId>.job + <JobId>.stl)
#   work\        jobs the station is evaluating
#   reports\     results for the scanner PCs (<JobId>.pdf, .csv, .result)
#   processed\   finished jobs        failed\   jobs that could not be evaluated
#   status\      station heartbeat    programs.csv   VL program -> PolyWorks workspace and template
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

function Get-VlcProgramsFile([string]$Share) { return Join-Path $Share 'programs.csv' }

# programs.csv: Program;Workspace;Template (semicolon separated, UTF-8 with BOM, first line = header).
#   Program: the AI Replay program, i.e. the .vld4 file name without extension. The STL of a scan is named
#            after it (<program>_<date>_<time>.stl) and the job carries it.
#   Workspace, Template: the PolyWorks workspace file (path on the station) and the template project in it.
function Get-VlcPrograms([string]$Share) {
    $file = Get-VlcProgramsFile $Share
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $rows = @(Import-Csv -LiteralPath $file -Delimiter ';' -Encoding UTF8)
    return @($rows | Where-Object { $_.Program -and $_.Template } | ForEach-Object {
        [pscustomobject]@{ Program = ([IO.Path]::GetFileNameWithoutExtension($_.Program.Trim())); Workspace = ([string]$_.Workspace).Trim(); Template = $_.Template.Trim() }
    })
}

# The row of a VL program (path, file name or name; case does not matter), $null if there is none.
function Find-VlcProgram([string]$Share, [string]$Program) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Program)
    if (-not $name) { return $null }
    return @(Get-VlcPrograms $Share | Where-Object { $_.Program -eq $name })[0]
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
