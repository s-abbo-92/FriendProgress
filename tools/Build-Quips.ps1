# Generates DeathQuips.lua (the in-game copy of the death jokes) from
# discord\DeathQuips.json, so the addon and the Discord relay share one list.
# Run after editing the JSON:
#   powershell -ExecutionPolicy Bypass -File tools\Build-Quips.ps1
#
# Killer patterns are .NET regexes in the relay but Lua patterns in game, so only
# a small subset is allowed: words separated by |, optionally wrapped in ^(...)$,
# with \b at a word's start or end and " ?" for an optional space.
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot
$json = Join-Path $root "discord\DeathQuips.json"
$out = Join-Path $root "DeathQuips.lua"

$quips = Get-Content $json -Raw -Encoding UTF8 | ConvertFrom-Json

# A Lua string literal. "|" starts an escape sequence in WoW text, so double it.
function LuaString([string]$s) {
    '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace('|', '||') + '"'
}

# One _killers regex -> a list of Lua patterns (matched against the lowercased name).
function LuaPatterns([string]$regex) {
    $anchored = $false
    $body = $regex
    if ($body -match '^\^\((.*)\)\$$') { $anchored = $true; $body = $Matches[1] }
    elseif ($body -match '^\^(.*)\$$') { $anchored = $true; $body = $Matches[1] }
    foreach ($alt in $body.Split('|')) {
        $start = $alt.StartsWith('\b'); if ($start) { $alt = $alt.Substring(2) }
        $end = $alt.EndsWith('\b'); if ($end) { $alt = $alt.Substring(0, $alt.Length - 2) }
        # Letters, digits, spaces, apostrophes and hyphens, plus "?" only after a space.
        if ($alt -notmatch "^[\w' -]+( \?[\w' -]+)*$") { throw "Killer pattern '$regex' uses syntax the in-game copy can't handle: '$alt'" }
        $p = $alt.ToLower().Replace('-', '%-')
        if ($start) { $p = '%f[%w]' + $p }
        if ($end) { $p = $p + '%f[%W]' }
        if ($anchored) { $p = '^' + $p + '$' }
        $p
    }
}

$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("-- Generated from discord\DeathQuips.json by tools\Build-Quips.ps1. Edit the JSON and rerun that")
[void]$sb.AppendLine("-- script; changes made here are overwritten.")
[void]$sb.AppendLine("local _, ns = ...")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("ns.DeathQuips = {")
[void]$sb.AppendLine("    -- { category, { lowercase Lua patterns } }, first match wins")
[void]$sb.AppendLine("    killers = {")
foreach ($p in $quips._killers.PSObject.Properties) {
    $pats = (LuaPatterns $p.Name | ForEach-Object { LuaString $_ }) -join ", "
    [void]$sb.AppendLine("        { $(LuaString $p.Value), { $pats } },")
}
[void]$sb.AppendLine("    },")
[void]$sb.AppendLine("    lines = {")
foreach ($p in $quips.PSObject.Properties) {
    if ($p.Name.StartsWith("_")) { continue }
    [void]$sb.AppendLine("        $($p.Name) = {")
    foreach ($line in $p.Value) { [void]$sb.AppendLine("            $(LuaString $line),") }
    [void]$sb.AppendLine("        },")
}
[void]$sb.AppendLine("    },")
[void]$sb.AppendLine("}")

[IO.File]::WriteAllText($out, $sb.ToString().Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
$count = ($quips.PSObject.Properties | Where-Object { -not $_.Name.StartsWith("_") } | ForEach-Object { $_.Value.Count } | Measure-Object -Sum).Sum
Write-Host "Wrote $out ($count lines)."
