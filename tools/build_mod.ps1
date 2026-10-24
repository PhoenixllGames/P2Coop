# Rebuilds System\P2Coop.u in the test copy with P2Ucc.
# UCC "make" only compiles packages whose .u is missing, so the old one is deleted first.
# Prints compiler errors and warnings for P2Coop and exits 1 on failure.
param([string]$System = '')
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }

$u = Join-Path $System 'P2Coop.u'
Remove-Item $u -ErrorAction SilentlyContinue
# A running copy of the game keeps the package open; make would then keep the old one.
if (Test-Path $u) { "cannot replace $u (is a game copy still running?)"; exit 1 }
$p = Start-Process -FilePath (Join-Path $System 'P2Ucc.exe') -WorkingDirectory $System `
    -ArgumentList 'make', 'ini=P2Coop.ini' -PassThru -WindowStyle Hidden
if (-not $p.WaitForExit(600000)) { $p.Kill(); 'make: timeout'; exit 1 }

$log = Join-Path $System 'P2Ucc.log'
Select-String -Path $log -Pattern '\\P2Coop\\Classes\\.*\((\d+)\)|: Error|Warning:.*P2Coop\.|Success: Compiled|Failed due to errors' |
    ForEach-Object Line
if ($p.ExitCode -ne 0 -or -not (Test-Path $u)) {
    # Parse errors come as plain "Warning:" lines without file and line, right before the failure.
    Select-String -Path $log -Pattern '^Warning:' | Select-Object -Last 4 | ForEach-Object Line
    "make failed (exit $($p.ExitCode))"; exit 1
}
"built $u"
