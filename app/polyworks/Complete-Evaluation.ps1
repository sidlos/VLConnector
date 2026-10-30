<#
  Complete-Evaluation.ps1 - VL Connector for PolyWorks: the verdict of a measured piece. VLC_Evaluate.pwmacro
  writes the raw control data of the piece (-Controls, UTF-16; format in lib\Verdict.ps1) and runs this script.
  It checks the data, computes the verdict (fail-closed: only PolyWorks' documented results inside the tolerance
  count as OK), writes the CSV next to the PDF and the verdict file (-Out) in this fixed line order:
     1 STATE    OK, or ERROR (no verdict; the macro keeps the piece for checking)
     2 VERDICT  OK or NOK (empty on ERROR)
     3 SUMMARY  e.g. "all 13 controls within tolerance"
     4 COUNT    controls read (the macro compares it with its own count)
     5 RUN      run of the control data (the macro compares it with its own)
     6 JOBID    job of the control data (the macro compares it with its own)
     7 CSV      the CSV written (empty on ERROR)
     8 MESSAGE  the reason of an ERROR
  Usage (from the macro): powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File Complete-Evaluation.ps1
                          -Controls <file> -Out <file>
#>
param(
    [Parameter(Mandatory = $true)] [string]$Controls,
    [Parameter(Mandatory = $true)] [string]$Out
)

# FullLanguage mode is needed (docs\IT-Review); checked before anything is loaded
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    & (Join-Path (Split-Path $PSScriptRoot) 'lib\LanguageCheck.ps1') -Caller Evaluation -Mode $ExecutionContext.SessionState.LanguageMode -OutFile $Out -Keys STATE, VERDICT, SUMMARY, COUNT, RUN, JOBID, CSV, MESSAGE
    exit 1
}

$ErrorActionPreference = 'Stop'
$app = Split-Path $PSScriptRoot
foreach ($lib in 'Settings', 'Log', 'KeyValueFile', 'Verdict') { . (Join-Path $app "lib\$lib.ps1") }
[void](Initialize-VlcLog 'Evaluation')

$o = [ordered]@{ STATE = 'ERROR'; VERDICT = ''; SUMMARY = ''; COUNT = ''; RUN = ''; JOBID = ''; CSV = ''; MESSAGE = '' }
try {
    $data = Read-VlcControlsFile $Controls
    $h = $data.Header
    $o.RUN = $h.RUN
    $o.JOBID = $h.JOBID
    $o.COUNT = [string]@($data.Controls).Count
    $hash = if ($h.STL -and (Test-Path -LiteralPath $h.STL -PathType Leaf)) { (Get-FileHash -LiteralPath $h.STL -Algorithm SHA256).Hash.ToLower() } else { '' }
    $e = Get-VlcEvaluation $data $hash
    $o.STATE = $e.State
    $o.VERDICT = $e.Verdict
    $o.SUMMARY = $e.Summary
    $o.MESSAGE = $e.Message
    if ($e.State -eq 'OK') {
        # the CSV goes into the report folder, next to the PDF, and nowhere else
        $csv = [IO.Path]::GetFullPath($h.CSV)
        if ((Split-Path $csv) -ne [IO.Path]::GetFullPath($h.REPORT_DIR).TrimEnd('\') -or [IO.Path]::GetExtension($csv) -ne '.csv') {
            throw "The CSV $csv is not a .csv file in the report folder $($h.REPORT_DIR)."
        }
        Write-VlcEvaluationCsv $csv $data $e (Get-VlcVersion) $hash
        $o.CSV = $csv
    }
    Write-VlcLog "$($h.PIECE): $($o.STATE) $($o.VERDICT) - $($o.SUMMARY) $($o.MESSAGE)".Trim()
}
catch {
    $o.STATE = 'ERROR'
    $o.VERDICT = ''
    $o.CSV = ''
    $o.MESSAGE = "Evaluation: $($_.Exception.Message)"
    Write-VlcLog "ERROR: $($o.MESSAGE)"
}
Write-KeyValueFile $Out $o
