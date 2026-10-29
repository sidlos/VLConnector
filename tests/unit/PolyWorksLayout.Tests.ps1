# Pester 3.4 unit tests: the button picture in the format of a PolyWorks visual layout (layout.xml and the
# icon entry of the macro), without PolyWorks.
$app = Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'app'
foreach ($lib in 'Settings', 'PolyWorksLayout') { . (Join-Path $app "lib\$lib.ps1") }

function ConvertFrom-IconData([string]$Data) {
    $b = New-Object byte[] ($Data.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [byte](([int]$Data[2 * $i + 1] - 65) * 16 + ([int]$Data[2 * $i] - 65)) }
    return , $b
}

Describe 'button picture' {
    $svg = [Text.Encoding]::UTF8.GetBytes("<svg xmlns=`"http://www.w3.org/2000/svg`" viewBox=`"0 0 100 100`">`n  <path fill=`"#FFFFFF`" d=`"M0 0 L1 1 Z`"/>`n  <path fill=`"#334155`" d=`"M0 0 L1 1 Z`"/>`n</svg>`n")
    It 'writes the icon entry as length, SVG and 1' {
        $e = Get-VlcIconEntry $svg
        $e.Length | Should Be ($svg.Length + 6)
        [BitConverter]::ToUInt16($e, 0) | Should Be $svg.Length
        [BitConverter]::ToUInt32($e, 2 + $svg.Length) | Should Be 1
    }
    It 'writes the layout picture like PolyWorks: normal and grey picture' {
        $data = ConvertTo-VlcIconData $svg
        $data | Should Match '^[A-P]+$'
        # PolyWorks' own exports start the same way: 2 pictures, FF FF 2D 00 00 00
        $data.StartsWith('CAAAPPPPNCAAAAAA') | Should Be $true
        $b = ConvertFrom-IconData $data
        [BitConverter]::ToUInt16($b, 8) | Should Be $svg.Length
        [Text.Encoding]::UTF8.GetString($b, 10, $svg.Length) | Should Be ([Text.Encoding]::UTF8.GetString($svg))
        $at = 10 + $svg.Length
        [BitConverter]::ToUInt32($b, $at) | Should Be 1
        [BitConverter]::ToUInt16($b, $at + 4) | Should Be 0
        [BitConverter]::ToUInt32($b, $at + 6) | Should Be 0
        $len = [BitConverter]::ToUInt16($b, $at + 10)
        $grey = [Text.Encoding]::UTF8.GetString($b, $at + 12, $len)
        $b.Length | Should Be ($at + 12 + $len + 4)
        $grey | Should Match '#C5C5C5'
        $grey | Should Not Match '#334155'
    }
    It 'recognizes a control that holds the picture' {
        $control = '<Control Class="CIMXtControlButtonMacro" CustomIconId="11992" resString="VLC_Measure_Button.pwmacro"><CustomIcon><Icon Width="32" Data="' +
            (ConvertTo-VlcIconData $svg) + '"/></CustomIcon></Control>'
        Test-VlcIconData $control $svg | Should Be $true
        Test-VlcIconData $control ([Text.Encoding]::UTF8.GetBytes('<svg xmlns="http://www.w3.org/2000/svg"></svg>')) | Should Be $false
        Test-VlcIconData '<Control Class="CIMXtControlButtonMacro" resString="x.pwmacro"></Control>' $svg | Should Be $false
    }
}
