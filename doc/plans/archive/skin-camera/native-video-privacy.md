# Apple Native Video Capture Privacy

## Cause

PR #939's iPhone crash report confirms a TCC privacy kill. WKWebView's native
video file-input picker configures an audio input, but the app has no
`NSMicrophoneUsageDescription`. This picker bypasses the Dart live-camera gate.
The pinned macOS plugin uses NSOpenPanel for file inputs; the report does not
establish a macOS crash from the same interaction.

## Decision

Add a microphone usage description to the iOS app plist. A usage description
does not grant permission. iOS can ask for microphone permission when a user
chooses native video recording, and the recording can include audio after that
permission is granted. Keep live WebView microphone and combined requests
denied. Leave onboarding, permission-handler opt-ins and macOS audio-input
entitlements unchanged. The macOS file picker does not record video, so macOS
does not need a microphone usage description.

The user approved this tradeoff after considering camera-only native recording.
The pinned plugin cannot configure Apple's file-input recorder without audio.
Page-script restrictions would not provide a native permission boundary and
could restrict file imports.

## Verification

On Windows with Flutter 3.47.5 / Dart 3.13.4, the XML-based regression check
failed on the missing iOS microphone usage description before the fix. After
the fix, all six declaration and entitlement checks passed. The focused camera
suite passed 77 tests with zero error events and empty stderr. Formatting
checked 906 Dart files with zero changes; analysis reported no issues. The
dependency lockfile stayed unchanged. Test assets use the pinned external
plugins and the CI-style bundled-skin stub.

The full Flutter suite did not run: an existing Windows Decaid Test session
held the lab lock and ports 3000, 4001 and 8080. No approval to interrupt that
session was given. No Apple build or hardware verification was performed on
this Windows host. Apple hardware must verify native recording, microphone
denial and cancellation, and continued live-microphone denial. The manual audit
checklist includes these cases.

## Review Follow-Up

Review 5440542470 removed the unsupported macOS microphone description and
replaced the PowerShell-only helper with a standard-library Python plist test
wired into PR CI. Temporary CI jobs compiled unsigned iOS and macOS release
builds using the release workflow's toolchain and asset setup. Compilation
checks do not establish device permission behavior.

The unrelated user-script extraction was removed; host identity and simulated
device scripts remain in `skin_view.dart`. The stored setting is labelled
`Live camera access` because native file pickers are outside that policy.

Windows follow-up verification used Flutter 3.47.5 / Dart 3.13.4 and the exact
dependency lockfile. At that revision, the three Python privacy tests and both
unsigned symbol-upload checks passed; actionlint 1.7.12 found no workflow errors.
Formatting checked 905 files with zero changes and analysis reported no issues.
The full unmodified Flutter suite passed 4,658 tests with two skipped, zero
error events and empty stderr (`--concurrency=4`, exclusive lab lock, fixed
test ports free). Expected malformed-URI server logs were inspected. The
archive-path assertion was not modified for this run. The stored-setting label
fits 320/800 px widget surfaces at normal/doubled text size.

The first native CI attempt stopped before compilation because the release
Flutter SDK's five core package pins differ from the current lockfile. The
verification jobs used the release workflow's normal `flutter pub get`, leaving
the committed lockfile and camera-plugin versions unchanged.

Both native builds passed on `b5a500978388f09a64aadac9ae76c52256980606`
with Flutter 3.44.2, Xcode 26.3 and the release asset setup:

- [iOS unsigned release archive](https://github.com/decentespresso/decaid/actions/runs/37610433781/job/112757991859), using the supported Swift Package Manager configuration.
- [macOS unsigned release app](https://github.com/decentespresso/decaid/actions/runs/37610433781/job/112757991769).

Both jobs also passed the three Python privacy tests. All seven checks in
[that CI run](https://github.com/decentespresso/decaid/actions/runs/37610433781)
passed. No Apple simulator or hardware runtime acceptance is claimed.

## CI Scope Follow-Up

At the user's request, removed the temporary Apple build jobs and their change
detection from normal PR CI. Retained the Python privacy/configuration check
and the successful native compilation results above as PR-specific evidence.
Restored the symbol-upload script's pre-verification behavior by removing the
unsigned-build bypass. This camera fix does not establish a repository-wide
Apple build policy or change release symbol uploads. The macOS microphone
description and audio-input entitlement remain absent: the pinned file-input
delegate only presents NSOpenPanel, and live microphone/combined requests
remain denied.
