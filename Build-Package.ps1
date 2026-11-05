# Đóng gói Device Widget để mang sang máy khác:
#   dist\DeviceWidget-Setup.exe  - 1 file, nhấp đúp là cài (tạo bằng IExpress có sẵn trong Windows)
#   dist\DeviceWidget.zip        - dự phòng khi máy kia chặn .exe: giải nén rồi chạy Install.cmd
# Chạy:  powershell -ExecutionPolicy Bypass -File Build-Package.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $root 'dist'
$files = 'DeviceWidget.ps1', 'DeviceStatus.cs', 'Start-Widget.vbs', 'Launcher.cs', 'Install.ps1', 'Install.cmd', 'Uninstall.ps1', 'HUONG-DAN.txt'

foreach ($f in $files) { if (-not (Test-Path (Join-Path $root $f))) { throw "Thiếu tệp $f" } }
New-Item -ItemType Directory -Force $dist | Out-Null

# thư mục tạm chỉ chứa đúng các tệp cần đóng gói
$stage = Join-Path $env:TEMP ("DeviceWidget-build-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $stage | Out-Null
foreach ($f in $files) { Copy-Item (Join-Path $root $f) (Join-Path $stage $f) }

try {
    # ---------- ZIP
    $zip = Join-Path $dist 'DeviceWidget.zip'
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
    Write-Host "Đã tạo $zip"

    # ---------- EXE (IExpress)
    # IExpress không chịu được đường dẫn dài, nên tạo trong thư mục tạm rồi mới chép sang dist
    $final = Join-Path $dist 'DeviceWidget-Setup.exe'
    if (Test-Path $final) { Remove-Item $final -Force }
    $exe = Join-Path $stage 'DeviceWidget-Setup.exe'
    $sed = Join-Path $stage 'package.sed'
    $fileLines = for ($i = 0; $i -lt $files.Count; $i++) { "FILE$i=""$($files[$i])""" }
    $srcLines = for ($i = 0; $i -lt $files.Count; $i++) { "%FILE$i%=" }
    @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exe
FriendlyName=Device Widget
AppLaunched=cmd /c Install.cmd
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($fileLines -join "`r`n")
[SourceFiles]
SourceFiles0=$stage\
[SourceFiles0]
$($srcLines -join "`r`n")
"@ | Set-Content -Path $sed -Encoding Default

    $p = Start-Process (Join-Path $env:WINDIR 'System32\iexpress.exe') -ArgumentList '/N', '/Q', $sed -WorkingDirectory $stage -Wait -PassThru
    if (-not (Test-Path $exe)) { throw "IExpress không tạo được tệp (mã thoát $($p.ExitCode))." }
    Copy-Item $exe $final -Force
    Write-Host "Đã tạo $final"

    # ---------- ZIP hoàn chỉnh để mang sang máy khác:
    #   Device Widget <phiên bản>\DeviceWidget-Setup.exe
    #   Device Widget <phiên bản>\HUONG-DAN.txt
    #   Device Widget <phiên bản>\Cai-thu-cong\...  (dự phòng khi máy chặn .exe: chạy Install.cmd)
    $ver = if ((Get-Content (Join-Path $root 'Install.ps1') -Raw) -match "\`$AppVersion\s*=\s*'([^']+)'") { $Matches[1] } else { '0' }
    $bundleName = "Device Widget $ver"
    $bundle = Join-Path $stage "bundle\$bundleName"
    $manual = Join-Path $bundle 'Cai-thu-cong'
    New-Item -ItemType Directory -Force $manual | Out-Null
    Copy-Item $exe (Join-Path $bundle 'DeviceWidget-Setup.exe')
    Copy-Item (Join-Path $root 'HUONG-DAN.txt') (Join-Path $bundle 'HUONG-DAN.txt')
    foreach ($f in $files) { if ($f -ne 'HUONG-DAN.txt') { Copy-Item (Join-Path $root $f) (Join-Path $manual $f) } }
    $full = Join-Path $dist "DeviceWidget-$ver.zip"
    if (Test-Path $full) { Remove-Item $full -Force }
    Compress-Archive -Path $bundle -DestinationPath $full
    Write-Host "Đã tạo $full"
} finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
