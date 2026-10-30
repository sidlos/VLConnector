<#
  Sign-Package.ps1 - for IT: signs the PowerShell scripts of a VL Connector package with your own code signing
  certificate before you deploy it, so it also runs where only signed scripts may run (execution policy
  AllSigned, or an application control policy that trusts your certificate). Run it on the unpacked package:
    tools\Sign-Package.ps1 -Package <unpacked package folder> -Thumbprint <certificate thumbprint>
        -Zip <downloaded ZIP> -Sums <SHA256SUMS.txt>   first checks the ZIP against the published SHA-256
        -TimestampServer <url>                         timestamp (default http://timestamp.digicert.com), so the
                                                       signatures stay valid after the certificate expires
        -NoTimestamp                                   no timestamp (tests, PCs without internet access)
        -InteropDll <file>                             also builds the interface DLL from this package and signs
                                                       it; install with Install.cmd -InteropDll <file>
        -AllowUntrusted                                accepts a certificate this PC does not trust (tests only)
  The package is checked against its manifest first; nothing is signed when a file differs, and the script stops
  at the first error. The installer accepts the signed scripts: it compares them with the manifest without their
  signature block. Prints every signed file with its new SHA-256 (for your records or AppLocker hash rules).
#>
param(
    [Parameter(Mandatory = $true)] [string]$Package,
    [Parameter(Mandatory = $true)] [string]$Thumbprint,
    [string]$Zip = '',
    [string]$Sums = '',
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [switch]$NoTimestamp,
    [string]$InteropDll = '',
    [switch]$AllowUntrusted
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything else runs
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path (Split-Path $PSScriptRoot) 'app\lib\LanguageCheck.ps1') -Caller Sign -Mode $ExecutionContext.SessionState.LanguageMode
    exit 1
}

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'app\lib\Install.ps1')
$Package = [IO.Path]::GetFullPath($Package).TrimEnd('\')

# 1) the download, against the published SHA-256
if ($Zip) {
    $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLower()
    if ($Sums) {
        $line = @([IO.File]::ReadAllLines($Sums) | Where-Object { $_ -match "^[0-9a-f]{64}  $([regex]::Escape((Split-Path $Zip -Leaf)))$" })
        if (-not $line.Count) { throw "$Sums names no SHA-256 for $(Split-Path $Zip -Leaf)." }
        if ($line[0].Substring(0, 64) -ne $hash) { throw "$(Split-Path $Zip -Leaf) differs from the published SHA-256. Download it again; nothing was signed." }
        Write-Host "ZIP matches the published SHA-256 $hash." -ForegroundColor Green
    }
    else { Write-Host "SHA-256 of the ZIP: $hash - compare it with the published one." -ForegroundColor Yellow }
}

# 2) the unpacked package, against its manifest; only the manifest's own scripts are signed
$manifest = Read-VlcManifest $Package
$check = Test-VlcPackageTree $Package $manifest -Strict
if (-not $check.Ok) { throw "The package differs from its manifest: $(@($check.Problems | Select-Object -First 10) -join '; '). Nothing was signed." }
Write-Host "Package matches its manifest. Fingerprint: $($manifest.Fingerprint)" -ForegroundColor Green

$cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $Thumbprint -and $_.HasPrivateKey } | Select-Object -First 1
if (-not $cert) { throw "No code signing certificate with a private key and the thumbprint $Thumbprint was found in Cert:\CurrentUser\My or Cert:\LocalMachine\My." }

function Set-Signature([string]$Path) {
    $params = @{ FilePath = $Path; Certificate = $cert; HashAlgorithm = 'SHA256' }
    if (-not $NoTimestamp) { $params.TimestampServer = $TimestampServer }
    $r = Set-AuthenticodeSignature @params
    $now = Get-AuthenticodeSignature -LiteralPath $Path
    if (-not $now.SignerCertificate -or $now.SignerCertificate.Thumbprint -ne $cert.Thumbprint) { throw "$Path was not signed: $($r.StatusMessage)" }
    if ($now.Status -ne 'Valid' -and -not $AllowUntrusted) { throw "$Path is signed, but this PC does not trust the signature ($($now.Status): $($now.StatusMessage)). Use a certificate your PCs trust." }
    if (-not $NoTimestamp -and -not $now.TimeStamperCertificate) { throw "$Path has no timestamp from $TimestampServer. Use another timestamp server, or -NoTimestamp." }
    '{0}  {1}' -f (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower(), $Path.Substring($Package.Length + 1)
}

# 3) signing
$scripts = @($manifest.Entries.PSBase.Keys | Where-Object { [IO.Path]::GetExtension($_) -in '.ps1', '.psm1', '.psd1' })
Write-Host "Signing $($scripts.Count) scripts with $($cert.Subject)..."
foreach ($rel in $scripts) { Set-Signature (Join-Path $Package ($rel -replace '/', '\')) }

# 4) the signed package must still pass the installer's check
$check = Test-VlcPackageTree $Package $manifest -Strict
if (-not $check.Ok) { throw "After signing, the installer would refuse: $(@($check.Problems | Select-Object -First 10) -join '; ')" }
Write-Host 'The signed package passes the installer''s check.' -ForegroundColor Green

# 5) optionally the interface DLL, built from this package
if ($InteropDll) {
    $InteropDll = [IO.Path]::GetFullPath($InteropDll)
    $built = Invoke-VlcTool 'WindowsPowerShell\v1.0\powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Package 'tools\Build-Interop.ps1'), '-OutputPath', $InteropDll)
    if ($built.ExitCode -ne 0) { throw "The interface DLL could not be built: $($built.Output)" }
    $params = @{ FilePath = $InteropDll; Certificate = $cert; HashAlgorithm = 'SHA256' }
    if (-not $NoTimestamp) { $params.TimestampServer = $TimestampServer }
    [void](Set-AuthenticodeSignature @params)
    $sig = Get-AuthenticodeSignature -LiteralPath $InteropDll
    if (-not $sig.SignerCertificate -or $sig.SignerCertificate.Thumbprint -ne $cert.Thumbprint) { throw "$InteropDll was not signed: $($sig.StatusMessage)" }
    Write-Host "Interface DLL built and signed: $InteropDll (install with Install.cmd -InteropDll `"$InteropDll`")" -ForegroundColor Green
    '{0}  {1}' -f (Get-FileHash -LiteralPath $InteropDll -Algorithm SHA256).Hash.ToLower(), $InteropDll
}
