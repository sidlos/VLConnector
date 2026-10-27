# VL Connector for PolyWorks - Acceptance checklist

Run these checks at the scanner before production use. Use a part with a finished PolyWorks template and an
AI Replay program. Tick each line; note deviations.

## Preparation

- [ ] Package checked: SHA-256 of the ZIP matches `SHA256SUMS.txt`; the fingerprint shown by Install.cmd matches.
- [ ] Installed with Install.cmd; the setup wizard opens; settings window opens from the Start menu.
- [ ] Setup page: all lines green (or understood warnings).
- [ ] VL Application shows its English user interface.

## Scenario A (PolyWorks on the scanner PC)

- [ ] Wizard, step PolyWorks, with PolyWorks|Inspector open: **Add to PolyWorks** - the tab "VL Connector" with
      the Measure button appears; **Undo** brings the previous ribbon back; add it again.
- [ ] Template has the property `VL program`.
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
- [ ] `programs.csv` filled (VL program -> workspace and template on the station).
- [ ] Station PC: wizard (PolyWorks station) > **Add to PolyWorks** - tab "VL Connector" with **VL Station**;
      it runs and shows the shared folder.
- [ ] Scanner PC: agent switched on (*Start with Windows*), icon in the notification area; after a Windows
      logon it starts by itself.
- [ ] Agent menu shows *station online*.
- [ ] AI Replay started **in VL** with a program from the list: after the last position the STL is exported
      (`Documents\VL Connector\Scans\<program>_<date>_<time>.stl`) and a notification says it was sent.
- [ ] The station evaluates it with the right template; the notification shows OK/NOK and the PDF opens.
- [ ] A second scanner PC (if any) does **not** open the reports of the first one.
- [ ] Shared folder unreachable during a scan: the STL waits in the outbox and is sent later.
- [ ] Station stopped: agent menu shows *station offline*; the scan is evaluated after the station starts.
- [ ] VL program missing in `programs.csv`: a notification "not evaluated" with the reason.

## Result

| | |
|---|---|
| Date, place | |
| VL Application version | |
| PolyWorks version | |
| VL Connector version | |
| Tested by | |
| Accepted for production | yes / no |
