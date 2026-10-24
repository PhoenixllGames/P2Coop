# Installs POSTAL 2 co-op (P2Coop) into a POSTAL 2 folder (Steam, build 5100).
#
#   install.ps1 [-Game "<POSTAL 2 folder>"] [-Uninstall] [-DryRun]
#   Without -Game: the folder of this script (or its parent) when it holds System\Postal2.exe,
#   else POSTAL 2 in the Steam library folders.
#   install.ps1 -SelfTest [-Game "<POSTAL 2 folder>"]
#
# The game is then started as always (Steam's Play button, the stock System\Postal2.exe) and has
# Co-op in its main menu. Single player works as before. Adds, never replaces game files:
#   System\P2Coop.u        the co-op package
#   System\P2CoopRu.int    the mod's Russian menu texts (used by a Russian copy)
#   System\dinput8.dll     P2CoopHk: the co-op engine fixes and the menu's control of the Steam relay.
#                          The game's WinDrv.dll loads it from System and it passes DirectInput on to
#                          Windows' own dinput8.dll.
#   P2CoopLink\            the Steam relay (P2CoopLink.exe, steam_api.dll, steam_appid.txt)
# and edits the player's System\Postal2.ini (first saved as Postal2.ini.p2coop-backup): the
# co-op main menu, the packages clients need, net rates for co-op, no server browser actors.
# -Uninstall removes the files and puts the edited Postal2.ini settings back as they were; the
# player's other settings stay as they are now.
# -DryRun shows what would change and changes nothing. -SelfTest checks the Postal2.ini edit and
# its undo on a copy in memory of the game's Postal2.ini (or Default.ini, or a built-in sample).
# The files to install come from the folder of this script (see README.md, "Build (developer)").
param(
    [string]$Game = '',
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

# True when this script runs in a console window of its own (started with "Run with PowerShell"
# or a double click): the window closes at the end, so wait for Enter to keep the result readable.
function Test-OwnConsole {
    try {
        if (-not ('P2Coop.Con' -as [type])) {
            Add-Type -Namespace P2Coop -Name Con -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);'
        }
        [P2Coop.Con]::GetConsoleProcessList((New-Object 'uint32[]' 8), 8) -le 1
    } catch { $false }
}
function Quit([int]$Code) {
    if (Test-OwnConsole) { try { [void](Read-Host 'Press Enter to close') } catch { } }
    exit $Code
}
function Fail([string]$Msg) { Write-Host "P2Coop install: $Msg" -ForegroundColor Red; Quit 1 }

# The POSTAL 2 folders to try when -Game is missing: next to this script, then the Steam libraries.
function Find-Game {
    $c = @($here, (Split-Path $here -Parent))
    try {
        $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) { $libs += $m.Matches[0].Groups[1].Value -replace '\\\\', '\' }
        }
        foreach ($l in $libs) { $c += (Join-Path $l 'steamapps\common\POSTAL2Complete') }
    } catch { }
    foreach ($d in $c) { if ($d -and (Test-Path (Join-Path $d 'System\Postal2.exe'))) { return $d } }
    $null
}

$files = @('System\P2Coop.u', 'System\P2CoopRu.int', 'System\dinput8.dll', 'P2CoopLink')
# What earlier versions added: a patched copy of Postal2.exe, its co-op ini and .bat launchers.
$legacy = @('System\P2CoopHost.exe', 'System\P2CoopHk.dll', 'System\P2CoopHostSplash.bmp', 'System\P2CoopHost.int',
            'System\P2CoopGame.ini', 'System\P2CoopHost.log', 'P2Coop.bat', 'P2Coop Host.bat', 'P2Coop Join.bat')

# The Postal2.ini settings P2Coop changes. Packages a client needs to resolve single-player
# classes (the stock list has only multiplayer packages).
$extraPackages = 'GameTypes', 'BasePeople', 'People', 'AIPack', 'AWPawns', 'AWInventory', 'AWPStuff', 'EDStuff',
                 'FX2', 'Postal2Holidays', 'P2Coop'
