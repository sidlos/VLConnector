@echo off
rem VL Connector for PolyWorks - removes VL Connector from this PC (scans, reports and PolyWorks data stay).
rem Options: -RemoveUserData  -Quiet   (see Uninstall.ps1)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
