# Changelog

## 1.0.0 - 2026-10-27

First release for a closed group of users.

- **Scenario A** (PolyWorks on the scanner PC): Measure button in PolyWorks - AI Replay in VL, automatic STL
  export, evaluation against the part template (pre-alignment, best-fit, all controls, color map), A4 PDF report
  with OK/NOK verdict and CSV, optional removal of measured pieces, optional PDF opening.
- **Scenario B** (PolyWorks on another PC): the operator scans with AI Replay in VL as usual; the VL Connector
  agent (notification area, optionally started with Windows) exports the STL named after the .vld4 program,
  sends it to a shared network folder (outbox, hash check) and opens the returned PDF (only own scans). The
  PolyWorks station runs in its own Inspector and picks the template by the VL program (programs list).
- Setup wizard (opens after the installation): scenario, scanning options, report layouts, shared folder and agent,
  and **Add to PolyWorks** - a ribbon tab "VL Connector" with the Measure or Station button in PolyWorks|Inspector,
  added with PolyWorks' own macro commands after saving the visual layout (undo possible).
- Settings window with status check, report layout builder, PolyWorks button files, network test and support ZIP.
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
