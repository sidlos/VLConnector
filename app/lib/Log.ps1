# Logging of VL Connector. Dot-source this file (it has no param block).
# One file per component and day in %LOCALAPPDATA%\VLConnector\logs; files older than 30 days are removed.

$script:VlcLogFile = $null

function Initialize-VlcLog([string]$Component, [int]$KeepDays = 30) {
    $dir = Join-Path (Join-Path $env:LOCALAPPDATA 'VLConnector') 'logs'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $script:VlcLogFile = Join-Path $dir ('{0}_{1:yyyyMMdd}.log' -f $Component, (Get-Date))
    $limit = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit } | Remove-Item -Force -ErrorAction SilentlyContinue
    return $script:VlcLogFile
}

# Shared write: the log can be written even while a viewer has it open.
function Write-VlcLog([string]$Text) {
    if (-not $script:VlcLogFile) { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Text
    try {
        $fs = [IO.File]::Open($script:VlcLogFile, 'Append', 'Write', 'ReadWrite, Delete')
        try { $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($bytes, 0, $bytes.Length) }
        finally { $fs.Dispose() }
    }
    catch { }
}
