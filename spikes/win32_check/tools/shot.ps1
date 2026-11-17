# shot.ps1 - full primary-screen capture to build\win32_check.png; must run in the interactive session.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
$bmp.Save('C:\baldr\build\win32_check.png', [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"shot $($b.Width)x$($b.Height) at $(Get-Date -Format o)" | Out-File -Append C:\baldr\build\check_shot.log
