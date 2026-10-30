# Installation and removal of VL Connector, used by Install.ps1 and Uninstall.ps1 at the package root.
# Dot-source this file; it needs nothing else.
#
# The machine part runs as administrator (docs\IT-Review, installation). It reads the package manifest once,
# stages the files in <folder>.new under an administrator-only ACL, builds the interface DLL and the button files
# there, checks the staged copy against the manifest and its permissions, and swaps the folders; the previous
# version stays in <folder>.old for one rollback. Nothing here follows a junction or symbolic link.
# Exit codes of Install.cmd and Uninstall.cmd: 0 done, 1 failed, 2 cancelled, 740 administrator rights needed,
# 1618 VL Connector is in use (close it, or let the software deployment retry later).

$script:VlcSid = @{
    System = 'S-1-5-18'; Admins = 'S-1-5-32-544'; Users = 'S-1-5-32-545'
    TrustedInstaller = 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
}
# written by the installer itself, so not in the package manifest
$script:VlcGeneratedFiles = 'machine.json', 'install-info.txt', 'bin/VLConnector.Interop.dll', 'VLC_Measure_Button.pwmacro', 'VLC_Station_Button.pwmacro'
$script:VlcForwarderNote = 'VLConnector-moved.txt'

function Test-VlcAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VlcSha256([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return -join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
}

# Runs a Windows tool (icacls, takeown); its error output does not stop the script. Returns ExitCode and Output.
function Invoke-VlcTool([string]$Name, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = & (Join-Path $env:SystemRoot "System32\$Name") @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out.Trim() }
}

# ------------------------------------------------------------------------------------------------
# Package manifest
# ------------------------------------------------------------------------------------------------

# MANIFEST.sha256 of a package or an installed copy ("<sha256>  <relative/path>" per line), read once: Entries
# (path -> hash), Bytes (to write exactly this manifest) and Fingerprint (its SHA-256, shown to the user). Throws
# when it is missing or empty, or when a line is not a plain relative path.
function Read-VlcManifest([string]$Root) {
    $file = Join-Path $Root 'MANIFEST.sha256'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "MANIFEST.sha256 is missing in $Root." }
    $bytes = [IO.File]::ReadAllBytes($file)
    $entries = [ordered]@{}
    $n = 0
    foreach ($line in ([Text.Encoding]::UTF8.GetString($bytes) -split "`r?`n")) {
        $n++
        if (-not $line) { continue }
        if ($line -notmatch '^([0-9a-f]{64})  ([A-Za-z0-9_. /-]+)$') { throw "MANIFEST.sha256 line $n is not '<sha256>  <path>'." }
        $hash = $Matches[1]
        $path = $Matches[2]
        if ($path -match '(^|/)\.{1,2}(/|$)|^/|//|/$' -or $path -ieq 'MANIFEST.sha256') { throw "MANIFEST.sha256 line ${n}: '$path' is not a plain relative path." }
        if ($entries.Contains($path)) { throw "MANIFEST.sha256 names $path twice." }
        $entries[$path] = $hash
    }
    if (-not $entries.PSBase.Count) { throw 'MANIFEST.sha256 is empty.' }
    return [pscustomobject]@{ Entries = $entries; Bytes = $bytes; Fingerprint = Get-VlcSha256 $bytes }
}

# The text encoding of a file by its byte order mark: Encoding (writes no BOM) and Bom (its bytes).
function Get-VlcTextEncoding([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
        return [pscustomobject]@{ Encoding = (New-Object Text.UTF8Encoding($false)); Bom = [byte[]]@(0xEF, 0xBB, 0xBF) }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) { return [pscustomobject]@{ Encoding = (New-Object Text.UnicodeEncoding($false, $false)); Bom = [byte[]]@(0xFF, 0xFE) } }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) { return [pscustomobject]@{ Encoding = (New-Object Text.UnicodeEncoding($true, $false)); Bom = [byte[]]@(0xFE, 0xFF) } }
    return [pscustomobject]@{ Encoding = (New-Object Text.UTF8Encoding($false)); Bom = [byte[]]@() }
}

# The hashes a file may have in the manifest: its own, and for a PowerShell script that IT signed (an Authenticode
# signature block at its end) also that of the text before the block, with and without one line break before it.
function Get-VlcAcceptedHashes([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hashes = New-Object Collections.Generic.List[string]
    $hashes.Add((Get-VlcSha256 $bytes))
    if ([IO.Path]::GetExtension($Path) -in '.ps1', '.psm1', '.psd1') {
        $enc = Get-VlcTextEncoding $bytes
        $text = $enc.Encoding.GetString($bytes, $enc.Bom.Length, $bytes.Length - $enc.Bom.Length)
        $i = $text.LastIndexOf('# SIG # Begin signature block')
        if ($i -ge 0 -and $text.Substring($i).TrimEnd() -match '# SIG # End signature block$') {
            $head = $text.Substring(0, $i)
            foreach ($t in $head, ($head -replace '\r\n\z', '')) { $hashes.Add((Get-VlcSha256 ([byte[]]($enc.Bom + $enc.Encoding.GetBytes($t))))) }
        }
    }
    return $hashes.ToArray()
}

# Every file below a folder: Path, Rel (relative, with '/'), Link, Directory. A junction or symbolic link is listed
# (Link) and never entered. -Directories: the folders themselves too.
function Get-VlcTreeFiles([string]$Root, [switch]$Directories) {
    $root = $Root.TrimEnd('\')
    $result = [Collections.Generic.List[object]]::new()
    $stack = New-Object Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($dir)) {
            $attr = [IO.File]::GetAttributes($entry)
            $isDir = [bool]($attr -band [IO.FileAttributes]::Directory)
            $link = [bool]($attr -band [IO.FileAttributes]::ReparsePoint)
            $item = [pscustomobject]@{ Path = $entry; Rel = $entry.Substring($root.Length + 1) -replace '\\', '/'; Link = $link; Directory = $isDir }
            if ($isDir -and -not $link) {
                $stack.Push($entry)
                if ($Directories) { $result.Add($item) }
                continue
            }
            $result.Add($item)
        }
    }
    return $result.ToArray()
}

