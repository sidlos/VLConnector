# Pester 3.4 unit tests: tools\Test-Static.ps1 finds the problems it is meant to find, on a small tree.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Describe 'static checks' {
    $root = Join-Path $TestDrive 'tree'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'app\lib'), (Join-Path $root 'app\polyworks') | Out-Null
    $check = "if (`$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {`r`n    & (Join-Path `$PSScriptRoot 'lib\LanguageCheck.ps1') -Caller X -Mode `$ExecutionContext.SessionState.LanguageMode`r`n    exit 1`r`n}`r`n"
    Set-Content -LiteralPath (Join-Path $root 'app\Good.ps1') -Value "param([string]`$A)`r`n$check'work'"
    Set-Content -LiteralPath (Join-Path $root 'app\polyworks\Late.ps1') -Value "param([string]`$A)`r`n. (Join-Path `$PSScriptRoot 'x.ps1')`r`n$check"
    Set-Content -LiteralPath (Join-Path $root 'app\NoCheck.ps1') -Value "'work'"
    Set-Content -LiteralPath (Join-Path $root 'app\lib\Compile.ps1') -Value "Add-Type -TypeDefinition 'public class X {}'`r`nAdd-Type -AssemblyName System.Drawing"
    Set-Content -LiteralPath (Join-Path $root 'app\lib\LoadDll.ps1') -Value "Add-Type -Path 'C:\x.dll'"
    Set-Content -LiteralPath (Join-Path $root 'app\lib\Bare.ps1') -Value "# powershell.exe in a comment is fine`r`nStart-Process -FilePath 'powershell.exe' -ArgumentList '-File', 'x.ps1'`r`n`$ok = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'"
    Set-Content -LiteralPath (Join-Path $root 'app\polyworks\Bare.pwmacro') -Value "# SYSTEM COMMAND EXEC SYNC ( `"powershell.exe`" ) in a comment`r`nSYSTEM COMMAND EXEC SYNC ( `"powershell.exe`", { `"-File`" }, vId )`r`nSYSTEM COMMAND EXEC SYNC ( `$vPs, { `"-File`" }, vId )"
    [IO.File]::WriteAllText((Join-Path $root 'app\Bare.cmd'), "@echo off`r`nrem powershell.exe -File x.ps1`r`npowershell.exe -File x.ps1`r`n`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -File y.ps1`r`n")
    [IO.File]::WriteAllText((Join-Path $root 'app\lib\Control.ps1'), "'a`vb'`r`n")
    Set-Content -LiteralPath (Join-Path $root 'app\lib\Lists.ps1') -Value "`$a = New-Object Collections.Generic.List[object]`r`n`$b = [Collections.Generic.List[object]]::new()`r`n`$c = New-Object Collections.Generic.List[string]"

    $out = & $ps -NoProfile -File (Join-Path $repo 'tools\Test-Static.ps1') -Root $root | Out-String
    It 'fails' { $LASTEXITCODE | Should Be 1 }
    It 'finds entry scripts whose first statement is not the language mode check' {
        $out | Should Match 'app\\NoCheck\.ps1: the first statement must be the language mode check'
        $out | Should Match 'app\\polyworks\\Late\.ps1: the first statement must be the language mode check'
        $out | Should Not Match 'app\\Good\.ps1'
    }
    It 'finds Add-Type with source code or a DLL outside lib\Interop.ps1' {
        $out | Should Match 'app\\lib\\Compile\.ps1: line 1: Add-Type compiles or loads code'
        $out | Should Not Match 'Compile\.ps1: line 2'
        $out | Should Match 'app\\lib\\LoadDll\.ps1: line 1: Add-Type compiles or loads code'
    }
    It 'finds powershell.exe started without its full path, in scripts, macros and batch files, but not in comments' {
        $out | Should Match 'app\\lib\\Bare\.ps1: line 2: powershell\.exe without its full System32 path'
        $out | Should Not Match 'Bare\.ps1: line [13]:'
        $out | Should Match 'app\\polyworks\\Bare\.pwmacro: line 2: powershell\.exe without'
        $out | Should Not Match 'Bare\.pwmacro: line [13]:'
        $out | Should Match 'app\\Bare\.cmd: line 3: powershell\.exe without'
        $out | Should Not Match 'Bare\.cmd: line [124]:'
    }
    It 'finds control characters in text files' {
        $out | Should Match 'app\\lib\\Control\.ps1: 1 control character'
    }
    It 'finds a List[object] made by New-Object (PowerShell 5.1 cannot put it into @())' {
        $out | Should Match 'app\\lib\\Lists\.ps1: line 1: New-Object List\[object\]'
        $out | Should Not Match 'Lists\.ps1: line [23]:'
    }
}
