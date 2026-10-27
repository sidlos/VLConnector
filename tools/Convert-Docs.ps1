<#
  Development tool: converts docs\*.md to self-contained HTML pages (docs\*.html) that the settings window
  opens. Handles the Markdown used in these documents: headings, paragraphs, lists (also task lists),
  tables, code blocks, quotes, images, links (.md links point to the .html pages), inline code, bold, italic.
#>
param([string]$DocsDir = (Join-Path (Split-Path $PSScriptRoot) 'docs'))

$ErrorActionPreference = 'Stop'

function ConvertTo-HtmlText([string]$Text) { return [Net.WebUtility]::HtmlEncode($Text) }

function ConvertTo-Anchor([string]$Title) {
    return (($Title.ToLower() -replace '[^\p{L}\p{Nd} -]', '') -replace ' ', '-')
}

function Convert-Inline([string]$Text) {
    $codes = New-Object Collections.Generic.List[string]
    $t = [regex]::Replace($Text, '`([^`]+)`', { param($m) $codes.Add($m.Groups[1].Value); "\u0000$($codes.Count - 1)\u0000" })
    $t = ConvertTo-HtmlText $t
    $t = [regex]::Replace($t, '!\[([^\]]*)\]\(([^)]+)\)', '<img src="$2" alt="$1">')
    $t = [regex]::Replace($t, '\[([^\]]+)\]\(([^)]+)\)', {
        param($m)
        $href = $m.Groups[2].Value -replace '\.md($|#)', '.html$1'
        '<a href="{0}">{1}</a>' -f $href, $m.Groups[1].Value
    })
    $t = [regex]::Replace($t, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    $t = [regex]::Replace($t, '(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])', '<em>$1</em>')
    $t = [regex]::Replace($t, '\\u0000(\d+)\\u0000', { param($m) '<code>' + (ConvertTo-HtmlText $codes[[int]$m.Groups[1].Value]) + '</code>' })
    return $t
}

function Convert-Markdown([string[]]$Lines) {
    $out = New-Object Text.StringBuilder
    $i = 0
    $para = New-Object Collections.Generic.List[string]
    $flush = { if ($para.Count) { [void]$out.AppendLine('<p>' + (Convert-Inline ($para -join ' ')) + '</p>'); $para.Clear() } }
    while ($i -lt $Lines.Count) {
        $line = $Lines[$i]
        if ($line -match '^```') {
            & $flush
            $code = New-Object Collections.Generic.List[string]
            $i++
            while ($i -lt $Lines.Count -and $Lines[$i] -notmatch '^```') { $code.Add($Lines[$i]); $i++ }
            [void]$out.AppendLine('<pre><code>' + (ConvertTo-HtmlText ($code -join "`n")) + '</code></pre>')
            $i++; continue
        }
        if ($line -match '^(#{1,4}) (.+)$') {
            & $flush
            $n = $Matches[1].Length; $title = $Matches[2]
            [void]$out.AppendLine(('<h{0} id="{1}">{2}</h{0}>' -f $n, (ConvertTo-Anchor $title), (Convert-Inline $title)))
            $i++; continue
        }
        if ($line -match '^\|') {
            & $flush
            $rows = New-Object Collections.Generic.List[string]
            while ($i -lt $Lines.Count -and $Lines[$i] -match '^\|') { $rows.Add($Lines[$i]); $i++ }
            [void]$out.AppendLine('<table>')
            for ($r = 0; $r -lt $rows.Count; $r++) {
                if ($r -eq 1 -and $rows[$r] -match '^\|[\s:|-]+\|$') { continue }
                $cells = ($rows[$r].Trim().Trim('|')) -split '(?<!\\)\|'
                $tag = if ($r -eq 0) { 'th' } else { 'td' }
                [void]$out.AppendLine('<tr>' + (($cells | ForEach-Object { "<$tag>" + (Convert-Inline $_.Trim()) + "</$tag>" }) -join '') + '</tr>')
            }
            [void]$out.AppendLine('</table>')
            continue
        }
        if ($line -match '^\s*([-*]|\d+\.) ') {
            & $flush
            $ordered = $line -match '^\s*\d+\.'
            $tag = if ($ordered) { 'ol' } else { 'ul' }
            [void]$out.AppendLine("<$tag>")
            while ($i -lt $Lines.Count -and $Lines[$i] -match '^\s*([-*]|\d+\.) (.*)$') {
                $item = $Matches[2]
                $i++
                while ($i -lt $Lines.Count -and $Lines[$i] -match '^\s{2,}\S' -and $Lines[$i] -notmatch '^\s*([-*]|\d+\.) ') { $item += ' ' + $Lines[$i].Trim(); $i++ }
                if ($item -match '^\[( |x)\] (.*)$') {
                    $box = if ($Matches[1] -eq 'x') { '&#9745;' } else { '&#9744;' }
                    [void]$out.AppendLine("<li class=`"task`">$box " + (Convert-Inline $Matches[2]) + '</li>')
                }
                else { [void]$out.AppendLine('<li>' + (Convert-Inline $item) + '</li>') }
            }
            [void]$out.AppendLine("</$tag>")
            continue
        }
        if ($line -match '^> ?(.*)$') {
            & $flush
            $quote = New-Object Collections.Generic.List[string]
            while ($i -lt $Lines.Count -and $Lines[$i] -match '^> ?(.*)$') { $quote.Add($Matches[1]); $i++ }
            [void]$out.AppendLine('<blockquote>' + (Convert-Inline ($quote -join ' ')) + '</blockquote>')
            continue
        }
        if (-not $line.Trim()) { & $flush; $i++; continue }
        $para.Add($line.Trim())
        $i++
    }
    & $flush
    return $out.ToString()
}

$css = @'
body { font-family: "Segoe UI Variable Text", "Segoe UI", sans-serif; font-size: 15px; line-height: 1.55; color: #1b1b1b;
       background: #f3f3f3; margin: 0; }
main { max-width: 920px; margin: 28px auto; background: #fff; border: 1px solid #e5e5e5; border-radius: 8px; padding: 32px 44px 44px; }
h1 { font-size: 28px; font-weight: 600; margin: 0 0 8px; }
h2 { font-size: 21px; font-weight: 600; margin: 34px 0 10px; padding-top: 6px; border-top: 1px solid #ececec; }
h3 { font-size: 17px; font-weight: 600; margin: 24px 0 8px; }
a { color: #0f6cbd; text-decoration: none; } a:hover { text-decoration: underline; }
code { font-family: Consolas, "Cascadia Mono", monospace; font-size: 13px; background: #f3f3f3; padding: 1px 5px; border-radius: 4px; }
pre { background: #f6f6f6; border: 1px solid #e5e5e5; border-radius: 6px; padding: 12px 14px; overflow-x: auto; }
pre code { background: none; padding: 0; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 14px; }
th, td { border: 1px solid #e3e3e3; padding: 7px 10px; text-align: left; vertical-align: top; }
th { background: #f7f7f7; font-weight: 600; }
blockquote { margin: 14px 0; padding: 10px 16px; background: #fff4ce; border-left: 4px solid #9d5d00; border-radius: 4px; }
img { max-width: 100%; border: 1px solid #e5e5e5; border-radius: 6px; margin: 8px 0; }
li.task { list-style: none; margin-left: -18px; }
footer { max-width: 920px; margin: 0 auto 28px; color: #666; font-size: 12px; text-align: center; }
'@

foreach ($md in Get-ChildItem -LiteralPath $DocsDir -Filter '*.md') {
    $lines = [IO.File]::ReadAllLines($md.FullName, [Text.Encoding]::UTF8)
    $title = (@($lines | Where-Object { $_ -match '^# ' })[0] -replace '^# ', '')
    $body = Convert-Markdown $lines
    $html = "<!DOCTYPE html>`r`n<html lang=`"en`">`r`n<head>`r`n<meta charset=`"utf-8`">`r`n<title>$(ConvertTo-HtmlText $title)</title>`r`n<style>`r`n$css`r`n</style>`r`n</head>`r`n<body>`r`n<main>`r`n$body</main>`r`n<footer>VL Connector for PolyWorks - unofficial tool, not an official KEYENCE or InnovMetric product.</footer>`r`n</body>`r`n</html>`r`n"
    $target = [IO.Path]::ChangeExtension($md.FullName, '.html')
    [IO.File]::WriteAllText($target, ($html -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding($false)))
    "Created $target"
}
