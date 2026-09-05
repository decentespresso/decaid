# Simulated devices

Decent ships with in-process device implementations for development without hardware. Simulate mode is enabled with `--dart-define=simulate=1`, a comma-delimited subset such as `--dart-define=simulate=machine,scale`, or the Settings UI. The current `SimulatedDevicesTypes` values are `machine, scale, sensor, bengle, replay`. `sb-dev start` enables the default set from `lib/main.dart`; `--real` omits `--dart-define=simulate=1` but does not clear devices enabled in Settings. Before testing hardware, use the verification and cleanup steps in `lifecycle.md`.

## Available mocks

Registered in `lib/src/services/simulated_device_service.dart`:

| Type    | Internal id         | REST `name` field | Source |
|---------|---------------------|-------------------|--------|
| Machine | `MockDe1`           | `MockDe1`         | `lib/src/models/device/impl/mock_de1/mock_de1.dart` |
| Bengle  | `MockBengle`        | `MockBengle`      | `lib/src/models/device/impl/bengle/mock_bengle.dart` |
| Replay  | `MockReplayDe1`     | `Replay DE1`      | `lib/src/models/device/impl/replay/mock_replay_de1.dart` |
| Scale   | `MockScale`         | `Mock Scale`      | `lib/src/models/device/impl/mock_scale/mock_scale.dart` (id is `MockScale`; `name` carries the space) |
| Sensor  | `MockSensorBasket`  | `SensorBasket`    | `lib/src/models/device/impl/sensor/mock/mock_sensor_basket.dart` |
| Sensor  | `MockDebugPort`     | `DebugPort`       | `lib/src/models/device/impl/sensor/mock/mock_debug_port.dart` |

The internal id (left column) is what you pass to `preferredMachineId` / `preferredScaleId` dart-defines and to `sb-dev`'s `--connect-machine` / `--connect-scale` flags — case-sensitive. The REST `name` is what you match on when reading `/api/v1/devices`.

**Scale weight synthesis.** `MockScale`'s weight follows the simulated machine's flow — `SimulatedDeviceService` wires it to the enabled mock machine on every scan. Like real scale firmware, the emitted stream is stability-filtered: at rest it holds one steady value (~0 after tare), and only actual weight changes move the reading (with a hair of load-cell jitter while in motion). During a simulated espresso shot the weight lags the pour start (preinfusion absorbed, first-drops holdback, ramp-in) and then tracks flow 1:1; hot water lands in the cup directly. The same model (`lib/src/models/device/impl/simulated_shot_weight_model.dart`) drives `MockBengle`'s integrated scale. With no mock machine enabled the scale just sits at ~0 — it no longer self-generates a climbing weight, so weight-based flows (SAW, shot timers) only trigger when the machine actually pours.

## Auto-connect fast-path

`sb-dev start --connect-machine MockDe1 --connect-scale MockScale` translates to:

```bash
flutter run \
  --dart-define=simulate=1 \
  --dart-define=preferredMachineId=MockDe1 \
  --dart-define=preferredScaleId=MockScale
```

`lib/main.dart` (~line 360) reads those defines and seeds `settingsController.setPreferredMachineId` / `setPreferredScaleId`, which `ConnectionManager` then uses to bypass the device selection screen and direct-connect on the first scan. After boot, `sb-dev`'s `connect_machine` helper polls `GET /api/v1/devices/scan?connect=true` and `GET /api/v1/devices` in a 30s loop, checking with `jq` that an entry with the requested machine `name` has `state == "connected"` before returning. For the scale, `sb-dev` just passes the dart-define and trusts the auto-connect — no post-boot verification.

## Typical TDD recipes

Unit / widget tests — no app, no simulate flag needed:

```bash
flutter test test/controllers/shot_controller_test.dart
```

Integration flow against a running app:

```bash
scripts/sb-dev.sh start --connect-machine MockDe1
curl -s http://localhost:8080/api/v1/machine/state | jq .
```

Full shot flow with machine + scale:

```bash
scripts/sb-dev.sh start --connect-machine MockDe1 --connect-scale MockScale
curl -sX POST http://localhost:8080/api/v1/machine/profile \
  -H 'content-type: application/json' --data @test_data/profile.json
curl -sX PUT http://localhost:8080/api/v1/machine/state/espresso
websocat --no-async-stdio -n -U -t --max-messages-rev 20 \
  ws://localhost:8080/ws/v1/machine/snapshot | jq -c .
```

See `websocket.md` for why all four of `--no-async-stdio -n -U -t` are needed.

## Cleaning state between runs

- **Hot restart** (`sb-dev hot-restart`) rebuilds the widget tree from `main()` but keeps the process and every on-disk file intact.
- **Cold restart** (`sb-dev stop && sb-dev start`) gives a fresh flutter process, but the Drift SQLite DB and `shared_preferences` survive.
- **Fresh slate** - stop the app, remove the runtime directory, then remove persistent state from the resolved support directory:

```bash
scripts/sb-dev.sh stop
rm -rf "${SB_RUNTIME_DIR:-/tmp/decent-$USER}"
```

Persistent desktop state lives under `AppDirectories.support`, which uses `getApplicationSupportDirectory()`. Run the desktop executable with `--print-storage-paths` and remove only the reported `support:` path after backing up anything needed. Do not assume the Documents directory; see `doc/AI_STORAGE_NOTES.md`.

## Known weirdness

- **First scan can be empty.** `SimulatedDeviceService.enabledDevices` is populated by a `settingsController` listener (`lib/main.dart` ~line 349). If you scan before that listener fires, `scanForDevices()` returns with no devices and the stream emits nothing. `sb-dev connect_machine` works around this with a 30s re-scan loop; a manual `curl /api/v1/devices/scan?connect=true` may need retrying.
- **Scale id `MockScale` vs display name `Mock Scale`.** The scale's `deviceId` is `MockScale` (no space) — that's what you pass to `preferredScaleId` / `sb-dev --connect-scale` and what matches in connection policy. Its human-facing `name` field returned by `/api/v1/devices` is `"Mock Scale"` (with a space), so filter on `"Mock Scale"` when matching by name. The `MockDe1` machine uses the same string for both.
