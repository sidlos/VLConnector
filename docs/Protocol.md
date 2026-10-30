# VL Connector for PolyWorks - Protocol

Files exchanged between the launcher, the PolyWorks macros, the agent and the PolyWorks station.

**Format of all KEY=value files:** one `KEY=value` per line, keys in the fixed order given below (the
PolyWorks macros read them by line number), UTF-8 **with BOM** (files written by PolyWorks are UTF-16; readers
accept both). Values never contain line breaks or `=` (written as `-`; paths with `=` are refused). The scripts
write their files under a temporary name (`.part`) and rename them, so a reader never sees half a file. The
PolyWorks macros can only write line by line (the station heartbeat, the control data, the results); their
readers check that a file is complete (fixed keys, `END` and `COUNT` lines) and empty the answer files before
each call. A file without a single `KEY=value` line counts as missing.

## 1. Launcher (VLReplay.ps1)

**Launch file** (`-LaunchFile`, UTF-16, written by the Measure macro): `PROGRAM` (the template's *VL program*)
and `OPTIONS` (its *VL options*). Template values never reach the command line, where a quote could add
parameters; an option that only the administrator may set (`-ConfirmStageMotion`) is refused.

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
| 9 | JOBID | `-JobId` or empty |
| 10 | VERSION | VL Connector version |
| 11 | START_UTC | Start time, UTC |
| 12 | STL_SHA256 | SHA-256 of the exported STL (the evaluation checks it: a replaced STL is refused) |

**Status** `<marker>.status`, written at once and then at least every 5 s: `STEP`, `TEXT` (progress text shown
to the operator), `VLMESSAGE` (text of a VL dialog), `UPDATED`, `BEAT` (a counter). The Measure macro reports
"could not start" when no status appears within 30 s and "stopped unexpectedly" when `BEAT` stops for 60 s.
**Cancel:** the caller creates `<marker>.cancel` (a stale one is deleted before the start); the launcher ends with
`STATE=CANCELLED`.

**Exit codes:** 0 OK, 1 error, 2 cancelled, 3 bad parameters or program not found, 4 another scan running
(`STATE=BUSY`: a second VL window is never opened).

**Program names:** the name of a .vld4 file without `.vld4` (only that ending is removed: `Part.A` stays
`Part.A`), compared without regard to case; the configured program folders are searched first, then VL's recent
programs; a name found twice is an error.

**Watch mode** (`-Watch`, used by the agent): the launcher waits until the operator starts AI Replay in VL,
takes the program from VL's *Open File* dialog (only `.vld4`; else from the VL window title or VL's recent
programs), follows the run like a normal one and names the STL `<program>_<yyyy-MM-dd_HH-mm-ss>.stl`. A replay
started by another VL Connector run (the run mutex is taken) is left alone.

## 2. PolyWorks macros

**Get-MacroContext.ps1 output** (for VLC_Measure): `STATE, RUN, USER, UTC, REPORTS_DIR, SCANS_DIR, KEEP_PIECES,
OPEN_PDF, COLOR_SCALE, DEVICE, VERSION, MESSAGE, TIMEOUT_MIN`.

**VLC_Evaluate.pwmacro parameters** (`$1` = file): `PWK, TEMPLATE, STL, RUN, REPORT_DIR, OPERATOR, PROGRAM, UTC,
KEEP_PIECES, COLOR_SCALE, DEVICE, RESULT, JOBID, APP, STL_SHA256`. The piece is named `<TEMPLATE>_<RUN>`; PDF and
CSV get the same name in `REPORT_DIR`.

**Control data** (`VLC-CONTROLS-1`, UTF-16, written by VLC_Evaluate for `Complete-Evaluation.ps1`): the header
`FORMAT, RUN, JOBID, PIECE, TEMPLATE, PROGRAM, OPERATOR, STL, STL_SHA256, REPORT_DIR, CSV, ALIGN_STATUS,
ALIGN_ERROR, EXTRACT_STATUS, EXTRACT_ERROR`, then ten lines per control `CONTROL, NAME, NOMINAL, MEASURED,
DEVIATION, UPPER_TOL, UPPER_WARN, LOWER_WARN, LOWER_TOL, RESULT`, then `END=<number of controls>`. Data that is
cut off, out of order or miscounted is refused.

**Verdict file** (written by `Complete-Evaluation.ps1`, emptied by the macro before): `STATE (OK/ERROR), VERDICT
(OK/NOK), SUMMARY, COUNT, RUN, JOBID, CSV, MESSAGE`. The macro compares `COUNT`, `RUN` and `JOBID` with its own
values; anything missing or different gives `STATE=ERROR` and the piece is kept for checking.

**Verdict rules (fail-closed):** a control is OK only with PolyWorks' documented results *Within positive/negative
safe zone* (OK) or *Within upper/lower warning zone* (OK, warning); *Beyond upper/lower tolerance limit* is NOK;
an empty result is NOT MEASURED and anything else UNKNOWN - both NOK. No verdict at all (STATE=ERROR) without
controls, after a failed alignment or measurement, or when the STL is not the one the launcher exported.

