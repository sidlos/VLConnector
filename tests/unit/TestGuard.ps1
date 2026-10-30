# Unit tests write settings, logs and job files into the profile folders APPDATA and LOCALAPPDATA.
# tests\Run-Tests.ps1 -Unit points both to a temporary profile for the whole run (VLC_TEST_PROFILE); a test file
# started any other way stops here, before it can touch the profile of the user who runs it.
foreach ($k in 'APPDATA', 'LOCALAPPDATA') {
    $value = [Environment]::GetEnvironmentVariable($k)
    if (-not $env:VLC_TEST_PROFILE -or -not $value -or -not $value.StartsWith($env:VLC_TEST_PROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Run the unit tests with tests\Run-Tests.ps1 -Unit: started on their own they would write into your profile ($k = $value)."
    }
}
