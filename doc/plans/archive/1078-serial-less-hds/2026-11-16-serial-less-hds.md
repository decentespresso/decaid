# Serial-less USB HDS preference

## Problem

Issue #1078's test log identifies the HDS as
`usb-1a86-7522-unknown-1004`. Android's physical attachment number is not a
durable device identity. Existing identity protection rejects this preference,
while native UI and REST settings can report a successful save.

## Approved Behavior

Remember a USB HDS family preference when a protocol-identified USB HDS has no
durable serial identity. Select automatically only when a completed discovery
finds exactly one eligible family member. Multiple eligible members require the
existing scale picker. Unique serial identities retain exact-device matching.

## Design

- Keep actual transport IDs, auxiliary reservations, and remembered-device
  identity protection unchanged.
- Store the fixed `usb-hds:any` selector in the existing scale preference key.
  Normalize only identified serial-less HDS devices, not arbitrary CH340 USB
  descriptors.
- Reuse scale selection policy after discovery completes; family selection must
  not connect or stop discovery on the first sighting.
- Use serial scale scan/retry recovery rather than BLE background watch.
- Normalize native/API selections and report unsupported transient identities
  accurately. Document the selector's REST and discovery semantics.
- Preserve existing skins' exact-ID preference highlighting by presenting the
  unique matching attachment ID in settings GET responses. This projection does
  not modify persisted preferences or device IDs. Absent and ambiguous inventory
  returns the family selector; backups retain it in all cases.
- Failed or incomplete serial discovery does not establish uniqueness. Keep the
  existing recovery obligation rather than connecting from a partial result.

## Verification

Regression checks failed before implementation and now cover persistence,
single/multiple matches, late discovery, reattachment, both scale power policies,
explicit-scan overlap, auxiliary isolation, and incomplete discovery. Settings
POST/GET also round-trips over a real loopback HTTP connection.

Changed-file formatting and analysis pass with the repository-pinned SDK. The
full Windows suite with CI's concurrency setting finished with 6,287 passed,
19 failed, and 3 skipped. All 19 failures reproduce at unchanged base `ab734bb6`:
seven QuickJS BigInt cases, two plugin folder-install UI cases, and ten
POSIX credential-storage cases. No unrelated production code was changed to
accommodate those failures.

An isolated debug reporter APK was built and its signature verified without
simulated-device defines. Its package is
`net.tadel.reaprime.localtest`, version `0.9.3-test.1078-preference` (3210).

The APK was deployed to a Samsung SM-X210 running Android 16 with a real
serial-less USB HDS. Runtime settings retained the simulated MockDe1, while the
real Bengle remained discovered and unconnected. Tablet checks confirmed:

- Force-stop/reopen preserved the family preference and automatically connected
  the HDS without a manual scan or preference rewrite.
- Physical USB removal left `usb-hds:any` saved. Replug recovered automatically
  through the existing bounded retry scan. Android reused the attachment ID,
  so a changed-ID replug is covered by deterministic tests, not this hardware run.
- Fresh weight snapshots streamed after recovery.
- One operator-authorized MockDe1 sleep/wake cycle per policy exercised the real
  HDS: disconnect mode disconnected on sleep, scanned about three seconds after
  wake, and reconnected about 18 seconds after wake. Display-off mode kept the connection
  active and logged display sleep/wake commands. Physical display changes were
  not independently confirmed visually.
- The original disabled scale power policy and simulated machine state were
  restored. No real machine was operated.

These are not repeated-cycle, physical DE1 sleep/wake, or USB-suspend tests.
Representative DE1 hardware validation remains pending, as do tablet
background/foreground and multiple-physical-HDS checks. The issue must remain open until its required
real-device validation succeeds.
