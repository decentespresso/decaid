# DE1 calibration machine API plan

**Issue:** [decentespresso/decaid#613](https://github.com/decentespresso/decaid/issues/613)  
**Branch:** `feat/613-de1-calibration-api`  
**Scope:** DE1 A012 protocol, the public Dart machine interface, and the public REST machine API. No calibration UI, operator procedure, or WebSocket endpoint.

## Current findings

- `Endpoint.calibration` already declares A012 / serial representation `R`, but `UnifiedDe1Transport` does not subscribe to, route, or expose calibration notifications.
- `De1Interface` and `UnifiedDe1` have no A012 calibration methods or model.
- The public REST API already exposes `GET`/`POST /api/v1/machine/calibration`, but those routes only read/write `flowMultiplier` through the `calFlowEst` MMR. Their existing request and response shapes are compatibility surfaces.
- `getFlowEstimation()` / `setFlowEstimation()` use the separate `calFlowEst` MMR (`0x0080383C`) and must remain unchanged.
- DE1app's `calibrate_spec` is a 14-byte, big-endian packet:
  - `WriteKey`: unsigned 32-bit
  - `CalCommand`: unsigned 8-bit
  - `CalTarget`: unsigned 8-bit (`flow=0`, `pressure=1`, `temperature=2`)
  - `DE1ReportedVal` / `MeasuredVal`: Q16.16, **signed** (S32P16) per the
    firmware `T_Calibration` struct (`BLE/DE1_BLE/src/APIDataTypes.hpp`).
    de1app's `{unsigned}` marker on DE1ReportedVal is a flag character that
    Tcl's `binary format` ignores, so the wire bytes are signed big-endian
    `I` either way.
- DE1app commands are current read `0`, write `1`, reset `2` (out of scope), and factory read `3`. Reads use `WriteKey=1`; writes use `WriteKey=0xCAFEF00D`.
- A012 emits returned data (`WriteKey == 0`) for read requests. Writes complete at the GATT write acknowledgement: de1app unblocks its command queue on the BLE write event (`access == "w"`), not on a calibration frame. Read operations need response correlation; writes must not wait for a notification (verified on real hardware: waiting for an A012 write frame times out).

## Proposed public interfaces

### Dart machine interface

Add to the device model layer:

```dart
enum De1CalibrationTarget { flow, pressure, temperature }
enum De1CalibrationSource { current, factory }

final class De1Calibration {
  final De1CalibrationTarget target;
  final double de1ReportedValue;
  final double measuredValue;
}
```

Add to `De1Interface`:

```dart
Future<De1Calibration> readCalibration(
  De1CalibrationTarget target, {
  De1CalibrationSource source = De1CalibrationSource.current,
});
Future<void> writeCalibration(De1Calibration calibration);
```

This keeps target and current/factory selection typed while making write acknowledgement explicit through the returned `Future<void>`.

### REST machine API

Keep the existing flow-estimation routes unchanged:

- `GET /api/v1/machine/calibration` → `{ "flowMultiplier": 1.0 }`
- `POST /api/v1/machine/calibration` with `{ "flowMultiplier": 1.0 }`

Add A012 calibration as typed subresources rather than overloading or changing those legacy shapes:

- `GET /api/v1/machine/calibration/{target}?source=current|factory`
  - `target`: `flow`, `pressure`, or `temperature`
  - `source` defaults to `current`
  - response: `{ "target", "source", "de1ReportedValue", "measuredValue" }`
- `PUT /api/v1/machine/calibration/{target}`
  - request: `{ "de1ReportedValue", "measuredValue" }`
  - returns `202` only after the A012 write acknowledgement arrives

The REST surface never exposes `WriteKey`, `CalCommand`, numeric target IDs, or raw bytes.

## Implementation plan

### 1. Lock the wire contract with codec tests

Create focused tests first for a small standalone A012 codec.

- Assert canonical 14-byte vectors for read, factory-read, and write packets.
- Parameterize target encoding/decoding across flow, pressure, and temperature.
- Verify big-endian fields and Q16.16 rounding.
- Cover positive reported values and positive/negative measured values.
- Reject short packets, unknown commands/targets, non-finite values, and values outside the representable signed/unsigned ranges.

Then implement the minimum packet type/codec under `lib/src/models/device/impl/de1/unified_de1/`, keeping command IDs and `WriteKey` values internal.

### 2. Wire A012 through `UnifiedDe1Transport`

Add transport tests before production changes.

- BLE connect subscribes to A012 without performing an unrelated characteristic read.
- Serial connect enables representation `R`; disconnect disables it.
- BLE and serial A012 frames enter one calibration stream.
- Reconnect/reset/dispose replace or close that stream consistently with the existing endpoint subjects.
- Malformed short notifications are dropped rather than completing a request.

Implement one calibration subject and route A012 / `[R]` notifications through it. Preserve the existing serial response-correlator behavior where required by direct transport reads.

### 3. Implement request/response behavior in `UnifiedDe1`

Write behavior tests first using `FakeBleTransport` and its existing `emitNotification()` seam.

- Current reads send command `0`, then complete only from matching returned data (`WriteKey == 0`).
- Factory reads send command `3` and ignore current-read responses.
- Writes send command `1` with `0xCAFEF00D`, then complete only on a matching write acknowledgement; a returned-value frame must not be mistaken for the acknowledgement.
- Unrelated target/command notifications are ignored.
- All three targets work through the same code path.
- Transport write errors propagate immediately.
- Missing responses fail with `EndpointUnavailableException` after the existing-style bounded timeout.
- Concurrent calibration operations are serialized so one A012 response cannot complete multiple callers.

Implement the methods as a focused `UnifiedDe1` part/extension, following the existing subscribe-before-write MMR pattern. Add an injectable calibration timeout to `UnifiedDe1` for fast deterministic timeout tests, with a production default matching the existing 4-second endpoint convention.

### 4. Complete interface and simulated-device support

- Add the typed models and methods to `De1Interface`.
- Give `MockDe1` separate in-memory current and factory values per target; writes update current values only.
- Add the minimal required stubs to direct `De1Interface` test doubles. Do not introduce a new abstraction solely to avoid these compile fixes.

### 5. Expand the public REST machine API

Create `test/services/webserver/de1handler_calibration_test.dart` first and cover:

- the legacy GET/POST `flowMultiplier` contract remains unchanged and continues to call only the MMR methods;
- current and factory GETs for all three typed targets return the documented model;
- PUT validates the target and finite numeric values, uses the path target rather than accepting a raw target ID, runs through `De1Controller.runDeviceWrite`, and waits for the write acknowledgement before returning `202`;
- malformed JSON, unknown targets/sources, and missing fields return `400`;
- A012 response timeout returns `504`, machine replacement timeout returns `503`, and other transport failures retain the existing `500` behavior.

Then extend `De1Handler` with the two subresource routes, using `readCalibration()` for GET and the queued device-write path for PUT. Keep the legacy route implementations intact.

Update the same change set with:

- `assets/api/rest_v1.yml`: paths, target/source enums, request/response schemas, examples, and error responses;
- `doc/Api.md`: distinguish the legacy flow-estimation multiplier from DE1 sensor calibration;
- no AsyncAPI change, because no WebSocket topic is added.

### 6. Prove flow-estimation separation

Add protocol and handler regression tests that exercise `getFlowEstimation()` / `setFlowEstimation()` and the legacy REST routes, asserting they still use `calFlowEst` through A005/A006 with no A012 traffic. Do not rename, redirect, or otherwise alter those methods.

### 7. Verify

Run, in order:

1. New codec, calibration behavior, and `De1Handler` calibration tests.
2. `test/unit/models/device/impl/de1/unified_de1/serial_parity_test.dart` and existing unified transport/MMR tests.
3. Validate `assets/api/rest_v1.yml` and inspect the generated API docs.
4. `dart format lib test`.
5. `flutter analyze`.
6. Full `flutter test`.
7. Start simulated Decaid with `scripts/sb-dev.sh start --connect-machine MockDe1`, then use `curl` to verify:
   - legacy flow-multiplier GET/POST compatibility;
   - current and factory GETs for flow, pressure, and temperature;
   - one PUT followed by a current GET round-trip;
   - malformed target/source/body responses;
   - clean logs before `scripts/sb-dev.sh stop`.

## Baseline note

The pre-change full suite reached 3,020 tests but failed four `webui_token_injection_test.dart` cases because port 3000 was already occupied. Treat this as an environmental baseline issue: rerun those tests with the port free before attributing failures to #613.
