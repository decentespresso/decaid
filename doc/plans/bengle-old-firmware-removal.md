# Plan: Drop the Bengle old-firmware compat layer

## Context

PR #612 introduced a single-surface contract with a firmware compatibility
probe: a current-firmware Bengle advertises the full 7-item capability list;
older firmware gets an empty list, 404s on every Bengle endpoint, and an
`extra.bengleFirmwareSurface: outdated` marker.

Decision (2026-08-14): drop all old-firmware support. The capability list is
always the full set for any Bengle, and old firmware is handled with a
connect-time refusal instead of a connected-but-degraded state.

## Why

The compat layer costs more than it protects:

- Per-endpoint gates, nullable API schemas, an outdated-state mock flag, and
  a whole test axis dedicated to a machine state nobody benefits from.
- The self-review of #612 showed the contract leaks: even with the API
  gates, the integrated-scale attach, the ShotSequencer SAW bypass, and the
  SAW bridge all treated any `BengleInterface` as current-firmware.
- There is no evidence of old-firmware Bengles in the field (Bengle is
  pre-production), and Decaid has no Bengle firmware-update path, so a
  connected-but-degraded state has no escape route for the user.

## Inventory (verified against HEAD)

| Area | Location |
|------|----------|
| Probe mixin (2x2s read, latch) | `lib/src/models/device/impl/de1/unified_de1/bengle_firmware_probe.dart` |
| Interface getter | `bengle_interface.dart` `supportsCurrentBengleFirmwareSurface` |
| `machineInfo` extra | `impl/bengle/bengle.dart`, `impl/bengle/mock_bengle.dart` |
| Capability gate + per-endpoint 404 gate | `services/webserver/de1handler.dart` (`_bengleFirmwareGate`) |
| Firmware-sync gate | `controllers/presence_controller.dart` |
| Internal-surface guards (added 2026-08-14) | `connection_manager.dart` virtual-scale attach, `shot_sequencer.dart` SAW bypass, `bengle_saw_bridge.dart` write guard |
| Mock flag | `mock_bengle.dart` `supportsCurrentFirmwareSurface`; `mock_replay_de1.dart` getter |
| Tests | `bengle_firmware_probe_test.dart`; outdated-firmware cases in `de1handler_cup_warmer_test.dart`, `de1handler_led_strip_test.dart`, `presence_controller_bengle_sync_test.dart`, `led_strip_capability_test.dart` |
| Spec/docs | `rest_v1.yml` (capabilities description, `MachineInfo.extra`, `CupWarmerState` nullability), `doc/Api.md`, `doc/DeviceManagement.md`, `doc/AI_BENGLE_NOTES.md`, decent-app scenarios, PR #612 description |

## Options

### Option A — delete the probe entirely (rejected)

Assume every Bengle speaks the current surface. Old firmware then fails
lazily: palette hydration 503s, MMR reads time out, wake-sync writes are
silently skipped by the firmware. No explicit signal, scattered failures.

### Option B — probe becomes a connect-time gate (recommended)

Keep the one-per-connection probe read, but change its failure semantics:
a failed probe makes `Bengle.onConnect()` throw
`BengleFirmwareOutdatedException` (new exception in `errors.dart`); the
connection fails with a clear message. There is no connected outdated
state at all, so the entire API compat layer disappears. Post-connect,
every Bengle has the current surface by construction.

## Work items

### Code

1. `bengle_firmware_probe.dart`: on probe failure, throw
   `BengleFirmwareOutdatedException` instead of latching
   `supports=false`; drop the per-consumer state.
2. `bengle_interface.dart`: remove `supportsCurrentBengleFirmwareSurface`
   from the interface (post-connect it is guaranteed; no consumer branches
   on it anymore).
3. `bengle.dart`: remove the `bengleFirmwareSurface` extra from
   `machineInfo`.
4. `de1handler.dart`: capabilities always return the full 7-item set for
   any `BengleInterface`; `_bengleFirmwareGate` shrinks to a plain
   `is! BengleInterface -> 404` guard (plain DE1s only).
5. `presence_controller.dart`: drop the surface checks in
   `_syncFirmwareScheduleAndTimeout` / `_pushFirmwareDesiredState`.
6. Revert the internal-surface guards added by the 2026-08-14 fixes
   (`connection_manager.dart`, `shot_sequencer.dart`,
   `bengle_saw_bridge.dart`) — dead once connect guarantees the surface.
7. `mock_bengle.dart`: replace the static
   `supportsCurrentFirmwareSurface` flag with an `onConnect()` throw when a
   `simulateOldFirmware` flag is set; drop the machineInfo extra.
8. `mock_replay_de1.dart`: drop the `supports... => false` getter.

### Tests

- Rework `bengle_firmware_probe_test.dart` to assert the throw instead of
  the latch.
- Delete outdated-firmware 404/capability cases across the handler,
  presence-sync, and LED tests.
- Add: outdated Bengle connect fails and surfaces the refusal as a connect
  error (ConnectionManager-level test).

### Specs & docs

- `rest_v1.yml`: capabilities description (no empty-list variant), remove
  `bengleFirmwareSurface` from `MachineInfo.extra`.
- `doc/Api.md`, `doc/DeviceManagement.md`, `doc/AI_BENGLE_NOTES.md`
  (probe + single-surface sections), decent-app scenarios.
- PR #612 description: replace the outdated-firmware narrative with the
  connect-time refusal contract.

## Open questions

1. Do any real Bengles run pre-`2377c7e0` firmware? If yes, the refusal
   message must point at the tool that updates Bengle firmware (Decaid has
   no Bengle update path).
2. Exact wording of the connect refusal error shown to the user.
