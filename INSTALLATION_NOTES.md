# Decaid macOS Installation - Status & Workarounds

## Current Status

Successfully installed and configured:
- ✅ Flutter SDK 3.47.2 (stable, arm64)
- ✅ All Dart dependencies resolved (117 packages)
- ✅ All git-backed pubspec overrides cloned to `./external_repos/`
- ✅ All decentespresso GitHub org repos cloned to `~/github/decentespresso/`
- ✅ A-Flow profiles located at `assets/defaultProfiles/A-Flow____*.json` (5 variants)

Blocked:
- ❌ **macOS native build** — Requires CocoaPods, which requires Homebrew + Ruby 3+ (your system has Ruby 2.6)
- ❌ **Web platform** — Can't compile because `dart_js` and `libserialport` depend on `dart:ffi` (not available on web)
- ❌ **CocoaPods installation** — Blocked because:
  - System Ruby 2.6 is too old (ffi gem requires Ruby >= 3.0)
  - Homebrew installation requires interactive sudo approval
  - No alternative Ruby version available (rbenv/rvm not installed)

## Solutions

### Option A: Grant Sudo for Homebrew (Recommended)
The fastest solution is to enable sudo access once, then Homebrew and CocoaPods install automatically.

**Steps:**
1. In Terminal, run: `sudo -l` (authenticate once if needed)
2. Then re-run the Flutter build:
   ```bash
   cd /Users/prm/mcp-servers/copilot-worktrees/decaid/paulmersky-verbose-train
   export PATH="$HOME/flutter/bin:$PATH"
   
   # Install Homebrew (interactive, requires sudo)
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   
   # Add brew to PATH
   export PATH="/opt/homebrew/bin:$PATH"
   
   # Install CocoaPods via Homebrew
   brew install cocoapods
   
   # Run the app in simulation mode
   flutter run -d macos --dart-define=simulate=1
   ```

### Option B: Use Linux Release Build (via Docker)
Docker image can build Linux release binary without CocoaPods.

**Prerequisites:**
- Docker must be running

**Steps:**
```bash
cd /Users/prm/mcp-servers/copilot-worktrees/decaid/paulmersky-verbose-train
make dual-build  # Builds Linux release in Docker
```

Result: Binary at `build/linux/x64/release/bundle/` (can be copied to Linux machine or run in WSL2 on Windows)

### Option C: Use Android Device (if available)
If you have an Android phone or emulator, Flutter can run there:

```bash
export PATH="$HOME/flutter/bin:$PATH"
flutter run -d android --dart-define=simulate=1
```

Requires: Android SDK, device USB debugging enabled, or Android emulator running.

### Option D: Manual CocoaPods via rbenv (Advanced)
Install Ruby 3+ manually without Homebrew using rbenv (GitHub Copilot can help automate this if you prefer).

---

## A-Flow Profile Editor Access

Once the app launches in any platform (macOS, Linux, Android, or web—when FFI issues are resolved):

1. Open the app
2. Navigate to **Profiles** menu
3. Select **A-Flow** profile
4. Profile editor UI opens—make changes and save

A-Flow profiles bundled with the app:
- `A-Flow____default-dark.json`
- `A-Flow____default-light.json`
- `A-Flow____default-medium.json`
- `A-Flow____default-very-dark.json`
- `A-Flow____default-like-dflow.json`

Profiles are JSON files stored in `assets/defaultProfiles/`. No custom editor tool needed—UI is built into the app.

---

## Repository Structure

```
~/github/decentespresso/          # All org repos (cloned)
  ├── decaid/                      # Main app (current worktree)
  ├── openscale/
  ├── de1app/
  ├── streamline-js/
  ├── insight-js/
  ├── shot-upload/
  ├── dye2/
  ├── tasmota-auto-doser/
  └── [additional 19 repos]

./external_repos/                  # Git-backed pubspec dependencies (cloned)
  ├── universal_ble/
  ├── flutter_libserialport/
  ├── libserialport/
  ├── dart_js/
  ├── flutter_inappwebview/
  └── usbserial_dart/
```

---

## Next Steps

**Recommended immediate action:**
1. Run `sudo -l` in Terminal to enable sudo (one-time approval)
2. Then proceed with **Option A** above to install Homebrew/CocoaPods
3. Once CocoaPods installs, `flutter run -d macos --dart-define=simulate=1` should launch the app

After app launches:
- Verify simulation mode works (simulated espresso machine, scales, etc.)
- Navigate to Profiles → A-Flow to access the profile editor
- Test profile creation/modification/export

---

## Troubleshooting

**Q: "CocoaPods not installed" error on macOS**
→ Follow Option A above (Homebrew + CocoaPods via sudo)

**Q: "dart:ffi not available" on web**
→ Web platform is not supported for this app (uses native FFI bindings). Use macOS, Linux, or Android instead.

**Q: Spark/SPM dependency errors during build**
→ Already fixed in this session (regenerated macOS platform, removed Sparkle).

**Q: Missing plugin files (dye2.reaplugin, shot-upload.reaplugin)**
→ These are optional plugins. If not present, the app still runs in simulation mode. They can be added later.

---

## Manual Commands Reference

```bash
# View all local repos
ls -la ~/github/decentespresso/
ls -la ./external_repos/

# Check Flutter setup
export PATH="$HOME/flutter/bin:$PATH"
flutter doctor
flutter pub get

# Clean and rebuild
flutter clean

# Run in simulation mode (requires CocoaPods on macOS)
flutter run -d macos --dart-define=simulate=1

# Analyze code
flutter analyze

# Run tests
flutter test
```

---

## Questions?

Refer to:
- `doc/AI_BUILD_NOTES.md` — Build, flash, simulate, platform quirks
- `doc/AI_REPO_MAP.md` — Fast file routing
- `CONTRIBUTING.md` — Contributing guidelines