# Checks a folder against the manifest: missing and changed files and links are problems. Files the manifest does
# not name are problems too with -Strict (a staged or installed copy), otherwise only listed in Extra (a package:
# they are simply not installed). $Generated: files the installer writes itself.
function Test-VlcPackageTree([string]$Root, $Manifest, [string[]]$Generated = @(), [switch]$Strict) {
    $problems = New-Object Collections.Generic.List[string]
    $extra = New-Object Collections.Generic.List[string]
    foreach ($rel in $Manifest.Entries.PSBase.Keys) {
        $file = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { $problems.Add("missing: $rel"); continue }
        if ((Get-VlcAcceptedHashes $file) -notcontains $Manifest.Entries[$rel]) { $problems.Add("changed: $rel") }
    }
    foreach ($f in Get-VlcTreeFiles $Root) {
        if ($f.Link) { $problems.Add("link (not allowed): $($f.Rel)"); continue }
        if ($f.Rel -ieq 'MANIFEST.sha256' -or $Manifest.Entries.Contains($f.Rel) -or $Generated -contains $f.Rel) { continue }
        if ($Strict) { $problems.Add("not in the package: $($f.Rel)") } else { $extra.Add($f.Rel) }
    }
    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = $problems.ToArray(); Extra = $extra.ToArray(); Fingerprint = $Manifest.Fingerprint }
}

# Copies the files of the manifest from the package into a folder and checks every copy against the manifest read
# before (a file changed in the package meanwhile is refused). Only these files are copied and only these lose the
# "downloaded from the internet" mark; the manifest is written from memory.
function Copy-VlcPackage([string]$Source, [string]$Target, $Manifest) {
    foreach ($rel in $Manifest.Entries.PSBase.Keys) {
        $from = Join-Path $Source ($rel -replace '/', '\')
        $to = Join-Path $Target ($rel -replace '/', '\')
        [void][IO.Directory]::CreateDirectory((Split-Path $to))
        [IO.File]::Copy($from, $to, $true)
        if ((Get-VlcAcceptedHashes $to) -notcontains $Manifest.Entries[$rel]) { throw "The copy of $rel differs from the package manifest." }
        Unblock-File -LiteralPath $to -ErrorAction SilentlyContinue
    }
    [IO.File]::WriteAllBytes((Join-Path $Target 'MANIFEST.sha256'), $Manifest.Bytes)
}

# ------------------------------------------------------------------------------------------------
# Versions and folders
# ------------------------------------------------------------------------------------------------

function ConvertTo-VlcVersionParts([string]$Version) {
    if ($Version.Trim() -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z]+)\.?(\d+))?$') { throw "'$Version' is not a VL Connector version." }
    $pre = [string]$Matches[4]
    $preNumber = if ($Matches[5]) { [int64]$Matches[5] } else { [int64]0 }
    return @([int64]$Matches[1], [int64]$Matches[2], [int64]$Matches[3], [int64]$(if ($pre) { 0 } else { 1 }), $pre.ToLowerInvariant(), $preNumber)
}

# Compares two VL Connector versions (1.0.0, 1.0.0-rc11): -1, 0 or 1. A release is newer than its candidates
# (1.0.0-rc11 < 1.0.0), numbers compare as numbers (rc9 < rc10). Throws for a text that is no version.
function Compare-VlcVersion([string]$A, [string]$B) {
    $pa = ConvertTo-VlcVersionParts $A
    $pb = ConvertTo-VlcVersionParts $B
    for ($i = 0; $i -lt $pa.Count; $i++) {
        $c = if ($pa[$i] -is [string]) { [string]::CompareOrdinal($pa[$i], $pb[$i]) } else { $pa[$i].CompareTo($pb[$i]) }
        if ($c) { return [Math]::Sign($c) }
    }
    return 0
}

# What a folder holds: $null (missing or empty); Kind 'VLConnector' with its Version (an installation, also one
# of 1.0.0-rc10), 'Forwarders' (left by the installer at the place of an old installation) or 'Other'.
function Get-VlcFolderKind([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) { return $null }
    if (-not @([IO.Directory]::GetFileSystemEntries($Dir)).Count) { return $null }
    if (Test-Path -LiteralPath (Join-Path $Dir $script:VlcForwarderNote) -PathType Leaf) { return [pscustomobject]@{ Kind = 'Forwarders'; Version = '' } }
    $versionFile = Join-Path $Dir 'VERSION'
    if ((Test-Path -LiteralPath (Join-Path $Dir 'app\VLReplay.ps1') -PathType Leaf) -and (Test-Path -LiteralPath $versionFile -PathType Leaf)) {
        return [pscustomobject]@{ Kind = 'VLConnector'; Version = ([IO.File]::ReadAllText($versionFile)).Trim() }
    }
    return [pscustomobject]@{ Kind = 'Other'; Version = '' }
}

