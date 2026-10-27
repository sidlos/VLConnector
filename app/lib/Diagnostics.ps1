# Versions and the diagnostics ZIP for support. Dot-source this file; it needs lib\Settings.ps1,
# lib\PolyWorksSetup.ps1, lib\Share.ps1 and lib\Prerequisites.ps1.

function Get-VlcVersionsText($Settings) {
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add(('{0,-20}{1}' -f 'VL Connector', (Get-VlcVersion)))
    $exe = [string]$Settings.vl.exe
    $vl = if ($exe -and (Test-Path -LiteralPath $exe)) { (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } else { 'not found' }
    $lines.Add(('{0,-20}{1}' -f 'VL Application', $vl))
    $pw = Get-PolyWorksInfo
    $lines.Add(('{0,-20}{1}' -f 'PolyWorks|Inspector', $(if ($pw) { "$($pw.InspectorVersion) ($($pw.Name))" } else { 'not found' })))
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $lines.Add(('{0,-20}{1}' -f 'Windows', $(if ($os) { "$($os.Caption -replace '^Microsoft ', '') $($os.Version)" } else { [Environment]::OSVersion.VersionString })))
    $lines.Add(('{0,-20}{1}' -f 'PowerShell', $PSVersionTable.PSVersion.ToString()))
    return ($lines -join "`n")
}

# ZIP on the desktop with logs, settings, the status check and the list of installed files with hashes.
# Scans, reports and PolyWorks data are not included.
function New-VlcDiagnosticsZip([string]$Folder = [Environment]::GetFolderPath('Desktop')) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $paths = Get-VlcPaths
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $temp = Join-Path ([IO.Path]::GetTempPath()) "VLConnector_diag_$stamp"
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        $settings = Read-VlcSettings
        Get-VlcVersionsText $settings | Set-Content -LiteralPath (Join-Path $temp 'versions.txt') -Encoding UTF8
        Get-VlcStatusItems $settings | Format-Table Level, Title, Detail -AutoSize -Wrap | Out-String -Width 200 |
            Set-Content -LiteralPath (Join-Path $temp 'status.txt') -Encoding UTF8
        $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $temp 'settings-effective.json') -Encoding UTF8
        foreach ($f in $paths.MachineFile, $paths.UserFile) {
            if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination (Join-Path $temp ("settings-" + (Split-Path $f -Leaf))) }
        }
        if (Test-Path -LiteralPath $paths.LogDir) {
            $logs = Join-Path $temp 'logs'
            New-Item -ItemType Directory -Force -Path $logs | Out-Null
            Get-ChildItem -LiteralPath $paths.LogDir -Filter '*.log' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) } |
                Copy-Item -Destination $logs
        }
        Get-ChildItem -LiteralPath $paths.InstallDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\(layouts|\.git|tests|dist)\\' } |
            ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.FullName.Substring($paths.InstallDir.Length + 1) } |
            Set-Content -LiteralPath (Join-Path $temp 'installed-files.sha256') -Encoding UTF8
        $zip = Join-Path $Folder "VLConnector_diagnostics_$($env:COMPUTERNAME)_$stamp.zip"
        [IO.Compression.ZipFile]::CreateFromDirectory($temp, $zip)
        return $zip
    }
    finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
