# run_hello.ps1 — run an example (default 01_hello.exe) on the interactive desktop from an SSH
# shell (session 0) via a scheduled task, drive it by keyboard (Tab, Tab, Enter ×2), take a
# screenshot, close it with WM_CLOSE, clean up. Prints the driver log.
#   powershell -NoProfile -ExecutionPolicy Bypass -File C:\baldr\tools\win\run_hello.ps1 [-Exe 01_hello] [-Keys 1]
param([string]$Exe = '01_hello', [int]$Keys = 1, [int]$Timeout = 30)
$exePath = "C:\baldr\build\$Exe.exe"
$png = "C:\baldr\build\$Exe.png"
$dlog = "C:\baldr\build\$Exe.driver.log"
Remove-Item $png, $dlog -ErrorAction SilentlyContinue
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { Write-Output "NOBODY LOGGED ON"; exit 2 }
if (Get-Process $Exe -ErrorAction SilentlyContinue) { Stop-Process -Name $Exe -Force; Start-Sleep -Milliseconds 300 }
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName BaldrApp -Force -Principal $principal -Action (New-ScheduledTaskAction -Execute $exePath -WorkingDirectory 'C:\baldr\build') | Out-Null
Register-ScheduledTask -TaskName BaldrDrive -Force -Principal $principal -Action (New-ScheduledTaskAction -Execute 'conhost.exe' -Argument "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\baldr\tools\win\drive.ps1 -Exe $Exe -Keys $Keys") | Out-Null
Start-ScheduledTask BaldrApp
Start-Sleep -Milliseconds 1500
Start-ScheduledTask BaldrDrive
$deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
  if ((Test-Path $dlog) -and (Select-String -Path $dlog -Pattern 'done' -Quiet)) { break }
  Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 500
Write-Output "--- driver log"; if (Test-Path $dlog) { Get-Content $dlog } else { Write-Output "(no driver log)" }
if (Test-Path $png) { $f = Get-Item $png; Write-Output "--- png $($f.Length) bytes" } else { Write-Output "--- no png" }
foreach ($n in 'BaldrApp','BaldrDrive') { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
if (Get-Process $Exe -ErrorAction SilentlyContinue) { Write-Output "$Exe still alive -> Stop-Process"; Stop-Process -Name $Exe -Force }
Write-Output "--- cleaned up"
