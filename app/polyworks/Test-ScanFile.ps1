<#
  Test-ScanFile.ps1 - VL Connector for PolyWorks: checks, right before VLC_Evaluate.pwmacro imports a scan, that
  the STL is the one VL Connector exported (the launcher or the station recorded its SHA-256). It evaluates
  nothing. Writes KEY=value lines in this fixed order (the macro reads them by line number, see docs\Protocol.md):
     1 STATE    OK, or ERROR (the scan is not imported)
     2 MESSAGE  the reason of an ERROR
  Usage (from the macro): powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File Test-ScanFile.ps1
                          -Stl <file> -Sha256 <hex> -Out <file>
#>
param(
    [Parameter(Mandatory = $true)] [string]$Stl,
    [Parameter(Mandatory = $true)] [string]$Sha256,
    [Parameter(Mandatory = $true)] [string]$Out
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path (Split-Path $PSScriptRoot) 'lib\LanguageCheck.ps1') -Caller ScanCheck -Mode $ExecutionContext.SessionState.LanguageMode -OutFile $Out -Keys STATE, MESSAGE
    exit 1
}

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
foreach ($lib in 'Settings', 'Log', 'KeyValueFile') { . (Join-Path $app "lib\$lib.ps1") }
[void](Initialize-VlcLog 'ScanCheck')

$o = [ordered]@{ STATE = 'ERROR'; MESSAGE = '' }
try {
    if (-not (Test-Path -LiteralPath $Stl -PathType Leaf)) { throw "The scan $Stl was not found." }
    $hash = (Get-FileHash -LiteralPath $Stl -Algorithm SHA256).Hash.ToLower()
    if ($hash -ne $Sha256.Trim().ToLower()) { throw "The STL is not the one that was scanned (SHA-256 $hash, expected $Sha256)." }
    $o.STATE = 'OK'
}
catch {
    $o.MESSAGE = $_.Exception.Message
    Write-VlcLog "ERROR: $($o.MESSAGE)"
}
Write-KeyValueFile $Out $o
