@echo off
rem VL Connector for PolyWorks - starts AI Replay in the VL-800 with the given program; after the part
rem the STL goes to the output folder and the marker <program>.done is written next to it.
rem Usage: VLReplay.cmd <program or path to the .vld4> [-Mode Standard] [-DryRun] [-ExportOnly] ...
rem Run it under the Windows account VL runs under. Exit code: 0 OK, 1 error, 2 cancelled, 3 parameters, 4 already running.
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0VLReplay.ps1" %*
exit /b %ERRORLEVEL%