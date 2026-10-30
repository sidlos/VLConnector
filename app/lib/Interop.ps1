# The Windows and PolyWorks interfaces of VL Connector (namespace VLConnector.Interop, sources in
# app\interop\*.cs). Dot-source this file (it has no param block) and call Import-VlcInterop before the first use.
#
# The installer compiles the sources once into <install>\bin\VLConnector.Interop.dll (tools\Build-Interop.ps1);
# an installed copy only loads that DLL and never starts a compiler. The DLL carries the SHA-256 of the sources
# it was built from (file properties, Comments: "SourceSha256 <hash>"), so a DLL that does not belong to the
# installed scripts is refused before it is loaded. Only a development tree (neither install-info.txt nor
# MANIFEST.sha256 next to app\) compiles in memory.

$script:VlcInteropSourceDir = Join-Path (Split-Path $PSScriptRoot) 'interop'
$script:VlcInteropRoot = Split-Path (Split-Path $PSScriptRoot)
$script:VlcInteropReferences = 'UIAutomationClient', 'UIAutomationTypes', 'WindowsBase'

function Get-VlcInteropDllPath { return Join-Path $script:VlcInteropRoot 'bin\VLConnector.Interop.dll' }

# The sources as one compilable text and their SHA-256. Line endings are normalized, so a checkout with LF or
# CRLF gives the same value. Generated around them: the file properties of the DLL (with the hash) and the
# class BuildInfo, which tells which sources a loaded copy came from.
function Get-VlcInteropSource([string]$Dir = $script:VlcInteropSourceDir) {
    $names = [string[]]@(Get-ChildItem -LiteralPath $Dir -Filter '*.cs' -File | ForEach-Object { $_.Name })
    if (-not $names.Count) { throw "No interface sources (*.cs) in $Dir." }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $sb = New-Object Text.StringBuilder
    foreach ($name in $names) {
        $text = [IO.File]::ReadAllText((Join-Path $Dir $name)) -replace "`r`n", "`n"
        [void]$sb.Append("// ---- $name`n").Append($text)
        if (-not $text.EndsWith("`n")) { [void]$sb.Append("`n") }
    }
    $body = $sb.ToString()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($body)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $version = 'dev'
    $versionFile = Join-Path (Split-Path (Split-Path $Dir)) 'VERSION'
    if (Test-Path -LiteralPath $versionFile) { $version = ([IO.File]::ReadAllText($versionFile)).Trim() -replace '[^0-9A-Za-z.+-]', '' }
    $fileVersion = if ($version -match '^(\d+)\.(\d+)\.(\d+)') { "$($Matches[1]).$($Matches[2]).$($Matches[3]).0" } else { '0.0.0.0' }
    $header = "[assembly: System.Reflection.AssemblyTitle(`"VL Connector for PolyWorks - Windows and PolyWorks interfaces`")]`n" +
        "[assembly: System.Reflection.AssemblyProduct(`"VL Connector for PolyWorks`")]`n" +
        "[assembly: System.Reflection.AssemblyInformationalVersion(`"$version`")]`n" +
        "[assembly: System.Reflection.AssemblyFileVersion(`"$fileVersion`")]`n" +
        "[assembly: System.Reflection.AssemblyDescription(`"SourceSha256 $hash`")]`n"
    $buildInfo = "namespace VLConnector.Interop`n{`n    public static class BuildInfo { public const string SourceSha256 = `"$hash`"; }`n}`n"
    return [pscustomobject]@{ Text = $header + $body + $buildInfo; Sha256 = $hash }
}

# The source hash a compiled DLL carries, read from its file properties without loading it ('' when none).
function Get-VlcInteropDllHash([string]$Path) {
    $comments = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).Comments
    if ($comments -match '^SourceSha256 ([0-9a-f]{64})$') { return $Matches[1] }
    return ''
}

# Compiles the sources into a DLL (written under a temporary name, checked, then moved into place).
function Build-VlcInterop([Parameter(Mandatory = $true)] [string]$OutputPath, [string]$SourceDir = $script:VlcInteropSourceDir) {
    $src = Get-VlcInteropSource $SourceDir
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    $dir = Split-Path $OutputPath
    $temp = Join-Path $dir ('.build-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        $built = Join-Path $temp (Split-Path $OutputPath -Leaf)
        # with -OutputAssembly the types are only written to the file, not loaded into this process
        Add-Type -TypeDefinition $src.Text -ReferencedAssemblies $script:VlcInteropReferences -OutputAssembly $built -OutputType Library
        if ((Get-VlcInteropDllHash $built) -ne $src.Sha256) { throw "The compiled DLL does not carry the source hash $($src.Sha256)." }
        Move-Item -LiteralPath $built -Destination $OutputPath -Force
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    return $src.Sha256
}

function Import-VlcInterop {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $expected = (Get-VlcInteropSource).Sha256
    $loaded = 'VLConnector.Interop.BuildInfo' -as [type]
    if ($loaded) {
        if ($loaded::SourceSha256 -ne $expected) { throw 'Another version of VL Connector is already loaded in this PowerShell process. Close it and start VL Connector again.' }
        return
    }
    $dll = Get-VlcInteropDllPath
    $release = (Test-Path -LiteralPath (Join-Path $script:VlcInteropRoot 'install-info.txt')) -or (Test-Path -LiteralPath (Join-Path $script:VlcInteropRoot 'MANIFEST.sha256'))
    if (Test-Path -LiteralPath $dll) {
        if ((Get-VlcInteropDllHash $dll) -ne $expected) { throw "$dll does not belong to the installed VL Connector scripts. Repair VL Connector: run Install.cmd of the package again." }
        Add-Type -Path $dll
    }
    elseif ($release) { throw "VL Connector is not complete: $dll is missing. Repair VL Connector: run Install.cmd of the package again." }
    else { Add-Type -TypeDefinition (Get-VlcInteropSource).Text -ReferencedAssemblies $script:VlcInteropReferences }
}
