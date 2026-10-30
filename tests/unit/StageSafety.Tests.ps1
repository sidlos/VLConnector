# Pester 3.4 unit tests: VL Connector answers VL's stage rotation questions only when the administrator's policy
# allows it, and nothing else can switch that on (C38, C39, C25, C76). The FakeVL scenarios safety-*.json test the
# same with the launcher driving a simulated VL.
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
. (Join-Path $app 'lib\KeyValueFile.ps1')

function Invoke-Child([string]$Code, [switch]$Sta) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'`n$Code"))
    $ErrorActionPreference = 'Continue'
    $flags = @('-NoProfile', '-NonInteractive') + $(if ($Sta) { '-STA' } else { '-MTA' })
    $out = & $ps @flags -EncodedCommand $enc 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
}

Describe 'stage questions' {
    . (Join-Path $app 'lib\StageWarning.ps1')
    It 'are only the two exact questions of VL' {
        Test-VlcStageQuestion 'The stage will rotate. Continue?' | Should Be $true
        Test-VlcStageQuestion 'Return the stage to the origin?' | Should Be $true
        Test-VlcStageQuestion 'the stage will rotate. continue?' | Should Be $true
        foreach ($t in 'stage will rotate', 'The stage will rotate. Continue? Check the part.', 'Rotate the stage?', 'Continue?', '') {
            Test-VlcStageQuestion $t | Should Be $false
        }
    }
}

Describe 'who may answer a stage question' {
    # a copy of the settings files, so that machine.json lies in a temporary program folder
    $root = Join-Path $TestDrive 'install'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'app\lib'), (Join-Path $root 'app\config') | Out-Null
    Copy-Item -LiteralPath (Join-Path $app 'lib\Settings.ps1') -Destination (Join-Path $root 'app\lib')
    Copy-Item -Path (Join-Path $app 'config\*.json') -Destination (Join-Path $root 'app\config')
    $machine = Join-Path $root 'machine.json'
    $user = Join-Path $env:APPDATA 'VLConnector\settings.json'
    $vl = [pscustomobject]@{ MainModule = [pscustomobject]@{ FileVersionInfo = [pscustomobject]@{ FileVersion = '4.6.1.6002' } } }
    $untested = [pscustomobject]@{ MainModule = [pscustomobject]@{ FileVersionInfo = [pscustomobject]@{ FileVersion = '9.9.9.9' } } }
    $decide = ". '$root\app\lib\Settings.ps1'; . '$app\lib\Interop.ps1'; Import-VlcInterop; . '$app\lib\StageWarning.ps1'; " +
        "`$p = [pscustomobject]@{ MainModule = [pscustomobject]@{ FileVersionInfo = [pscustomobject]@{ FileVersion = '{0}' } } }; '[' + (Get-VlcStageConfirmBlocker `$p) + ']|[' + (Get-VlcSessionBlocker) + ']'"
    function Get-Decision([string]$Version) {
        $r = Invoke-Child ($decide -replace '\{0\}', $Version)
        $parts = $r.Text.Trim() -split '\|'
        return [pscustomobject]@{ Blocker = $parts[0].Trim('[', ']'); Session = $parts[1].Trim('[', ']'); Text = $r.Text }
    }

    It 'nobody but the operator without the policy, whatever the user, the machine defaults or the files say' {
        New-Item -ItemType Directory -Force -Path (Split-Path $user) | Out-Null
        [IO.File]::WriteAllText($user, '{ "vl": { "confirmStageMotion": true, "testedVersions": [ "9.9.9.9" ] } }')
        [IO.File]::WriteAllText($machine, '{ "defaults": { "vl": { "confirmStageMotion": true } }, "policy": { "vl": { "confirmStageMotion": "true" } } }')
        (Get-Decision '4.6.1.6002').Blocker | Should Be 'off'
        Remove-Item -LiteralPath $user
    }
    It 'VL Connector with the policy, on a tested VL version, when somebody is at the PC' {
        [IO.File]::WriteAllText($machine, '{ "policy": { "vl": { "confirmStageMotion": true } } }')
        $d = Get-Decision '4.6.1.6002'
        $d.Blocker | Should Be $d.Session
        (Get-Decision '9.9.9.9').Blocker | Should Be "VL version '9.9.9.9' is not one of the tested versions"
        (Get-Decision '').Blocker | Should Be "VL version '' is not one of the tested versions"
    }
    It 'stops at once when the policy is switched off' {
        [IO.File]::WriteAllText($machine, '{ "policy": { "vl": { "confirmStageMotion": false } } }')
        (Get-Decision '4.6.1.6002').Blocker | Should Be 'off'
    }
}

