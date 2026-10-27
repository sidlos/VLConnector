@echo off
rem AI Replay ve VL-800 se zadanym programem, po dilu STL do C:\PolyWorks\Vstup + znacka <program>.hotovo.
rem Pouziti: vl_replay.cmd <program nebo cesta k .vld4> [-Rezim Standard] [-Nanecisto] [-JenExport] ...
rem Spoustet pod uctem, pod kterym bezi VL. Navratovy kod: 0 OK, 1 chyba, 2 zruseno, 3 parametry, 4 uz bezi.
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0VLReplay.ps1" %*
exit /b %ERRORLEVEL%
