# End-to-end check of the Co-op menu over the mock Steam: two copies of the stock Postal2.exe start
# at the main menu; the host picks Co-op -> "Play over Steam" -> "Create game", the client
# Co-op -> "Play over Steam" and the first friend's game the page lists. The page starts
# P2CoopLink (P2CoopHk, P2COOP_LINK_DIR = the mock relay), waits for its status and opens the
# game. A third copy opens the Steam page and presses Escape there. Passes when the client joins
# the host's game through the relay, the host's game started as a new game (not marked cheated),
# Escape stopped the third copy's relay and no relay outlives its game.
# The picks come from P2COOP_MENU_TEST (CoopRootWindow.MenuTest): keys and clicks on a window that is not in front are not reliable.
param(
    [string]$System = '',
    [int]$Timeout = 150,
    [int]$MockPortBase = 0	# 0: the copy's (testgame.local "mock=", else 47000) + 50
)
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gamewindows.ps1')
if (-not $MockPortBase) { $MockPortBase = [int](Get-TestSetting 'mock' 47000) + 50 }
$gameRoot = Split-Path $System -Parent
$mock = Join-Path $gameRoot 'P2CoopLinkMock'
$names = @('MenuHost', 'MenuLeave', 'MenuClient')
python -I (Join-Path $PSScriptRoot 'mkcoopini.py') $System @names | Out-Null
foreach ($n in $names) { Remove-Item (Join-Path $System "$n.log") -ErrorAction SilentlyContinue }
Get-ChildItem $mock -Include 'menu-status*.txt', 'mock_steam.log', 'P2CoopLink-*.log' -Recurse -ErrorAction SilentlyContinue | Remove-Item
# A copy left over from an earlier run would keep files open and ports busy (only this game copy).
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$gameRoot\*" } | Stop-Process -Force
Initialize-GameWindows (Get-TestSetting 'display' '') '800x600' ([int](Get-TestSetting 'slot' 0)) | Out-Null

function Start-Copy([string]$Name, [int]$Slot, [string]$MockName, [string]$Pick) {
    $envs = Get-BackgroundEnv $Slot
    $envs.P2COOP_MENU_TEST = $Pick
    $envs.P2COOP_LINK_DIR = $mock
    $envs.P2COOP_MOCK_STEAM_NAME = $MockName
    $envs.P2COOP_MOCK_STEAM_PORT_BASE = "$MockPortBase"
    $envs.P2COOP_MOCK_STEAM_LOG = '1'
    Start-WithEnv (Join-Path $System 'Postal2.exe') "-NewWindow -nosteam ini=P2Coop$Name.ini userini=P2Coop${Name}User.ini log=$Name.log" $System $envs
}

# The relays a game started (P2CoopHk passes its process id).
function Get-Relays($Game) {
    @(Get-CimInstance Win32_Process -Filter "Name = 'P2CoopLink.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "--game-pid $($Game.Id)(\s|$)" })
}

function Wait-Until([scriptblock]$Test, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) { if (& $Test) { return $true }; Start-Sleep -Milliseconds 500 }
    return $false
}

# Waits for Pattern in the copy's log; gives up early when the copy's process ($Proc) has exited.
function Wait-Log([string]$Name, [string]$Pattern, [int]$Seconds, $Proc = $null) {
    $log = Join-Path $System "$Name.log"
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ($true) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern $Pattern -Quiet)) { return $true }
        if ((Get-Date) -ge $deadline -or ($Proc -and $Proc.HasExited)) { return $false }
        Start-Sleep 1
    }
}