$force = [ordered]@{
    'Engine.Engine'      = [ordered]@{ BaseMenu = 'P2Coop.CoopRootWindow' }
    # A host that loads a save serves the save itself (16 MB) to clients; at the stock 20000
    # bytes/s that took about 13 minutes.
    'IpDrv.TcpNetDriver' = [ordered]@{ MaxConnPerIPPerMinute = '64'; MaxClientRate = '1000000'; MaxInternetClientRate = '1000000' }
    'Engine.Player'      = [ordered]@{ ConfiguredInternetSpeed = '1000000'; ConfiguredLanSpeed = '1000000' }
}
$rootSection = 'P2Coop.CoopRootWindow'

function Read-Ini([string]$Path) { @(Get-Content $Path -Encoding Default) }
function Write-Ini([string]$Path, $Lines) { [IO.File]::WriteAllLines($Path, [string[]]$Lines, [Text.Encoding]::Default) }
function Section-Of([string]$Line) { if ($Line -match '^\s*\[(.+)\]\s*$') { $Matches[1] } else { $null } }
function Key-Of([string]$Line) { ($Line -split '=', 2)[0].Trim() }
function Value-Of([string]$Line) { if ($Line -match '=') { ($Line -split '=', 2)[1].Trim() } else { '' } }

# Section -> list of its key=value lines.
function Get-Sections($Lines) {
    $s = @{}; $cur = ''
    foreach ($l in $Lines) {
        $sec = Section-Of $l
        if ($sec) { $cur = $sec; if (-not $s.ContainsKey($cur)) { $s[$cur] = New-Object System.Collections.Generic.List[string] }; continue }
        if ($cur -and $l.Trim()) { $s[$cur].Add($l) }
    }
    $s
}

# The co-op settings applied to Lines (a Postal2.ini). Applying them again changes nothing more.
function Add-Coop($Lines) {
    $out = New-Object System.Collections.Generic.List[string]
    $section = ''; $seen = @{}
    # A subclass reads its config from its own section: the stock menu's settings carry over
    # (kept as they are on a reinstall).
    $sections = Get-Sections $Lines
    $rootLines = if ($sections.ContainsKey($rootSection)) { $sections[$rootSection] } else { $sections['Shell.ShellRootWindow'] }
    $flush = {
        param($Sec)
        if ($force.Contains($Sec)) { foreach ($k in $force[$Sec].Keys) { if (-not $seen["$Sec|$k"]) { $out.Add("$k=$($force[$Sec][$k])") } } }
        if ($Sec -eq 'Engine.GameEngine') { foreach ($p in $extraPackages) { $out.Add("ServerPackages=$p") } }
    }
    foreach ($line in $Lines) {
        $sec = Section-Of $line
        if ($sec) {
            if ($section) { & $flush $section }
            $section = $sec
            if ($section -ne $rootSection) { $out.Add($line) }
            continue
        }
        if ($section -eq $rootSection) { continue }    # written again below
        $key = Key-Of $line
        if ($section -eq 'Engine.GameEngine') {
            if ($key -eq 'ServerActors') { continue }   # no server browser query, master server uplink, beacon or web server
            if ($key -eq 'ServerPackages' -and $extraPackages -contains (Value-Of $line)) { continue }
        }
        if ($force.Contains($section) -and $force[$section].Contains($key)) {
            $seen["$section|$key"] = $true; $line = "$key=$($force[$section][$key])"
        }
        $out.Add($line)
    }
    if ($section) { & $flush $section }
    while ($out.Count -and -not $out[$out.Count - 1].Trim()) { $out.RemoveAt($out.Count - 1) }
    foreach ($sec in $force.Keys) {
        if ($sections.ContainsKey($sec)) { continue }
        $out.Add(''); $out.Add("[$sec]"); foreach ($k in $force[$sec].Keys) { $out.Add("$k=$($force[$sec][$k])") }
    }
    $out.Add(''); $out.Add("[$rootSection]"); if ($rootLines) { foreach ($l in $rootLines) { $out.Add($l) } }
    $out
}

