# Pester 3.4 unit tests: the Windows and PolyWorks interfaces (app\interop\*.cs) are compiled once by the
# installer, an installed copy only loads that DLL and refuses one that does not match its sources (C03, C64).
# Loading happens in new PowerShell processes: a loaded assembly stays in the process for good.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
. (Join-Path $app 'lib\Interop.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Runs PowerShell code in a new process; returns the exit code and the output (errors included).
function Invoke-Child([string]$Code) {
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ErrorActionPreference = 'Stop'`n$Code"))
    # error output of the child is collected as text, not raised here
    $ErrorActionPreference = 'Continue'
    $out = & $ps -NoProfile -NonInteractive -EncodedCommand $enc 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
}

# A copy of the files the interfaces need: app\lib\Interop.ps1, app\interop\*.cs and VERSION.
function New-Layout([string]$Root, [switch]$Installed) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Root 'app\lib'), (Join-Path $Root 'app\interop') | Out-Null
    Copy-Item -LiteralPath (Join-Path $app 'lib\Interop.ps1') -Destination (Join-Path $Root 'app\lib')
    Copy-Item -Path (Join-Path $app 'interop\*.cs') -Destination (Join-Path $Root 'app\interop')
    Copy-Item -LiteralPath (Join-Path $repo 'VERSION') -Destination $Root
    if ($Installed) { Set-Content -LiteralPath (Join-Path $Root 'install-info.txt') -Value 'VERSION=test' }
    return $Root
}

Describe 'interface sources' {
    It 'gives the same hash for CRLF and LF line endings and a new one for any change' {
        $lf = Join-Path $TestDrive 'lf'
        New-Item -ItemType Directory -Path $lf | Out-Null
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $app 'interop') -Filter '*.cs') {
            [IO.File]::WriteAllText((Join-Path $lf $f.Name), ([IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"))
        }
        $repoHash = (Get-VlcInteropSource).Sha256
        $repoHash | Should Match '^[0-9a-f]{64}$'
        (Get-VlcInteropSource $lf).Sha256 | Should Be $repoHash
        Add-Content -LiteralPath (Join-Path $lf 'Window.cs') -Value '// changed'
        (Get-VlcInteropSource $lf).Sha256 | Should Not Be $repoHash
    }
    It 'has no Add-Type with source code outside lib\Interop.ps1 (static check 6)' {
        $hits = Select-String -Path (Join-Path $app '*.ps1'), (Join-Path $app 'lib\*.ps1'), (Join-Path $app 'ui\*.ps1'), (Join-Path $app 'polyworks\*.ps1') -Pattern 'Add-Type\s.*-(TypeDefinition|MemberDefinition)' |
            Where-Object { $_.Path -notlike '*\lib\Interop.ps1' }
        @($hits).Count | Should Be 0
    }
}

Describe 'interface DLL of an installed copy' {
    $root = New-Layout (Join-Path $TestDrive 'installed') -Installed
    $dll = Join-Path $root 'bin\VLConnector.Interop.dll'
    $expected = (Get-VlcInteropSource (Join-Path $root 'app\interop')).Sha256
    $load = ". '$root\app\lib\Interop.ps1'; Import-VlcInterop; "

    It 'is built by tools\Build-Interop.ps1 and carries the source hash in its file properties' {
        $r = Invoke-Child "& '$repo\tools\Build-Interop.ps1' -OutputPath '$dll' -SourceDir '$root\app\interop'"
        $r.ExitCode | Should Be 0
        $r.Text.Trim() | Should Be $expected
        Get-VlcInteropDllHash $dll | Should Be $expected
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll)
        $info.ProductName | Should Be 'VL Connector for PolyWorks'
        $info.ProductVersion | Should Be ([IO.File]::ReadAllText((Join-Path $repo 'VERSION')).Trim())
        @(Get-ChildItem -LiteralPath (Join-Path $root 'bin') -Force).Count | Should Be 1
    }
    It 'is loaded from bin\ (not compiled) and offers all interface classes' {
        $r = Invoke-Child ($load + "[VLConnector.Interop.Vl].Assembly.Location; [VLConnector.Interop.BuildInfo]::SourceSha256; " +
            "[VLConnector.Interop.VlcPolyWorks].FullName; [VLConnector.Interop.VlcRetryFilter].FullName; [VLConnector.Interop.VlcWindow].FullName")
        $r.ExitCode | Should Be 0
        $lines = @($r.Text -split "`r?`n" | Where-Object { $_ })
        $lines[0] | Should Be $dll
        $lines[1] | Should Be $expected
        $lines[2..4] -join ',' | Should Be 'VLConnector.Interop.VlcPolyWorks,VLConnector.Interop.VlcRetryFilter,VLConnector.Interop.VlcWindow'
    }
    It 'answers the session questions of the stage safety gate' {
        $r = Invoke-Child ($load + "[VLConnector.Interop.Vl]::SessionOf(`$PID) -eq [Diagnostics.Process]::GetCurrentProcess().SessionId; [VLConnector.Interop.Vl]::IsRemoteSession().GetType().Name; [VLConnector.Interop.Vl]::InputDesktopActive().GetType().Name")
        $r.ExitCode | Should Be 0
        @($r.Text -split "`r?`n" | Where-Object { $_ }) -join ',' | Should Be 'True,Boolean,Boolean'
    }
    It 'is refused, and nothing is loaded, when the scripts come from other sources' {
        $window = Join-Path $root 'app\interop\Window.cs'
        $original = [IO.File]::ReadAllText($window)
        try {
            Add-Content -LiteralPath $window -Value '// another version'
            $r = Invoke-Child ($load.Replace('Import-VlcInterop; ', 'try { Import-VlcInterop } catch { "ERROR " + $_.Exception.Message }; ') + "[bool]('VLConnector.Interop.BuildInfo' -as [type])")
            $r.Text | Should Match 'ERROR .*VLConnector\.Interop\.dll does not belong to the installed VL Connector scripts'
            $r.Text | Should Match 'False\s*$'
        }
        finally { [IO.File]::WriteAllText($window, $original) }
    }
    It 'is never replaced by a compiler run when it is missing' {
        Remove-Item -LiteralPath $dll
        $r = Invoke-Child ($load.Replace('Import-VlcInterop; ', 'try { Import-VlcInterop } catch { "ERROR " + $_.Exception.Message }; ') + "[bool]('VLConnector.Interop.BuildInfo' -as [type])")
        $r.Text | Should Match 'ERROR VL Connector is not complete: .*is missing\. Repair VL Connector'
        $r.Text | Should Match 'False\s*$'
    }
}

