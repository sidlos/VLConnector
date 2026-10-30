# WPF helpers shared by the windows of VL Connector. Dot-source this file (it has no param block).
# Windows are plain XAML files in app\ui; this file loads them, applies the theme and finds controls.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

$script:UiDir = Join-Path (Split-Path $PSScriptRoot) 'ui'
$script:AssetDir = Join-Path (Split-Path $PSScriptRoot) 'assets'
$script:UiWorkScript = Join-Path $PSScriptRoot 'UiWork.ps1'

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

# Runs lib\UiWork.ps1 -Work <name> in a background runspace and calls $Done with (output, error text) on the UI
# thread, so slow work (network folders) does not freeze the window. The work runs as a file, not as script
# text: an application control policy that trusts the program folder trusts it too.
function Start-UiJob([ValidateSet('Status', 'ShareTest')] [string]$Work, [hashtable]$Parameters, [scriptblock]$Done) {
    $ps = [PowerShell]::Create()
    [void]$ps.AddCommand($script:UiWorkScript).AddParameter('Work', $Work)
    foreach ($k in $Parameters.Keys) { [void]$ps.AddParameter($k, $Parameters[$k]) }
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

# Starts app\Set-MachinePolicy.ps1 -Show <dialog> with administrator rights (Windows asks: UAC) and calls $Done on
# the UI thread when it has ended. Returns $false when the administrator prompt was cancelled. Needs lib\Settings.ps1.
function Start-VlcPolicyTool([ValidateSet('StageMotion', 'VlExe')] [string]$Show, [scriptblock]$Done) {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $tool = Join-Path (Get-VlcPaths).AppDir 'Set-MachinePolicy.ps1'
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try {
        $p = Start-Process -FilePath $ps -Verb RunAs -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned',
            '-WindowStyle', 'Hidden', '-File', "`"$tool`"", '-Show', $Show, '-RequestedBy', "`"$me`""
    }
    catch { return $false }
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $timer.Tag = [pscustomobject]@{ Process = $p; Done = $Done }
    $timer.Add_Tick({
        if (-not $this.Tag.Process.HasExited) { return }
        $this.Stop()
        & $this.Tag.Done
    })
    $timer.Start()
    return $true
}

# Shows the controls of settings the administrator locked for this PC read-only, with the reason as tooltip.
# $Map: setting key -> control names. Returns $true when any of them is locked.
function Set-VlcLockedControls($Controls, $Map, [string[]]$Locked) {
    $any = $false
    foreach ($key in $Map.Keys) {
        $isLocked = $Locked -contains $key
        if ($isLocked) { $any = $true }
        foreach ($name in $Map[$key]) {
            $control = $Controls[$name]
            if (-not $control) { continue }
            $control.IsEnabled = -not $isLocked
            # not every style of the theme greys out a disabled control
            $control.Opacity = if ($isLocked) { 0.5 } else { 1.0 }
            $control.ToolTip = if ($isLocked) { 'Set by the administrator for all users of this PC' } else { $null }
            [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($control, $true)
        }
    }
    return $any
}

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
