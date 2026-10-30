# Pester 3.4 unit tests: parts of the launcher that need no VL (the FakeVL scenarios test the rest): finding the
# AI Replay program (C43), the status file with its heartbeat (C80) and the checks of the options.
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
foreach ($lib in 'KeyValueFile', 'VlPrograms') { . (Join-Path $app "lib\$lib.ps1") }
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Describe 'AI Replay programs' {
    $root = Join-Path $TestDrive 'programs'
    foreach ($f in 'Line 1\ABC.vld4', 'Line 1\Part.A.vld4', 'Line 2\Twice.vld4', 'Line 3\Twice.vld4', 'Other\Recent.vld4', 'Other\Old.vld4') {
        $p = Join-Path $root $f
        New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
        [IO.File]::WriteAllText($p, 'program')
    }
    $folders = @((Join-Path $root 'Line 1'), (Join-Path $root 'Line 2'), (Join-Path $root 'Line 3'))
    $recent = @((Join-Path $root 'Other\Recent.vld4'), (Join-Path $root 'Line 1\ABC.vld4'), (Join-Path $root 'Other\Missing.vld4'))

    It 'keeps every part of a name but a trailing .vld4' {
        Get-VlcProgramName 'Part.A' | Should Be 'Part.A'
        Get-VlcProgramName 'Part.A.vld4' | Should Be 'Part.A'
        Get-VlcProgramName 'C:\x\ABC.VLD4' | Should Be 'ABC'
    }
    It 'finds a name in the program folders first, without regard to case and with or without .vld4' {
        Resolve-VlcProgram 'abc' $folders $recent | Should Be (Join-Path $root 'Line 1\ABC.vld4')
        Resolve-VlcProgram 'Part.A' $folders $recent | Should Be (Join-Path $root 'Line 1\Part.A.vld4')
        Resolve-VlcProgram 'Part.A.vld4' $folders $recent | Should Be (Join-Path $root 'Line 1\Part.A.vld4')
        Resolve-VlcProgram 'Part' $folders $recent | Should Be $null
    }
    It 'then in the recent programs of VL, never in other folders' {
        Resolve-VlcProgram 'Recent' $folders $recent | Should Be (Join-Path $root 'Other\Recent.vld4')
        Resolve-VlcProgram 'Old' $folders $recent | Should Be $null
        Resolve-VlcProgram 'Missing' $folders $recent | Should Be $null
        Resolve-VlcProgram 'Recent' @() $recent | Should Be (Join-Path $root 'Other\Recent.vld4')
    }
    It 'refuses a name that exists more than once' {
        { Resolve-VlcProgram 'Twice' $folders $recent } | Should Throw 'exists in several places'
        { Resolve-VlcProgram 'Recent' @() @($recent[0], $recent[0].ToUpper()) } | Should Not Throw
    }
    It 'takes a path as it is' {
        Resolve-VlcProgram (Join-Path $root 'Other\Old') $folders $recent | Should Be (Join-Path $root 'Other\Old.vld4')
        Resolve-VlcProgram (Join-Path $root 'Other\Old.vld4') @() @() | Should Be (Join-Path $root 'Other\Old.vld4')
        Resolve-VlcProgram (Join-Path $root 'Other\Nope.vld4') @() @() | Should Be $null
    }
    It 'reads the recent programs of VL, oldest first' {
        $list = Join-Path $TestDrive 'RecentUsedTemplateFiles.xml'
        $entry = { param($p) '<KeyValueOfstringanyType><Key>Path</Key><a:Value i:type="b:string" xmlns:b="http://www.w3.org/2001/XMLSchema">' + [Security.SecurityElement]::Escape($p) + '</a:Value></KeyValueOfstringanyType>' }
        [IO.File]::WriteAllText($list, '<ArrayOfKeyValueOfstringanyType>' + (& $entry 'C:\a & b\One.vld4') + (& $entry 'relative.vld4') + (& $entry '\\server\share\Two.vld4') + '</ArrayOfKeyValueOfstringanyType>')
        (Get-VlcRecentPrograms $list) -join '|' | Should Be 'C:\a & b\One.vld4|\\server\share\Two.vld4'
        @(Get-VlcRecentPrograms (Join-Path $TestDrive 'none.xml')).Count | Should Be 0
    }
}

Describe 'status file of a scan' {
    It 'is written at once, then again with a growing BEAT, in the order the Measure macro reads' {
        $status = Join-Path $TestDrive 'run.done.status'
        $code = ". '$app\lib\Interop.ps1'; Import-VlcInterop; `$s = New-Object VLConnector.Interop.StatusFile('$status', 300); " +
            "`$s.Set('replay', 'Position 1 of 2: a=b', ''); `$first = [IO.File]::ReadAllText('$status'); Start-Sleep -Milliseconds 1100; " +
            "`$s.Dispose(); `$beat = `$s.Beat; Start-Sleep -Milliseconds 700; `$first; '---'; [IO.File]::ReadAllText('$status'); '---'; `$beat; `$s.Beat"
        $out = & $ps -NoProfile -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) 2>&1 | Out-String
        $parts = $out -split '---'
        $first = @($parts[0].Trim() -split "`r?`n")
        @($first | ForEach-Object { ($_ -split '=', 2)[0] }) -join ',' | Should Be 'STEP,TEXT,VLMESSAGE,UPDATED,BEAT'
        $first[1] | Should Be 'TEXT=Position 1 of 2: a-b'
        $first[4] | Should Be 'BEAT=0'
        $nums = @($parts[2].Trim() -split "`r?`n")
        [int]$nums[0] | Should BeGreaterThan 1
        # no beat after Dispose
        $nums[1] | Should Be $nums[0]
        $parts[1] | Should Match "BEAT=$($nums[0])"
        [IO.File]::ReadAllBytes($status)[0] | Should Be 0xEF
    }
}

Describe 'launcher options' {
    $marker = Join-Path $TestDrive 'opt.done'
    It 'refuses a time limit or a settle time out of range' {
        foreach ($case in @(@{ O = '-TimeoutMin 9999'; M = '-TimeoutMin 9999 is not valid' }, @{ O = '-SettleSec 99'; M = '-SettleSec 99 is not valid' }, @{ O = '-Mode Fast'; M = "-Mode 'Fast' is not valid" })) {
            Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
            $code = "& '$app\VLReplay.ps1' ABC -Options '$($case.O)' -MarkerFile '$marker'; exit `$LASTEXITCODE"
            & $ps -NoProfile -STA -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) *> $null
            $LASTEXITCODE | Should Be 3
            (Read-KeyValueFile $marker).MESSAGE | Should Match ([regex]::Escape($case.M))
        }
    }
}
