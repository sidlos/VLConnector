# Pester 3.4 unit tests: installation and removal (lib\Install.ps1) on temporary folders, without administrator
# rights: the package manifest and IT-signed scripts (C57, C05), the install folder (C77), the folder swap with
# rollback (C15), deleting without following links, the move of a 1.0.0-rc10 installation to forwarders (C17),
# processes in use, permissions (C19-C21) and a whole installation, update and removal. Permissions, the event
# source and a real Program Files installation are tested as administrator (CI, acceptance test).
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'app\lib\Install.ps1')

# A manifest of every file in the folder, as tools\Build-Release.ps1 writes it.
function New-TestManifest([string]$Dir) {
    $lines = foreach ($f in Get-ChildItem -LiteralPath $Dir -Recurse -File | Where-Object { $_.Name -ne 'MANIFEST.sha256' } | Sort-Object FullName) {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(), ($f.FullName.Substring($Dir.TrimEnd('\').Length + 1) -replace '\\', '/')
    }
    [IO.File]::WriteAllLines((Join-Path $Dir 'MANIFEST.sha256'), [string[]]@($lines))
}

function New-TestTree([string]$Dir, [hashtable]$Files) {
    foreach ($rel in $Files.Keys) {
        $path = Join-Path $Dir $rel
        New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
        [IO.File]::WriteAllText($path, $Files[$rel])
    }
}

function New-Junction([string]$Link, [string]$Target) { [void](cmd.exe /c mklink /J "$Link" "$Target") }

Describe 'package manifest' {
    It 'is read once, with its fingerprint' {
        $dir = Join-Path $TestDrive 'm1'
        New-TestTree $dir @{ 'a.txt' = 'a'; 'sub\b.txt' = 'b' }
        New-TestManifest $dir
        $m = Read-VlcManifest $dir
        @($m.Entries.PSBase.Keys) -join ',' | Should Be 'a.txt,sub/b.txt'
        $m.Fingerprint | Should Be (Get-FileHash -LiteralPath (Join-Path $dir 'MANIFEST.sha256') -Algorithm SHA256).Hash.ToLower()
    }
    It 'is refused when it is missing or empty, or a line is not a plain relative path' {
        $dir = Join-Path $TestDrive 'm2'
        New-Item -ItemType Directory -Path $dir | Out-Null
        { Read-VlcManifest $dir } | Should Throw 'missing'
        $hash = 'a' * 64
        foreach ($case in @(@('', 'empty'), @('xyz  a.txt', 'line 1'), @("$hash  ../a.txt", 'plain relative'), @("$hash  sub//a.txt", 'plain relative'),
                @("$hash  /a.txt", 'plain relative'), @("$hash  MANIFEST.sha256", 'plain relative'), @("$hash  a.txt`r`n$hash  A.TXT", 'twice'))) {
            [IO.File]::WriteAllText((Join-Path $dir 'MANIFEST.sha256'), $case[0])
            { Read-VlcManifest $dir } | Should Throw $case[1]
        }
    }
}

Describe 'package check' {
    It 'finds missing, changed and extra files; extra files are problems only in an installed copy' {
        $dir = Join-Path $TestDrive 'c1'
        New-TestTree $dir @{ 'a.txt' = 'a'; 'b.txt' = 'b'; 'c.txt' = 'c' }
        New-TestManifest $dir
        $m = Read-VlcManifest $dir
        (Test-VlcPackageTree $dir $m).Ok | Should Be $true
        Remove-Item -LiteralPath (Join-Path $dir 'a.txt')
        [IO.File]::WriteAllText((Join-Path $dir 'b.txt'), 'changed')
        [IO.File]::WriteAllText((Join-Path $dir 'extra.txt'), 'x')
        [IO.File]::WriteAllText((Join-Path $dir 'machine.json'), '{}')
        $r = Test-VlcPackageTree $dir $m $script:VlcGeneratedFiles
        $r.Problems -join ';' | Should Be 'missing: a.txt;changed: b.txt'
        $r.Extra -join ';' | Should Be 'extra.txt'
        (Test-VlcPackageTree $dir $m $script:VlcGeneratedFiles -Strict).Problems -contains 'not in the package: extra.txt' | Should Be $true
        (Test-VlcPackageTree $dir $m $script:VlcGeneratedFiles -Strict).Problems -contains 'not in the package: machine.json' | Should Be $false
    }
    It 'accepts a script that IT signed, with any encoding, and no other change' {
        $dir = Join-Path $TestDrive 'c2'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $text = "# a script`r`nWrite-Output 'x'`r`n"
        [IO.File]::WriteAllText((Join-Path $dir 'utf8.ps1'), $text, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $dir 'utf16.ps1'), $text, [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText((Join-Path $dir 'ascii.ps1'), $text, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $dir 'batch.cmd'), "@echo off`r`n", [Text.Encoding]::ASCII)
        New-TestManifest $dir
        $m = Read-VlcManifest $dir
        $block = "# SIG # Begin signature block`r`n# MIIoFAYJKoZIhvcNAQcCoIIoBTCCKAECAQExDzANBglghkgBZQMEAgEFADB5Bgor`r`n# SIG # End signature block`r`n"
        [IO.File]::WriteAllText((Join-Path $dir 'utf8.ps1'), $text + $block, (New-Object Text.UTF8Encoding($true)))
        [IO.File]::WriteAllText((Join-Path $dir 'utf16.ps1'), $text + "`r`n" + $block, [Text.Encoding]::Unicode)
        [IO.File]::WriteAllText((Join-Path $dir 'ascii.ps1'), ($text -replace 'x', 'y') + $block, [Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $dir 'batch.cmd'), "@echo off`r`n" + $block, [Text.Encoding]::ASCII)
        (Test-VlcPackageTree $dir $m).Problems -join ';' | Should Be 'changed: ascii.ps1;changed: batch.cmd'
    }
    It 'refuses a link in the folder' {
        $dir = Join-Path $TestDrive 'c3'
        New-TestTree $dir @{ 'a.txt' = 'a'; 'outside\o.txt' = 'o' }
        New-TestManifest $dir
        $m = Read-VlcManifest $dir
        New-Junction (Join-Path $dir 'link') (Join-Path $dir 'outside')
        try { (Test-VlcPackageTree $dir $m).Problems | Should Be 'link (not allowed): link' }
        finally { [IO.Directory]::Delete((Join-Path $dir 'link')) }
    }
}

Describe 'copying the package' {
    It 'copies only the files of the manifest and writes the manifest that was read' {
        $src = Join-Path $TestDrive 'p1'
        New-TestTree $src @{ 'app\a.ps1' = 'a'; 'VERSION' = '1.0.0' }
        New-TestManifest $src
        $m = Read-VlcManifest $src
        [IO.File]::WriteAllText((Join-Path $src 'not-listed.txt'), 'x')
        [IO.File]::WriteAllText((Join-Path $src 'MANIFEST.sha256'), 'replaced afterwards')
        $dst = Join-Path $TestDrive 'p1-copy'
        Copy-VlcPackage $src $dst $m
        @(Get-ChildItem -LiteralPath $dst -Recurse -File | ForEach-Object { $_.Name } | Sort-Object) -join ',' | Should Be 'a.ps1,MANIFEST.sha256,VERSION'
        (Test-VlcPackageTree $dst (Read-VlcManifest $dst) -Strict).Ok | Should Be $true
    }
    It 'refuses a file that was changed after the manifest was read' {
        $src = Join-Path $TestDrive 'p2'
        New-TestTree $src @{ 'a.txt' = 'a' }
        New-TestManifest $src
        $m = Read-VlcManifest $src
        [IO.File]::WriteAllText((Join-Path $src 'a.txt'), 'swapped')
        { Copy-VlcPackage $src (Join-Path $TestDrive 'p2-copy') $m } | Should Throw 'differs'
    }
}

Describe 'versions' {
    It 'compare release candidates and releases by their numbers' {
        foreach ($pair in @(@('1.0.0-rc9', '1.0.0-rc10'), @('1.0.0-rc10', '1.0.0-rc11'), @('1.0.0-rc11', '1.0.0'), @('1.0.0', '1.0.1'), @('1.2.0', '1.10.0'), @('0.9.9', '1.0.0-rc1'))) {
            Compare-VlcVersion $pair[0] $pair[1] | Should Be -1
            Compare-VlcVersion $pair[1] $pair[0] | Should Be 1
        }
        Compare-VlcVersion '1.0.0-RC11' '1.0.0-rc11' | Should Be 0
    }
    It 'refuse a text that is no version' {
        { Compare-VlcVersion 'dev' '1.0.0' } | Should Throw 'not a VL Connector version'
    }
}

Describe 'install folder' {
    $pkg = Join-Path $TestDrive 'pkg'
    New-TestTree $pkg @{ 'VERSION' = '1.0.0-rc11' }
    It 'is refused when the package lies in it, is it, or holds it (C77)' {
        { Test-VlcInstallTarget $pkg $pkg '1.0.0-rc11' } | Should Throw 'Unpack the package'
        { Test-VlcInstallTarget $pkg (Split-Path $pkg) '1.0.0-rc11' } | Should Throw 'Unpack the package'
        { Test-VlcInstallTarget $pkg (Join-Path $pkg 'inner') '1.0.0-rc11' } | Should Throw 'Unpack the package'
    }
    It 'is refused for a relative path, a drive, the Windows folder or a shared folder itself' {
        foreach ($t in 'VLConnector', 'C:\', $env:SystemRoot, (Join-Path $env:SystemRoot 'VLC'), $env:ProgramFiles, $env:ProgramData) {
            { Test-VlcInstallTarget $pkg $t '1.0.0-rc11' } | Should Throw
        }
    }
    It 'is refused when it holds something else, or is a link' {
        $other = Join-Path $TestDrive 'other'
        New-TestTree $other @{ 'x.txt' = 'x' }
        { Test-VlcInstallTarget $pkg $other '1.0.0-rc11' } | Should Throw 'holds no VL Connector'
        $link = Join-Path $TestDrive 'link'
        New-Junction $link $other
        try { { Test-VlcInstallTarget $pkg $link '1.0.0-rc11' } | Should Throw 'link' }
        finally { [IO.Directory]::Delete($link) }
    }
    It 'takes an empty folder or an installation, and keeps a newer one unless -Force' {
        Test-VlcInstallTarget $pkg (Join-Path $TestDrive 'new') '1.0.0-rc11' | Should Be ''
        $inst = Join-Path $TestDrive 'inst'
        New-TestTree $inst @{ 'VERSION' = '1.0.0'; 'app\VLReplay.ps1' = '#' }
        { Test-VlcInstallTarget $pkg $inst '1.0.0-rc11' } | Should Throw 'newer'
        Test-VlcInstallTarget $pkg $inst '1.0.0-rc11' -Force | Should Be '1.0.0'
        Test-VlcInstallTarget $pkg $inst '1.0.1' | Should Be '1.0.0'
    }
}

Describe 'folder swap' {
    It 'keeps the installed version in .old and puts the stage in place' {
        $target = Join-Path $TestDrive 'swap1\VLConnector'
        New-TestTree $target @{ 'VERSION' = 'old' }
        New-TestTree "$target.old" @{ 'VERSION' = 'older' }
        New-TestTree "$target.new" @{ 'VERSION' = 'new' }
        Invoke-VlcFolderSwap "$target.new" $target
        [IO.File]::ReadAllText((Join-Path $target 'VERSION')) | Should Be 'new'
        [IO.File]::ReadAllText((Join-Path "$target.old" 'VERSION')) | Should Be 'old'
        Test-Path -LiteralPath "$target.new" | Should Be $false
    }
    It 'puts the installed version back when the stage cannot be moved' {
        $target = Join-Path $TestDrive 'swap2\VLConnector'
        New-TestTree $target @{ 'VERSION' = 'old' }
        New-TestTree "$target.new" @{ 'VERSION' = 'new' }
        $open = [IO.File]::Open((Join-Path "$target.new" 'VERSION'), 'Open', 'Read', 'Read')
        try { { Invoke-VlcFolderSwap "$target.new" $target } | Should Throw 'cannot be renamed' }
        finally { $open.Dispose() }
        [IO.File]::ReadAllText((Join-Path $target 'VERSION')) | Should Be 'old'
    }
}

Describe 'deleting a folder' {
    It 'removes a link in it, never what the link points to, and read-only files' {
        $outside = Join-Path $TestDrive 'd-outside'
        New-TestTree $outside @{ 'keep.txt' = 'keep' }
        $dir = Join-Path $TestDrive 'd1'
        New-TestTree $dir @{ 'a.txt' = 'a'; 'sub\ro.txt' = 'r' }
        Set-ItemProperty -LiteralPath (Join-Path $dir 'sub\ro.txt') -Name IsReadOnly -Value $true
        New-Junction (Join-Path $dir 'sub\link') $outside
        Remove-VlcTree $dir
        Test-Path -LiteralPath $dir | Should Be $false
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
    }
}

Describe 'permissions' {
    It 'finds who else may change a folder' {
        $dir = Join-Path $TestDrive 'acl'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $problems = @(Get-VlcAclProblems $dir)
        ($problems -join ' ') | Should Match ([regex]::Escape($me))
        @(Get-VlcAclProblems (Join-Path $dir 'VLConnector') -Parents).Count | Should BeGreaterThan 0
    }
    It 'finds nothing in folders that only administrators and Windows may change' {
        @(Get-VlcAclProblems (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0')).Count | Should Be 0
        @(Get-VlcAclProblems (Join-Path $env:ProgramFiles 'VLConnector') -Parents).Count | Should Be 0
    }
}

Describe 'VL Connector processes' {
    It 'are found in every session by the script they run' {
        $dir = 'C:\Program Files\VLConnector'
        $fake = @(
            [pscustomobject]@{ ProcessId = 1; SessionId = 1; CommandLine = "powershell.exe -STA -File `"$dir\app\Agent.ps1`"" }
            [pscustomobject]@{ ProcessId = 2; SessionId = 2; CommandLine = "powershell.exe -File `"$dir\app\VLReplay.ps1`" -Watch -MarkerFile `"x`"" }
            [pscustomobject]@{ ProcessId = 3; SessionId = 2; CommandLine = "powershell.exe -File `"$dir\app\VLReplay.ps1`" -LaunchFile `"x`"" }
            [pscustomobject]@{ ProcessId = 4; SessionId = 1; CommandLine = "powershell.exe -File `"$dir\app\polyworks\Station-Step.ps1`" -Action Next" }
            [pscustomobject]@{ ProcessId = 5; SessionId = 3; CommandLine = "powershell.exe -STA -File `"$dir\app\VLConnector.ps1`" -Show Wizard" }
            [pscustomobject]@{ ProcessId = 6; SessionId = 1; CommandLine = "powershell.exe -File `"$dir\app\polyworks\Complete-Evaluation.ps1`"" }
            [pscustomobject]@{ ProcessId = 7; SessionId = 1; CommandLine = "powershell.exe -File `"C:\Other\app\Agent.ps1`"" }
            [pscustomobject]@{ ProcessId = 8; SessionId = 1; CommandLine = $null })
        $found = @(Get-VlcProcesses @($dir, 'C:\ProgramData\VLConnector') $fake)
        @($found | ForEach-Object { "$($_.ProcessId):$($_.Kind)" }) -join ',' | Should Be '1:Agent,2:Agent,3:Launcher,4:Station,5:Window,6:Other'
    }
}

Describe 'older installation (1.0.0-rc10)' {
    It 'is replaced by forwarders: a link in it is removed, not followed, and its machine.json is returned' {
        $outside = Join-Path $TestDrive 'l-outside'
        New-TestTree $outside @{ 'keep.txt' = 'keep' }
        $old = Join-Path $TestDrive 'ProgramData\VLConnector'
        New-TestTree $old @{ 'VERSION' = '1.0.0-rc10'; 'app\VLReplay.ps1' = '#'; 'machine.json' = '{ "vl": { "confirmStageMotion": true } }' }
        New-Junction (Join-Path $old 'app\link') $outside
        $new = Join-Path $TestDrive 'Program Files\VLConnector'
        $r = Move-VlcLegacyInstall $old $new -SkipAcl
        $r.MachineJson | Should Match 'confirmStageMotion'
        $r.Left | Should Be ''
        (Get-VlcFolderKind $old).Kind | Should Be 'Forwarders'
        [IO.File]::ReadAllText((Join-Path $old 'app\polyworks\VLC_Measure.pwmacro')) | Should Match ([regex]::Escape("MACRO EXEC ( `"$new\app\polyworks\VLC_Measure.pwmacro`", `"$new\app`" )"))
        Test-Path -LiteralPath (Join-Path $old 'app\VLReplay.ps1') | Should Be $false
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
        @(Get-ChildItem -LiteralPath (Split-Path $old) -Filter 'VLConnector.removing-*').Count | Should Be 0
        # again: the forwarders are written anew
        (Move-VlcLegacyInstall $old $new -SkipAcl).Note | Should Match 'forwarders'
    }
    It 'is left alone when the folder holds something else' {
        $other = Join-Path $TestDrive 'pd2\VLConnector'
        New-TestTree $other @{ 'notes.txt' = 'mine' }
        Move-VlcLegacyInstall $other (Join-Path $TestDrive 'pf2\VLConnector') -SkipAcl | Should Be $null
        Test-Path -LiteralPath (Join-Path $other 'notes.txt') | Should Be $true
    }
    It 'forwards the old buttons and shortcuts to the new folder' {
        $fw = Get-VlcForwarders "C:\Program Files\O'Brien\VLConnector"
        @($fw.PSBase.Keys) -join ',' | Should Be 'app\polyworks\VLC_Measure.pwmacro,VLC_Measure_Button.pwmacro,app\polyworks\VLC_Station.pwmacro,VLC_Station_Button.pwmacro,app\Agent.ps1,app\VLConnector.ps1,VLConnector-moved.txt'
        $fw['app\Agent.ps1'] | Should Match ([regex]::Escape("& 'C:\Program Files\O''Brien\VLConnector\app\Agent.ps1' @args"))
    }
}

Describe 'users who had switched the stage confirmation on' {
    It 'are those whose own settings switched it on, as 1.0.0-rc10 read them' {
        $profiles = Join-Path $TestDrive 'Users'
        foreach ($u in @(@('anna', '{ "vl": { "confirmStageMotion": true } }'), @('ben', '{ "vl": { "confirmStageMotion": "false" } }'),
                @('cleo', '{ "vl": { "confirmStageMotion": false } }'), @('dan', 'not json'))) {
            New-TestTree (Join-Path $profiles $u[0]) @{ 'AppData\Roaming\VLConnector\settings.json' = $u[1] }
        }
        New-Item -ItemType Directory -Path (Join-Path $profiles 'eve') | Out-Null
        @(Find-VlcStageUsers @(Get-ChildItem -LiteralPath $profiles | ForEach-Object { $_.FullName })) -join ',' | Should Be 'anna,ben'
    }
}

Describe 'Start menu and startup shortcuts' {
    It 'creates the entries for all users' {
        $menuRoot = Join-Path $TestDrive 'menu'
        $menu = Set-VlcStartMenu 'C:\Program Files\VLConnector' $menuRoot
        $names = [string[]]@(Get-ChildItem -LiteralPath $menu | ForEach-Object { $_.Name })
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $names -join ',' | Should Be 'Uninstall VL Connector.lnk,VL Connector agent.lnk,VL Connector.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shell.CreateShortcut((Join-Path $menu 'VL Connector.lnk')).Arguments | Should Match ([regex]::Escape('"C:\Program Files\VLConnector\app\VLConnector.ps1"'))
        $shell.CreateShortcut((Join-Path $menu 'Uninstall VL Connector.lnk')).WorkingDirectory | Should Be $env:SystemRoot
    }
    It 'removes only the agent startup shortcuts of this installation' {
        $profiles = Join-Path $TestDrive 'Users2'
        foreach ($u in @(@('anna', 'C:\Program Files\VLConnector\app'), @('ben', 'D:\Other\app'))) {
            $startup = Join-Path $profiles "$($u[0])\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
            New-Item -ItemType Directory -Force -Path $startup | Out-Null
            New-VlcShortcut (Join-Path $startup 'VL Connector agent.lnk') 'powershell.exe' "-File `"$($u[1])\Agent.ps1`"" $u[1] 'x.ico' 'agent'
        }
        $removed = @(Remove-VlcStartupShortcuts 'C:\Program Files\VLConnector\app' @(Get-ChildItem -LiteralPath $profiles | ForEach-Object { $_.FullName }))
        $removed.Count | Should Be 1
        $removed[0] | Should Match 'anna'
        Test-Path -LiteralPath (Join-Path $profiles 'ben\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\VL Connector agent.lnk') | Should Be $true
    }
}

Describe 'installation, update and removal on temporary folders (no administrator rights)' {
    $root = Join-Path $TestDrive 'e2e'
    $pkg = Join-Path $root 'package'
    foreach ($item in 'app', 'VERSION', 'Install.ps1', 'Install.cmd', 'Uninstall.ps1', 'Uninstall.cmd', 'tools\Build-Interop.ps1') {
        $to = Join-Path $pkg $item
        New-Item -ItemType Directory -Force -Path (Split-Path $to) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $to -Recurse
    }
    New-TestManifest $pkg
    $target = Join-Path $root 'Program Files\VLConnector'
    $legacy = Join-Path $root 'ProgramData\VLConnector'
    $menuRoot = Join-Path $root 'menu'
    $outside = Join-Path $root 'outside'
    New-TestTree $outside @{ 'keep.txt' = 'keep' }
    New-TestTree $legacy @{ 'VERSION' = '1.0.0-rc10'; 'app\VLReplay.ps1' = '#'
        'machine.json' = '{ "polyworks": { "keepPieces": "Nok" }, "vl": { "confirmStageMotion": true, "exe": "C:\\Tools\\other.exe" } }' }
    New-Junction (Join-Path $legacy 'link') $outside
    $lines = New-Object Collections.Generic.List[string]
    $say = { param([string]$Text, [string]$Color) $lines.Add($Text) }.GetNewClosure()
    $version = ([IO.File]::ReadAllText((Join-Path $repo 'VERSION'))).Trim()

    It 'installs the files, the interface DLL, the button files, the machine settings and the Start menu' {
        $r = Install-VlcMachine -Source $pkg -Target $target -ConfirmStageMotion Off -LegacyDir $legacy -MenuRoot $menuRoot -SkipAcl -Say $say
        ($lines -join "`n") | Should Not Match 'failed'
        $r.ExitCode | Should Be 0
        $r.Version | Should Be $version
        (Test-VlcPackageTree $target (Read-VlcManifest $target) $script:VlcGeneratedFiles -Strict).Problems -join ';' | Should Be ''
        $info = [IO.File]::ReadAllText((Join-Path $target 'install-info.txt'))
        $info | Should Match "VERSION=$([regex]::Escape($version))"
        $sourceHash = [regex]::Match($info, 'INTERFACES=([0-9a-f]{64})').Groups[1].Value
        [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $target 'bin\VLConnector.Interop.dll')).Comments | Should Be "SourceSha256 $sourceHash"
        [IO.File]::ReadAllText((Join-Path $target 'VLC_Station_Button.pwmacro')) | Should Match ([regex]::Escape("MACRO EXEC ( `"$target\app\polyworks\VLC_Station.pwmacro`", `"$target\app`" )"))
        $machine = [IO.File]::ReadAllText((Join-Path $target 'machine.json')) | ConvertFrom-Json
        $machine.defaults.polyworks.keepPieces | Should Be 'Nok'
        $machine.policy.vl.confirmStageMotion | Should Be $false
        $machine.defaults.vl | Should Be $null
        ($lines -join "`n") | Should Match 'Not taken over .*vl\.confirmStageMotion'
        @(Get-ChildItem -LiteralPath (Join-Path $menuRoot 'VL Connector')).Count | Should Be 3
    }
    It 'leaves only forwarders at the place of 1.0.0-rc10, without following its link' {
        (Get-VlcFolderKind $legacy).Kind | Should Be 'Forwarders'
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
    }
    It 'updates: the previous version stays in .old, machine.json is kept' {
        $lines.Clear()
        $r = Install-VlcMachine -Source $pkg -Target $target -LegacyDir $legacy -MenuRoot $menuRoot -SkipAcl -Say $say
        $r.ExitCode | Should Be 0
        Test-Path -LiteralPath (Join-Path "$target.old" 'install-info.txt') | Should Be $true
        ([IO.File]::ReadAllText((Join-Path $target 'machine.json')) | ConvertFrom-Json).defaults.polyworks.keepPieces | Should Be 'Nok'
        (Test-VlcPackageTree $target (Read-VlcManifest $target) $script:VlcGeneratedFiles -Strict).Ok | Should Be $true
    }
    It 'refuses machine settings that are not allowed, before anything is changed' {
        $bad = Join-Path $root 'bad.json'
        [IO.File]::WriteAllText($bad, '{ "defaults": { "vl": { "confirmStageMotion": true } } }')
        $before = (Get-Item -LiteralPath (Join-Path $target 'install-info.txt')).LastWriteTimeUtc
        { Install-VlcMachine -Source $pkg -Target $target -MachineSettings $bad -LegacyDir $legacy -MenuRoot $menuRoot -SkipAcl -Say $say } | Should Throw 'only be set in the policy'
        (Get-Item -LiteralPath (Join-Path $target 'install-info.txt')).LastWriteTimeUtc | Should Be $before
    }
    It 'removes the installation, the previous version, the forwarders and the Start menu' {
        $lines.Clear()
        Uninstall-VlcMachine -InstallDir $target -LegacyDir $legacy -MenuRoot $menuRoot -ProfileDirs @() -SkipAcl -Say $say | Should Be 0
        foreach ($gone in $target, "$target.old", $legacy, (Join-Path $menuRoot 'VL Connector')) { Test-Path -LiteralPath $gone | Should Be $false }
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should Be $true
    }
}

Describe 'shortcuts of a user after an update' {
    $inst = Join-Path $TestDrive 'inst2'
    New-Item -ItemType Directory -Path $inst | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'app') -Destination (Join-Path $inst 'app') -Recurse
    [IO.File]::WriteAllText((Join-Path $inst 'install-info.txt'), "VERSION=test`r`n")
    foreach ($lib in 'Settings', 'AgentControl') { . (Join-Path $inst "app\lib\$lib.ps1") }
    $startup = Join-Path $TestDrive 'Startup'
    $programs = Join-Path $TestDrive 'Programs'
    $common = Join-Path $TestDrive 'CommonPrograms'
    New-Item -ItemType Directory -Force -Path $startup, (Join-Path $programs 'VL Connector'), (Join-Path $common 'VL Connector') | Out-Null
    New-VlcShortcut (Join-Path $startup 'VL Connector agent.lnk') 'powershell.exe' '-File "C:\ProgramData\VLConnector\app\Agent.ps1"' 'C:\ProgramData\VLConnector\app' 'x.ico' 'agent'
    It 'points the agent start at this installation and removes the own Start menu folder of 1.0.0-rc10' {
        @(Repair-VlcUserShortcuts $startup $programs $common).Count | Should Be 2
        (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $startup 'VL Connector agent.lnk')).Arguments | Should Match ([regex]::Escape("`"$inst\app\Agent.ps1`""))
        Test-Path -LiteralPath (Join-Path $programs 'VL Connector') | Should Be $false
        @(Repair-VlcUserShortcuts $startup $programs $common).Count | Should Be 0
    }
    It 'leaves the shortcuts alone in a development tree' {
        Remove-Item -LiteralPath (Join-Path $inst 'install-info.txt')
        New-VlcShortcut (Join-Path $startup 'VL Connector agent.lnk') 'powershell.exe' '-File "C:\Elsewhere\app\Agent.ps1"' 'C:\Elsewhere\app' 'x.ico' 'agent'
        @(Repair-VlcUserShortcuts $startup $programs $common).Count | Should Be 0
    }
}

Describe 'signing tool for IT (tools\Sign-Package.ps1)' {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $tool = Join-Path $repo 'tools\Sign-Package.ps1'
    $pkg = Join-Path $TestDrive 'signpkg'
    New-TestTree $pkg @{ 'app\a.ps1' = "'a'"; 'VERSION' = '1.0.0' }
    New-TestManifest $pkg
    function Invoke-Tool([string[]]$More) {
        # the tool's error output must not stop this test (Run-Tests.ps1 runs with ErrorActionPreference Stop)
        $ErrorActionPreference = 'Continue'
        $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $tool -Package $pkg -Thumbprint '0000' @More 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
    }
    It 'checks the package and then needs a certificate with a private key' {
        $r = Invoke-Tool
        $r.Code | Should Not Be 0
        $r.Text | Should Match 'Package matches its manifest'
        $r.Text | Should Match 'No code signing certificate'
    }
    It 'signs nothing when the ZIP differs from the published SHA-256' {
        $zip = Join-Path $TestDrive 'VLConnector-1.0.0.zip'
        [IO.File]::WriteAllText($zip, 'not the published zip')
        $sums = Join-Path $TestDrive 'SHA256SUMS.txt'
        [IO.File]::WriteAllText($sums, ('0' * 64) + "  VLConnector-1.0.0.zip`r`n")
        $r = Invoke-Tool @('-Zip', $zip, '-Sums', $sums)
        $r.Code | Should Not Be 0
        $r.Text | Should Match 'differs from the published SHA-256'
    }
    It 'signs nothing when a file of the package was changed' {
        [IO.File]::WriteAllText((Join-Path $pkg 'app\a.ps1'), "'changed'")
        $r = Invoke-Tool
        $r.Code | Should Not Be 0
        $r.Text | Should Match 'differs from its manifest'
    }
}
