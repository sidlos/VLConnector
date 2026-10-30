<#
  CI only (GitHub Actions; the runner is an administrator): the real installation of the package built from this
  commit into C:\Program Files\VLConnector, checked from outside. The move of a 1.0.0-rc10 folder in
  C:\ProgramData\VLConnector (with a link that must not be followed), files and permissions (also by trying to
  write as a standard user), the event source and the policy event, the refusal while VL Connector is in use, an
  update, a package signed with a throwaway certificate (tools\Sign-Package.ps1) and the removal.
  It installs and removes software and creates a local user: never run it on a workstation.
#>
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Only for the CI runner: it installs and removes VL Connector and creates a local user.' }
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'app\lib\Install.ps1')
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$target = Join-Path $env:ProgramFiles 'VLConnector'
$legacy = Join-Path $env:ProgramData 'VLConnector'
$menu = Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'VL Connector'
$work = Join-Path $env:RUNNER_TEMP 'vlc-install'
$failures = New-Object Collections.Generic.List[string]

function Test-Step([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { Write-Host "PASS  $What" -ForegroundColor Green }
    else { Write-Host "FAIL  $What  $Detail" -ForegroundColor Red; $failures.Add($What) }
}

function Invoke-Batch([string]$File, [string[]]$Arguments = @()) {
    $ErrorActionPreference = 'Continue'
    & $File @Arguments 2>&1 | ForEach-Object { Write-Host "      $_" }
    return $LASTEXITCODE
}

function Get-Policy { return ([IO.File]::ReadAllText((Join-Path $target 'machine.json')) | ConvertFrom-Json).policy }

Remove-VlcTree $work
[void][IO.Directory]::CreateDirectory($work)

# --- the package, as it is published ------------------------------------------------------------------------
& (Join-Path $repo 'tools\Build-Release.ps1') | ForEach-Object { Write-Host $_ }
$zip = Get-ChildItem -LiteralPath (Join-Path $repo 'dist') -Filter 'VLConnector-*.zip' | Select-Object -First 1
Expand-Archive -LiteralPath $zip.FullName -DestinationPath (Join-Path $work 'pkg')
$pkg = (Get-ChildItem -LiteralPath (Join-Path $work 'pkg') -Directory | Select-Object -First 1).FullName

# --- 1.0.0-rc10 in C:\ProgramData\VLConnector, with a link to a folder outside ----------------------------------
$outside = Join-Path $work 'outside'
[void][IO.Directory]::CreateDirectory($outside)
[IO.File]::WriteAllText((Join-Path $outside 'keep.txt'), 'keep')
[void][IO.Directory]::CreateDirectory((Join-Path $legacy 'app\polyworks'))
[IO.File]::WriteAllText((Join-Path $legacy 'VERSION'), '1.0.0-rc10')
[IO.File]::WriteAllText((Join-Path $legacy 'app\VLReplay.ps1'), '# 1.0.0-rc10')
[IO.File]::WriteAllText((Join-Path $legacy 'machine.json'), '{ "polyworks": { "keepPieces": "Nok" }, "vl": { "confirmStageMotion": true } }')
[void](cmd.exe /c mklink /J "$legacy\app\link" "$outside")

# --- installation as administrator, stage confirmation off ------------------------------------------------------
$code = Invoke-Batch (Join-Path $pkg 'Install.cmd') @('-Quiet', '-ConfirmStageMotion', 'Off')
Test-Step 'installation' ($code -eq 0) "exit $code"
Test-Step 'install-info.txt' (Test-Path -LiteralPath (Join-Path $target 'install-info.txt'))
$code = Invoke-Batch (Join-Path $target 'Install.cmd') @('-Verify', '-Quiet')
Test-Step 'Install.cmd -Verify: files, permissions, interface DLL' ($code -eq 0) "exit $code"
$acl = @(Get-VlcAclProblems $target -Recurse) + @(Get-VlcAclProblems $target -Parents)
Test-Step 'only administrators can change the program folder' (-not $acl.Count) ($acl -join '; ')
Test-Step 'event source "VL Connector"' ([Diagnostics.EventLog]::SourceExists('VL Connector'))
$events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'VL Connector'; Id = 1000 } -ErrorAction SilentlyContinue)
Test-Step 'policy change written to the event log (1000)' ($events.Count -ge 1)
Test-Step 'policy: stage confirmation off' ((Get-Policy).vl.confirmStageMotion -eq $false)
Test-Step 'Start menu for all users' (Test-Path -LiteralPath (Join-Path $menu 'VL Connector.lnk'))
Test-Step 'rc10 folder holds only forwarders' ((Get-VlcFolderKind $legacy).Kind -eq 'Forwarders')
Test-Step 'the link in the rc10 folder was not followed' (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))
$fwAcl = @(Get-VlcAclProblems $legacy -Recurse)
Test-Step 'only administrators can change the forwarders' (-not $fwAcl.Count) ($fwAcl -join '; ')
Test-Step 'machine defaults taken over from rc10, not its stage setting' (([IO.File]::ReadAllText((Join-Path $target 'machine.json')) | ConvertFrom-Json).defaults.polyworks.keepPieces -eq 'Nok')

