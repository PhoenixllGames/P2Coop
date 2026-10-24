# End-to-end check of the Co-op menu over the mock Steam: two copies start at the main menu; the
# host picks Co-op -> "Host over Steam", the client Co-op -> "Join a friend over Steam". The menu
# starts P2CoopLink (P2CoopHk.dll, P2COOP_LINK_DIR = the mock relay), waits for its status and
# opens the game. Passes when the client joins the host's game through the relay.
# The picks come from P2COOP_MENU_TEST (CoopRootWindow.MenuTest): keys and clicks on a window that is not in front are not reliable.
param(
    [string]$System = '',
    [int]$Timeout = 150,
    [int]$MockPortBase = 47100
)
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gamewindows.ps1')
$gameRoot = Split-Path $System -Parent
$mock = Join-Path $gameRoot 'P2CoopLinkMock'
$names = @('MenuHost', 'MenuClient')
python -I (Join-Path $PSScriptRoot 'mkcoopini.py') $System @names | Out-Null
foreach ($n in $names) { Remove-Item (Join-Path $System "$n.log") -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $mock 'menu-status.txt'), (Join-Path $mock 'mock_steam.log') -ErrorAction SilentlyContinue
Initialize-GameWindows | Out-Null

function Start-Copy([string]$Name, [int]$Slot, [string]$MockName, [string]$Pick) {
    $envs = Get-BackgroundEnv $Slot
    $envs.P2COOP_MENU_TEST = $Pick
    $envs.P2COOP_LINK_DIR = $mock
    $envs.P2COOP_MOCK_STEAM_NAME = $MockName
    $envs.P2COOP_MOCK_STEAM_PORT_BASE = "$MockPortBase"
    $envs.P2COOP_MOCK_STEAM_LOG = '1'
    Start-WithEnv (Join-Path $System 'P2CoopHost.exe') "-NewWindow -nosteam ini=P2Coop$Name.ini userini=P2Coop${Name}User.ini log=$Name.log" $System $envs
}

function Wait-Log([string]$Name, [string]$Pattern, [int]$Seconds) {
    $log = Join-Path $System "$Name.log"
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern $Pattern -Quiet)) { return $true }
        Start-Sleep 1
    }
    return $false
}

$procs = @()
$ok = $false
try {
    $h = Start-Copy 'MenuHost' 0 'Host' 'host'; $procs += $h
    $hosting = Wait-Log 'MenuHost' 'TcpNetDriver on port 7777|TcpNetDriver.*7777' 120
    "host: listen server from the menu: $hosting"
    if ($hosting) {
        $c = Start-Copy 'MenuClient' 1 'Client' 'join'; $procs += $c
        $opened = Wait-Log 'MenuClient' 'co-op menu opens 127\.0\.0\.1:' 120
        "client: relay ready, menu opened its address: $opened"
        $joined = $opened -and (Wait-Log 'MenuHost' 'DevNet: Join succeeded' $Timeout)
        "host: client joined: $joined"
        $ok = $joined
    }
} finally {
    foreach ($p in $procs) { if ($p -and -not $p.HasExited) { $null = $p.CloseMainWindow(); if (-not $p.WaitForExit(20000)) { $p.Kill() } } }
    Start-Sleep 3
    $left = @(Get-Process P2CoopLink -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$mock*" })
    "relays still running after the games closed: $($left.Count)"
    $left | Stop-Process -Force
}
foreach ($n in $names) {
    if (-not (Test-Path (Join-Path $System "$n.log"))) { "  $n | no log"; continue }
    Select-String -Path (Join-Path $System "$n.log") -Pattern 'co-op menu|^Critical' -ErrorAction SilentlyContinue |
        Select-Object -First 8 | ForEach-Object { "  $n | $($_.Line)" }
}
if ($ok -and $left.Count -eq 0) { 'RESULT: PASS' } else { 'RESULT: FAIL'; exit 1 }
