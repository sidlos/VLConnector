<#
  Make-ReportLayouts.ps1 - VL Connector for PolyWorks: creates the two report layouts used by
  VLC_Evaluate.pwmacro from the A4_Portrait.ezl layout of the PolyWorks installed on this PC (the
  original is only read; no InnovMetric file is shipped with VL Connector):
      <Target>\VL_Report_OK.ezl, VL_Report_NOK.ezl (+ the *_Files folders with the PolyWorks logos)
  Changes against A4_Portrait: date with time, "Piece" instead of "Project" on the cover page, full-width
  title, cover page = large isometric color map ("snapshot 0", 178 x 179 mm) + verdict box
  ($_REPORT_CUSTOM_RESULT, green or red) and a summary ($_REPORT_CUSTOM_SUMMARY, _PROGRAM, _SCAN).
  Without these layouts the macro uses the default PolyWorks layout.

  Usage: Make-ReportLayouts.ps1 [-Target <folder>] [-PolyWorksDir <installation folder>]
#>
param([string]$Target = '', [string]$PolyWorksDir = '')

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'lib\Settings.ps1')
. (Join-Path (Split-Path $PSScriptRoot) 'lib\PolyWorksSetup.ps1')
if (-not $Target) { $Target = (Get-VlcPaths).LayoutDir }
if (-not $PolyWorksDir) { $PolyWorksDir = (Get-PolyWorksInfo).Dir }
if (-not $PolyWorksDir) { throw 'PolyWorks was not found on this PC (no COM registration of the Workspace Manager).' }
$src = Join-Path $PolyWorksDir 'report\layout\A4_Portrait.ezl'
$srcFiles = Join-Path $PolyWorksDir 'report\layout\A4_Portrait_Files'
if (-not (Test-Path -LiteralPath $src)) { throw "The PolyWorks layout $src was not found." }
$base = [IO.File]::ReadAllText($src)

function Replace-Required([string]$Text, [string]$What, [string]$With) {
    if (-not $Text.Contains($What)) { throw "The A4_Portrait layout of this PolyWorks version is different (not found: $What). The macro will use the default PolyWorks layout." }
    return $Text.Replace($What, $With)
}

$changes = [ordered]@{
    'Date: $_PIECE_SHORT_DATE\par'                = 'Date: $_PIECE_SHORT_DATE  $_PIECE_TIME\par'
    '\b\fs22\lang1033 Drawing #\b0 :\par'         = '\b\fs22\lang1033 Drawing #:\par'
    '\b\fs22\lang1033 Organization:\b0\tab\par'   = '\b\fs22\lang1033 Organization:\par'
    '\b\fs22\lang1033 Project:\par'               = '\b\fs22\lang1033 Piece:\par'
    '\fs22\lang1033 $_PROJECT\par'                = '\fs22\lang1033 $_PIECE\par'
    '\cf1\fs22 $_PIECE_SHORT_DATE\par'            = '\cf1\fs22 $_PIECE_SHORT_DATE  $_PIECE_TIME\par'
    # title across the whole header width, 20 pt (otherwise "Inspection Report - <template>" wraps)
    '\cf1\fs44 $_REPORT_TITLE\par'                = '\cf1\fs40 $_REPORT_TITLE\par'
    '<Right>164.746</Right>'                      = '<Right>193.5</Right>'
}
foreach ($k in $changes.Keys) { $base = Replace-Required $base $k $changes[$k] }

# cover page: snapshot 0 as large as possible (178 x 179 mm), below it only the verdict and the summary.
# VLC_Evaluate captures the snapshot in the same aspect ratio (CAPTURE_REGION 1440 x 1450 px).
$base = Replace-Required $base "<Name>snapshot 0</Name>`r`n`t`t`t`t`t<Box>`r`n`t`t`t`t`t`t<Left>15.9979</Left>`r`n`t`t`t`t`t`t<Top>43.2384</Top>`r`n`t`t`t`t`t`t<Right>194.342</Right>`r`n`t`t`t`t`t`t<Bottom>236.955</Bottom>" `
    "<Name>snapshot 0</Name>`r`n`t`t`t`t`t<Box>`r`n`t`t`t`t`t`t<Left>15.9979</Left>`r`n`t`t`t`t`t`t<Top>43.2384</Top>`r`n`t`t`t`t`t`t<Right>194.342</Right>`r`n`t`t`t`t`t`t<Bottom>222.5</Bottom>"

