# Puts test copies of the game on a secondary monitor: each copy is started with
# P2COOP_WINDOW_POS=x,y and P2CoopHk.dll (tools/ucc5100/bgwindows.h) places its window there.
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

$script:GW = @{ Screen = $null; Stolen = 0; Classes = @{} }

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

function Initialize-GameWindows([string]$Display = '') {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    $pick = if ($Display) { $screens | Where-Object DeviceName -eq $Display } else {
        $screens | Where-Object { -not $_.Primary } |
            Sort-Object { $_.WorkingArea.Width * $_.WorkingArea.Height } -Descending | Select-Object -First 1 }
    if (-not $pick) { $pick = [System.Windows.Forms.Screen]::PrimaryScreen }
    $script:GW.Screen = $pick
    "game windows go to $($pick.DeviceName) $($pick.WorkingArea)"
}

# "x,y" of window slot $Index (0 = host), tiled top to bottom, then left to right.
function Get-WindowSlot([int]$Index, [int]$Width = 1040, [int]$Height = 800) {
    $a = $script:GW.Screen.WorkingArea
    $perCol = [Math]::Max(1, [Math]::Floor($a.Height / $Height))
    $x = $a.Left + [Math]::Floor($Index / $perCol) * $Width
    $y = $a.Top + ($Index % $perCol) * $Height
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
