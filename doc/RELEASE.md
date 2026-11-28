# Release Guide

This document describes how to create releases for Decaid.

## 0.9.3 upgrade: extension-management protection becomes opt-in

Decaid 0.9.2 gated plugin and skin management on an `extensions:manage` API
token for every caller. 0.9.3 reverses that default: the management API is open
again to any client that can reach the device, including other machines on the
LAN such as Home Assistant and MCP clients, and the token gate now sits behind a
native **Settings → Security → "Require authorization for extension
management"** switch that ships **OFF** for new installations **and** for
upgrades.

The 0.9.3 release notes have to lead with this, in this order:

1. **What changed.** Upgrading removes the always-on protection 0.9.2 shipped,
   in both new and existing installations.
2. **What it means while the switch is off.** Anyone who can reach the
   management API on the device's network, or a plugin allowed to call it, can
   install, modify, approve and remove extensions, approve permission
   escalations and change extension settings. It is an explicit compatibility
   tradeoff, not a security claim.
3. **What to do.** Open Settings → Security, turn the switch on for a shared or
   café device, and restrict network access to the device. The café hardening
   and provisioning guide is
   [`doc/deployment/cafe-provisioning.md`](deployment/cafe-provisioning.md).
4. **What is separate.** The switch covers extension management only. Tokens
   travel over plain HTTP on port 8080, so they are readable on a hostile LAN;
   HTTPS is issue #925 and optional full REST/WS authentication is issue #1135.

