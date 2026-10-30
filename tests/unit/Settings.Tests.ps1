# Pester 3.4 unit tests: the four settings layers, the schema check, machine-only keys, the administrator's
# policy and the save functions (C23, C74, C39, C45, C56). They run on a copy of lib\Settings.ps1 and the config
# files in a temporary folder, so machine.json (next to app\) never touches the development tree.
$repo = Split-Path (Split-Path $PSScriptRoot)
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-SettingsRoot([string]$Root) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'app\lib'), (Join-Path $Root 'app\config'), (Join-Path $Root 'appdata'), (Join-Path $Root 'local') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'app\lib\Settings.ps1') -Destination (Join-Path $Root 'app\lib')
    Copy-Item -Path (Join-Path $repo 'app\config\*.json') -Destination (Join-Path $Root 'app\config')
    return $Root
}
function Write-Json([string]$Path, [string]$Json) { New-Item -ItemType Directory -Force -Path (Split-Path $Path) | Out-Null; [IO.File]::WriteAllText($Path, $Json) }

$saved = @{ APPDATA = $env:APPDATA; LOCALAPPDATA = $env:LOCALAPPDATA; ProgramData = $env:ProgramData }
$root = New-SettingsRoot (Join-Path ([IO.Path]::GetTempPath()) ('vlc_settings_' + [guid]::NewGuid().ToString('N')))
$env:APPDATA = Join-Path $root 'appdata'
$env:LOCALAPPDATA = Join-Path $root 'local'
. (Join-Path $root 'app\lib\Settings.ps1')
$machineFile = Join-Path $root 'machine.json'
$userFile = Join-Path $env:APPDATA 'VLConnector\settings.json'
function Reset-Files { Remove-Item -LiteralPath $machineFile, $userFile -ErrorAction SilentlyContinue }

Describe 'settings layers' {
    It 'reads machine.json from the program folder only, never from an environment variable' {
        (Get-VlcPaths).MachineFile | Should Be $machineFile
        $env:ProgramData = Join-Path $root 'programdata'
        Write-Json (Join-Path $env:ProgramData 'VLConnector\machine.json') '{ "policy": { "vl": { "confirmStageMotion": true } }, "vl": { "confirmStageMotion": true } }'
        (Read-VlcSettings).vl.confirmStageMotion | Should Be $false
        $env:ProgramData = $saved.ProgramData
    }
    It 'applies product defaults, machine defaults, the user file and the policy in this order' {
        Reset-Files
        Write-Json $machineFile '{ "defaults": { "vl": { "mode": "Standard", "timeoutMin": 30 }, "polyworks": { "keepPieces": "Nok" } }, "policy": { "polyworks": { "keepPieces": "None" } } }'
        Write-Json $userFile '{ "vl": { "mode": "Ask" }, "polyworks": { "keepPieces": "All" } }'
        $s = Get-VlcSettingsState
        $s.Settings.vl.mode | Should Be 'Ask'
        $s.Settings.vl.timeoutMin | Should Be 30
        $s.Settings.vl.settleSec | Should Be 2
        $s.Settings.polyworks.keepPieces | Should Be 'None'
        $s.Locked -join ',' | Should Be 'polyworks.keepPieces'
        $s.Sources['vl.mode'] | Should Be 'user settings'
        $s.Inherited['vl.mode'] | Should Be 'Standard'
        $s.Warnings.Count | Should Be 0
    }
    It 'takes machine-only keys only from the product defaults and the policy' {
        Reset-Files
        Write-Json $userFile '{ "vl": { "confirmStageMotion": true, "exe": "C:\\evil.exe", "dialogRules": [ { "match": "Continue?", "action": "ConfirmStageMotion" } ], "menuExportStl": "File>Exit" }, "safety": { "watchAllowClose": true } }'
        Write-Json $machineFile '{ "defaults": { "vl": { "confirmStageMotion": true } } }'
        $s = Get-VlcSettingsState
        $s.Settings.vl.confirmStageMotion | Should Be $false
        $s.Settings.vl.exe | Should Match 'KEYENCE'
        @($s.Settings.vl.dialogRules).Count | Should Be 3
        $s.Settings.safety.watchAllowClose | Should Be $false
        @($s.Warnings | Where-Object { $_ -match "only the administrator's policy" }).Count | Should Be 6
        Write-Json $machineFile '{ "policy": { "vl": { "confirmStageMotion": true } } }'
        (Read-VlcSettings).vl.confirmStageMotion | Should Be $true
    }
    It 'checks every value: JSON types are taken literally, ranges and names are enforced' {
        Reset-Files
        Write-Json $machineFile '{ "policy": { "vl": { "confirmStageMotion": "true" } } }'
        Write-Json $userFile '{ "vl": { "timeoutMin": "5", "settleSec": 99, "mode": "standard", "returnFocus": 1, "afterExport": "", "programFolders": "C:\\x" }, "network": { "pollSec": 2.5 }, "polyworks": { "colorScaleMm": 0.25 }, "extra": 1 }'
        $s = Get-VlcSettingsState
        $s.Settings.vl.confirmStageMotion | Should Be $false
        $s.Settings.vl.timeoutMin | Should Be 45
        $s.Settings.vl.settleSec | Should Be 2
        $s.Settings.vl.mode | Should Be 'Standard'
        $s.Settings.vl.returnFocus | Should Be $true
        $s.Settings.vl.afterExport | Should Be 'None'
        @($s.Settings.vl.programFolders).Count | Should Be 0
        $s.Settings.network.pollSec | Should Be 3
        $s.Settings.polyworks.colorScaleMm | Should Be 0.25
        $text = $s.Warnings -join "`n"
        $text | Should Match "'vl.confirmStageMotion' in the machine policy must be true or false"
        $text | Should Match "'vl.timeoutMin' in the user settings must be a whole number"
        $text | Should Match "'vl.settleSec' in the user settings must be at most 60"
        $text | Should Match "'vl.afterExport' in the user settings must be one of"
        $text | Should Match "'network.pollSec' in the user settings must be a whole number"
        $text | Should Match "Unknown setting 'extra' in the user settings"
    }
    It 'keeps working when a file is not valid JSON' {
        Reset-Files
        Write-Json $userFile '{ "vl": '
        Write-Json $machineFile '[ 1, 2 ]'
        $s = Get-VlcSettingsState
        $s.Settings.vl.mode | Should Be 'HighSpeed'
        ($s.Warnings -join "`n") | Should Match 'Your settings .* cannot be read'
        ($s.Warnings -join "`n") | Should Match 'is not a JSON object'
    }
}

