# DeathRelay: posts your FriendProgress deaths to a Discord webhook.
#
# The addon (with /fp discord on) queues each of your deaths as a "FPDEATH;..."
# line in its saved variables (WTF\Account\<account>\SavedVariables\FriendProgress.lua).
# WoW writes that file on /reload, logout and exit, and the addon reloads your UI
# when you release spirit, so a death posts a few seconds after you release.
#
# Install.cmd copies this script to %LOCALAPPDATA%\FriendProgress, writes the
# config next to it and starts it hidden with Windows. Output goes to relay.log there.
# To run it by hand instead:
#   powershell -ExecutionPolicy Bypass -File DeathRelay.ps1
param(
    [string]$Config = (Join-Path $PSScriptRoot "DeathRelay.config.json")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# One relay at a time, or each death would post twice.
$mutex = New-Object System.Threading.Mutex($false, "Local\FriendProgressDeathRelay")
if (-not $mutex.WaitOne(0)) {
    Write-Host "The death relay is already running."
    exit
}
try { Start-Transcript -Path (Join-Path $PSScriptRoot "relay.log") -Force | Out-Null } catch { }

if (-not (Test-Path $Config)) {
    Write-Error "No config at $Config. Run Install.cmd from the addon's discord folder."
}
$cfg = Get-Content $Config -Raw | ConvertFrom-Json
if (-not $cfg.webhookUrl -or $cfg.webhookUrl -notmatch '^https://(\w+\.)?discord(app)?\.com/api/webhooks/') {
    Write-Error "webhookUrl in $Config doesn't look like a Discord webhook URL."
}

$ClassColors = @{
    WARRIOR = 0xC69B6D; PALADIN = 0xF48CBA; HUNTER = 0xAAD372; ROGUE = 0xFFF468; PRIEST = 0xFFFFFF
    SHAMAN = 0x0070DD; MAGE = 0x3FC7EB; WARLOCK = 0x8788EE; DRUID = 0xFF7C0A
}
$Environment = @{
    Falling = "fell to their death"; Drowning = "drowned"; Fatigue = "died of fatigue"
    Fire = "burned to death"; Lava = "died in lava"; Slime = "died in slime"
}

# Same wording as ns.DeathText in Deaths.lua.
function Format-Death($d) {
    $class = if ($d.Class) { (Get-Culture).TextInfo.ToTitleCase($d.Class.ToLower()) } else { "" }
    $who = "**$($d.Short)** (level $($d.Level) $class)" -replace ' \)', ')'
    $zone = ""
    if ($d.Zone) {
        $zone = if ($d.Subzone -and $d.Subzone -ne $d.Zone) { " in $($d.Subzone), $($d.Zone)" } else { " in $($d.Zone)" }
    }
    $killer = "**$($d.Killer)**"
    if ($d.KillerLevel -and [int]$d.KillerLevel -lt 0) { $killer += " (level ??)" }
    elseif ($d.KillerLevel) { $killer += " (level $($d.KillerLevel))" }
    $dmg = if ($d.Damage -and [int]$d.Damage -gt 0) { $d.Damage } else { $null }
    if ($d.Killer -and $d.Ability -and $d.Ability -ne "Melee") {
        $for = if ($dmg) { " for $dmg damage" } else { "" }
        return "$who was killed by $killer with $($d.Ability)$for$zone."
    }
    $last = if ($dmg) { " (last hit $dmg damage)" } else { "" }
    if ($d.Killer -and $d.Ability -eq "Melee") {
        $hit = if ($dmg) { " with a melee hit for $dmg damage" } else { "" }
        return "$who was killed by $killer$hit$zone."
    }
    if ($d.Killer) { return "$who was killed by $killer$last$zone." }
    if ($Environment.ContainsKey($d.Ability)) {
        $amount = if ($dmg) { " ($dmg damage)" } else { "" }
        return "$who $($Environment[$d.Ability])$amount$zone."
    }
    if ($d.Ability) {
        $for = if ($dmg) { " for $dmg damage" } else { "" }
        return "$who was killed by $($d.Ability)$for$zone."
    }
    return "$who died$last$zone."
}

function Send-Death($d) {
    $title = if ($d.Kind -eq "test") { "[Test] $($d.Short) has died" } else { "$($d.Short) has died" }
    $embed = @{
        title       = $title
        description = Format-Death $d
        color       = if ($ClassColors.ContainsKey($d.Class)) { $ClassColors[$d.Class] } else { 0x808080 }
        timestamp   = [DateTimeOffset]::FromUnixTimeSeconds($d.Time).UtcDateTime.ToString("o")
        footer      = @{ text = $d.Name }
    }
    $body = @{ username = "FriendProgress"; embeds = @($embed) } | ConvertTo-Json -Depth 5
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-RestMethod -Uri $cfg.webhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $bytes | Out-Null
            Write-Host "Posted: $($d.Short) ($($d.Kind))"
            return $true
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 429) { Start-Sleep -Seconds 2; continue }   # Discord rate limit
            Write-Warning "Discord post failed ($status): $($_.Exception.Message)"
            return $false
        }
    }
    return $false
}

