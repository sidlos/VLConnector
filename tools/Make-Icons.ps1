<#
  Development tool: draws the VL Connector logo - the letters "VL" as two plain shapes in slate grey with a thin
  white outline (unseen on light backgrounds, readable on a dark taskbar) - and writes every icon file in
  app\assets from that one drawing:
      VLC_icon.ico       16, 24, 32, 48, 64 and 256 px (PNG entries): shortcuts, notification area
      VLC_icon_256.png   settings window, setup wizard
      VLC_icon_64.png, VLC_icon_32.png
      VLC_icon.svg       the PolyWorks ribbon button. PolyWorks draws only vector SVG icons of at most 32767
                         bytes (a picture inside the SVG stays empty), so the SVG holds the same two shapes.
  The logo is our own drawing: VL Connector must not look like official KEYENCE software.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot) 'app\assets'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$color = '#334155'
# the two letters in a 100 x 100 grid (V with a flat foot, L), stroke width 13
$sw = 13; $top = 20; $bottom = 80
$v = @(@(6, $top), @((6 + $sw * 1.15), $top), @(30, ($bottom - $sw * 1.25)), @((54 - $sw * 1.15), $top), @(54, $top), @((30 + $sw * 0.62), $bottom), @((30 - $sw * 0.62), $bottom))
$l = @(@(61, $top), @((61 + $sw), $top), @((61 + $sw), ($bottom - $sw)), @(94, ($bottom - $sw)), @(94, $bottom), @(61, $bottom))
$letters = @(, $v) + @(, $l)

function New-LogoBitmap([int]$Px) {
    $bmp = New-Object Drawing.Bitmap $Px, $Px
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([Drawing.Color]::Transparent)
    $g.ScaleTransform($Px / 100.0, $Px / 100.0)
    $brush = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($color))
    # a thin white outline: invisible on light backgrounds, keeps the letters readable on a dark taskbar
    $halo = New-Object Drawing.Pen ([Drawing.Color]::White), ([single][Math]::Max(6, 200.0 / $Px))
    $halo.LineJoin = 'Round'
    foreach ($shape in $letters) {
        $points = [Drawing.PointF[]]@($shape | ForEach-Object { New-Object Drawing.PointF ([single]$_[0]), ([single]$_[1]) })
        $g.DrawPolygon($halo, $points)
    }
    foreach ($shape in $letters) { $g.FillPolygon($brush, [Drawing.PointF[]]@($shape | ForEach-Object { New-Object Drawing.PointF ([single]$_[0]), ([single]$_[1]) })) }
    $g.Dispose()
    return $bmp
}

# Icon entry as a 32-bit bitmap (bottom-up BGRA rows, then an empty AND mask): small sizes must not be PNG,
# System.Drawing (notification area icon) cannot draw PNG entries below 256 px
function Get-BmpEntry($Bmp) {
    $n = $Bmp.Width
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter($ms)
    $w.Write([uint32]40); $w.Write([int32]$n); $w.Write([int32]($n * 2)); $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]0); $w.Write([uint32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) { $c = $Bmp.GetPixel($x, $y); $w.Write([byte]$c.B); $w.Write([byte]$c.G); $w.Write([byte]$c.R); $w.Write([byte]$c.A) }
    }
    $w.Write((New-Object byte[] ([int][Math]::Ceiling($n / 32.0) * 4 * $n)))
    $w.Flush()
    return , $ms.ToArray()   # the comma keeps PowerShell from unrolling the byte array
}

$sizes = 16, 24, 32, 48, 64, 256
$pngs = @{}
foreach ($size in $sizes) {
    $bmp = New-LogoBitmap $size
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    if ($size -in 32, 64, 256) { [IO.File]::WriteAllBytes((Join-Path $OutDir "VLC_icon_$size.png"), $ms.ToArray()) }
    if ($size -eq 256) { $pngs[$size] = [byte[]]$ms.ToArray() } else { $pngs[$size] = [byte[]](Get-BmpEntry $bmp) }
    $bmp.Dispose()
}

# ICO: header, one directory entry per size, then the image data (256 px as PNG, the others as bitmaps)
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

# SVG with the same two shapes
$inv = [Globalization.CultureInfo]::InvariantCulture
$d = ($letters | ForEach-Object { 'M' + (($_ | ForEach-Object { $_[0].ToString('0.##', $inv) + ' ' + $_[1].ToString('0.##', $inv) }) -join ' L') + ' Z' }) -join ' '
$svg = '<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 100 100">' + "`n" +
       "  <path fill=`"#FFFFFF`" stroke=`"#FFFFFF`" stroke-width=`"6.25`" stroke-linejoin=`"round`" d=`"$d`"/>" + "`n" +
       "  <path fill=`"$color`" d=`"$d`"/>" + "`n" + '</svg>' + "`n"
if ($svg.Length -gt 32767) { throw "The SVG icon has $($svg.Length) bytes; PolyWorks takes at most 32767." }
[IO.File]::WriteAllText((Join-Path $OutDir 'VLC_icon.svg'), $svg, (New-Object Text.UTF8Encoding($false)))
Get-ChildItem $OutDir -Filter 'VLC_icon*' | ForEach-Object { '{0} {1} B' -f $_.Name, $_.Length }
