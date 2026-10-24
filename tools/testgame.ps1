# The test copy of the game for the tools: P2COOP_TEST_GAME, or the first line of
# tools\testgame.local (not in git). Never the Steam install.
function Get-TestSystem {
    $game = $env:P2COOP_TEST_GAME
    $local = Join-Path $PSScriptRoot 'testgame.local'
    if (-not $game -and (Test-Path $local)) { $game = (Get-Content $local -TotalCount 1).Trim() }
    if (-not $game) { throw 'Set P2COOP_TEST_GAME (or tools\testgame.local) to the test copy of POSTAL 2, or pass -System.' }
    Join-Path $game 'System'
}

# Other settings of this copy, so several copies can run tests at the same time: tools\testgame.local
# lines "slot=N" (first window place, see gamewindows.ps1), "port=N" (game port), "mock=N" (mock
# Steam port base), "display=\\.\DISPLAYn" (another monitor), "renderer=Engine.NullRenderDevice"
# (no graphics, see mkcoopini.py --renderer), "res=WxH" (window size, smaller fits more copies side by side);
# P2COOP_TEST_<KEY> overrides a line. Without them: slot 0, port 7777, mock 47000, res 800x600.
function Get-TestSetting([string]$Key, $Default) {
    $env_ = [Environment]::GetEnvironmentVariable("P2COOP_TEST_$($Key.ToUpper())")
    if ($env_) { return $env_ }
    $local = Join-Path $PSScriptRoot 'testgame.local'
    if (Test-Path $local) {
        foreach ($line in (Get-Content $local | Select-Object -Skip 1)) {
            if ($line -match "^\s*$Key\s*=\s*(\S+)") { return $Matches[1] }
        }
    }
    $Default
}
