# inject.ps1 - drive the running win32_check window with real input from the interactive session:
# pointer moves into the client area, left/right clicks, a wheel notch, a drag that leaves the window,
# keys ('a', Shift+'B', Enter, F5, arrows, Escape), focus away and back, app theme flipped to dark
# (registry + WM_SETTINGCHANGE "ImmersiveColorSet", restored at the end), maximize (screenshot
# window), restore, an interactive corner drag (modal size loop), pointer out (Leave), WM_CLOSE.
# Each step is timestamped into inject.log so it can be lined up with the win32_check log.
$L = 'C:\baldr\build\inject.log'
$ThemeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
function Log($s) { "$(Get-Date -Format 'HH:mm:ss.fff') $s" | Out-File -Append $L }
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace Baldr {
  public static class In {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, IntPtr w, string l, uint flags, uint timeout, out IntPtr result);
    public static void Key(byte vk, bool extended) {
      byte scan = (byte)MapVirtualKeyW(vk, 0);
      uint f = extended ? 1u : 0u;                       // KEYEVENTF_EXTENDEDKEY
      keybd_event(vk, scan, f, UIntPtr.Zero); System.Threading.Thread.Sleep(40);
      keybd_event(vk, scan, f | 2u, UIntPtr.Zero); System.Threading.Thread.Sleep(60);   // KEYEVENTF_KEYUP
    }
    public static void Down(byte vk) { keybd_event(vk, (byte)MapVirtualKeyW(vk, 0), 0, UIntPtr.Zero); System.Threading.Thread.Sleep(40); }
    public static void Up(byte vk)   { keybd_event(vk, (byte)MapVirtualKeyW(vk, 0), 2, UIntPtr.Zero); System.Threading.Thread.Sleep(40); }
    // What Settings does when the user flips "Choose your default app mode".
    public static void BroadcastTheme() { IntPtr r; SendMessageTimeoutW((IntPtr)0xFFFF, 0x001A, IntPtr.Zero, "ImmersiveColorSet", 2, 1000, out r); }
    // Bottom-right corner drag: Windows enters its modal size loop (WM_ENTERSIZEMOVE..WM_EXITSIZEMOVE).
    public static string DragCorner(IntPtr h, int dx, int dy, int steps, int sleepMs) {
      RECT r; GetWindowRect(h, out r);
      int x = r.Right - 3, y = r.Bottom - 3;
      SetCursorPos(x, y); System.Threading.Thread.Sleep(200);
      mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(200);
      for (int i = 1; i <= steps; i++) { SetCursorPos(x + dx * i / steps, y + dy * i / steps); System.Threading.Thread.Sleep(sleepMs); }
      System.Threading.Thread.Sleep(200);
      mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
      return "dragged corner from " + x + "," + y + " by " + dx + "," + dy;
    }
  }
}
'@
$p = $null
for ($i = 0; $i -lt 50 -and -not $p; $i++) {
  $p = Get-Process win32_check -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { Start-Sleep -Milliseconds 100 }
}
if (-not $p) { Log "no win32_check window"; exit 0 }
$h = $p.MainWindowHandle
$wr = New-Object Baldr.In+RECT; [Baldr.In]::GetWindowRect($h, [ref]$wr) | Out-Null
$cr = New-Object Baldr.In+RECT; [Baldr.In]::GetClientRect($h, [ref]$cr) | Out-Null
$o = New-Object Baldr.In+POINT; $o.X = 0; $o.Y = 0; [Baldr.In]::ClientToScreen($h, [ref]$o) | Out-Null
Log "proc $($p.Id) hwnd $h window $($wr.Left),$($wr.Top) $($wr.Right - $wr.Left)x$($wr.Bottom - $wr.Top) client origin $($o.X),$($o.Y) size $($cr.Right)x$($cr.Bottom)"
[Baldr.In]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300

