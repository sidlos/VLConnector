# Pester 3.4 unit tests: every entry script stops at once with a clear message when PowerShell runs it in
# ConstrainedLanguage mode, as an AppLocker or WDAC policy does with scripts it does not trust (C48). The
# PolyWorks macros get their result file with STATE=ERROR and the message on the line they read.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
. (Join-Path $app 'lib\KeyValueFile.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$message = 'VL Connector cannot run: Windows PowerShell runs its scripts in ConstrainedLanguage mode'

# Runs a script in a new PowerShell process; -Constrained sets the session to ConstrainedLanguage first.
# A script that does not stop within 60 s is ended (the agent and the windows would otherwise keep running).
function Invoke-Entry([string]$Script, [string]$Arguments = '', [switch]$Constrained) {
    $mode = if ($Constrained) { "`$ExecutionContext.SessionState.LanguageMode = 'ConstrainedLanguage'; " } else { '' }
    $cmd = "$mode& '$($Script -replace "'", "''")' $Arguments; exit `$LASTEXITCODE"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $out = Join-Path $TestDrive ('out_' + [guid]::NewGuid().ToString('N') + '.txt')
    $p = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $enc -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError "$out.err"
    $null = $p.Handle
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "$Script did not stop within 60 s." }
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = [IO.File]::ReadAllText($out) + [IO.File]::ReadAllText("$out.err") }
}

function Get-Lines([string]$Path) { return @([IO.File]::ReadAllLines($Path)) }
function Get-Keys([string]$Path) { return @((Read-KeyValueFile $Path).Keys) -join ',' }

Describe 'entry scripts in ConstrainedLanguage mode' {
    $savedNoUi = $env:VLCONNECTOR_NO_UI
    $env:VLCONNECTOR_NO_UI = '1'
    $logDir = Join-Path $env:LOCALAPPDATA 'VLConnector\logs'
    $today = Get-Date -Format 'yyyyMMdd'

    It 'VLReplay.ps1 writes an ERROR marker in the order the Measure macro reads' {
        $marker = Join-Path $TestDrive 'clm.done'
        $r = Invoke-Entry (Join-Path $app 'VLReplay.ps1') "ABC -MarkerFile '$marker'" -Constrained
        $r.ExitCode | Should Be 1
        $r.Output | Should Match $message
        $lines = Get-Lines $marker
        $lines[0] | Should Be 'STATE=ERROR'
        $lines[5] | Should Match "^MESSAGE=$message"
        # the same keys in the same order as a marker of a normal run (here: a parameter error)
        $normal = Join-Path $TestDrive 'normal.done'
        $n = Invoke-Entry (Join-Path $app 'VLReplay.ps1') "ABC -Mode Bogus -MarkerFile '$normal'"
        $n.ExitCode | Should Be 3
        Get-Keys $marker | Should Be (Get-Keys $normal)
        Get-Content -LiteralPath (Join-Path $logDir "VLReplay_$today.log") -Raw | Should Match $message
    }
    It 'Get-MacroContext.ps1 writes STATE=ERROR on line 1 and the message on line 12' {
        $ctx = Join-Path $TestDrive 'context.txt'
        $r = Invoke-Entry (Join-Path $app 'polyworks\Get-MacroContext.ps1') "-Out '$ctx' -Pwk '$TestDrive\w.pwk'" -Constrained
        $r.ExitCode | Should Be 1
        $lines = Get-Lines $ctx
        $lines[0] | Should Be 'STATE=ERROR'
        $lines[11] | Should Match "^MESSAGE=$message"
        $normal = Join-Path $TestDrive 'context_normal.txt'
        (Invoke-Entry (Join-Path $app 'polyworks\Get-MacroContext.ps1') "-Out '$normal' -Pwk '$TestDrive\w.pwk'").ExitCode | Should Be 0
        Get-Keys $ctx | Should Be (Get-Keys $normal)
    }
    It 'Complete-Evaluation.ps1 writes STATE=ERROR on line 1 and the message on line 8 of the verdict file' {
        $out = Join-Path $TestDrive 'clm.verdict'
        $r = Invoke-Entry (Join-Path $app 'polyworks\Complete-Evaluation.ps1') "-Controls '$TestDrive\none.controls' -Out '$out'" -Constrained
        $r.ExitCode | Should Be 1
        $lines = Get-Lines $out
        $lines[0] | Should Be 'STATE=ERROR'
        $lines[7] | Should Match "^MESSAGE=$message"
        $normal = Join-Path $TestDrive 'normal.verdict'
        [void](Invoke-Entry (Join-Path $app 'polyworks\Complete-Evaluation.ps1') "-Controls '$TestDrive\none.controls' -Out '$normal'")
        Get-Keys $out | Should Be (Get-Keys $normal)
    }
    It 'Station-Step.ps1 writes the Context, Next and Publish files in the order the Station macro reads' {
        foreach ($case in @(@{ Action = 'Context'; Args = ''; Line = 4 }, @{ Action = 'Next'; Args = ''; Line = 5 }, @{ Action = 'Publish'; Args = ' -JobId x'; Line = 1 })) {
            $out = Join-Path $TestDrive "station_$($case.Action).txt"
            $r = Invoke-Entry (Join-Path $app 'polyworks\Station-Step.ps1') "-Action $($case.Action)$($case.Args) -Out '$out'" -Constrained
            $r.ExitCode | Should Be 1
            $r.Output | Should Match $message
            $lines = Get-Lines $out
            $lines[0] | Should Be 'STATE=ERROR'
            $lines[$case.Line] | Should Match "^MESSAGE=$message"
            $normal = Join-Path $TestDrive "station_$($case.Action)_normal.txt"
            [void](Invoke-Entry (Join-Path $app 'polyworks\Station-Step.ps1') "-Action $($case.Action)$($case.Args) -Out '$normal'")
            Get-Keys $out | Should Be (Get-Keys $normal)
        }
    }
    It 'Agent.ps1 and the windows stop with the message and log it' {
        foreach ($case in @(@{ Script = 'Agent.ps1'; Args = ''; Log = 'Agent' }, @{ Script = 'Agent.ps1'; Args = '-Stop'; Log = 'Agent' },
                @{ Script = 'VLConnector.ps1'; Args = ''; Log = 'Settings' }, @{ Script = 'VLConnector.ps1'; Args = '-Show Wizard'; Log = 'Wizard' })) {
            $r = Invoke-Entry (Join-Path $app $case.Script) $case.Args -Constrained
            $r.ExitCode | Should Be 1
            $r.Output | Should Match $message
            Get-Content -LiteralPath (Join-Path $logDir "$($case.Log)_$today.log") -Raw | Should Match $message
        }
    }
    It 'Install.ps1 and Uninstall.ps1 stop before they change anything' {
        # copies without the rest of the package: if the check did not stop them, they would stop at their
        # own folder checks with another message
        $pkg = Join-Path $TestDrive 'package'
        New-Item -ItemType Directory -Force -Path (Join-Path $pkg 'app\lib') | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'Install.ps1'), (Join-Path $repo 'Uninstall.ps1') -Destination $pkg
        Copy-Item -LiteralPath (Join-Path $app 'lib\LanguageCheck.ps1') -Destination (Join-Path $pkg 'app\lib')
        foreach ($script in 'Install.ps1', 'Uninstall.ps1') {
            $r = Invoke-Entry (Join-Path $pkg $script) '-Quiet' -Constrained
            $r.ExitCode | Should Be 1
            $r.Output | Should Match $message
        }
    }

    $env:VLCONNECTOR_NO_UI = $savedNoUi
}
