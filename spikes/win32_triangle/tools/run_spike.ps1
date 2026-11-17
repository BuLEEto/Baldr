# run_spike.ps1 - run win32_triangle.exe in the logged-on user's *interactive* session (session 1)
# from an SSH shell (session 0) via a scheduled task; optionally run another script in that
# session after a delay (shot.ps1 screenshot, drag_spike.ps1, close_spike.ps1); wait for the
# "closing" milestone in the log; print everything; unregister the tasks.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_triangle\tools\run_spike.ps1 `
#       -SpikeArgs '--seconds 4' -Shot 1800
#   ... -SpikeArgs '--maximize --seconds 5' -Shot 2200     (screenshot while maximized)
#   ... -SpikeArgs '--minimize --seconds 6' -Shot 0
#   ... -SpikeArgs '--seconds 10' -Extra drag_spike.ps1 -ExtraDelay 2000 -Shot 6500
param(
  [string]$SpikeArgs = '--seconds 4',
  [int]$Shot = 1800,          # ms after start to take the screenshot; 0 = none
  [string]$Extra = '',        # script in this tools dir to run in the interactive session
  [int]$ExtraDelay = 2000,    # ms after start to run it
  [int]$Timeout = 40          # s to wait for "closing"
)
$tools = 'C:\baldr\spikes\win32_triangle\tools'
$exe = 'C:\baldr\build\win32_triangle.exe'
$log = 'C:\baldr\build\win32_triangle.log'
$png = 'C:\baldr\build\win32_triangle.png'
Remove-Item $log, $png, 'C:\baldr\build\shot.log', 'C:\baldr\build\drag.log', 'C:\baldr\build\close.log' -ErrorAction SilentlyContinue

$user = (Get-CimInstance Win32_ComputerSystem).UserName
$explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output "console user: $user; explorer session: $($explorer.SessionId); this script's session: $((Get-Process -Id $PID).SessionId)"
if (-not $user -or -not $explorer) { Write-Output "NOBODY LOGGED ON INTERACTIVELY"; exit 2 }
if (Get-Process win32_triangle -ErrorAction SilentlyContinue) { Write-Output "a win32_triangle.exe is already running; close it first (close_spike.ps1)"; exit 3 }

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
function Task($name, $exe, $argList) {
  Register-ScheduledTask -TaskName $name -Force -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument $argList) | Out-Null
}
Task BaldrSpike $exe "$SpikeArgs --log $log"
# conhost --headless: Windows Terminal (default console on Win 11) ignores -WindowStyle Hidden and
# would pop a terminal over the spike window right when the screenshot is taken.
if ($Shot -gt 0) { Task BaldrShot 'conhost.exe' "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tools\shot.ps1" }
if ($Extra)      { Task BaldrExtra 'conhost.exe' "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tools\$Extra" }

$t0 = Get-Date
Start-ScheduledTask BaldrSpike
$fired = @{}
$deadline = $t0.AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
  $ms = ((Get-Date) - $t0).TotalMilliseconds
  if ($Extra -and -not $fired.extra -and $ms -ge $ExtraDelay) { Start-ScheduledTask BaldrExtra; $fired.extra = $true }
  if ($Shot -gt 0 -and -not $fired.shot -and $ms -ge $Shot) { Start-ScheduledTask BaldrShot; $fired.shot = $true }
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'closing' -Quiet) -and (-not $Shot -or $fired.shot) -and (-not $Extra -or $fired.extra)) { break }
  Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 1000
foreach ($n in 'BaldrSpike','BaldrShot','BaldrExtra') {
  $i = Get-ScheduledTaskInfo $n -ErrorAction SilentlyContinue
  if ($i) { Write-Output ("--- {0}: last run {1}, result 0x{2:X}" -f $n, $i.LastRunTime, $i.LastTaskResult) }
}
Write-Output "--- log"; if (Test-Path $log) { Get-Content $log } else { Write-Output "(no log file)" }
foreach ($f in 'shot.log','drag.log','close.log') { if (Test-Path "C:\baldr\build\$f") { Write-Output "--- $f"; Get-Content "C:\baldr\build\$f" } }
if (Test-Path $png) { $f = Get-Item $png; Write-Output "--- png $($f.Length) bytes $($f.LastWriteTime)" }
foreach ($n in 'BaldrSpike','BaldrShot','BaldrExtra') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
Write-Output "--- tasks cleaned up; still running: $((Get-Process win32_triangle -ErrorAction SilentlyContinue | Measure-Object).Count)"