`fastlane/metadata/en-US/release_notes.txt` carries the same points for the App
Store listing. The reference text is `doc/Api.md` ("Extension management
authorization") and `doc/Plugins.md` ("Authorization").

## Creating a Release

Decaid uses git tags to trigger automatic releases. When you push a tag, GitHub Actions will:
1. Build all supported platforms
2. Export the iOS archive for TestFlight
3. Package the macOS DMG and Linux AppImages, and bundle the VC++ runtime into the Windows ZIP
4. Generate release notes from merged pull requests using GitHub's release-notes generator
5. Attach every artifact plus a SHA-256 checksum manifest to a GitHub release

## Desktop Artifacts

Each tagged release attaches these desktop files (plus the Android APK and unsigned iOS IPA):

| Platform | Artifact | Install |
| --- | --- | --- |
| macOS (Intel + Apple Silicon) | `decaid-macos-<tag>.dmg` | Open the DMG and drag Decaid to Applications. Signed and notarized. |
| macOS (portable / auto-update) | `decaid-macos-<tag>.zip` | Extract and run `Decaid.app`; also the Sparkle auto-update payload. |
| Windows x64 | `decaid-windows-x64-<tag>.zip` | Extract the whole ZIP and run `Decaid.exe`. Portable and unsigned; the VC++ runtime is bundled. |
| Linux x86_64 | `decaid-linux-x86_64-<tag>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux ARM64 | `decaid-linux-aarch64-<tag>.AppImage` | `chmod +x` and run. No installation needed. |
| Linux portable | `decaid-linux-x64-<tag>.tar.gz`, `decaid-linux-arm64-<tag>.tar.gz` | Extract and run `decaid` from the bundle directory. |

`<tag>` is the full git tag, including its leading `v`: tag `v0.9.4` publishes
`decaid-android-v0.9.4.apk`, `decaid-macos-v0.9.4.zip`, `decaid-macos-v0.9.4.dmg`,
`decaid-windows-x64-v0.9.4.zip`, `decaid-linux-x64-v0.9.4.tar.gz`,
`decaid-linux-x86_64-v0.9.4.AppImage`, `decaid-linux-arm64-v0.9.4.tar.gz`,
`decaid-linux-aarch64-v0.9.4.AppImage` and `decaid-ios-unsigned-v0.9.4.ipa`; a beta tag keeps
the whole tag, so `v0.9.4-beta.1` publishes `decaid-macos-v0.9.4-beta.1.zip`. Only filenames carry
the tag: release titles, app versions and channel selection keep the bare `MAJOR.MINOR.PATCH`
version. Releases published before #1240 kept the bare version in their filenames; those assets
are not renamed and stay downloadable from their own tag.

All files are covered by `decaid-<tag>-SHA256SUMS.txt` in the release.

Every file also ships as a `-latest` alias (`decaid-android-latest.apk`, `decaid-macos-latest.dmg`, `decaid-linux-x86_64-latest.AppImage`, ...), so `https://github.com/decentespresso/decaid/releases/latest/download/decaid-android-latest.apk` always points at the newest stable release. Aliases never include a version. The aliases are covered by `decaid-latest-SHA256SUMS.txt`.

### Verifying checksums

```bash
# macOS / Linux
curl -sL -O https://github.com/decentespresso/decaid/releases/download/<tag>/decaid-<tag>-SHA256SUMS.txt
shasum -a 256 -c decaid-<tag>-SHA256SUMS.txt --ignore-missing
# download every artifact into the same directory first, or use --ignore-missing
```

```powershell
# Windows PowerShell
curl.exe -L -O https://github.com/decentespresso/decaid/releases/download/<tag>/decaid-<tag>-SHA256SUMS.txt
Get-FileHash decaid-windows-x64-<tag>.zip -Algorithm SHA256
# compare the hash against the manifest entry
```

### AppImage notes

- Optional desktop integration (menu entry, icon) is handled by AppImageLauncher or `appimaged` when installed; the AppImage itself always runs standalone.
- On systems without FUSE, run `./decaid-linux-<arch>-<tag>.AppImage --appimage-extract-and-run` instead.
- Removal is deleting the file; the app stores its data under `~/.local/share` (or `$XDG_DATA_HOME`).

### Windows notes

The Windows build is unsigned, so a clean machine may show an unknown-publisher warning when `Decaid.exe` is first launched. There is no installer; the ZIP is portable. Decaid stores user data and logs under `%APPDATA%`, not in the extraction folder, so deleting the extracted folder does not remove them.

### Dry-run validation before tagging

`Create Release` also accepts `workflow_dispatch`, which builds every platform job and then stops: `create-release` and `publish-appcast` are guarded by `if: github.event_name == 'push'`, so a dispatch never creates a release, uploads assets to one, or touches the `gh-pages` appcast feed. This is the way to validate a change to the workflow itself, or a new action/runtime version, without cutting a tag.

Dispatch it on the branch that contains the workflow change and pass an optional `version` label (default `0.0.0-dryrun`). The job synthesizes the tag by prefixing `v` when the label does not already have one, so the dry run produces the same filenames a tag push would:

```bash
gh workflow run "Create Release" --ref <branch> -f version=0.0.0-dryrun
gh run watch "$(gh run list --workflow "Create Release" --limit 1 --json databaseId --jq '.[0].databaseId')"
```

The dry run exercises the build jobs, so it costs the same runner time as a real release. The tag push remains the only path that publishes.

### Step 1: Tag Your Release

```bash
# For a stable release
git tag v1.0.0
git push origin v1.0.0

# For a beta release (will be marked as pre-release)
git tag v1.0.0-beta.1
git push origin v1.0.0-beta.1

# For an alpha release (will be marked as pre-release)
git tag v1.0.0-alpha.1
git push origin v1.0.0-alpha.1
```

### Step 2: Monitor the Build

1. Go to https://github.com/decentespresso/decaid/actions
2. Watch the "Create Release" workflow
3. Wait for it to complete (usually 5-10 minutes)

### Step 3: Verify the Release

1. Go to https://github.com/decentespresso/decaid/releases
2. Your new release should appear with all platform artifacts attached
3. Download and test the relevant artifacts
4. On an Android or iOS device, run a bulk de1app import (a few hundred shots)
   and watch for dropped frames. The import parses on the UI isolate; host
   figures are in `test/import/de1app_parse_benchmark_test.dart`, but no device
   measurement has been taken. If frames drop, the parse loop is what to move
   to a worker isolate.

## Version Numbering

Decaid follows [Semantic Versioning](https://semver.org/):

- **MAJOR.MINOR.PATCH** (e.g., `v1.2.3`)
  - **MAJOR**: Breaking changes or major new features
  - **MINOR**: New features, backwards compatible
  - **PATCH**: Bug fixes, backwards compatible

### Pre-release Versions

- **Beta**: `v1.0.0-beta.1` - Feature complete, testing phase
- **Alpha**: `v1.0.0-alpha.1` - Early testing, incomplete features
- **RC**: `v1.0.0-rc.1` - Release candidate, final testing

## Update Channels

The app's update system recognizes these channels:

- **Stable**: Only final releases (v1.0.0, v2.1.0, etc.)
- **Beta**: Pre-releases and beta tags (v1.0.0-beta.1, etc.)
- **Development**: All releases including alphas

Pre-releases are automatically detected by:
- Version suffix (beta, alpha, rc)
- GitHub's pre-release flag

## macOS Auto-Update (Sparkle)

macOS builds check for updates through [Sparkle](https://sparkle-project.org) against a signed
appcast at `https://decentespresso.github.io/decaid/appcast.xml`. The feed is generated from the
same GitHub release ZIPs the manual flow publishes, so a tag push publishes both the release and
the feed.

### One-time setup (required before the first Sparkle-enabled release)

1. On a trusted Mac, generate the EdDSA keypair with Sparkle 2.9.5's `generate_keys`:
   ```bash
   curl -sL -o /tmp/Sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz
   tar -xJf /tmp/Sparkle.tar.xz -C /tmp bin
   /tmp/bin/generate_keys
   ```
   It prints the `SUPublicEDKey` value; the private key is stored in the login keychain.
2. Put the printed value in `SUPublicEDKey` in `macos/Runner/Info.plist` (keep it in sync with the
   private key below).
3. Export the private key from the keychain and store it as the GitHub Actions secret
   `SPARKLE_ED_PRIVATE_KEY`:
   ```bash
   security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w \
     | gh secret set SPARKLE_ED_PRIVATE_KEY
   ```
   (A keychain permission prompt appears once.) The appcast job fails fast until the secret and
   `SUPublicEDKey` match.
4. Enable GitHub Pages for `decentespresso/decaid`: Settings > Pages > Source: **Deploy from a
   branch** > branch `gh-pages` > folder `/ (root)`. The `publish-appcast` job maintains that
   branch.
5. First release only — bootstrap the feed by setting the repo variable
   `SPARKLE_APPCAST_BOOTSTRAP=true` (Settings > Secrets and variables > Actions > Variables),
   push the first Sparkle-enabled tag, then delete the variable. The publish job fails fast with
   instructions until the feed exists; the variable is the explicit one-time escape hatch.
6. Verify `https://decentespresso.github.io/decaid/appcast.xml` is publicly reachable.

### What a tag push publishes

1. All platform builds, signed + notarized as before, plus the DMG wrapping the notarized app. macOS uses Developer ID signing of Sparkle's
   nested helpers deepest-first (never `codesign --deep` — see `scripts/sign_macos_deepest_first.sh`)
   and runs `scripts/verify_macos_signature.sh` before and after notarization.
2. `create-release` attaches the artifacts, then `publish-appcast` (macOS runner):
   - reads the currently deployed feed from the **`gh-pages` branch through git** (not the Pages
     CDN), so a transient Pages/TLS failure is never mistaken for a first publication;
   - downloads `decaid-macos-<tag>.zip` from the release;
   - downloads Sparkle 2.9.5's tools with a pinned SHA-256 check;
   - reads `CFBundleVersion` from the ZIP and refuses to publish unless it is strictly greater than
     every item already in the feed (see the version policy below);
   - runs `generate_appcast` with the `SPARKLE_ED_PRIVATE_KEY` secret, embedding the GitHub release
     notes;
   - asserts the feed grows by exactly one item (one more default-channel item for a
     stable publication) and that every old (version, channel) pair survives — a beta
     publication can never erase stable or historical items;
   - validates the feed with `xmllint` + `scripts/appcast_helpers.sh` assertions;
   - commits `appcast.xml` to the `gh-pages` branch, which Pages serves.

Beta/alpha/rc tags publish feed items with `<sparkle:channel>beta</sparkle:channel>`; stable tags
publish un-channelled (default) items. A Beta user sees Beta and Stable items; a Stable user sees
only default-channel items.

### Version policy for macOS

Sparkle compares `CFBundleVersion`, which `flutter_with_commit.sh` derives from the commit count of
`origin/main`. Every published macOS release must therefore have a strictly greater commit count
than the previously published macOS item — including beta-to-stable tags cut from the same commit.
The appcast job rejects equal or lower values rather than publishing an update Sparkle cannot
select. Keep `CFBundleShortVersionString` as `MAJOR.MINOR.PATCH` (no `-beta.N` suffix); prerelease
identity lives in the Beta channel and release title.

### Rollback

To stop offering an update: remove or fix the latest appcast item (the feed redeploys without
rebuilding the app). Keep the GitHub ZIP available for manual installation. Never replace a signed
archive in place under the same appcast version; publish a corrected release with a strictly higher
`CFBundleVersion`. Do not rotate the EdDSA key and the Developer ID identity in the same update.

### Testing a macOS update locally

1. Build a release ZIP and generate a feed with `scripts/publish_appcast.sh` (see its usage); a
   temporary keypair works for local testing as long as `SUPublicEDKey` matches.
2. Install the older build in `/Applications`, launch once, then check Settings > Check for updates.
3. Confirm data/settings survive the relaunch and the bundle ID is unchanged.

### Acceptance gate: notarized two-build update (required before the first public Sparkle release)

The full procedure lives in `doc/plans/archive/521-macos-auto-update-sparkle/` (Phase 4). Use two
Developer-ID-signed, notarized builds with increasing `CFBundleVersion` values and a temporary
signed feed:

1. Install the older build in `/Applications` and launch it once.
2. Stable channel: publish a Beta item only; a manual check must report no Stable update.
3. Switch to Beta; a manual check must offer the Beta update.
4. Accept it; verify download, sandboxed XPC installation, relaunch, the new build number, the
   same bundle ID, the same application data, and retained settings.
5. Publish a newer Stable item; both channels must offer it.
6. Tamper with one byte of the ZIP; Sparkle must reject it before extraction.
7. Sign an archive with a different EdDSA key or app-signing identity; Sparkle must reject it.
8. Disable automatic checks, relaunch, and confirm no scheduled check occurs; a manual check must
   still work.

Do not close #521 until the baseline-to-newer-build update has been demonstrated with
production-equivalent signatures. The first public Sparkle-enabled release is a baseline: older
Decaid builds cannot self-update into it.

## Editing Release Notes

The workflow publishes GitHub's generated release notes. After the release is created, review them and edit the release when a shorter summary, screenshots, upgrade instructions, or corrections are needed.

## Workflow Files

- **`.github/workflows/release.yml`**: Builds and publishes releases on tag push
- **`.github/workflows/develop-builds.yml`**: Development builds on main branch

### Development Artifacts

Development builds use stable GitHub Actions artifact names, while the packaged filename includes the seven-character commit SHA:

| Platform | Actions artifact | Downloaded file |
| --- | --- | --- |
| Android | `decaid-android-develop` | `decaid-android-develop-<short-sha>.apk` |
| macOS | `decaid-macos-develop` | `decaid-macos-develop-<short-sha>.zip` |
| Linux x64 | `decaid-linux-x64-develop` | `decaid-linux-x64-develop-<short-sha>.tar.gz` |
| Linux ARM64 | `decaid-linux-arm64-develop` | `decaid-linux-arm64-develop-<short-sha>.tar.gz` |
| Windows x64 | `decaid-windows-x64-develop` | `decaid-windows-x64-develop-<short-sha>.zip` |
| iOS unsigned | `decaid-ios-unsigned-develop` | `decaid-ios-unsigned-develop-<short-sha>.ipa` |

Tagged release artifacts use the same `decaid-<platform>` prefix without `-develop`. Development workflow artifacts are retained build outputs, not GitHub Releases or prereleases by themselves.

## Testing Before Release

```bash
# Build locally to test
./flutter_with_commit.sh build apk --release

# Check the version is correct
./flutter_with_commit.sh run
# Open Settings and verify version number
```

### DE1 firmware validation scope (#1103)

Release validation notes must distinguish the managed firmware no-replay policy
from raw firmware writes, which may still reconnect and replay once after a BLE
timeout. The #1103 Android BLE/ESP32 emulator checks used synthetic faults after
successful real writes; physical DE1 firmware flashing and naturally lost
acknowledgements remain unverified. Do not describe emulator results as proof of
production bootloader safety. Physical DE1 checks require separate operator
authorisation. See the [policy rationale, proposed raw-write follow-up and
validation limits](plans/archive/1103-firmware-write-replay/README.md).

## Troubleshooting

### Release Failed to Build
- Check GitHub Actions logs for errors
- Ensure all tests pass locally
- Verify secrets are configured (ANDROID_KEYSTORE_B64)

### APK Not Attached to Release
- Check the workflow completed successfully
- Verify the APK was built (check workflow artifacts)
- Ensure GITHUB_TOKEN has `contents: write` permission
- Check that GitHub's release-notes generator returned a non-empty response

### Wrong Version Number
- Verify your tag follows the format `vX.Y.Z`
- Check `flutter_with_commit.sh` extracts version correctly
- Rebuild with correct tag

## iOS / TestFlight

iOS builds are uploaded to TestFlight automatically on tag push, running as an independent CI job (`build-ios`) alongside the other platform builds.

### Local TestFlight Upload

To build and upload an IPA locally:

```bash
./flutter_with_commit.sh build ipa --release
```

Then upload via Xcode Organizer (Window → Organizer → Distribute App → TestFlight & App Store).

### CI/CD

The `build-ios` job in `.github/workflows/release.yml`:
1. Builds one unsigned Xcode archive and packages an unsigned IPA for the GitHub Release
2. Exports that archive with the Apple Distribution certificate and App Store provisioning profile
3. Uploads the signed IPA to TestFlight via the App Store Connect API

The unsigned IPA is intended for self-signing and sideloading; it cannot be installed directly.

### App Store Listing

Listing text and screenshots live in `fastlane/` and are pushed with a manual
`fastlane deliver` run; CI only ships builds to TestFlight. See
`fastlane/README.md` for the commands, screenshot sizes, and API key setup.

Required secrets: `APPLE_DISTRIBUTION_CERTIFICATE_P12`, `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_B64`, `IOS_PROVISIONING_PROFILE_NAME`, `APP_STORE_CONNECT_API_KEY_ID`, `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_KEY_P8`, `TEAM_ID`.

### TestFlight Distribution

- **Internal testing**: Available immediately after processing (~10-30 min). Up to 100 testers (App Store Connect users).
- **External testing**: Requires App Review for first build per version. Up to 10,000 testers. Can use a public link.

## Future Enhancements

- [ ] Add release approval workflow
