# Removes the FriendProgress death relay installed by Install.cmd.
$dest = Join-Path $env:LOCALAPPDATA "FriendProgress"
$relayPath = Join-Path $dest "DeathRelay.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Startup")) "FriendProgress Death Relay.lnk"

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$relayPath*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Remove-Item $shortcutPath -Force -ErrorAction SilentlyContinue
Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "FriendProgress death relay removed." -ForegroundColor Green
Write-Host "In game, /fp discord turns off posting (and stops writing deaths to the chat log)."
