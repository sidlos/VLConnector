# Pester 3.4 unit tests: tools\Test-Static.ps1 finds the problems it is meant to find, on a small tree.
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
}
