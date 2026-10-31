<#
  Development tool: builds the release package from the committed files only (git archive HEAD), so
  nothing outside the repository and nothing uncommitted can end up in it.
    tools\Build-Release.ps1                 -> dist\VLConnector-<VERSION>.zip and dist\SHA256SUMS.txt
    tools\Build-Release.ps1 -AllowDirty     test build with uncommitted changes: dist\VLConnector-<VERSION>-dirty.zip
                                            and dist\SHA256SUMS-dirty.txt
  The ZIP holds one folder VLConnector-<version>\ with app\, docs\, Install.cmd, Uninstall.cmd, the license,
  tools\Sign-Package.ps1, tools\Build-Interop.ps1 and MANIFEST.sha256 (SHA-256 of every file; Install.ps1
  checks it). The package fingerprint (SHA-256 of MANIFEST.sha256) is shown by the installer; publish it
  together with the ZIP hash (SHA256SUMS.txt). Releases are built by GitHub Actions from a tag
  (.github\workflows\release.yml). Anyone can rebuild a release from its tag and compare: the fingerprint is the
  same (the ZIP's own hash is not: ZIP files carry time stamps). A release package that exists already is never
  built again (its hash may be published): -Force only for one that was never handed out.
#>
param([switch]$AllowDirty, [switch]$Force)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$version = ([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim()
# a test build never takes the name of a release package
$name = if ($AllowDirty) { "VLConnector-$version-dirty" } else { "VLConnector-$version" }
$dist = Join-Path $repo 'dist'
if (-not $AllowDirty -and -not $Force -and (Test-Path -LiteralPath (Join-Path $dist "$name.zip"))) {
    throw "dist\$name.zip exists already. Raise VERSION for a new release, or use -AllowDirty for a test build."
}
$include = @('app', 'docs', 'Install.cmd', 'Install.ps1', 'Uninstall.cmd', 'Uninstall.ps1', 'README.md', 'LICENSE', 'CHANGELOG.md', 'VERSION', 'tools/Sign-Package.ps1', 'tools/Build-Interop.ps1')
$exclude = '^docs/images/source/'
$textExt = '.ps1', '.psm1', '.psd1', '.cmd', '.pwmacro', '.xaml', '.json', '.md', '.txt', '.svg', '.cs', '.html'

$dirty = @(git -C $repo status --porcelain --untracked-files=all -- $include)
if ($dirty -and -not $AllowDirty) { throw "Uncommitted changes in the package files:`n$($dirty -join "`n")`nCommit them or use -AllowDirty for a test build." }

New-Item -ItemType Directory -Force -Path $dist | Out-Null
$stage = Join-Path $dist $name
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$existing = @($include | Where-Object { git -C $repo ls-files -- $_ })
$tar = Join-Path $dist "$name.tar"
# git archive applies the same line-ending conversion as a checkout (.gitattributes: CRLF for scripts)
git -C $repo archive --format=tar -o $tar HEAD -- @existing
if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
& "$env:SystemRoot\System32\tar.exe" -xf $tar -C $stage
if ($LASTEXITCODE -ne 0) { throw 'tar failed.' }
Remove-Item -LiteralPath $tar
if ($AllowDirty) {
    # test build: the working copy of changed and new files; deleted files are left out ("R  old -> new": both).
    # Text files get CRLF line endings, as git archive would write them (.gitattributes).
    foreach ($line in $dirty) {
        foreach ($rel in @($line.Substring(3) -split ' -> ' | ForEach-Object { $_.Trim('"') })) {
            $src = Join-Path $repo $rel
            $dst = Join-Path $stage $rel
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
                if ($textExt -contains [IO.Path]::GetExtension($src)) {
                    $latin1 = [Text.Encoding]::GetEncoding(28591)
                    $text = $latin1.GetString([IO.File]::ReadAllBytes($src)) -replace "`r`n", "`n" -replace "`n", "`r`n"
                    [IO.File]::WriteAllBytes($dst, $latin1.GetBytes($text))
                }
                else { Copy-Item -LiteralPath $src -Destination $dst -Force }
            }
            elseif (Test-Path -LiteralPath $dst -PathType Leaf) { Remove-Item -LiteralPath $dst -Force }
        }
    }
}
Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { ($_.FullName.Substring($stage.Length + 1) -replace '\\', '/') -match $exclude } | Remove-Item -Force

# every text file of the package uses CRLF: the installer compares signed scripts with the manifest by
# cutting off the signature block, which only works on the exact line endings of the package
$lfOnly = foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object { $textExt -contains $_.Extension }) {
    if ([regex]::IsMatch([IO.File]::ReadAllText($f.FullName), "(?<!`r)`n")) { $f.FullName.Substring($stage.Length + 1) }
}
if ($lfOnly) { throw "Files with LF-only line endings in the package (check .gitattributes): $($lfOnly -join ', ')" }

# manifest "<sha256>  <relative/path>" in ordinal order: a rebuild of the same commit gives the same fingerprint on
# any PC, whatever its language (Czech collation, for one, puts "ch" after "h")
. (Join-Path $repo 'app\lib\Install.ps1')
$files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
$fingerprint = Write-VlcManifest $stage

# ZIP with '/' separators and one top folder
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $dist "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File) {
        $entry = "$name/" + ($f.FullName.Substring($stage.Length + 1) -replace '\\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, 'Optimal')
    }
}
finally { $archive.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
$sums = Join-Path $dist $(if ($AllowDirty) { 'SHA256SUMS-dirty.txt' } else { 'SHA256SUMS.txt' })
[IO.File]::WriteAllText($sums, ("{0}  {1}`r`n# package fingerprint shown by Install.cmd (SHA-256 of MANIFEST.sha256): {2}`r`n" -f $zipHash, (Split-Path $zip -Leaf), $fingerprint))
Remove-Item -LiteralPath $stage -Recurse -Force
"Package:     $zip ($([math]::Round((Get-Item $zip).Length / 1KB)) KB, $($files.Count + 1) files)"
"SHA-256:     $zipHash"
"Fingerprint: $fingerprint"
"Sums:        $sums"
