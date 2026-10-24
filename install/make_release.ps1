# Collects a P2Coop release folder (what install.ps1 installs) from the built files.
#   make_release.ps1 [-System <test copy System>] [-Out <folder>]
# Needs: tools\build_mod.ps1 (P2Coop.u), tools\ucc5100\build.bat (P2CoopHk.dll),
#        link\build.bat with link\redist\steam_api.dll (P2CoopLink.exe).
# Contains no game files: P2CoopHost.exe is made from the player's own Postal2.exe at install.
param(
    [string]$System = '',
    [string]$Out = (Join-Path $PSScriptRoot '..\release\P2Coop')
)
. (Join-Path $PSScriptRoot '..\tools\testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
New-Item -ItemType Directory -Force (Join-Path $Out 'P2CoopLink') | Out-Null
$Out = (Resolve-Path $Out).Path
Copy-Item (Join-Path $System 'P2Coop.u') $Out -Force
Copy-Item (Join-Path $root 'System\P2CoopRu.int') $Out -Force
Copy-Item (Join-Path $root 'tools\ucc5100\out\P2CoopHk.dll') $Out -Force
Copy-Item (Join-Path $root 'link\out\P2CoopLink.exe') (Join-Path $Out 'P2CoopLink') -Force
Copy-Item (Join-Path $root 'link\redist\steam_api.dll') (Join-Path $Out 'P2CoopLink') -Force
Copy-Item (Join-Path $PSScriptRoot 'install.ps1'), (Join-Path $PSScriptRoot 'README.txt') $Out -Force
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'THIRD_PARTY.md') $Out -Force
Get-ChildItem $Out -Recurse -File | ForEach-Object {
    "{0,-40} {1}" -f $_.FullName.Substring($Out.Length + 1), (Get-FileHash $_.FullName).Hash.Substring(0, 16)
}
