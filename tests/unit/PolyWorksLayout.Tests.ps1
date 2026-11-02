# Pester 3.4 unit tests: the button picture in the format of a PolyWorks visual layout (layout.xml and the
# icon entry of the macro), without PolyWorks.
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
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

Describe 'VL Connector tab in the ribbon' {
    # the structure of PolyWorks 2026 layout.xml, shortened; built-in tabs carry a resource name in any language
    $ribbon = '<CommandBar Class="CRibbonBar" BarID="25"><Tabs><Tab Class="CIMXtRibbonTab" Caption="Start" resString="Ribbon Home" tabType="0"><Groups/></Tab>' +
        '<Tab Class="CIMXtRibbonTab" Caption="Hilfe" resString="Ribbon Help" tabType="0"><Groups/></Tab>' +
        '<Tab Class="CIMXtRibbonTab" Caption="VL Connector" Selected="1" tabType="2"><Groups><Group Class="CIMXtRibbonGroup" Caption="VL Connector" groupType="2"><Controls><Control resString="VLC_Measure_Button_old.pwmacro"/></Controls></Group></Groups></Tab>' +
        '<Tab Class="CIMXtRibbonTab" Caption="Context" resString="Ribbon Data" tabType="1"><Groups/></Tab></Tabs></CommandBar>' +
        '<CommandBar Class="CIMXtToolBar" Title="Macros from VL Connector buttons" Id="1"><Controls/></CommandBar>'
    $control = '<Control Class="CIMXtControlButtonMacro" Caption="Measure" resString="VLC_Measure_Button.pwmacro"/>'
    It 'removes the tab of an earlier Add and the hidden import toolbar' {
        $clean = Remove-VlcLayoutParts $ribbon
        $clean | Should Not Match 'Caption="VL Connector"'
        $clean | Should Not Match 'Macros from VL Connector'
        $clean | Should Match 'Caption="Hilfe"'
    }
    It 'puts the tab after Help, found in any language, and after the last tab of the user' {
        $xml = Add-VlcRibbonTab (Remove-VlcLayoutParts $ribbon) $control
        $xml | Should Match ('resString="Ribbon Help" tabType="0"><Groups/></Tab><Tab Class="CIMXtRibbonTab" Caption="VL Connector" tabType="2"><Groups><Group [^>]*><Controls>' + [regex]::Escape($control))
        # a second Add replaces the tab of the first one
        Add-VlcRibbonTab (Remove-VlcLayoutParts $xml) $control | Should Be $xml
        $own = (Remove-VlcLayoutParts $ribbon) -replace '(<Tab Class="CIMXtRibbonTab" Caption="Context")', '<Tab Class="CIMXtRibbonTab" Caption="Mine" tabType="2"><Groups/></Tab>$1'
        Add-VlcRibbonTab $own $control | Should Match ('Caption="Mine" tabType="2"><Groups/></Tab><Tab Class="CIMXtRibbonTab" Caption="VL Connector"')
    }
    It 'finds no ribbon in the layout of a ribbon nobody has changed' {
        Test-VlcRibbonInLayout $ribbon | Should Be $true
        Test-VlcRibbonInLayout '<Settings><CommandBars Schema="45"><Layout><DockState/></Layout></CommandBars></Settings>' | Should Be $false
        Add-VlcRibbonTab '<Settings/>' $control | Should Be ''
    }
}
