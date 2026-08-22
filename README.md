# Decaid

> **Decaid** connects your Decent Espresso machine to beautiful,
modern user interfaces (called "skins").  
Think of it as the bridge between your
DE1 (or Bengle) and sleek touchscreen experiences like [Streamline.js](https://github.com/allofmeng/streamline_project).

**What it does:**

- Connects to your Decent Espresso machine via Bluetooth or USB
- Lets you control your machine through modern web-based interfaces
- Provides real-time shot data, temperatures, and pressure readings
- Works with scales to automatically stop shots at your target weight
- Runs on Android tablets, desktop computers, and more

**For developers:** Decaid provides
a complete REST and WebSocket API, making it
easy to build custom interfaces without dealing with the
complexity of machine communication and device connectivity.

## Table of Contents

- [Features](#features)
- [API Documentation](#api-documentation)
- [Supported Platforms](#supported-platforms)
- [WebUI / Skins](#webui--skins)
- [Supported Operations](#supported-operations)
- [Plugins](#plugins)
- [Documentation](#documentation)
- [Building](#building)
- [System Requirements](#system-requirements)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)

## Features

- **REST API** for machine control, settings, and shot management
- **WebSocket streams** for real-time updates (shot progress, weight, temperature)
- **Profile management** with content-based hashing and automatic deduplication
- **Auto-connect** to preferred devices on startup
- **Gateway modes** for flexible control delegation
- **Display control** — screen brightness and wake-lock management via API
- **Presence-based auto-sleep** with configurable timeouts and scheduled wake times
- **Plugin system** for extensibility
- **WebUI support** with multiple skins
- **Cross-platform** support (Android, macOS, Linux, Windows, iOS)

## API Documentation

To browse the complete API documentation:

1. Start Decaid
2. Navigate to [http://localhost:4001](http://localhost:4001)

Or:  

1. Change directory to `assets/api/` on your computer
2. Run `npx httpserver -p 4001` to start a http server in that folder
3. Navigate to `http://localhost:4001`  

The API provides:  

- **REST endpoints** on port `8080`
- **WebSocket streams** for real-time data
- **Plugin HTTP endpoints** for custom integrations

## Supported Platforms

| Platform | Status | Notes |
|----------|--------|-------|
| **Android** | ✅ Primary | Runs on Decent Espresso tablets |
| **macOS** | ✅ Full support | Desktop development and testing |
| **Linux** | ✅ Full support | ARM64 and x86_64 |
| **Windows** | ✅ Full support | Desktop operation |
| **iPad** | ✅ Full support | [Install to your iPad now with SideStep](https://decentespresso.com/downloads) |

### Background Operation

On Android, Decaid can run as a foreground service, maintaining stable connections to your machine and scale while tucked away in the background.

## WebUI / Skins

Similar to the original DE1 app, Decaid supports loading and displaying different "skins" (web-based UIs).

### Accessing Skins

- **Network access**: From any device on your local network at `http://<device-ip>:3000`
- **In-app WebView**: On supported platforms, use the embedded browser to access skins directly

### Android WebView Compatibility

**Note for Teclast tablets**: Some older Android System WebView versions may cause display issues with the in-app skin view.

**Solutions:**
1. Update Android System WebView from [APKMirror](https://www.apkmirror.com/apk/google-inc/android-system-webview/)
2. Restart your device after updating
3. Use an external browser if issues persist (the app will automatically detect incompatible WebViews)

## Supported Operations

### Machine Operations

- ✅ Query and control machine state (power on/off, start/stop espresso)
- ✅ Configure machine settings (temperatures, flow rates, timeouts)
- ✅ Upload v2 JSON profiles (compatible with DE1 app `profiles_v2` format)
- ✅ Real-time shot telemetry via WebSocket
- ✅ Advanced settings management

### Scale Operations

- ✅ Tare scale
- ✅ Real-time weight updates via WebSocket
- ✅ Auto-stop shots at target weight
- ✅ Power management (auto-disconnect/display-off when machine sleeps)

#### Supported Scales

- **Felicita Arc**
- **Decent Scale**
- **Bookoo Mini Scale**

### Workflow Management

- ✅ Create and save multi-step workflows
- ✅ Set target weight for automatic shot stopping
- ✅ Profile selection per workflow

### Display & Presence

- ✅ Screen brightness control (dim/restore) via REST and WebSocket
- ✅ Wake-lock management (keep screen on) with auto-cleanup
- ✅ User presence heartbeats with configurable auto-sleep timeout
- ✅ Scheduled wake times (e.g., warm up the machine every weekday at 6:30 AM)

### Additional Features

- ✅ **Auto-connect**: Set preferred devices for automatic connection on startup
- ✅ **Gateway modes**:
  - **Disabled**: Full local control
  - **Tracking**: Monitor and stop at target weight
  - **Full**: Complete remote control
- ✅ **Shot history**: Save and export shot data
- ✅ **Device simulation**: Test without physical hardware

## Plugins

Decaid features a JavaScript plugin system for dynamic functionality expansion.

**Capabilities:**
- React to machine state changes
- Make HTTP requests
- Store persistent data
- Emit custom events
- Serve custom HTTP endpoints

**Bundled Plugins:**
- `settings.reaplugin`: Web-based settings dashboard
- `time-to-ready.reaplugin`: Machine warm-up notifications
- `visualizer.reaplugin`: Real-time shot visualization

📖 **[Read the Plugin Development Guide →](doc/Plugins.md)**

## Documentation

In-depth guides and API references are available in the [`doc/`](doc/) directory:

| Document | Description |
|----------|-------------|
| [Skins.md](doc/Skins.md) | WebUI skin development guide — REST & WebSocket API reference, development workflow, deployment via GitHub Releases |
| [Plugins.md](doc/Plugins.md) | JavaScript plugin development — host API, event system, manifest structure, and examples |
| [Profiles.md](doc/Profiles.md) | Profiles API — content-based hash IDs, version tracking, import/export, and storage architecture |
| [DeviceManagement.md](doc/DeviceManagement.md) | Device discovery and connection management — transport abstraction, auto-connect logic, adding new device types |
| [RELEASE.md](doc/RELEASE.md) | Release process — Git tag workflow, GitHub Actions CI, versioning conventions |

## Building

### Prerequisites

- **Flutter SDK**: Version 3.7.0 or later
- **Platform-specific tools**:
  - Android: Android Studio / SDK
  - macOS: Xcode
  - Linux: Standard build tools
  - Windows: Visual Studio

### Development Build

The project includes a build script that injects version information from Git:

```bash
./flutter_with_commit.sh run
```

For standard Flutter builds:

```bash
flutter run
```

### Linux ARM64 (Docker/Colima)

Build for ARM64 tablets using containers:

```bash
# Start Colima with ARM64 profile
make colima-arm

# Build
make build-arm
```

For x86_64:

```bash
make colima-amd
make build-amd
```

Build both architectures:

```bash
make dual-build
```

For a systemd installation, order ReaPrime after BlueZ:

```ini
[Unit]
Wants=bluetooth.service
After=bluetooth.service
```

This reduces startup races but does not replace the application's Bluetooth recovery.

## System Requirements

### Minimum Requirements

- **Android**: 9.0 (API 28) or later
- **macOS**: 13.0 or later
- **iOS**: 15.0 or later (experimental)
- **Linux**: Modern distribution with GTK 3.0+
- **Windows**: Windows 10 or later (the release ZIP bundles the Visual C++ runtime; no separate redistributable install is needed)

### Recommended

- **RAM**: 2GB+ available
- **Storage**: 500MB for app + skins
- **Network**: Local WiFi network for skin access
- **Bluetooth**: Bluetooth 4.0+ for device connectivity

## Troubleshooting

### WebView Issues (Android)

**Problem**: Blank screen or rendering artifacts in skin view

**Solutions**:
1. Update Android System WebView
2. Clear app data and restart
3. Use external browser option (Settings → Auto-detected)

### Connection Issues

**Problem**: Cannot connect to machine or scale

**Solutions**:
1. Verify Bluetooth is enabled
2. Check device permissions (Location, Bluetooth)
3. Try "Scan Again" in device selection
4. Check if device is already connected to another app

### Auto-Connect Not Working

**Problem**: Preferred device doesn't auto-connect

**Solutions**:
1. Verify device ID is correct (Settings → Auto-Connect Device)
2. Ensure device is powered on during scan
3. Clear and re-set preferred device
4. Check logs for connection errors

### API Not Accessible

**Problem**: Cannot reach API at localhost:8080

**Solutions**:
1. Verify app is running
2. Check firewall settings
3. On network access: use device's local IP instead of localhost
4. Check port 8080 is not in use by another application

## About the Name

**Decaid** (formerly REA → ReaPrime → Streamline Bridge) is the companion app for Decent Espresso machines.

### The Evolution

The original name **REA** stood for "Reasonable Espresso App" — a tongue-in-cheek reference to brewing something "reasonably decent" with a Decent Espresso machine. As the project evolved through **ReaPrime** and **Streamline Bridge**, it eventually became **Decent.app**.

In 2026, ten years after the first commit to the original **de1app** repository on May 14, 2016, we renamed the app **Decaid**. The name commemorates that decade of Decent Espresso history while capturing the app's purpose: it **aids** you in making *decent* espresso.

- **Internal identifiers** remain unchanged (`reaprime` Dart package, `net.tadel.reaprime` bundle ID, `streamline_bridge` database, and `.reaplugin` extension) to avoid breaking existing integrations.
- **Display name** is **Decaid** on all platforms. On macOS, Finder displays the application bundle as **Decaid.app**; use **Decaid** in prose.

## Credits

### Acknowledgments

- **[@randomcoffeesnob](https://github.com/randomcoffeesnob)**: Original name inspiration and ongoing support
- **[@mimoja](https://github.com/mimoja)**: [First Flutter app](https://github.com/Mimoja/flupresso) version
- **Decent Espresso community**: Testing, feedback, and feature requests

### License

This project is licensed under the GNU General Public License v3.0 (GPL-3.0).

See the [LICENSE](LICENSE.txt) file for details.

---

**Need help?** Check our [documentation](/doc) or open an [issue](https://github.com/decentespresso/decaid/issues).


