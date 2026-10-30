<#
  Background work of the VL Connector windows: lib\Ui.ps1 (Start-UiJob) runs this file in its own runspace, so a
  slow network folder does not freeze a window. It runs as a file, not as script text, so an application control
  policy that trusts the program folder trusts it too.
    -Work Status                          the status items of the Setup page
    -Work ShareTest -Path p -Role r       the test of the shared folder for a scanner PC or a station
#>
param(
    [Parameter(Mandatory = $true)] [ValidateSet('Status', 'ShareTest')] [string]$Work,
    [string]$Path = '',
    [ValidateSet('Scanner', 'Station')] [string]$Role = 'Station'
)

$ErrorActionPreference = 'Stop'
switch ($Work) {
    'Status' {
        foreach ($lib in 'Settings', 'PolyWorksSetup', 'Share', 'Prerequisites') { . (Join-Path $PSScriptRoot "$lib.ps1") }
        $state = Get-VlcSettingsState
        Get-VlcStatusItems $state.Settings $state.Warnings
    }
    'ShareTest' {
        . (Join-Path $PSScriptRoot 'Share.ps1')
        Test-VlcShare $Path $Role
    }
}
