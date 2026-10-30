# Settings and paths of VL Connector. Dot-source this file (it has no param block).
#
# Settings come in four layers; a later layer overrides single values of an earlier one:
#   1. app\config\defaults.json                  shipped with the product
#   2. machine.json, section "defaults"          starting values of IT for all users of this PC; users may change them
#   3. %APPDATA%\VLConnector\settings.json       the user's own changes (settings window, setup wizard)
#   4. machine.json, section "policy"            values IT locked for all users of this PC, applied last
# machine.json lies in the program folder next to app\, which only administrators can change; its place never
# comes from an environment variable. Every value is checked against app\config\settings-schema.json: a value of
# the wrong type or out of range, an unknown key, or a machine-only key outside defaults.json and the policy is
# ignored with a warning (the layer below then applies). The warnings appear on the Setup page and in the logs.

$script:VlcAppDir = Split-Path $PSScriptRoot
$script:VlcSchema = $null

function Get-VlcPaths {
    $data = Join-Path $env:LOCALAPPDATA 'VLConnector'
    $install = Split-Path $script:VlcAppDir
    return [pscustomobject]@{
        AppDir      = $script:VlcAppDir
        InstallDir  = $install
        Defaults    = Join-Path $script:VlcAppDir 'config\defaults.json'
        Schema      = Join-Path $script:VlcAppDir 'config\settings-schema.json'
        MachineFile = Join-Path $install 'machine.json'
        UserFile    = Join-Path $env:APPDATA 'VLConnector\settings.json'
        DataDir     = $data
        LogDir      = Join-Path $data 'logs'
        # an installed copy (the installer writes install-info.txt); otherwise a development tree
        Installed   = Test-Path -LiteralPath (Join-Path $install 'install-info.txt')
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

# Writes a settings file in one step: a temporary file next to it replaces the old one (UTF-8 without BOM).
function Write-JsonFile([string]$Path, $Object) {
    New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($Object | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

# The schema as an ordered dictionary 'section.key' -> definition (type, min, max, values, machineOnly, ...).
function Get-VlcSettingsSchema {
    if (-not $script:VlcSchema) {
        $raw = Read-JsonFile (Get-VlcPaths).Schema
        if (-not $raw) { throw "The settings schema is missing: $((Get-VlcPaths).Schema)" }
        $schema = [ordered]@{}
        foreach ($p in $raw.settings.PSObject.Properties) { $schema[$p.Name] = $p.Value }
        $script:VlcSchema = $schema
    }
    return $script:VlcSchema
}

# Checks one value against its definition. Returns Ok, the value in its canonical form (Value) or the reason (Error).
# JSON types are taken literally: "true" in quotes is text, not a switch, and 5 in quotes is not a number.
function Test-VlcSettingValue($Definition, $Value) {
    $bad = { param([string]$Why) [pscustomobject]@{ Ok = $false; Value = $null; Error = $Why } }
    $good = { param($V) [pscustomobject]@{ Ok = $true; Value = $V; Error = '' } }
    $isNumber = $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double] -or $Value -is [single]
    $range = {
        param([double]$N)
        if ($null -ne $Definition.min -and $N -lt [double]$Definition.min) { return "must be at least $($Definition.min)" }
        if ($null -ne $Definition.max -and $N -gt [double]$Definition.max) { return "must be at most $($Definition.max)" }
        return ''
    }
    $text = {
        param($V, [int]$Max)
        if ($V -isnot [string]) { return 'must be text' }
        if ($V.Length -gt $Max) { return "must be at most $Max characters long" }
        if ($V -match '[\x00-\x1f]') { return 'must be one line of text' }
        return ''
    }
    switch ([string]$Definition.type) {
        'bool' {
            if ($Value -is [bool]) { return & $good $Value }
            return & $bad 'must be true or false (without quotes)'
        }
        'int' {
            if (-not $isNumber -or [math]::Floor([double]$Value) -ne [double]$Value) { return & $bad 'must be a whole number (without quotes)' }
            $why = & $range ([double]$Value)
            if ($why) { return & $bad $why }
            return & $good ([int]$Value)
        }
        'number' {
            if (-not $isNumber) { return & $bad 'must be a number (without quotes)' }
            $why = & $range ([double]$Value)
            if ($why) { return & $bad $why }
            return & $good ([double]$Value)
        }
        'enum' {
            $match = @(if ($Value -is [string]) { $Definition.values | Where-Object { $_ -eq $Value } })
            if (-not $match.Count) { return & $bad "must be one of: $(@($Definition.values) -join ', ')" }
            return & $good ([string]$match[0])
        }
        { $_ -in 'string', 'path', 'menu' } {
            $max = if ($Definition.maxLength) { [int]$Definition.maxLength } else { 1024 }
            $why = & $text $Value $max
            if ($why) { return & $bad $why }
            if ($_ -eq 'menu' -and $Value -notmatch '^File>[^>]+(>[^>]+)*$') { return & $bad "must be a path in VL's File menu, e.g. File>Export>STL" }
            return & $good ([string]$Value).Trim()
        }
        { $_ -in 'pathList', 'stringList' } {
            if ($null -eq $Value) { return & $good ([string[]]@()) }
            if ($Value -isnot [array]) { return & $bad 'must be a list ([ ... ])' }
            foreach ($item in $Value) { $why = & $text $item 1024; if ($why) { return & $bad "every entry $why" } }
            return & $good ([string[]]@($Value | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
        }
        'dialogRules' {
            if ($Value -isnot [array]) { return & $bad 'must be a list of { "match": ..., "action": ... }' }
            $rules = foreach ($rule in $Value) {
                if ($rule -isnot [System.Management.Automation.PSCustomObject]) { return & $bad 'every rule must be { "match": ..., "action": ... }' }
                $why = & $text $rule.match 200
                if ($why -or -not $rule.match.Trim()) { return & $bad "every rule needs a match text$(if ($why) { " that $why" })" }
                $action = @($Definition.actions | Where-Object { $_ -eq $rule.action })
                if (-not $action.Count) { return & $bad "the action of a rule must be one of: $(@($Definition.actions) -join ', ')" }
                [pscustomobject]@{ match = $rule.match.Trim(); action = [string]$action[0] }
            }
            return & $good @($rules)
        }
        default { return & $bad "has an unknown type '$($Definition.type)' in the schema" }
    }
}

# 'section.key' -> value for every schema key in a settings object, plus the keys the schema does not know.
function ConvertTo-VlcFlatSettings($Object, $Schema) {
    $values = [ordered]@{}
    $unknown = New-Object Collections.Generic.List[string]
    $walk = {
        param($Node, [string]$Prefix)
        foreach ($p in $Node.PSObject.Properties) {
            $key = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            $known = @($Schema.Keys | Where-Object { $_ -eq $key })
            if ($known.Count) { $values[$known[0]] = $p.Value }
            elseif ($p.Value -is [System.Management.Automation.PSCustomObject]) { & $walk $p.Value $key }
            else { $unknown.Add($key) }
        }
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) { & $walk $Object '' }
    return [pscustomobject]@{ Values = $values; Unknown = $unknown.ToArray() }
}

function ConvertFrom-VlcFlatSettings($Flat) {
    $root = [pscustomobject]@{}
    foreach ($key in $Flat.Keys) {
        $parts = $key -split '\.'
        $node = $root
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            if (-not $node.PSObject.Properties[$parts[$i]]) { $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{}) }
            $node = $node.PSObject.Properties[$parts[$i]].Value
        }
        $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Flat[$key]
    }
    return $root
}

# All four layers, checked. Settings: the effective settings object. Values: the same as 'section.key' -> value.
# Inherited: what a user gets without an own value (product and machine defaults). Locked: keys set by the policy.
# Sources: the layer each value comes from. Warnings: everything that was ignored, and why.
function Get-VlcSettingsState {
    $paths = Get-VlcPaths
    $schema = Get-VlcSettingsSchema
    $warnings = New-Object Collections.Generic.List[string]
    $product = Read-JsonFile $paths.Defaults
    if (-not $product) { throw "Default settings missing: $($paths.Defaults)" }
    $machine = $null
    try { $machine = Read-JsonFile $paths.MachineFile } catch { $warnings.Add("The settings of the administrator ($($paths.MachineFile)) cannot be read: $($_.Exception.Message)") }
    if ($null -ne $machine) {
        if ($machine -isnot [System.Management.Automation.PSCustomObject]) { $warnings.Add("$($paths.MachineFile) is not a JSON object; ignored."); $machine = $null }
        else {
            foreach ($p in $machine.PSObject.Properties) {
                if ($p.Name -notin 'defaults', 'policy') { $warnings.Add("$($paths.MachineFile): only the sections 'defaults' and 'policy' are read; '$($p.Name)' is ignored.") }
            }
        }
    }
    $user = $null
    try { $user = Read-JsonFile $paths.UserFile } catch { $warnings.Add("Your settings ($($paths.UserFile)) cannot be read: $($_.Exception.Message) VL Connector uses the other settings.") }

    $layers = @(
        @{ Name = 'product defaults'; Object = $product; MachineOnly = $true }
        @{ Name = 'machine defaults'; Object = $(if ($machine) { $machine.defaults }); MachineOnly = $false }
        @{ Name = 'user settings'; Object = $user; MachineOnly = $false }
        @{ Name = 'machine policy'; Object = $(if ($machine) { $machine.policy }); MachineOnly = $true })
    $effective = @{}
    $sources = @{}
    $inherited = [ordered]@{}
    for ($i = 0; $i -lt $layers.Count; $i++) {
        $layer = $layers[$i]
        if ($i -eq 2) { foreach ($key in $schema.Keys) { if ($effective.ContainsKey($key)) { $inherited[$key] = $effective[$key] } } }
        if ($null -eq $layer.Object) { continue }
        if ($layer.Object -isnot [System.Management.Automation.PSCustomObject]) { $warnings.Add("The $($layer.Name) are not a JSON object; ignored."); continue }
        $flat = ConvertTo-VlcFlatSettings $layer.Object $schema
        foreach ($u in $flat.Unknown) { $warnings.Add("Unknown setting '$u' in the $($layer.Name); ignored.") }
        foreach ($key in $flat.Values.Keys) {
            if ($schema[$key].machineOnly -and -not $layer.MachineOnly) {
                $warnings.Add("'$key' in the $($layer.Name) is ignored: only the administrator's policy for this PC can set it.")
                continue
            }
            $r = Test-VlcSettingValue $schema[$key] $flat.Values[$key]
            if (-not $r.Ok) { $warnings.Add("'$key' in the $($layer.Name) $($r.Error); ignored."); continue }
            $effective[$key] = $r.Value
            $sources[$key] = $layer.Name
        }
    }
    $values = [ordered]@{}
    foreach ($key in $schema.Keys) {
        if ($effective.ContainsKey($key)) { $values[$key] = $effective[$key] }
        else { $warnings.Add("'$key' has no value in $($paths.Defaults).") }
    }
    return [pscustomobject]@{
        Settings = ConvertFrom-VlcFlatSettings $values; Values = $values; Inherited = $inherited
        Locked = [string[]]@($schema.Keys | Where-Object { $sources[$_] -eq 'machine policy' }); Sources = $sources; Warnings = $warnings.ToArray()
    }
}

function Read-VlcSettings { return (Get-VlcSettingsState).Settings }

function Test-VlcSameValue($A, $B) { return (ConvertTo-Json $A -Compress -Depth 5) -ceq (ConvertTo-Json $B -Compress -Depth 5) }

function Set-VlcJsonValue($Root, [string]$Key, $Value) {
    $parts = $Key -split '\.'
    $node = $Root
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $next = $node.PSObject.Properties[$parts[$i]]
        if (-not $next -or $next.Value -isnot [System.Management.Automation.PSCustomObject]) {
            if ($next) { $node.PSObject.Properties.Remove($parts[$i]) }
            $node | Add-Member -NotePropertyName $parts[$i] -NotePropertyValue ([pscustomobject]@{})
            $next = $node.PSObject.Properties[$parts[$i]]
        }
        $node = $next.Value
    }
    if ($node.PSObject.Properties[$parts[-1]]) { $node.PSObject.Properties.Remove($parts[-1]) }
    $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value
}

# Removes a key; sections that become empty are removed too.
function Remove-VlcJsonValue($Root, [string]$Key) {
    $parts = $Key -split '\.'
    $chain = @($Root)
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $next = $chain[-1].PSObject.Properties[$parts[$i]]
        if (-not $next -or $next.Value -isnot [System.Management.Automation.PSCustomObject]) { return }
        $chain += $next.Value
    }
    $chain[-1].PSObject.Properties.Remove($parts[-1])
    for ($i = $parts.Count - 2; $i -ge 0; $i--) {
        if (@($chain[$i + 1].PSObject.Properties).Count) { break }
        $chain[$i].PSObject.Properties.Remove($parts[$i])
    }
}

function Use-VlcLock([string]$Name, [scriptblock]$Work) {
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'The settings are being changed by another VL Connector window; try again.' }
        & $Work
    }
    finally { if ($owned) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
}