function New-TextField([string]$Name, [double]$Left, [double]$Top, [double]$Right, [double]$Bottom, [string]$ColorTable, [string]$Body, [int]$Border, [int]$DrawBorder) {
    $rtf = "{\rtf1\ansi\ansicpg1252\deff0\nouicompat\deflang1033{\fonttbl{\f0\fnil\fcharset0 Arial;}}`r`n{\colortbl ;$ColorTable}`r`n{\*\generator Riched20 10.0.15063}\viewkind4\uc1 `r`n$Body`r`n}"
    $def = "{\rtf1\ansi\ansicpg1252\deff0\deflang1031{\fonttbl{\f0\fnil\fcharset0 Arial;}}`r`n{\colortbl ;\red0\green0\blue0;}`r`n\viewkind4\uc1\pard\sl264\slmult1\tx720\cf1\f0\fs24\par`r`n}"
    $i = "`t`t`t`t"
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $item = @"
$i<Item>
$i`t<Name>$Name</Name>
$i`t<Box>
$i`t`t<Left>$($Left.ToString($inv))</Left>
$i`t`t<Top>$($Top.ToString($inv))</Top>
$i`t`t<Right>$($Right.ToString($inv))</Right>
$i`t`t<Bottom>$($Bottom.ToString($inv))</Bottom>
$i`t</Box>
$i`t<Alpha>0</Alpha>
$i`t<BackgroundColor>16777215</BackgroundColor>
$i`t<BorderColor>$Border</BorderColor>
$i`t<DrawBorder>$DrawBorder</DrawBorder>
$i`t<Spacing>1</Spacing>
$i`t<WidthInMM>1.4</WidthInMM>
$i`t<Rtf>$rtf</Rtf>
$i`t<DefaultTextFormat>$def</DefaultTextFormat>
$i`t<FactoryKey>text field</FactoryKey>
$i</Item>
"@
    return ($item -replace "`r?`n", "`r`n")
}

New-Item -ItemType Directory -Force -Path $Target | Out-Null
$variants = [ordered]@{
    'VL_Report_OK'  = @{ R = 0; G = 140; B = 50 }
    'VL_Report_NOK' = @{ R = 210; G = 20; B = 20 }
}
foreach ($v in $variants.Keys) {
    $c = $variants[$v]
    # BorderColor is ARGB as int32 (black = -16777216 = 0xFF000000)
    $argb = -16777216 + ($c.R * 65536) + ($c.G * 256) + $c.B
    $ct = "\red0\green0\blue0;\red$($c.R)\green$($c.G)\blue$($c.B);"
    $verdict = New-TextField 'result' 18 224 66 239.5 $ct '\pard\sl264\slmult1\sb60\qc\tx720\cf2\b\fs52 $_REPORT_CUSTOM_RESULT\par' $argb 1
    $summary = New-TextField 'summary' 70 224 193.5 239.5 $ct ('\pard\sl264\slmult1\tx720\cf1\b\fs22 $_REPORT_CUSTOM_SUMMARY\b0\par' + "`r`n" + '\fs18 VL program: $_REPORT_CUSTOM_PROGRAM\par' + "`r`n" + 'Scan: $_REPORT_CUSTOM_SCAN\par') -16777216 0
    $t = $base.Replace('<Name>A4_Portrait.ezl</Name>', "<Name>$v.ezl</Name>").Replace('<Directory>A4_Portrait_Files</Directory>', "<Directory>${v}_Files</Directory>")
    # the new fields go to the end of the cover page items
    $anchor = "`t`t`t</Items>`r`n`t`t`t<PageBackground>Cover page</PageBackground>"
    $t = Replace-Required $t $anchor ($verdict + "`r`n" + $summary + "`r`n" + $anchor)
    [IO.File]::WriteAllText((Join-Path $Target "$v.ezl"), $t, (New-Object Text.UTF8Encoding($false)))
    $files = Join-Path $Target "${v}_Files"
    New-Item -ItemType Directory -Force -Path $files | Out-Null
    if (Test-Path -LiteralPath $srcFiles) { Copy-Item -Path (Join-Path $srcFiles '*') -Destination $files -Force }
    "Created $(Join-Path $Target "$v.ezl")"
}