Describe 'the launcher refuses every other way to switch it on' {
    $marker = Join-Path $TestDrive 'run.done'
    function Invoke-Launcher([string]$Arguments) {
        Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        return Invoke-Child "& '$app\VLReplay.ps1' $Arguments; exit `$LASTEXITCODE" -Sta
    }
    It 'has no -ConfirmStageMotion, -VlExe, -VlArgs or -Menu parameter' {
        foreach ($p in 'ConfirmStageMotion', 'VlExe', 'VlArgs', 'Menu') {
            $r = Invoke-Launcher "ABC -$p On -MarkerFile '$marker'"
            $r.ExitCode | Should Not Be 0
            # PowerShell refuses the call before the script runs (the console wraps the message, the id is stable)
            $r.Text | Should Match 'NamedParameterNotFound,VLReplay\.ps1'
            Test-Path -LiteralPath $marker | Should Be $false
        }
    }
    It 'refuses -ConfirmStageMotion in the VL options of a template' {
        $r = Invoke-Launcher "ABC -Options '-Mode Standard -ConfirmStageMotion On' -MarkerFile '$marker'"
        $r.ExitCode | Should Be 3
        $m = Read-KeyValueFile $marker
        $m.STATE | Should Be 'ERROR'
        $m.MESSAGE | Should Match 'ConfirmStageMotion is not a template option any more'
    }
    It 'reads the template values from the launch file, where a quote is only a character' {
        $launch = Join-Path $TestDrive 'run.launch'
        [IO.File]::WriteAllLines($launch, [string[]]@('PROGRAM=ABC', 'OPTIONS=-Mode Standard" -ConfirmStageMotion "On'), [Text.Encoding]::Unicode)
        $r = Invoke-Launcher "-LaunchFile '$launch' -MarkerFile '$marker'"
        $r.ExitCode | Should Be 3
        (Read-KeyValueFile $marker).MESSAGE | Should Match 'ConfirmStageMotion is not a template option'
        [IO.File]::WriteAllLines($launch, [string[]]@('PROGRAM=ABC', 'OPTIONS=-Mode Bogus'), [Text.Encoding]::Unicode)
        $r = Invoke-Launcher "-LaunchFile '$launch' -MarkerFile '$marker'"
        (Read-KeyValueFile $marker).MESSAGE | Should Match "-Mode 'Bogus' is not valid"
    }
}

Describe 'Measure button macro' {
    $measure = [IO.File]::ReadAllText((Join-Path $app 'polyworks\VLC_Measure.pwmacro'))
    It 'passes the template values in the launch file, never on the command line of the launcher' {
        @([regex]::Matches($measure, 'DATA_FILE APPEND LINE \( \$vLaunch, \{ "(\w+)=') | ForEach-Object { $_.Groups[1].Value }) -join ',' | Should Be 'PROGRAM,OPTIONS'
        $exec = @($measure -split "`n" | Where-Object { $_ -match 'SYSTEM COMMAND EXEC .*VLReplay\.ps1' })
        $exec.Count | Should Be 1
        $exec[0] | Should Match '"-LaunchFile", "\$\{_QUOTES\}\$\{vLaunch\}\$\{_QUOTES\}"'
        $exec[0] | Should Not Match 'vProgram|vOptions|ConfirmStageMotion'
    }
}

Describe 'stage warning window' {
    $show = $env:CI -eq 'true' -or $env:VLC_TEST_SHOW_WINDOWS -eq '1'
    It 'starts hidden in its own thread and ends again' {
        $r = Invoke-Child (". '$app\lib\Interop.ps1'; Import-VlcInterop; . '$app\lib\StageWarning.ps1'; `$w = Start-VlcStageWarning; " +
            "'ready=' + `$w.Ready + ' hwnd=' + (`$w.Sync.Hwnd -ne [IntPtr]::Zero) + ' visible=' + [VLConnector.Interop.Vl]::IsWindowVisible(`$w.Sync.Hwnd) + ' error=' + `$w.Error; " +
            "Stop-VlcStageWarning `$w; 'ended=' + `$w.Async.IsCompleted")
        $r.Text | Should Match 'ready=True hwnd=True visible=False error=\s'
        $r.Text | Should Match 'ended=True'
    }
    It 'is on screen within 1 s, does not take the focus and hides again (CI, or VLC_TEST_SHOW_WINDOWS=1)' {
        if (-not $show) { Set-TestInconclusive 'Shows a red warning window on this screen; runs in CI or with VLC_TEST_SHOW_WINDOWS=1.'; return }
        $r = Invoke-Child (". '$app\lib\Interop.ps1'; Import-VlcInterop; . '$app\lib\StageWarning.ps1'; `$w = Start-VlcStageWarning; " +
            "`$fg = [VLConnector.Interop.Vl]::GetForegroundWindow(); `$ok = Show-VlcStageWarning `$w 'Automatic test - no stage moves.' 2 `$false; " +
            "'shown=' + `$ok + ' focus=' + ([VLConnector.Interop.Vl]::GetForegroundWindow() -eq `$fg); Start-Sleep -Seconds 3; " +
            "'hidden=' + (-not [VLConnector.Interop.Vl]::IsWindowVisible(`$w.Sync.Hwnd)); Stop-VlcStageWarning `$w")
        $r.Text | Should Match 'shown=True focus=True'
        $r.Text | Should Match 'hidden=True'
    }
}