# --- a standard user cannot change it --------------------------------------------------------------------------
$name = 'vlcci' + (Get-Random -Minimum 1000 -Maximum 9999)
$password = ConvertTo-SecureString ([guid]::NewGuid().ToString('N') + 'Aa1!') -AsPlainText -Force
try {
    New-LocalUser -Name $name -Password $password -AccountNeverExpires -PasswordNeverExpires | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name
    $cred = New-Object Management.Automation.PSCredential("$env:COMPUTERNAME\$name", $password)
    foreach ($file in (Join-Path $target 'app\VLReplay.ps1'), (Join-Path $target 'machine.json'), (Join-Path $target 'app\new.ps1'), (Join-Path $legacy 'app\polyworks\VLC_Measure.pwmacro')) {
        $probe = "try { [IO.File]::AppendAllText('$($file -replace "'", "''")', 'x'); exit 1 } catch { exit 0 }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe))
        $p = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-EncodedCommand', $encoded -Credential $cred -WorkingDirectory $env:SystemRoot -WindowStyle Hidden -Wait -PassThru
        Test-Step "a standard user cannot write $file" ($p.ExitCode -eq 0) "exit $($p.ExitCode)"
    }
}
catch { Write-Host "SKIP  standard user test: $($_.Exception.Message)" -ForegroundColor Yellow }
finally { Remove-LocalUser -Name $name -ErrorAction SilentlyContinue }

# --- refused while VL Connector is in use ------------------------------------------------------------------------
$window = Start-Process -FilePath $ps -ArgumentList '-NoProfile', '-Command', "`"& { Start-Sleep -Seconds 120 } '$target\app\VLConnector.ps1'`"" -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 2
try {
    $code = Invoke-Batch (Join-Path $pkg 'Install.cmd') @('-Quiet')
    Test-Step 'installation refused while a VL Connector window is open (1618)' ($code -eq 1618) "exit $code"
}
finally { Stop-Process -Id $window.Id -Force -ErrorAction SilentlyContinue }

# --- update -------------------------------------------------------------------------------------------------------
$code = Invoke-Batch (Join-Path $pkg 'Install.cmd') @('-Quiet')
Test-Step 'update' ($code -eq 0) "exit $code"
Test-Step 'previous version kept in .old' (Test-Path -LiteralPath (Join-Path "$target.old" 'install-info.txt'))
Test-Step 'machine.json kept' ((Get-Policy).vl.confirmStageMotion -eq $false)

# --- a package that IT signed with its own certificate (a throwaway one here) ------------------------------------
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=VL Connector CI test' -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(1)
try {
    $signed = Join-Path $work 'signed'
    Copy-Item -LiteralPath $pkg -Destination $signed -Recurse
    $dll = Join-Path $work 'VLConnector.Interop.dll'
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $signed 'tools\Sign-Package.ps1') -Package $signed -Thumbprint $cert.Thumbprint -NoTimestamp -AllowUntrusted `
        -Zip $zip.FullName -Sums (Join-Path $repo 'dist\SHA256SUMS.txt') -InteropDll $dll | ForEach-Object { Write-Host "      $_" }
    Test-Step 'Sign-Package.ps1' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
    $code = Invoke-Batch (Join-Path $signed 'Install.cmd') @('-Quiet', '-InteropDll', $dll)
    Test-Step 'installation of the signed package with the signed interface DLL' ($code -eq 0) "exit $code"
    Test-Step 'installed scripts carry the signature' ((Get-AuthenticodeSignature -LiteralPath (Join-Path $target 'app\VLReplay.ps1')).SignerCertificate.Thumbprint -eq $cert.Thumbprint)
    Test-Step 'installed interface DLL carries the signature' ((Get-AuthenticodeSignature -LiteralPath (Join-Path $target 'bin\VLConnector.Interop.dll')).SignerCertificate.Thumbprint -eq $cert.Thumbprint)
    $code = Invoke-Batch (Join-Path $target 'Install.cmd') @('-Verify', '-Quiet')
    Test-Step 'Install.cmd -Verify accepts the signed scripts' ($code -eq 0) "exit $code"
}
finally { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force -ErrorAction SilentlyContinue }

# --- removal -------------------------------------------------------------------------------------------------------
$code = Invoke-Batch (Join-Path $target 'Uninstall.cmd') @('-Quiet')
Test-Step 'removal' ($code -eq 0) "exit $code"
foreach ($gone in $target, "$target.old", $menu) { Test-Step "removed: $gone" (-not (Test-Path -LiteralPath $gone)) }
Test-Step 'the rc10 place stays as an empty folder only administrators can change' ((@(Get-ChildItem -LiteralPath $legacy -Force).Count -eq 1) -and -not @(Get-VlcAclProblems $legacy -Recurse).Count)
Test-Step 'event source removed' (-not [Diagnostics.EventLog]::SourceExists('VL Connector'))
Test-Step 'the folder outside is untouched' (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))

if ($failures.Count) { Write-Host "$($failures.Count) installation check(s) failed: $($failures -join ', ')" -ForegroundColor Red; exit 1 }
Write-Host 'All installation checks passed' -ForegroundColor Green
exit 0
