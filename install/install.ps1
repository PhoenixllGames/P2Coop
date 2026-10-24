# Installs POSTAL 2 co-op (P2Coop) into a POSTAL 2 folder (Steam, build 5100).
#
#   install.ps1 -Game "<POSTAL 2 folder>" [-Uninstall]
#
# Adds, never replaces game files:
#   System\P2Coop.u                      the co-op package
#   System\P2CoopRu.int                  the mod's Russian menu texts (used by a Russian copy)
#   System\P2CoopHost.exe, P2CoopHk.dll  a copy of Postal2.exe with the co-op engine fixes
#   System\P2CoopHostSplash.bmp, .int    copies the engine wants next to that exe
#   System\P2CoopGame.ini                Postal2.ini with the co-op settings
#   P2CoopLink\                          the Steam relay (P2CoopLink.exe, steam_api.dll, steam_appid.txt)
#   "P2Coop.bat" (the game with the Co-op menu), "P2Coop Host.bat", "P2Coop Join.bat"
# The files to install come from the folder of this script (see README.md, "Build a release").
param(
    [Parameter(Mandatory)][string]$Game,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$sys = Join-Path $Game 'System'

function Fail([string]$Msg) { Write-Host "P2Coop install: $Msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $sys 'Postal2.exe'))) { Fail "no System\Postal2.exe in $Game" }

$added = @('System\P2Coop.u', 'System\P2CoopRu.int', 'System\P2CoopHost.exe', 'System\P2CoopHk.dll',
           'System\P2CoopHostSplash.bmp', 'System\P2CoopHost.int', 'System\P2CoopGame.ini', 'P2CoopLink',
           'P2Coop.bat', 'P2Coop Host.bat', 'P2Coop Join.bat')
if ($Uninstall) {
    foreach ($f in $added) { Remove-Item (Join-Path $Game $f) -Recurse -Force -ErrorAction SilentlyContinue }
    "P2Coop removed from $Game"
    exit 0
}

# The engine hooks and the relay are made for build 5100.
$ver = (Select-String -Path (Join-Path $sys 'Version.ini') -Pattern '^InstalledVersion=(\d+)' -ErrorAction SilentlyContinue).Matches.Groups[1].Value
if ($ver -ne '5100') { Fail "this is POSTAL 2 version '$ver'; P2Coop needs 5100 (the current Steam build)" }
foreach ($f in 'P2Coop.u', 'P2CoopRu.int', 'P2CoopHk.dll', 'P2CoopLink\P2CoopLink.exe', 'P2CoopLink\steam_api.dll') {
    if (-not (Test-Path (Join-Path $here $f))) { Fail "the release is missing $f" }
}

# P2CoopHost.exe: Postal2.exe with its COMDLG32.dll import renamed to P2CoopHk.dll (same length
# budget, padded with zeros), which loads the host's engine fixes. One occurrence expected.
$exe = [IO.File]::ReadAllBytes((Join-Path $sys 'Postal2.exe'))
$old = [Text.Encoding]::ASCII.GetBytes("COMDLG32.dll`0")
$new = [Text.Encoding]::ASCII.GetBytes("P2CoopHk.dll`0")
$hits = @()
for ($i = 0; $i -le $exe.Length - $old.Length; $i++) {
    if ($exe[$i] -ne $old[0]) { continue }
    $match = $true
    for ($k = 1; $k -lt $old.Length; $k++) { if ($exe[$i + $k] -ne $old[$k]) { $match = $false; break } }
    if ($match) { $hits += $i }
}
if ($hits.Count -ne 1) { Fail "Postal2.exe does not look like the 5100 build ($($hits.Count) COMDLG32.dll imports)" }
[Array]::Copy($new, 0, $exe, $hits[0], $new.Length)
[IO.File]::WriteAllBytes((Join-Path $sys 'P2CoopHost.exe'), $exe)
Copy-Item (Join-Path $sys 'Postal2Splash.bmp') (Join-Path $sys 'P2CoopHostSplash.bmp') -Force
Copy-Item (Join-Path $sys 'Postal2.int') (Join-Path $sys 'P2CoopHost.int') -Force
Copy-Item (Join-Path $here 'P2Coop.u'), (Join-Path $here 'P2CoopRu.int') $sys -Force
Copy-Item (Join-Path $here 'P2CoopHk.dll') $sys -Force

# P2CoopGame.ini: the player's Postal2.ini plus what co-op needs.
$extraPackages = 'GameTypes', 'BasePeople', 'People', 'AIPack', 'AWPawns', 'AWInventory', 'AWPStuff', 'EDStuff',
                 'FX2', 'Postal2Holidays', 'P2Coop'
$force = @{
    'Engine.Engine'         = @{ BaseMenu = 'P2Coop.CoopRootWindow' }
    'IpDrv.TcpNetDriver'    = @{ MaxConnPerIPPerMinute = '64'; MaxClientRate = '1000000'; MaxInternetClientRate = '1000000' }
    'Engine.Player'         = @{ ConfiguredInternetSpeed = '1000000'; ConfiguredLanSpeed = '1000000' }
}
$src = Get-Content (Join-Path $sys 'Postal2.ini') -Encoding Default
$out = New-Object System.Collections.Generic.List[string]
$section = ''; $seen = @{}; $shellRoot = @()
function Flush([string]$Sec) {
    if ($force.ContainsKey($Sec)) { foreach ($k in $force[$Sec].Keys) { if (-not $seen["$Sec|$k"]) { $out.Add("$k=$($force[$Sec][$k])") } } }
    if ($Sec -eq 'Engine.GameEngine') { foreach ($p in $extraPackages) { $out.Add("ServerPackages=$p") } }
}
foreach ($line in $src) {
    if ($line -match '^\[(.+)\]\s*$') {
        if ($section) { Flush $section }
        $section = $Matches[1]; $out.Add($line); continue
    }
    $key = ($line -split '=', 2)[0].Trim()
    if ($section -eq 'Shell.ShellRootWindow' -and $line.Trim()) { $shellRoot += $line }
    if ($section -eq 'Engine.GameEngine') {
        if ($key -eq 'ServerActors') { continue }   # no server browser query, master server uplink, beacon or web server
        if ($key -eq 'ServerPackages' -and $extraPackages -contains ($line -split '=', 2)[1].Trim()) { continue }
    }
    if ($force.ContainsKey($section) -and $force[$section].ContainsKey($key)) {
        $seen["$section|$key"] = $true; $line = "$key=$($force[$section][$key])"
    }
    $out.Add($line)
}
if ($section) { Flush $section }
$out.Add(''); $out.Add('[P2Coop.CoopRootWindow]'); foreach ($l in $shellRoot) { $out.Add($l) }
[IO.File]::WriteAllLines((Join-Path $sys 'P2CoopGame.ini'), $out, [Text.Encoding]::Default)

# The relay, in its own folder with its own steam_api.dll and app id (480, Spacewar).
$linkDir = Join-Path $Game 'P2CoopLink'
New-Item -ItemType Directory -Force $linkDir | Out-Null
Copy-Item (Join-Path $here 'P2CoopLink\P2CoopLink.exe'), (Join-Path $here 'P2CoopLink\steam_api.dll') $linkDir -Force
Set-Content (Join-Path $linkDir 'steam_appid.txt') '480' -Encoding ASCII -NoNewline
Set-Content (Join-Path $Game 'P2Coop.bat') "@echo off`r`ncd /d `"%~dp0System`"`r`nstart `"`" P2CoopHost.exe ini=P2CoopGame.ini`r`n" -Encoding ASCII
Set-Content (Join-Path $Game 'P2Coop Host.bat') "@echo off`r`ncd /d `"%~dp0P2CoopLink`"`r`nP2CoopLink.exe host %*`r`n" -Encoding ASCII
Set-Content (Join-Path $Game 'P2Coop Join.bat') "@echo off`r`ncd /d `"%~dp0P2CoopLink`"`r`nP2CoopLink.exe join %*`r`n" -Encoding ASCII

"P2Coop installed into $Game"
"  play:  'P2Coop.bat', then Co-op in the main menu (host or join over Steam or by address)"
"  host: 'P2Coop Host.bat' (optional map name, default suburbs-3)"
"  join: 'P2Coop Join.bat' (optional lobby id)"
