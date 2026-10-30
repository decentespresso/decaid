# Bengle settings MMR coalescing (#1065)

## Decision

Enable fan/tank, flush, and heater groups for USB-serial Bengle. Keep the
steam-purge/USB pair sequential: its second word was zeroed despite single-word
reads returning `1`. Normal settings therefore use five requests instead of nine;
advanced settings use two instead of four. These counts are logical settings MMR
reads, excluding retries and unrelated background traffic. BLE Bengle remains
unverified and sequential. Simulated, replay, and interface-only test devices remain sequential.

No retry, timeout, MMR serialization, ownership, or framing rule changes were made.
The Bengle-only capability gate is unrelated and remains unchanged. This
USB-specific selection decision supersedes the older blanket Bengle exclusion in
`doc/AI_BLE_NOTES.md`; that architecture summary was not edited because its
ownership and framing rules did not change. LED,
cup-warmer, identity-read coalescing, firmware changes, and DE1Pro measurements
are outside this validation.

## Hardware identity and chronology

Measured on 2026-10-30, Samsung SM-X210 tablet `de1tablet.home`, USB serial.
`GET /api/v1/machine/info` returned Bengle firmware `472`, serial number `11431`,
GHC true. The transport logs identify `Serial:/dev/bus/usb/001/002`.
The operator identified host ports `/dev/ttyACM1`, `/dev/ttyACM2`; the app's Android
USB path, not those host port names, appears in the captured framing evidence.

Initially tablet REST was reachable but wireless adb discovery was empty and the
USB machine was unavailable. No framing conclusion was drawn then. Once access
was restored, `adb connect 192.168.12.87:46627` reached the SM-X210. The first
inventory had `usb-2e8a-a-unknown` connected and
`usb-2e8a-a-8549628789ABCDEF` disconnected. After installing this lane's debug APK,
the inventory instead had `usb-2e8a-a-8549628789ABCDEF` connected and `-unknown`
disconnected. The physical framing and unchanged-state comparison below were
captured on the explicitly connected **`usb-2e8a-a-8549628789ABCDEF`** link with
machine-info serial `11431`. Evidence from the earlier `-unknown` snapshot is not
used to establish that link's identity or group equivalence. No BLE connection or
measurement was substituted.

## Serial framing first

The first isolated experimental build selected only `fanTank`. At tablet local
time `11:15:45.704346`, the serial transport wrote:

```text
<E>0180380800000000000000000000000000000000
```

At `11:15:45.737944`, `machineSettings/fan` received the complete 20-byte response:

```text
08 80 38 08 32 00 00 00 1f 00 00 00 00 00 00 00 00 00 00 00
```

This decodes to two distinct non-zero words, fan `50`, tank `31`. Thus multi-word
requests and responses survive this serial path; physical group comparison could
proceed. Header `08` is recorded, not treated as a general word-count contract.

A later request returned tank `0`, but an intervening startup `mmr write: tankTemp`
with payload `0` at `11:15:50.903921` changed the machine state. It is not an
unchanged-state discrepancy. Restarting builds also reapplied other normal
settings. Cross-install comparisons were therefore not used as group evidence.

## Unchanged-state comparison

One installed debug build selected `fanTank,flush,heater,purgeUsb`. After startup
restoration settled, test values were written once. Ground truth was then read
one register at a time through the existing persistent `/ws/v1/machine/raw`
connection, using operation `write` to **A005** (`readFromMMR`, serial `<E>`),
20-byte requests with length byte `0`. A006 is register writing and was not used
for the single-word read probes.

Raw reads, REST settings requests, and the final raw readback ran sequentially,
with gaps, never concurrently: the raw endpoint bypasses the MMR gate. Responses
were correlated to the request's write receipt, address, and single-word response
header `04`; queued primer notifications were not accepted as ground truth.
The initial incomplete raw attempt had accepted a queued primer response and then
lost a tank reply; it was excluded, not counted as a valid comparison.

The completed comparison ran `10:22:52.596095`–`10:23:12.496597` UTC (tablet logs
`11:22:52`–`11:23:12`). All 13 single-word register values were identical before
and after the coalesced REST requests. There were no intervening MMR writes in
that interval. Two single-word probes had no valid response on the first attempt
and succeeded on the second (flush temperature before, heater idle temperature
after); attempts were separated by the existing 300 ms retry-settle duration.
No returned value disagreement was retried until agreement. Malformed serial
messages were also observed outside these successful exchanges; this lane does
not change their handling or claim serial reliability is perfect.

### Per-group results on Bengle 472 / serial 11431 / USB serial

Raw integers are signed little-endian words at payload offsets 4, 8, 12, 16.
Decimal display below abbreviates the ordinary Dart floating-point representation;
full JSON is recorded below, without rounding in the comparison.

| Group | Start / length byte | Single-word before = after | Coalesced words / decoded values | Observed coalesced label (tablet time) | Default |
| --- | --- | --- | --- | --- | --- |
| fan/tank | `0x00803808` / `1` | `[50, 31]` | `[50, 31]` | `machineSettings/fan` (`11:23:02.665237`) | coalesced |
| flush | `0x00803840` / `3` | `[71, 893, 47, 62]` | same words; flow `7.1`, temperature `89.3`, timeout `4.7`, hot-water flow `6.2` | `machineSettings/flush` (`11:23:02.755865`) | coalesced |
| heater | `0x00803810` / `2` | `[31, 42, 834]` | same words; phase-1 `3.1`, phase-2 `4.2`, idle `83.4` | `advancedSettings/heater` (`11:23:02.873432`) | coalesced |
| purge/USB | `0x00803850` / `1`; USB `0x00803854` | `[0, 1]` | **`[0, 0]`**, USB incorrectly `false` | `machineSettings/purgeUsb` (`11:23:02.812159`) | **sequential** |

