# VL Connector for PolyWorks - Acceptance checklist

Run these checks at the scanner before production use. Use a part with a finished PolyWorks template and an
AI Replay program. Tick each line; note deviations.

## Preparation

- [ ] Package checked: SHA-256 of the ZIP matches `SHA256SUMS.txt`; the fingerprint shown by Install.cmd matches.
- [ ] Installed with Install.cmd; settings window opens from the Start menu.
- [ ] Setup page: all lines green (or understood warnings).
- [ ] VL Application shows its English user interface.

## Scenario A (PolyWorks on the scanner PC)

- [ ] Template has the property `VL program`; Measure button imported into the PolyWorks ribbon.
- [ ] **Measure** in the template: VL starts AI Replay with the right program and mode.
- [ ] Progress window in PolyWorks shows the VL steps; scanning works as usual.
- [ ] After the last position: STL exported, PolyWorks comes to the front, evaluation runs.
- [ ] Verdict message and PDF: cover page with color map and OK/NOK, control table, views; CSV next to it.
- [ ] Piece `<template>_<date>_<time>` saved; the template is unchanged.
- [ ] **Measure** again while the piece is open: starts from the template.
- [ ] **Cancel** in the progress window during the scan: the run stops with "cancelled".
- [ ] Scanner disconnected: clear message "The scanner is not connected", no hanging.
- [ ] Optional: *Confirm stage movement automatically* - the stage dialogs are answered (watch the safety!).
- [ ] Optional: *VL window after the export* = Close / Save and close - VL closes only after the export.
- [ ] Optional: keep pieces *Only NOK* - an OK piece is removed, the PDF stays.
- [ ] A NOK part (or tightened tolerance) gives a red NOK report.

## Scenario B (PolyWorks on another PC)

- [ ] Shared folder entered on both PCs; **Test** is green on both.
- [ ] `parts.csv` filled; the part appears in the Scan window.
- [ ] Station button imported on the station PC; **VL Station** runs and shows the shared folder.
- [ ] Scan window shows *Station online*.
- [ ] **Start scan**: VL starts AI Replay; the bar shows the VL steps.
- [ ] After the scan: *Sending* -> *Waiting* -> OK/NOK; the PDF opens on the scanner PC.
- [ ] A second scanner PC (if any) does **not** open the reports of the first one.
- [ ] Shared folder unreachable during a scan: the STL waits in the outbox and is sent later.
- [ ] Station stopped: Scan window shows *Station offline*; the job is evaluated after the station starts.
- [ ] Part missing in `parts.csv` on the station: the scan ends with a clear error in the Scan window.

## Result

| | |
|---|---|
| Date, place | |
| VL Application version | |
| PolyWorks version | |
| VL Connector version | |
| Tested by | |
| Accepted for production | yes / no |