**VLC_Evaluate result** (file `RESULT`, UTF-16, written last): `STATE (OK/ERROR), VERDICT (OK/NOK), SUMMARY, PDF,
CSV, PIECE, PIECE_KEPT (1/0), MESSAGE`. When `PIECE_KEPT=0` the caller removes the piece after reopening the
template.

**CSV** (UTF-8 with BOM, `;`): header lines with part, program, operator, alignment, version, STL and its
SHA-256, then one line per control and the verdict; text cells that a spreadsheet would run as a formula start
with `'`.

## 3. Network scenario

**Shared folder:** `jobs\` (with `rejected\`), `work\`, `reports\`, `processed\`, `failed\`, `status\`,
`programs.csv`. Rights per role: [Notes for IT](IT-Review.md), section 9.

**JobId:** `<COMPUTER>_<PROGRAM>_<yyyyMMdd-HHmmss>_<4 hex>`, characters `A-Z a-z 0-9 -` and `_` as separator only
(other characters in computer and program names become `-`). Files: `<JobId>.job`, `.stl`, `.claim`, `.pdf`,
`.csv`, `.result`.

**Scanner PC:**

- The tray of the agent only notes a finished scan in `%LOCALAPPDATA%\VLConnector\inbox\<JobId>.scan`
  (`JOBID, PART, STL, PROGRAM, NOTED_UTC`). The background cycle - the only writer of the outbox and of the
  pending list - turns it into an outbox job (copy of the STL and the `.job`) and a line in `pending.txt`
  (`JobId;Part;submitted`). A note that comes again is not sent twice.
- The outbox is sent oldest first (by the time in the JobId): STL, then `.job`, each as `.part` and renamed. An
  unreachable shared folder stops the round; any other problem skips that job and counts an attempt
  (`<JobId>.tries`); after five attempts, or without its STL, the job is set aside in `outbox\failed\` with a
  `.reason` and a notification.
- Results are read only for the pending JobIds. A PDF is copied when it starts with `%PDF-` and ends with
  `%%EOF`; a result whose PDF has not arrived stays pending up to 10 minutes after the station finished. Copied
  PDF and CSV files are marked as downloaded from another computer.

**Job** `jobs\<JobId>.job` (written after the STL): `PROTOCOL (1), JOBID, PART (program name), PROGRAM (.vld4 file
name), COMPUTER, USER, CREATED_UTC, STL, STL_SIZE, STL_SHA256, VERSION`.

**Station:** claims the oldest job (by the time in its JobId) by moving `<JobId>.job` to `work\` (a station that
loses the race skips it) and writing `work\<JobId>.claim` (`STATION, COMPUTER, CLAIMED_UTC`); files in `jobs\`
that are no jobs go to `jobs\rejected\`. It moves the STL and checks protocol, JobId, STL size (at most 2 GB),
SHA-256 and binary STL format, and that the VL program is in the Measurement Programs List with an existing
workspace. It evaluates with VLC_Evaluate and publishes `reports\<JobId>.pdf` and `.csv`, then
**`reports\<JobId>.result` last**: `PROTOCOL, JOBID, STATE, VERDICT, SUMMARY, PDF, CSV, STATION, FINISHED_UTC,
MESSAGE, WORKSPACE, TEMPLATE`. The job and STL move to `processed\` (STATE=OK) or `failed\` (STATE=ERROR with the
reason). An OK result is never overwritten. A job that fails after its claim is completed as ERROR, so its
scanner PC learns why. Jobs left in `work\` - by this station when it starts, or by any station longer than
`network.jobTimeoutMin` (default 15 min) - are completed as ERROR.

**Heartbeat** `status\<COMPUTER>.station`: `STATION, STATE (Idle/Busy/Paused/Stopped), JOB, VERSION, UPDATED_UTC,
BEAT`. `BEAT` grows with every write (about every 30 s while waiting, and at every step). The agent judges
liveness with **its own clock** from the last change of `BEAT` (clocks of other PCs do not matter, and no write
right in `status\` is needed): online up to 2 minutes after the last change, a busy station up to the job time
limit; *paused* means the station waits for a problem to be solved (e.g. an unusable Measurement Programs List).

**programs.csv**, the Measurement Programs List (UTF-8 with BOM, `;`, first line `Program;Workspace;Template`):
the program is the .vld4 file name without `.vld4`, matched exactly (without regard to case); the workspace is
the full path of a `.pwk` file on the station (network paths only when the policy allows them). Lines with fewer
or more values, `=` or quotes, or a program listed twice, are left out and named on the Setup page. Without its
header line the list is not usable: the station pauses instead of failing every job.

Both sides treat each other's files as untrusted input: names are checked against the JobId pattern, paths are
built locally, sizes are limited, the STL is checked by hash and format, and the station takes the template only
from its own Measurement Programs List.
