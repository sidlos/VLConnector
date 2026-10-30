<#
  Compiles the Windows and PolyWorks interfaces (app\interop\*.cs) into VLConnector.Interop.dll. The installer
  runs it in its own PowerShell process; an installed VL Connector loads only this DLL and never compiles.
    tools\Build-Interop.ps1 -OutputPath <install>\bin\VLConnector.Interop.dll
  Prints the source hash the DLL carries (the same value on every PC; the DLL file itself differs, because
  the compiler writes a new module id each time).
#>
param(
    [Parameter(Mandatory = $true)] [string]$OutputPath,
    [string]$SourceDir = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'app\lib\Interop.ps1')
if (-not $SourceDir) { $SourceDir = $script:VlcInteropSourceDir }
Build-VlcInterop -OutputPath $OutputPath -SourceDir $SourceDir
