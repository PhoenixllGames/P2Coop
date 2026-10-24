# Runs a co-op host and N clients of the test copy on this PC and collects their logs.
# The host is a listen server bound to 127.0.0.1; every copy gets its own P2Coop<Name>.ini
# from mkcoopini.py (silent, windowed). Windows go side by side on the primary monitor
# (or -Display \\.\DISPLAY2; gamewindows.ps1, window placement of P2CoopHk).
# Every copy runs the stock Postal2.exe, as players do; it loads P2CoopHk (the engine fixes and the
# window placement, tools/ucc5100) as System\dinput8.dll.
# Usage: run_local.ps1 [-Map suburbs-3] [-Clients 1] [-Timeout 120] [-Until 'P2CoopProbe: DONE']
#                      [-HostExe Postal2.exe] [-Exe Postal2.exe] [-Display \\.\DISPLAY1]
param(
    [string]$System = '',
    [string]$Map = 'suburbs-3',
    [string]$Game = 'P2Coop.CoopGame',
    [int]$Port = 0,		# 0: the copy's port (testgame.local "port=", else 7777)
    [int]$Clients = 1,
    [int]$Timeout = 120,
    [string]$Until = 'P2CoopProbe: DONE',
    [string]$UrlExtra = '',
    [string]$Exe = 'Postal2.exe',
    [string]$HostExe = 'Postal2.exe',
    [int]$ClientDelay = 0,
    [int]$ClientGap = 2,
    [string[]]$HostArgs = @(),
    [string]$Res = '800x600',
    [int]$SlotBase = -1,	# -1: the copy's first window place (testgame.local "slot=", else 0)
    # Regex the host log must also match, e.g. 'P2CoopTest: DONE combat pass=\d+ fail=0'.
    [string]$PassPattern = '',
    [string]$Display = '',
    [switch]$StockMenu,
    [string]$PlayerName = '',
    # Run every copy through P2CoopLink with the mock steam_api.dll (<game>\P2CoopLinkMock):
    # the game traffic goes game -> link -> mock "Steam" (localhost UDP) -> link -> game.
    [switch]$Relay,
    [int]$MockPortBase = 0,	# 0: the copy's (testgame.local "mock=", else 47000)
    # One game ini for every copy (e.g. a windowed copy of a Postal2.ini the installer edited)
    # instead of the per-copy ones from mkcoopini.py.
    [string]$Ini = ''
)
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gamewindows.ps1')
$clientExe = Join-Path $System $Exe
$hostExe = Join-Path $System $HostExe
$names = @('Host') + @(if ($Clients -gt 0) { 1..$Clients | ForEach-Object { "Client$_" } })

$iniArgs = @('--res', $Res) + $(if ($StockMenu) { @('--stock-menu') } else { @() }) +
    $(if ($PlayerName) { @('--player-name', $PlayerName) } else { @() })
python -I (Join-Path $PSScriptRoot 'mkcoopini.py') @iniArgs $System @names | Out-Null
foreach ($n in $names) { Remove-Item (Join-Path $System "$n.log") -ErrorAction SilentlyContinue }
Remove-Item (Join-Path $System 'Running.ini') -ErrorAction SilentlyContinue
# A copy left over from an earlier run (a crash window) would keep files open and the port busy.
Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$(Split-Path $System -Parent)\*" } | Stop-Process -Force
if (-not $Port) { $Port = [int](Get-TestSetting 'port' 7777) }
if (-not $MockPortBase) { $MockPortBase = [int](Get-TestSetting 'mock' 47000) }
if ($SlotBase -lt 0) { $SlotBase = [int](Get-TestSetting 'slot' 0) }
Initialize-GameWindows $Display $Res $SlotBase

$procs = @()
$links = @()
$gameRoot = Split-Path $System -Parent
$linkDir = Join-Path $gameRoot 'P2CoopLinkMock'

function GameIni([string]$Name) { if ($Ini) { $Ini } else { "P2Coop$Name.ini" } }

function Start-Game([string]$Name, [string]$Url, [string[]]$Extra) {
    # Without "NewWindow" a second copy hands its URL to the first copy's window and exits.
    $argLine = (@("`"$Url`"", '-NewWindow', '-nosteam', "ini=$(GameIni $Name)", "userini=P2Coop${Name}User.ini", "log=$Name.log") + $Extra) -join ' '
    $path = if ($Name -eq 'Host') { $hostExe } else { $clientExe }
    Start-WithEnv $path $argLine $System (Get-BackgroundEnv ([array]::IndexOf($names, $Name)))
}

# Relay mode: starts P2CoopLink as <Name> in the mock, which starts the game; returns the game.
function Start-Linked([string]$Name, [string[]]$Extra) {
    $gameArgs = (@('-NewWindow', '-nosteam', "ini=$(GameIni $Name)", "userini=P2Coop${Name}User.ini", "log=$Name.log") + $Extra) -join ' '
    $mockName = if ($Name -eq 'Host') { 'Host' } elseif ($Name -eq 'Client1') { 'Client' } else { $Name }
    $linkArgs = if ($Name -eq 'Host') {
        @('host', $Map, '--game', "`"$gameRoot`"", '--port', $Port, '--url-extra', "`"$UrlExtra`"", '--game-args', "`"$gameArgs`"")
    } else {
        @('join', '--game', "`"$gameRoot`"", '--client-exe', $Exe, '--game-args', "`"$gameArgs`"")
    }
    # The link passes its environment (minus SteamAppId/SteamGameId) to the game.
    $envs = Get-BackgroundEnv ([array]::IndexOf($names, $Name))
    $envs.P2COOP_MOCK_STEAM_NAME = $mockName
    $envs.P2COOP_MOCK_STEAM_PORT_BASE = "$MockPortBase"
    $envs.P2COOP_MOCK_STEAM_LOG = '1'
    $log = Join-Path $System "Link$Name.log"
    $link = Start-WithEnv (Join-Path $linkDir 'P2CoopLink.exe') ($linkArgs -join ' ') $linkDir $envs $log
    if (-not $link) { "link $Name did not start" | Write-Host; return $null }
    $script:links += $link
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $link.HasExited) {
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($link.Id)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '\.exe$' -and $_.Name -notmatch 'conhost' } | Select-Object -First 1
        if ($child) { return Get-Process -Id $child.ProcessId }
        Start-Sleep -Milliseconds 300
    }
    "link $Name started no game (see Link$Name.log)" | Write-Host
    return $null
}