# Changes the user's own settings: Set-VlcUserSettings -Set @{ 'vl.mode' = 'Standard' } -Remove 'vl.afterExport'.
# Values are checked against the schema; machine-only keys and keys locked by the administrator's policy are
# refused. A value equal to what the user would get without it (product and machine defaults) is removed, so
# later changes by IT reach the user. Read, change and write run under a lock, the file is replaced in one
# step, and every change is written to the log. Returns the changes as text.
function Set-VlcUserSettings([hashtable]$Set = @{}, [string[]]$Remove = @()) {
    $schema = Get-VlcSettingsSchema
    $state = Get-VlcSettingsState
    $values = @{}
    foreach ($key in @(@($Set.Keys) + $Remove)) {
        if (-not $schema.Contains($key)) { throw "Unknown setting '$key'." }
        if ($schema[$key].machineOnly) { throw "'$key' can only be set by the administrator for this PC." }
        if ($state.Locked -contains $key) { throw "'$key' is set by the administrator for this PC." }
    }
    foreach ($key in $Set.Keys) {
        $r = Test-VlcSettingValue $schema[$key] $Set[$key]
        if (-not $r.Ok) { throw "'$key' $($r.Error)." }
        $values[$key] = $r.Value
    }
    $paths = Get-VlcPaths
    $changes = New-Object Collections.Generic.List[string]
    Use-VlcLock 'Local\VLConnector_UserSettings' {
        $user = Read-JsonFile $paths.UserFile
        if ($user -isnot [System.Management.Automation.PSCustomObject]) { $user = [pscustomobject]@{} }
        $own = (ConvertTo-VlcFlatSettings $user $schema).Values
        foreach ($key in $values.Keys) {
            $new = $values[$key]
            if ($state.Inherited.Contains($key) -and (Test-VlcSameValue $new $state.Inherited[$key])) {
                if ($own.Contains($key)) { Remove-VlcJsonValue $user $key; $changes.Add("$key = $(ConvertTo-Json $new -Compress) (back to the default)") }
            }
            elseif (-not ($own.Contains($key) -and (Test-VlcSameValue $new $own[$key]))) {
                Set-VlcJsonValue $user $key $new
                $changes.Add("$key = $(ConvertTo-Json $new -Compress)")
            }
        }
        foreach ($key in $Remove) {
            if ($own.Contains($key)) { Remove-VlcJsonValue $user $key; $changes.Add("$key removed") }
        }
        if ($changes.Count) { Write-JsonFile $paths.UserFile $user }
    }
    foreach ($c in $changes) { Write-VlcSettingsAudit "user settings: $c" }
    return $changes.ToArray()
}

