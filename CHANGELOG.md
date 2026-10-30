# Changelog

## 1.0.0-rc11 - 2026-10-30

Hardening after an enterprise IT safety audit of 1.0.0-rc10 (84 findings).

**Note for users of 1.0.0-rc10:** the installation moves to `C:\Program Files\VLConnector` and needs
administrator rights once. *Confirm stage movement automatically* is no longer a setting of a user or a template:
after the update it is **off** for everybody until an administrator switches it on for the PC (the installer
lists the users who had it on). PolyWorks buttons and shortcuts made for `C:\ProgramData\VLConnector` keep
working through forwarders.

- **Installation:** as administrator into `C:\Program Files\VLConnector` with an administrator-only ACL; the
  package is staged, checked against its manifest (also scripts IT signed) and swapped in, the previous version
  stays in `.old`; refuses the package folder as install folder; exit code 1618 while VL Connector is in use;
  silent installation with `-ConfirmStageMotion` and `-MachineSettings`; Start menu for all users; event source
  "VL Connector". The uninstaller removes everything synchronously and checks it.
- **No compiler at run time:** the Windows and PolyWorks interfaces are built once by the installer into
  `bin\VLConnector.Interop.dll`, which carries the SHA-256 of its source; IT can bring its own signed DLL.
- **Settings policy:** four checked layers (product defaults, machine defaults, user, machine policy); keys only
  an administrator may set; values checked against a schema; the settings window and the wizard save only real
  changes; changes are logged, machine changes also in the Event Log. *Change (administrator)* button.
- **Stage rotation:** only by the machine policy, only VL's two exact questions on a tested VL version, only at
  an unlocked console (no remote desktop), and only after a red warning window and a sound are on screen; every
  automatic answer is in the Event Log. The template's values reach the launcher in a launch file, never on the
  command line.
- **Verdict:** computed fail-closed in tested PowerShell: OK only for PolyWorks' documented results inside the
  tolerance; not measured or unknown results are NOK; no verdict after a failed alignment or measurement or for
  a replaced STL (checked by its SHA-256). CSV as UTF-8 with BOM, protected against spreadsheet formulas.
- **Launcher:** language mode checked first; heartbeat to the Measure macro ("could not start", "stopped
  unexpectedly"); only expected dialogs (the STL Save As dialog is no longer taken for the program); program
  names exact (`Part.A`); no second VL window; export retries with a new name; after-export errors no longer
  turn an OK into an error; full path of `powershell.exe` everywhere.
- **Network:** durable inbox and a single writer of the outbox; five send attempts, then set aside with a
  notification; reports wait for their complete PDF; a station never loses a claimed job and never overwrites
  an OK result; stale jobs are reported; the Measurement Programs List is validated; liveness by a heartbeat
  counter on the scanner PC's own clock; *station paused*; NOK keeps the tray red until it is seen.
- **Trust without a personal signature:** releases built by GitHub Actions from a tag with `SHA256SUMS.txt` and
  an optional build attestation; `tools\Sign-Package.ps1` for IT replaces `Sign-Scripts.ps1`.
- Documentation: Notes for IT rewritten (trust model, policy, safety, what security software sees, rights of
  the shared folder), Protocol, User guide, Acceptance checklist with safety checks and sign-off.

## 1.0.0 - 2026-10-27

First release for a closed group of users.

- **Scenario A** (PolyWorks on the scanner PC): Measure button in PolyWorks - AI Replay in VL, automatic STL
  export, evaluation against the part template (pre-alignment, best-fit, all controls, color map), OK/NOK
  verdict, PDF report in PolyWorks' standard layout and CSV, optional removal of measured pieces, optional PDF
  opening.
- **Scenario B** (PolyWorks on another PC): the operator scans with AI Replay in VL as usual; the VL Connector
  agent (notification area, optionally started with Windows) exports the STL named after the .vld4 program,
  sends it to a shared network folder (outbox, hash check) and opens the returned PDF (only own scans). The
  PolyWorks station runs in its own Inspector and picks the template by the VL program (Measurement Programs List).
- Setup wizard (opens after the installation): scenario, scanning options, shared folder and agent,
  and **Add to PolyWorks** - a ribbon tab "VL Connector" with the Measure or Station button in PolyWorks|Inspector,
  added with PolyWorks' own macro commands after saving the visual layout (undo possible).
- Settings window with status check, PolyWorks button files, network test and support ZIP.
- Launcher options: replay mode (High speed / Standard / Ask), export right after the scan, automatic
  confirmation of the stage dialogs, VL window after the export (leave, minimize, close, save and close with
  STL re-check), options per part.
- Installer without administrator rights (manifest check, package fingerprint, permissions, Start menu),
  uninstaller, release build with SHA-256, script signing helper for IT.
- Documentation: user guide, notes for IT, protocol, acceptance checklist.

Fixed after the live test at the scanner (2026-10-29, 1.0.0-rc4):
- Measure: **Cancel** in the progress window no longer stops on the PolyWorks message "No progress window is
  currently active"; the cancel reaches VL Connector at once and a short note says that AI Replay may still
  run in VL.
- Network scenario: the agent reads the program chosen in VL's program dialog until the dialog closes (a
  double-clicked program was missed). Without it, only a program that VL applied during this scan is used
  (VL's list of recent programs is oldest first; the oldest entry was taken before). A scan whose program is
  not known is not sent, so the station never evaluates it with a wrong template.
- Station: **Stop** stays usable after a job that could not be evaluated (the progress window was left
  disabled).
- PolyWorks progress windows show names with "_" correctly (they were doubled).

1.0.0-rc8 (2026-10-29):
- New VL Connector logo, our own drawing: the letters "VL" in slate grey with a thin white outline (readable on a
  dark taskbar). Used for the shortcuts, the notification area, the windows, the PolyWorks button and the
  screenshots in the documentation; `tools\Make-Icons.ps1` draws all icon files from one drawing.
- The PolyWorks button icon is a small vector SVG: PolyWorks draws only vector SVG icons of at most 32767 bytes.
- **Add to PolyWorks** again (wizard, settings) takes the newly imported button. Before, PolyWorks named the new
  macro "<name> (2)", "(3)", ..., the tab kept the old button and the copies piled up in the PolyWorks macro list;
  now earlier copies that no button uses are removed. It also works more than once in the same Inspector session
  (PolyWorks refuses a second import of the same macro name there; the button then gets a name with a time stamp).

1.0.0-rc9 (2026-10-29):
- **Add to PolyWorks** shows the current logo on the button also in a PolyWorks|Inspector that has been open for
  a long time. PolyWorks could give the new button the picture slot of an earlier button and keep the old picture;
  the button then gets its picture from VL Connector in a slot of its own.

1.0.0-rc10 (2026-10-29):
- The VL Connector report layouts are gone (settings window, setup wizard, installer, `Make-ReportLayouts.ps1`):
  they suited one demo part, and every company reports its parts its own way. The PDF uses PolyWorks' standard
  report layout; the OK/NOK verdict stays in the PolyWorks message, the agent notification and the CSV. An
  update removes the `layouts` folder of earlier versions. Macro protocol: `LAYOUT_DIR` is no longer in the
  Get-MacroContext output nor in the VLC_Evaluate parameters.
- The programs list of the network scenario is now called **Measurement Programs List**.
- Support text: VL Connector is not official software; you can try contacting your local sales engineer.
