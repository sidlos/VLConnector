# VL Connector for PolyWorks - Acceptance checklist

Run these checks at the scanner before production use. Use a part with a finished PolyWorks template and an
AI Replay program. Tick each line; note deviations.

## Installation and trust (IT)

- [ ] Package checked: SHA-256 of the ZIP matches `SHA256SUMS.txt` of the release; the fingerprint shown by
      Install.cmd matches; optional: `gh attestation verify <zip> --repo <owner>/<repo>`.
- [ ] Installed with Install.cmd (Windows asked for administrator rights) to `C:\Program Files\VLConnector`; the
      setup wizard opens; the settings window opens from the Start menu.
- [ ] `Install.cmd -Verify` in the program folder: files, permissions and interface DLL OK.
- [ ] A standard user cannot change files in `C:\Program Files\VLConnector` (try to save a copy of a file there).
- [ ] PC with 1.0.0-rc10: the old buttons in PolyWorks still work; `C:\ProgramData\VLConnector` holds only the
      forwarders (`VLConnector-moved.txt`).
- [ ] Event Viewer > Windows Logs > Application: source *VL Connector* exists.
- [ ] Application control (AppLocker/WDAC) or AllSigned in use: VL Connector runs (Setup page: *PowerShell full
      language mode*); signed packages: `tools\Sign-Package.ps1` was used.
- [ ] Setup page: all lines green (or understood warnings).
- [ ] VL Application shows its English user interface.

## Safety: stage rotation

- [ ] **Policy off (default):** Measure with a part - VL's stage questions wait for the operator; VL Connector
      never answers them. The log shows no `Confirmed:` line.
- [ ] A user cannot switch it on: settings window > Scanning shows *Off* without a switch; the template option
      `-ConfirmStageMotion On` stops the scan with a message.
- [ ] **Policy on** (*Change (administrator)*, Windows asks for administrator rights; Event Viewer shows event
      1000 with the change): Measure - before each automatic OK the red warning window appears with a sound,
      without covering VL's question and without taking the keyboard focus; event 1100 per answer.
- [ ] Policy on, screen locked (Windows+L) during the scan: VL Connector does not answer; event 1101 names the
      reason; after unlocking the operator answers.
- [ ] Policy switched off during a scan: the next question waits for the operator.
- [ ] Safety officer informed: who may switch the policy on, and that the stage then rotates without a person
      confirming it.

## Scenario A (PolyWorks on the scanner PC)

- [ ] Wizard, step PolyWorks, with PolyWorks|Inspector open: **Add to PolyWorks** - the tab "VL Connector" with
      the Measure button appears; **Undo** brings the previous ribbon back; add it again.
- [ ] Template has the property `VL program`.
- [ ] **Measure** in the template: VL starts AI Replay with the right program and mode.
- [ ] Progress window in PolyWorks shows the VL steps; scanning works as usual.
- [ ] After the last position: STL exported, PolyWorks comes to the front, evaluation runs.
- [ ] Verdict message (OK/NOK) and PDF in PolyWorks' standard layout: control table, color map views; CSV next to
      it opens in Excel with correct characters; its header names the STL and its SHA-256.
- [ ] Piece `<template>_<date>_<time>` saved; the template is unchanged.
- [ ] **Measure** again while the piece is open: starts from the template.
- [ ] **Cancel** in the progress window during the scan: the run stops with "cancelled".
- [ ] Scanner disconnected: clear message "The scanner is not connected", no hanging.
- [ ] VL busy (another AI Replay open in VL): clear message, no second VL window.
- [ ] Optional: *VL window after the export* = Close / Save and close - VL closes only after the export.
- [ ] Optional: keep pieces *Only NOK* - an OK piece is removed, the PDF stays.
- [ ] A NOK part (or tightened tolerance) gives the verdict NOK; a control without a result gives NOK
      (*not measured*), never OK.

## Scenario B (PolyWorks on another PC)

- [ ] Shared folder with the rights of the Notes for IT (section 9); **Test** is green on both PCs (each checks
      its role).
- [ ] Measurement Programs List (`programs.csv`) filled (VL program -> workspace and template on the station);
      the Setup page shows no unused lines.
- [ ] Station PC: wizard (PolyWorks station) > **Add to PolyWorks** - tab "VL Connector" with **VL Station**;
      it runs and shows the shared folder.
- [ ] Scanner PC: agent switched on (*Start with Windows*), icon in the notification area; after a Windows
      logon it starts by itself.
- [ ] Agent menu shows *station online*.
- [ ] AI Replay started **in VL** with a program from the list: after the last position the STL is exported
      (`Documents\VL Connector\Scans\<program>_<date>_<time>.stl`) and a notification says it was sent.
- [ ] The station evaluates it with the right template; the notification shows OK/NOK and the PDF opens; after a
      NOK the icon stays red until *Mark the NOK result as seen*.
- [ ] A second scanner PC (if any) does **not** open the reports of the first one.
- [ ] Shared folder unreachable during a scan: the STL waits in the outbox and is sent later.
- [ ] Station stopped: agent menu shows *station offline*; the scan is evaluated after the station starts.
- [ ] `programs.csv` without its header line: the station shows *Paused*, the agent *station paused*; after the
      correction it continues.
- [ ] VL program missing in the Measurement Programs List: a notification "not evaluated" with the reason.

## Result

| | |
|---|---|
| Date, place | |
| VL Application version | |
| PolyWorks version | |
| VL Connector version, package fingerprint | |
| Stage confirmation policy (on/off), decided by | |
| Tested by | |
| IT sign-off (installation, rights, application control) | |
| Safety officer sign-off (stage rotation) | |
| Accepted for production | yes / no |
