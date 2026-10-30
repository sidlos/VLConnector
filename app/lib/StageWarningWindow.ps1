<#
  The stage warning window of VL Connector. lib\StageWarning.ps1 runs this file in its own STA thread (WPF needs
  one with a message loop): the window waits hidden, shows the warning on request (on top of all windows,
  without ever taking the keyboard focus), plays the sound and reports when it is on screen. It is started as a
  file, not as script text, so an application control policy that trusts the program folder trusts it too.
  $Sync (synchronized hashtable): Request @{ Id; Text; Seconds; Sound; Avoid = left, top, right, bottom of VL's
  question } in, Hwnd / Ready / Shown (id of the request on screen) / Error out, Quit to end.
#>
param([Parameter(Mandatory = $true)] [hashtable]$Sync)

$ErrorActionPreference = 'Stop'
try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $window = [System.Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="VL Connector - stage rotation" WindowStyle="None" ResizeMode="NoResize" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" Focusable="False" SizeToContent="WidthAndHeight"
        WindowStartupLocation="Manual" Background="#B42318" FontFamily="Segoe UI" UseLayoutRounding="True">
    <Border BorderBrush="#7A1A12" BorderThickness="2" Padding="24,18">
        <StackPanel Orientation="Horizontal">
            <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="44" Foreground="White" VerticalAlignment="Center" Margin="0,0,20,0"/>
            <StackPanel MaxWidth="600" VerticalAlignment="Center">
                <TextBlock Text="The stage rotates - keep clear of the scanner" FontSize="22" FontWeight="SemiBold" Foreground="White"/>
                <TextBlock Name="Detail" FontSize="14" Foreground="White" TextWrapping="Wrap" Margin="0,6,0,0"/>
            </StackPanel>
        </StackPanel>
    </Border>
</Window>
'@)
    $player = $null
    $wav = Join-Path $env:SystemRoot 'Media\Windows Exclamation.wav'
    if (Test-Path -LiteralPath $wav) { $player = New-Object System.Media.SoundPlayer $wav; $player.Load() }
    $Sync.Hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $window).EnsureHandle()
    [VLConnector.Interop.Vl]::SetNoActivate($Sync.Hwnd)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $timer.Tag = [pscustomobject]@{ Sync = $Sync; Window = $window; Detail = $window.FindName('Detail'); Player = $player }
    $timer.Add_Tick({
        $t = $this.Tag
        $s = $t.Sync
        $request = $s.Request
        if ($request) {
            $s.Request = $null
            $t.Detail.Text = $request.Text
            $content = $t.Window.Content
            $content.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
            $width = $content.DesiredSize.Width
            $height = $content.DesiredSize.Height
            # top center of the screen; at the bottom when that would cover VL's question
            $area = [System.Windows.SystemParameters]::WorkArea
            $left = $area.Left + ($area.Width - $width) / 2
            $top = $area.Top + 24
            $avoid = @($request.Avoid)
            if ($avoid.Count -eq 4) {
                $scaleX = 1.0; $scaleY = 1.0
                $source = [System.Windows.PresentationSource]::FromVisual($t.Window)
                if ($source) { $m = $source.CompositionTarget.TransformFromDevice; $scaleX = $m.M11; $scaleY = $m.M22 }
                $r = @(($avoid[0] * $scaleX), ($avoid[1] * $scaleY), ($avoid[2] * $scaleX), ($avoid[3] * $scaleY))
                if ($left -lt $r[2] -and ($left + $width) -gt $r[0] -and $top -lt $r[3] -and ($top + $height) -gt $r[1]) { $top = $area.Bottom - $height - 24 }
            }
            $t.Window.Left = $left
            $t.Window.Top = $top
            $t.Window.Show()
            if ($request.Sound) { if ($t.Player) { $t.Player.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() } }
            $s.HideAt = [DateTime]::Now.AddSeconds([double]$request.Seconds)
            $s.Shown = $request.Id
        }
        if ($s.HideAt -and [DateTime]::Now -ge $s.HideAt) { $s.HideAt = $null; $t.Window.Hide() }
        if ($s.Quit) { $this.Stop(); $t.Window.Close(); $t.Window.Dispatcher.InvokeShutdown() }
    })
    $timer.Start()
    $Sync.Ready = $true
    [System.Windows.Threading.Dispatcher]::Run()
}
catch { $Sync.Error = $_.Exception.Message }
