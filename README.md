# Device Widget

An iOS / macOS Control Center–style widget for **Windows 10 and 11**. Press **Ctrl + Alt + D** anywhere to see, at a glance, what's connected and what's active on your PC — and change it with one click.

No installation of extra runtimes, no admin rights: it's built on PowerShell + WPF and the .NET Framework that already ships with Windows.

## Features

**Status tiles** — always visible, click any tile to open its panel:

| Tile | Shows | Click to |
|---|---|---|
| Wi-Fi | Network name and signal strength | Scan, connect (with password), disconnect, turn Wi-Fi on/off |
| LAN | "Connected" + link speed (e.g. 1 Gbps) as soon as a cable is plugged in | See adapter name, IP and MAC address |
| Bluetooth | Number of connected devices | Turn Bluetooth on/off, see paired devices |
| Headphones | Bluetooth / USB headset status and battery | Connect / disconnect Bluetooth audio |
| Mouse / Keyboard | Bluetooth or 2.4 GHz USB receiver, battery level | See device details |
| Mic / Speaker | Whether an app is using the mic, current volume | Pick the default device, mute |
| Camera | Whether an app is using the webcam (and which one) | See camera details |
| CPU / RAM / Disk / Battery | Usage, free space, charge | See system details |

- **Customizable tiles** — add, remove and reorder tiles (pencil button in the header).
- **Brightness and volume sliders** — brightness works on laptops and on external monitors that support DDC/CI.
- **Music player** — shows the current track from Spotify, browsers, etc., with play / pause / next / previous.
- **Live network speed** (MB/s down / up) in the header.
- **Liquid Glass theme** — optional frosted-glass look, light and dark.
- **Pin to desktop** — keep the widget on the desktop like a gadget (survives Win + D).
- **Configurable hotkey**, tray icon, start with Windows, single instance.
- Light: about 0–3 % CPU, and polling pauses while the widget is hidden.

## Requirements

- Windows 10 version 1809 (build 17763) or later, or Windows 11
- .NET Framework 4.x and Windows PowerShell 5.1 (both included with Windows)

## Install

1. Download `DeviceWidget-<version>.zip` from the [Releases](../../releases) page.
2. Right-click the zip → **Extract All** (don't run it from inside the zip).
3. Double-click **`DeviceWidget-Setup.exe`**.
   - If SmartScreen says *"Windows protected your PC"*, click **More info → Run anyway** (the installer isn't code-signed).
   - If `.exe` files are blocked on your PC, open the `Cai-thu-cong` (manual install) folder and double-click **`Install.cmd`** instead.

The app installs per user into `%LOCALAPPDATA%\Programs\DeviceWidget`, adds **Device Widget** to the Start Menu and Desktop, and appears in *Settings → Apps* for uninstalling.

### Install from source

Clone or download this repository, then double-click `Install.cmd` (or run):

```powershell
powershell -ExecutionPolicy Bypass -File Install.ps1
```

## Usage

- **Ctrl + Alt + D** — show / hide the widget (change it from the right-click menu).
- **Click a tile** — open its panel. **Esc** closes the panel or the widget.
- **Right-click** the widget or the tray icon for options: hotkey, pin to desktop, auto-hide, always on top, Liquid Glass, start with Windows, exit.
- After **Exit**, reopen it from the Start Menu or the Desktop shortcut.

The first launch takes roughly 10–15 seconds while PowerShell loads; after that the widget runs in the background and the hotkey responds instantly.

## Build the installer

```powershell
powershell -ExecutionPolicy Bypass -File Build-Package.ps1
```

This creates in `dist\`:

- `DeviceWidget-Setup.exe` — self-extracting installer (built with Windows' own IExpress)
- `DeviceWidget-<version>.zip` — the setup, the guide and a manual-install folder, ready to share
- `DeviceWidget.zip` — source files only

## Project structure

| File | Purpose |
|---|---|
| `DeviceWidget.ps1` | Main app: WPF UI, tiles, panels, themes, hotkey, tray icon |
| `DeviceStatus.cs` | Backend compiled at first run: Bluetooth, Core Audio, Wi-Fi / radios, brightness (DDC/CI + WMI), media session, system stats, window helpers |
| `Launcher.cs` | Source of `DeviceWidget.exe`, compiled during install so Windows Search finds the app |
| `Start-Widget.vbs` | Fallback launcher without a console window |
| `Install.ps1` / `Install.cmd` | Per-user installer |
| `Uninstall.ps1` | Uninstaller (used by *Settings → Apps*) |
| `Build-Package.ps1` | Builds the setup EXE and zip packages |
| `HUONG-DAN.txt` | Install guide in Vietnamese |

Settings are stored in `%APPDATA%\DeviceWidget\settings.json`.

## Notes

- Only devices the PC actually has are shown (Wi-Fi, Bluetooth, webcam…).
- For external monitors, enable **DDC/CI** in the monitor's on-screen menu to use the brightness slider.
- Liquid Glass uses the Windows 10 blur-behind effect, so it looks close to iOS but without light refraction.

## License

[MIT](LICENSE)