# Lines (the current Postal2.ini) with the settings P2Coop changed as they are in Original (the
# backup); everything else stays as the player has it now.
function Remove-Coop($Lines, $Original) {
    $orig = Get-Sections $Original
    $now = Get-Sections $Lines
    $out = New-Object System.Collections.Generic.List[string]
    $section = ''; $done = @{}
    $origValues = {
        param($Sec, $Key)
        if (-not $orig.ContainsKey($Sec)) { return @() }
        @($orig[$Sec] | Where-Object { (Key-Of $_) -eq $Key })
    }
    # The server actors go back before the first ServerPackages line, where the stock ini has them.
    $actorsAtTop = -not ($now.ContainsKey('Engine.GameEngine') -and ($now['Engine.GameEngine'] | Where-Object { (Key-Of $_) -eq 'ServerPackages' }))
    foreach ($line in $Lines) {
        $sec = Section-Of $line
        if ($sec) {
            $section = $sec
            if ($section -eq $rootSection) { continue }
            $out.Add($line)
            if ($section -eq 'Engine.GameEngine' -and $actorsAtTop) { foreach ($l in (& $origValues $section 'ServerActors')) { $out.Add($l) } }
            continue
        }
        if ($section -eq $rootSection) { continue }
        $key = Key-Of $line
        if ($section -eq 'Engine.GameEngine') {
            if ($key -eq 'ServerActors') { continue }
            if ($key -eq 'ServerPackages' -and -not $actorsAtTop -and -not $done['actors']) {
                $done['actors'] = $true
                foreach ($l in (& $origValues $section 'ServerActors')) { $out.Add($l) }
            }
            if ($key -eq 'ServerPackages' -and $extraPackages -contains (Value-Of $line)) {
                $was = @(& $origValues $section 'ServerPackages' | Where-Object { (Value-Of $_) -eq (Value-Of $line) })
                if (-not $was) { continue }
            }
        }
        if ($force.Contains($section) -and $force[$section].Contains($key)) {
            if ($done["$section|$key"]) { continue }
            $done["$section|$key"] = $true
            foreach ($l in (& $origValues $section $key)) { $out.Add($l) }
            continue
        }
        $out.Add($line)
    }
    while ($out.Count -and -not $out[$out.Count - 1].Trim()) { $out.RemoveAt($out.Count - 1) }
    $out
}

# Our dinput8.dll has the export P2CoopHkVersion; another one belongs to something else.
function Test-OurDinput([string]$Path) {
    $text = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($Path))
    $text.Contains("P2CoopHkVersion`0")
}

# "section|key" -> the key's values in order: what the engine reads from an ini.
function Get-Settings($Lines) {
    $m = @{}; $cur = ''
    foreach ($l in $Lines) {
        $sec = Section-Of $l
        if ($sec) { $cur = $sec; continue }
        if (-not $cur -or -not $l.Trim()) { continue }
        $k = "$cur|$(Key-Of $l)"
        if (-not $m.ContainsKey($k)) { $m[$k] = New-Object System.Collections.Generic.List[string] }
        $m[$k].Add((Value-Of $l))
    }
    $m
}

# What differs between two inis, setting by setting ("section|key: old -> new").
function Compare-Settings($A, $B) {
    $a = Get-Settings $A; $b = Get-Settings $B
    foreach ($k in (@($a.Keys) + @($b.Keys) | Sort-Object -Unique)) {
        $va = if ($a.ContainsKey($k)) { $a[$k] -join ' ; ' } else { '(none)' }
        $vb = if ($b.ContainsKey($k)) { $b[$k] -join ' ; ' } else { '(none)' }
        if ($va -cne $vb) { "  ${k}: $va -> $vb" }
    }
}