Steam flow was raw `81` / decoded `0.81`; heater phase-2 timeout was raw `95` /
decoded `9.5`, both unchanged before/after and still individual requests.

Distinct non-zero words were used within each enabled group. The attempted purge
mode `2` read back as `1` on this firmware; fan requests above `50` are clamped by
the existing app model, and USB writes require the existing string `"enable"`,
not JSON boolean `true`. None of those attempted inputs was substituted for
measured output. For the pair the supervisor explicitly approved `[0, 1]` as a
zero-fill diagnostic: it detects the observed zeroed second word but does not
establish immunity to arbitrary word crossing. The failed pair is not enabled.

### Actual multi-word response frames

These follow the labels and request lengths in the table, on the same USB link:

```text
fan:    08 80 38 08 32 00 00 00 1f 00 00 00 00 00 00 00 00 00 00 00
flush:  10 80 38 40 47 00 00 00 7d 03 00 00 2f 00 00 00 3e 00 00 00
heater: 0c 80 38 10 1f 00 00 00 2a 00 00 00 42 03 00 00 00 00 00 00
pair:   08 80 38 50 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
```

The paired USB control was `04 80 38 54 01 00 00 00` followed by twelve zero
padding bytes, both before and after. This is not a legitimate USB `0`.

### REST JSON observed in the all-groups experiment

Normal JSON differed from sequential ground truth only at `usb` (expected `true`):

```json
{"fan":50,"usb":false,"flushTemp":89.30000000000001,"flushTimeout":4.7,"flushFlow":7.1000000000000005,"hotWaterFlow":6.2,"steamFlow":0.81,"tankTemp":31,"steamPurgeMode":0}
```

Advanced JSON matched the single-word values exactly:

```json
{"heaterPh1Flow":3.1,"heaterPh2Flow":4.2,"heaterIdleTemp":83.4,"heaterPh2Timeout":9.5,"heaterVoltage":230,"refillKitSetting":2}
```

The default fix keeps the USB getter separate, so this experimental mismatch is
not accepted as product behavior. The original normal and advanced settings were
restored, with GET JSON equal to the pre-experiment snapshots. Heater-voltage and
refill-kit settings were not changed.

## Final default-build smoke test

A final APK built with only `--dart-define=simulate=0` (no group override) served
normal settings with all the test-state values above and **`usb: true`**, using
`machineSettings/fan`, `machineSettings/steam`, `machineSettings/flush`, then
individual `steamPurgeMode` and `allowUSBCharging` reads. In particular,
`allowUSBCharging` at `11:35:48.698758` received a single-word `04` response with
value `1` at `11:35:48.743894`. Heater settings used the measured group and matched.

The subsequent bracketed readback was not an unchanged-state USB comparison:
`allowUSBCharging` changed from `1` before to `0` after. The log explicitly shows
an intervening write of `0` at `11:36:11.764927`; the following individual getter
returned `0`, so REST correctly reported `false`. All other raw words stayed
unchanged and the three enabled groups still matched. This state change is
recorded rather than misclassified as a coalescing defect or retried until it
agrees. Missing serial replies also caused ordinary retries in this smoke run;
no timeout/retry behavior was changed.

After that run, original normal and advanced settings were restored again and
GET JSON matched both original snapshots exactly. The tablet was left running the
final default-selection debug build with `simulate=0`, not a simulated machine or
the known-bad all-groups override. The lane-created debug-keystore copy was removed;
no pre-existing keystore was overwritten or deleted.

## Reproducing selection

`--dart-define=bengleCoalescedSettings=fanTank,flush,heater` selects the measured
USB-serial Bengle groups and is also the production default. An explicit empty
value (`--dart-define=bengleCoalescedSettings=`) forces original sequential
composition. A comma-separated subset selects mixed paths independently;
`purgeUsb` is available only for explicit experiments and is not a validated
default. Unknown names enable nothing. Normal and advanced routes select only
their relevant groups. Compile-time defines require a new build/launch, not hot
reload; do not use cross-restart snapshots as unchanged-state evidence.

The investigation builds used the following commands. The second command was
sequential before the measured default was introduced; to reproduce that path on
the final source, append `--dart-define=bengleCoalescedSettings=`.

```sh
flutter build apk --debug --dart-define=simulate=0 --dart-define=bengleCoalescedSettings=fanTank
flutter build apk --debug --dart-define=simulate=0
flutter build apk --debug --dart-define=simulate=0 --dart-define=bengleCoalescedSettings=fanTank,flush,heater,purgeUsb
adb -s 192.168.12.87:46627 install -r build/app/outputs/flutter-apk/app-debug.apk
adb -s 192.168.12.87:46627 shell am start -n net.tadel.reaprime/.MainActivity
```

`simulate=0` enables debug infrastructure without creating simulated devices.
Rediscover wireless adb coordinates with `adb mdns services` if they change.
No request-time selector, endpoint, or public API contract was added.

Capture chronological logs with:

```sh
curl -sf 'http://de1tablet.home:8080/api/v1/logs?kb=4096&order=asc'
```

Use current request timestamps and the actual read labels, not historical entries
or JSON values alone. Earlier sequential builds logged individual getters
(`fanThreshold`, `tankTemp`, `flushFlowRate`, `heaterUp1Flow`, etc.); the unchanged
single-word controls used explicit A005 length-0 frames. Multi-word labels above
prove the experimental REST requests actually took the coalesced path.
