# Serial shot-settings frame recovery

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

## Approach

Actively re-request the frame from the serial transport, and let the existing
`De1Controller._deferStartupDefaults` deferral pick it up.

After `_serialConnect` completes, prime the shot-settings subject:

1. Wait `shotSettingsPrimeTimeout` for the connect-time `<+K>` to deliver.
2. If nothing arrived, re-arm the endpoint with `<-K>` then `<+K>` and wait
   again.
3. Repeat at most `shotSettingsPrimeRetries` times with
   `shotSettingsPrimeBackoff` between attempts, then give up with a warning.

The re-arm reuses the `<+X>` / `<-X>` mechanism the documented one-shot A/J/R
reads already depend on. `_processDe1Response` routes `K` to
`_shotSettingsNotification` before the `SerialResponseCorrelator` default
branch, so the wait is on `_shotSettingsSubject` rather than on
`_serialResponses`.

Priming runs unawaited so `connect()` latency is unchanged, and is fenced by a
generation counter incremented in `_resetCachedState()` so a disconnect,
reconnect or dispose abandons an in-flight prime.

Recovery is confined to the transport. `De1Controller` is unchanged: its
existing deferral already applies startup defaults when a late frame arrives,
and later steam and hot-water writes read the recovered value through the
normal path. Write serialization and connection-generation fencing are
therefore untouched.

## Bounded by construction

If a DE1 answers neither the connect-time `<+K>` nor a re-armed one, the loop
exhausts its retries and stops. That is the behaviour shipped today, so the
change cannot regress a machine it does not help.

This is recovery for a missing initial frame, not a keepalive: it stops on the
first frame and never restarts on its own. The serial parity rule that there is
no separate keepalive or reconnect loop still holds.

## Verification

`test/unit/models/device/impl/de1/unified_de1/serial_shot_settings_prime_test.dart`,
over the `_RecordingSerialTransport` fake already used by the serial parity
tests:

- a frame delivered by the connect-time subscribe seeds the subject and issues
  no re-arm
- a missing frame triggers `<-K>` then `<+K>`, and a frame delivered on the
  re-arm seeds the subject
- a DE1 that never answers stops after the configured retries
- disconnect during priming abandons it
- BLE connects issue no serial commands

Hardware verification on a real field DE1 over USB (2026-08-24, stock DE1
on `/dev/cu.wchusbserial5B1F0919251`, 115200 8N1, commands newline-terminated
exactly as `SerialTransport.writeCommand` emits them) refutes the re-arm
assumption. With the app's connect sequence (`<+N><+M><+Q><+K><+E><+I><+R>`
then `<B>02`), the machine streamed `[N]`/`[M]`/`[Q]` but never pushed a
`[K]`: not after the connect-time `<+K>` (5s), not after two `<-K>`/`<+K>`
re-arms (2x5s), and not on a fresh session. Serial `<E>` MMR reads do answer
(`[E]0480382864...` for targetSteamFlow), so the link is fully live; the
machine simply does not retransmit `K` on subscribe or re-arm, and it also
answered no `<+A>`/`<+J>` one-shot subscribes. The recovery is therefore a
no-op on this hardware and #660 needs a different protocol action; the
re-arm loop is kept because it is bounded, fenced and cannot regress a
machine it does not help.
