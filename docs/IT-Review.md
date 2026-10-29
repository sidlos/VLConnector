# VL Connector for PolyWorks - Notes for IT

This page explains what VL Connector runs, what it changes on a PC and why, so that IT can review it
before use. Everything is **readable source**: Windows PowerShell 5.1 scripts, PolyWorks macros (MSCL),
WPF window definitions (XAML) and JSON settings. There are **no compiled programs, DLLs or installers** in
the package. The few Windows functions that PowerShell cannot call directly are declared as C# source inside
the scripts (`Add-Type`) and compiled in memory by .NET at run time - the source is what runs.

Unofficial tool - not an official KEYENCE or InnovMetric product. License: MIT.

## 1. Components

| File | Runs | Purpose |
|---|---|---|
| `app\VLConnector.ps1` | when the user opens it (Start menu; the installer offers the wizard) | Settings window and setup wizard (WPF). |
| `app\Agent.ps1` | scenario B, scanner PC: at logon (only if switched on) or from the Start menu | Notification-area agent: starts the launcher in watch mode, sends STL files to the shared folder, opens the user's reports. |
| `app\VLReplay.ps1` | started by the PolyWorks Measure macro or by the agent (`-Watch`) | Drives AI Replay in the VL Application (or follows a replay the operator started) and exports the STL. |
| `app\polyworks\*.pwmacro` | inside PolyWorks, when the user presses the button | Evaluation, report, network station loop. |
| `app\polyworks\Get-MacroContext.ps1`, `Station-Step.ps1` | started by the macros | Read settings, move job files (PolyWorks macros cannot read JSON). |
| `app\lib\*.ps1` | loaded by the scripts above | Shared code. `Native.ps1` holds all Windows API declarations; `PolyWorksLayout.ps1` the PolyWorks COM declarations (used only by *Add to PolyWorks*). |
| `Install.ps1`, `Uninstall.ps1` | once, by the user | Installation, removal. |
| `tools\Sign-Scripts.ps1` | by IT, optional | Signs the scripts with your certificate (AllSigned environments). |

No service, scheduled task, driver or browser extension is installed. The only autostart is the optional
Startup-folder shortcut of the agent (per user, switched on in the settings window). While it waits for AI
Replay, the agent's launcher looks at the VL windows of the user's session about every 0.25 s (window list and
texts only).

## 2. PowerShell requirements

- **Windows PowerShell 5.1** (part of Windows 10/11) in **FullLanguage** mode. Constrained Language Mode
  (AppLocker/WDAC script enforcement) blocks `Add-Type` and WPF; VL Connector then stops with a clear message.
  Allow `C:\ProgramData\VLConnector\*` in your script rules, or sign the scripts (below).
- **Execution policy:** the Start menu entries and the PolyWorks macros start the scripts with
  `-ExecutionPolicy RemoteSigned`. The installer removes the "downloaded from the internet" mark from the
  installed files only (after checking them against the manifest). `Install.cmd` itself starts `Install.ps1`
  with `-ExecutionPolicy Bypass`, because the extracted package still carries that mark.
- **AllSigned:** run `tools\Sign-Scripts.ps1 -Thumbprint <your code signing certificate>` after the
  installation. Signing changes the files; keep the hash list it prints.
- A Group Policy execution policy always wins over the command line options above.

## 3. Windows interfaces used

VL has no programming interface for AI Replay, so `VLReplay.ps1` operates the VL window like a careful user,
but with documented Windows messages and UI Automation instead of mouse and keyboard input:

| Interface | Why |
|---|---|
| `EnumWindows`, `EnumChildWindows`, `GetWindowText`, `GetClassName`, `GetWindowThreadProcessId` | Find VL's windows and dialogs. |
| `SendMessageTimeout` (`WM_GETTEXT`, `WM_SETTEXT`) | Read dialog texts; enter the program path in VL's file dialog. |
| `PostMessage` (`BM_CLICK`, `WM_CLOSE`) | Press a dialog button (e.g. OK of the stage dialog when enabled); close a VL window when the user chose so. |
| `OpenProcess` (only `PROCESS_VM_OPERATION`, `PROCESS_VM_READ`), `VirtualAllocEx`, `ReadProcessMemory`, `VirtualFreeEx` with `WM_GETCONTROLNAME` | Read the internal control names of VL's WinForms windows (e.g. `_replayScanButton`), the standard technique of UI test tools, so buttons are found independent of their captions. Nothing is written into VL's memory by VL Connector; no code is injected. |
| UI Automation (`System.Windows.Automation`) | Open VL's menus (File > Export > STL, File > Save As) and read the AI Replay progress. |
| `SetForegroundWindow`, `AttachThreadInput`, `ShowWindow`, `mouse_event` with a 0-pixel move | Bring the PolyWorks or VL Connector window to the front after the scan, or minimize VL. Windows lets only the process with the last input change the foreground; the zero move gives that right without moving the mouse. |
| PolyWorks COM interface (`InnovMetric.PolyWorks.WorkspaceManager`: running modules, command center, run a macro script text) | Only when the user presses *Add to PolyWorks* (wizard or settings): sends PolyWorks' own macro commands to the PolyWorks|Inspector the user has open. PolyWorks is never started by VL Connector. |

