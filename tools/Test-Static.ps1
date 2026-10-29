<#
  Static source checks (no PowerShell module needed). Exit code 1 when anything fails.
  - every PowerShell file parses without errors
  - shipped files are ASCII, or UTF-8 with BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI)
  - no Czech words from the prototype and no developer paths in shipped files
  - no binaries in app\ and docs\ except PNG and ICO
  - .cmd files use CRLF line endings (cmd.exe misparses LF-only batch files)
#>
param([string]$Root = (Split-Path $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$problems = New-Object Collections.Generic.List[string]
function Add-Problem([string]$File, [string]$Text) { $problems.Add(('{0}: {1}' -f $File.Substring($Root.Length + 1), $Text)) }

$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\(\.git|dist|tests\\_work)\\' })
$shipped = @($files | Where-Object {
    $rel = $_.FullName.Substring($Root.Length + 1)
    $rel -match '^(app|docs)\\' -or $rel -match '^(Install|Uninstall)\.(cmd|ps1)$' -or $rel -match '^(README\.md|LICENSE|CHANGELOG\.md|VERSION)$' -or $rel -eq 'tools\Sign-Scripts.ps1' })

# 1. PowerShell syntax
foreach ($f in $files | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    foreach ($e in @($errors)) { Add-Problem $f.FullName "parse error line $($e.Extent.StartLineNumber): $($e.Message)" }
}

# 2. Encoding
$textExt = '.ps1', '.psm1', '.psd1', '.cmd', '.pwmacro', '.json', '.xaml', '.md', '.txt', '.svg', '.html', '.css'
foreach ($f in $shipped | Where-Object { $textExt -contains $_.Extension -or $_.Name -in 'LICENSE', 'VERSION' }) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
    if ($nonAscii -and -not $bom -and $f.Extension -in '.ps1', '.psm1', '.psd1', '.pwmacro', '.cmd') {
        Add-Problem $f.FullName "non-ASCII text without UTF-8 BOM ($nonAscii bytes)"
    }
    if ($f.Extension -eq '.cmd' -and $nonAscii) { Add-Problem $f.FullName 'non-ASCII text in a .cmd file' }
}

# 3. Czech prototype words and developer paths
$czech = '\b(Znacka|Vystup|Rezim|Rychly|HnedPoSkenu|Nanecisto|JenExport|NoveOkno|VlDoPozadi|CasovacMin|KlidSec|StlSoubor|STAV=|ZPRAVA=|ZACATEK=|KONEC=|CHYBA|ZRUSENO|NANECISTO|hotovo|neni|okno|oteviram|pouziju|cekam|Spoustet|Pouziti|souradnic\w*|zarovn\w*|sablon\w*|protokol\w*|trojuhelnik\w*)\b'
$devPaths = 'C:\\Users\\host|VL_diagnostika|\bVRVL\b|\\\\SERVER\\|Desktop\\Polyworks test|C:\\PolyWorks\\ABC'
foreach ($f in $shipped | Where-Object { $textExt -contains $_.Extension }) {
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($f.FullName)) {
        $n++
        if ($line -match $czech) { Add-Problem $f.FullName "line ${n}: Czech prototype word '$($Matches[0])'" }
        if ($line -match $devPaths) { Add-Problem $f.FullName "line ${n}: developer path '$($Matches[0])'" }
    }
}

# 4. Binaries
$allowedBinary = '.png', '.ico'
foreach ($f in $shipped) {
    if ($textExt -contains $f.Extension -or $f.Name -in 'LICENSE', 'VERSION' -or $allowedBinary -contains $f.Extension) { continue }
    Add-Problem $f.FullName "unexpected file type '$($f.Extension)' in the shipped set"
}

# 5. CRLF in .cmd
foreach ($f in $files | Where-Object { $_.Extension -eq '.cmd' }) {
    $text = [IO.File]::ReadAllText($f.FullName)
    if ($text -match '(?<!\r)\n') { Add-Problem $f.FullName 'LF-only line endings (needs CRLF)' }
}

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "$($problems.Count) static check problem(s)" -ForegroundColor Red
    exit 1
}
Write-Host "Static checks passed ($($files.Count) files, $($shipped.Count) shipped)" -ForegroundColor Green
