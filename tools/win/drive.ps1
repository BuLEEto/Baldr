# drive.ps1 — runs in the interactive session: find the example's window, focus it, send keys,
# screenshot the primary screen, close the window. Logs to build\<exe>.driver.log.
param([string]$Exe = '01_hello', [int]$Keys = 1)
$L = "C:\baldr\build\$Exe.driver.log"
function Log($s) { "$(Get-Date -Format 'HH:mm:ss.fff') $s" | Out-File -Append $L }
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
namespace BaldrDrive {
  public static class W {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyW(uint code, uint mapType);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
    public static void Key(byte vk) {
      byte scan = (byte)MapVirtualKeyW(vk, 0);
      keybd_event(vk, scan, 0, UIntPtr.Zero); System.Threading.Thread.Sleep(50);
      keybd_event(vk, scan, 2, UIntPtr.Zero); System.Threading.Thread.Sleep(120);
    }
  }
}
'@
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$p = $null
for ($i = 0; $i -lt 100 -and -not $p; $i++) {
  $p = Get-Process $Exe -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if (-not $p) { Start-Sleep -Milliseconds 100 }
}
if (-not $p) { Log "no $Exe window; done"; exit 0 }
$h = $p.MainWindowHandle
$r = New-Object BaldrDrive.W+RECT; [BaldrDrive.W]::GetWindowRect($h, [ref]$r) | Out-Null
Log "window $($r.Left),$($r.Top) $($r.Right - $r.Left)x$($r.Bottom - $r.Top)"
[BaldrDrive.W]::SetCursorPos(($r.Left + $r.Right) / 2, $r.Top + 60) | Out-Null
[BaldrDrive.W]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 400
if ($Keys -ne 0) {
  [BaldrDrive.W]::Key(0x09); [BaldrDrive.W]::Key(0x09)      # Tab, Tab → "+" (Reset is disabled at 0)
  [BaldrDrive.W]::Key(0x0D); [BaldrDrive.W]::Key(0x0D)      # Enter ×2 → Count: 2
  Log "sent Tab Tab Enter Enter"
}
Start-Sleep -Milliseconds 600
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$bmp.Save("C:\baldr\build\$Exe.png", [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Log "screenshot $($b.Width)x$($b.Height)"
[BaldrDrive.W]::PostMessageW($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE
Start-Sleep -Milliseconds 500
Log ("closed; process alive: " + [bool](Get-Process $Exe -ErrorAction SilentlyContinue) + "; done")
