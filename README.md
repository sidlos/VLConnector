# VL Connector for PolyWorks

VL Connector links **KEYENCE VL-800 AI Replay** scans with **PolyWorks|Inspector** evaluation and reports:
press one button, scan the part in VL as usual, and get an A4 PDF report with a clear OK/NOK verdict.

> **Unofficial tool.** It is not an official KEYENCE or InnovMetric product and is not covered by their
> warranty or support. KEYENCE, VL-800 and PolyWorks are trademarks of their respective owners.

## Two ways to work

| | Scenario A: PolyWorks on the scanner PC | Scenario B: PolyWorks on another PC |
|---|---|---|
| Start | **Measure** button in PolyWorks | **Scan** window on the scanner PC |
| Scan | AI Replay in VL, STL exported automatically | the same |
| Evaluation | in the same PolyWorks | a PolyWorks **station** takes the STL from a shared network folder |
| Report | PDF and CSV, opened automatically | the PDF comes back and opens only on the PC that scanned the part |

For each part, a PolyWorks template holds the CAD, alignment and controls. VL Connector copies the template into a
measured piece, aligns the scan to the CAD, measures all controls and creates the report. The template itself
is never changed.

## Requirements

- Windows 10 or 11, Windows PowerShell 5.1 in FullLanguage mode (standard on Windows).
- KEYENCE VL-800 with VL Application 4.6 (tested: 4.6.1.6002), English user interface.
- PolyWorks Metrology Suite 2026 (Inspector) on the evaluating PC.
- Scenario B: a shared network folder that the scanner PCs and the station can read and write.
- No administrator rights are needed.

## Install

1. Check the download: the SHA-256 of the ZIP must match `SHA256SUMS.txt` (PowerShell: `Get-FileHash <zip>`).
2. Extract the ZIP and run **Install.cmd**. It checks every file, shows the package fingerprint (compare it
   with the one you received), installs to `C:\ProgramData\VLConnector` and creates the Start menu entries.
3. Open **VL Connector** from the Start menu, choose the scenario and follow the Setup page.

Update: run Install.cmd of the new version (settings, report layouts and the PolyWorks buttons stay).
Uninstall: Start menu > Uninstall VL Connector.

## Documents

- [User guide](docs/User-Guide.md): setup, part templates, the Measure button, the network scenario, troubleshooting.
- [Notes for IT](docs/IT-Review.md): what runs, which Windows interfaces are used and why, files, permissions.
- [Protocol](docs/Protocol.md): files exchanged between VL Connector, PolyWorks and the station.
- [Acceptance checklist](docs/Acceptance-Checklist.md): tests at the scanner before production use.
- [Changelog](CHANGELOG.md)

## Support

Contact your local sales engineer, who forwards questions to the local technical team. In the settings window,
**Diagnostics > Create ZIP** collects the logs and settings for them (no scans or reports).

## License

[MIT](LICENSE). Everything is plain, readable PowerShell, PolyWorks macro (MSCL), XAML and JSON - no
compiled programs. Developers: `tests\Run-Tests.ps1 -Static -Unit` runs the checks without VL or PolyWorks.
