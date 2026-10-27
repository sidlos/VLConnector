@echo off
rem VL Connector for PolyWorks - removes VL Connector from this PC (scans, reports and PolyWorks data stay).
rem Options: -RemoveUserData  -Quiet   (see Uninstall.ps1)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1" %*