# Older installs stored the chat log path: <wow>\Logs\WoWChatLog.txt.
$wow = if ($cfg.wowFolder) { $cfg.wowFolder } else { Split-Path (Split-Path $cfg.chatLog) }
$pattern = Join-Path $wow "WTF\Account\*\SavedVariables\FriendProgress.lua"
$MaxAge = 24 * 3600   # don't post deaths older than this (e.g. the backlog on first install)

# What we've posted, kept across restarts so a reload doesn't repost old deaths.
$postedPath = Join-Path $PSScriptRoot "posted.txt"
$posted = New-Object 'System.Collections.Generic.HashSet[string]'
if (Test-Path $postedPath) { Get-Content $postedPath | ForEach-Object { [void]$posted.Add($_) } }

function Read-Deaths($file) {
    # Saved as quoted strings in FriendProgressDB.relayQueue; the addon strips quotes from the fields.
    $text = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, '"FPDEATH;(\d+);(\w+);([^"]*)"')) {
        # Version 1: name;level;class;zone;killer;ability;time. Version 2 adds damage;killerLevel;subzone.
        if ($m.Groups[1].Value -notin "1", "2") { continue }
        $f = $m.Groups[3].Value.Split(';')
        if ($f.Count -lt 7) { continue }
        [pscustomobject]@{
            Kind = $m.Groups[2].Value; Name = $f[0]; Short = ($f[0] -split '-')[0]; Level = $f[1]; Class = $f[2]
            Zone = $f[3]; Killer = $f[4]; Ability = $f[5]; Time = [long]$f[6]
            Damage = if ($f.Count -gt 7) { $f[7] } else { "" }
            KillerLevel = if ($f.Count -gt 8) { $f[8] } else { "" }
            Subzone = if ($f.Count -gt 9) { $f[9] } else { "" }
        }
    }
}

Write-Host "Watching $pattern. Ctrl+C to stop."
$lastWrite = @{}   # file -> LastWriteTime we've processed
$retryAt = @{}     # file -> when to retry after a failed post
while ($true) {
    foreach ($file in Get-ChildItem $pattern -ErrorAction SilentlyContinue) {
        $changed = $lastWrite[$file.FullName] -ne $file.LastWriteTimeUtc
        $retry = $retryAt[$file.FullName] -and (Get-Date) -ge $retryAt[$file.FullName]
        if (-not $changed -and -not $retry) { continue }
        try { $deaths = @(Read-Deaths $file.FullName) } catch { continue }   # mid-write; next pass
        $failed = $false
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        foreach ($d in $deaths) {
            $key = "$($d.Name);$($d.Time);$($d.Kind)"
            if ($posted.Contains($key)) { continue }
            if ($now - $d.Time -gt $MaxAge) { [void]$posted.Add($key); continue }
            if (Send-Death $d) {
                [void]$posted.Add($key)
                Add-Content $postedPath $key
            } else {
                $failed = $true
            }
        }
        # On failure, try that file again in a minute.
        $lastWrite[$file.FullName] = $file.LastWriteTimeUtc
        $retryAt[$file.FullName] = if ($failed) { (Get-Date).AddMinutes(1) } else { $null }
    }
    Start-Sleep -Seconds 3
}