$lightBefore = (Get-ItemProperty $ThemeKey).AppsUseLightTheme
try {
  # --- pointer: approach from outside (Enter), two moves inside (Motion)
  $cx = $o.X + [int]($cr.Right / 2); $cy = $o.Y + [int]($cr.Bottom / 2)
  [Baldr.In]::SetCursorPos($wr.Right + 40, $cy) | Out-Null; Start-Sleep -Milliseconds 150
  [Baldr.In]::SetCursorPos($o.X + 100, $o.Y + 80) | Out-Null; Start-Sleep -Milliseconds 150     # expect Enter at (100,80)
  [Baldr.In]::SetCursorPos($o.X + 200, $o.Y + 150) | Out-Null; Start-Sleep -Milliseconds 150    # Motion (200,150)
  [Baldr.In]::SetCursorPos($cx, $cy) | Out-Null; Start-Sleep -Milliseconds 150                  # Motion (centre)
  Log "pointer entered and moved to client centre $cx,$cy (client $([int]($cr.Right/2)),$([int]($cr.Bottom/2)))"
  # --- buttons
  [Baldr.In]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80      # LEFTDOWN
  [Baldr.In]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150     # LEFTUP
  [Baldr.In]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80      # RIGHTDOWN
  [Baldr.In]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150     # RIGHTUP
  Log "left click + right click at centre"
  [Baldr.In]::mouse_event(0x0800, 0, 0, -120, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150  # WHEEL one notch down (expect delta.y = +48)
  Log "wheel down one notch"
  # --- drag with the left button held: 3 moves, last one outside the window (capture)
  [Baldr.In]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  [Baldr.In]::SetCursorPos($cx + 30, $cy + 20) | Out-Null; Start-Sleep -Milliseconds 80
  [Baldr.In]::SetCursorPos($cx + 60, $cy + 40) | Out-Null; Start-Sleep -Milliseconds 80
  [Baldr.In]::SetCursorPos($wr.Right + 60, $cy + 40) | Out-Null; Start-Sleep -Milliseconds 120   # outside: Motion must still arrive (SetCapture)
  [Baldr.In]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150       # release outside -> Leave
  Log "drag from centre to outside the window and release (expect Motion outside, then Leave)"
  [Baldr.In]::SetCursorPos($cx, $cy) | Out-Null; Start-Sleep -Milliseconds 150                    # back in -> Enter
  Log "pointer back to centre (expect Enter)"

  # --- keys (window is foreground): a, Shift+B, Enter, F5, Left, Right, Up, Down, Escape
  [Baldr.In]::Key(0x41, $false)                          # 'a'  -> Ev_Key A + Ev_Text "a"
  [Baldr.In]::Down(0x10); [Baldr.In]::Key(0x42, $false); [Baldr.In]::Up(0x10)   # Shift+'B' -> Ev_Text "B", mods Shift
  [Baldr.In]::Key(0x0D, $false)                          # Enter -> Ev_Key Enter, NO Ev_Text
  [Baldr.In]::Key(0x74, $false)                          # F5
  [Baldr.In]::Key(0x25, $true); [Baldr.In]::Key(0x27, $true); [Baldr.In]::Key(0x26, $true); [Baldr.In]::Key(0x28, $true)  # arrows (extended)
  [Baldr.In]::Key(0x1B, $false)                          # Escape -> Ev_Key, no Ev_Text
  Log "keys sent: a, Shift+B, Enter, F5, Left, Right, Up, Down, Escape"

  # --- focus away (desktop) and back: Ev_Configure activated=false/true + Ev_Focus false/true
  $shell = [Baldr.In]::GetShellWindow()
  Log "focus -> desktop: $([Baldr.In]::SetForegroundWindow($shell))"; Start-Sleep -Milliseconds 500
  Log "focus -> window: $([Baldr.In]::SetForegroundWindow($h))"; Start-Sleep -Milliseconds 500

  # --- app theme to dark: the backend must emit Ev_Theme{dark=true} and darken the title bar
  Set-ItemProperty -Path $ThemeKey -Name AppsUseLightTheme -Value 0 -Type DWord
  [Baldr.In]::BroadcastTheme()
  Log "AppsUseLightTheme 0 + WM_SETTINGCHANGE ImmersiveColorSet (was $lightBefore)"
  Start-Sleep -Milliseconds 600

  # --- maximize (expect Ev_Configure maximized=true, new size_px), hold for the screenshot, restore
  [Baldr.In]::ShowWindow($h, 3) | Out-Null; Start-Sleep -Milliseconds 300                         # SW_MAXIMIZE
  Log "SW_MAXIMIZE: IsZoomed=$([Baldr.In]::IsZoomed($h))"
  Start-Sleep -Milliseconds 2700
  [Baldr.In]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 400                         # SW_RESTORE
  Log "SW_RESTORE: IsZoomed=$([Baldr.In]::IsZoomed($h))"

  # --- interactive corner drag: modal size loop -> redraw_callback, then Ev_Configure(s)
  Log ([Baldr.In]::DragCorner($h, 120, 80, 8, 60))
  Start-Sleep -Milliseconds 300
} finally {
  Set-ItemProperty -Path $ThemeKey -Name AppsUseLightTheme -Value $lightBefore -Type DWord
  [Baldr.In]::BroadcastTheme()
  Log "AppsUseLightTheme restored to $lightBefore + WM_SETTINGCHANGE (expect Ev_Theme dark=false)"
  Start-Sleep -Milliseconds 500
}

# --- pointer out (Leave), then close (Ev_Close; the app exits itself)
[Baldr.In]::SetCursorPos($wr.Right + 200, $wr.Bottom + 200) | Out-Null; Start-Sleep -Milliseconds 300
Log "pointer moved outside (expect Leave)"
Log "posted WM_CLOSE: $([Baldr.In]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero))"
