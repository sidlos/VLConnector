@echo off
rem VL Connector for PolyWorks - opens the settings window. Other windows: VLConnector.cmd -Show Scan / -Show Station
start "" powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "%~dp0VLConnector.ps1" %*
