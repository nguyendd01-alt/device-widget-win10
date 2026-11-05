# Gỡ Device Widget: thoát ứng dụng, xoá lối tắt Start Menu + chạy cùng Windows,
# xoá thư mục cài đặt, dữ liệu cài đặt và mục trong Apps & features.
# Thường được gọi từ Settings > Apps > Device Widget > Uninstall.
param([switch]$Quiet)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms

function Show-Msg([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') {
    if ($Quiet) { return 'Yes' }
    [string][Windows.Forms.MessageBox]::Show($text, 'Device Widget', $buttons, $icon,
        [Windows.Forms.MessageBoxDefaultButton]::Button1, [Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

if ((Show-Msg 'Gỡ Device Widget khỏi máy này?' 'YesNo' 'Question') -ne 'Yes') { return }
Set-Location $env:TEMP   # để xoá được thư mục cài đặt

try { [void][System.Threading.EventWaitHandle]::OpenExisting('Local\DeviceStatusWidget.Exit').Set() } catch {}
for ($i = 0; $i -lt 25; $i++) {
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like '*DeviceWidget.ps1*' })
    if ($running.Count -eq 0) { break }
    Start-Sleep -Milliseconds 200
}
$running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($lnk in (Join-Path ([Environment]::GetFolderPath('Programs')) 'Device Widget.lnk'),
                 (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Device Widget.lnk'),
                 (Join-Path ([Environment]::GetFolderPath('Startup')) 'Device Widget.lnk')) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force }
}
foreach ($dir in (Join-Path $env:LOCALAPPDATA 'Programs\DeviceWidget'),
                 (Join-Path $env:LOCALAPPDATA 'DeviceWidget'),
                 (Join-Path $env:APPDATA 'DeviceWidget')) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
}
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeviceWidget' -Recurse -Force -ErrorAction SilentlyContinue

Show-Msg 'Đã gỡ Device Widget.' | Out-Null