# One-time cleanup of a user file of VL Connector up to 1.0.0-rc10, which stored every effective value, including
# machine-only keys such as vl.confirmStageMotion. Removed: unknown keys, machine-only keys, invalid values, keys
# locked by the policy and values equal to the inherited ones. A file that is not valid JSON is kept as
# settings.json.bad. Returns what was removed.
function Repair-VlcUserSettings {
    $paths = Get-VlcPaths
    if (-not (Test-Path -LiteralPath $paths.UserFile)) { return @() }
    $schema = Get-VlcSettingsSchema
    $removed = New-Object Collections.Generic.List[string]
    Use-VlcLock 'Local\VLConnector_UserSettings' {
        $user = $null
        try { $user = Read-JsonFile $paths.UserFile } catch { }
        if ($user -isnot [System.Management.Automation.PSCustomObject]) {
            Move-Item -LiteralPath $paths.UserFile -Destination "$($paths.UserFile).bad" -Force
            $removed.Add('the whole file (not valid JSON; kept as settings.json.bad)')
            return
        }
        $state = Get-VlcSettingsState
        $flat = ConvertTo-VlcFlatSettings $user $schema
        foreach ($key in $flat.Unknown) { Remove-VlcJsonValue $user $key; $removed.Add("$key (unknown)") }
        foreach ($key in @($flat.Values.Keys)) {
            $value = $flat.Values[$key]
            $reason = if ($schema[$key].machineOnly) { 'only the administrator can set it' }
                elseif (-not (Test-VlcSettingValue $schema[$key] $value).Ok) { 'invalid value' }
                elseif ($state.Locked -contains $key) { 'set by the administrator' }
                elseif ($state.Inherited.Contains($key) -and (Test-VlcSameValue (Test-VlcSettingValue $schema[$key] $value).Value $state.Inherited[$key])) { 'same as the default' }
            if ($reason) { Remove-VlcJsonValue $user $key; $removed.Add("$key ($reason)") }
        }
        if ($removed.Count) { Write-JsonFile $paths.UserFile $user }
    }
    if ($removed.Count) { Write-VlcSettingsAudit "user settings cleaned up: $($removed -join ', ')" }
    return $removed.ToArray()
}

