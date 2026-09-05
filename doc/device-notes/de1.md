# DE1 Device Notes

Device-specific guidance for the DE1 machine family. Cross-device transport
and connection behavior remains in [`AI_BLE_NOTES.md`](../AI_BLE_NOTES.md).

## Protocol source of truth

The original DE1 app at
[`decentespresso/de1app`](https://github.com/decentespresso/de1app) is the
authoritative source for DE1 protocol behavior, BLE characteristics, machine
state logic, and MMR definitions. Profiles use Profile JSON v2; see
[`Profiles.md`](../Profiles.md).

`tools/ingest_profiles.py` rejects de1app TCL profiles whose type is
`settings_2a` or `settings_2b`, even when `advanced_shot` is populated. That
stored field is not authoritative for simple-profile types. Generate final
advanced-profile JSON externally instead of duplicating de1app's frame
generators in Decaid.

## MMR model mapping

`v13Model` (MMR `0x0080000C`) is read on connect:

| Value | Model |
|-------|-------|
| 0 | Unknown |
| 1 | DE1 |
| 2 | DE1+ |
| 3 | DE1PRO |
| 4 | DE1XL |
| 5 | DE1CAFE |
| 6 | DE1XXL |
| 7 | DE1XXXL |
| >=128 | Bengle |

`DecentMachineModel.fromInt` and API SKU parsing must use this mapping.
Bengle values are outside legacy DE1 identity resolution.

## USB charger deduplication

DE1 firmware re-enables the charger on its own. `BatteryController` must use
`shouldWriteChargerMode()` from `charging_logic.dart`: write on change,
reassert off every five minutes while discharging, skip otherwise, and reset
the last-applied value on disconnect.

## Sleep from refill state

DE1 firmware build 1357+ honors a sleep request in `needsWater` when no refill
kit is present. `PresenceController` sends that request only for DE1 on firmware
1357 or newer; `idle` and `schedIdle` remain eligible on all supported builds.

Older firmware ignores the request while refilling but keeps it latched, then
sleeps immediately after refill. The firmware itself suppresses sleep while a
refill kit is active.

## Serial behavior

Exact USB product name `DE1` creates `UnifiedDe1`. Devices admitted through
generic serial-name rules are identified with the normal `v13Model` MMR read.

- `<F>` MMR write frames are exactly 20 bytes. Short payloads are zero-padded
  without changing their length byte; oversized payloads fail.
- One-shot A/J/R reads use temporary `<+X>` subscriptions correlated by
  representation and always attempt `<-X>` cleanup.
- Persistent reads return observed wire data or explicit local state recorded
  after a successful write, never seeded zero buffers.
- Missing observed data is temporarily unavailable; endpoints without a serial
  representation are unsupported.
- Notification liveness uses the normal snapshot watchdog and
  `ConnectionManager` reconnect lifecycle.
- Stock DE1 firmware does not push a `K` shot-settings frame on connect,
  re-arm, or write. `UnifiedDe1Transport` therefore maintains a local
  nine-byte mirror, refreshed by live frames and successful writes, and seeds
  the shot-settings subject after `<B>02`.

## Profile upload safety

### Firmware latch

The firmware sets `ProfileDownloadInProgress` on header write and clears it on
tail write plus flash commit. If upload stops mid-sequence, the machine ignores
start requests and pulses the group-head LED magenta. A complete profile upload
is the recovery.

### Cache layers

| Cache | Location | Cleared on |
|-------|----------|------------|
| `_lastPushedProfile` | `WorkflowDeviceSync` | Disconnect and upload failure |
| `_currentProfile` | `UnifiedDe1` | Every connect and upload start |

Both caches must clear on connection edges. The on-connect profile push starts
from `De1Controller.initSettled`, after readiness and startup defaults.
Generation tokens in `De1Controller` and `WorkflowDeviceSync` reject stale
completion from a prior connection.

### Missing shot settings

`UnifiedDe1Transport._shotSettingsSubject` is unseeded until the connect-time
read succeeds. Every steam and hot-water write reads current shot settings, so
an unbounded missing frame wedges the device-write queue.

`De1Controller._readShotSettings` bounds the read with
`ConnectionTimings.initialShotSettingsTimeout` and maps a closed subject to
`DeviceNotConnectedException`. A connect-time timeout re-arms startup defaults
when the first frame arrives. Do not put a generic `Future.timeout()` around
the write queue: it does not cancel the underlying write and could allow a
stale operation to overwrite a newer one.

### Failure diagnosis

Symptoms are a magenta pulsing group-head LED, ignored start requests, and a
connected app that still shows the selected profile. Check `setProfile`
failure/retry logs, `/ws/v1/devices` for `profileUploadFailed`, and
`WorkflowDeviceSync` logs. Re-uploading a complete profile clears the latch.
See [`profile-upload-recovery`](../plans/archive/profile-upload-recovery/design.md)
for design rationale.

## Post-initialization profile synchronization

`WorkflowDeviceSync` subscribes to `De1Controller.initSettled`, not the raw
machine stream. Startup-default failures are logged but do not suppress
`initSettled`.

Initialization captures both the device and connection generation. Every async
boundary checks that both are still current before continuing or emitting
`initSettled`. `adoptDevice()` uses the same ready, initialize, and
`initSettled` sequence.

## Unexpected auto-connect

`ConnectionManager` auto-connects when only one machine is found or when a
preferred machine ID is configured. Clear the preferred machine in Device
Management or inspect `ConnectionManager` policy logs when this is unexpected.

## Legacy identity resolution

Early DE1-family machines can report zero for `SerialN` or `v13Model`.
`De1StateManager` resolves an effective identity from the linked Decent account
before serial-ownership checks.

Resolution prefers an exact nonzero serial match, then a persisted
account/transport/device mapping, then a single compatible legacy candidate.
Remaining ambiguity is resolved through a native picker. The result is an
in-memory `MachineInfo` override; raw MMR identity is never rewritten and stays
available through `rawMachineInfo`.

Bengle and unknown-SKU records are excluded. A rejected account session is not
identity authority; logout or successful account replacement clears cached
machine records and mappings.

## Hot water stop-at-weight

`HotWaterSequencer` reacts to entry into `MachineState.hotWater`. When enabled,
with a connected scale, positive target, and non-`full` gateway mode, it tares
and waits until a near-zero reading proves the tare landed.

After the settle window it projects weight with
`weight + weightFlow * hotWaterFlowMultiplier` and requests idle once the
target is reached. Native volume/time stopping remains the backstop. The
sequencer disarms when hot water ends, the machine disconnects, or the scale
drops.
