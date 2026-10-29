# VL Connector for PolyWorks

VL Connector links **KEYENCE VL-800 AI Replay** scans with **PolyWorks|Inspector** evaluation and reports:
press one button, scan the part in VL as usual, and get a clear OK/NOK verdict with a PDF report.

> **Unofficial tool.** It is not an official KEYENCE or InnovMetric product and is not covered by their
> warranty or support. KEYENCE, VL-800 and PolyWorks are trademarks of their respective owners.

## Two ways to work

| | Scenario A: PolyWorks on the scanner PC | Scenario B: PolyWorks on another PC |
|---|---|---|
| Start | **Measure** button in PolyWorks (the template knows its VL program) | AI Replay in VL as usual - the **VL Connector agent** waits in the background |
| Scan | AI Replay in VL, STL exported automatically | the same; the STL is named after the .vld4 program plus date and time |
| Evaluation | in the same PolyWorks | a PolyWorks **station** takes the STL from a shared network folder and picks the template by the VL program |
| Report | PDF and CSV, opened automatically | the PDF comes back and opens only on the PC that scanned the part |

For each part, a PolyWorks template holds the CAD, alignment and controls. VL Connector copies the template into a
measured piece, aligns the scan to the CAD, measures all controls and creates the report. The template itself
is never changed.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 in FullLanguage mode (standard on Windows).
- KEYENCE VL-800 with VL Application 4.6 (tested: 4.6.1.6002), English user interface.
- PolyWorks Metrology Suite 2026 (Inspector) on the evaluating PC.
- Scenario B: a shared network folder that the scanner PCs and the station can read and write.
- No administrator rights are needed. Nothing is copied into the program folders of VL or PolyWorks
  (VL Connector is not a PolyWorks plug-in).

## Install

1. Check the download: the SHA-256 of the ZIP must match `SHA256SUMS.txt` (PowerShell: `Get-FileHash <zip>`).
2. Extract the ZIP and run **Install.cmd**. It checks every file, shows the package fingerprint (compare it
   with the one you received), installs to `C:\ProgramData\VLConnector` and creates the Start menu entries.
3. The **setup wizard** opens at the end (later: Start menu > VL Connector > Setup wizard). It asks for the
   scenario and the main options and **adds the VL Connector tab with the Measure or
   Station button to PolyWorks** (PolyWorks|Inspector must be open; the PolyWorks layout is saved before and
   can be restored). The settings window only holds settings (modes, options, start with Windows); scanning
   stays in VL and evaluating in PolyWorks.

Update: run Install.cmd of the new version (settings and the PolyWorks buttons stay).
Uninstall: Start menu > Uninstall VL Connector.

## Documents

- [User guide](docs/User-Guide.md): setup, part templates, the Measure button, the network scenario, troubleshooting.
- [Notes for IT](docs/IT-Review.md): what runs, which Windows interfaces are used and why, files, permissions.
- [Protocol](docs/Protocol.md): files exchanged between VL Connector, PolyWorks and the station.
- [Acceptance checklist](docs/Acceptance-Checklist.md): tests at the scanner before production use.
- [Changelog](CHANGELOG.md)

## Support

VL Connector is not official software. You can try contacting your local sales engineer, who can forward
questions to the local technical team. In the settings window, **Diagnostics > Create ZIP** collects the logs
and settings for them (no scans or reports).

## License

[MIT](LICENSE). Everything is plain, readable PowerShell, PolyWorks macro (MSCL), XAML and JSON - no
compiled programs. Developers: `tests\Run-Tests.ps1 -Static -Unit` runs the checks without VL or PolyWorks.