VL Connector **reads** two VL files: `%APPDATA%\KEYENCE\VL-800 Series\VL Application\VLOperation.log` (to see
when AI Replay finished) and `%LOCALAPPDATA%\KEYENCE\...\RecentUsedTemplateFiles.xml` (to find programs).
It **never writes** KEYENCE files and never terminates VL.

## 4. What is written where

| Path | Content |
|---|---|
| `C:\ProgramData\VLConnector\` | The program (read and execute for all users; write only for administrators, SYSTEM and the installing user), the PolyWorks button files, `install-info.txt`. |
| `C:\ProgramData\VLConnector\machine.json` | Optional, created by IT: settings for all users of the PC. |
| `%APPDATA%\VLConnector\settings.json` | Settings of the user (settings window). |
| `%LOCALAPPDATA%\VLConnector\` | `logs\` (30 days), agent outbox and pending list, station work files, `polyworks-layout\` (backups of the PolyWorks visual layout made before *Add to PolyWorks*). |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\VL Connector agent.lnk` | Only if the user switches on *Start the agent with Windows*. |
| PolyWorks visual layout of the user | Only on *Add to PolyWorks*: a ribbon tab "VL Connector" with the button macro (a copy of `VLC_Measure_Button.pwmacro` or `VLC_Station_Button.pwmacro`). The previous layout is saved first and can be loaded back (*Undo*). |
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\VL Connector\` | Start menu entries. |
| `Documents\VL Connector\` | Scans (STL) and, in scenario B, the received reports. |
| PolyWorks workspace of the part | Measured pieces (copies of the template) and, by default, `Reports`/`Scans` folders next to the workspace. Templates are never modified. Pieces are removed only when the user chose to keep fewer pieces, and only pieces created by VL Connector in the same run. |
| Shared folder (scenario B) | `jobs`, `work`, `reports`, `processed`, `failed`, `status`, `programs.csv` - see [Protocol](Protocol.md). |

Nothing is written into the program folders of VL (`C:\Program Files\KEYENCE\...`) or PolyWorks
(`C:\Program Files\InnovMetric\...`): VL Connector installs no PolyWorks plug-in (DLL) and changes no PolyWorks
options. No registry keys are written. There is no internet access and no telemetry; the only network access is the
shared folder that the user configures for scenario B.

## 5. PolyWorks

The setup wizard can add the buttons to the PolyWorks ribbon by itself, only when the user presses *Add to
PolyWorks*: it sends documented PolyWorks macro commands (`WINDOW VISUAL_LAYOUT EXPORT`, `IMPORT_MACRO_SCRIPTS`,
`LOAD`) through the PolyWorks programming interface (COM) to the PolyWorks|Inspector the user has open, after
saving the current visual layout; it never starts PolyWorks itself. The Measure and Station buttons are small
macro files (also importable by hand) that the user adds to the PolyWorks ribbon once;
they call `app\polyworks\*.pwmacro`. The macros use only the documented PolyWorks macro language. The station
runs in a PolyWorks|Inspector of the station PC that a user starts; it keeps PolyWorks' own licensing (one
licence per PC).

## 6. Integrity of the package

- `SHA256SUMS.txt` next to the ZIP: SHA-256 of the ZIP and the package fingerprint.
- `MANIFEST.sha256` in the ZIP: SHA-256 of every file. The installer refuses to install when a file is
  missing or different, and shows the fingerprint (SHA-256 of the manifest) for comparison.
- `Install.cmd -Verify` in the program folder compares an installed copy with its manifest at any time.

## 7. Tests

`tests\Run-Tests.ps1 -Static -Unit` (in the source repository) checks syntax, encodings and forbidden content
and runs the unit tests of settings, file formats and the network protocol; `-Launcher` runs the launcher
against a simulated VL application (`tests\FakeVL`) in 20+ scenarios. None of them needs VL or PolyWorks.

## 8. Removal

Start menu > Uninstall VL Connector (or `Uninstall.cmd` in the program folder) removes the program folder and
the Start menu entries; `-RemoveUserData` also removes settings and logs. Remove the imported buttons in
PolyWorks by hand (File > Visual Layout > Customize).
