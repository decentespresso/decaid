# MOTTO80 (Bookoo) BLE Grinder support

## Why

Add a new device kind to decaid: the MOTTO80 grinder, a BLE grinder with a
~200ms status broadcast protocol reverse-engineered in the user's
`grinder_gui` test rig. decaid had no grinder support at all (verified: zero
matches across lib/; DeviceType was machine/scale/sensor only). Goal: the
grinder appears in Devices, connects, streams typed state, and auto-connects
by preferred id. streamline.js UI is a separate follow-up task.

## Design

- `DeviceType.grinder` + typed `Grinder` abstraction parallel to `Scale`
  (user-confirmed; not the generic Sensor map channel): `GrinderSnapshot`
  DTO, operations (start/stop/setPreset/setGrindSection/geneSetting setters).
- `BookooGrinder` in `lib/src/models/device/impl/bookoo/` implements the
  MOTTO80 protocol: A5 01 framed JSON with seq, long-frame reassembly
  (repeated-header and headerless continuations, stale-pending drop, single
  UTF-8 decode), handshake/section/preset startup queries with injectable
  gaps.
- `GrinderController` mirrors ScaleController (no deviceStream subscription;
  ConnectionManager drives it).
- Auto-connect: `preferredGrinderId` setting + `_tryConnectPreferredGrinder`
  after each scan's machine/scale publish. Minimal honest scope; deferred:
  picker ambiguity, background watch/reacquisition, quick-connect execution,
  scan-flow column, ws/v1/grinder channel, wifi/usage queries.
- `MockGrinder` simulated device for simulate-mode testing.

## Protocol notes

Full protocol spec and footguns in `doc/AI_BLE_NOTES.md` (MOTTO80 section):
framing, reassembly rules, UTF-8 split-multibyte gotcha, connect sequence,
confirmed vs guessed commands.

## Verification

- BookooGrinder fake-transport tests (15), GrinderController tests (4),
  matcher/factory/remembered additions, connection_manager assertion updates.
- Full `flutter test` suite green before PR.
- E2E real: physical MOTTO80 → Devices shows "MOTTO80 Grinder" → connect →
  snapshot stream; Settings auto-connect; restart + scan → auto-connect.
- E2E simulate: MockGrinder appears and auto-connects.