$procs = @()
$ok = $false
$joined = $false
try {
    $h = Start-Copy 'MenuHost' 0 'Host' 'host'; $procs += $h
    $hosting = Wait-Log 'MenuHost' 'TcpNetDriver on port 7777|TcpNetDriver.*7777' 120 $h
    "host: listen server from the menu: $hosting"
    $newGame = $hosting -and (Wait-Log 'MenuHost' 'PostTravel\(\): Continuing existing game' 30 $h)
    "host: the first map continues the menu's new game: $newGame"
    if ($hosting) {
        # Escape on the Steam page stops the relay that lists the games (the game goes on).
        $l = Start-Copy 'MenuLeave' 2 'Client2' 'leave'; $procs += $l
        $listing = Wait-Until { @(Get-Relays $l).Count -gt 0 } 90
        $stopped = $listing -and (Wait-Until { @(Get-Relays $l).Count -eq 0 -or $l.HasExited } 60) -and -not $l.HasExited
        "leave: the Steam page started its relay: $listing, Escape stopped it: $stopped"
        if (-not $l.HasExited) { $null = $l.CloseMainWindow(); if (-not $l.WaitForExit(20000)) { $l.Kill() } }
        $escaped = (Test-Path (Join-Path $System 'MenuLeave.log')) -and
            (Select-String -Path (Join-Path $System 'MenuLeave.log') -Pattern 'leaves the Steam page and stops the relay (list)' -SimpleMatch -Quiet)
        "leave: the log says Escape left the page: $escaped"
        $c = Start-Copy 'MenuClient' 1 'Client' 'join'; $procs += $c
        $listed = Wait-Log 'MenuClient' 'co-op menu joins lobby' 90 $c
        "client: the Steam page listed the host's game and joined it: $listed"
        $opened = $listed -and (Wait-Log 'MenuClient' 'co-op menu opens 127\.0\.0\.1:' 120 $c)
        "client: relay ready, menu opened its address: $opened"
        # The engine writes its log in blocks: a quiet host (the Monday map screen) may show the
        # join only when it quits, so the full log is checked again below.
        $joinWait = [Math]::Min($Timeout, 45)
        $joined = $opened -and (Wait-Log 'MenuHost' 'DevNet: Join succeeded' $joinWait $h)
        "host: client joined (live log): $joined"
        $ok = $newGame -and $stopped -and $escaped -and $opened
    }
} finally {
    foreach ($p in $procs) { if ($p -and -not $p.HasExited) { $null = $p.CloseMainWindow(); if (-not $p.WaitForExit(20000)) { $p.Kill() } } }
    Start-Sleep 3
    $left = @(Get-Process P2CoopLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$mock*" })
    "relays still running after the games closed: $($left.Count)"
    $left | Stop-Process -Force
}
$hostLog = Join-Path $System 'MenuHost.log'
if ($ok -and -not $joined) {
    $joined = (Test-Path $hostLog) -and (Select-String -Path $hostLog -Pattern 'DevNet: Join succeeded' -SimpleMatch -Quiet)
    "host: client joined (full log after quitting): $joined"
}
$ok = $ok -and $joined
$cheated = (Test-Path $hostLog) -and (Select-String -Path $hostLog -Pattern 'PLAYER CHEATED' -SimpleMatch -Quiet)
"host: game marked cheated: $cheated"
foreach ($n in $names) {
    if (-not (Test-Path (Join-Path $System "$n.log"))) { "  $n | no log"; continue }
    Select-String -Path (Join-Path $System "$n.log") -Pattern 'co-op menu|^Critical|PLAYER CHEATED' -ErrorAction SilentlyContinue |
        Select-Object -First 8 | ForEach-Object { "  $n | $($_.Line)" }
}
Get-ChildItem $mock -Filter 'P2CoopLink-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
    $f = $_
    Get-Content $f.FullName | Select-Object -Last 3 | ForEach-Object { "  $($f.Name) | $_" }
}
# A copy that crashed (a Critical line) fails the run, unless it is the failure P2CoopHk contains on quit.
$crashed = @()
foreach ($n in $names) {
    $f = Join-Path $System "$n.log"
    if ((Test-Path $f) -and (Select-String -Path $f -Pattern '^Critical' -Quiet) -and
        -not (Select-String -Path $f -Pattern 'P2CoopHk: an object failed to shut down on exit' -SimpleMatch -Quiet)) { $crashed += $n }
}
"copies that crashed: $($crashed.Count)$(if ($crashed) { ' (' + ($crashed -join ', ') + ')' })"
if ($ok -and -not $cheated -and $left.Count -eq 0 -and $crashed.Count -eq 0) { 'RESULT: PASS' } else { 'RESULT: FAIL'; exit 1 }
