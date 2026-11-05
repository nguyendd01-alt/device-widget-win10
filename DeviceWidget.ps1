# Device Widget: ứng dụng chạy nền, bấm phím tắt (mặc định Ctrl + Alt + D) để hiện / ẩn.
# Gồm Wi-Fi, Bluetooth, tai nghe / chuột / bàn phím, mic, loa, camera, thanh độ sáng + âm lượng,
# trình phát nhạc và tốc độ mạng.
# Chạy: nhấp đúp Start-Widget.vbs, hoặc mở "Device Widget" trong Start Menu sau khi cài.
param(
    [switch]$Hidden,            # khởi động ẩn (chỉ hiện biểu tượng ở khay) - dùng khi chạy cùng Windows
    [switch]$WriteIcon,         # tạo app.ico rồi thoát (dùng khi cài đặt)
    [string]$Snapshot,          # chỉ để kiểm tra: lưu ảnh PNG của widget rồi thoát
    [ValidateSet('', 'light', 'dark')][string]$Theme = '',
    [string]$Panel = '',        # chỉ để kiểm tra: mở sẵn một bảng (wifi, bluetooth, hotkey, ...)
    [switch]$GlassTest          # chỉ để kiểm tra: dùng giao diện Liquid Glass cho ảnh chụp
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ============================================================ biểu tượng ứng dụng
function New-IconBitmap([int]$size) {
    $bmp = New-Object Drawing.Bitmap $size, $size
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = 'AntiAlias'
    $gfx.TextRenderingHint = 'AntiAlias'
    $rad = [math]::Max(2, [int]($size * 0.23))
    $edge = $size - 1
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 2 * $rad, 2 * $rad, 180, 90)
    $path.AddArc($edge - 2 * $rad, 0, 2 * $rad, 2 * $rad, 270, 90)
    $path.AddArc($edge - 2 * $rad, $edge - 2 * $rad, 2 * $rad, 2 * $rad, 0, 90)
    $path.AddArc(0, $edge - 2 * $rad, 2 * $rad, 2 * $rad, 90, 90)
    $path.CloseFigure()
    $p1 = New-Object Drawing.PointF 0, 0
    $p2 = New-Object Drawing.PointF $size, $size
    $c1 = [Drawing.Color]::FromArgb(255, 10, 132, 255)
    $c2 = [Drawing.Color]::FromArgb(255, 94, 92, 230)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush -ArgumentList $p1, $p2, $c1, $c2
    $gfx.FillPath($brush, $path)
    $font = New-Object Drawing.Font -ArgumentList 'Segoe MDL2 Assets', ([float]($size * 0.56)), ([Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $rect = New-Object Drawing.RectangleF 0, ([float]($size * 0.03)), $size, $size
    $gfx.DrawString([string][char]0xE772, $font, [Drawing.Brushes]::White, $rect, $fmt)
    $gfx.Dispose(); $brush.Dispose(); $font.Dispose()
    $bmp
}

function Write-AppIcon([string]$path) {
    # tệp .ico chứa ảnh PNG ở nhiều kích thước (Windows Vista trở lên đọc được)
    $sizes = @(16, 24, 32, 48, 256)
    $pngs = @()
    foreach ($sz in $sizes) {
        $bmp = New-IconBitmap $sz
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        $pngs += , $ms.ToArray()
    }
    $fs = [IO.File]::Create($path)
    $bw = New-Object IO.BinaryWriter $fs
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($png in $pngs) { $bw.Write([byte[]]$png) }
    $bw.Close()
}

if ($WriteIcon) { Write-AppIcon (Join-Path $here 'app.ico'); return }

# ============================================================ chỉ chạy 1 bản
# Mở lại lần nữa (Start Menu, nhấp đúp) thì bản đang chạy sẽ hiện lên.
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\DeviceStatusWidget', [ref]$createdNew)
$showEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\DeviceStatusWidget.Show')
$exitEvt = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\DeviceStatusWidget.Exit')
if (-not $createdNew -and -not $Snapshot) {
    if (-not $Hidden) { [void]$showEvt.Set() }
    return
}

# ============================================================ biên dịch phần lõi
function Import-Backend {
    $src = Join-Path $here 'DeviceStatus.cs'
    $hash = (Get-FileHash $src -Algorithm SHA1).Hash.Substring(0, 12)
    $binDir = Join-Path $env:LOCALAPPDATA 'DeviceWidget\bin'
    $dll = Join-Path $binDir "DeviceStatus-$hash.dll"
    if (-not (Test-Path $dll)) {
        New-Item -ItemType Directory -Force $binDir | Out-Null
        $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
        if (-not (Test-Path "$fw\csc.exe")) { $fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319' }
        $wm = Join-Path $env:WINDIR 'System32\WinMetadata'
        $refs = @('Foundation', 'Devices', 'Media', 'Networking', 'Security', 'Storage' | ForEach-Object { "/r:$wm\Windows.$_.winmd" })
        $refs += "/r:$fw\System.Runtime.dll", "/r:$fw\System.Threading.Tasks.dll", '/r:System.Management.dll', '/r:System.Core.dll',
                 "/r:$fw\WPF\PresentationCore.dll", "/r:$fw\WPF\WindowsBase.dll", "/r:$fw\System.Xaml.dll"
        $out = & "$fw\csc.exe" /nologo /optimize+ /target:library "/out:$dll" @refs $src
        if ($LASTEXITCODE -ne 0) { throw "Không biên dịch được DeviceStatus.cs:`n$($out -join "`n")" }
        Get-ChildItem $binDir -Filter 'DeviceStatus-*.dll' | Where-Object { $_.FullName -ne $dll } |
            ForEach-Object { try { Remove-Item $_.FullName -ErrorAction Stop } catch {} }
    }
    Add-Type -Path $dll
}

try { Import-Backend }
catch { [Windows.MessageBox]::Show($_.Exception.Message, 'Device Widget') | Out-Null; return }

# ============================================================ cài đặt
$cfgDir  = Join-Path $env:APPDATA 'DeviceWidget'
$cfgPath = Join-Path $cfgDir 'settings.json'
$logPath = Join-Path $cfgDir 'error.log'
$cfg = @{ Left = $null; Top = $null; Topmost = $false; AutoHide = $true; ShowSliders = $true; ShowMusic = $true
          DesktopMode = $false               # true = luôn hiện trên màn hình desktop (như gadget)
          Glass = $false                     # true = giao diện Liquid Glass (kính mờ)
          Tiles = $null                      # danh sách ô biểu tượng theo thứ tự; $null = mặc định
          HotMods = 3; HotKey = 0x44 }       # 3 = Ctrl + Alt, 0x44 = phím D
if (Test-Path $cfgPath) {
    try { (Get-Content $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch {}
}
function Save-Config {
    if ($Snapshot) { return }
    try {
        New-Item -ItemType Directory -Force $cfgDir | Out-Null
        ($cfg | ConvertTo-Json) | Set-Content -Path $cfgPath -Encoding UTF8
    } catch {}
}
function Write-Log($msg) {
    try { New-Item -ItemType Directory -Force $cfgDir | Out-Null; "$(Get-Date -Format s) $msg" | Add-Content -Path $logPath -Encoding UTF8 } catch {}
}
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Device Widget.lnk'

# ============================================================ màu sắc
$isLight = $true
try { $isLight = (Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme') -ne 0 } catch {}
if ($Theme) { $isLight = $Theme -eq 'light' }
$isGlass = [bool]$cfg.Glass -or [bool]$GlassTest
$T = if ($isGlass -and $isLight) {
    # Liquid Glass sáng: thẻ trắng trong suốt trên nền kính mờ
    @{ Bg = '#80F5F3FA'; Card = '#52FFFFFF'; Text = '#1C1C1E'; Sub = '#4F4C57'; Track = '#26000000'; Line = '#40FFFFFF'
       Hover = '#4DFFFFFF'; Fill = '#F2FFFFFF'; FillIcon = '#8E8B93'; Btn = '#4DFFFFFF'; BtnHover = '#80FFFFFF'; Input = '#CCFFFFFF' }
} elseif ($isGlass) {
    # Liquid Glass tối
    @{ Bg = '#A61C1C1E'; Card = '#1AFFFFFF'; Text = '#FFFFFF'; Sub = '#C0C0C8'; Track = '#33FFFFFF'; Line = '#26FFFFFF'
       Hover = '#26FFFFFF'; Fill = '#E6FFFFFF'; FillIcon = '#6E6E73'; Btn = '#26FFFFFF'; BtnHover = '#40FFFFFF'; Input = '#661C1C1E' }
} elseif ($isLight) {
    @{ Bg = '#E9E7EE'; Card = '#F7F6F9'; Text = '#1C1C1E'; Sub = '#85828B'; Track = '#DDDAE2'; Line = '#E6E3EA'
       Hover = '#ECEAF0'; Fill = '#FFFFFF'; FillIcon = '#8E8B93'; Btn = '#E4E1E8'; BtnHover = '#D8D5DD'; Input = '#FFFFFF' }
} else {
    @{ Bg = '#1C1C1E'; Card = '#2C2C2E'; Text = '#FFFFFF'; Sub = '#98989F'; Track = '#3A3A3C'; Line = '#3A3A3C'
       Hover = '#363638'; Fill = '#E5E5EA'; FillIcon = '#6E6E73'; Btn = '#3A3A3C'; BtnHover = '#48484A'; Input = '#1C1C1E' }
}
# các brush dùng chung cho thẻ / nền / lớp bóng (khác nhau giữa giao diện thường và Liquid Glass)
$GlassRes = if ($isGlass -and $isLight) { @'
    <SolidColorBrush x:Key="CardBg" Color="#52FFFFFF"/>
    <LinearGradientBrush x:Key="CardRim" StartPoint="0,0" EndPoint="0.3,1">
      <GradientStop Color="#E6FFFFFF" Offset="0"/><GradientStop Color="#26FFFFFF" Offset="0.5"/><GradientStop Color="#80FFFFFF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="RootBg" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#8CF7F5FC" Offset="0"/><GradientStop Color="#59E2DFEA" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="SheenBrush" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#66FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.32"/>
    </LinearGradientBrush>
'@ } elseif ($isGlass) { @'
    <SolidColorBrush x:Key="CardBg" Color="#1AFFFFFF"/>
    <LinearGradientBrush x:Key="CardRim" StartPoint="0,0" EndPoint="0.3,1">
      <GradientStop Color="#73FFFFFF" Offset="0"/><GradientStop Color="#14FFFFFF" Offset="0.5"/><GradientStop Color="#40FFFFFF" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="RootBg" StartPoint="0,0" EndPoint="1,1">
      <GradientStop Color="#B31C1C20" Offset="0"/><GradientStop Color="#8C2A2A30" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="SheenBrush" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#2EFFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="0.32"/>
    </LinearGradientBrush>
'@ } else { @"
    <SolidColorBrush x:Key="CardBg" Color="$($T.Card)"/>
    <SolidColorBrush x:Key="CardRim" Color="Transparent"/>
    <SolidColorBrush x:Key="RootBg" Color="$($T.Bg)"/>
    <SolidColorBrush x:Key="SheenBrush" Color="Transparent"/>
"@ }
$Green = '#34C759'; $Orange = '#FF9500'; $Red = '#FF3B30'; $Blue = '#0A84FF'

$brushCache = @{}
function B([string]$hex) {
    if (-not $brushCache.ContainsKey($hex)) {
        $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
        $b.Freeze(); $brushCache[$hex] = $b
    }
    $brushCache[$hex]
}

# Biểu tượng Segoe MDL2 Assets (có sẵn trên Windows 10)
$G = @{
    keyboard = 0xE765; mouse = 0xE962; headphones = 0xE7F6; phone = 0xE8EA; other = 0xE702; bluetooth = 0xE702
    mic = 0xE720; micOff = 0xEC54; speaker = 0xE767; speakerOff = 0xE74F; camera = 0xE714
    wifi = 0xE701; wifi1 = 0xE872; wifi2 = 0xE873; wifi3 = 0xE874; ethernet = 0xE839
    monitor = 0xE7F4; sun = 0xE706; output = 0xE7F5; music = 0xE8D6
    play = 0xE768; pause = 0xE769; next = 0xE893; prev = 0xE892
    refresh = 0xE72C; check = 0xE73E; chevron = 0xE76C; add = 0xE710; settings = 0xE713; usb = 0xE88E
    hide = 0xE921; keys = 0xE92E; pin = 0xE718; unpin = 0xE77A
}
$KindLabel = @{ keyboard = 'Bàn phím'; mouse = 'Chuột'; headphones = 'Tai nghe'; phone = 'Điện thoại'; other = 'Bluetooth' }

# ============================================================ ứng dụng WPF
$app = [Windows.Application]::Current
if (-not $app) { $app = New-Object Windows.Application }
$app.ShutdownMode = 'OnExplicitShutdown'

# ============================================================ giao diện (XAML)
$btnTemplate = @'
<ControlTemplate TargetType="Button">
  <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="RADIUS" Padding="{TemplateBinding Padding}">
    <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="HOVER"/></Trigger>
    <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@
$flatTpl  = $btnTemplate.Replace('RADIUS', '12').Replace('HOVER', $T.Hover)
$roundTpl = $btnTemplate.Replace('RADIUS', '20').Replace('HOVER', $T.BtnHover)

$xamlText = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Device Widget" Width="404" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        ShowInTaskbar="False" FontFamily="Segoe UI" UseLayoutRounding="True" Foreground="$($T.Text)">
  <Window.Resources>
$GlassRes
    <Style x:Key="Flat" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="$($T.Text)"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>$flatTpl</Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Round" TargetType="Button">
      <Setter Property="Background" Value="$($T.Btn)"/>
      <Setter Property="Foreground" Value="$($T.Text)"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>$roundTpl</Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="$($T.Text)"/></Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border CornerRadius="3" Background="$($T.Sub)" Opacity="0.45"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Margin="12" CornerRadius="24" Background="{StaticResource RootBg}" Padding="12"
          BorderBrush="{StaticResource CardRim}" BorderThickness="CARDBT">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.28"/></Border.Effect>
    <Grid>
    <!-- lớp phản sáng phía trên (chỉ thấy ở giao diện Liquid Glass) -->
    <Border x:Name="Sheen" Margin="-11,-11,-11,0" CornerRadius="23,23,0,0" Height="150" VerticalAlignment="Top"
            Background="{StaticResource SheenBrush}" IsHitTestVisible="False"/>
    <ScrollViewer x:Name="OuterScroll" VerticalScrollBarVisibility="Auto">
    <StackPanel>
      <!-- tiêu đề + tốc độ mạng + nút ghim desktop + nút ẩn -->
      <Grid Margin="6,0,0,10">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Text="Thiết bị" FontSize="15" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center"
                    Margin="0,0,4,0" ToolTip="Tốc độ mạng hiện tại (tải xuống / tải lên)">
          <TextBlock Text="↓" Foreground="$Green" FontWeight="Bold" FontSize="12" Margin="0,0,3,0"/>
          <TextBlock x:Name="SpeedDown" FontSize="12" Width="70" Text="0 KB/s"/>
          <TextBlock Text="↑" Foreground="$Blue" FontWeight="Bold" FontSize="12" Margin="0,0,3,0"/>
          <TextBlock x:Name="SpeedUp" FontSize="12" Width="64" Text="0 KB/s"/>
        </StackPanel>
        <Button x:Name="EditBtn" Grid.Column="2" Style="{StaticResource Flat}" Width="28" Height="28"
                HorizontalContentAlignment="Center" ToolTip="Tuỳ chỉnh biểu tượng: thêm, bớt, sắp xếp">
          <TextBlock Text="&#xE70F;" FontFamily="Segoe MDL2 Assets" FontSize="12" HorizontalAlignment="Center"/>
        </Button>
        <Button x:Name="PinBtn" Grid.Column="3" Style="{StaticResource Flat}" Width="28" Height="28"
                HorizontalContentAlignment="Center">
          <TextBlock x:Name="PinGlyph" Text="&#xE718;" FontFamily="Segoe MDL2 Assets" FontSize="12" HorizontalAlignment="Center"/>
        </Button>
        <Button x:Name="HideBtn" Grid.Column="4" Style="{StaticResource Flat}" Width="28" Height="28"
                HorizontalContentAlignment="Center">
          <TextBlock Text="&#xE921;" FontFamily="Segoe MDL2 Assets" FontSize="11" HorizontalAlignment="Center"/>
        </Button>
      </Grid>

      <!-- các vòng biểu tượng (luôn hiện) -->
      <Border CornerRadius="18" Background="$($T.Card)" Padding="4,8,4,4">
        <UniformGrid x:Name="Rings" Columns="4"/>
      </Border>

      <!-- bảng tuỳ chỉnh khi bấm vào một biểu tượng -->
      <Border x:Name="PanelCard" CornerRadius="18" Background="$($T.Card)" Margin="0,10,0,0" Padding="8,8,8,8" Visibility="Collapsed">
        <StackPanel>
          <Grid Margin="8,2,0,6">
            <TextBlock x:Name="PanelTitle" FontSize="14" FontWeight="SemiBold" VerticalAlignment="Center"/>
            <StackPanel x:Name="PanelTools" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <ScrollViewer MaxHeight="320" VerticalScrollBarVisibility="Auto">
            <StackPanel x:Name="PanelBody"/>
          </ScrollViewer>
        </StackPanel>
      </Border>

      <!-- thanh trượt -->
      <StackPanel x:Name="SliderArea">
        <Border CornerRadius="18" Background="$($T.Card)" Margin="0,10,0,0" Padding="14,10,10,12">
          <StackPanel>
            <Grid Margin="2,0,0,8">
              <TextBlock Text="Màn hình" FontSize="14" FontWeight="SemiBold"/>
              <TextBlock x:Name="BriVal" HorizontalAlignment="Right" Margin="0,0,54,0" FontSize="12" Foreground="$($T.Sub)"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid x:Name="BriHost"/>
              <Button x:Name="DisplayBtn" Grid.Column="1" Style="{StaticResource Round}" Width="40" Height="40" Margin="12,0,0,0"
                      ToolTip="Cài đặt màn hình">
                <TextBlock Text="&#xE7F4;" FontFamily="Segoe MDL2 Assets" FontSize="16"/>
              </Button>
            </Grid>
            <TextBlock x:Name="BriNote" Visibility="Collapsed" Margin="2,6,0,0" FontSize="11" Foreground="$($T.Sub)"
                       Text="Màn hình này không cho chỉnh độ sáng từ máy tính (cần bật DDC/CI trong menu màn hình)."
                       TextWrapping="Wrap"/>
          </StackPanel>
        </Border>
        <Border CornerRadius="18" Background="$($T.Card)" Margin="0,10,0,0" Padding="14,10,10,12">
          <StackPanel>
            <Grid Margin="2,0,0,8">
              <TextBlock Text="Âm thanh" FontSize="14" FontWeight="SemiBold"/>
              <TextBlock x:Name="VolVal" HorizontalAlignment="Right" Margin="0,0,54,0" FontSize="12" Foreground="$($T.Sub)"/>
            </Grid>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Grid x:Name="VolHost"/>
              <Button x:Name="OutputBtn" Grid.Column="1" Style="{StaticResource Round}" Width="40" Height="40" Margin="12,0,0,0"
                      ToolTip="Chọn loa / tai nghe phát ra">
                <TextBlock Text="&#xE7F5;" FontFamily="Segoe MDL2 Assets" FontSize="16"/>
              </Button>
            </Grid>
          </StackPanel>
        </Border>
      </StackPanel>

      <!-- trình phát nhạc -->
      <Border x:Name="MusicCard" CornerRadius="18" Background="$($T.Card)" Margin="0,10,0,0" Padding="10">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="Art" Width="58" Height="58" CornerRadius="10" Background="$($T.Btn)">
            <Border x:Name="ArtBadge" Width="30" Height="30" CornerRadius="8" Background="#FF2D55">
              <TextBlock Text="&#xE8D6;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="White"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </Border>
          <StackPanel Grid.Column="1" Margin="14,0,8,0" VerticalAlignment="Center">
            <TextBlock x:Name="MTitle" FontSize="14" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="MSub" FontSize="12" Foreground="$($T.Sub)" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="PrevBtn" Style="{StaticResource Flat}" Width="34" Height="34" HorizontalContentAlignment="Center" ToolTip="Bài trước">
              <TextBlock Text="&#xE892;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="$($T.Sub)"/>
            </Button>
            <Button x:Name="PlayBtn" Style="{StaticResource Flat}" Width="38" Height="38" HorizontalContentAlignment="Center" ToolTip="Phát / tạm dừng">
              <TextBlock x:Name="PlayGlyph" Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="20"/>
            </Button>
            <Button x:Name="NextBtn" Style="{StaticResource Flat}" Width="34" Height="34" HorizontalContentAlignment="Center" ToolTip="Bài tiếp">
              <TextBlock Text="&#xE893;" FontFamily="Segoe MDL2 Assets" FontSize="14" Foreground="$($T.Sub)"/>
            </Button>
          </StackPanel>
        </Grid>
      </Border>
    </StackPanel>
    </ScrollViewer>
    </Grid>
  </Border>
</Window>
"@
# thẻ dùng brush chung (để Liquid Glass có viền phản sáng)
$xamlText = $xamlText.Replace("Background=`"$($T.Card)`"",
    'Background="{StaticResource CardBg}" BorderBrush="{StaticResource CardRim}" BorderThickness="CARDBT"')
$xamlText = $xamlText.Replace('CARDBT', $(if ($isGlass) { '1' } else { '0' }))
if ($isGlass) {
    # kính mờ: Windows làm mờ phần phía sau cửa sổ, nên bỏ lề + bóng đổ (vùng mờ được bo góc theo widget)
    $xamlText = $xamlText.Replace('<Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.28"/></Border.Effect>', '')
    $xamlText = $xamlText.Replace('x:Name="Root" Margin="12"', 'x:Name="Root" Margin="0"')
    $xamlText = $xamlText.Replace('Title="Device Widget" Width="404"', 'Title="Device Widget" Width="380"')
}
[xml]$xaml = $xamlText
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'Rings', 'PanelCard', 'PanelTitle', 'PanelTools', 'PanelBody', 'SliderArea', 'BriHost', 'BriVal', 'BriNote',
               'VolHost', 'VolVal', 'DisplayBtn', 'OutputBtn', 'MusicCard', 'Art', 'ArtBadge', 'MTitle', 'MSub',
               'PrevBtn', 'PlayBtn', 'NextBtn', 'PlayGlyph', 'SpeedDown', 'SpeedUp', 'HideBtn', 'PinBtn', 'PinGlyph', 'EditBtn', 'Root', 'Sheen') {
    Set-Variable -Name $n -Value $win.FindName($n)
}
$FlatStyle = $win.Resources['Flat']
$RoundStyle = $win.Resources['Round']

# ============================================================ khối dựng giao diện
function New-Text($text, $size, $color, $weight = 'Normal') {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = $size; $tb.Foreground = B $color; $tb.FontWeight = $weight
    $tb
}
function New-Icon($glyph, $size, $color) {
    $tb = New-Text ([string][char]$glyph) $size $color
    $tb.FontFamily = 'Segoe MDL2 Assets'
    $tb
}
function New-Cols([string[]]$widths) {
    $grid = New-Object Windows.Controls.Grid
    $conv = New-Object Windows.GridLengthConverter
    foreach ($w in $widths) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = $conv.ConvertFromString($w)
        [void]$grid.ColumnDefinitions.Add($cd)
    }
    $grid
}

# ---------- vòng tròn (các ô biểu tượng: thêm / bớt / sắp xếp được)
$Thick = 5
$script:RingBtn = @{}
$script:R = @{}

# tất cả các loại ô có thể chọn, theo thứ tự mặc định
$TileDefs = [ordered]@{
    wifi       = @{ Glyph = 0xE701; Label = 'Wi-Fi' }
    lan        = @{ Glyph = 0xE839; Label = 'Mạng LAN' }
    bluetooth  = @{ Glyph = 0xE702; Label = 'Bluetooth' }
    headphones = @{ Glyph = 0xE7F6; Label = 'Tai nghe' }
    mouse      = @{ Glyph = 0xE962; Label = 'Chuột' }
    keyboard   = @{ Glyph = 0xE765; Label = 'Bàn phím' }
    mic        = @{ Glyph = 0xE720; Label = 'Micro' }
    speaker    = @{ Glyph = 0xE767; Label = 'Loa' }
    camera     = @{ Glyph = 0xE714; Label = 'Camera' }
    cpu        = @{ Glyph = 0xE950; Label = 'CPU' }
    ram        = @{ Glyph = 0xE964; Label = 'RAM' }
    disk       = @{ Glyph = 0xEDA2; Label = 'Ổ đĩa' }
    battery    = @{ Glyph = 0xEBA7; Label = 'Pin' }
}
$DefaultTiles = @('wifi', 'lan', 'bluetooth', 'headphones', 'mouse', 'keyboard', 'mic', 'speaker', 'camera')
function Get-Tiles {
    $list = @($cfg.Tiles | Where-Object { $TileDefs.Contains([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($list.Count -eq 0) { $list = $DefaultTiles }
    , $list
}
# chọn số cột cho gọn: ít hàng nhất, rồi ít ô trống nhất (ưu tiên 4 cột)
function Get-TileColumns([int]$n) {
    if ($n -le 5) { return [math]::Max(1, $n) }
    $best = 4; $bestScore = 1e9
    foreach ($c in 4, 5, 3) {
        $rows = [math]::Ceiling($n / $c); $empty = $rows * $c - $n
        $score = $rows * 100 + $empty
        if ($score -lt $bestScore) { $best = $c; $bestScore = $score }
    }
    $best
}

function New-Ring($key, $glyph, $label, [int]$size, [double]$maxText) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Padding = '0,6,0,5'; $btn.Margin = '2'; $btn.Tag = $key
    $btn.HorizontalContentAlignment = 'Center'
    $btn.ToolTip = "$label - bấm để tuỳ chỉnh"
    $sp = New-Object Windows.Controls.StackPanel
    $ringGrid = New-Object Windows.Controls.Grid
    $ringGrid.Width = $size; $ringGrid.Height = $size
    $track = New-Object Windows.Shapes.Ellipse
    $track.StrokeThickness = $Thick; $track.Stroke = B $T.Track
    $prog = New-Object Windows.Shapes.Ellipse
    $prog.StrokeThickness = $Thick; $prog.StrokeDashCap = 'Round'
    $prog.RenderTransformOrigin = '0.5,0.5'
    $prog.RenderTransform = New-Object Windows.Media.RotateTransform(-90)
    $icon = New-Icon $glyph $(if ($size -lt 54) { 18 } else { 20 }) $T.Text
    $icon.HorizontalAlignment = 'Center'; $icon.VerticalAlignment = 'Center'
    [void]$ringGrid.Children.Add($track); [void]$ringGrid.Children.Add($prog); [void]$ringGrid.Children.Add($icon)
    $val = New-Text '…' 12 $T.Sub 'SemiBold'
    $val.HorizontalAlignment = 'Center'; $val.Margin = '0,6,0,0'; $val.MaxWidth = $maxText; $val.TextTrimming = 'CharacterEllipsis'
    $lab = New-Text $label 11 $T.Sub
    $lab.HorizontalAlignment = 'Center'; $lab.MaxWidth = $maxText; $lab.TextTrimming = 'CharacterEllipsis'
    [void]$sp.Children.Add($ringGrid); [void]$sp.Children.Add($val); [void]$sp.Children.Add($lab)
    $btn.Content = $sp
    $btn.Add_Click({ Switch-Panel $this.Tag })
    [void]$Rings.Children.Add($btn)
    $script:RingBtn[$key] = $btn
    @{ Prog = $prog; Icon = $icon; Value = $val; Last = $null; Circ = [math]::PI * ($size - $Thick) }
}

# dựng lại toàn bộ các ô theo cấu hình (gọi lúc khởi động và sau khi tuỳ chỉnh)
function Build-Rings {
    $tiles = Get-Tiles
    $cols = Get-TileColumns $tiles.Count
    $Rings.Children.Clear()
    $Rings.Columns = $cols
    $script:R = @{}
    $script:RingBtn = @{}
    $cell = 344.0 / $cols - 4
    $size = if ($cols -ge 5) { 48 } else { 54 }
    foreach ($k in $tiles) {
        $def = $TileDefs[$k]
        $script:R[$k] = New-Ring $k $def.Glyph $def.Label $size ([math]::Max(50, $cell - 4))
    }
    if ($script:panelKey -and $script:RingBtn.ContainsKey($script:panelKey)) { $script:RingBtn[$script:panelKey].Background = B $T.Hover }
}

function Set-Ring($ring, [double]$frac, [string]$color, [string]$text, [string]$textColor, $glyph = $null) {
    if (-not $ring) { return }   # ô này đang bị ẩn
    $key = "$frac|$color|$text|$textColor|$glyph"
    if ($ring.Last -eq $key) { return }   # không đổi thì không vẽ lại
    $ring.Last = $key
    if ($frac -le 0) { $ring.Prog.Visibility = 'Hidden' }
    else {
        $ring.Prog.Visibility = 'Visible'
        $dc = New-Object Windows.Media.DoubleCollection
        $dc.Add([math]::Min($frac, [double]1.0) * $ring.Circ / $Thick); $dc.Add(10000)
        $ring.Prog.StrokeDashArray = $dc
        $ring.Prog.Stroke = B $color
    }
    $ring.Value.Text = $text
    $ring.Value.Foreground = B $textColor
    $ring.Icon.Foreground = if ($frac -gt 0) { B $T.Text } else { B $T.Sub }
    if ($glyph) { $ring.Icon.Text = [string][char]$glyph }
}

$script:panelKey = $null
Build-Rings

# ---------- thanh trượt ngang
$SH = 32
function New-BarSlider($hostGrid, $glyph, [scriptblock]$onChange) {
    $sg = New-Object Windows.Controls.Grid
    $sg.Height = $SH; $sg.Background = B '#01000000'; $sg.Cursor = 'Hand'
    $track = New-Object Windows.Controls.Border
    $track.CornerRadius = $SH / 2; $track.Background = B $T.Track
    $fill = New-Object Windows.Controls.Border
    $fill.CornerRadius = $SH / 2; $fill.Background = B $T.Fill; $fill.HorizontalAlignment = 'Left'; $fill.Width = $SH
    $icon = New-Icon $glyph 13 $T.FillIcon
    $icon.HorizontalAlignment = 'Left'; $icon.VerticalAlignment = 'Center'; $icon.Margin = '10,0,0,0'
    $thumb = New-Object Windows.Shapes.Ellipse
    $thumb.Width = $SH; $thumb.Height = $SH; $thumb.Fill = B '#FFFFFF'; $thumb.HorizontalAlignment = 'Left'
    $thumb.Stroke = B $T.Line; $thumb.StrokeThickness = 0.5
    $shadow = New-Object Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 6; $shadow.ShadowDepth = 1; $shadow.Opacity = 0.25
    $thumb.Effect = $shadow
    [void]$sg.Children.Add($track); [void]$sg.Children.Add($fill); [void]$sg.Children.Add($icon); [void]$sg.Children.Add($thumb)
    $sl = @{ Grid = $sg; Fill = $fill; Thumb = $thumb; Icon = $icon; Value = 0.0; Dragging = $false; OnChange = $onChange; Enabled = $true; Drawn = $false }
    $sg.Tag = $sl
    $sg.Add_SizeChanged({ Update-SliderVisual $this.Tag })
    $sg.Add_MouseLeftButtonDown({
        param($sender, $e)
        $sl = $sender.Tag; $e.Handled = $true
        if (-not $sl.Enabled) { return }
        $sl.Dragging = $true; [void]$sender.CaptureMouse(); Set-SliderFromMouse $sl $e
    })
    $sg.Add_MouseMove({ param($sender, $e) $sl = $sender.Tag; if ($sl.Dragging) { Set-SliderFromMouse $sl $e } })
    $sg.Add_MouseLeftButtonUp({
        param($sender, $e)
        $sl = $sender.Tag; $e.Handled = $true
        if ($sl.Dragging) { $sl.Dragging = $false; $sender.ReleaseMouseCapture(); Set-SliderFromMouse $sl $e }
    })
    $sg.Add_MouseWheel({
        param($sender, $e)
        $sl = $sender.Tag; $e.Handled = $true
        if ($sl.Enabled) { Set-SliderValue $sl ($sl.Value + [math]::Sign($e.Delta) * 0.05) $true }
    })
    [void]$hostGrid.Children.Add($sg)
    $sl
}
function Update-SliderVisual($sl) {
    $w = $sl.Grid.ActualWidth
    if ($w -le 0) { return }
    $fw = $SH + $sl.Value * ($w - $SH)
    $sl.Fill.Width = $fw
    $sl.Thumb.Margin = New-Object Windows.Thickness(($fw - $SH), 0, 0, 0)
}
function Set-SliderValue($sl, [double]$v, [bool]$fire) {
    $v = [math]::Max([double]0.0, [math]::Min([double]1.0, $v))
    if (-not $fire -and $sl.Value -eq $v -and $sl.Drawn) { return }
    $sl.Value = $v
    $sl.Drawn = $sl.Grid.ActualWidth -gt 0
    Update-SliderVisual $sl
    if ($fire -and $sl.OnChange) { & $sl.OnChange $v }
}
function Set-SliderFromMouse($sl, $e) {
    $w = $sl.Grid.ActualWidth
    if ($w -le $SH) { return }
    $x = $e.GetPosition($sl.Grid).X
    Set-SliderValue $sl (($x - $SH / 2) / ($w - $SH)) $true
}
function Set-SliderEnabled($sl, [bool]$on) {
    $sl.Enabled = $on
    $sl.Grid.Opacity = if ($on) { 1 } else { 0.45 }
    $sl.Grid.Cursor = if ($on) { 'Hand' } else { 'Arrow' }
}

$BriSlider = New-BarSlider $BriHost $G.sun {
    param($v)
    $p = [int][math]::Round($v * 100)
    [DeviceWidget.Brightness]::Set($p)
    $BriVal.Text = "$p%"
}
$VolSlider = New-BarSlider $VolHost $G.speaker {
    param($v)
    $p = [int][math]::Round($v * 100)
    [DeviceWidget.Devices]::SetVolume($false, $p)
    $VolVal.Text = "$p%"
    if ($script:data.Spk) { $script:data.Spk.Volume = $p; if ($p -gt 0) { $script:data.Spk.Muted = $false } }
}

# ---------- dòng trong bảng tuỳ chỉnh
function New-PanelRow($glyph, $title, $sub, $right, $rightColor, $tag, [scriptblock]$onClick, $glyphColor = $null) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Padding = '8,7'; $btn.Tag = $tag
    $grid = New-Cols @('Auto', '*', 'Auto')
    $ic = New-Icon $glyph 16 $(if ($glyphColor) { $glyphColor } else { $T.Text })
    $ic.Width = 30; $ic.VerticalAlignment = 'Center'
    $mid = New-Object Windows.Controls.StackPanel
    $mid.VerticalAlignment = 'Center'
    $tt = New-Text $title 13 $T.Text; $tt.TextTrimming = 'CharacterEllipsis'
    [void]$mid.Children.Add($tt)
    if ($sub) {
        $st = New-Text $sub 11 $T.Sub; $st.TextTrimming = 'CharacterEllipsis'; $st.Margin = '0,1,0,0'
        [void]$mid.Children.Add($st)
    }
    [Windows.Controls.Grid]::SetColumn($mid, 1)
    [void]$grid.Children.Add($ic); [void]$grid.Children.Add($mid)
    if ($right) {
        $rt = New-Text $right 12 $(if ($rightColor) { $rightColor } else { $T.Sub }) 'SemiBold'
        $rt.VerticalAlignment = 'Center'; $rt.Margin = '8,0,2,0'
        if ($right.Length -eq 1 -and [int][char]$right -ge 0xE000) { $rt.FontFamily = 'Segoe MDL2 Assets'; $rt.FontWeight = 'Normal' }
        [Windows.Controls.Grid]::SetColumn($rt, 2)
        [void]$grid.Children.Add($rt)
    }
    $btn.Content = $grid
    if ($onClick) { $btn.Add_Click($onClick) } else { $btn.Cursor = 'Arrow' }
    [void]$PanelBody.Children.Add($btn)
    $btn
}
function Add-InfoRow($text, $color = $null) {
    $tb = New-Text $text 12 $(if ($color) { $color } else { $T.Sub })
    $tb.Margin = '10,6,10,6'; $tb.TextWrapping = 'Wrap'
    [void]$PanelBody.Children.Add($tb)
}
function Add-LinkRow($glyph, $text, $uri) {
    [void](New-PanelRow $glyph $text $null ([string][char]$G.chevron) $T.Sub $uri {
        try { Start-Process $this.Tag } catch { Start-Process 'ms-settings:' }
    } $T.Sub)
}
function Add-Separator {
    $sep = New-Object Windows.Controls.Border
    $sep.Height = 1; $sep.Background = B $T.Line; $sep.Margin = '10,4'
    [void]$PanelBody.Children.Add($sep)
}
function New-Toggle([bool]$on, $tag, [scriptblock]$onClick, $tip) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Padding = '4'; $btn.Tag = $tag; $btn.ToolTip = $tip
    $pill = New-Object Windows.Controls.Border
    $pill.Width = 40; $pill.Height = 24; $pill.CornerRadius = 12
    $pill.Background = if ($on) { B $Green } else { B $T.Track }
    $knob = New-Object Windows.Shapes.Ellipse
    $knob.Width = 20; $knob.Height = 20; $knob.Fill = B '#FFFFFF'; $knob.Margin = '2,0'
    $knob.HorizontalAlignment = if ($on) { 'Right' } else { 'Left' }
    $pill.Child = $knob
    $btn.Content = $pill
    $btn.Add_Click($onClick)
    [void]$PanelTools.Children.Add($btn)
}
function New-ToolButton($glyph, $tip, [scriptblock]$onClick) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Width = 30; $btn.Height = 30; $btn.ToolTip = $tip
    $btn.HorizontalContentAlignment = 'Center'
    $btn.Content = New-Icon $glyph 13 $T.Sub
    $btn.Add_Click($onClick)
    [void]$PanelTools.Children.Add($btn)
}

# ============================================================ việc chạy nền
$script:jobs = New-Object System.Collections.ArrayList
function Add-Job($task, [scriptblock]$done, $data = $null) {
    [void]$script:jobs.Add(@{ Task = $task; Done = $done; Data = $data })
}
function Invoke-Jobs {
    foreach ($j in @($script:jobs)) {
        if (-not $j.Task.IsCompleted) { continue }
        $script:jobs.Remove($j)
        try { if ($j.Done) { & $j.Done $j.Task $j.Data } } catch { Write-Log "job: $($_.Exception.Message)" }
    }
}

# trạng thái "đang kết nối…" / ghi chú tạm thời cho từng thiết bị hoặc mạng
$script:busy = @{}
$script:notes = @{}
function Set-Busy($name, $text, $want, $seconds) {
    $script:busy[$name] = @{ Text = $text; Want = $want; Until = (Get-Date).AddSeconds($seconds) }
}
function Clear-Busy($name) { $script:busy.Remove($name) }
function Get-Busy($name, $state = $null) {
    $bz = $script:busy[$name]
    if (-not $bz) { return $null }
    if ($null -ne $bz.Want -and $null -ne $state -and $state -eq $bz.Want) { $script:busy.Remove($name); return $null }
    if ((Get-Date) -gt $bz.Until) {
        $script:busy.Remove($name)
        if ($bz.Want -eq $true) { Set-Note $name 'Không kết nối được - hãy bật thiết bị và để gần máy' }
        elseif ($bz.Want -eq $false) { Set-Note $name 'Chưa ngắt được kết nối' }
        return $null
    }
    $bz.Text
}
function Set-Note($name, $text, $seconds = 8) { $script:notes[$name] = @{ Text = $text; Until = (Get-Date).AddSeconds($seconds) } }
function Get-Note($name) {
    $nt = $script:notes[$name]
    if (-not $nt) { return $null }
    if ((Get-Date) -gt $nt.Until) { $script:notes.Remove($name); return $null }
    $nt.Text
}

# ============================================================ dữ liệu thiết bị
$script:data = @{ Bt = @(); Usb = @(); Spk = $null; Mic = $null; MicUse = $null; CamUse = $null; Cams = @(); Disks = @() }

function Update-Devices {
    $d = $script:data
    $d.Bt = @([DeviceWidget.Devices]::GetBluetooth())
    $d.Usb = @([DeviceWidget.Devices]::GetUsbInputs())
    $d.Spk = [DeviceWidget.Devices]::GetDefaultAudio($false)
    $d.Mic = [DeviceWidget.Devices]::GetDefaultAudio($true)
    $d.MicUse = [DeviceWidget.Devices]::GetUsage('microphone')
    $d.CamUse = [DeviceWidget.Devices]::GetUsage('webcam')
    $d.Cams = @([DeviceWidget.Devices]::GetCameras())
    $d.Disks = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })
    Update-Rings
    if ($script:panelKey) { Show-PanelContent $false }
}

function Update-Rings {
    $d = $script:data
    foreach ($kind in 'keyboard', 'mouse', 'headphones') {
        $all = @($d.Bt | Where-Object { $_.Kind -eq $kind })
        $conn = @($all | Where-Object { $_.Connected })
        $usb = @($d.Usb | Where-Object { $_.Kind -eq $kind })
        if ($conn.Count -gt 0) {
            $x = $conn[0]
            if ($x.Battery -ge 0) {
                $c = if ($x.Battery -le 20) { $Orange } else { $Green }
                Set-Ring $R[$kind] ($x.Battery / 100) $c "$($x.Battery)%" $T.Text
            } else { Set-Ring $R[$kind] 1 $Green 'Đã nối' $T.Text }
        } elseif ($usb.Count -gt 0) {
            Set-Ring $R[$kind] 1 $Green 'USB / 2.4G' $T.Text
        } elseif ($all.Count -gt 0) {
            Set-Ring $R[$kind] 0 $T.Sub 'Chưa nối' $T.Sub
        } else {
            Set-Ring $R[$kind] 0 $T.Sub 'Chưa có' $T.Sub
        }
    }

    $mic = $d.Mic; $mu = $d.MicUse
    if (-not $mic.Present -and -not $mu.InUse) { Set-Ring $R.mic 0 $T.Sub 'Không có' $T.Sub $G.mic }
    elseif ($mu.InUse -and $mic.Muted) { Set-Ring $R.mic 1 $Red 'Tắt tiếng' $Red $G.micOff }
    elseif ($mu.InUse) { Set-Ring $R.mic 1 $Orange 'Đang bật' $Orange $G.mic }
    elseif ($mic.Muted) { Set-Ring $R.mic 0 $T.Sub 'Tắt tiếng' $T.Sub $G.micOff }
    else { Set-Ring $R.mic 0 $T.Sub 'Đang tắt' $T.Sub $G.mic }

    $spk = $d.Spk
    if (-not $spk.Present) { Set-Ring $R.speaker 0 $T.Sub 'Không có' $T.Sub $G.speaker }
    elseif ($spk.Muted -or $spk.Volume -eq 0) { Set-Ring $R.speaker 0 $T.Sub 'Tắt tiếng' $Red $G.speakerOff }
    else { Set-Ring $R.speaker ($spk.Volume / 100) $Green "$($spk.Volume)%" $T.Text $G.speaker }

    if ($d.CamUse.InUse) { Set-Ring $R.camera 1 $Green 'Đang bật' $Green }
    elseif ($d.Cams.Count -eq 0) { Set-Ring $R.camera 0 $T.Sub 'Không có' $T.Sub }
    else { Set-Ring $R.camera 0 $T.Sub 'Đang tắt' $T.Sub }

    # ổ đĩa hệ thống (C:)
    $sysDrive = $d.Disks | Where-Object { $_.Name -eq ($env:SystemDrive + '\') } | Select-Object -First 1
    if (-not $sysDrive) { $sysDrive = $d.Disks | Select-Object -First 1 }
    if ($sysDrive) {
        $used = 1 - $sysDrive.AvailableFreeSpace / $sysDrive.TotalSize
        $c = if ($used -ge 0.95) { $Red } elseif ($used -ge 0.85) { $Orange } else { $Green }
        Set-Ring $R.disk $used $c ('{0:0} GB trống' -f ($sysDrive.AvailableFreeSpace / 1GB)) $T.Text
    } else { Set-Ring $R.disk 0 $T.Sub 'Không có' $T.Sub }
}

function Format-LinkSpeed([long]$mbps) {
    if ($mbps -ge 1000) { '{0:0.#} Gbps' -f ($mbps / 1000) } elseif ($mbps -gt 0) { "$mbps Mbps" } else { '' }
}

# CPU / RAM / pin: đọc mỗi lần cập nhật (rất nhẹ)
$script:sys = $null
function Update-SysRings {
    $st = [DeviceWidget.SysInfo]::Sample()
    $script:sys = $st
    if ($st.Cpu -ge 0) {
        $c = if ($st.Cpu -ge 90) { $Red } elseif ($st.Cpu -ge 70) { $Orange } else { $Green }
        Set-Ring $R.cpu ([math]::Max(0.02, $st.Cpu / 100)) $c "$($st.Cpu)%" $T.Text
    }
    if ($st.RamPercent -ge 0) {
        $c = if ($st.RamPercent -ge 90) { $Red } elseif ($st.RamPercent -ge 75) { $Orange } else { $Green }
        Set-Ring $R.ram ($st.RamPercent / 100) $c "$($st.RamPercent)%" $T.Text
    }
    if ($st.HasBattery -and $st.Battery -ge 0) {
        $c = if ($st.Battery -le 20 -and -not $st.OnAc) { $Red } elseif ($st.Battery -le 40) { $Orange } else { $Green }
        Set-Ring $R.battery ($st.Battery / 100) $c "$($st.Battery)%$(if ($st.Charging) { ' ⚡' })" $T.Text
    } else {
        Set-Ring $R.battery 0 $T.Sub $(if ($st.OnAc) { 'Cắm điện' } else { 'Không có' }) $T.Sub
    }
}

function Update-NetRings {
    $ns = [DeviceWidget.Net]::State
    if (-not $ns.Ready) { return }
    if ($ns.HasWifi -and $ns.HasWifiRadio -and -not $ns.WifiOn) { Set-Ring $R.wifi 0 $T.Sub 'Đang tắt' $T.Sub $G.wifi }
    elseif ($ns.HasWifi -and $ns.Connected) {
        $glyph = switch ($ns.Bars) { 0 { $G.wifi1 } 1 { $G.wifi1 } 2 { $G.wifi2 } 3 { $G.wifi3 } default { $G.wifi } }
        Set-Ring $R.wifi 1 $Blue $ns.Ssid $T.Text $glyph
    }
    elseif ($ns.HasWifi) { Set-Ring $R.wifi 0 $T.Sub 'Chưa nối' $T.Sub $G.wifi }
    else { Set-Ring $R.wifi 0 $T.Sub 'Không có' $T.Sub $G.wifi }

    # mạng LAN (dây): tự hiện "đã kết nối" khi cắm dây mạng
    $up = @($ns.EthAdapters | Where-Object { $_.Up })
    if ($up.Count -gt 0) {
        $sp = Format-LinkSpeed $up[0].SpeedMbps
        Set-Ring $R.lan 1 $Blue $(if ($sp) { $sp } else { 'Đã kết nối' }) $T.Text
    } elseif (@($ns.EthAdapters).Count -gt 0) { Set-Ring $R.lan 0 $T.Sub 'Chưa cắm' $T.Sub }
    else { Set-Ring $R.lan 0 $T.Sub 'Không có' $T.Sub }

    $cnt = @($script:data.Bt | Where-Object { $_.Connected }).Count
    if (-not $ns.HasBt) { Set-Ring $R.bluetooth 0 $T.Sub 'Không có' $T.Sub }
    elseif ($ns.BtOn) { Set-Ring $R.bluetooth 1 $Blue $(if ($cnt -gt 0) { "$cnt thiết bị" } else { 'Đang bật' }) $T.Text }
    else { Set-Ring $R.bluetooth 0 $T.Sub 'Đang tắt' $T.Sub }
}

# ============================================================ phím tắt
$script:capturing = $false
$script:hotNote = $null
$script:hotNoteColor = $Blue

function Format-HotKey($mods, $vk) {
    $parts = @()
    if ($mods -band 2) { $parts += 'Ctrl' }
    if ($mods -band 1) { $parts += 'Alt' }
    if ($mods -band 4) { $parts += 'Shift' }
    if ($mods -band 8) { $parts += 'Win' }
    $k = [string][Windows.Input.KeyInterop]::KeyFromVirtualKey([int]$vk)
    $map = @{ Oem3 = '`'; OemMinus = '-'; OemPlus = '='; Return = 'Enter'; OemComma = ','; OemPeriod = '.'
              OemQuestion = '/'; Oem5 = '\'; Oem1 = ';'; OemQuotes = "'"; OemOpenBrackets = '['; Oem6 = ']' }
    if ($k -match '^D(\d)$') { $k = $Matches[1] }
    elseif ($map.ContainsKey($k)) { $k = $map[$k] }
    ($parts + $k) -join ' + '
}
function Register-HotKey {
    if ($Snapshot) { return $true }
    [DeviceWidget.HotKey]::Register([uint32]$cfg.HotMods, [uint32]$cfg.HotKey)
}
function Start-Capture {
    $script:capturing = $true
    if (-not $Snapshot) { [DeviceWidget.HotKey]::Unregister() }   # để bấm lại đúng tổ hợp cũ cũng bắt được
}
function End-Capture {
    if (-not $script:capturing) { return }
    $script:capturing = $false
    [void](Register-HotKey)
}
function Update-HotkeyLabels {
    $name = Format-HotKey $cfg.HotMods $cfg.HotKey
    $HideBtn.ToolTip = if ($cfg.DesktopMode) { "Đưa về màn hình desktop (bấm $name để gọi lên)" } else { "Ẩn widget (bấm $name để mở lại)" }
    $PinGlyph.Text = [string][char]$(if ($cfg.DesktopMode) { $G.unpin } else { $G.pin })
    $PinGlyph.Foreground = if ($cfg.DesktopMode) { B $Blue } else { B $T.Text }
    $PinBtn.ToolTip = if ($cfg.DesktopMode) { 'Bỏ ghim khỏi desktop (widget sẽ tự ẩn như cũ)' } else { 'Ghim lên màn hình desktop - luôn hiển thị' }
    $miHotkey.Header = "Đổi phím tắt… ($name)"
    if ($script:tray) {
        $tip = "Device Widget - $name"
        if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
        $script:tray.Text = $tip
        $script:trayHot.Text = "Đổi phím tắt… ($name)"
    }
}

# ============================================================ bảng tuỳ chỉnh
$script:panelKey = $null
$script:panelSig = $null
$script:wifiList = @()
$script:wifiScanning = $false
$script:pwFor = $null
$script:pwTried = $null

function Switch-Panel($key) {
    if ($script:panelKey -eq $key) { Close-Panel; return }
    End-Capture
    $script:panelKey = $key
    $script:pwFor = $null
    foreach ($k in $RingBtn.Keys) { $RingBtn[$k].Background = if ($k -eq $key) { B $T.Hover } else { B '#00000000' } }
    $PanelCard.Visibility = 'Visible'
    if ($key -eq 'wifi') { Start-WifiScan }
    if ($key -eq 'hotkey') { $script:hotNote = $null; Start-Capture }
    Show-PanelContent $true
}
function Close-Panel {
    End-Capture
    $script:panelKey = $null; $script:pwFor = $null
    foreach ($k in $RingBtn.Keys) { $RingBtn[$k].Background = B '#00000000' }
    $PanelCard.Visibility = 'Collapsed'
    $PanelBody.Children.Clear(); $PanelTools.Children.Clear()
}
function Show-PanelContent([bool]$force) {
    try {
        switch ($script:panelKey) {
            'wifi'       { Show-WifiPanel $force }
            'bluetooth'  { Show-DevicePanel $null $force }
            'headphones' { Show-DevicePanel 'headphones' $force }
            'mouse'      { Show-DevicePanel 'mouse' $force }
            'keyboard'   { Show-DevicePanel 'keyboard' $force }
            'mic'        { Show-AudioPanel $true $force }
            'speaker'    { Show-AudioPanel $false $force }
            'camera'     { Show-CameraPanel $force }
            'hotkey'     { Show-HotkeyPanel $force }
            'lan'        { Show-LanPanel $force }
            'cpu'        { Show-SysPanel 'cpu' $force }
            'ram'        { Show-SysPanel 'ram' $force }
            'battery'    { Show-SysPanel 'battery' $force }
            'disk'       { Show-DiskPanel $force }
            'tiles'      { Show-TilesPanel $force }
        }
    } catch { Write-Log "panel: $($_.Exception.Message)" }
}
function Test-PanelChanged($sig, [bool]$force) {
    if (-not $force -and $sig -eq $script:panelSig) { return $false }
    $script:panelSig = $sig
    $PanelBody.Children.Clear(); $PanelTools.Children.Clear()
    $true
}

# ---------- mạng LAN
function Show-LanPanel([bool]$force) {
    $ads = @([DeviceWidget.Net]::State.EthAdapters)
    $sig = 'lan|' + (($ads | ForEach-Object { "$($_.Name)$($_.Up)$($_.SpeedMbps)$($_.Ip)" }) -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Mạng LAN (cắm dây)'
    if ($ads.Count -eq 0) { Add-InfoRow 'Máy này không có cổng mạng LAN.' }
    foreach ($a in $ads) {
        if ($a.Up) {
            $sp = Format-LinkSpeed $a.SpeedMbps
            [void](New-PanelRow $G.ethernet $a.Name ('Đang kết nối' + $(if ($sp) { " · $sp" })) 'Đã kết nối' $Green $null $null $Blue)
            if ($a.Ip) { Add-InfoRow "Địa chỉ IP: $($a.Ip)" }
            Add-InfoRow "Card mạng: $($a.Description)$(if ($a.Mac) { "  ·  MAC $($a.Mac)" })"
        } else {
            [void](New-PanelRow $G.ethernet $a.Name $a.Description 'Chưa cắm dây' $T.Sub $null $null)
        }
    }
    if ($ads.Count -gt 0 -and -not ($ads | Where-Object { $_.Up })) {
        Add-InfoRow 'Cắm dây mạng vào máy, ô "Mạng LAN" sẽ tự chuyển sang Đã kết nối.'
    }
    Add-Separator
    Add-LinkRow $G.settings 'Cài đặt Ethernet' 'ms-settings:network-ethernet'
    Add-LinkRow $G.settings 'Trạng thái mạng' 'ms-settings:network-status'
}

# ---------- CPU / RAM / pin
function Show-SysPanel($kind, [bool]$force) {
    $st = $script:sys
    if (-not $st) { $st = [DeviceWidget.SysInfo]::Sample() }
    $sig = "sys|$kind|$($st.Cpu)|$($st.RamPercent)|$($st.Battery)|$($st.Charging)|$($st.OnAc)"
    if (-not (Test-PanelChanged $sig $force)) { return }
    switch ($kind) {
        'cpu' {
            $PanelTitle.Text = 'CPU'
            [void](New-PanelRow $TileDefs.cpu.Glyph ([DeviceWidget.SysInfo]::CpuName()) "$([Environment]::ProcessorCount) luồng xử lý" "$($st.Cpu)%" $Blue $null $null $Blue)
            Add-InfoRow 'Mức dùng CPU của toàn máy, cập nhật mỗi giây.'
        }
        'ram' {
            $PanelTitle.Text = 'Bộ nhớ RAM'
            [void](New-PanelRow $TileDefs.ram.Glyph ('Đang dùng {0:0.0} / {1:0.0} GB' -f $st.RamUsedGb, $st.RamTotalGb) ('Còn trống {0:0.0} GB' -f ($st.RamTotalGb - $st.RamUsedGb)) "$($st.RamPercent)%" $Blue $null $null $Blue)
        }
        'battery' {
            $PanelTitle.Text = 'Pin'
            if ($st.HasBattery) {
                $state = if ($st.Charging) { 'Đang sạc' } elseif ($st.OnAc) { 'Đang cắm điện' } else { 'Đang dùng pin' }
                [void](New-PanelRow $TileDefs.battery.Glyph "Pin $($st.Battery)%" $state $null $null $null $null $Blue)
            } else {
                Add-InfoRow 'Máy này không có pin (máy bàn), đang chạy bằng điện trực tiếp.'
            }
        }
    }
    Add-Separator
    if ($kind -eq 'battery') { Add-LinkRow $G.settings 'Cài đặt pin & nguồn' 'ms-settings:powersleep' }
    Add-LinkRow $G.settings 'Mở Task Manager' 'taskmgr.exe'
}

# ---------- ổ đĩa
function Show-DiskPanel([bool]$force) {
    $disks = @($script:data.Disks)
    $sig = 'disk|' + (($disks | ForEach-Object { "$($_.Name)$([int]($_.AvailableFreeSpace / 1GB))" }) -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Ổ đĩa'
    foreach ($dk in $disks) {
        $used = 1 - $dk.AvailableFreeSpace / $dk.TotalSize
        $label = if ($dk.VolumeLabel) { "Ổ $($dk.Name.TrimEnd('\')) ($($dk.VolumeLabel))" } else { "Ổ $($dk.Name.TrimEnd('\'))" }
        $c = if ($used -ge 0.95) { $Red } elseif ($used -ge 0.85) { $Orange } else { $Blue }
        [void](New-PanelRow $TileDefs.disk.Glyph $label ('Trống {0:0} GB / {1:0} GB' -f ($dk.AvailableFreeSpace / 1GB), ($dk.TotalSize / 1GB)) ('{0:0}%' -f ($used * 100)) $c $dk.Name {
            Start-Process 'explorer.exe' $this.Tag
        } $c)
    }
    if ($disks.Count -eq 0) { Add-InfoRow 'Không đọc được ổ đĩa.' }
    Add-Separator
    Add-LinkRow $G.settings 'Cài đặt lưu trữ' 'ms-settings:storagesense'
}

# ---------- tuỳ chỉnh các ô biểu tượng
function Set-Tiles($list) {
    $cfg.Tiles = @($list)
    Save-Config
    Build-Rings
    Update-Rings; Update-NetRings; Update-SysRings
    Show-PanelContent $true
}
function New-Pill([bool]$on, $tag, [scriptblock]$onClick, $tip) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Padding = '4'; $btn.Tag = $tag; $btn.ToolTip = $tip
    $pill = New-Object Windows.Controls.Border
    $pill.Width = 40; $pill.Height = 24; $pill.CornerRadius = 12
    $pill.Background = if ($on) { B $Green } else { B $T.Track }
    $knob = New-Object Windows.Shapes.Ellipse
    $knob.Width = 20; $knob.Height = 20; $knob.Fill = B '#FFFFFF'; $knob.Margin = '2,0'
    $knob.HorizontalAlignment = if ($on) { 'Right' } else { 'Left' }
    $pill.Child = $knob
    $btn.Content = $pill
    $btn.Add_Click($onClick)
    $btn
}
function New-SmallButton($glyph, $tag, $tip, [bool]$enabled, [scriptblock]$onClick) {
    $btn = New-Object Windows.Controls.Button
    $btn.Style = $FlatStyle; $btn.Width = 28; $btn.Height = 28; $btn.Tag = $tag; $btn.ToolTip = $tip
    $btn.HorizontalContentAlignment = 'Center'; $btn.IsEnabled = $enabled
    $btn.Content = New-Icon $glyph 11 $T.Sub
    $btn.Add_Click($onClick)
    $btn
}
function Show-TilesPanel([bool]$force) {
    $tiles = Get-Tiles
    $sig = 'tiles|' + ($tiles -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Tuỳ chỉnh biểu tượng'
    Add-InfoRow 'Gạt công tắc để thêm / bớt ô, bấm mũi tên để đổi thứ tự.'
    $all = @($tiles) + @($TileDefs.Keys | Where-Object { $tiles -notcontains $_ })
    foreach ($k in $all) {
        $shown = $tiles -contains $k
        $idx = [array]::IndexOf($tiles, $k)
        $grid = New-Cols @('Auto', '*', 'Auto', 'Auto', 'Auto')
        $grid.Margin = '8,1,0,1'
        $ic = New-Icon $TileDefs[$k].Glyph 16 $(if ($shown) { $T.Text } else { $T.Sub })
        $ic.Width = 30; $ic.VerticalAlignment = 'Center'
        $tt = New-Text $TileDefs[$k].Label 13 $(if ($shown) { $T.Text } else { $T.Sub })
        $tt.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($tt, 1)
        [void]$grid.Children.Add($ic); [void]$grid.Children.Add($tt)
        if ($shown) {
            $upB = New-SmallButton 0xE70E @{ Key = $k; D = -1 } 'Lên trước' ($idx -gt 0) { Move-Tile $this.Tag.Key $this.Tag.D }
            $dnB = New-SmallButton 0xE70D @{ Key = $k; D = 1 } 'Xuống sau' ($idx -lt $tiles.Count - 1) { Move-Tile $this.Tag.Key $this.Tag.D }
            [Windows.Controls.Grid]::SetColumn($upB, 2); [Windows.Controls.Grid]::SetColumn($dnB, 3)
            [void]$grid.Children.Add($upB); [void]$grid.Children.Add($dnB)
        }
        $pill = New-Pill $shown $k { Switch-Tile $this.Tag } $(if ($shown) { 'Bớt ô này' } else { 'Thêm ô này' })
        [Windows.Controls.Grid]::SetColumn($pill, 4)
        [void]$grid.Children.Add($pill)
        [void]$PanelBody.Children.Add($grid)
    }
    Add-Separator
    [void](New-PanelRow $G.refresh 'Khôi phục mặc định' $null $null $null $null { Set-Tiles $DefaultTiles } $T.Sub)
}
function Move-Tile($key, [int]$delta) {
    $list = New-Object System.Collections.ArrayList
    [void]$list.AddRange([object[]](Get-Tiles))
    $i = $list.IndexOf($key); $j = $i + $delta
    if ($i -lt 0 -or $j -lt 0 -or $j -ge $list.Count) { return }
    $tmp = $list[$i]; $list[$i] = $list[$j]; $list[$j] = $tmp
    Set-Tiles $list.ToArray()
}
function Switch-Tile($key) {
    $list = New-Object System.Collections.ArrayList
    [void]$list.AddRange([object[]](Get-Tiles))
    if ($list.Contains($key)) {
        if ($list.Count -le 1) { return }   # phải còn ít nhất 1 ô
        $list.Remove($key)
    } else { [void]$list.Add($key) }
    Set-Tiles $list.ToArray()
}

# ---------- phím tắt
function Show-HotkeyPanel([bool]$force) {
    $sig = "hot|$script:capturing|$script:hotNote|$($cfg.HotMods)|$($cfg.HotKey)"
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Phím tắt mở widget'
    [void](New-PanelRow $G.keys (Format-HotKey $cfg.HotMods $cfg.HotKey) 'Phím tắt hiện tại - bấm ở bất kỳ đâu để hiện / ẩn widget' $null $null $null $null $Blue)
    if ($script:hotNote) { Add-InfoRow $script:hotNote $script:hotNoteColor }
    if ($script:capturing) {
        Add-InfoRow 'Hãy nhấn tổ hợp phím mới ngay bây giờ, ví dụ Ctrl + Alt + D hoặc Ctrl + Shift + Space. Bấm Esc để huỷ.' $T.Text
    } else {
        [void](New-PanelRow $G.refresh 'Đổi tổ hợp khác' $null ([string][char]$G.chevron) $T.Sub $null {
            $script:hotNote = $null; Start-Capture; Show-PanelContent $true
        } $T.Sub)
    }
}

# ---------- Wi-Fi
function Start-WifiScan {
    if ($script:wifiScanning) { return }
    $script:wifiScanning = $true
    Add-Job ([DeviceWidget.Net]::Scan()) {
        param($task)
        $script:wifiScanning = $false
        if (-not $task.IsFaulted) { $script:wifiList = @($task.Result) }
        if ($script:panelKey -eq 'wifi') { Show-PanelContent $false }
    }
}
$WifiDone = {
    param($task, $ssid)
    Clear-Busy $ssid
    $st = if ($task.IsFaulted) { 'Error' } else { [string]$task.Result }
    switch ($st) {
        'Success' { $script:pwFor = $null; Set-Note $ssid 'Đã kết nối' }
        'InvalidCredential' {
            if ($script:pwTried -eq $ssid) { Set-Note $ssid 'Sai mật khẩu, hãy nhập lại' 20 }
            else { Set-Note $ssid 'Nhập mật khẩu để kết nối' 60 }
            $script:pwFor = $ssid
        }
        'NetworkNotAvailable' { Set-Note $ssid 'Không tìm thấy mạng này nữa' }
        'Timeout' { Set-Note $ssid 'Hết thời gian chờ kết nối' }
        'UnsupportedAuthenticationProtocol' { Set-Note $ssid 'Kiểu bảo mật này chưa hỗ trợ - dùng Cài đặt Wi-Fi' }
        'AccessRevoked' { Set-Note $ssid 'Windows chặn quyền điều khiển Wi-Fi' }
        default { Set-Note $ssid 'Không kết nối được' }
    }
    $script:pwTried = $null
    Show-PanelContent $true
    Start-WifiScan
}
function Connect-Wifi($ssid, $password) {
    if ($password) { $script:pwTried = $ssid }
    Set-Busy $ssid 'Đang kết nối…' $null 45
    Add-Job ([DeviceWidget.Net]::Connect($ssid, $password)) $WifiDone $ssid
    Show-PanelContent $true
}
function Add-PasswordRow($ssid) {
    $grid = New-Cols @('*', 'Auto')
    $grid.Margin = '38,0,8,8'
    $pb = New-Object Windows.Controls.PasswordBox
    $pb.Height = 32; $pb.Padding = '8,0'; $pb.VerticalContentAlignment = 'Center'; $pb.FontSize = 13
    $pb.Background = B $T.Input; $pb.Foreground = B $T.Text; $pb.BorderBrush = B $T.Line; $pb.CaretBrush = B $T.Text
    $pb.ToolTip = 'Mật khẩu Wi-Fi'
    $go = New-Object Windows.Controls.Button
    $go.Style = $RoundStyle; $go.Height = 32; $go.Padding = '14,0'; $go.Margin = '8,0,0,0'
    $go.Background = B $Blue
    $go.Content = New-Text 'Kết nối' 12 '#FFFFFF' 'SemiBold'
    $go.Tag = @{ Ssid = $ssid; Box = $pb }
    $pb.Tag = $go
    $go.Add_Click({ $x = $this.Tag; if ($x.Box.Password) { Connect-Wifi $x.Ssid $x.Box.Password } })
    $pb.Add_KeyDown({
        param($s, $e)
        if ($e.Key -eq 'Return') { $s.Tag.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) }
    })
    $pb.Add_Loaded({ [void]$this.Focus() })
    [Windows.Controls.Grid]::SetColumn($go, 1)
    [void]$grid.Children.Add($pb); [void]$grid.Children.Add($go)
    [void]$PanelBody.Children.Add($grid)
}
function Show-WifiPanel([bool]$force) {
    if ($script:pwFor -and -not $force) { return }   # đang gõ mật khẩu thì không vẽ lại
    $ns = [DeviceWidget.Net]::State
    $sig = "wifi|$($ns.WifiOn)|$($ns.Ssid)|$script:wifiScanning|" +
           (($script:wifiList | ForEach-Object { "$($_.Ssid)$($_.Bars)$(Get-Busy $_.Ssid)$(Get-Note $_.Ssid)" }) -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Wi-Fi'
    New-ToolButton $G.refresh 'Quét lại' { Start-WifiScan; Show-PanelContent $true }
    New-Toggle $ns.WifiOn $null {
        $on = -not [DeviceWidget.Net]::State.WifiOn
        Add-Job ([DeviceWidget.Net]::SetRadio($false, $on)) { param($task) Show-PanelContent $true; Start-WifiScan }
    } 'Bật / tắt Wi-Fi'

    if (-not $ns.HasWifi) { Add-InfoRow 'Không tìm thấy bộ thu Wi-Fi trên máy.' }
    elseif ($ns.HasWifiRadio -and -not $ns.WifiOn) { Add-InfoRow 'Wi-Fi đang tắt. Bật công tắc ở trên để tìm mạng.' }
    else {
        if ($script:wifiScanning -and $script:wifiList.Count -eq 0) { Add-InfoRow 'Đang tìm mạng Wi-Fi…' }
        elseif ($script:wifiList.Count -eq 0) { Add-InfoRow 'Không tìm thấy mạng nào.' }
        $nets = @($script:wifiList | Sort-Object { -not ($ns.Connected -and $_.Ssid -eq $ns.Ssid) }, { - $_.Bars })
        foreach ($n in $nets) {
            $isCur = $ns.Connected -and $n.Ssid -eq $ns.Ssid
            $glyph = switch ($n.Bars) { 0 { $G.wifi1 } 1 { $G.wifi1 } 2 { $G.wifi2 } 3 { $G.wifi3 } default { $G.wifi } }
            $sub = if ($isCur) { 'Đã kết nối' } elseif ($n.Secured) { 'Có mật khẩu' } else { 'Mạng mở' }
            $note = Get-Note $n.Ssid
            if ($note) { $sub = $note }
            $busy = Get-Busy $n.Ssid
            $right = if ($busy) { $busy } elseif ($isCur) { 'Ngắt kết nối' } else { 'Kết nối' }
            $rc = if ($busy) { $Orange } elseif ($isCur) { $Red } else { $Blue }
            [void](New-PanelRow $glyph $n.Ssid $sub $right $rc @{ Ssid = $n.Ssid; Cur = $isCur } {
                $x = $this.Tag
                if (Get-Busy $x.Ssid) { return }
                if ($x.Cur) {
                    Set-Busy $x.Ssid 'Đang ngắt…' $null 10
                    Add-Job ([DeviceWidget.Net]::Disconnect()) { param($task, $ssid) Clear-Busy $ssid; Show-PanelContent $true; Start-WifiScan } $x.Ssid
                    Show-PanelContent $true
                } else { Connect-Wifi $x.Ssid $null }
            } $(if ($isCur) { $Blue } else { $null }))
            if ($script:pwFor -eq $n.Ssid) { Add-PasswordRow $n.Ssid }
        }
    }
    Add-Separator
    Add-LinkRow $G.settings 'Cài đặt Wi-Fi' 'ms-settings:network-wifi'
}

# ---------- Bluetooth / chuột / bàn phím / tai nghe
function Show-DevicePanel($kind, [bool]$force) {
    $ns = [DeviceWidget.Net]::State
    $bt = @($script:data.Bt | Where-Object { -not $kind -or $_.Kind -eq $kind })
    $usb = if ($kind) { @($script:data.Usb | Where-Object { $_.Kind -eq $kind }) } else { @() }
    $sig = "dev|$kind|$($ns.BtOn)|" + (($bt | ForEach-Object { "$($_.Name):$($_.Connected):$($_.Battery):$(Get-Busy $_.Name $_.Connected):$(Get-Note $_.Name)" }) -join ',') +
           '|' + (($usb | ForEach-Object { $_.Name }) -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }

    $PanelTitle.Text = if ($kind) { $KindLabel[$kind] } else { 'Bluetooth' }
    if (-not $kind) {
        New-Toggle $ns.BtOn $null {
            $on = -not [DeviceWidget.Net]::State.BtOn
            Add-Job ([DeviceWidget.Net]::SetRadio($true, $on)) { param($task) Update-NetRings; Show-PanelContent $true }
        } 'Bật / tắt Bluetooth'
        if (-not $ns.BtOn) { Add-InfoRow 'Bluetooth đang tắt. Bật công tắc ở trên để kết nối thiết bị.' }
    }

    foreach ($u in $usb) {
        [void](New-PanelRow $G.usb $u.Name "$($KindLabel[$u.Kind]) · cắm qua USB / đầu thu 2.4G" 'Đang cắm' $Green $null $null $Green)
    }
    foreach ($x in ($bt | Sort-Object { -not $_.Connected }, Name)) {
        $sub = $KindLabel[$x.Kind] + ' · Bluetooth'
        if ($x.Connected -and $x.Battery -ge 0) { $sub += " · Pin $($x.Battery)%" }
        $note = Get-Note $x.Name
        if ($note) { $sub = $note }
        $busy = Get-Busy $x.Name $x.Connected
        $isAudio = $x.Kind -eq 'headphones'
        if ($busy) { $right = $busy; $rc = $Orange }
        elseif ($x.Connected) { $right = $(if ($isAudio) { 'Ngắt kết nối' } else { 'Đã kết nối' }); $rc = $(if ($isAudio) { $Red } else { $Green }) }
        else { $right = $(if ($isAudio) { 'Kết nối' } else { 'Chưa kết nối' }); $rc = $(if ($isAudio) { $Blue } else { $T.Sub }) }
        [void](New-PanelRow $G[$x.Kind] $x.Name $sub $right $rc $x {
            $dev = $this.Tag
            if (Get-Busy $dev.Name $dev.Connected) { return }
            if ($dev.Kind -eq 'headphones') {
                $want = -not $dev.Connected
                Set-Busy $dev.Name $(if ($want) { 'Đang kết nối…' } else { 'Đang ngắt…' }) $want 15
                Add-Job ([DeviceWidget.Devices]::BtAudio($dev.ContainerId, $want)) {
                    param($task, $devName)
                    if ($task.IsFaulted -or -not $task.Result) { Clear-Busy $devName; Set-Note $devName 'Thiết bị này không điều khiển được từ đây' }
                    Show-PanelContent $true
                } $dev.Name
            } elseif ($dev.Kind -eq 'phone') {
                Set-Note $dev.Name 'Điện thoại: hãy kết nối từ phía điện thoại'
            } elseif ($dev.Connected) {
                Set-Note $dev.Name 'Tắt nguồn thiết bị để ngắt kết nối'
            } else {
                Set-Note $dev.Name 'Bật nguồn thiết bị - nó sẽ tự kết nối lại'
            }
            Show-PanelContent $true
        } $(if ($x.Connected) { $Blue } else { $null }))
    }
    if ($bt.Count -eq 0 -and $usb.Count -eq 0) {
        Add-InfoRow $(if ($kind) { "Chưa có $($KindLabel[$kind].ToLower()) nào được ghép hoặc cắm vào máy." } else { 'Chưa ghép thiết bị Bluetooth nào.' })
    }
    Add-Separator
    Add-LinkRow $G.add 'Ghép thiết bị Bluetooth mới' 'ms-settings-connectabledevices:devicediscovery'
    Add-LinkRow $G.settings 'Cài đặt Bluetooth' 'ms-settings:bluetooth'
}

# ---------- micro / loa
function Show-AudioPanel([bool]$capture, [bool]$force) {
    $eps = @([DeviceWidget.Devices]::ListEndpoints($capture))
    $info = if ($capture) { $script:data.Mic } else { $script:data.Spk }
    $use = $script:data.MicUse
    $sig = "audio|$capture|$($info.Muted)|$($use.InUse)|$($use.Apps -join ',')|" + (($eps | ForEach-Object { "$($_.Id)$($_.IsDefault)" }) -join ',')
    if (-not (Test-PanelChanged $sig $force)) { return }

    $PanelTitle.Text = if ($capture) { 'Micro' } else { 'Loa / tai nghe phát ra' }
    if ($info.Present) {
        New-Toggle (-not $info.Muted) $capture {
            $cap = [bool]$this.Tag
            $cur = [DeviceWidget.Devices]::GetDefaultAudio($cap)
            [DeviceWidget.Devices]::SetMute($cap, -not $cur.Muted)
            Update-Devices; Show-PanelContent $true
        } $(if ($capture) { 'Bật / tắt tiếng micro' } else { 'Bật / tắt tiếng loa' })
    }
    if ($capture -and $use.InUse) { Add-InfoRow ('Đang được dùng bởi: ' + ($use.Apps -join ', ')) $Orange }
    if ($eps.Count -eq 0) {
        Add-InfoRow $(if ($capture) { 'Không tìm thấy micro. Hãy cắm micro hoặc tai nghe có mic.' } else { 'Không tìm thấy loa / tai nghe.' })
    }
    foreach ($ep in $eps) {
        $low = $ep.Name.ToLower()
        $glyph = if ($capture) { $G.mic } elseif ($low -match 'headphone|headset|tai nghe|buds|hands-free') { $G.headphones } elseif ($low -match 'monitor|hdmi|display') { $G.monitor } else { $G.speaker }
        $sub = if ($ep.IsDefault) { 'Đang dùng' } else { 'Bấm để chuyển sang' }
        $right = if ($ep.IsDefault) { [string][char]$G.check } else { $null }
        [void](New-PanelRow $glyph $ep.Name $sub $right $Blue $ep.Id {
            [void][DeviceWidget.Devices]::SetDefaultEndpoint([string]$this.Tag)
            Update-Devices; Show-PanelContent $true
        } $(if ($ep.IsDefault) { $Blue } else { $null }))
    }
    Add-Separator
    if ($capture) { Add-LinkRow $G.settings 'Quyền truy cập micro' 'ms-settings:privacy-microphone' }
    Add-LinkRow $G.settings 'Cài đặt âm thanh' 'ms-settings:sound'
}

# ---------- camera
function Show-CameraPanel([bool]$force) {
    $cams = $script:data.Cams; $use = $script:data.CamUse
    $sig = "cam|$($cams -join ',')|$($use.InUse)|$($use.Apps -join ',')"
    if (-not (Test-PanelChanged $sig $force)) { return }
    $PanelTitle.Text = 'Camera'
    if ($use.InUse) { Add-InfoRow ('Đang được dùng bởi: ' + ($use.Apps -join ', ')) $Green }
    if ($cams.Count -eq 0) { Add-InfoRow 'Không tìm thấy camera. Hãy cắm webcam vào máy.' }
    foreach ($c in $cams) {
        [void](New-PanelRow $G.camera $c $(if ($use.InUse) { 'Đang bật' } else { 'Sẵn sàng' }) $null $null $null $null)
    }
    Add-Separator
    Add-LinkRow $G.camera 'Mở ứng dụng Camera' 'microsoft.windows.camera:'
    Add-LinkRow $G.settings 'Quyền truy cập camera' 'ms-settings:privacy-webcam'
}

# ============================================================ nhạc, tốc độ, thanh trượt
function Format-Speed([double]$bps) {
    if ($bps -ge 1MB) { '{0:0.00} MB/s' -f ($bps / 1MB) }
    else { '{0:0} KB/s' -f ($bps / 1KB) }
}

$script:artVersion = -1
function Set-DefaultArt {
    $Art.Background = B $T.Btn
    $ArtBadge.Visibility = 'Visible'
}
function Update-Music {
    $m = [DeviceWidget.Media]::Info
    if ($m.Has) {
        $MTitle.Text = if ($m.Title) { $m.Title } else { $m.App }
        $MSub.Text = (@($m.Artist, $m.App) | Where-Object { $_ }) -join ' · '
    } else {
        $MTitle.Text = 'Không có nhạc đang phát'
        $MSub.Text = 'Bấm ▶ để phát tiếp bài gần nhất'
    }
    $PlayGlyph.Text = [string][char]$(if ($m.Playing) { $G.pause } else { $G.play })
    if ($m.Version -ne $script:artVersion) {
        $script:artVersion = $m.Version
        if ($m.Thumb) {
            try {
                $bmp = New-Object Windows.Media.Imaging.BitmapImage
                $bmp.BeginInit()
                $bmp.StreamSource = New-Object IO.MemoryStream (, $m.Thumb)
                $bmp.CacheOption = 'OnLoad'; $bmp.DecodePixelWidth = 120
                $bmp.EndInit(); $bmp.Freeze()
                $brush = New-Object Windows.Media.ImageBrush $bmp
                $brush.Stretch = 'UniformToFill'
                $Art.Background = $brush
                $ArtBadge.Visibility = 'Collapsed'
            } catch { Set-DefaultArt }
        } else { Set-DefaultArt }
    }
}

function Update-Sliders {
    if ([DeviceWidget.Brightness]::Supported) {
        Set-SliderEnabled $BriSlider $true; $BriNote.Visibility = 'Collapsed'
        if (-not $BriSlider.Dragging) {
            $bv = [DeviceWidget.Brightness]::Current
            if ($bv -ge 0) { Set-SliderValue $BriSlider ($bv / 100) $false; $BriVal.Text = "$bv%" }
        }
    } elseif ($script:tick -gt 4) {
        Set-SliderEnabled $BriSlider $false; $BriNote.Visibility = 'Visible'; $BriVal.Text = ''
    }
    if (-not $VolSlider.Dragging) {
        $spk = $script:data.Spk
        if ($null -eq $spk) { return }
        if ($spk.Present) {
            Set-SliderEnabled $VolSlider $true
            Set-SliderValue $VolSlider ($spk.Volume / 100) $false
            $VolVal.Text = if ($spk.Muted) { 'Tắt tiếng' } else { "$($spk.Volume)%" }
            $VolSlider.Icon.Text = [string][char]$(if ($spk.Muted) { $G.speakerOff } else { $G.speaker })
        } else { Set-SliderEnabled $VolSlider $false; $VolVal.Text = 'Không có loa' }
    }
}

$script:tick = 0
$script:idleSkip = $false
function Invoke-Tick {
    if (-not $win.IsVisible -and -not $Snapshot) { return }   # đang ẩn: không làm gì cả
    # đang nằm trên desktop mà không được dùng: cập nhật 2 giây / lần cho nhẹ máy
    if ($cfg.DesktopMode -and -not $win.IsActive -and -not $Snapshot) {
        $script:idleSkip = -not $script:idleSkip
        if ($script:idleSkip) { return }
    }
    $script:tick++
    try {
        [DeviceWidget.NetSpeed]::Sample()
        $SpeedDown.Text = Format-Speed ([DeviceWidget.NetSpeed]::Down)
        $SpeedUp.Text = Format-Speed ([DeviceWidget.NetSpeed]::Up)
        if ($script:tick % 2 -eq 1) { Update-Devices }
        Update-NetRings
        Update-SysRings
        if ($MusicCard.Visibility -eq 'Visible') { Update-Music }
        if ($SliderArea.Visibility -eq 'Visible') { Update-Sliders }
    } catch { Write-Log "tick: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)" }
}

# ============================================================ hiện / ẩn
$script:hiddenAt = [datetime]::MinValue
$script:exiting = $false
$script:menuOpen = $false

function Set-StartPosition {
    $wa = [Windows.SystemParameters]::WorkArea
    $win.MaxHeight = $wa.Height
    if ($null -ne $cfg.Left -and $null -ne $cfg.Top -and
        $cfg.Left -gt ($wa.Left - 300) -and $cfg.Left -lt ($wa.Right - 50) -and
        $cfg.Top -gt ($wa.Top - 50) -and $cfg.Top -lt ($wa.Bottom - 50)) {
        $win.Left = $cfg.Left; $win.Top = $cfg.Top
    } else {
        $win.Left = $wa.Right - $win.Width - 4; $win.Top = $wa.Top + 4
    }
}
$script:prevFg = [IntPtr]::Zero
$script:sentBackAt = [datetime]::MinValue

function Get-WantTopmost { [bool](-not $cfg.DesktopMode -and ($cfg.Topmost -or $cfg.AutoHide)) }

function Show-Widget([bool]$activate = $true) {
    if ($activate) {
        $fg = [DeviceWidget.DesktopPin]::Foreground()
        if ($fg -ne $hwnd) { $script:prevFg = $fg }   # nhớ cửa sổ đang dùng để trả lại khi widget lùi về desktop
    }
    if (-not $win.IsVisible) {
        Set-StartPosition
        [DeviceWidget.Watcher]::Paused = $false
        [DeviceWidget.NetSpeed]::Reset()
        $win.Topmost = Get-WantTopmost
        $win.ShowActivated = $activate
        $win.Show()
        $win.ShowActivated = $true
        $script:tick = 0
        Invoke-Tick
    }
    if ($activate) { [void]$win.Activate() }
    elseif ($cfg.DesktopMode) { [DeviceWidget.DesktopPin]::SendToBottom($hwnd) }
}
function Hide-Widget {
    if (-not $win.IsVisible) { return }
    $script:hiddenAt = Get-Date
    if ($script:panelKey -eq 'hotkey') { Close-Panel }
    $win.Hide()
    [DeviceWidget.Watcher]::Paused = $true
}
# chế độ desktop: lùi xuống sát hình nền (vẫn hiện), trả focus cho cửa sổ trước đó
function Send-ToDesktop {
    $script:sentBackAt = Get-Date
    if ($script:panelKey -eq 'hotkey') { Close-Panel }
    $wasActive = $win.IsActive
    [DeviceWidget.DesktopPin]::SendToBottom($hwnd)
    if ($wasActive) { [DeviceWidget.DesktopPin]::Focus($script:prevFg) }
}
# nút "–", Esc, Alt + F4: ẩn đi, hoặc lùi về desktop nếu đang ghim
function Dismiss-Widget {
    if ($cfg.DesktopMode) { Send-ToDesktop } else { Hide-Widget }
}
function Toggle-Widget([bool]$fromTray) {
    if ($cfg.DesktopMode) {
        if ($win.IsVisible -and $win.IsActive) { Send-ToDesktop }
        elseif ($fromTray -and ((Get-Date) - $script:sentBackAt).TotalMilliseconds -lt 500) {
            # widget vừa lùi về desktop vì bấm vào biểu tượng khay: coi như bấm để đóng
        } else { Show-Widget }
        return
    }
    if ($win.IsVisible) {
        if ($win.IsActive -or $fromTray) { Hide-Widget } else { Show-Widget }
    } elseif ($fromTray -and ((Get-Date) - $script:hiddenAt).TotalMilliseconds -lt 500) {
        # widget vừa tự ẩn vì bấm vào biểu tượng khay: coi như bấm để đóng
    } else { Show-Widget }
}
function Set-DesktopMode([bool]$on) {
    $cfg.DesktopMode = $on
    Save-Config
    if (-not $Snapshot) { [DeviceWidget.DesktopPin]::Pin($hwnd, $on) }
    $win.Topmost = Get-WantTopmost
    $miDesktop.IsChecked = $on
    $miAutoHide.IsEnabled = -not $on
    $miTopmost.IsEnabled = -not $on
    if ($script:trayDesktop) { $script:trayDesktop.Checked = $on }
    Update-HotkeyLabels
    if ($on -and -not $win.IsVisible) { Show-Widget $false }
}
function Open-HotkeyPanel {
    Show-Widget
    if ($script:panelKey -ne 'hotkey') { Switch-Panel 'hotkey' }
    else { $script:hotNote = $null; Start-Capture; Show-PanelContent $true }
}
function Set-Autostart([bool]$on) {
    if ($on) {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($startupLnk)
        $exe = Join-Path $here 'DeviceWidget.exe'
        if (Test-Path $exe) {
            $lnk.TargetPath = $exe
            $lnk.Arguments = '/hidden'
        } else {
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
            $lnk.Arguments = '"' + (Join-Path $here 'Start-Widget.vbs') + '" /hidden'
        }
        $lnk.WorkingDirectory = $here
        $ico = Join-Path $here 'app.ico'
        if (Test-Path $ico) { $lnk.IconLocation = $ico }
        $lnk.Description = 'Device Widget'
        $lnk.Save()
    } else { Remove-Item $startupLnk -ErrorAction SilentlyContinue }
}
# Liquid Glass: bo góc vùng làm mờ theo đúng kích thước widget (tính theo điểm ảnh thật của màn hình)
function Update-GlassRegion {
    if (-not $isGlass -or $Snapshot) { return }
    $src = [Windows.PresentationSource]::FromVisual($win)
    if (-not $src) { return }
    $m = $src.CompositionTarget.TransformToDevice
    $w = [int][math]::Ceiling($win.ActualWidth * $m.M11)
    $h = [int][math]::Ceiling($win.ActualHeight * $m.M22)
    if ($w -le 0 -or $h -le 0) { return }
    [DeviceWidget.Glass]::Clip($hwnd, $w, $h, [int][math]::Round(24 * $m.M11))
}
# đổi giao diện cần dựng lại cửa sổ: khởi động lại ứng dụng (mất khoảng 10-15 giây)
$script:restart = $false
function Restart-App {
    $script:restart = $true
    Exit-App
}
function Set-Glass([bool]$on) {
    if ($on -eq $isGlass) { return }
    $cfg.Glass = $on
    Save-Config
    Restart-App
}

function Exit-App {
    if ($script:exiting) { return }
    $script:exiting = $true
    Save-Config
    try { [DeviceWidget.HotKey]::Unregister() } catch {}
    try { $timer.Stop(); $jobTimer.Stop() } catch {}
    if ($script:tray) { try { $script:tray.Visible = $false; $script:tray.Dispose() } catch {} }
    try { $mutex.ReleaseMutex() } catch {}
    # đóng hẳn các đối tượng dùng chung để bản khởi động lại (nếu có) chạy được ngay
    foreach ($h in $mutex, $showEvt, $exitEvt) { try { $h.Dispose() } catch {} }
    try { $win.Close() } catch {}
    $app.Shutdown()
}

# ============================================================ nút bấm cố định
$DisplayBtn.Add_Click({ Start-Process 'ms-settings:display' })
$OutputBtn.Add_Click({ Switch-Panel 'speaker' })
$PlayBtn.Add_Click({ [void][DeviceWidget.Media]::Command(0) })
$NextBtn.Add_Click({ [void][DeviceWidget.Media]::Command(1) })
$PrevBtn.Add_Click({ [void][DeviceWidget.Media]::Command(2) })
$HideBtn.Add_Click({ Dismiss-Widget })
$PinBtn.Add_Click({ Set-DesktopMode (-not $cfg.DesktopMode) })
$EditBtn.Add_Click({ Switch-Panel 'tiles' })

function Set-Visibility {
    $SliderArea.Visibility = if ($cfg.ShowSliders) { 'Visible' } else { 'Collapsed' }
    $MusicCard.Visibility = if ($cfg.ShowMusic) { 'Visible' } else { 'Collapsed' }
}

# ============================================================ menu chuột phải trên widget
$menu = New-Object Windows.Controls.ContextMenu
function Add-MenuItem($header, [scriptblock]$onClick, $checkable = $false, $checked = $false) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; $mi.IsCheckable = $checkable; $mi.IsChecked = $checked
    $mi.Add_Click($onClick)
    [void]$menu.Items.Add($mi)
    $mi
}
$miHotkey = Add-MenuItem 'Đổi phím tắt…' { Open-HotkeyPanel }
$miDesktop = Add-MenuItem 'Luôn hiện trên màn hình desktop' { Set-DesktopMode $this.IsChecked } $true ([bool]$cfg.DesktopMode)
$miAutoHide = Add-MenuItem 'Tự ẩn khi bấm ra ngoài' {
    $cfg.AutoHide = $this.IsChecked; $win.Topmost = Get-WantTopmost; Save-Config
} $true ([bool]$cfg.AutoHide)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-MenuItem 'Hiện thanh độ sáng / âm lượng' {
    $cfg.ShowSliders = $this.IsChecked; Set-Visibility; Save-Config
} $true ([bool]$cfg.ShowSliders))
[void](Add-MenuItem 'Hiện trình phát nhạc' {
    $cfg.ShowMusic = $this.IsChecked; Set-Visibility; Save-Config
} $true ([bool]$cfg.ShowMusic))
$miTopmost = Add-MenuItem 'Luôn nằm trên cùng' {
    $cfg.Topmost = $this.IsChecked; $win.Topmost = Get-WantTopmost; Save-Config
} $true ([bool]$cfg.Topmost)
$miAutoHide.IsEnabled = -not $cfg.DesktopMode
$miTopmost.IsEnabled = -not $cfg.DesktopMode
$miAuto = Add-MenuItem 'Chạy cùng Windows' { Set-Autostart $this.IsChecked } $true (Test-Path $startupLnk)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-MenuItem 'Tuỳ chỉnh biểu tượng…' { if ($script:panelKey -ne 'tiles') { Switch-Panel 'tiles' } })
[void](Add-MenuItem 'Giao diện Liquid Glass (kính mờ)' { Set-Glass $this.IsChecked } $true $isGlass)
[void]$menu.Items.Add((New-Object Windows.Controls.Separator))
[void](Add-MenuItem 'Làm mới' { Update-Devices; if ($script:panelKey -eq 'wifi') { Start-WifiScan } })
[void](Add-MenuItem 'Ẩn widget' { Hide-Widget })   # ẩn hẳn kể cả khi đang ghim desktop; phím tắt gọi lại
[void](Add-MenuItem 'Thoát hẳn' { Exit-App })
$menu.Add_Opened({ $script:menuOpen = $true; $miAuto.IsChecked = Test-Path $startupLnk })
$menu.Add_Closed({ $script:menuOpen = $false })
$win.ContextMenu = $menu

# ============================================================ biểu tượng ở khay hệ thống
$script:tray = $null
$script:trayDesktop = $null
function New-Tray {
    [Windows.Forms.Application]::EnableVisualStyles()
    $bmp = New-IconBitmap 32
    $script:trayIcon = [Drawing.Icon]::FromHandle($bmp.GetHicon())
    $nt = New-Object Windows.Forms.NotifyIcon
    $nt.Icon = $script:trayIcon
    $cm = New-Object Windows.Forms.ContextMenuStrip
    $open = New-Object Windows.Forms.ToolStripMenuItem 'Mở widget'
    $open.Font = New-Object Drawing.Font($open.Font, [Drawing.FontStyle]::Bold)
    $open.Add_Click({ Show-Widget })
    [void]$cm.Items.Add($open)
    $script:trayHot = New-Object Windows.Forms.ToolStripMenuItem 'Đổi phím tắt…'
    $script:trayHot.Add_Click({ Open-HotkeyPanel })
    [void]$cm.Items.Add($script:trayHot)
    $script:trayDesktop = New-Object Windows.Forms.ToolStripMenuItem 'Luôn hiện trên màn hình desktop'
    $script:trayDesktop.CheckOnClick = $true
    $script:trayDesktop.Checked = [bool]$cfg.DesktopMode
    $script:trayDesktop.Add_Click({ Set-DesktopMode $script:trayDesktop.Checked })
    [void]$cm.Items.Add($script:trayDesktop)
    $glassItem = New-Object Windows.Forms.ToolStripMenuItem 'Giao diện Liquid Glass (kính mờ)'
    $glassItem.Checked = $isGlass
    $glassItem.Add_Click({ Set-Glass (-not $isGlass) })
    [void]$cm.Items.Add($glassItem)
    [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $script:trayAuto = New-Object Windows.Forms.ToolStripMenuItem 'Chạy cùng Windows'
    $script:trayAuto.CheckOnClick = $true
    $script:trayAuto.Add_Click({ Set-Autostart $script:trayAuto.Checked })
    [void]$cm.Items.Add($script:trayAuto)
    [void]$cm.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    $quit = New-Object Windows.Forms.ToolStripMenuItem 'Thoát'
    $quit.Add_Click({ Exit-App })
    [void]$cm.Items.Add($quit)
    $cm.Add_Opening({ $script:trayAuto.Checked = Test-Path $startupLnk })
    $nt.ContextMenuStrip = $cm
    $nt.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) {
            try { Toggle-Widget $true } catch { Write-Log "tray: $($_.Exception.Message)" }
        }
    })
    $nt.Visible = $true
    $script:tray = $nt
}

# ============================================================ cửa sổ
Set-Visibility
Set-StartPosition

# kéo cửa sổ: bấm giữ vào chỗ trống bất kỳ (nút và thanh trượt tự xử lý cú bấm của chúng)
$win.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.OriginalSource -is [Windows.Controls.PasswordBox]) { return }
    try { $win.DragMove() } catch {}
    $cfg.Left = $win.Left; $cfg.Top = $win.Top; Save-Config
})
# khi widget dài ra thì tự đẩy lên cho khỏi tràn xuống dưới màn hình
$win.Add_SizeChanged({
    if ($Snapshot) { return }
    Update-GlassRegion
    $area = [Windows.SystemParameters]::WorkArea
    if ($win.Top + $win.ActualHeight -gt $area.Bottom) {
        $win.Top = [math]::Max([double]$area.Top, [double]($area.Bottom - $win.ActualHeight))
    }
})
# bấm ra ngoài: tự ẩn (giống Control Center), hoặc lùi về desktop nếu đang ghim
$win.Add_Deactivated({
    if ($Snapshot -or $script:menuOpen -or $script:exiting) { return }
    if ($cfg.DesktopMode) { [DeviceWidget.DesktopPin]::SendToBottom($hwnd) }
    elseif ($cfg.AutoHide) { Hide-Widget }
})
# Alt + F4 chỉ ẩn / lùi về desktop, không thoát
$win.Add_Closing({
    param($s, $e)
    if (-not $script:exiting -and -not $Snapshot) { $e.Cancel = $true; Dismiss-Widget }
})
# Win + D / "Show desktop" thu nhỏ mọi cửa sổ: khi đang ghim thì hiện lại ngay trên desktop
$win.Add_StateChanged({
    if ($cfg.DesktopMode -and $win.WindowState -eq 'Minimized') {
        $win.WindowState = 'Normal'
        [DeviceWidget.DesktopPin]::SendToBottom($hwnd)
    }
})
# Esc để ẩn; khi đang đổi phím tắt thì bắt tổ hợp phím mới
$win.Add_PreviewKeyDown({
    param($s, $e)
    try {
        if ($script:capturing) {
            $e.Handled = $true
            $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
            if ($key -eq 'Escape') { Close-Panel; return }
            if (@('LeftCtrl', 'RightCtrl', 'LeftAlt', 'RightAlt', 'LeftShift', 'RightShift', 'LWin', 'RWin', 'System') -contains [string]$key) { return }
            $mods = [int][Windows.Input.Keyboard]::Modifiers   # 1 Alt, 2 Ctrl, 4 Shift, 8 Win
            if (-not (($mods -band 1) -or ($mods -band 8) -or (($mods -band 6) -eq 6))) {
                $script:hotNote = 'Tổ hợp cần có Alt hoặc Win, hoặc cả Ctrl + Shift (để không đè lên phím tắt thông thường như Ctrl + C).'
                $script:hotNoteColor = $Orange
                Show-PanelContent $true; return
            }
            $vk = [Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
            $name = Format-HotKey $mods $vk
            if ([DeviceWidget.HotKey]::Register([uint32]$mods, [uint32]$vk)) {
                $cfg.HotMods = $mods; $cfg.HotKey = $vk; Save-Config
                $script:capturing = $false
                $script:hotNote = "Đã đổi! Từ giờ bấm $name để hiện / ẩn widget."
                $script:hotNoteColor = $Green
                Update-HotkeyLabels
            } else {
                $script:hotNote = "$name đang bị Windows hoặc ứng dụng khác dùng, hãy thử tổ hợp khác."
                $script:hotNoteColor = $Orange
            }
            Show-PanelContent $true
        } elseif ($e.Key -eq 'Escape') {
            Dismiss-Widget
        }
    } catch { Write-Log "key: $($_.Exception.Message)" }
})

[DeviceWidget.Watcher]::Start()

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({ Invoke-Tick })
$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$jobTimer.Add_Tick({
    Invoke-Jobs
    if (-not $Snapshot) {
        try {
            if ($showEvt.WaitOne(0)) { Show-Widget }   # ai đó mở app lần nữa
            if ($exitEvt.WaitOne(0)) { Exit-App }      # trình cài đặt / gỡ cài đặt yêu cầu thoát
        } catch { Write-Log "events: $($_.Exception.Message)" }
    }
})

# phím tắt toàn hệ thống + khay
$hwnd = (New-Object Windows.Interop.WindowInteropHelper $win).EnsureHandle()
if (-not $Snapshot) {
    if ($cfg.DesktopMode) { [DeviceWidget.DesktopPin]::Pin($hwnd, $true) }
    [DeviceWidget.HotKey]::Attach($hwnd)
    [DeviceWidget.HotKey]::add_Pressed({ try { Toggle-Widget $false } catch { Write-Log "hotkey: $($_.Exception.Message)" } })
    $hotOk = Register-HotKey
    if ($isGlass) { [void][DeviceWidget.Glass]::Enable($hwnd, $true) }
    New-Tray
    Update-HotkeyLabels
    $hotName = Format-HotKey $cfg.HotMods $cfg.HotKey
    if (-not $hotOk) {
        $script:tray.ShowBalloonTip(6000, 'Device Widget',
            "Phím tắt $hotName đang bị ứng dụng khác dùng. Chuột phải biểu tượng này để đổi.", [Windows.Forms.ToolTipIcon]::Warning)
    } elseif ($Hidden -and -not $cfg.DesktopMode) {
        $script:tray.ShowBalloonTip(4000, 'Device Widget', "Đang chạy nền. Bấm $hotName để mở.", [Windows.Forms.ToolTipIcon]::Info)
    }
} else {
    Update-HotkeyLabels
}

$timer.Start(); $jobTimer.Start()

if ($Snapshot) {
    $win.Left = -5000
    $win.Show()
    Invoke-Tick
    if ($Panel) { Switch-Panel $Panel }
    $snapTimer = New-Object Windows.Threading.DispatcherTimer
    $snapTimer.Interval = [TimeSpan]::FromSeconds($(if ($Panel -eq 'wifi') { 9 } else { 4 }))
    $snapTimer.Add_Tick({
        $snapTimer.Stop()
        Invoke-Tick
        $win.UpdateLayout()
        $dpi = 120
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap(
            [int]($win.ActualWidth * $dpi / 96), [int]($win.ActualHeight * $dpi / 96), $dpi, $dpi,
            [Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win.Content)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
        Exit-App
    })
    $snapTimer.Start()
} elseif ($Hidden -and $cfg.DesktopMode) {
    Show-Widget $false          # chạy cùng Windows + đang ghim: hiện luôn trên desktop, không giành focus
} elseif ($Hidden) {
    [DeviceWidget.Watcher]::Paused = $true
} else {
    Show-Widget
}

[void]$app.Run()

# vừa đổi giao diện: mở lại ứng dụng
if ($script:restart) {
    $exe = Join-Path $here 'DeviceWidget.exe'
    if (Test-Path $exe) { Start-Process $exe } else { Start-Process (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $here 'Start-Widget.vbs') + '"') }
}
