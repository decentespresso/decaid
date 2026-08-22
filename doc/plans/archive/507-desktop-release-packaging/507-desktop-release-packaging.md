# Issue #507 — Desktop release packaging

## Revised contract

Tagged releases improve the desktop download experience:

- macOS: a signed, notarized universal DMG containing `Decaid.app` and an `/Applications` shortcut.
- Linux: self-contained x86_64 and ARM64 AppImages that require no installation or root access.
- Windows: retain the unsigned x64 portable ZIP, matching the `de1app` download, extract, and launch flow.
- Keep the existing macOS ZIP and Linux tarballs as alternate portable formats.
- Publish one SHA-256 manifest covering every release asset.

The Windows installer, Authenticode, SmartScreen, and unattended install/uninstall requirements are removed from #507. Windows signing can be proposed separately if it becomes necessary; it is not a closure gate for this issue.

## Reference findings

- `de1app` publishes Windows as `decent_win.zip`; users extract it and launch `DECENT.bat`. It does not provide the installer previously attributed to it.
- Decenza has an Inno Setup installer, but that is not the requested Windows experience and will not be copied.
- `de1app` demonstrates the expected macOS DMG shape: an application plus an Applications shortcut.
- Decaid already signs its universal macOS app deepest-first, verifies Sparkle helpers and entitlements, notarizes it, staples it, and passes Gatekeeper. The DMG must wrap that exact verified app without weakening this flow.
- `de1app` already publishes type-2 x86_64 and aarch64 AppImages. Decaid will follow that single-file delivery model, but it does not need `de1app`'s writable payload-copy workaround because Decaid already stores user data outside its application bundle.

## Published desktop artifacts

| Platform | Artifact | Role |
| --- | --- | --- |
| macOS universal | `decaid-macos-<version>.dmg` | Recommended drag-to-Applications install |
| macOS universal | `decaid-macos-<version>.zip` | Existing portable/Sparkle artifact |
| Windows x64 | `decaid-windows-x64-<version>.zip` | Unsigned portable build; extract and run `Decaid.exe` |
| Linux x86_64 | `decaid-linux-x86_64-<version>.AppImage` | Recommended portable build |
| Linux ARM64 | `decaid-linux-aarch64-<version>.AppImage` | Recommended portable build |
| Linux x64 | `decaid-linux-x64-<version>.tar.gz` | Existing portable archive |
| Linux arm64 | `decaid-linux-arm64-<version>.tar.gz` | Existing portable archive |
| All | `decaid-<version>-SHA256SUMS.txt` | Checksums for every attached release asset |

Existing Android and iOS release assets remain unchanged and are also included in the checksum manifest.

## Package designs

### Release metadata

Add a small `release-metadata` job to `.github/workflows/release.yml` that validates the `v*` tag once and exposes the original tag and release version without the leading `v`.

Make each build job depend on this job and remove its local tag-parsing step. Use the shared version output in artifact filenames, release title, and release notes. Keep the existing `flutter_with_commit.sh` build-number policy and assert that expected filenames exist before publication.

### macOS DMG

Extend `build-macos` after the existing app notarization and stapling gates:

1. Create a temporary DMG root with the stapled `Decaid.app` and an `Applications` symlink to `/Applications`.
2. Build `decaid-macos-<version>.dmg` with macOS's built-in `hdiutil`; do not add a third-party DMG tool or decorative background.
3. Sign the disk image with the existing Developer ID Application identity and a secure timestamp.
4. Submit the final DMG to `notarytool`, staple its ticket, and validate the staple and Gatekeeper assessment.
5. Mount the DMG read-only and verify the app, Applications link, Team ID, hardened runtime, host entitlements, and Sparkle helper signatures using `scripts/verify_macos_signature.sh` against the mounted app.
6. Copy the mounted app to a temporary Applications directory, execute its deterministic `--print-storage-paths` launch probe, remove it, and detach the image.
7. Upload the DMG beside the unchanged notarized ZIP. `publish-appcast` continues to consume only the ZIP.

### Windows portable ZIP

Keep `build-windows` installer-free and unsigned:

1. Preserve the current release bundle and filename.
2. Copy the Visual C++ x64 app-local runtime DLL set from the Visual Studio 2022 redist directory into the bundle before compression, so a clean machine does not require a separate prerequisite installer.
3. Expand the completed ZIP into a fresh directory and run the extracted `Decaid.exe --print-storage-paths`; fail if it exits unsuccessfully or required bundle/runtime files are absent.
4. Publish only the ZIP. There is no setup executable, Start menu entry, registry state, or uninstall test.

A manual clean-Windows check may encounter an unsigned-app warning. That warning is documented and is not an Authenticode or SmartScreen acceptance gate.

### Linux AppImages

