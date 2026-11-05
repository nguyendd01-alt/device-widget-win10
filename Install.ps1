# Trình cài Device Widget (không cần quyền quản trị, chỉ cài cho tài khoản đang dùng):
#  - chép ứng dụng vào %LOCALAPPDATA%\Programs\DeviceWidget
#  - tạo lối tắt "Device Widget" trong Start Menu
#  - đăng ký vào Settings > Apps & features để gỡ được như phần mềm bình thường
#  - hỏi có muốn chạy cùng Windows không, rồi mở ứng dụng
# Chạy:  nhấp đúp Install.cmd   (hoặc DeviceWidget-Setup.exe)
param(
    [switch]$Quiet,       # không hiện hộp thoại nào (dùng khi cài tự động)
    [switch]$Autostart    # dùng cùng -Quiet: bật chạy cùng Windows
)
$AppVersion = '1.2.0'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

function Show-Msg([string]$text, [string]$buttons = 'OK', [string]$icon = 'Information') {
    if ($Quiet) { return 'OK' }
    [string][Windows.Forms.MessageBox]::Show($text, 'Device Widget', $buttons, $icon,
        [Windows.Forms.MessageBoxDefaultButton]::Button1, [Windows.Forms.MessageBoxOptions]::DefaultDesktopOnly)
}

try {
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 17763) {
        Show-Msg "Device Widget cần Windows 10 bản 1809 trở lên (máy này đang là bản build $build)." 'OK' 'Warning' | Out-Null
        exit 1
    }

    $src = Split-Path -Parent $MyInvocation.MyCommand.Path
    $dest = Join-Path $env:LOCALAPPDATA 'Programs\DeviceWidget'

    # nhờ bản đang chạy tự thoát (để gỡ biểu tượng khay cho sạch), quá 5 giây thì buộc dừng
    try { [void][System.Threading.EventWaitHandle]::OpenExisting('Local\DeviceStatusWidget.Exit').Set() } catch {}
    for ($i = 0; $i -lt 25; $i++) {
        $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
            Where-Object { $_.CommandLine -like '*DeviceWidget.ps1*' })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    # chép tệp
    New-Item -ItemType Directory -Force $dest | Out-Null
    foreach ($f in 'DeviceWidget.ps1', 'DeviceStatus.cs', 'Start-Widget.vbs', 'Launcher.cs', 'Uninstall.ps1') {
        Copy-Item (Join-Path $src $f) (Join-Path $dest $f) -Force
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $dest 'DeviceWidget.ps1') -WriteIcon
    $ico = Join-Path $dest 'app.ico'

    # DeviceWidget.exe: biên dịch trình mở bằng csc.exe có sẵn của .NET Framework
    # (có .exe thật thì Windows Search mới tìm thấy ứng dụng); không được thì dùng lại Start-Widget.vbs
    $exe = Join-Path $dest 'DeviceWidget.exe'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
    if (Test-Path $exe) { Remove-Item $exe -Force -ErrorAction SilentlyContinue }
    if (Test-Path $csc) {
        $cscArgs = @('/nologo', '/target:winexe', '/optimize+', "/out:$exe", "/win32icon:$ico", (Join-Path $dest 'Launcher.cs'))
        & $csc $cscArgs | Out-Null
    }
    $useExe = Test-Path $exe

    # lối tắt
    $ws = New-Object -ComObject WScript.Shell
    function New-AppShortcut([string]$lnkPath, [bool]$hidden) {
        $lnk = $ws.CreateShortcut($lnkPath)
        if ($useExe) {
            $lnk.TargetPath = $exe
            $lnk.Arguments = if ($hidden) { '/hidden' } else { '' }
        } else {
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = '"' + (Join-Path $dest 'Start-Widget.vbs') + '"' + $(if ($hidden) { ' /hidden' } else { '' })
        }
        $lnk.WorkingDirectory = $dest
        $lnk.IconLocation = $ico
        $lnk.Description = 'Device Widget - bảng điều khiển thiết bị'
        $lnk.Save()
    }
    New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Programs')) 'Device Widget.lnk') $false
    New-AppShortcut (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Device Widget.lnk') $false

    # đăng ký vào Apps & features (chỉ cho tài khoản này, không cần quyền quản trị)
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\DeviceWidget'
    New-Item -Path $key -Force | Out-Null
    $uninst = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\Uninstall.ps1`""
    $sizeKb = [int]((Get-ChildItem $dest | Measure-Object Length -Sum).Sum / 1KB)
    $strings = @{ DisplayName = 'Device Widget'; DisplayVersion = $AppVersion; Publisher = 'Device Widget'
                  DisplayIcon = $ico; InstallLocation = $dest; UninstallString = $uninst; QuietUninstallString = "$uninst -Quiet" }
    foreach ($k in $strings.Keys) { New-ItemProperty -Path $key -Name $k -Value $strings[$k] -PropertyType String -Force | Out-Null }
    foreach ($k in 'NoModify', 'NoRepair') { New-ItemProperty -Path $key -Name $k -Value 1 -PropertyType DWord -Force | Out-Null }
    New-ItemProperty -Path $key -Name 'EstimatedSize' -Value $sizeKb -PropertyType DWord -Force | Out-Null

    # chạy cùng Windows
    $startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'Device Widget.lnk'
    $wantAutostart = if ($Quiet) { [bool]$Autostart -or (Test-Path $startup) }
                     elseif (Test-Path $startup) { $true }
                     else {
                         (Show-Msg ("Đã cài xong Device Widget.`n`nBật ""Chạy cùng Windows"" để phím tắt Ctrl + Alt + D " +
                                    "dùng được ngay mỗi khi mở máy?") 'YesNo' 'Question') -eq 'Yes'
                     }
    if ($wantAutostart) { New-AppShortcut $startup $true }

    # mở ứng dụng
    if ($useExe) { Start-Process $exe }
    else { Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $dest 'Start-Widget.vbs') + '"') }
    Show-Msg ("Device Widget đã sẵn sàng!`n`n" +
              "•  Bấm Ctrl + Alt + D ở bất kỳ đâu để hiện / ẩn widget.`n" +
              "•  Biểu tượng ở khay hệ thống: bấm phải để đổi phím tắt hoặc thoát.`n" +
              "•  Gỡ cài đặt: Settings > Apps > Device Widget.") | Out-Null
} catch {
    Show-Msg "Cài đặt không thành công:`n$($_.Exception.Message)" 'OK' 'Error' | Out-Null
    if ($Quiet) { throw }
    exit 1
}
