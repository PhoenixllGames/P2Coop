# Starts one copy of the game (P2CoopHost.exe, co-op ini) to the main menu, optionally runs
# clicks, and saves a picture of its window. For checking the menus by eye.
# Usage: menushot.ps1 [-Out <png>] [-Wait 30] [-Clicks '520,420',...] [-Keys 0x28,0x0D]
param(
    [string]$System = '',
    [string]$Out = (Join-Path $env:TEMP 'p2coop-menu.png'),
    [int]$Wait = 30,
    # Clicks sent to the game window after $Wait seconds, 3 s apart: "x,y" in client pixels.
    [string[]]$Clicks = @(),
    # Keys sent after the clicks, 1 s apart: virtual-key codes (0x28 down, 0x0D enter, 0x1B esc).
    [int[]]$Keys = @()
)
. (Join-Path $PSScriptRoot 'testgame.ps1')
if (-not $System) { $System = Get-TestSystem }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gamewindows.ps1')
Add-Type -AssemblyName System.Drawing
if (-not ('P2Coop.Win' -as [type])) {
    Add-Type -Namespace P2Coop -Name Win -MemberDefinition @'
public struct RECT { public int Left, Top, Right, Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
'@
}
python -I (Join-Path $PSScriptRoot 'mkcoopini.py') $System Menu | Out-Null
Initialize-GameWindows | Out-Null
$p = Start-WithEnv (Join-Path $System 'P2CoopHost.exe') '-NewWindow -nosteam ini=P2CoopMenu.ini userini=P2CoopMenuUser.ini log=Menu.log' $System (Get-BackgroundEnv 0)
Start-Sleep $Wait
$p.Refresh()
$h = $p.MainWindowHandle
# Window messages to the viewport, so the game need not have the focus: move, press, release.
$view = [P2Coop.Win]::FindWindowEx($h, [IntPtr]::Zero, 'Postal2UnrealWWindowsViewportWindow', $null)
if ($view -eq [IntPtr]::Zero) { $view = $h }
foreach ($c in $Clicks) {
    $x, $y = $c -split ','
    $lp = [IntPtr](([int]$y -shl 16) -bor [int]$x)
    [void][P2Coop.Win]::PostMessage($view, 0x0200, [IntPtr]0, $lp)
    Start-Sleep -Milliseconds 300
    [void][P2Coop.Win]::PostMessage($view, 0x0201, [IntPtr]1, $lp)
    Start-Sleep -Milliseconds 100
    [void][P2Coop.Win]::PostMessage($view, 0x0202, [IntPtr]0, $lp)
    Start-Sleep 3
}
foreach ($k in $Keys) {
    [void][P2Coop.Win]::PostMessage($view, 0x0100, [IntPtr]$k, [IntPtr]1)
    Start-Sleep -Milliseconds 100
    [void][P2Coop.Win]::PostMessage($view, 0x0101, [IntPtr]$k, [IntPtr]0xC0000001)
    Start-Sleep 1
}
Start-Sleep 2
$r = New-Object P2Coop.Win+RECT
[void][P2Coop.Win]::GetWindowRect($h, [ref]$r)
$bmp = New-Object System.Drawing.Bitmap ($r.Right - $r.Left), ($r.Bottom - $r.Top)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size)
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
$null = $p.CloseMainWindow()
if (-not $p.WaitForExit(20000)) { $p.Kill() }
"saved $Out"
