@echo off
setlocal
rem VL Connector for PolyWorks - installation on this PC (Windows asks for administrator rights).
rem Checks the package, installs it to C:\Program Files\VLConnector and creates the Start menu entries.
rem Options: -InstallDir <folder>  -ConfirmStageMotion On or Off  -MachineSettings <file>  -InteropDll <file>
rem          -Force  -Quiet  -Verify   (see Install.ps1)
rem The 64-bit Windows PowerShell also when a 32-bit program (e.g. a deployment agent) starts this file.
set "VLC_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "VLC_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%VLC_PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %ERRORLEVEL%