Describe 'saving user settings' {
    It 'saves a changed value and removes one that equals the inherited value' {
        Reset-Files
        Write-Json $machineFile '{ "defaults": { "vl": { "mode": "Standard" } } }'
        @(Set-VlcUserSettings -Set @{ 'vl.mode' = 'Ask'; 'vl.exportImmediately' = $false }).Count | Should Be 2
        (Read-JsonFile $userFile).vl.mode | Should Be 'Ask'
        @(Set-VlcUserSettings -Set @{ 'vl.mode' = 'Standard' }).Count | Should Be 1
        (Read-JsonFile $userFile).vl.PSObject.Properties['mode'] | Should Be $null
        @(Set-VlcUserSettings -Set @{ 'vl.exportImmediately' = $false }).Count | Should Be 0
        @(Set-VlcUserSettings -Remove 'vl.exportImmediately').Count | Should Be 1
        (Read-JsonFile $userFile).PSObject.Properties['vl'] | Should Be $null
        Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA "VLConnector\logs\Settings_$(Get-Date -Format yyyyMMdd).log") -Raw | Should Match 'user settings: vl.mode = "Ask"'
    }
    It 'refuses machine-only keys, locked keys, unknown keys and invalid values' {
        Reset-Files
        Write-Json $machineFile '{ "policy": { "network": { "autoOpenReports": false } } }'
        { Set-VlcUserSettings -Set @{ 'vl.confirmStageMotion' = $true } } | Should Throw 'can only be set by the administrator'
        { Set-VlcUserSettings -Set @{ 'vl.exe' = 'C:\x.exe' } } | Should Throw 'can only be set by the administrator'
        { Set-VlcUserSettings -Set @{ 'network.autoOpenReports' = $true } } | Should Throw 'is set by the administrator'
        { Set-VlcUserSettings -Set @{ 'vl.bogus' = 1 } } | Should Throw 'Unknown setting'
        { Set-VlcUserSettings -Set @{ 'vl.afterExport' = '' } } | Should Throw 'must be one of'
        { Set-VlcUserSettings -Set @{ 'vl.exportImmediately' = 'false' } } | Should Throw 'must be true or false'
        Test-Path -LiteralPath $userFile | Should Be $false
    }
    It 'keeps both changes when two processes save at the same time' {
        Reset-Files
        $child = "`$env:APPDATA = '$env:APPDATA'; `$env:LOCALAPPDATA = '$env:LOCALAPPDATA'; . '$root\app\lib\Settings.ps1'; " +
            "foreach (`$i in 1..15) { [void](Set-VlcUserSettings -Set @{ 'polyworks.operatorName' = ""op`$i"" }) }"
        $p = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-EncodedCommand', ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))) -PassThru -WindowStyle Hidden
        foreach ($i in 1..15) { [void](Set-VlcUserSettings -Set @{ 'network.stationName' = "st$i" }) }
        $p.WaitForExit(60000) | Should Be $true
        $u = Read-JsonFile $userFile
        $u.polyworks.operatorName | Should Be 'op15'
        $u.network.stationName | Should Be 'st15'
    }
    It 'cleans up a user file written by 1.0.0-rc10' {
        Reset-Files
        Write-Json $userFile '{ "scenario": "Local", "role": "Scanner", "vl": { "mode": "Standard", "exportImmediately": true, "confirmStageMotion": true, "afterExport": "", "timeoutMin": 45, "exe": "C:\\x.exe" }, "polyworks": { "keepPieces": "Nok", "reportLayout": "x" } }'
        $removed = Repair-VlcUserSettings
        ($removed -join ',') | Should Match 'vl.confirmStageMotion \(only the administrator'
        ($removed -join ',') | Should Match 'vl.afterExport \(invalid value\)'
        ($removed -join ',') | Should Match 'polyworks.reportLayout \(unknown\)'
        ($removed -join ',') | Should Match 'scenario \(same as the default\)'
        $u = Read-JsonFile $userFile
        $u.vl.mode | Should Be 'Standard'
        $u.polyworks.keepPieces | Should Be 'Nok'
        @($u.vl.PSObject.Properties).Count | Should Be 1
        @(Repair-VlcUserSettings).Count | Should Be 0
        (Get-VlcSettingsState).Warnings.Count | Should Be 0
    }
    It 'keeps a user file that is not valid JSON as settings.json.bad' {
        Reset-Files
        Write-Json $userFile '{ broken'
        @(Repair-VlcUserSettings).Count | Should Be 1
        Test-Path -LiteralPath "$userFile.bad" | Should Be $true
        Test-Path -LiteralPath $userFile | Should Be $false
        Remove-Item -LiteralPath "$userFile.bad"
    }
}

