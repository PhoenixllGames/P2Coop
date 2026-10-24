# Runs every in-game co-op test with real game copies (run_local.ps1) and prints a summary.
# Usage: run_suite.ps1 [-Relay] [-Only combat,travel]
param([switch]$Relay, [string[]]$Only = @(), [string]$System = '')
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
# "powershell -File run_suite.ps1 -Only combat,travel" passes one string: split it.
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })

$tests = @(
    @{ Name = 'combat'; Map = 'suburbs-3'; Clients = 1; Timeout = 200; Extra = '' },
    @{ Name = 'travel'; Map = 'suburbs-3'; Clients = 2; Timeout = 700; Extra = '' },
    @{ Name = 'errand'; Map = 'Suburbs-1'; Clients = 1; Timeout = 200; Extra = '' },
    @{ Name = 'screens'; Map = 'suburbs-3'; Clients = 1; Timeout = 240; Extra = '' },
    @{ Name = 'ragdoll';  Map = 'suburbs-3'; Clients = 1; Timeout = 200; Extra = '' },
    @{ Name = 'cutscene'; Map = 'suburbs-3'; Clients = 1; Timeout = 300; Extra = '' },
    @{ Name = 'jail';   Map = 'suburbs-3'; Clients = 1; Timeout = 400; Extra = '' },
    @{ Name = 'death';  Map = 'suburbs-3'; Clients = 1; Timeout = 240; Extra = '?CoopRespawnDelay=3' },
    @{ Name = 'load';   Map = 'suburbs-3'; Clients = 1; Timeout = 360; Extra = '' },
    @{ Name = 'leaderdead'; Map = 'suburbs-3'; Clients = 1; Timeout = 600; Extra = '' }
)
$results = @()
foreach ($t in $tests) {
    if ($Only -and $Only -notcontains $t.Name) { continue }
    $args = @{
        Map = $t.Map; Clients = $t.Clients; Timeout = $t.Timeout; ClientDelay = 5; ClientGap = 3
        UrlExtra = "?CoopTest=$($t.Name)$($t.Extra)"; Until = 'P2CoopTest: DONE'
        System = $System; PassPattern = "P2CoopTest: DONE $($t.Name) pass=\d+ fail=0"
    }
    if ($Relay) { $args.Relay = $true }
    $out = & (Join-Path $PSScriptRoot 'run_local.ps1') @args
    $done = Select-String -Path (Join-Path $System 'Host.log') -Pattern "P2CoopTest: DONE $($t.Name) .*" -ErrorAction SilentlyContinue |
        Select-Object -Last 1 | ForEach-Object { $_.Line -replace '^ScriptLog: ', '' }
    $result = ($out | Select-String 'RESULT:' | Select-Object -Last 1).Line
    $crit = ($out | Select-String 'critical=Critical' | Where-Object { $_.Line -notmatch 'contained by P2CoopHk' } |
        ForEach-Object { ($_.Line -split ' ')[0] }) -join ','
    $quit = ($out | Select-String 'contained by P2CoopHk' | ForEach-Object { ($_.Line -split ' ')[0] }) -join ','
    $results += "{0,-7} {1,-13} {2} {3}{4}" -f $t.Name, $result, $done, $(if ($crit) { "crash in: $crit" }),
        $(if ($quit) { " quit cleanup failed (contained) in: $quit" })
}
''
'=== suite' + $(if ($Relay) { ' (relay)' })
$results
$failed = @($results | Where-Object { $_ -notmatch 'RESULT: PASS' }).Count
"SUITE FINISHED $($results.Count - $failed) pass / $failed not pass"
if (-not $results) { "no test is named $($Only -join ', ')"; exit 1 }
