# Changelog

## 1.0.0 - 2026-10-27

First release for a closed group of users.

- **Scenario A** (PolyWorks on the scanner PC): Measure button in PolyWorks - AI Replay in VL, automatic STL
  export, evaluation against the part template (pre-alignment, best-fit, all controls, color map), A4 PDF report
  with OK/NOK verdict and CSV, optional removal of measured pieces, optional PDF opening.
- **Scenario B** (PolyWorks on another PC): Scan window on the scanner PC, shared network folder with job
  protocol (outbox, hash check, only own reports opened), PolyWorks station running in its own Inspector.
- Settings window with status check, report layout builder, PolyWorks button files, network test and support ZIP.
- Launcher options: replay mode (High speed / Standard / Ask), export right after the scan, automatic
  confirmation of the stage dialogs, VL window after the export (leave, minimize, close, save and close with
  STL re-check), options per part.
- Installer without administrator rights (manifest check, package fingerprint, permissions, Start menu),
  uninstaller, release build with SHA-256, script signing helper for IT.
- Documentation: user guide, notes for IT, protocol, acceptance checklist.
