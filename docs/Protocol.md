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
| 12 | STL_SHA256 | SHA-256 of the exported STL (Test-ScanFile.ps1 checks it before the import: a replaced STL is refused) |

**Status** `<marker>.status`, written at once and then at least every 5 s: `STEP`, `TEXT` (progress text shown
to the operator), `VLMESSAGE` (text of a VL dialog), `UPDATED`, `BEAT` (a counter). The Measure macro reports
"could not start" when no status appears within 30 s and "stopped unexpectedly" when `BEAT` stops for 60 s.
**Cancel:** the caller creates `<marker>.cancel` (a stale one is deleted before the start); the launcher ends with
`STATE=CANCELLED`.

**Exit codes:** 0 OK, 1 error, 2 cancelled, 3 bad parameters or program not found, 4 another scan running or
VL busy (`STATE=BUSY`: a scan runs in VL or VL shows a message; a second VL window is never opened next to a busy
VL, only next to VL windows that show earlier scans).

**Program names:** the name of a .vld4 file without `.vld4` (only that ending is removed: `Part.A` stays
`Part.A`), compared without regard to case; the configured program folders are searched first, then VL's recent
programs; a name found twice is an error.

**Watch mode** (`-Watch`, used by the agent): the launcher waits until the operator starts AI Replay in VL,
takes the program from VL's *Open File* dialog (only `.vld4`; else from the VL window title or VL's recent
programs), follows the run like a normal one and names the STL `<program>_<yyyy-MM-dd_HH-mm-ss>.stl`. A replay
started by another VL Connector run (the run mutex is taken) is left alone.

## 2. PolyWorks macros

**Get-MacroContext.ps1 output** (for VLC_Measure): `STATE, RUN, USER, UTC, REPORTS_DIR, SCANS_DIR, OPEN_PDF,
DEVICE, VERSION, MESSAGE, TIMEOUT_MIN, UNSAVED`. `UNSAVED` is `1` when the project named by
`-Project` has unsaved changes, `0` when not, empty when it cannot be told: no macro command tells it, so the
script reads the window title of the PolyWorks|Inspector that started it (PolyWorks marks unsaved changes with `*`
after the project name).

**VLC_Evaluate.pwmacro parameters** (`$1` = file): `PWK, TEMPLATE, STL, RUN, REPORT_DIR, OPERATOR, UTC, DEVICE,
RESULT, JOBID, APP, STL_SHA256`. The scan becomes a new piece of the template project (`PIECE NEW`) named
`<TEMPLATE>_<RUN>`; the PDF gets the same name in `REPORT_DIR`.

**Scan check** (when `STL_SHA256` is given): before anything is changed, VLC_Evaluate empties its check file and
runs `Test-ScanFile.ps1`, which writes `STATE (OK/ERROR), MESSAGE`. The scan is measured only when the STL has the
SHA-256 the launcher (marker) or the scanner PC (job) recorded; otherwise the result is ERROR and no piece is made.

**Measurement by the template's plan:** the source of the new piece is the template's piece template (project
property `VL piece template`, otherwise the first one; a named one that does not exist is an error), or, without a
piece template, the open piece. Then: `PIECE NEW` (PolyWorks' new-piece questions are answered by setting their
options, which are restored at once; PolyWorks saves unsaved changes of the open piece first) -> the plan of the
new piece is checked: an active measurement sequence with at least one step, no *Data Object* step (the step that
acquires data) unless it is ignored, and exactly one data object; otherwise the new piece is deleted again and the
source of the plan is opened -> the automatic project update of the new piece is switched on if it is off ->
`PIECE LINK` to the piece template (not when the PolyWorks option *Link to the piece template* is *No*; linking
changes the option *Nonupdatable reports*, which is set and restored around it; a failed link is a note in
`MESSAGE`) -> piece properties (date, serial number, operator, device) -> `FILE IMPORT_DATA POLYGONAL_MODEL` replaces
the data of the template's data object (its name is kept) -> `PIECE PLAY_INSPECTION` plays the plan (alignment,
measurement, color map, report items; an error of PolyWorks is an ERROR) -> the automatic project update is switched
off again if it was off -> `FILE EXPORT_FORMATTED_REPORT PDF` of the template's report (project property `VL report`,
otherwise the first formatted report; none: no PDF, no error) -> `FILE SAVE_PROJECT`. Every piece is kept; VL
Connector deletes only a new piece whose plan cannot run (see above). Messages of PolyWorks are written on one line.

**No verdict of VL Connector.** VLC_Evaluate reads no control, and VL Connector writes no verdict and no CSV:
PolyWorks judges the part, as the template is designed - in its formatted report (the PDF) and in the Control
Reviewer. What the operator sees after the measurement belongs to the template.

**VLC_Evaluate result** (file `RESULT`, UTF-16, written last, one block for every way out): `STATE, PDF, PIECE,
MESSAGE`. `STATE=OK`: the plan was played and the PDF exported if the template has a formatted report; `ERROR`: the
reason is in `MESSAGE`. `PDF` is empty without a formatted report. `PIECE` names the new piece (empty when the template
could not be measured and the new piece was removed again). With `STATE=OK`, `MESSAGE` is a note (e.g. the piece
could not be linked to the piece template). VLC_Measure shows a message only for `ERROR` and opens the PDF when
`OPEN_PDF` is 1; it shows nothing else.

## 3. Network scenario

**Shared folder:** `jobs\` (with `rejected\`), `work\`, `reports\`, `processed\`, `failed\`, `status\`,
`programs.csv`. Rights per role: [Notes for IT](IT-Review.md), section 9.

**JobId:** `<COMPUTER>_<PROGRAM>_<yyyyMMdd-HHmmss>_<4 hex>`, characters `A-Z a-z 0-9 -` and `_` as separator only
(other characters in computer and program names become `-`). Files: `<JobId>.job`, `.stl`, `.claim`, `.pdf`,
`.result`.

**Protocol version** (`PROTOCOL` in jobs and results): `2` since 3.0 (the result has no verdict; 1.x and 2.0 used
`1`). A station takes only jobs of its own protocol and answers others with the reason (*Protocol 1 is not supported
by this station*): update the scanner PCs and the stations together.

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
  `%%EOF`; a result whose PDF has not arrived stays pending up to 10 minutes after the station finished. A result
  without a PDF (the template has no formatted report) is done at once. Copied PDFs are marked as downloaded from
  another computer.

**Job** `jobs\<JobId>.job` (written after the STL): `PROTOCOL (2), JOBID, PART (program name), PROGRAM (.vld4 file
name), COMPUTER, USER, CREATED_UTC, STL, STL_SIZE, STL_SHA256, VERSION`.

**Station:** claims the oldest job (by the time in its JobId) by moving `<JobId>.job` to `work\` (a station that
loses the race skips it) and writing `work\<JobId>.claim` (`STATION, COMPUTER, CLAIMED_UTC`); files in `jobs\`
that are no jobs go to `jobs\rejected\`. It moves the STL and checks protocol, JobId, STL size (at most 2 GB),
SHA-256 and binary STL format, and that the VL program is in the Measurement Programs List with an existing
workspace. It measures with VLC_Evaluate and publishes `reports\<JobId>.pdf` (when the template has a formatted
report; a PDF that is not complete makes the result ERROR), then **`reports\<JobId>.result` last**: `PROTOCOL, JOBID,
STATE, PDF, STATION, FINISHED_UTC, MESSAGE, WORKSPACE, TEMPLATE`. The job and STL move to `processed\` (STATE=OK) or `failed\` (STATE=ERROR with the
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