# Changes machine.json in the program folder (needs administrator rights): the policy (locked for all users) or the
# machine defaults. Values are checked against the schema; machine-only keys go only into the policy. Every change
# goes to the log and to the Windows event log. Returns the changes as text.
function Set-VlcMachineSettings([ValidateSet('policy', 'defaults')] [string]$Section = 'policy', [hashtable]$Set = @{}, [string[]]$Remove = @(), [string]$RequestedBy = '') {
    $schema = Get-VlcSettingsSchema
    $values = @{}
    foreach ($key in @(@($Set.Keys) + $Remove)) { if (-not $schema.Contains($key)) { throw "Unknown setting '$key'." } }
    foreach ($key in $Set.Keys) {
        if ($Section -eq 'defaults' -and $schema[$key].machineOnly) { throw "'$key' can only be set in the policy." }
        $r = Test-VlcSettingValue $schema[$key] $Set[$key]
        if (-not $r.Ok) { throw "'$key' $($r.Error)." }
        $values[$key] = $r.Value
    }
    $paths = Get-VlcPaths
    $changes = New-Object Collections.Generic.List[string]
    Use-VlcLock 'Global\VLConnector_MachineSettings' {
        $machine = Read-JsonFile $paths.MachineFile
        if ($null -eq $machine) { $machine = [pscustomobject]@{} }
        if ($machine -isnot [System.Management.Automation.PSCustomObject]) { throw "$($paths.MachineFile) is not a JSON object. Correct or delete it first." }
        if ($machine.PSObject.Properties[$Section] -and $machine.$Section -isnot [System.Management.Automation.PSCustomObject]) { throw "The section '$Section' of $($paths.MachineFile) is not a JSON object." }
        if (-not $machine.PSObject.Properties[$Section]) { $machine | Add-Member -NotePropertyName $Section -NotePropertyValue ([pscustomobject]@{}) }
        $own = (ConvertTo-VlcFlatSettings $machine.$Section $schema).Values
        foreach ($key in $values.Keys) {
            if ($own.Contains($key) -and (Test-VlcSameValue $values[$key] $own[$key])) { continue }
            $was = if ($own.Contains($key)) { ConvertTo-Json $own[$key] -Compress } else { 'not set' }
            Set-VlcJsonValue $machine.$Section $key $values[$key]
            $changes.Add("$key = $(ConvertTo-Json $values[$key] -Compress) (was $was)")
        }
        foreach ($key in $Remove) { if ($own.Contains($key)) { Remove-VlcJsonValue $machine.$Section $key; $changes.Add("$key removed") } }
        if ($changes.Count) { Write-JsonFile $paths.MachineFile $machine }
    }
    if ($changes.Count) {
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $text = "VL Connector machine $Section for $env:COMPUTERNAME changed by $who$(if ($RequestedBy) { " (requested in the session of $RequestedBy)" }): $($changes -join '; ')"
        Write-VlcSettingsAudit $text
        [void](Write-VlcEventLog $text 1000)
    }
    return $changes.ToArray()
}