function Wait-Seconds([double]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do { Watch-Foreground $script:procs; Start-Sleep -Milliseconds 200 } while ((Get-Date) -lt $deadline)
}

function Wait-Log([string]$Name, [string]$Pattern, [int]$Seconds) {
    $log = Join-Path $System "$Name.log"
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern $Pattern -SimpleMatch -Quiet)) { return $true }
        if ($script:procs | Where-Object { $_.HasExited }) { return $false }
        Wait-Seconds 0.5
    }
    return $false
}

if ($Relay) { Get-ChildItem $linkDir -Filter mock_steam.log -ErrorAction SilentlyContinue | Remove-Item }
# Without a test, measure the join (CoopProbe quits the host when done).
if ($UrlExtra -notmatch 'CoopTest=|CoopProbe=') { $UrlExtra += '?CoopProbe=join' }
$host_ = if ($Relay) { Start-Linked 'Host' $HostArgs }
         else { Start-Game 'Host' "$Map`?Game=$Game`?Listen`?Port=$Port$UrlExtra" (@('-multihome=127.0.0.1') + $HostArgs) }
$procs += $host_
$ok = $host_ -and (Wait-Log 'Host' "TcpNetDriver on port $Port" 60)
$clientsExited = @()
if ($ok) {
    Wait-Seconds $ClientDelay
    foreach ($n in $(if ($names.Count -gt 1) { $names[1..($names.Count - 1)] })) {
        $c = if ($Relay) { Start-Linked $n @() } else { Start-Game $n "127.0.0.1:$Port" @() }
        if (-not $c) { $ok = $false; break }
        $procs += $c
        Wait-Seconds $ClientGap
    }
}
if ($ok) {
    # The engine log is buffered: the test actor ends the run by quitting the host,
    # so wait for the host to exit and read its log afterwards. A client that exits
    # while the host still runs is a failure.
    $deadline = (Get-Date).AddSeconds($Timeout)
    while (-not $host_.HasExited -and (Get-Date) -lt $deadline) {
        $clientsExited = @($procs | Where-Object { $_ -ne $host_ -and $_.HasExited })
        if ($clientsExited) { break }
        Wait-Seconds 0.5
    }
    $ok = $host_.HasExited
    if (-not $ok -and -not $clientsExited) { 'host did not finish within the timeout' }
}

foreach ($p in @($procs) + @($links)) {
    if ($p -and -not $p.HasExited) {
        $null = $p.CloseMainWindow()
        if (-not $p.WaitForExit(15000)) { $p.Kill() }
    }
}
if ($Relay) {
    foreach ($n in $names) {
        $l = Join-Path $System "Link$n.log"
        if (Test-Path $l) { Select-String -Path $l -Pattern 'ERROR|version check|offset|status|relayed|refused' | Select-Object -Last 4 | ForEach-Object { "  link $n | $($_.Line)" } }
    }
}
$crashed = $false
foreach ($n in $names) {
    $log = Join-Path $System "$n.log"
    $crit = if (Test-Path $log) { Select-String -Path $log -Pattern '^Critical:' | Select-Object -First 3 | ForEach-Object Line } else { 'no log' }
    # P2CoopHk contains a failure in the object cleanup on quit (the game exits normally): shown, not a crash.
    $quitFix = (Test-Path $log) -and (Select-String -Path $log -Pattern 'P2CoopHk: an object failed to shut down on exit' -SimpleMatch -Quiet)
    if ($crit -and -not $quitFix) { $crashed = $true }
    "{0,-8} log={1} critical={2}{3}" -f $n, (Test-Path $log), ((@($crit) -join ' | ') -replace '^$', 'none'),
        $(if ($quitFix) { ' (on quit, contained by P2CoopHk)' })
}
$hostLog = Join-Path $System 'Host.log'
$reached = (Test-Path $hostLog) -and (Select-String -Path $hostLog -Pattern $Until -SimpleMatch -Quiet)
"host log has '$Until': $reached"
if ($reached -and $PassPattern) {
    $reached = Select-String -Path $hostLog -Pattern $PassPattern -Quiet
    "host log matches '$PassPattern': $reached"
}
"game window had the foreground: $(Get-ForegroundSteals) of the 200 ms checks"
if ($clientsExited) { "clients exited while the host ran: " + (($clientsExited | ForEach-Object { $_.Id }) -join ', ') }
if ($ok -and $reached -and -not $crashed -and -not $clientsExited) { 'RESULT: PASS' } else { 'RESULT: FAIL'; exit 1 }
