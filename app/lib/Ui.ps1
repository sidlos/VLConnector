# WPF helpers shared by the windows of VL Connector. Dot-source this file (it has no param block).
# Windows are plain XAML files in app\ui; this file loads them, applies the theme and finds controls.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:UiDir = Join-Path (Split-Path $PSScriptRoot) 'ui'
$script:AssetDir = Join-Path (Split-Path $PSScriptRoot) 'assets'

# One WPF Application per process; its resources hold the theme, so StaticResource works in every window.
function Initialize-Ui {
    if (-not [System.Windows.Application]::Current) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = 'OnExplicitShutdown'
    }
    $app = [System.Windows.Application]::Current
    if ($app.Resources.MergedDictionaries.Count -eq 0) {
        $theme = Import-XamlObject (Join-Path $script:UiDir 'Theme.xaml')
        $app.Resources.MergedDictionaries.Add($theme)
    }
    return $app
}

function Import-XamlObject([string]$Path) {
    $reader = [System.Xml.XmlReader]::Create($Path)
    try { return [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
}

# Loads a window and returns it plus a hashtable of all named elements.
function Import-Window([string]$Name) {
    [void](Initialize-Ui)
    $path = Join-Path $script:UiDir $Name
    $window = Import-XamlObject $path
    $names = @{}
    foreach ($m in [regex]::Matches([IO.File]::ReadAllText($path), '\bx:Name="([^"]+)"')) {
        $n = $m.Groups[1].Value
        $el = $window.FindName($n)
        if ($el) { $names[$n] = $el }
    }
    return [pscustomobject]@{ Window = $window; Controls = $names }
}

function Get-AppImage([string]$File) {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object Uri (Join-Path $script:AssetDir $File)
    $bmp.CacheOption = 'OnLoad'
    $bmp.EndInit()
    $bmp.Freeze()
    return $bmp
}

# Runs a script block in a background runspace and calls $Done with (output, error text) on the UI thread,
# so slow work (network folders) does not freeze the window.
function Start-UiJob([scriptblock]$Work, [object[]]$Arguments, [scriptblock]$Done) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($Work.ToString())
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Tag = [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $Done }
    $timer.Add_Tick({
        $job = $this.Tag
        if (-not $job.Handle.IsCompleted) { return }
        $this.Stop()
        $out = $null; $err = $null
        try { $out = $job.PS.EndInvoke($job.Handle) } catch { $err = $_.Exception.Message }
        if (-not $err -and $job.PS.Streams.Error.Count) { $err = $job.PS.Streams.Error[0].ToString() }
        $job.PS.Dispose()
        & $job.Done $out $err
    })
    $timer.Start()
}

function Get-Brush([string]$Key) { return [System.Windows.Application]::Current.Resources[$Key] }

# Renders a window offscreen to a PNG (documentation screenshots, no window is shown).
function Save-WindowImage($Window, [string]$Path, [int]$Width = 1100, [int]$Height = 740, [double]$Scale = 1.5) {
    $root = $Window.Content
    $Window.Content = $null
    $size = New-Object System.Windows.Size($Width, $Height)
    $root.Measure($size)
    $root.Arrange((New-Object System.Windows.Rect($size)))
    $root.UpdateLayout()
    $pxWidth = [int]($Width * $Scale); $pxHeight = [int]($Height * $Scale); $dpi = 96.0 * $Scale
    $bmp = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($pxWidth, $pxHeight, $dpi, $dpi, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    $Window.Content = $root
}
