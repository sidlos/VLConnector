# Settings and paths of VL Connector. Dot-source this file (it has no param block).
#
# Settings come in three layers; a later layer overrides single values of an earlier one:
#   1. app\config\defaults.json                      shipped with the product (read-only)
#   2. %ProgramData%\VLConnector\machine.json        optional, for all users of the PC (IT)
#   3. %APPDATA%\VLConnector\settings.json           written by the settings window (per user)

$script:VlcAppDir = Split-Path $PSScriptRoot

function Get-VlcPaths {
    $data = Join-Path $env:LOCALAPPDATA 'VLConnector'
    return [pscustomobject]@{
        AppDir      = $script:VlcAppDir
        InstallDir  = Split-Path $script:VlcAppDir
        Defaults    = Join-Path $script:VlcAppDir 'config\defaults.json'
        MachineFile = Join-Path $env:ProgramData 'VLConnector\machine.json'
        LayoutDir   = Join-Path $env:ProgramData 'VLConnector\layouts'
        UserFile    = Join-Path $env:APPDATA 'VLConnector\settings.json'
        DataDir     = $data
        LogDir      = Join-Path $data 'logs'
    }
}

function Get-VlcVersion {
    $file = Join-Path (Split-Path $script:VlcAppDir) 'VERSION'
    if (Test-Path -LiteralPath $file) { return ([IO.File]::ReadAllText($file)).Trim() }
    return 'dev'
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { throw "Settings file $Path is not valid JSON: $($_.Exception.Message)" }
}

# Copies the values of $Override into $Base: objects are merged key by key, everything else is replaced.
function Merge-Settings($Base, $Override) {
    if ($null -eq $Override) { return $Base }
    foreach ($p in $Override.PSObject.Properties) {
        $current = $Base.PSObject.Properties[$p.Name]
        if ($current -and $current.Value -is [pscustomobject] -and $p.Value -is [pscustomobject]) {
            Merge-Settings $current.Value $p.Value | Out-Null
        }
        elseif ($current) { $current.Value = $p.Value }
        else { $Base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
    }
    return $Base
}

function Read-VlcSettings {
    $paths = Get-VlcPaths
    $settings = Read-JsonFile $paths.Defaults
    if (-not $settings) { throw "Default settings missing: $($paths.Defaults)" }
    $settings = Merge-Settings $settings (Read-JsonFile $paths.MachineFile)
    $settings = Merge-Settings $settings (Read-JsonFile $paths.UserFile)
    return $settings
}

# Saves single values for the current user. $Values: @{ 'vl.mode' = 'Standard'; 'scenario' = 'Network' }
function Save-VlcUserSettings([hashtable]$Values) {
    $paths = Get-VlcPaths
    $user = Read-JsonFile $paths.UserFile
    if (-not $user) { $user = [pscustomobject]@{} }
    foreach ($key in $Values.Keys) {
        $node = $user
        $parts = $key -split '\.'
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $next = $node.PSObject.Properties[$parts[$i]]
            if (-not $next) { $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{}); $next = $node.PSObject.Properties[$parts[$i]] }
            $node = $next.Value
        }
        $leaf = $parts[-1]
        if ($node.PSObject.Properties[$leaf]) { $node.$leaf = $Values[$key] }
        else { $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Values[$key] }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $paths.UserFile) | Out-Null
    $json = $user | ConvertTo-Json -Depth 8
    $temp = "$($paths.UserFile).tmp"
    [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $paths.UserFile) { [IO.File]::Delete($paths.UserFile) }
    [IO.File]::Move($temp, $paths.UserFile)
}