if ($SelfTest) {
    $src = $null
    if ($Game) {
        foreach ($n in 'Postal2.ini', 'Default.ini') { $p = Join-Path (Join-Path $Game 'System') $n; if (-not $src -and (Test-Path $p)) { $src = $p } }
    }
    $orig = if ($src) { Read-Ini $src } else {
        @('[Engine.Engine]', 'BaseMenu=Shell.ShellRootWindow', '', '[Engine.GameEngine]', 'CacheSizeMegs=32',
          'ServerActors=IpDrv.UdpBeacon', 'ServerActors=UWeb.WebServer', 'ServerPackages=FPSGame', 'ServerPackages=MultiGame',
          '', '[IpDrv.TcpNetDriver]', 'MaxClientRate=20000', '', '[Shell.ShellRootWindow]', 'InstalledVersion=5100')
    }
    "self-test on $(if ($src) { $src } else { 'the built-in sample' }) (read only)"
    $fails = 0
    function Check([bool]$Ok, [string]$What) { if ($Ok) { "  ok   $What" } else { "  FAIL $What"; $script:fails++ } }
    $a = @(Add-Coop $orig)
    $s = Get-Settings $a
    Check ($s['Engine.Engine|BaseMenu'] -join ',' -eq 'P2Coop.CoopRootWindow') 'BaseMenu is the co-op menu'
    Check (-not $s.ContainsKey('Engine.GameEngine|ServerActors')) 'no server actors'
    $pk = @($s['Engine.GameEngine|ServerPackages'])
    $missing = @($extraPackages | Where-Object { $x = $_; @($pk | Where-Object { $_ -eq $x }).Count -ne 1 })
    Check ($missing.Count -eq 0) "every extra package listed once$(if ($missing) { " (not: $($missing -join ','))" })"
    Check ($s['IpDrv.TcpNetDriver|MaxClientRate'] -join ',' -eq '1000000') 'net rate'
    Check ($s.ContainsKey("$rootSection|InstalledVersion")) 'the menu settings carry over'
    $b = @(Add-Coop $a)
    Check (($a -join "`n") -ceq ($b -join "`n")) 'a second install changes nothing'
    # The player changes a setting while P2Coop is installed (the game saves Postal2.ini).
    $played = @($a) + @('', '[P2Coop.SelfTest]', 'Changed=1')
    $c = @(Remove-Coop $played $orig)
    $diff = @(Compare-Settings (@($orig) + @('', '[P2Coop.SelfTest]', 'Changed=1')) $c)
    Check ($diff.Count -eq 0) 'uninstall puts the co-op settings back and keeps the player''s'
    $diff
    $d = @(Remove-Coop (@(Add-Coop $orig)) $orig)
    Check (@(Compare-Settings $orig $d).Count -eq 0) 'install then uninstall gives the same settings'
    if ($fails) { "SELFTEST: FAIL ($fails)"; exit 1 }
    'SELFTEST: PASS'
    exit 0
}