# Settings changes go to %LOCALAPPDATA%\VLConnector\logs\Settings_<date>.log (shared write, never fails).
function Write-VlcSettingsAudit([string]$Text) {
    try {
        $dir = (Get-VlcPaths).LogDir
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}: {2}' -f (Get-Date), [Security.Principal.WindowsIdentity]::GetCurrent().Name, $Text
        $fs = [IO.File]::Open((Join-Path $dir ('Settings_{0:yyyyMMdd}.log' -f (Get-Date))), 'Append', 'Write', 'ReadWrite, Delete')
        try { $bytes = [Text.Encoding]::UTF8.GetBytes($line + "`r`n"); $fs.Write($bytes, 0, $bytes.Length) }
        finally { $fs.Dispose() }
    }
    catch { }
}

# Windows event log (Application, source "VL Connector", registered by the installer). Event ids: 1000 machine
# settings changed, 1100 stage rotation confirmed automatically, 1101 automatic confirmation skipped. Returns
# $false when the entry could not be written (source not registered); never throws.
function Write-VlcEventLog([string]$Text, [int]$EventId, [ValidateSet('Information', 'Warning', 'Error')] [string]$Type = 'Information') {
    try { [Diagnostics.EventLog]::WriteEntry('VL Connector', $Text, $Type, $EventId); return $true }
    catch { return $false }
}
