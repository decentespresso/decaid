# Serial shot-settings frame ownership

Closes gh-660. Field report: gh-670.

## Problem

`UnifiedDe1Transport._shotSettingsSubject` is an unseeded `BehaviorSubject`.

On BLE it is seeded during `_bleConnect` by an explicit
`_transport.read(de1ServiceUUID, Endpoint.shotSettings.uuid)`.

On serial there is no equivalent. `_serialConnect` only issues
`<+K>` and relies on the DE1 pushing a `[K]` frame. A DE1 pushes `[K]`
only when shot settings change, so on a connection where no change occurs
the subject stays empty for the life of that connection.

Consequences, all downstream of the empty subject:

- `De1Controller._initializeData` times out on `_readShotSettings` and defers
  startup defaults. The deferral waits passively on `device.shotSettings.first`,
  which never fires, so configured defaults (including steam duration) are never
  applied.
- `_writeSteamSettings` and `_writeHotWaterSettings` need the current
  `De1ShotSettings` to `copyWith` without clobbering sibling fields. Both fail
  with `TimeoutException` on every attempt.
- `PUT /api/v1/workflow` carries `Workflow.profile` plus steam, hot-water and
  rinse settings, so the user-visible symptom is "failed to send profiles".

gh-634 / gh-635 bounded the wait so a missing frame can no longer wedge the
device-write queue. This change addresses the missing frame itself.

## Field evidence

Android tablet (SM-X210) with a USB serial DE1, build 5bb2d525, 2026-08-24
09:52-10:22. Eight machine connects, and every one logged:

```
WARNING De1Controller - Initial shot settings unavailable; deferring startup defaults
TimeoutException after 0:00:02.000000: Future not completed
```

Over the same 30 minutes there were zero `mmr write: targetSteamFlow` and zero
flush setting writes, and 38 of 40 `PUT /api/v1/workflow` requests failed. The
two that succeeded changed no steam, hot-water or rinse value, so
`updateWorkflowSettings` returned before touching the device.

## Hardware evidence (2026-08-24)

Real field DE1 over USB serial (`/dev/cu.wchusbserial5B1F0919251`, 115200
8N1), commands newline-terminated exactly as `SerialTransport.writeCommand`
emits them. With the app's connect sequence (`<+N><+M><+Q><+K><+E><+I><+R>`
then `<B>02`), the machine streams `[N]`/`[M]`/`[Q]` but never pushes `[K]`:

- no `[K]` after the connect-time `<+K>` (5s window)
- no `[K]` after two `<-K>`/`<+K>` re-arms (2x5s)
- no `[K]` after a full `<K>` settings write (10s window)
- serial `<E>` MMR reads do answer (`[E]0480382864...` for targetSteamFlow),
  so the link is fully live both ways; `<+A>`/`<+J>` one-shot subscribes do
  not answer

The machine never transmits `K` unprompted. Only the app's own writes could
ever populate the frame, so the app must own it.

## Approach

The transport keeps a local mirror of the 9-byte shot-settings frame,
initialised to the stock firmware defaults (`_defaultShotSettingsFrame`; BLE
firmware also resets `K` to these defaults, so the app and the machine agree
until the app writes). The mirror is refreshed by:

- live `[K]` frames (`_shotSettingsNotification`), when the machine does push
  one
- every local write (`recordLocalShotSettings`, called by
  `UnifiedDe1.updateShotSettings`)

After `_serialConnect` completes (right after `<B>02`), the transport seeds
`_shotSettingsSubject` from the mirror. `De1Controller` is unchanged: its
initial `_readShotSettings` succeeds immediately, so startup defaults
(including configured steam duration) are applied and later steam/hot-water
writes read the seeded value through the normal copyWith path. Write
serialization and connection-generation fencing are untouched.

Why not other options:

- Re-arming (`<-K>`/`<+K>`) to elicit a retransmit: refuted on hardware, see
  above.
- Reading the values from serial MMR registers: the K fields (steam
  temperature/duration, hot-water temperature/volume/duration, shot volume,
  group temperature) have no MMR register counterparts; only `targetSteamFlow`
  etc. exist.
- Seeding from BLE session data: the DE1 allows only one active connection
  (BLE or serial), and BLE firmware resets `K` to defaults, so a BLE-learned
  frame is neither available nor authoritative.

The mirror is in-memory and per-transport. Staleness is accepted and bounded:
the app writes the full frame it knows whenever settings change, which is the
only way serial machines ever receive settings; a live `[K]` push (user
changing settings on the machine) refreshes the mirror and takes precedence.

## Verification

`test/unit/models/device/impl/de1/unified_de1/serial_shot_settings_mirror_test.dart`,
over a quiet serial fake:

- a serial connect seeds the subject from the mirror (firmware defaults) and
  issues no `<-K>` re-arm
- a live `[K]` frame updates the mirror for the next connect
- a local write (`recordLocalShotSettings`) updates the mirror for the next
  connect
- BLE connects issue no serial commands

`test/controllers/de1_controller_shotsettings_stall_test.dart` drives a real
`UnifiedDe1` over a quiet serial fake that never pushes `[K]`:

- startup defaults run without any machine cooperation: the fan-threshold
  write precedes the steam `<K>` write carrying configured steam duration 16
- no `<-K>` re-arm is ever issued
