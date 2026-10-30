@echo off
rem VL Connector for PolyWorks - installation on this PC (no administrator rights needed).
rem Checks the package, copies it to C:\ProgramData\VLConnector and creates the Start menu entries.
rem Options: -InstallDir <folder>  -AllUsers  -Verify  -Quiet   (see Install.ps1)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %ERRORLEVEL%
