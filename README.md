# Verification evidence — issues #913, #912, #1195 and #1141

Evidence only; this branch is not an implementation branch and must not be merged into main.

## Onboarding #1141

Tested implementation commit: `aa458f640a7323f99ed752a2fa1803cef106dbde`.
Candidate: `dd37278b94143de1e9a0ca3da5072800266938835df0fe6aee9d3f2aacb5ada1`.
APK SHA256: `733895e14d67a20a567915e4b3d149ad736812d5751276f78839372640ff4386`.

The four numbered PNGs show a physical M50Mini Android tablet using **simulated devices only**. OS status/navigation bars were cropped; app content is otherwise unchanged. No real BLE machine or scale was connected. Debug build flags: forceOnboarding=true, dummyAccount=true, DECAID_ENABLE_DUMMY_ACCOUNT=true, simulate=1, preferredMachineId=issue1141-no-machine, preferredScaleId=issue1141-no-scale.

- [200% text: named discovery, progress, skip and help](onboarding/20-large-scan.png)
- [Successful simulated machine and scale connection](onboarding/14-native-dashboard.png)
- [Disconnected dashboard more than one minute after explicit skip](onboarding/22-skip-stable-later.png)
- [Launcher retains Cancel at 200% text](onboarding/23-launcher.png)
- [Scan connection-error state](onboarding/widget-error.png): **rendered widget simulation**, not a physical Android error scenario.

Limits: no real BLE/USB, clean-install permission prompt or spoken screen-reader validation. FittedBox may reduce enlargement in narrow buttons. A default-skin WebView compatibility timeout occurred; the native dashboard remained available. That failure was not baseline-proven or changed by this PR. The tablet's original APK, app files and font-scale state were restored and verified after testing. Private backups, device identifiers, logs and account data are not published here.

## Combined code verification

Base main: `f1cc2894144357adacdf36589f99bb260c076c5c`.
Disposable combined commit: `38c484d6f7f16be8a16b08b56e82cf6409be05b7`.
Combined tree: `8affecb0f251f05b5e10c2c30919e8cbadada524`.
Exact candidate: `d461c7bd76c22e5fc502787be1a04ce3520ef72b3286274ff28e3c7a6925e503`.

The combination includes the actual #913 and #912 commits plus frozen #1195 candidate `c7b7977b8c7f942fedc86074cc4712cb3728e2c8099a7d0d9dec90eaf919e0ce` and #1141 candidate above. Synthetic commits are local verification artifacts, not merges into main. Final implementation commit-to-tree mapping must be checked before treating this as current-head evidence.

All gates used the candidate helper; receipts finished, valid, exit 0:

- Changed-Dart-file formatting check: passed.
- `flutter analyze --no-pub`: passed.
- `node --test test/plugins/settings_calibration_honesty_test.cjs`: 7 passed.
- `flutter test --no-pub --concurrency=4`: **7309 passed, 1 skipped**, 3m40s.

These results establish code-combination verification, not real-machine behavior or merge authorization. Raw local receipts are retained privately; sanitized results and fingerprints are supplied here.
