# Plan: harden background scale-watch ownership (#451)

## Goal

Ensure the background scale watch and discovery bursts have one known native scan owner. A queued watch must not be reported as active, and a failed ownership handoff must block GATT work and further scans.

## Scope

- Replace implicit watch activation with an explicit result/state contract.
- Propagate ownership-transfer `stopScan()` failures and surface a watch fault.
- Make watch start/disarm/restart generation-safe and transactional.
- Recover preferred-device discovery when a stale cached instance survives a hard power loss.
- Expose a read-only BLE diagnostics snapshot and endpoint.
- Bundle a small diagnostics skin/report fixture for the prescribed two-cycle reproduction.

## Verification

- Add service and `ScaleWatch` regression tests for queued starts, failed stops, failed starts, and disarm races.
- Add endpoint/diagnostic serialization tests and bundled-skin asset validation.
- Run focused tests, `flutter analyze`, and the full `flutter test` suite.
