<#
  Get-MacroContext.ps1 - VL Connector for PolyWorks: gives the Measure button macro (VLC_Measure.pwmacro)
  what a macro cannot read by itself: the run time stamp, the operator, the VL Connector settings and the
  folders for scans, reports and report layouts.

  Writes KEY=value lines in this fixed order (the macro reads them by line number, see docs\Protocol.md):
     1 STATE        OK or ERROR
     2 RUN          time stamp of this run, yyyyMMdd_HHmmss (part of the piece name)
     3 USER         operator name for the report
     4 UTC          start time, UTC (piece date in the report)
     5 REPORTS_DIR  folder for PDF and CSV (setting, otherwise <workspace folder>\Reports)
     6 SCANS_DIR    folder for the STL files (setting, otherwise <workspace folder>\Scans)
     7 LAYOUT_DIR   folder with VL_Report_OK.ezl and VL_Report_NOK.ezl, empty when they are missing
     8 KEEP_PIECES  All, Nok or None
     9 OPEN_PDF     1 or 0
    10 COLOR_SCALE  color map range in mm
    11 DEVICE       device text for the report
    12 VERSION      VL Connector version
    13 MESSAGE      error text when STATE=ERROR
  Usage (from the macro): powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File Get-MacroContext.ps1
                          -Out <file> -Pwk <workspace file>
#>
param(
    [Parameter(Mandatory = $true)] [string]$Out,
    [string]$Pwk = ''
)

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
. (Join-Path $app 'lib\Settings.ps1')
. (Join-Path $app 'lib\KeyValueFile.ps1')

$now = Get-Date
$ctx = [ordered]@{
    STATE = 'OK'; RUN = $now.ToString('yyyyMMdd_HHmmss'); USER = $env:USERNAME
    UTC = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    REPORTS_DIR = ''; SCANS_DIR = ''; LAYOUT_DIR = ''; KEEP_PIECES = 'All'; OPEN_PDF = '1'; COLOR_SCALE = '0.5'
    DEVICE = ''; VERSION = (Get-VlcVersion); MESSAGE = ''
}
try {
    $cfg = Read-VlcSettings
    $pw = $cfg.polyworks
    $base = if ($Pwk) { Split-Path $Pwk } else { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'VL Connector' }
    $ctx.REPORTS_DIR = if ($pw.reportsFolder) { [string]$pw.reportsFolder } else { Join-Path $base 'Reports' }
    $ctx.SCANS_DIR = if ($pw.scansFolder) { [string]$pw.scansFolder } else { Join-Path $base 'Scans' }
    $layouts = (Get-VlcPaths).LayoutDir
    if ((Test-Path -LiteralPath (Join-Path $layouts 'VL_Report_OK.ezl')) -and (Test-Path -LiteralPath (Join-Path $layouts 'VL_Report_NOK.ezl'))) {
        $ctx.LAYOUT_DIR = $layouts
    }
    $keep = [string]$pw.keepPieces
    if ('All', 'Nok', 'None' -notcontains $keep) { throw "polyworks.keepPieces '$keep' is not valid (use All, Nok, None)." }
    $ctx.KEEP_PIECES = (Get-Culture).TextInfo.ToTitleCase($keep.ToLower())
    $ctx.OPEN_PDF = if ($pw.openPdf) { '1' } else { '0' }
    $scale = [double]$pw.colorScaleMm
    if ($scale -le 0 -or $scale -gt 100) { throw "polyworks.colorScaleMm $scale is not valid." }
    $ctx.COLOR_SCALE = $scale.ToString([Globalization.CultureInfo]::InvariantCulture)
    $ctx.DEVICE = [string]$pw.deviceText
    if ($pw.operatorName) { $ctx.USER = [string]$pw.operatorName }
    foreach ($dir in $ctx.REPORTS_DIR, $ctx.SCANS_DIR) {
        if ($dir.Contains('=')) { throw "The folder '$dir' contains '=', which the macro cannot read. Choose another folder in the settings." }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}
catch {
    $ctx.STATE = 'ERROR'
    $ctx.MESSAGE = "VL Connector settings: $($_.Exception.Message)"
}
Write-KeyValueFile $Out $ctx
