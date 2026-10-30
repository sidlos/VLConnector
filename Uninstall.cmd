@echo off
setlocal
rem VL Connector for PolyWorks - removes VL Connector from this PC (scans, reports and PolyWorks data stay).
rem Windows asks for administrator rights. Options: -RemoveUserData  -Quiet   (see Uninstall.ps1)
set "VLC_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "VLC_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
set "VLC_DIR=%~dp0"
rem not in the program folder: a current folder there would keep it from being deleted
cd /d "%SystemRoot%"
"%VLC_PS%" -NoProfile -ExecutionPolicy Bypass -File "%VLC_DIR%Uninstall.ps1" %*
exit /b %ERRORLEVEL%