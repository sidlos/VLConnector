# Pester 3.4 unit tests: the line-numbered files between the scripts and the PolyWorks macros (docs\Protocol.md).
# PolyWorks macros read KEY=value files by line number, so writer and reader must agree on every line.
$repo = Split-Path (Split-Path $PSScriptRoot)
$poly = Join-Path $repo 'app\polyworks'
$measure = [IO.File]::ReadAllText((Join-Path $poly 'VLC_Measure.pwmacro'))
$evaluate = [IO.File]::ReadAllText((Join-Path $poly 'VLC_Evaluate.pwmacro'))
$station = [IO.File]::ReadAllText((Join-Path $poly 'Station-Step.ps1'))
$stationMacro = [IO.File]::ReadAllText((Join-Path $poly 'VLC_Station.pwmacro'))

# line number -> variable for every "DATA_FILE READ LINE_FIELD ( $<file>, <line>, 2, <variable>, ..."
function Get-MacroReads([string]$Macro, [string]$FileVar) {
    $reads = @{}
    foreach ($m in [regex]::Matches($Macro, 'DATA_FILE READ LINE_FIELD \( \$' + $FileVar + ', (\d+), 2, (v\w+),')) { $reads[[int]$m.Groups[1].Value] = $m.Groups[2].Value }
    return $reads
}

# keys in the order of "DATA_FILE APPEND LINE ( $<file>, { "KEY=..." } )"
function Get-MacroWrites([string]$Macro, [string]$FileVar) {
    return @([regex]::Matches($Macro, 'DATA_FILE APPEND LINE \( \$' + $FileVar + ', \{ "(\w+)=') | ForEach-Object { $_.Groups[1].Value })
}

function Assert-Reads($Reads, [string[]]$Keys, [hashtable]$KeyOf) {
    foreach ($line in $Reads.Keys) {
        $var = $Reads[$line]
        $KeyOf.ContainsKey($var) | Should Be $true
        "line $line = $($Keys[$line - 1])" | Should Be "line $line = $($KeyOf[$var])"
    }
}

