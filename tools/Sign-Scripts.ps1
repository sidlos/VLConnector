<#
  Sign-Scripts.ps1 - for IT: signs the PowerShell scripts of an installed VL Connector with your own code
  signing certificate, so they also run where the PowerShell execution policy is AllSigned.
    Sign-Scripts.ps1 -Thumbprint <certificate thumbprint> [-InstallDir C:\ProgramData\VLConnector] [-TimestampServer <url>]
  The certificate must be in Cert:\CurrentUser\My or Cert:\LocalMachine\My and be trusted on the PCs.
  Signing changes the files, so "Install.cmd -Verify" then reports them as changed; keep a list of the
  signed hashes (this script prints it) for your own records.
#>
param(
    [Parameter(Mandatory = $true)] [string]$Thumbprint,
    [string]$InstallDir = (Join-Path $env:ProgramData 'VLConnector'),
    [string]$TimestampServer = ''
)

$ErrorActionPreference = 'Stop'
$cert = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
if (-not $cert) { throw "No code signing certificate with thumbprint $Thumbprint was found." }
$scripts = Get-ChildItem -LiteralPath $InstallDir -Recurse -Include '*.ps1', '*.psm1', '*.psd1'
foreach ($s in $scripts) {
    $params = @{ FilePath = $s.FullName; Certificate = $cert; HashAlgorithm = 'SHA256' }
    if ($TimestampServer) { $params.TimestampServer = $TimestampServer }
    $r = Set-AuthenticodeSignature @params
    '{0,-12} {1}  {2}' -f $r.Status, (Get-FileHash -LiteralPath $s.FullName -Algorithm SHA256).Hash.ToLower(), $s.FullName
}
