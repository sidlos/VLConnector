# VL Connector for PolyWorks - Protocol

Files exchanged between the launcher, the PolyWorks macros, the Scan window and the PolyWorks station.

**Format of all KEY=value files:** one `KEY=value` per line, keys in the fixed order given below (the
PolyWorks macros read them by line number), UTF-8 **with BOM** (files written by PolyWorks are UTF-16; readers
accept both). Values never contain line breaks or `=` (written as `-`; paths with `=` are refused). Files are
written under a temporary name (`.part`) and renamed, so a reader never sees half a file.

## 1. Launcher (VLReplay.ps1)

**Marker** (`-MarkerFile`, written once at the end):

| # | Key | Value |
|---|---|---|
| 1 | STATE | `OK`, `ERROR`, `CANCELLED`, `DRYRUN`, `BUSY` |
| 2 | STL | Exported STL (state OK) |
| 3 | PROGRAM | .vld4 program |
| 4 | START | Start time (local, `yyyy-MM-dd HH:mm:ss`) |
| 5 | END | End time |
| 6 | MESSAGE | Error or cancel reason, empty on OK |
| 7 | USER | Windows user |
| 8 | COMPUTER | Computer name |
| 9 | JOBID | `-JobId` (Scan window) or empty |
| 10 | VERSION | VL Connector version |
| 11 | START_UTC | Start time, UTC |

**Status** `<marker>.status` while the run is active: `STEP`, `TEXT` (progress text shown to the operator),
`VLMESSAGE` (text of a VL dialog), `UPDATED`. **Cancel:** a caller creates `<marker>.cancel`; the launcher
ends with `STATE=CANCELLED`. Both files are removed at the end.

**Exit codes:** 0 OK, 1 error, 2 cancelled, 3 bad parameters or program not found, 4 another scan running.

## 2. PolyWorks macros

**Get-MacroContext.ps1 output** (for VLC_Measure): `STATE, RUN, USER, UTC, REPORTS_DIR, SCANS_DIR,
LAYOUT_DIR, KEEP_PIECES, OPEN_PDF, COLOR_SCALE, DEVICE, VERSION, MESSAGE`.

**VLC_Evaluate.pwmacro parameters** (`$1` = file): `PWK, TEMPLATE, STL, RUN, REPORT_DIR, LAYOUT_DIR,
OPERATOR, PROGRAM, UTC, KEEP_PIECES, COLOR_SCALE, DEVICE, RESULT, JOBID`.
The piece is named `<TEMPLATE>_<RUN>`; PDF and CSV get the same name in `REPORT_DIR`.

**VLC_Evaluate result** (file `RESULT`, UTF-16, written last): `STATE (OK/ERROR), VERDICT (OK/NOK), SUMMARY,
PDF, CSV, PIECE, PIECE_KEPT (1/0), MESSAGE`. When `PIECE_KEPT=0` the caller removes the piece from the
workspace after reopening the template.

## 3. Network scenario

**Shared folder:** `jobs\`, `work\`, `reports\`, `processed\`, `failed\`, `status\`, `parts.csv`.

**JobId:** `<COMPUTER>_<PART>_<yyyyMMdd-HHmmss>_<4 hex>`, characters `A-Z a-z 0-9 -` and `_` as separator
only (other characters in computer and part names become `-`). Files: `<JobId>.job`, `.stl`, `.pdf`, `.csv`,
`.result`.

**Job** `jobs\<JobId>.job` (written after the STL): `PROTOCOL (1), JOBID, PART, PROGRAM, COMPUTER, USER,
CREATED_UTC, STL, STL_SIZE, STL_SHA256, VERSION`.

**Station:** claims the oldest job by moving `<JobId>.job` to `work\` (a station that loses the race skips
it), moves the STL, checks protocol, JobId, STL size, SHA-256 and binary STL format, and that the part is in
`parts.csv` with an existing workspace. It then evaluates with VLC_Evaluate and publishes
`reports\<JobId>.pdf` and `.csv`, then **`reports\<JobId>.result` last**:
`PROTOCOL, JOBID, STATE, VERDICT, SUMMARY, PDF, CSV, STATION, FINISHED_UTC, MESSAGE`.
The job and STL move to `processed\` (STATE=OK) or `failed\` (with a result STATE=ERROR and the reason).

**Scanner PC:** keeps its JobIds in `%LOCALAPPDATA%\VLConnector\pending.txt` and reads only the results of
those JobIds. A PDF is copied and opened only when it starts with `%PDF-` and ends with `%%EOF`.

**Heartbeat** `status\<COMPUTER>.station`: `STATION, STATE (Idle/Busy/Stopped), JOB, VERSION, UPDATED_UTC`,
updated about every 30 s and at each job; the Scan window shows a station as online when the file is newer
than 2 minutes and the state is not `Stopped`.

**parts.csv** (UTF-8 with BOM, `;`-separated, header line): `Part;Workspace;Template;VlProgram;Options`.

Both sides treat each other's files as untrusted input: names are checked against the JobId pattern, paths
are built locally, the STL is checked by hash and format, and the station takes the template only from its
own parts list.
