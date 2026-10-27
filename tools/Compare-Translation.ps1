<#
  Development tool: proves that a translation changed only comments, string texts and an agreed list
  of renamed identifiers. Both scripts are split into PowerShell tokens; comments and line breaks
  are ignored; every other token must be identical, except:
    - variables and parameters on the rename list,
    - strings: the text may differ, but the variables used inside ($name, after renaming) and the
      format placeholders ({0}, {1:...}) must be the same,
    - the C# source of Add-Type here-strings: identical once // comments and blank space are removed.
  Exit code 1 when anything else differs. All changed strings are listed for review.
#>
param(
    [Parameter(Mandatory = $true)][string]$Old,
    [Parameter(Mandatory = $true)][string]$New,
    [hashtable]$Rename = @{},
    [switch]$ShowStrings
)

$ErrorActionPreference = 'Stop'

function Get-Tokens([string]$Path) {
    $errors = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize((Get-Content -LiteralPath $Path -Raw), [ref]$errors)
    if ($errors) { throw "Parse errors in ${Path}: $($errors[0].Message)" }
    return @($tokens | Where-Object { $_.Type -notin 'Comment', 'NewLine' })
}

function Get-Variables([string]$Text, [hashtable]$Map) {
    return @([regex]::Matches($Text, '\$\{?(?:script:|global:|env:)?([A-Za-z_][A-Za-z0-9_]*)') | ForEach-Object {
        $n = $_.Groups[1].Value
        if ($Map.ContainsKey($n)) { $Map[$n] } else { $n }
    } | Sort-Object)
}

function Get-Placeholders([string]$Text) {
    return @([regex]::Matches($Text, '\{\d+(?::[^}]*)?\}') | ForEach-Object { $_.Value } | Sort-Object)
}

function Get-CSharpCode([string]$Text) {
    $noComments = [regex]::Replace($Text, '//[^\r\n]*', '')
    return [regex]::Replace($noComments, '\s+', ' ').Trim()
}

$a = Get-Tokens $Old
$b = Get-Tokens $New
$problems = New-Object Collections.Generic.List[string]
$changedStrings = New-Object Collections.Generic.List[string]

if ($a.Count -ne $b.Count) { $problems.Add("token count differs: $($a.Count) vs $($b.Count)") }
$n = [math]::Min($a.Count, $b.Count)
for ($i = 0; $i -lt $n; $i++) {
    $x = $a[$i]; $y = $b[$i]
    $where = "old line $($x.StartLine) / new line $($y.StartLine)"
    if ($x.Type -ne $y.Type) { $problems.Add("$($where): token type $($x.Type) '$($x.Content)' vs $($y.Type) '$($y.Content)'"); break }
    switch ($x.Type) {
        'String' {
            if ($x.Content -eq $y.Content) { continue }
            if ($x.Content -match 'using System;') {
                if ((Get-CSharpCode $x.Content) -ne (Get-CSharpCode $y.Content)) { $problems.Add("$($where): C# code differs (not only comments)") }
                continue
            }
            $va = (Get-Variables $x.Content $Rename) -join ','
            $vb = (Get-Variables $y.Content @{}) -join ','
            if ($va -ne $vb) { $problems.Add("$($where): variables in string differ: [$va] vs [$vb]") }
            $pa = (Get-Placeholders $x.Content) -join ','
            $pb = (Get-Placeholders $y.Content) -join ','
            if ($pa -ne $pb) { $problems.Add("$($where): placeholders differ: [$pa] vs [$pb]") }
            $changedStrings.Add("${where}:`n    - $($x.Content)`n    + $($y.Content)")
        }
        { $_ -in 'Variable', 'CommandParameter', 'CommandArgument', 'Member', 'Command', 'Keyword', 'Operator', 'Number', 'Type', 'Attribute', 'GroupStart', 'GroupEnd', 'StatementSeparator', 'LineContinuation', 'Position' } {
            $expected = $x.Content
            $key = $x.Content.TrimStart('-')
            if ($x.Type -in 'Variable', 'CommandParameter' -and $Rename.ContainsKey($key)) {
                $expected = if ($x.Type -eq 'CommandParameter') { '-' + $Rename[$key] } else { $Rename[$key] }
            }
            if ($y.Content -ne $expected) { $problems.Add("$($where): $($x.Type) '$($x.Content)' -> '$($y.Content)' (expected '$expected')") }
        }
        default {
            if ($x.Content -ne $y.Content) { $problems.Add("$($where): $($x.Type) '$($x.Content)' -> '$($y.Content)'") }
        }
    }
}

if ($ShowStrings) { $changedStrings | ForEach-Object { Write-Host $_ } }
Write-Host "$($a.Count) tokens compared, $($changedStrings.Count) strings translated."
if ($problems.Count) {
    $problems | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}
Write-Host 'Only comments, strings and the agreed renames differ.' -ForegroundColor Green
