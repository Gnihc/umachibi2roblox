# Installs the Uma2Roblox Roblox Studio plugin into Studio's local plugins folder.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$plugins = Join-Path $env:LOCALAPPDATA "Roblox\Plugins"
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
Copy-Item -Force (Join-Path $here "roblox\Uma2Roblox.plugin.lua") (Join-Path $plugins "Uma2Roblox.lua")
Write-Host "Studio plugin installed -> $plugins\Uma2Roblox.lua  (close and reopen the place in Studio to load it)"
