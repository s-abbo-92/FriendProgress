# Installs the FriendProgress death relay for the current Windows user:
#   - asks for the Discord webhook URL and checks it with Discord
#   - finds the WoW folder this addon is installed in
#   - copies the relay to %LOCALAPPDATA%\FriendProgress and starts it hidden,
#     now and every time Windows starts
# Run again to change the webhook or update the relay. Uninstall.cmd removes it.
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $env:LOCALAPPDATA "FriendProgress"
$configPath = Join-Path $dest "DeathRelay.config.json"
$relayPath = Join-Path $dest "DeathRelay.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "FriendProgress Death Relay.lnk"

Write-Host ""
Write-Host "FriendProgress death relay setup" -ForegroundColor Green
Write-Host "Posts your own WoW deaths to a Discord channel."
Write-Host ""

$old = if (Test-Path $configPath) { Get-Content $configPath -Raw | ConvertFrom-Json } else { $null }

# --- WoW folder -------------------------------------------------------------
# Normally this script sits in <WoW>\<version>\Interface\AddOns\FriendProgress\discord.
function Find-WowFolders {
    $found = @()
    if ($PSScriptRoot -match '^(.*)\\Interface\\AddOns\\') { $found += $Matches[1] }
    $roots = @()
    foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft",
                     "HKLM:\SOFTWARE\Blizzard Entertainment\World of Warcraft") {
        try { $roots += Split-Path (Get-ItemProperty $key -ErrorAction Stop).InstallPath.TrimEnd('\') } catch { }
    }
    $roots += "C:\Program Files (x86)\World of Warcraft", "C:\Program Files\World of Warcraft"
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Directory | Where-Object {
            Test-Path (Join-Path $_.FullName "Interface\AddOns\FriendProgress")
        } | ForEach-Object { $found += $_.FullName }
    }
    return @($found | Select-Object -Unique)
}

# @() because PowerShell returns a single result as a bare string, and "path"[0] is "C".
$folders = @(Find-WowFolders)
if ($folders.Count -eq 1) {
    $wow = $folders[0]
} elseif ($folders.Count -gt 1) {
    Write-Host "FriendProgress is installed in more than one WoW version:"
    for ($i = 0; $i -lt $folders.Count; $i++) { Write-Host "  $($i + 1). $($folders[$i])" }
    do { $pick = Read-Host "Which one do you play WoW Forever in? (1-$($folders.Count))" }
    until ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $folders.Count)
    $wow = $folders[[int]$pick - 1]
} else {
    Write-Host "Couldn't find your WoW folder."
    do { $wow = (Read-Host "Paste the folder that contains Interface\AddOns (e.g. C:\Program Files (x86)\World of Warcraft\_forever_)").Trim('"', ' ') }
    until (Test-Path (Join-Path $wow "Interface"))
}
Write-Host "WoW folder: $wow"
Write-Host ""

# --- Webhook ----------------------------------------------------------------
Write-Host "Paste the Discord webhook URL for the deaths channel"
Write-Host "(Discord: channel settings > Integrations > Webhooks > Copy Webhook URL)."
while ($true) {
    $prompt = if ($old.webhookUrl) { "Webhook URL (Enter keeps the current one)" } else { "Webhook URL" }
    $url = (Read-Host $prompt).Trim()
    if (-not $url -and $old.webhookUrl) { $url = $old.webhookUrl }
    if ($url -notmatch '^https://(\w+\.)?discord(app)?\.com/api/webhooks/\d+/[\w-]+$') {
        Write-Host "That doesn't look like a Discord webhook URL; try again." -ForegroundColor Yellow
        continue
    }
    try {
        # A GET only reads the webhook's details; it doesn't post anything.
        $hook = Invoke-RestMethod -Uri $url -Method Get
        Write-Host "Found webhook '$($hook.name)'." -ForegroundColor Green
        break
    } catch {
        Write-Host "Discord didn't accept that webhook ($($_.Exception.Message)); try again." -ForegroundColor Yellow
    }
}
Write-Host ""

# --- Install ----------------------------------------------------------------
# Stop a relay that's already running so the new copy and config take over.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$relayPath*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $PSScriptRoot "DeathRelay.ps1") $relayPath -Force
Unblock-File $relayPath
Copy-Item (Join-Path $PSScriptRoot "DeathQuips.json") $dest -Force
@{ webhookUrl = $url; wowFolder = $wow } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

$relayArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$relayPath`""
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut($shortcutPath)
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = $relayArgs
$lnk.WorkingDirectory = $dest
$lnk.WindowStyle = 7   # minimized; -WindowStyle Hidden then hides it
$lnk.Description = "Posts your FriendProgress deaths to Discord"
$lnk.Save()

# Start it in its own folder, as the shortcut does: otherwise it inherits this script's
# working directory (the addon's discord folder) and Windows won't let WowUp replace
# the addon folder on update while the relay is running.
Start-Process powershell.exe -ArgumentList $relayArgs -WindowStyle Hidden -WorkingDirectory $dest

Write-Host "Installed. The relay is running now and will start with Windows." -ForegroundColor Green
Write-Host ""
Write-Host "Last step, in game:"
Write-Host "  /fp discord       turn on posting your deaths (once; it covers all your characters)"
Write-Host "                    after you die, releasing spirit reloads your UI and the post goes out"
Write-Host "  /fp deaths test   reloads your UI; a [Test] post should appear within a few seconds"
Write-Host ""
Write-Host "If nothing posts, check $dest\relay.log"