# Checks the install folder before anything is changed and throws with the reason: not a full local path, a
# Windows or shared folder itself, the folder of the package (C77), a link, a folder with other content, or a
# newer VL Connector (unless -Force). Returns the version installed there now ('' for none).
function Test-VlcInstallTarget([string]$Source, [string]$Target, [string]$Version, [switch]$Force) {
    if ($Target -notmatch '^[A-Za-z]:\\[^\\]') { throw "Install folder '$Target': use a full local path such as C:\Program Files\VLConnector." }
    $t = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $s = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    if ($t -ieq $s -or $t.StartsWith("$s\", [StringComparison]::OrdinalIgnoreCase) -or $s.StartsWith("$t\", [StringComparison]::OrdinalIgnoreCase)) {
        throw "The package is in the install folder $t. Unpack the package to another folder and start Install.cmd there."
    }
    $windows = [IO.Path]::GetFullPath($env:SystemRoot).TrimEnd('\')
    if ($t -ieq $windows -or $t.StartsWith("$windows\", [StringComparison]::OrdinalIgnoreCase)) { throw "VL Connector cannot be installed in $windows." }
    foreach ($shared in $env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData, (Split-Path $env:PUBLIC), $env:USERPROFILE) {
        if ($shared -and $t -ieq [IO.Path]::GetFullPath($shared).TrimEnd('\')) { throw "$t cannot be the install folder itself; use a folder of its own, e.g. $t\VLConnector." }
    }
    if (Test-Path -LiteralPath $t) {
        if ([IO.File]::GetAttributes($t) -band [IO.FileAttributes]::ReparsePoint) { throw "$t is a link to another folder; choose a real folder." }
        if (-not (Test-Path -LiteralPath $t -PathType Container)) { throw "$t is a file." }
    }
    $kind = Get-VlcFolderKind $t
    if ($kind -and $kind.Kind -ne 'VLConnector') { throw "$t is not empty and holds no VL Connector; choose an empty folder." }
    $installed = if ($kind) { $kind.Version } else { '' }
    if ($installed -and -not $Force) {
        $newer = $false
        try { $newer = (Compare-VlcVersion $installed $Version) -gt 0 } catch { }
        if ($newer) { throw "VL Connector $installed is installed, which is newer than this package ($Version). Use -Force to install the older version." }
    }
    return $installed
}

# Moves a folder; tries again for a few seconds (a virus scanner or an Explorer window can hold it briefly).
function Move-VlcFolder([string]$From, [string]$To) {
    for ($i = 1; ; $i++) {
        try { [IO.Directory]::Move($From, $To); return }
        catch {
            if ($i -ge 10) { throw "$From cannot be renamed to ${To}: $($_.Exception.GetBaseException().Message) Close windows and programs that use it." }
            Start-Sleep -Milliseconds 500
        }
    }
}

# Puts a staged copy in place: the installed folder becomes <folder>.old (an older .old is deleted first) and the
# stage becomes the folder. When that fails, the installed folder is put back.
function Invoke-VlcFolderSwap([string]$Stage, [string]$Target) {
    $old = "$Target.old"
    if (Test-Path -LiteralPath $old) { Remove-VlcTree $old }
    $had = Test-Path -LiteralPath $Target
    if ($had) { Move-VlcFolder $Target $old }
    try { Move-VlcFolder $Stage $Target }
    catch {
        $why = $_.Exception.Message
        if ($had) {
            try { Move-VlcFolder $old $Target }
            catch { throw "$why The previous version could not be put back either; it is in $old." }
        }
        throw $why
    }
}

# An item an administrator cannot delete (a folder users could change in 1.0.0-rc10) is taken over: owner
# Administrators, full control for them. A link is only given the right (icacls /L), never taken over: takeown
# would act on its target.
function Grant-VlcAdminAccess([string]$Path, [bool]$IsLink) {
    if (-not $IsLink) { [void](Invoke-VlcTool 'takeown.exe' @('/F', $Path, '/A')) }
    [void](Invoke-VlcTool 'icacls.exe' @($Path, '/grant', "*$($script:VlcSid.Admins):F", '/L', '/Q'))
}

# Deletes a folder (or file) and everything in it. A junction or symbolic link is removed itself, never followed;
# read-only files are deleted too. -TakeOwnership (administrator): an item that cannot be deleted is taken over
# first. Throws when something cannot be deleted.
function Remove-VlcTree([string]$Path, [switch]$TakeOwnership) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $attr = [IO.File]::GetAttributes($Path)
    $isDir = [bool]($attr -band [IO.FileAttributes]::Directory)
    $isLink = [bool]($attr -band [IO.FileAttributes]::ReparsePoint)
    for ($try = 1; ; $try++) {
        try {
            if ($isDir -and -not $isLink) {
                foreach ($entry in [IO.Directory]::GetFileSystemEntries($Path)) { Remove-VlcTree $entry -TakeOwnership:$TakeOwnership }
            }
            if (-not $isLink -and ($attr -band [IO.FileAttributes]::ReadOnly)) { [IO.File]::SetAttributes($Path, ($attr -band -bnot [IO.FileAttributes]::ReadOnly)) }
            if ($isDir) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
            return
        }
        catch {
            if (-not $TakeOwnership -or $try -ge 2) { throw "$Path cannot be deleted: $($_.Exception.GetBaseException().Message)" }
            Grant-VlcAdminAccess $Path $isLink
        }
    }
}

# ------------------------------------------------------------------------------------------------
# Permissions
# ------------------------------------------------------------------------------------------------

# Gives a folder the administrator-only ACL: full control for SYSTEM and Administrators, read and run for Users,
# nothing inherited from above; files created in it inherit this. -Owner: everything in it (made by the installer)
# also gets the owner Administrators. icacls errors stop the installation (C19-C21).
function Set-VlcAdminOnlyAcl([string]$Path, [switch]$Owner) {
    $r = Invoke-VlcTool 'icacls.exe' @($Path, '/inheritance:r', '/grant:r', "*$($script:VlcSid.System):(OI)(CI)F", "*$($script:VlcSid.Admins):(OI)(CI)F", "*$($script:VlcSid.Users):(OI)(CI)RX", '/Q')
    if ($r.ExitCode -ne 0) { throw "icacls could not set the permissions of ${Path}: $($r.Output)" }
    if ($Owner) {
        $r = Invoke-VlcTool 'icacls.exe' @($Path, '/setowner', "*$($script:VlcSid.Admins)", '/T', '/Q')
        if ($r.ExitCode -ne 0) { throw "icacls could not set the owner of ${Path}: $($r.Output)" }
    }
}

function ConvertTo-VlcAccountName([string]$Sid) {
    try { return (New-Object Security.Principal.SecurityIdentifier($Sid)).Translate([Security.Principal.NTAccount]).Value } catch { return $Sid }
}

# What lets someone other than SYSTEM, the administrators or TrustedInstaller change a folder: an owner who is not
# one of them, or an allow rule with write, delete, permission or ownership rights. -Recurse: every folder and file
# in it too (links are not followed). -Parents: the folders above it, where renaming one of them (delete right) or
# a subfolder, or changing the permissions, is what counts: the program folder could be swapped for another one.
# Returns the problems as texts.
function Get-VlcAclProblems([string]$Path, [switch]$Recurse, [switch]$Parents) {
    $trusted = $script:VlcSid.System, $script:VlcSid.Admins, $script:VlcSid.TrustedInstaller
    $generic = 0x40000000 -bor 0x10000000   # GENERIC_WRITE, GENERIC_ALL
    $rights = if ($Parents) { 'Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' }
        else { 'WriteData, AppendData, WriteExtendedAttributes, WriteAttributes, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership' }
    $mask = [int64]([Security.AccessControl.FileSystemRights]$rights) -bor $generic
    $root = $Path.TrimEnd('\')
    $items = New-Object Collections.Generic.List[string]
    if ($Parents) {
        for ($p = Split-Path $root; $p; $p = Split-Path $p) { if (Test-Path -LiteralPath $p) { $items.Add($p) } }
    }
    else {
        $items.Add($root)
        if ($Recurse) { foreach ($f in Get-VlcTreeFiles $root -Directories) { $items.Add($f.Path) } }
    }
    $problems = New-Object Collections.Generic.List[string]
    foreach ($item in $items) {
        $name = if ($Parents -or $item -eq $root) { $item } else { $item.Substring($root.Length + 1) }
        try {
            $acl = Get-Acl -LiteralPath $item
            $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($trusted -notcontains $owner) { $problems.Add("${name}: owner $(ConvertTo-VlcAccountName $owner)") }
            foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
                if ($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
                $sid = $rule.IdentityReference.Value
                if ($trusted -contains $sid) { continue }
                if (([int64]$rule.FileSystemRights) -band $mask) { $problems.Add("${name}: $(ConvertTo-VlcAccountName $sid) may change it ($($rule.FileSystemRights))") }
            }
        }
        catch { $problems.Add("${name}: permissions cannot be read ($($_.Exception.Message))") }
    }
    return $problems.ToArray()
}

# ------------------------------------------------------------------------------------------------
# Processes, profiles, Start menu, event source
# ------------------------------------------------------------------------------------------------

# VL Connector processes in every session that run scripts of one of the folders. Kind: Agent (also its watcher,
# VLReplay.ps1 -Watch), Launcher (a scan), Station (a step of the PolyWorks station), Window (settings, wizard,
# administrator tool) or Other (a step of the PolyWorks macros). $Processes: for tests, objects with ProcessId,
# SessionId and CommandLine instead of the processes that run (all sessions need administrator rights).
function Get-VlcProcesses([string[]]$Dirs, $Processes = $null) {
    if ($null -eq $Processes) { $Processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue) }
    foreach ($p in @($Processes)) {
        $cmd = [string]$p.CommandLine
        foreach ($dir in @($Dirs | Where-Object { $_ })) {
            $app = [IO.Path]::GetFullPath((Join-Path $dir 'app')).TrimEnd('\') + '\'
            $i = $cmd.IndexOf($app, [StringComparison]::OrdinalIgnoreCase)
            if ($i -lt 0) { continue }
            $file = [regex]::Match($cmd.Substring($i + $app.Length), '^[^"]+?\.ps1').Value
            $kind = switch -Regex ($file) {
                '^Agent\.ps1$' { 'Agent' }
                '^VLReplay\.ps1$' { if ($cmd -match '\s-Watch\b') { 'Agent' } else { 'Launcher' } }
                '^polyworks\\Station-Step\.ps1$' { 'Station' }
                '^(VLConnector|Set-MachinePolicy)\.ps1$' { 'Window' }
                default { 'Other' }
            }
            [pscustomobject]@{ ProcessId = [int]$p.ProcessId; SessionId = [int]$p.SessionId; Kind = $kind; Script = $file }
            break
        }
    }
}

# Stops the agents and their watchers: the one of this session first by its stop signal, then every one left in
# any session. Returns the sessions where an agent ran.
function Stop-VlcAgents([string[]]$Dirs) {
    $agents = @(Get-VlcProcesses $Dirs | Where-Object { $_.Kind -eq 'Agent' })
    if (-not $agents.Count) { return @() }
    $own = (Get-Process -Id $PID).SessionId
    $signal = $null
    if (@($agents | Where-Object { $_.SessionId -eq $own }).Count -and [Threading.EventWaitHandle]::TryOpenExisting('Local\VLConnector_AgentStop', [ref]$signal)) {
        [void]$signal.Set()
        $signal.Dispose()
        $until = (Get-Date).AddSeconds(12)
        while ((Get-Date) -lt $until -and @(Get-VlcProcesses $Dirs | Where-Object { $_.Kind -eq 'Agent' -and $_.SessionId -eq $own }).Count) { Start-Sleep -Milliseconds 300 }
    }
    # looked up again: a process id is never stopped after it may have been given to another program
    foreach ($a in @(Get-VlcProcesses $Dirs | Where-Object { $_.Kind -eq 'Agent' })) { Stop-Process -Id $a.ProcessId -Force -ErrorAction SilentlyContinue }
    return @($agents | ForEach-Object { $_.SessionId } | Select-Object -Unique)
}

# The profile folders of the Windows users of this PC (from the registry).
function Get-VlcProfileDirs {
    $list = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    return @(Get-ChildItem -LiteralPath $list -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'S-1-5-21-*' } |
        ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_.GetValue('ProfileImagePath')) } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
}

# Windows users whose own settings switched the automatic stage confirmation on. 1.0.0-rc10 took any value that
# was not false or empty; now only the machine policy can switch it on. Returns profile folder names.
function Find-VlcStageUsers([string[]]$ProfileDirs = @(Get-VlcProfileDirs)) {
    foreach ($p in $ProfileDirs) {
        $file = Join-Path $p 'AppData\Roaming\VLConnector\settings.json'
        try {
            $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
            if ($item.Length -gt 1MB) { continue }
            $json = [IO.File]::ReadAllText($file) | ConvertFrom-Json
            if ($json.vl.confirmStageMotion) { Split-Path $p -Leaf }
        }
        catch { }
    }
}

function New-VlcShortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$WorkDir, [string]$Icon, [string]$Description) {
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    $lnk.WorkingDirectory = $WorkDir
    $lnk.IconLocation = "$Icon,0"
    $lnk.Description = $Description
    if ($Arguments) { $lnk.WindowStyle = 7 }
    $lnk.Save()
}

# The Start menu entries for all users of the PC: VL Connector (settings), VL Connector agent, Uninstall.
function Set-VlcStartMenu([string]$InstallDir, [string]$MenuRoot = [Environment]::GetFolderPath('CommonPrograms')) {
    $menu = Join-Path $MenuRoot 'VL Connector'
    Remove-VlcTree $menu
    [void][IO.Directory]::CreateDirectory($menu)
    $app = Join-Path $InstallDir 'app'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $icon = Join-Path $app 'assets\VLC_icon.ico'
    $run = '-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File'
    New-VlcShortcut (Join-Path $menu 'VL Connector.lnk') $ps "$run `"$app\VLConnector.ps1`"" $app $icon 'VL Connector for PolyWorks - settings'
    New-VlcShortcut (Join-Path $menu 'VL Connector agent.lnk') $ps "$run `"$app\Agent.ps1`"" $app $icon 'VL Connector agent - exports the STL after AI Replay and opens the reports (network scenario, scanner PC)'
    # started outside the program folder: a process whose current folder it is would keep it from being deleted
    New-VlcShortcut (Join-Path $menu 'Uninstall VL Connector.lnk') (Join-Path $InstallDir 'Uninstall.cmd') '' $env:SystemRoot $icon 'Removes VL Connector for PolyWorks from this PC (administrator)'
    return $menu
}

# Startup shortcuts of the agent ("VL Connector agent.lnk") in the user profiles that start a script of the
# folder: only such shortcut files are deleted. Returns the deleted files.
function Remove-VlcStartupShortcuts([string]$AppDir, [string[]]$ProfileDirs = @(Get-VlcProfileDirs)) {
    $shell = New-Object -ComObject WScript.Shell
    $app = $AppDir.TrimEnd('\') + '\'
    foreach ($p in $ProfileDirs) {
        $lnk = Join-Path $p 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\VL Connector agent.lnk'
        try {
            $item = Get-Item -LiteralPath $lnk -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($shell.CreateShortcut($lnk).Arguments.IndexOf($app, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [IO.File]::Delete($lnk); $lnk }
        }
        catch { }
    }
}

function Register-VlcEventSource {
    if (-not [Diagnostics.EventLog]::SourceExists('VL Connector')) { [Diagnostics.EventLog]::CreateEventSource('VL Connector', 'Application') }
}

function Unregister-VlcEventSource {
    try { if ([Diagnostics.EventLog]::SourceExists('VL Connector')) { [Diagnostics.EventLog]::DeleteEventSource('VL Connector') } } catch { }
}

# ------------------------------------------------------------------------------------------------
# The place of a 1.0.0-rc10 installation (C:\ProgramData\VLConnector, users could change it)
# ------------------------------------------------------------------------------------------------

# The files that stay there and forward to the new installation: the Measure and Station macros and the button
# files (PolyWorks buttons made for the old folder call them), Agent.ps1 and VLConnector.ps1 (shortcuts of other
# Windows users) and a note. Relative path -> text.
function Get-VlcForwarders([string]$NewDir) {
    $app = Join-Path $NewDir 'app'
    $f = [ordered]@{}
    foreach ($kind in 'Measure', 'Station') {
        $macro = "version `"7.0`"`r`n# VL Connector has moved to $NewDir. This file only forwards a button made for the old folder.`r`nMACRO EXEC ( `"$app\polyworks\VLC_$kind.pwmacro`", `"$app`" )`r`n"
        $f["app\polyworks\VLC_$kind.pwmacro"] = $macro
        $f["VLC_${kind}_Button.pwmacro"] = $macro
    }
    foreach ($name in 'Agent.ps1', 'VLConnector.ps1') {
        $f["app\$name"] = "# VL Connector has moved to $NewDir. This file only forwards a shortcut made for the old folder.`r`n& '$((Join-Path $app $name) -replace "'", "''")' @args`r`n"
    }
    $f[$script:VlcForwarderNote] = "VL Connector for PolyWorks has moved to $NewDir.`r`nThe files here only forward PolyWorks buttons and shortcuts made for this folder. Uninstalling VL Connector removes them.`r`n"
    return $f
}

# Writes the forwarders into a new, empty folder with the administrator-only ACL. -SkipAcl: tests without
# administrator rights.
function New-VlcForwarderFolder([string]$Dir, [string]$NewDir, [switch]$SkipAcl) {
    [void][IO.Directory]::CreateDirectory($Dir)
    if (@([IO.Directory]::GetFileSystemEntries($Dir)).Count) { throw "$Dir was created again by somebody else while VL Connector was moved. Check it and install again." }
    if (-not $SkipAcl) { Set-VlcAdminOnlyAcl $Dir }
    $utf8 = New-Object Text.UTF8Encoding($true)
    $fw = Get-VlcForwarders $NewDir
    foreach ($rel in $fw.PSBase.Keys) {
        $path = Join-Path $Dir $rel
        [void][IO.Directory]::CreateDirectory((Split-Path $path))
        [IO.File]::WriteAllText($path, $fw[$rel], $utf8)
    }
    if (-not $SkipAcl) { Set-VlcAdminOnlyAcl $Dir -Owner }
}

# Moves an old installation out of the way (C17): the folder is renamed (nothing is followed), a new folder with
# the administrator-only ACL gets only the forwarders, and the renamed one is deleted (links removed, never
# followed). Returns MachineJson (the text of its machine.json, for the caller to check), Note and Left (a folder
# that could not be deleted completely); $null when there is no old installation.
function Move-VlcLegacyInstall([string]$OldDir, [string]$NewDir, [switch]$SkipAcl) {
    if (-not $OldDir -or -not (Test-Path -LiteralPath $OldDir)) { return $null }
    $old = [IO.Path]::GetFullPath($OldDir).TrimEnd('\')
    if ($old -ieq [IO.Path]::GetFullPath($NewDir).TrimEnd('\')) { return $null }
    if ([IO.File]::GetAttributes($old) -band [IO.FileAttributes]::ReparsePoint) {
        [IO.Directory]::Delete($old)
        return [pscustomobject]@{ MachineJson = ''; Note = "$old was a link to another folder: only the link was removed."; Left = '' }
    }
    $kind = Get-VlcFolderKind $old
    if (-not $kind -or $kind.Kind -eq 'Other') { return $null }
    $away = "$old.removing-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    Move-VlcFolder $old $away
    $json = ''
    $machine = Join-Path $away 'machine.json'
    if ($kind.Kind -eq 'VLConnector' -and (Test-Path -LiteralPath $machine -PathType Leaf)) {
        $item = Get-Item -LiteralPath $machine -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 256KB) { $json = [IO.File]::ReadAllText($machine) }
    }
    New-VlcForwarderFolder $old $NewDir -SkipAcl:$SkipAcl
    $left = ''
    try { Remove-VlcTree $away -TakeOwnership:(-not $SkipAcl) } catch { $left = $away }
    $note = if ($kind.Kind -eq 'Forwarders') { "The forwarders in $old point to $NewDir." }
        else { "VL Connector $($kind.Version) was removed from $old; PolyWorks buttons and shortcuts made for it are forwarded to $NewDir." }
    if ($left) { $note += " Not everything could be deleted: remove $left by hand." }
    return [pscustomobject]@{ MachineJson = $json; Note = $note; Left = $left }
}

# ------------------------------------------------------------------------------------------------
# Machine part of the installation and of the removal (administrator)
# ------------------------------------------------------------------------------------------------

# The settings of a file like machine.json ({ "policy": {...}, "defaults": {...} }), checked like every machine
# setting (needs lib\Settings.ps1): section -> hashtable 'section.key' -> value. Throws for anything not allowed.
function Read-VlcMachineSettingsFile([string]$Path) {
    $m = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    if ($m -isnot [System.Management.Automation.PSCustomObject]) { throw "$Path is not a JSON object." }
    $schema = Get-VlcSettingsSchema
    $sections = [ordered]@{}
    foreach ($p in $m.PSObject.Properties) {
        if ($p.Name -notin 'defaults', 'policy') { throw "${Path}: unknown section '$($p.Name)' (only defaults and policy)." }
        $flat = ConvertTo-VlcFlatSettings $p.Value $schema
        if (@($flat.Unknown).Count) { throw "${Path}: unknown settings $($flat.Unknown -join ', ')." }
        $set = @{}
        foreach ($key in @($flat.Values.PSBase.Keys)) {
            if ($p.Name -eq 'defaults' -and $schema[$key].machineOnly) { throw "${Path}: $key can only be set in the policy." }
            $r = Test-VlcSettingValue $schema[$key] $flat.Values[$key]
            if (-not $r.Ok) { throw "${Path}: $key $($r.Error)." }
            $set[$key] = $r.Value
        }
        $sections[$p.Name] = $set
    }
    return $sections
}

# Installs the package into $Target. $Say: called with a text and a color for every line of output.
# $ConfirmStageMotion On/Off and $MachineSettings (a file like machine.json: { "policy": {...}, "defaults": {...} })
# go into machine.json, checked like every machine setting. $InteropDll: an interface DLL that IT built (and
# signed) from these sources instead of one compiled here. -SkipAcl, $MenuRoot, $LegacyDir: tests without
# administrator rights (no permissions set or checked, no event source). Returns ExitCode, AgentSessions (where an
# agent was stopped) and Version.
function Install-VlcMachine {
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Target,
        [switch]$Force,
        [ValidateSet('', 'On', 'Off')] [string]$ConfirmStageMotion = '',
        [string]$MachineSettings = '',
        [string]$InteropDll = '',
        [string]$RequestedBy = '',
        [string]$LegacyDir = (Join-Path $env:ProgramData 'VLConnector'),
        [string]$MenuRoot = [Environment]::GetFolderPath('CommonPrograms'),
        [switch]$SkipAcl,
        [scriptblock]$Say = { param([string]$Text, [string]$Color) Write-Host $Text }
    )
    $result = [pscustomobject]@{ ExitCode = 1; AgentSessions = @(); Version = '' }
    $Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    & $Say '1/6  Checking the package...'
    $manifest = Read-VlcManifest $Source
    $check = Test-VlcPackageTree $Source $manifest
    if (-not $check.Ok) {
        & $Say 'The package is incomplete or was changed after it was built:' 'Red'
        foreach ($p in @($check.Problems | Select-Object -First 20)) { & $Say "  $p" 'Red' }
        & $Say 'Download the package again. Nothing was installed.' 'Red'
        return $result
    }
    $version = ([IO.File]::ReadAllText((Join-Path $Source 'VERSION'))).Trim()
    $result.Version = $version
    & $Say "     All files OK. Package fingerprint: $($manifest.Fingerprint)" 'Green'
    if ($check.Extra.Count) { & $Say "     Not part of the package, not installed: $($check.Extra -join ', ')" 'Yellow' }
    $installed = Test-VlcInstallTarget $Source $Target $version -Force:$Force
    # the machine settings of the administrator are checked before anything is changed
    $machineSet = [ordered]@{}
    if ($MachineSettings) {
        . (Join-Path $Source 'app\lib\Settings.ps1')
        $machineSet = Read-VlcMachineSettingsFile $MachineSettings
    }
    if (-not $SkipAcl) {
        $parents = @(Get-VlcAclProblems $Target -Parents)
        if ($parents.Count) { throw "Users can change a folder above ${Target}: $($parents[0]) Choose a folder below $env:ProgramFiles." }
    }
    $busy = @(Get-VlcProcesses @($Target, $LegacyDir) | Where-Object { $_.Kind -ne 'Agent' })
    if ($busy.Count) {
        & $Say "VL Connector is in use ($(@($busy | ForEach-Object { $_.Script } | Select-Object -Unique) -join ', ')). Close its windows, let running scans finish and install again." 'Yellow'
        $result.ExitCode = 1618
        return $result
    }

    & $Say "2/6  Copying to $Target.new ..."
    $stage = "$Target.new"
    Remove-VlcTree $stage
    try {
        [void][IO.Directory]::CreateDirectory($stage)
        if (-not $SkipAcl) { Set-VlcAdminOnlyAcl $stage }
        Copy-VlcPackage $Source $stage $manifest
        if ($installed -and (Test-Path -LiteralPath (Join-Path $Target 'machine.json') -PathType Leaf)) {
            [IO.File]::Copy((Join-Path $Target 'machine.json'), (Join-Path $stage 'machine.json'))
        }

        & $Say '3/6  Building the Windows and PolyWorks interfaces and the button files...'
        . (Join-Path $stage 'app\lib\Interop.ps1')
        $sourceHash = (Get-VlcInteropSource).Sha256
        $dll = Join-Path $stage 'bin\VLConnector.Interop.dll'
        [void][IO.Directory]::CreateDirectory((Split-Path $dll))
        if ($InteropDll) {
            [IO.File]::Copy($InteropDll, $dll)
            if ((Get-VlcInteropDllHash $dll) -ne $sourceHash) { throw "The interface DLL $InteropDll was not built from the sources of this package (expected source SHA-256 $sourceHash). Build it with tools\Build-Interop.ps1 of this package." }
            $signer = (Get-AuthenticodeSignature -LiteralPath $dll).SignerCertificate
            & $Say "     Interface DLL of IT taken over$(if ($signer) { ", signed by $($signer.Subject)" })." 'Green'
        }
        else {
            $built = Invoke-VlcTool 'WindowsPowerShell\v1.0\powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $stage 'tools\Build-Interop.ps1'), '-OutputPath', $dll)
            if ($built.ExitCode -ne 0) { throw "The interfaces could not be compiled: $($built.Output)" }
            if ((Get-VlcInteropDllHash $dll) -ne $sourceHash) { throw 'The compiled interface DLL does not carry the source hash of this package.' }
        }
        & $Say "     Interfaces: source SHA-256 $sourceHash" 'Green'
        foreach ($lib in 'Settings', 'PolyWorksSetup') { . (Join-Path $stage "app\lib\$lib.ps1") }
        foreach ($kind in 'Measure', 'Station') { [void](New-VlcButtonStub -Path (Join-Path $stage "VLC_${kind}_Button.pwmacro") -Kind $kind -AppDir (Join-Path $Target 'app')) }
        $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        [IO.File]::WriteAllText((Join-Path $stage 'install-info.txt'), ("VERSION={0}`r`nINSTALLED={1:yyyy-MM-dd HH:mm:ss}`r`nBY={2}`r`nREQUESTED_BY={3}`r`nCOMPUTER={4}`r`nFINGERPRINT={5}`r`nINTERFACES={6}`r`n" -f
            $version, (Get-Date), $who, $RequestedBy, $env:COMPUTERNAME, $manifest.Fingerprint, $sourceHash))

        & $Say '4/6  Checking the copy and its permissions...'
        $staged = Test-VlcPackageTree $stage $manifest $script:VlcGeneratedFiles -Strict
        if (-not $staged.Ok) { throw "The copied files differ from the package: $($staged.Problems -join '; ')" }
        if (-not $SkipAcl) {
            Set-VlcAdminOnlyAcl $stage -Owner
            $acl = @(Get-VlcAclProblems $stage -Recurse)
            if ($acl.Count) { throw "Users other than the administrators could change the copy: $(@($acl | Select-Object -First 5) -join '; ')" }
        }
        & $Say '     Files and permissions OK: only administrators can change them.' 'Green'

        & $Say "5/6  Putting $version in place..."
        $busy = @(Get-VlcProcesses @($Target, $LegacyDir) | Where-Object { $_.Kind -ne 'Agent' })
        if ($busy.Count) {
            & $Say "VL Connector was started meanwhile ($(@($busy | ForEach-Object { $_.Script } | Select-Object -Unique) -join ', ')). Close it and install again." 'Yellow'
            Remove-VlcTree $stage
            $result.ExitCode = 1618
            return $result
        }
        $result.AgentSessions = @(Stop-VlcAgents @($Target, $LegacyDir))
        if ($result.AgentSessions.Count) { & $Say '     Running agents were stopped for the update.' }
        Invoke-VlcFolderSwap $stage $Target
    }
    catch {
        try { Remove-VlcTree $stage } catch { }
        throw
    }
    & $Say "     $Target" 'Green'
    if ($installed) { & $Say "     The previous version ($installed) is kept in $Target.old." }

    & $Say '6/6  Machine settings, Start menu, older installation...'
    if (-not $SkipAcl) { Register-VlcEventSource }
    foreach ($lib in 'Settings', 'PolyWorksSetup') { . (Join-Path $Target "app\lib\$lib.ps1") }
    $schema = Get-VlcSettingsSchema
    $legacy = $null
    try { $legacy = Move-VlcLegacyInstall $LegacyDir $Target -SkipAcl:$SkipAcl }
    catch { & $Say "     The older installation in $LegacyDir could not be moved: $($_.Exception.Message) Close programs that use it and run Install.cmd again." 'Yellow' }
    if ($legacy) {
        & $Say "     $($legacy.Note)" $(if ($legacy.Left) { 'Yellow' } else { 'Gray' })
        if ($legacy.MachineJson -and -not $installed) {
            # users could change that file: only shared defaults are taken over, nothing an administrator decides
            try {
                $flat = ConvertTo-VlcFlatSettings ($legacy.MachineJson | ConvertFrom-Json) $schema
                $take = @{}
                $skip = New-Object Collections.Generic.List[string]
                foreach ($key in @($flat.Values.PSBase.Keys)) {
                    if ($schema[$key].machineOnly -or -not (Test-VlcSettingValue $schema[$key] $flat.Values[$key]).Ok) { $skip.Add($key) } else { $take[$key] = $flat.Values[$key] }
                }
                if ($take.Count) { [void](Set-VlcMachineSettings 'defaults' -Set $take -RequestedBy 'installation (machine.json of the older version)') }
                if ($take.Count) { & $Say "     Machine defaults taken over from the older version: $(@($take.Keys | Sort-Object) -join ', ')." }
                if ($skip.Count) { & $Say "     Not taken over (only the administrator decides these now): $($skip -join ', '). Set them with Install.cmd -MachineSettings or the Change (administrator) button." 'Yellow' }
            }
            catch { & $Say "     machine.json of the older version was not taken over: $($_.Exception.Message)" 'Yellow' }
        }
    }
    # the administrator's own settings come last: they win over anything taken over
    foreach ($section in $machineSet.PSBase.Keys) {
        foreach ($change in @(Set-VlcMachineSettings $section -Set $machineSet[$section] -RequestedBy $RequestedBy)) { & $Say "     $section`: $change" }
    }
    if ($ConfirmStageMotion) {
        foreach ($change in @(Set-VlcMachineSettings 'policy' -Set @{ 'vl.confirmStageMotion' = ($ConfirmStageMotion -eq 'On') } -RequestedBy $RequestedBy)) { & $Say "     policy: $change" }
    }
    $stageOn = (Get-VlcSettingsState).Settings.vl.confirmStageMotion
    & $Say "     Automatic stage confirmation: $(if ($stageOn) { 'ON for all users (warning window and sound)' } else { 'off (the operator confirms)' })." $(if ($stageOn) { 'Yellow' } else { 'Gray' })
    $users = @(Find-VlcStageUsers)
    if ($users.Count) { & $Say "     Users who had switched the stage confirmation on for themselves (now ignored): $($users -join ', ')." 'Yellow' }
    try { & $Say "     Start menu for all users: $(Set-VlcStartMenu $Target $MenuRoot)" }
    catch { & $Say "     The Start menu entries could not be created: $($_.Exception.Message)" 'Yellow' }
    $result.ExitCode = 0
    return $result
}

# Removes the installation in $InstallDir (with <folder>.old and .new), its Start menu entries, the forwarders at
# the place of 1.0.0-rc10 and the event source. Returns the exit code.
function Uninstall-VlcMachine {
    param(
        [Parameter(Mandatory = $true)] [string]$InstallDir,
        [string]$LegacyDir = (Join-Path $env:ProgramData 'VLConnector'),
        [string]$MenuRoot = [Environment]::GetFolderPath('CommonPrograms'),
        [string[]]$ProfileDirs = @(Get-VlcProfileDirs),
        [switch]$SkipAcl,
        [scriptblock]$Say = { param([string]$Text, [string]$Color) Write-Host $Text }
    )
    $dir = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
    $kind = Get-VlcFolderKind $dir
    if (-not $kind -or $kind.Kind -ne 'VLConnector') { & $Say "$dir holds no VL Connector installation. Nothing was removed." 'Red'; return 1 }
    $busy = @(Get-VlcProcesses @($dir) | Where-Object { $_.Kind -ne 'Agent' })
    if ($busy.Count) {
        & $Say "VL Connector is in use ($(@($busy | ForEach-Object { $_.Script } | Select-Object -Unique) -join ', ')). Close its windows, let running scans finish and try again." 'Yellow'
        return 1618
    }
    if (@(Stop-VlcAgents @($dir, $LegacyDir)).Count) { & $Say 'Running agents were stopped.' }
    foreach ($f in @(Remove-VlcStartupShortcuts (Join-Path $dir 'app') $ProfileDirs)) { & $Say "Removed $f" }
    $menu = Join-Path $MenuRoot 'VL Connector'
    if (Test-Path -LiteralPath $menu) { Remove-VlcTree $menu; & $Say "Removed $menu" }
    $legacy = Get-VlcFolderKind $LegacyDir
    if ($legacy -and $legacy.Kind -eq 'Forwarders') {
        # PolyWorks buttons of the older version may still look there: the folder stays, empty and only for
        # administrators, so nobody can place a macro in their way (C17)
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($LegacyDir)) { if ((Split-Path $entry -Leaf) -ne $script:VlcForwarderNote) { Remove-VlcTree $entry } }
        [IO.File]::WriteAllText((Join-Path $LegacyDir $script:VlcForwarderNote), "VL Connector for PolyWorks was removed from this PC.`r`nThis empty folder stays so that nobody can place files where PolyWorks buttons of an older VL Connector look. Delete it once those buttons are removed from PolyWorks.`r`n", (New-Object Text.UTF8Encoding($true)))
        & $Say "Removed the forwarders of the older version; the empty folder $LegacyDir stays (only administrators can change it)."
    }
    $failed = New-Object Collections.Generic.List[string]
    foreach ($d in "$dir.new", "$dir.old", $dir) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        try { Remove-VlcTree $d; & $Say "Removed $d" } catch { $failed.Add($_.Exception.Message) }
    }
    if (-not $SkipAcl) { Unregister-VlcEventSource }
    if ($failed.Count -or (Test-Path -LiteralPath $dir)) {
        foreach ($f in $failed) { & $Say $f 'Red' }
        & $Say 'VL Connector is not removed completely. Close programs that use its folder and run Uninstall again.' 'Red'
        return 1
    }
    return 0
}
