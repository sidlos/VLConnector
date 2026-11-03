# Changelog

## 2.0.0 - 2026-11-03

The part template is the customer's measurement plan; VL Connector only supplies the scan.

**Templates need a change (breaking):** a template now needs exactly one data object for the scan and an active
measurement sequence (Play Inspection) without a step that acquires data (removed or ignored); the PDF is the
template's own formatted report; a piece template is recommended. Templates of 1.x without a sequence are refused
with a message that says what to add (User Guide, section 4). The demo template `VL-Polyworks-demo` shows a complete
plan.

- **Evaluation by the template's plan:** every scan becomes a new piece of the template project (`PIECE NEW`, named
  `<template>_<date>_<time>`), the scan replaces the data of the template's data object, and PolyWorks plays the
  template's measurement sequence (alignment, measurement, color map, report items). VL Connector's own
  pre-alignment and best-fit, color map and report are gone.
- **New pieces as PolyWorks recommends:** made from the template's piece template (project property
  `VL piece template` when there are several) and linked to it, so that PolyWorks can propagate later corrections of
  the plan to measured pieces; without a piece template from the open piece. The plan is checked in the new piece;
  a new piece without a usable plan is removed again.
- **Unsaved changes:** when the open piece has unsaved changes, the Measure button asks before the scan (*Save and
  measure* or *Cancel*); PolyWorks would save them silently when the new piece is added.
- A *Data Object* step of the sequence may also be ignored (Sequence Editor, Edit > Ignore) instead of removed.
- The automatic project update, which Play Inspection and linking need and which each piece keeps as its own
  setting, is switched on for the new piece during its plan and switched off again if it was off.
- **Report:** the PDF is the template's formatted report of the new piece (project property `VL report` picks one
  when there are several); without a formatted report there is no PDF, the CSV is written anyway. The CSV header
  names the plan instead of the alignment.
- **Measure button:** the new piece stays open and the **Control Reviewer** shows its controls; a 1.x copy of a
  template still leads back to its template.
- **Keep measured pieces:** a piece that is not kept is marked and removed at the next measurement of the part, so it
  can be reviewed first; Measure button and station no longer delete projects.
- **PolyWorks options:** the questions of a new piece, of the data replacement and the Play Inspection interface are
  answered by setting PolyWorks' options for the moment of the evaluation; the user's values are restored right after
  (also the option *Nonupdatable reports*, which linking a piece changes).
- The control data between the macro and `Complete-Evaluation.ps1` is `VLC-CONTROLS-2` (plan status instead of
  alignment and extraction status). The setting `polyworks.colorScaleMm` and the parameter `COLOR_SCALE` stay for
  compatibility but are not used any more.

## 1.0.0 - 2026-11-02

First stable release: the release candidates (below) hardened after an enterprise IT safety audit of 1.0.0-rc10
(84 findings) and tested live at the scanner (installation, Measure with the stage policy off and on, a stored NOK
scan, the network scenario on one PC, removal and new installation).

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
  an unlocked console (no remote desktop), and only after a red warning window and a sound are on screen; the
  same warning comes already before AI Replay starts; every automatic answer is in the Event Log, a policy
  change with its value before and after. The template's values reach the launcher in a launch file, never on
  the command line.
- **Verdict:** computed fail-closed in tested PowerShell: OK only for PolyWorks' documented results inside the
  tolerance; not measured or unknown results are NOK; no verdict after a failed alignment or measurement or for
  a replaced STL (checked by its SHA-256). CSV as UTF-8 with BOM, protected against spreadsheet formulas.
- **Launcher:** language mode checked first; heartbeat to the Measure macro ("could not start", "stopped
  unexpectedly"); only expected dialogs (the STL Save As dialog is no longer taken for the program); program
  names exact (`Part.A`); no second VL window next to a VL that is busy (a new one only next to VL windows that
  show earlier scans); export retries with a new name; after-export errors no longer turn an OK into an error;
  full path of `powershell.exe` everywhere.
- **Network:** durable inbox and a single writer of the outbox; five send attempts, then set aside with a
  notification; reports wait for their complete PDF; a station never loses a claimed job and never overwrites
  an OK result; stale jobs are reported; the Measurement Programs List is validated; liveness by a heartbeat
  counter on the scanner PC's own clock; *station paused*; NOK keeps the tray red until it is seen.
- **Trust without a personal signature:** releases built by GitHub Actions from a tag with `SHA256SUMS.txt` and
  an optional build attestation; `tools\Sign-Package.ps1` for IT replaces `Sign-Scripts.ps1`.
- **Names and windows:** the Start menu has only *VL Connector* (the settings window) and *Uninstall VL Connector*;
  the part in the notification area is shown as *VL Connector* (the Startup shortcut too, renamed from *VL Connector
  agent*); started again while it runs, it opens the settings window.
- **PolyWorks button:** *Add to PolyWorks* finds the ribbon in any language of PolyWorks; a ribbon nobody has changed
  yet (PolyWorks does not export it) gets a clear message with the one step to do by hand instead of an error.
- **Event log:** only the installation the event source was registered for writes to it; a copy elsewhere (such as a
  test copy on a PC where VL Connector is installed) cannot leave entries that look like changes of the PC. Events of the
  agent's automatic answers name the program chosen in VL.
- **Package folder:** only *Install.cmd* is there to open; the scripts and *Uninstall.cmd* are in `setup\` (Start menu >
  Uninstall VL Connector). The uninstaller removes only a folder the installer made, never an unpacked package.
- Documentation: Notes for IT rewritten (trust model, policy, safety, what security software sees, rights of
  the shared folder), Protocol, User guide, Acceptance checklist with safety checks and sign-off.

## 1.0.0-rc1 to 1.0.0-rc10 - 2026-10-27 to 2026-10-29

Release candidates for a closed group of users.

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
