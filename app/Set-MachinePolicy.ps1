<#
  Set-MachinePolicy.ps1 - VL Connector for PolyWorks: settings the administrator sets for all users of this PC
  (machine.json in the program folder, section "policy"; users see them read-only). Needs administrator rights:
  the "Change (administrator)" buttons of the settings window and the setup wizard start it through Windows'
  administrator prompt (UAC).
    Set-MachinePolicy.ps1 -Show StageMotion            dialog: automatic confirmation of the stage rotation
    Set-MachinePolicy.ps1 -Show VlExe                  dialog: the VL Application that VL Connector starts
    Set-MachinePolicy.ps1 -ConfirmStageMotion On|Off   without a dialog (deployment by IT)
    Set-MachinePolicy.ps1 -VlExe <path>                without a dialog
  Every change goes to the Windows event log (Application, source "VL Connector", event 1000) and to the log
  %LOCALAPPDATA%\VLConnector\logs\Settings_<date>.log of the administrator account.
  Exit code: 0 done (or nothing to change), 1 error, 2 cancelled, 5 no administrator rights.
#>
param(
    [ValidateSet('', 'StageMotion', 'VlExe')] [string]$Show = '',
    [ValidateSet('', 'On', 'Off')] [string]$ConfirmStageMotion = '',
    [string]$VlExe = '',
    [string]$RequestedBy = ''
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path $PSScriptRoot 'lib\LanguageCheck.ps1') -Caller Policy -Mode $ExecutionContext.SessionState.LanguageMode -Show:([bool]$Show)
    exit 1
}

$ErrorActionPreference = 'Stop'
foreach ($lib in 'Settings', 'Log') { . (Join-Path $PSScriptRoot "lib\$lib.ps1") }
[void](Initialize-VlcLog 'Policy')
if ($Show) { Add-Type -AssemblyName PresentationFramework }
$title = 'VL Connector - settings for all users of this PC'

# A message box for the dialogs, the console for IT deployment. Returns the button pressed.
function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    Write-VlcLog ($Text -replace '\s+', ' ')
    if (-not $Show) { Write-Host $Text; return 'OK' }
    return [string][System.Windows.MessageBox]::Show($Text, $title, $Buttons, $Icon)
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [void](Show-Message 'Administrator rights are needed to change the settings for all users of this PC. Use the "Change (administrator)" button, or start this script as administrator.' 'OK' 'Error')
    exit 5
}

try {
    $set = @{}
    $settings = Read-VlcSettings
    switch ($Show) {
        'StageMotion' {
            if ($settings.vl.confirmStageMotion) {
                $answer = Show-Message ("The automatic confirmation of the stage rotation is ON for all users of this PC.`n`n" +
                    "Switch it OFF? The operators then confirm every stage rotation in VL themselves.") 'YesNo' 'Question'
                if ($answer -ne 'Yes') { exit 2 }
                $set['vl.confirmStageMotion'] = $false
            }
            else {
                $answer = Show-Message ("Switch ON the automatic confirmation of the stage rotation for all users of this PC?`n`n" +
                    "When VL asks 'The stage will rotate. Continue?' or 'Return the stage to the origin?', VL Connector then answers OK itself. " +
                    "A warning window and a sound appear each time, and every confirmation is written to the Windows event log.`n`n" +
                    "VL Connector confirms only on tested VL versions and only while the PC is unlocked and used at its own screen, not over Remote Desktop.`n`n" +
                    "Switch it on only when the scanner is safeguarded: nothing may block the stage and nobody may reach into the scanner while it turns.") 'YesNo' 'Warning'
                if ($answer -ne 'Yes') { exit 2 }
                $set['vl.confirmStageMotion'] = $true
            }
        }
        'VlExe' {
            $dlg = New-Object Microsoft.Win32.OpenFileDialog
            $dlg.Title = 'VL Application for all users of this PC'
            $dlg.Filter = 'VL Application (VLApplication4.exe)|VLApplication4.exe|Programs (*.exe)|*.exe'
            $current = [string]$settings.vl.exe
            if ($current -and (Test-Path -LiteralPath (Split-Path $current))) { $dlg.InitialDirectory = Split-Path $current }
            if (-not $dlg.ShowDialog()) { exit 2 }
            $set['vl.exe'] = $dlg.FileName
        }
        default {
            if ($ConfirmStageMotion) { $set['vl.confirmStageMotion'] = $ConfirmStageMotion -eq 'On' }
            if ($VlExe) {
                if (-not (Test-Path -LiteralPath $VlExe -PathType Leaf)) { throw "$VlExe does not exist." }
                $set['vl.exe'] = [IO.Path]::GetFullPath($VlExe)
            }
            if (-not $set.Count) { throw 'Nothing to change. Use -Show StageMotion, -Show VlExe, -ConfirmStageMotion On|Off or -VlExe <path>.' }
        }
    }
    $changes = @(Set-VlcMachineSettings -Section policy -Set $set -RequestedBy $RequestedBy)
    if ($changes.Count) { [void](Show-Message ("Changed for all users of this PC:`n`n" + ($changes -join "`n"))) }
    else { [void](Show-Message 'Nothing changed: the setting already had this value.') }
    exit 0
}
catch {
    [void](Show-Message "Nothing was changed: $($_.Exception.Message)" 'OK' 'Error')
    exit 1
}
