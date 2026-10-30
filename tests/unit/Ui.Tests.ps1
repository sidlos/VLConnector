# Pester 3.4 unit tests: the windows load, and every control the window scripts use exists in their XAML (a
# renamed or removed control would otherwise only fail when an operator opens the window).
# the real profile is never touched: only tests\Run-Tests.ps1 -Unit runs these tests (TestGuard.ps1)
. (Join-Path $PSScriptRoot 'TestGuard.ps1')
$repo = Split-Path (Split-Path $PSScriptRoot)
$app = Join-Path $repo 'app'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

Describe 'windows' {
    $pairs = @(
        @{ Xaml = 'SettingsWindow.xaml'; Scripts = @('ui\SettingsForm.ps1'); Map = 'SettingControls' }
        @{ Xaml = 'WizardWindow.xaml'; Scripts = @('ui\WizardForm.ps1'); Map = 'WizardControls' })
    foreach ($pair in $pairs) {
        It "$($pair.Xaml) loads and has every control its script uses" {
            # loaded in an STA process, as VLConnector.cmd starts it
            $code = ". '$app\lib\Settings.ps1'; . '$app\lib\Ui.ps1'; (Import-Window '$($pair.Xaml)').Controls.Keys -join ','"
            $out = & $ps -NoProfile -STA -NonInteractive -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))) 2>&1 | Out-String
            $LASTEXITCODE | Should Be 0
            $names = @($out.Trim() -split ',')
            $names.Count | Should BeGreaterThan 20
            $used = foreach ($s in $pair.Scripts) {
                $text = [IO.File]::ReadAllText((Join-Path $app $s))
                [regex]::Matches($text, '\$(?:c|c2|script:sc|script:wc)\.([A-Za-z][A-Za-z0-9]*)') | ForEach-Object { $_.Groups[1].Value }
                # the key -> controls map of locked settings
                $block = [regex]::Match($text, "(?s)\`$script:$($pair.Map) = \[ordered\]@\{(.*?)\n\}").Groups[1].Value
                [regex]::Matches($block, "'([A-Z][A-Za-z0-9]+)'") | ForEach-Object { $_.Groups[1].Value }
            }
            $missing = @($used | Sort-Object -Unique | Where-Object { $names -notcontains $_ })
            $missing -join ', ' | Should Be ''
        }
    }
}
