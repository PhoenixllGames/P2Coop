# Puts test copies of the game side by side on the main monitor without overlapping: each copy is
# started with P2COOP_WINDOW_POS=x,y and P2CoopHk.dll (tools/ucc5100/bgwindows.h) places its
# window there. Places form a grid sized for the game resolution; a copy of the game used by
# another worktree takes other places (testgame.local "slot=").
# Focus stays stock: blocking activation broke map changes.
# This script picks the monitor and the slots, and counts how often a game had the foreground.

Add-Type -AssemblyName System.Windows.Forms
if (-not ('P2Coop.Fg' -as [type])) {
    Add-Type -Namespace P2Coop -Name Fg -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
'@
}

$script:GW = @{ Screen = $null; Stolen = 0; Classes = @{}; SlotW = 816; SlotH = 639; SlotBase = 0 }

# Counts how often a game process owns the foreground window (it never should), by window class.
function Watch-Foreground($Procs) {
    $pid_ = [uint32]0
    $h = [P2Coop.Fg]::GetForegroundWindow()
    [void][P2Coop.Fg]::GetWindowThreadProcessId($h, [ref]$pid_)
    if ($Procs | Where-Object { $_ -and $_.Id -eq $pid_ }) {
        $script:GW.Stolen++
        $sb = New-Object System.Text.StringBuilder 128
        [void][P2Coop.Fg]::GetClassName($h, $sb, 128)
        $script:GW.Classes[$sb.ToString()] = 1 + [int]$script:GW.Classes[$sb.ToString()]
    }
}

function Get-ForegroundSteals {
    "$($script:GW.Stolen)" + $(if ($script:GW.Stolen) { " (" + (($script:GW.Classes.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + ")" })
}

# $Res is the game resolution (a window adds its frame: 16 x 39 pixels); $SlotBase the first place.
function Initialize-GameWindows([string]$Display = '', [string]$Res = '800x600', [int]$SlotBase = 0) {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $pick = if ($Display) { $screens | Where-Object DeviceName -eq $Display } else { [System.Windows.Forms.Screen]::PrimaryScreen }
    if (-not $pick) { $pick = [System.Windows.Forms.Screen]::PrimaryScreen }
    $w, $h = $Res -split 'x'
    $script:GW.Screen = $pick
    $script:GW.SlotW = [int]$w + 16
    $script:GW.SlotH = [int]$h + 39
    $script:GW.SlotBase = $SlotBase
    "game windows go to $($pick.DeviceName) $($pick.WorkingArea), places from $SlotBase"
}

# "x,y" of window place $Index of this run (0 = host), after SlotBase; left to right, then the next
# row. Past the last place it starts over (then windows overlap).
function Get-WindowSlot([int]$Index) {
    $a = $script:GW.Screen.WorkingArea
    $cols = [Math]::Max(1, [Math]::Floor($a.Width / $script:GW.SlotW))
    $rows = [Math]::Max(1, [Math]::Floor($a.Height / $script:GW.SlotH))
    $n = ($Index + $script:GW.SlotBase) % ($cols * $rows)
    $x = $a.Left + ($n % $cols) * $script:GW.SlotW
    $y = $a.Top + [Math]::Floor($n / $cols) * $script:GW.SlotH
    "$x,$y"
}

# Start-Process with extra environment variables for the child (set, start, restore).
# $OutFile redirects stdout/stderr and hides the console (for P2CoopLink).
function Start-WithEnv([string]$Exe, [string]$ArgLine, [string]$Dir, [hashtable]$Env = @{}, [string]$OutFile = '') {
    $saved = @{}
    foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $Env[$k]) }
    try {
        if ($OutFile) {
            Start-Process -FilePath $Exe -ArgumentList $ArgLine -WorkingDirectory $Dir -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $OutFile -RedirectStandardError "$OutFile.err"
        } else {
            Start-Process -FilePath $Exe -ArgumentList $ArgLine -WorkingDirectory $Dir -PassThru
        }
    } finally {
        foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
}

# Window-placement variables for copy number $Index (P2CoopHk.dll puts the window in that slot).
function Get-BackgroundEnv([int]$Index) {
    @{ P2COOP_WINDOW_POS = (Get-WindowSlot $Index) }
}
