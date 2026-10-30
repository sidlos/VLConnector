@echo off
rem VL Connector for PolyWorks - removes VL Connector from this PC (scans, reports and PolyWorks data stay).
rem Windows asks for administrator rights. Options: -RemoveUserData  -Quiet   (see Uninstall.ps1)
rem It continues from a copy in %TEMP%: cmd.exe reads a batch file line by line, and this one is deleted with the
rem program folder (the copy is started without CALL, so cmd.exe never comes back to this file).
if not defined VLC_UNINSTALL_DIR (
    set "VLC_UNINSTALL_DIR=%~dp0"
    copy /y "%~f0" "%TEMP%\VLConnector-Uninstall.cmd" >nul
    "%TEMP%\VLConnector-Uninstall.cmd" %*
)
setlocal
set "VLC_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "VLC_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
rem not in the program folder: a current folder there would keep it from being deleted
cd /d "%SystemRoot%"
"%VLC_PS%" -NoProfile -ExecutionPolicy Bypass -File "%VLC_UNINSTALL_DIR%Uninstall.ps1" %*
set "VLC_CODE=%ERRORLEVEL%"
endlocal & set "VLC_UNINSTALL_DIR=" & exit /b %VLC_CODE%