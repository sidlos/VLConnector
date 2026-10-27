<#
  Development tool: draws the VL Connector icon (scanner head, laser fan, part, green check) and
  writes app\assets\VLC_icon_<size>.png and VLC_icon.ico (PNG-compressed icon entries).
  The SVG version (app\assets\VLC_icon.svg) shows the same drawing.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'app\assets'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function New-IconBitmap([int]$Px) {
    $s = $Px / 32.0
    $bmp = New-Object Drawing.Bitmap $Px, $Px
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $g.ScaleTransform($s, $s)
    function C([string]$Hex, [int]$A = 255) {
        [Drawing.Color]::FromArgb($A, [Convert]::ToInt32($Hex.Substring(0, 2), 16), [Convert]::ToInt32($Hex.Substring(2, 2), 16), [Convert]::ToInt32($Hex.Substring(4, 2), 16))
    }
    $dark = New-Object Drawing.SolidBrush (C '37474f')
    $g.FillRectangle($dark, 9, 1.5, 14, 5.5)
    $g.FillRectangle($dark, 14, 7, 4, 1.5)
    $fan = [Drawing.PointF[]]@((New-Object Drawing.PointF 16, 8.5), (New-Object Drawing.PointF 3.5, 21), (New-Object Drawing.PointF 28.5, 21))
    $g.FillPolygon((New-Object Drawing.SolidBrush (C 'ff8f00' 72)), $fan)
    $orange = New-Object Drawing.Pen (C 'ff6f00'), 1
    $g.DrawLine($orange, 16, 8.5, 3.5, 21)
    $g.DrawLine($orange, 16, 8.5, 28.5, 21)
    $g.FillRectangle((New-Object Drawing.SolidBrush (C '90a4ae')), 3, 21.5, 26, 7)
    $g.FillRectangle((New-Object Drawing.SolidBrush (C 'b0bec5')), 3, 21.5, 26, 2)
    $g.DrawLine((New-Object Drawing.Pen (C 'e53935'), 1.6), 3.5, 21, 28.5, 21)
    $g.FillEllipse((New-Object Drawing.SolidBrush (C '2e7d32')), 18, 18, 13, 13)
    $g.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::White), 1.2), 18, 18, 13, 13)
    $check = New-Object Drawing.Pen ([Drawing.Color]::White), 2
    $check.StartCap = 'Round'; $check.EndCap = 'Round'; $check.LineJoin = 'Round'
    $g.DrawLines($check, [Drawing.PointF[]]@((New-Object Drawing.PointF 21.3, 24.6), (New-Object Drawing.PointF 23.7, 27), (New-Object Drawing.PointF 27.8, 22.2)))
    $g.Dispose()
    return $bmp
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = @{}
foreach ($size in $sizes) {
    $bmp = New-IconBitmap $size
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $pngs[$size] = $ms.ToArray()
    if ($size -in 32, 64, 256) { [IO.File]::WriteAllBytes((Join-Path $OutDir "VLC_icon_$size.png"), $pngs[$size]) }
    $bmp.Dispose()
}

# ICO: header, one directory entry per size, then the PNG data
$ico = New-Object IO.MemoryStream
$w = New-Object IO.BinaryWriter($ico)
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($size in $sizes) {
    $dim = if ($size -ge 256) { 0 } else { $size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$size].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$size].Length
}
foreach ($size in $sizes) { $w.Write($pngs[$size]) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $OutDir 'VLC_icon.ico'), $ico.ToArray())
Get-ChildItem $OutDir -Filter 'VLC_icon*' | ForEach-Object { '{0} {1} B' -f $_.Name, $_.Length }
