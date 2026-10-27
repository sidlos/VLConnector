# Status check of this PC for the chosen scenario and role (Setup page, diagnostics ZIP).
# Dot-source this file; it needs lib\Settings.ps1, lib\PolyWorksSetup.ps1 and lib\Share.ps1.
# Each item: Id, Level (Ok, Warning, Error), Title, Detail, Action (button text, empty = no button).

function New-VlcStatusItem([string]$Id, [string]$Level, [string]$Title, [string]$Detail, [string]$Action = '') {
    return [pscustomobject]@{ Id = $Id; Level = $Level; Title = $Title; Detail = $Detail; Action = $Action }
}

function Get-VlcStatusItems($Settings) {
    $items = New-Object Collections.Generic.List[object]
    $network = $Settings.scenario -eq 'Network'
    $station = $network -and $Settings.role -eq 'Station'
    $needsVl = -not $station
    $needsPolyWorks = (-not $network) -or $station

    if ($needsVl) {
        $exe = [string]$Settings.vl.exe
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
            $tested = @($Settings.vl.testedVersions) -contains $version
            if ($tested) { $items.Add((New-VlcStatusItem 'vl' 'Ok' "VL Application $version" (Split-Path $exe))) }
            else { $items.Add((New-VlcStatusItem 'vl' 'Warning' "VL Application $version" 'This VL version has not been tested with VL Connector. Run one test scan before production use.')) }
        }
        else { $items.Add((New-VlcStatusItem 'vl' 'Error' 'VL Application not found' "Expected: $exe" 'Locate')) }
    }

    if ($needsPolyWorks) {
        $pw = Get-PolyWorksInfo
        if ($pw) {
            $items.Add((New-VlcStatusItem 'pw' 'Ok' "$($pw.Name) (Inspector $($pw.InspectorVersion))" $pw.Dir))
            if (Test-VlcReportLayouts) { $items.Add((New-VlcStatusItem 'layouts' 'Ok' 'Report layouts' 'Built from your PolyWorks A4 layout.')) }
            else { $items.Add((New-VlcStatusItem 'layouts' 'Warning' 'Report layouts missing' 'Reports use the plain PolyWorks layout until the VL Connector layouts are built.' 'Build')) }
        }
        else { $items.Add((New-VlcStatusItem 'pw' 'Error' 'PolyWorks not found' 'PolyWorks Metrology Suite must be installed on this PC for this scenario.')) }
    }

    $mode = $ExecutionContext.SessionState.LanguageMode
    if ($mode -eq 'FullLanguage') { $items.Add((New-VlcStatusItem 'ps' 'Ok' 'PowerShell full language mode' 'Scripts can use the Windows and PolyWorks interfaces.')) }
    else { $items.Add((New-VlcStatusItem 'ps' 'Error' "PowerShell runs in $mode" 'VL Connector needs FullLanguage mode. Ask IT (see Notes for IT).')) }

    if ($station) {
        if (Test-Path -LiteralPath (Get-VlcButtonStubPath 'Station')) { $items.Add((New-VlcStatusItem 'button' 'Ok' 'Station button file ready' 'Import it once into the PolyWorks|Inspector of the station (page PolyWorks).' 'Show me how')) }
        else { $items.Add((New-VlcStatusItem 'button' 'Warning' 'Station button not set up' 'Create the station button file and import it into PolyWorks.' 'Show me how')) }
    }
    if (-not $network) {
        if (Test-Path -LiteralPath (Get-VlcButtonStubPath)) { $items.Add((New-VlcStatusItem 'button' 'Ok' 'Measure button file ready' 'Import it once into PolyWorks (page PolyWorks).' 'Show me how')) }
        else { $items.Add((New-VlcStatusItem 'button' 'Warning' 'Measure button not set up' 'Create the button file and import it into PolyWorks.' 'Show me how')) }
    }
    else {
        $share = [string]$Settings.network.share
        if (-not $share) { $items.Add((New-VlcStatusItem 'share' 'Warning' 'Shared folder not set' 'Enter the network folder on the Network page.' 'Set up')) }
        else {
            $test = Test-VlcShare $share
            $level = if ($test.Ok) { 'Ok' } else { 'Error' }
            $items.Add((New-VlcStatusItem 'share' $level "Shared folder $share" $test.Text $(if ($test.Ok) { '' } else { 'Set up' })))
            if ($test.Ok) {
                $parts = @(Get-VlcParts $share)
                if ($parts.Count) { $items.Add((New-VlcStatusItem 'parts' 'Ok' "$($parts.Count) part(s) in the parts list" (($parts | Select-Object -First 4 | ForEach-Object Part) -join ', '))) }
                else { $items.Add((New-VlcStatusItem 'parts' 'Warning' 'Parts list is empty' 'Add the parts on the Network page.' 'Edit list')) }
            }
        }
    }
    return $items.ToArray()
}