Describe 'macro file protocol' {
    It 'VLC_Measure reads the Get-MacroContext lines it expects' {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('vlc_ctx_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        try {
            $out = Join-Path $tmp 'context.txt'
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $poly 'Get-MacroContext.ps1') -Out $out -Pwk (Join-Path $tmp 'parts.pwk')
            $keys = @([IO.File]::ReadAllLines($out) | ForEach-Object { ($_ -split '=', 2)[0] })
            $keys -join ',' | Should Be 'STATE,RUN,USER,UTC,REPORTS_DIR,SCANS_DIR,KEEP_PIECES,OPEN_PDF,COLOR_SCALE,DEVICE,VERSION,MESSAGE,TIMEOUT_MIN'
            $keyOf = @{ vCtxState = 'STATE'; vRun = 'RUN'; vUser = 'USER'; vUtc = 'UTC'; vReportDir = 'REPORTS_DIR'; vScanDir = 'SCANS_DIR'
                vKeep = 'KEEP_PIECES'; vOpenPdf = 'OPEN_PDF'; vScale = 'COLOR_SCALE'; vDevice = 'DEVICE'; vMsg = 'MESSAGE'; vTimeoutMin = 'TIMEOUT_MIN' }
            $reads = Get-MacroReads $measure 'vCtx'
            $reads.Count | Should Be 12
            Assert-Reads $reads $keys $keyOf
        }
        finally { Remove-Item -LiteralPath $tmp -Recurse -Force }
    }
    It 'VLC_Evaluate reads the parameters in the order VLC_Measure and the station write them' {
        $keys = Get-MacroWrites $measure 'vParams'
        $keys -join ',' | Should Be 'PWK,TEMPLATE,STL,RUN,REPORT_DIR,OPERATOR,PROGRAM,UTC,KEEP_PIECES,COLOR_SCALE,DEVICE,RESULT,JOBID,APP,STL_SHA256'
        $keyOf = @{ vPwk = 'PWK'; vTemplate = 'TEMPLATE'; vStl = 'STL'; vRun = 'RUN'; vReportDir = 'REPORT_DIR'; vUser = 'OPERATOR'; vProgram = 'PROGRAM'
            vUtc = 'UTC'; vKeep = 'KEEP_PIECES'; vScale = 'COLOR_SCALE'; vDevice = 'DEVICE'; vResult = 'RESULT'; vJobId = 'JOBID'; vApp = 'APP'; vStlHash = 'STL_SHA256' }
        $reads = Get-MacroReads $evaluate 'vParams'
        $reads.Count | Should Be $keys.Count
        Assert-Reads $reads $keys $keyOf
        # Station-Step.ps1 writes the same file with Write-KeyValueFile, in the order of its [ordered] table
        $block = [regex]::Match($station, '(?s)\$params = \[ordered\]@\{(.*?)\n\s*\}').Groups[1].Value
        $stationKeys = @([regex]::Matches($block, '(?m)(?:^|;)\s*([A-Z][A-Z0-9_]*) =') | ForEach-Object { $_.Groups[1].Value })
        $stationKeys -join ',' | Should Be ($keys -join ',')
        # the station macro itself reads the workspace and the template back (to remove a piece it does not keep)
        Assert-Reads (Get-MacroReads $stationMacro 'vParams') $keys @{ vPwk = 'PWK'; vTemplate = 'TEMPLATE' }
    }
    It 'VLC_Station reads the Station-Step lines it expects (context, next job, publish)' {
        $keysOf = @{}
        foreach ($m in [regex]::Matches($station, "'(Context|Next|Publish)' \{ \[ordered\]@\{([^}]*)\} \}")) {
            $keysOf[$m.Groups[1].Value] = @([regex]::Matches($m.Groups[2].Value, '([A-Z_]+) =') | ForEach-Object { $_.Groups[1].Value })
        }
        $keysOf.Context -join ',' | Should Be 'STATE,SHARE,POLL_MS,STATUS_FILE,MESSAGE,STATION'
        $keysOf.Next -join ',' | Should Be 'STATE,JOBID,PART,PARAMS,RESULT,MESSAGE'
        $keysOf.Publish -join ',' | Should Be 'STATE,MESSAGE'
        $reads = Get-MacroReads $stationMacro 'vCtx'
        $reads.Count | Should Be 6
        Assert-Reads $reads $keysOf.Context @{ vState = 'STATE'; vShare = 'SHARE'; vPoll = 'POLL_MS'; vStatusFile = 'STATUS_FILE'; vMsg = 'MESSAGE'; vStation = 'STATION' }
        $reads = Get-MacroReads $stationMacro 'vNext'
        $reads.Count | Should Be 6
        Assert-Reads $reads $keysOf.Next @{ vState = 'STATE'; vJobId = 'JOBID'; vPart = 'PART'; vParams = 'PARAMS'; vResult = 'RESULT'; vMsg = 'MESSAGE' }
        $reads = Get-MacroReads $stationMacro 'vPub'
        $reads.Count | Should Be 2
        Assert-Reads $reads $keysOf.Publish @{ vPubState = 'STATE'; vPubMsg = 'MESSAGE' }
        # the answer files are emptied before each call: an answer of an earlier call is never read
        foreach ($v in 'vNext', 'vPub') { $stationMacro | Should Match ('DATA_FILE CREATE \( \$' + $v + ', "Ascii", "Yes" \)') }
    }
    It 'VLC_Station writes its heartbeat in the order of Write-VlcStationStatus and counts BEAT on' {
        $jobs = [IO.File]::ReadAllText((Join-Path $repo 'app\lib\Jobs.ps1'))
        $block = [regex]::Match($jobs, '(?s)function Write-VlcStationStatus.*?Write-KeyValueFile \$file \(\[ordered\]@\{(.*?)\}\)').Groups[1].Value
        $keys = @([regex]::Matches($block, '([A-Z_]+) =') | ForEach-Object { $_.Groups[1].Value })
        $keys -join ',' | Should Be 'STATION,STATE,JOB,VERSION,UPDATED_UTC,BEAT'
        # the heartbeat while waiting and the last one when the station stops
        (Get-MacroWrites $stationMacro 'vStatusFile') -join ',' | Should Be ((@($keys) * 2) -join ',')
        Assert-Reads (Get-MacroReads $stationMacro 'vStatusFile') $keys @{ vBeatN = 'BEAT' }
    }
    It 'VLC_Evaluate writes the control data in the order Complete-Evaluation.ps1 reads it' {
        . (Join-Path $repo 'app\lib\Verdict.ps1')
        $keys = Get-MacroWrites $evaluate 'vCtl'
        $keys -join ',' | Should Be ((@($script:VlcControlsHeader) + @($script:VlcControlKeys) + 'END') -join ',')
        $evaluate | Should Match 'DATA_FILE APPEND LINE \( \$vCtl, \{ "FORMAT=VLC-CONTROLS-1" \} \)'
    }
    It 'VLC_Evaluate reads the verdict lines Complete-Evaluation.ps1 writes, after emptying the file' {
        $script = [IO.File]::ReadAllText((Join-Path $poly 'Complete-Evaluation.ps1'))
        $block = [regex]::Match($script, '\$o = \[ordered\]@\{([^}]*)\}').Groups[1].Value
        $keys = @([regex]::Matches($block, '([A-Z_]+) =') | ForEach-Object { $_.Groups[1].Value })
        $keys -join ',' | Should Be 'STATE,VERDICT,SUMMARY,COUNT,RUN,JOBID,CSV,MESSAGE'
        $keyOf = @{ vEState = 'STATE'; vVerdictAll = 'VERDICT'; vDetail = 'SUMMARY'; vECount = 'COUNT'; vERun = 'RUN'; vEJob = 'JOBID'; vECsv = 'CSV'; vEMsg = 'MESSAGE' }
        $reads = Get-MacroReads $evaluate 'vVer'
        $reads.Count | Should Be 8
        Assert-Reads $reads $keys $keyOf
        $evaluate.IndexOf('DATA_FILE CREATE ( $vVer, "Ascii", "Yes" )') | Should BeLessThan $evaluate.IndexOf('Complete-Evaluation.ps1${_QUOTES}')
    }
    It 'VLC_Measure reads the marker lines VLReplay.ps1 writes' {
        $replay = [IO.File]::ReadAllText((Join-Path $repo 'app\VLReplay.ps1'))
        $block = [regex]::Match($replay, '(?s)function Write-Marker.*?\$pairs = \[ordered\]@\{(.*?)\n\s*\}').Groups[1].Value
        $keys = @([regex]::Matches($block, '(?m)^\s*([A-Z][A-Z0-9_]*)\s*=') | ForEach-Object { $_.Groups[1].Value })
        $keys -join ',' | Should Be 'STATE,STL,PROGRAM,START,END,MESSAGE,USER,COMPUTER,JOBID,VERSION,START_UTC,STL_SHA256'
        Assert-Reads (Get-MacroReads $measure 'vMarker') $keys @{ vState = 'STATE'; vStl = 'STL'; vMsg = 'MESSAGE'; vStlHash = 'STL_SHA256' }
    }
    It 'VLC_Measure reads the status lines (text and heartbeat) the launcher writes' {
        $cs = [IO.File]::ReadAllText((Join-Path $repo 'app\interop\StatusFile.cs'))
        $keys = @([regex]::Matches($cs, '"(?:\\r\\n)?([A-Z]+)="') | ForEach-Object { $_.Groups[1].Value })
        $keys -join ',' | Should Be 'STEP,TEXT,VLMESSAGE,UPDATED,BEAT'
        Assert-Reads (Get-MacroReads $measure 'vStatus') $keys @{ vText = 'TEXT'; vBeat = 'BEAT' }
        (Get-MacroReads $measure 'vStatus').Count | Should Be 2
    }
    It 'hides the progress window before VLC_Evaluate runs its synchronous command (it would stay disabled)' {
        foreach ($macro in $measure, [IO.File]::ReadAllText((Join-Path $poly 'VLC_Station.pwmacro'))) {
            $call = $macro.IndexOf('VLC_Evaluate.pwmacro", $vParams )')
            $call | Should BeGreaterThan 0
            $before = $macro.Substring(0, $call)
            $before.LastIndexOf('MACRO PROGRESS HIDE') | Should BeGreaterThan $before.LastIndexOf('MACRO PROGRESS SHOW')
        }
    }
    It 'VLC_Measure reads the result lines VLC_Evaluate writes' {
        $keys = Get-MacroWrites $evaluate 'vResult'
        # every early exit and the normal end write the same eight lines
        ($keys | Select-Object -Last 8) -join ',' | Should Be 'STATE,VERDICT,SUMMARY,PDF,CSV,PIECE,PIECE_KEPT,MESSAGE'
        $keyOf = @{ vRState = 'STATE'; vVerdict = 'VERDICT'; vSummary = 'SUMMARY'; vPdf = 'PDF'; vCsv = 'CSV'; vPiece = 'PIECE'; vKept = 'PIECE_KEPT'; vRMsg = 'MESSAGE' }
        Assert-Reads (Get-MacroReads $measure 'vResult') @($keys | Select-Object -Last 8) $keyOf
        Assert-Reads (Get-MacroReads $stationMacro 'vResult') @($keys | Select-Object -Last 8) $keyOf
    }
}