Describe 'interfaces in a development tree' {
    It 'are compiled in memory when there is no installation and no package manifest' {
        $root = New-Layout (Join-Path $TestDrive 'dev')
        $r = Invoke-Child ". '$root\app\lib\Interop.ps1'; Import-VlcInterop; '[' + [VLConnector.Interop.Vl].Assembly.Location + ']'; [VLConnector.Interop.BuildInfo]::SourceSha256"
        $r.ExitCode | Should Be 0
        @($r.Text -split "`r?`n" | Where-Object { $_ }) -join ',' | Should Be ('[],' + (Get-VlcInteropSource (Join-Path $root 'app\interop')).Sha256)
    }
    It 'refuse a second, different version in the same process' {
        $a = New-Layout (Join-Path $TestDrive 'dev-a')
        $b = New-Layout (Join-Path $TestDrive 'dev-b')
        Add-Content -LiteralPath (Join-Path $b 'app\interop\Window.cs') -Value '// another version'
        $r = Invoke-Child ". '$a\app\lib\Interop.ps1'; Import-VlcInterop; Import-VlcInterop; . '$b\app\lib\Interop.ps1'; try { Import-VlcInterop } catch { 'ERROR ' + `$_.Exception.Message }"
        $r.Text | Should Match 'ERROR Another version of VL Connector is already loaded'
    }
}

Describe 'type names in the shipped scripts' {
    It 'all resolve once the interfaces and the Windows assemblies are loaded (using namespace included)' {
        $files = @(Get-ChildItem -LiteralPath $app -Recurse -Filter '*.ps1') + @(Get-Item (Join-Path $repo 'Install.ps1'), (Join-Path $repo 'Uninstall.ps1'))
        $checks = foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $using = @($ast.UsingStatements | ForEach-Object { $_.Extent.Text })
            $names = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] -or $n -is [System.Management.Automation.Language.TypeConstraintAst] -or $n -is [System.Management.Automation.Language.ConvertExpressionAst] }, $true) |
                ForEach-Object { $_.TypeName.FullName } | Where-Object { $_ -ne 'ordered' } | Sort-Object -Unique
            foreach ($n in $names) { "$($f.Name)|$($using -join ';')|$n" }
        }
        $list = Join-Path $TestDrive 'types.txt'
        [IO.File]::WriteAllLines($list, [string[]]$checks)
        $code = "Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.IO.Compression, System.IO.Compression.FileSystem, Microsoft.VisualBasic; " +
            ". '$app\lib\Interop.ps1'; Import-VlcInterop; " +
            "foreach (`$line in [IO.File]::ReadAllLines('$list')) { `$p = `$line -split '\|'; `$text = (@(`$p[1] -split ';' | Where-Object { `$_ }) + @('[' + `$p[2] + ']')) -join [Environment]::NewLine; " +
            "try { if (-not ([scriptblock]::Create(`$text).Invoke())) { 'UNRESOLVED ' + `$line } } catch { 'UNRESOLVED ' + `$line } }"
        $r = Invoke-Child $code
        $r.ExitCode | Should Be 0
        $r.Text.Trim() | Should Be ''
    }
    It 'call the interface classes only with methods and argument counts those classes have' {
        $files = @(Get-ChildItem -LiteralPath $app -Recurse -Filter '*.ps1')
        $calls = foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $using = @($ast.UsingStatements | ForEach-Object { $_.Extent.Text }) -join ';'
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] }, $true)) {
                $count = if ($c.Arguments) { $c.Arguments.Count } else { 0 }
                "$($f.Name):$($c.Extent.StartLineNumber)|$using|$($c.Expression.TypeName.FullName)|$($c.Member.Value)|$count"
            }
        }
        $list = Join-Path $TestDrive 'calls.txt'
        [IO.File]::WriteAllLines($list, [string[]]$calls)
        $code = ". '$app\lib\Interop.ps1'; Import-VlcInterop; `$n = 0; " +
            "foreach (`$line in [IO.File]::ReadAllLines('$list')) { `$p = `$line -split '\|'; `$text = (@(`$p[1] -split ';' | Where-Object { `$_ }) + @('[' + `$p[2] + ']')) -join [Environment]::NewLine; " +
            "`$t = try { [scriptblock]::Create(`$text).Invoke()[0] } catch { `$null }; if (-not `$t -or `$t.Namespace -ne 'VLConnector.Interop') { continue }; `$n++; " +
            "if (-not (`$t.GetMethods() | Where-Object { `$_.IsStatic -and `$_.Name -eq `$p[3] -and `$_.GetParameters().Count -eq [int]`$p[4] })) { 'NO MATCH ' + `$line } }; 'checked ' + `$n"
        $r = Invoke-Child $code
        $r.ExitCode | Should Be 0
        $r.Text.Trim() | Should Match '^checked [1-9]\d*$'
    }
}
