# close_spike.ps1 - post WM_CLOSE to the running spike; must run in the interactive session.
# Note: FindWindowW via P/Invoke returned 0 from PowerShell here; Process.MainWindowHandle works.
$L = 'C:\baldr\build\close.log'
$u = Add-Type -Name U32 -Namespace Baldr -PassThru -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint m, IntPtr w, IntPtr l);
'@
$p = Get-Process win32_triangle -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { "no win32_triangle process" | Out-File -Append $L; exit 0 }
"proc $($p.Id) session $($p.SessionId) hwnd $($p.MainWindowHandle) title '$($p.MainWindowTitle)'" | Out-File -Append $L
"posted WM_CLOSE: $($u::PostMessageW($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero))" | Out-File -Append $L
Start-Sleep -Milliseconds 1500
if (Get-Process win32_triangle -ErrorAction SilentlyContinue) { "still alive -> Stop-Process" | Out-File -Append $L; Stop-Process -Name win32_triangle -Force }
