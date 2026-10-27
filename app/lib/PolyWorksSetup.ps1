# PolyWorks side of the setup: finds PolyWorks, writes the Measure button stub, checks the report layouts.
# Dot-source this file (it has no param block); it needs lib\Settings.ps1.

# The PolyWorks installation (folder and version) from the COM registration of the Workspace Manager.
function Get-PolyWorksInfo {
    $clsid = (Get-ItemProperty -LiteralPath 'Registry::HKEY_CLASSES_ROOT\InnovMetric.PolyWorks.WorkspaceManager\CLSID' -ErrorAction SilentlyContinue).'(default)'
    if (-not $clsid) { return $null }
    $server = (Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\CLSID\$clsid\LocalServer32" -ErrorAction SilentlyContinue).'(default)'
    if (-not $server) { return $null }
    $exe = if ($server -match '^"([^"]+)"') { $Matches[1] } else { ($server -split ' ')[0] }
    $dir = Split-Path (Split-Path $exe)
    $inspector = Join-Path $dir 'bin\iminspect.exe'
    $version = ''
    if (Test-Path -LiteralPath $inspector) {
        $vi = (Get-Item -LiteralPath $inspector).VersionInfo
        $version = '{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart
    }
    return [pscustomobject]@{ Dir = $dir; Name = Split-Path $dir -Leaf; InspectorVersion = $version }
}

# The button stubs that the operator imports into PolyWorks once (File > Visual Layout > Customize, Macro
# Scripts): VLC_Measure_Button (scenario A) and VLC_Station_Button (PolyWorks station of the network
# scenario). They only call the installed macro, so updates of VL Connector need no new import.
function Get-VlcButtonStubPath([string]$Kind = 'Measure') { return Join-Path (Get-VlcPaths).InstallDir "VLC_${Kind}_Button.pwmacro" }

function New-VlcButtonStub([string]$Path = '', [ValidateSet('Measure', 'Station')] [string]$Kind = 'Measure') {
    if (-not $Path) { $Path = Get-VlcButtonStubPath $Kind }
    $app = (Get-VlcPaths).AppDir
    if ($app.Contains('"')) { throw "The VL Connector folder '$app' cannot be used in a macro." }
    $what = @{ Measure = 'Measure button'; Station = 'Station button (PolyWorks station of the network scenario)' }[$Kind]
    $text = @"
version "7.0"
# VL Connector for PolyWorks - $what. Import this file once into PolyWorks:
#   File > Visual Layout > Customize > Customize, tab Macro Scripts > Import, then add it to the ribbon
#   or the Quick Access Toolbar (icon: $app\assets\VLC_icon_32.png).
# It runs the installed macro, so an update of VL Connector needs no new import.
# Created by VL Connector $(Get-VlcVersion) for the folder $app
MACRO EXEC ( "$app\polyworks\VLC_$Kind.pwmacro", "$app" )
"@
    [IO.File]::WriteAllText($Path, ($text -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($true)))
    return $Path
}

function Test-VlcReportLayouts {
    $dir = (Get-VlcPaths).LayoutDir
    return (Test-Path -LiteralPath (Join-Path $dir 'VL_Report_OK.ezl')) -and (Test-Path -LiteralPath (Join-Path $dir 'VL_Report_NOK.ezl'))
}
