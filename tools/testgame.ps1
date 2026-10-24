# The test copy of the game for the tools: P2COOP_TEST_GAME, or the first line of
# tools\testgame.local (not in git). Never the Steam install.
function Get-TestSystem {
    $game = $env:P2COOP_TEST_GAME
    $local = Join-Path $PSScriptRoot 'testgame.local'
    if (-not $game -and (Test-Path $local)) { $game = (Get-Content $local -TotalCount 1).Trim() }
    if (-not $game) { throw 'Set P2COOP_TEST_GAME (or tools\testgame.local) to the test copy of POSTAL 2, or pass -System.' }
    Join-Path $game 'System'
}
