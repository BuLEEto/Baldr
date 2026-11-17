# drag_spike.ps1 - inject a real bottom-right-corner drag (+240,+160 px) on the spike window so
# Windows enters its modal size loop (WM_ENTERSIZEMOVE .. WM_EXITSIZEMOVE). Interactive session only.
$L = 'C:\baldr\build\drag.log'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Threading;
namespace Baldr {
  public static class Drag {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    public static string Corner(IntPtr h, int dx, int dy, int steps, int sleepMs) {
      RECT r; GetWindowRect(h, out r);
      int x = r.Right - 3, y = r.Bottom - 3;
      SetForegroundWindow(h);
      SetCursorPos(x, y); Thread.Sleep(200);
      mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero); Thread.Sleep(200);          // MOUSEEVENTF_LEFTDOWN
      for (int i = 1; i <= steps; i++) { SetCursorPos(x + dx * i / steps, y + dy * i / steps); Thread.Sleep(sleepMs); }
      Thread.Sleep(200);
      mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);                             // MOUSEEVENTF_LEFTUP
      return "rect " + r.Left + "," + r.Top + " " + (r.Right - r.Left) + "x" + (r.Bottom - r.Top) + " dragged corner from " + x + "," + y + " by " + dx + "," + dy;
    }
  }
}
'@
$p = Get-Process win32_triangle -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { "no win32_triangle process" | Out-File -Append $L; exit 0 }
"proc $($p.Id) hwnd $($p.MainWindowHandle) at $(Get-Date -Format o)" | Out-File -Append $L
[Baldr.Drag]::Corner($p.MainWindowHandle, 240, 160, 16, 60) | Out-File -Append $L