Describe 'machine settings of the administrator' {
    It 'writes the policy and the machine defaults, machine-only keys only into the policy' {
        Reset-Files
        @(Set-VlcMachineSettings -Section policy -Set @{ 'vl.confirmStageMotion' = $true; 'safety.stageWarningSec' = 6 } -RequestedBy 'operator').Count | Should Be 2
        @(Set-VlcMachineSettings -Section defaults -Set @{ 'vl.mode' = 'Standard' }).Count | Should Be 1
        { Set-VlcMachineSettings -Section defaults -Set @{ 'vl.confirmStageMotion' = $true } } | Should Throw 'only be set in the policy'
        { Set-VlcMachineSettings -Section policy -Set @{ 'vl.confirmStageMotion' = 'yes' } } | Should Throw 'must be true or false'
        $s = Get-VlcSettingsState
        $s.Settings.vl.confirmStageMotion | Should Be $true
        $s.Settings.safety.stageWarningSec | Should Be 6
        $s.Settings.vl.mode | Should Be 'Standard'
        ($s.Locked -join ',') | Should Be 'vl.confirmStageMotion,safety.stageWarningSec'
        @(Set-VlcMachineSettings -Section policy -Set @{ 'vl.confirmStageMotion' = $true }).Count | Should Be 0
        @(Set-VlcMachineSettings -Section policy -Remove 'vl.confirmStageMotion').Count | Should Be 1
        (Read-VlcSettings).vl.confirmStageMotion | Should Be $false
        Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA "VLConnector\logs\Settings_$(Get-Date -Format yyyyMMdd).log") -Raw | Should Match 'machine policy for .* changed by .* \(requested in the session of operator\): .*vl.confirmStageMotion = true \(was not set\)'
    }
}

Describe 'Set-MachinePolicy.ps1' {
    It 'writes the policy only with administrator rights' {
        Reset-Files
        foreach ($f in 'Set-MachinePolicy.ps1') { Copy-Item -LiteralPath (Join-Path $repo "app\$f") -Destination (Join-Path $root 'app') }
        foreach ($f in 'Log.ps1', 'LanguageCheck.ps1') { Copy-Item -LiteralPath (Join-Path $repo "app\lib\$f") -Destination (Join-Path $root 'app\lib') }
        $code = "`$env:LOCALAPPDATA = '$env:LOCALAPPDATA'; & '$root\app\Set-MachinePolicy.ps1' -ConfirmStageMotion On -RequestedBy test; exit `$LASTEXITCODE"
        $out = & $ps -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) 2>&1 | Out-String
        $elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated) {
            $LASTEXITCODE | Should Be 0
            (Read-VlcSettings).vl.confirmStageMotion | Should Be $true
        }
        else {
            $LASTEXITCODE | Should Be 5
            $out | Should Match 'Administrator rights are needed'
            Test-Path -LiteralPath $machineFile | Should Be $false
        }
    }
}

foreach ($k in $saved.Keys) { Set-Item "env:$k" $saved[$k] }
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