Add `scripts/package_appimage.sh`, `linux/packaging/AppRun`, and `linux/packaging/net.tadel.reaprime.desktop`. The script accepts a Flutter bundle, canonical AppImage architecture (`x86_64` or `aarch64`), and output path, then stages:

```text
Decaid.AppDir/
├── AppRun
├── net.tadel.reaprime.desktop
├── decaid.png
├── .DirIcon
└── usr/lib/decaid/                complete Flutter bundle
```

`AppRun` launches the bundled `decaid` executable in place and forwards every argument; it does not copy application files into the user's data directory. Reuse `macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png` rather than add another icon copy. The desktop entry uses the reverse-DNS icon name and declares a non-terminal application.

Use an architecture-matched, pinned `linuxdeploy` release with its SHA-256 verified before execution. Have it inspect the Decaid executable and bundled plugin libraries, copy required non-base ELF dependencies into the AppDir, and emit a type-2 AppImage. Do not add a Dart packaging dependency or maintain a hand-written shared-library allowlist.

Pin the x86_64 runner to Ubuntu 22.04, matching the existing ARM64 runner baseline, because an AppImage cannot bundle glibc and must be built on the oldest supported base. Package each architecture in its native build job.

For both architectures, validate the desktop file, executable bit, runtime architecture, and extracted AppDir. Launch the completed file under Xvfb with `APPIMAGE_EXTRACT_AND_RUN=1` and `--print-storage-paths`, which exercises the actual AppImage without requiring FUSE in CI. Delete the copied file afterward; there is no package installation or uninstall state. Keep creating and uploading each existing tarball from the same Flutter bundle.

## Release assembly and documentation

In `create-release`:

1. Download build artifacts into one flat staging directory.
2. Assert all expected filenames are present, including recommended and alternate desktop variants.
3. Generate `decaid-<version>-SHA256SUMS.txt` over every staged artifact before adding the manifest itself.
4. Prepend concise, version-specific download guidance to GitHub's generated release notes: DMG for macOS, ZIP for Windows, and architecture-matched AppImage for Linux, with alternate portable archives clearly labelled.
5. Attach the staged files and checksum manifest to the release.

Update `doc/RELEASE.md` with the artifact matrix and user instructions:

- macOS: verify checksum, open DMG, drag Decaid to Applications, eject; ZIP remains the portable/Sparkle form.
- Windows: verify checksum with `Get-FileHash`, extract the whole ZIP, run `Decaid.exe`, and state plainly that the build is unsigned.
- Linux: select architecture, mark the AppImage executable, and run it without root; explain optional desktop integration, the `--appimage-extract-and-run` fallback when FUSE is unavailable, deletion as removal, and tarball extraction as the alternate format.
- Remove the stale checksum and multi-platform items from “Future Enhancements”.

Before implementation, edit #507's goal, scope, and acceptance criteria to match the revised Windows and Linux contracts.

## Test-first implementation order

1. **Acceptance contract:** revise #507 and add expected artifact names and smoke commands to this plan/PR description.
2. **AppImage red:** extend the existing PR Linux build smoke to call the not-yet-present packaging script, inspect the AppDir, and execute the result; then implement the script, launcher, and desktop entry until it passes.
3. **Release metadata:** add the shared metadata job and migrate build jobs one at a time.
4. **Linux release:** create and smoke-test both AppImages in their native architecture jobs while preserving both tarballs.
5. **Windows release:** add app-local VC++ runtime files, then test the completed ZIP by fresh extraction and execution.
6. **macOS release:** create, sign, notarize, staple, mount, verify, copy, launch, and remove the DMG payload after the existing app gates.
7. **Release assembly:** flatten artifacts, assert the artifact contract, generate checksums, and add the release-note header.
8. **Documentation:** update `doc/RELEASE.md`; no API, skin, plugin, profile, or device-management docs change.

## Verification gates

Before considering the implementation complete:

- `bash -n scripts/package_appimage.sh linux/packaging/AppRun`
- `desktop-file-validate linux/packaging/net.tadel.reaprime.desktop`
- `dart format lib test`
- relevant packaging/build smoke jobs
- `flutter analyze`
- `flutter test`
- a disposable prerelease tag exercises the complete release workflow without replacing an existing release asset
- manual macOS DMG install/first launch/removal on a quarantined download
- manual Windows clean extraction and launch from the official unsigned ZIP
- manual AppImage launch/removal on x86_64 Linux and an ARM64 Raspberry Pi
- one manual x86_64 launch on a non-Ubuntu distribution to check portability
- checksum verification on macOS/Linux and Windows

Application-data relocation remains out of scope under #445/#508. Debian packages, Flatpak, Snap, Microsoft Store, Mac App Store, Windows setup executables, Windows signing, and desktop auto-update changes are also out of scope.
