# DeathRelay: posts FriendProgress deaths to a Discord webhook.
#
# The addon (with /fp discord on) whispers each of your deaths to yourself as a
# "FPDEATH;..." line. WoW writes chat to Logs\WoWChatLog.txt while chat logging
# is on, and this script follows that file and posts every new death.
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
    Write-Error "No config at $Config. Copy DeathRelay.config.example.json to DeathRelay.config.json and fill it in."
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
            return
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -eq 429) { Start-Sleep -Seconds 2; continue }   # Discord rate limit
            Write-Warning "Discord post failed ($status): $($_.Exception.Message)"
            return
        }
    }
}

$log = $cfg.chatLog
while (-not (Test-Path $log)) {
    Write-Host "Waiting for $log (turn on /fp discord in game)..."
    Start-Sleep -Seconds 10
}
Write-Host "Watching $log. Ctrl+C to stop."

# Each death shows up twice (the "To" and "whispers" lines), so remember what we posted.
$seen = New-Object 'System.Collections.Generic.HashSet[string]'

Get-Content $log -Wait -Tail 0 -Encoding UTF8 | ForEach-Object {
    $line = $_
    if ($line -notmatch 'FPDEATH;(\d+);(\w+);(.*)$') { return }
    # Version 1: name;level;class;zone;killer;ability;time. Version 2 adds damage;killerLevel;subzone.
    if ($Matches[1] -notin "1", "2") { Write-Warning "Unknown relay version $($Matches[1]); update this script."; return }
    $kind = $Matches[2]
    $f = $Matches[3].Split(';')
    if ($f.Count -lt 7) { return }
    $d = [pscustomobject]@{
        Kind = $kind; Name = $f[0]; Short = ($f[0] -split '-')[0]; Level = $f[1]; Class = $f[2]
        Zone = $f[3]; Killer = $f[4]; Ability = $f[5]; Time = [long]$f[6]
        Damage = if ($f.Count -gt 7) { $f[7] } else { "" }
        KillerLevel = if ($f.Count -gt 8) { $f[8] } else { "" }
        Subzone = if ($f.Count -gt 9) { $f[9] } else { "" }
    }
    # The addon only whispers our own deaths to ourselves. Ignore anyone else
    # whispering us a fake one: their name won't match the dead character's.
    if ($line -match '\[?([^\s\[\]:]+)\]? whispers:' -and ($Matches[1] -split '-')[0] -ne $d.Short) { return }
    if (-not $seen.Add("$($d.Name);$($d.Time);$kind")) { return }
    Send-Death $d
}