if (-not $Game) {
    $Game = Find-Game
    if (-not $Game) { Fail 'POSTAL 2 not found; run again with -Game "<POSTAL 2 folder>"' }
    "POSTAL 2 found: $Game"
}
# Quotes pasted with the path, and a relative path: .NET file calls resolve those against the
# process directory, not PowerShell's location, so make it absolute once.
try { $Game = (Resolve-Path -LiteralPath $Game.Trim().Trim('"').Trim("'")).ProviderPath.TrimEnd('\') }
catch { Fail "the folder $Game does not exist" }
$sys = Join-Path $Game 'System'
$ini = Join-Path $sys 'Postal2.ini'
$backup = Join-Path $sys 'Postal2.ini.p2coop-backup'
if (-not (Test-Path (Join-Path $sys 'Postal2.exe'))) { Fail "no System\Postal2.exe in $Game" }
# The game writes Postal2.ini when it quits, over the edit.
$full = (Resolve-Path $Game).Path.TrimEnd('\')
if (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$full\*" }) {
    Fail "POSTAL 2 (or P2CoopLink) is running from $Game; close it first"
}
$dll = Join-Path $sys 'dinput8.dll'
$ourDll = (Test-Path $dll) -and (Test-OurDinput $dll)

if ($Uninstall) {
    $remove = @($files + $legacy | Where-Object { $_ -ne 'System\dinput8.dll' -or $ourDll } | Where-Object { Test-Path (Join-Path $Game $_) })
    if ($DryRun) {
        'dry run, nothing changed. Uninstall would:'
        foreach ($f in $remove) { "  remove $f" }
        if ((Test-Path $backup) -and (Test-Path $ini)) {
            '  put back in Postal2.ini:'
            Compare-Settings (Read-Ini $ini) (Remove-Coop (Read-Ini $ini) (Read-Ini $backup))
            '  remove System\Postal2.ini.p2coop-backup'
        }
        Quit 0
    }
    foreach ($f in $remove) { Remove-Item (Join-Path $Game $f) -Recurse -Force -ErrorAction SilentlyContinue }
    $left = @($remove | Where-Object { Test-Path (Join-Path $Game $_) })
    if ($left) { Fail "could not remove: $($left -join ', ') (in use? close everything that runs from $Game and run -Uninstall again)" }
    if (Test-Path $backup) {
        if (Test-Path $ini) { Write-Ini $ini (Remove-Coop (Read-Ini $ini) (Read-Ini $backup)) }
        Remove-Item $backup -Force
        "Postal2.ini: the co-op settings are back as they were before P2Coop"
    }
    "P2Coop removed from $Game"
    Quit 0
}

# The engine hooks and the relay are made for build 5100.
$verIni = Join-Path $sys 'Version.ini'
$m = if (Test-Path $verIni) { Select-String -Path $verIni -Pattern '^InstalledVersion=(\d+)' }
$ver = if ($m) { $m[0].Matches[0].Groups[1].Value } else { 'unknown (no System\Version.ini)' }
if ($ver -ne '5100') { Fail "this is POSTAL 2 version '$ver'; P2Coop needs 5100 (the current Steam build)" }
foreach ($f in 'P2Coop.u', 'P2CoopRu.int', 'dinput8.dll', 'P2CoopLink\P2CoopLink.exe', 'P2CoopLink\steam_api.dll') {
    if (-not (Test-Path (Join-Path $here $f))) { Fail "the release is missing $f" }
}
if ((Test-Path $dll) -and -not $ourDll) {
    Fail "System\dinput8.dll is there already and is not P2Coop's (another mod?). P2Coop needs that file name; remove the other one first"
}

# Postal2.ini. A game that was never started has none yet; the engine would make it from
# Default.ini, so this does the same. The backup keeps the player's own settings from before the
# first install (a reinstall keeps it).
$default = Join-Path $sys 'Default.ini'
$current = if (Test-Path $ini) { Read-Ini $ini } elseif (Test-Path $default) { Read-Ini $default } else { Fail "no System\Postal2.ini or System\Default.ini in $Game" }
$edited = Add-Coop $current
if ($DryRun) {
    'dry run, nothing changed. Install would:'
    foreach ($f in $legacy) { if (Test-Path (Join-Path $Game $f)) { "  remove $f (an earlier version)" } }
    '  copy P2Coop.u, P2CoopRu.int, dinput8.dll to System, and P2CoopLink\'
    if (-not (Test-Path $backup)) { '  save Postal2.ini as System\Postal2.ini.p2coop-backup' }
    '  change in Postal2.ini:'
    Compare-Settings $current $edited
    Quit 0
}

foreach ($f in $legacy) { Remove-Item (Join-Path $Game $f) -Recurse -Force -ErrorAction SilentlyContinue }
$left = @($legacy | Where-Object { Test-Path (Join-Path $Game $_) })
if ($left) { Fail "could not remove files of an earlier version: $($left -join ', ') (in use?); close everything that runs from $Game and run again" }
Copy-Item (Join-Path $here 'P2Coop.u'), (Join-Path $here 'P2CoopRu.int'), (Join-Path $here 'dinput8.dll') $sys -Force
if (-not (Test-Path $backup)) { Write-Ini $backup $current }
Write-Ini $ini $edited

# The relay, in its own folder with its own steam_api.dll and app id (480, Spacewar).
$linkDir = Join-Path $Game 'P2CoopLink'
New-Item -ItemType Directory -Force $linkDir | Out-Null
Copy-Item (Join-Path $here 'P2CoopLink\P2CoopLink.exe'), (Join-Path $here 'P2CoopLink\steam_api.dll') $linkDir -Force
Set-Content (Join-Path $linkDir 'steam_appid.txt') '480' -Encoding ASCII -NoNewline

"P2Coop installed into $Game"
"  play: start POSTAL 2 as always (Steam's Play button), then Co-op in the main menu"
"        (over Steam with friends, or by address)"
"  Postal2.ini was saved as System\Postal2.ini.p2coop-backup; -Uninstall puts its settings back"
Quit 0
