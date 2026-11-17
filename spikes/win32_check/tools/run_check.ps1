# run_check.ps1 - run win32_check.exe in the logged-on user's *interactive* session (session 1)
# from an SSH shell (session 0) via a scheduled task, run inject.ps1 (mouse/keys/maximize/close)
# and shot.ps1 (screenshot) in that session at the given offsets, wait for the "closing"
# milestone in the log, print everything, unregister the tasks.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\spikes\win32_check\tools\run_check.ps1
#   ... -CheckArgs '--seconds 20' -InjectDelay 2000 -Shot 5500
#   ... -Inject 0 -Shot 2000                 (no injection: just run, screenshot, wait for --seconds)
param(
  [string]$CheckArgs = '--seconds 25',
  [int]$InjectDelay = 2000,   # ms after start to run inject.ps1
  [int]$Inject = 1,           # 0 = do not inject
  [int]$Shot = 8000,          # ms after start to take the screenshot (inject.ps1 holds the window maximized ~7.5-10 s); 0 = none
  [int]$Timeout = 45          # s to wait for "closing"
)
$tools = 'C:\baldr\spikes\win32_check\tools'
$exe = 'C:\baldr\build\win32_check.exe'
$log = 'C:\baldr\build\win32_check.log'
$png = 'C:\baldr\build\win32_check.png'
Remove-Item $log, $png, 'C:\baldr\build\check_shot.log', 'C:\baldr\build\inject.log' -ErrorAction SilentlyContinue

$user = (Get-CimInstance Win32_ComputerSystem).UserName
$explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output "console user: $user; explorer session: $($explorer.SessionId); this script's session: $((Get-Process -Id $PID).SessionId)"
if (-not $user -or -not $explorer) { Write-Output "NOBODY LOGGED ON INTERACTIVELY"; exit 2 }
if (Get-Process win32_check -ErrorAction SilentlyContinue) { Write-Output "a win32_check.exe is already running; kill it first"; exit 3 }

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
function Task($name, $exe, $argList) {
  Register-ScheduledTask -TaskName $name -Force -Principal $principal -Action (New-ScheduledTaskAction -Execute $exe -Argument $argList) | Out-Null
}
Task BaldrCheck $exe "$CheckArgs --log $log"
# conhost --headless: Windows Terminal ignores -WindowStyle Hidden and would pop a terminal over the window.
if ($Shot -gt 0)   { Task BaldrCheckShot 'conhost.exe' "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tools\shot.ps1" }
if ($Inject -ne 0) { Task BaldrCheckInject 'conhost.exe' "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tools\inject.ps1" }

$t0 = Get-Date
Start-ScheduledTask BaldrCheck
$fired = @{}
$deadline = $t0.AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
  $ms = ((Get-Date) - $t0).TotalMilliseconds
  if ($Inject -ne 0 -and -not $fired.inject -and $ms -ge $InjectDelay) { Start-ScheduledTask BaldrCheckInject; $fired.inject = $true }
  if ($Shot -gt 0 -and -not $fired.shot -and $ms -ge $Shot) { Start-ScheduledTask BaldrCheckShot; $fired.shot = $true }
  if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'closing' -Quiet) -and (-not $Shot -or $fired.shot) -and (-not $Inject -or $fired.inject)) { break }
  Start-Sleep -Milliseconds 100
}
Start-Sleep -Milliseconds 1000
foreach ($n in 'BaldrCheck','BaldrCheckShot','BaldrCheckInject') {
  $i = Get-ScheduledTaskInfo $n -ErrorAction SilentlyContinue
  if ($i) { Write-Output ("--- {0}: last run {1}, result 0x{2:X}" -f $n, $i.LastRunTime, $i.LastTaskResult) }
}
Write-Output "--- log"; if (Test-Path $log) { Get-Content $log } else { Write-Output "(no log file)" }
foreach ($f in 'inject.log','check_shot.log') { if (Test-Path "C:\baldr\build\$f") { Write-Output "--- $f"; Get-Content "C:\baldr\build\$f" } }
if (Test-Path $png) { $f = Get-Item $png; Write-Output "--- png $($f.Length) bytes $($f.LastWriteTime)" }
foreach ($n in 'BaldrCheck','BaldrCheckShot','BaldrCheckInject') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
if (Get-Process win32_check -ErrorAction SilentlyContinue) { Write-Output "win32_check still alive -> Stop-Process"; Stop-Process -Name win32_check -Force }
# inject.ps1 flips the app theme to dark and restores it; this is the safety net if it died half-way.
# (HKCU of the interactive user is only reachable from session 0 via the registry path of that SID.)
$sid = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$theme = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
$light = (Get-ItemProperty $theme -ErrorAction SilentlyContinue).AppsUseLightTheme
Write-Output "--- AppsUseLightTheme after run: $light"
if ($light -eq 0) { Set-ItemProperty -Path $theme -Name AppsUseLightTheme -Value 1 -Type DWord; Write-Output "    (was left at 0: restored to 1)" }
Write-Output "--- tasks cleaned up; still running: $((Get-Process win32_check -ErrorAction SilentlyContinue | Measure-Object).Count)"
