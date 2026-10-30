# The AI Replay programs (.vld4) for VL Connector. A program given by name is searched in the program folders
# of the settings first, then in VL's list of recently used programs. Dot-source this file (it has no param block).

# VL's list of recently used programs (RecentUsedTemplateFiles.xml), oldest first; only absolute paths.
function Get-VlcRecentPrograms([string]$ListFile) {
    try {
        $fs = [IO.File]::Open($ListFile, 'Open', 'Read', 'ReadWrite, Delete')
        try { $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() }
        finally { $fs.Dispose() }
    }
    catch { return @() }
    return @([regex]::Matches($text, 'i:type="b:string"[^>]*>([^<]+)</a:Value>') |
        ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value) } |
        Where-Object { $_ -match '^([A-Za-z]:\\|\\\\)' })
}

# The program name without a trailing .vld4, and only that: "Part.A" stays "Part.A".
function Get-VlcProgramName([string]$Name) {
    return ([IO.Path]::GetFileName($Name.Trim()) -replace '\.vld4$', '')
}

# Full path of a program, $null when it is not found. A path is taken as it is. A name (with or without .vld4) is
# searched in the program folders (with subfolders) and, when it is not there, in VL's recent programs; names are
# compared without regard to case. A name found more than once in the same place is an error: the wrong part
# program must never be used.
function Resolve-VlcProgram([string]$Name, [string[]]$ProgramDirs = @(), [string[]]$RecentPaths = @()) {
    $Name = "$Name".Trim()
    if (-not $Name) { return $null }
    if ($Name -match '[\\/]') {
        foreach ($candidate in @($Name, "$Name.vld4")) {
            $full = [IO.Path]::GetFullPath($candidate)
            if ($full -match '\.vld4$' -and (Test-Path -LiteralPath $full -PathType Leaf)) { return (Get-Item -LiteralPath $full).FullName }
        }
        return $null
    }
    $base = Get-VlcProgramName $Name
    $isProgram = { param([string]$Path) [string]::Equals((Get-VlcProgramName $Path), $base, [StringComparison]::OrdinalIgnoreCase) }
    $inFolders = @(@(foreach ($dir in @($ProgramDirs | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $dir -PathType Container) {
            Get-ChildItem -LiteralPath $dir -Filter '*.vld4' -File -Recurse -ErrorAction SilentlyContinue | Where-Object { & $isProgram $_.Name } | ForEach-Object { $_.FullName }
        }
    }) | Sort-Object -Unique)
    if ($inFolders.Count -eq 1) { return $inFolders[0] }
    if ($inFolders.Count -gt 1) { throw "Program '$Name' exists in several places of the program folders, give the full path: $($inFolders -join '; ')" }
    $recent = @(@($RecentPaths | Where-Object { $_ -match '\.vld4$' -and (& $isProgram $_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }) | Sort-Object -Unique)
    if ($recent.Count -eq 1) { return $recent[0] }
    if ($recent.Count -gt 1) { throw "Program '$Name' is in VL's recent programs more than once, give the full path: $($recent -join '; ')" }
    return $null
}
