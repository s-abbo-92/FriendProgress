# Builds dist\FriendProgress-<version>.zip, ready to send to friends: it contains
# a FriendProgress folder to drop straight into Interface\AddOns.
#   powershell -ExecutionPolicy Bypass -File tools\Package.ps1
#
# The zip is made from the last commit (git archive), so uncommitted changes and
# local files like relay configs are never included. .gitattributes lists what's
# left out (the tools folder, git files).
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot
Set-Location $root

$version = (Select-String -Path "FriendProgress.toc" -Pattern '^## Version:\s*(\S+)').Matches[0].Groups[1].Value
$coreVersion = (Select-String -Path "Core.lua" -Pattern '^ns\.VERSION = "([^"]+)"').Matches[0].Groups[1].Value
if ($version -ne $coreVersion) { throw "Version mismatch: FriendProgress.toc says $version, Core.lua says $coreVersion." }

if (git status --porcelain) {
    Write-Warning "You have uncommitted changes. They won't be in the zip; commit first if you want them."
}

# The in-game jokes must match the JSON they're generated from.
& (Join-Path $PSScriptRoot "Build-Quips.ps1") | Out-Null
if (git status --porcelain -- DeathQuips.lua) {
    throw "DeathQuips.lua was out of date and has been regenerated. Commit it, then package again."
}

New-Item -ItemType Directory -Force "dist" | Out-Null
$zip = Join-Path $root "dist\FriendProgress-$version.zip"
git archive --format=zip --prefix=FriendProgress/ -o $zip HEAD
if ($LASTEXITCODE -ne 0) { throw "git archive failed." }

$size = [math]::Round((Get-Item $zip).Length / 1KB)
Write-Host "Built $zip ($size KB) from commit $(git rev-parse --short HEAD)." -ForegroundColor Green
