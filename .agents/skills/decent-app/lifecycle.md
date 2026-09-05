# sb-dev lifecycle

`scripts/sb-dev.sh` drives `flutter run` on macOS and Linux. It injects `--dart-define=simulate=1` by default; `--real` omits that define. The script waits for the REST server, owns the Flutter process, and supports reload, restart, logs, and shutdown. Windows users should run `flutter run` directly and use the other skill files normally.

## Prerequisites

The script requires `bash`, `curl`, `jq`, `mkfifo`, and `flutter` on `PATH`.

## Commands

Run commands from the repository root as `scripts/sb-dev.sh <command>`.

### Start

`start` launches the app and waits up to 120 seconds for `GET /api/v1/devices`. When `--connect-machine` is present, it also scans and waits up to 30 seconds for a matching name or device ID to report `connected`.

| Flag | Purpose |
|---|---|
| `--platform <id>` | Pass `-d <id>` to Flutter. |
| `--connect-machine <name|id>` | Match a machine in the post-boot scan loop. In simulate mode, also set `preferredMachineId`. |
| `--connect-scale <name|id>` | In simulate mode, set `preferredScaleId`. |
| `--preferred-machine-id <id>` | Explicitly set `preferredMachineId`; use a BLE MAC or UUID in real mode. |
| `--preferred-scale-id <id>` | Explicitly set `preferredScaleId`. |
| `--real` | Do not inject `--dart-define=simulate=1`; persisted simulated-device settings still apply. |
| `--adb-forward` | Forward the REST port to an Android device until `stop`. |
| `--dart-define <key=value>` | Pass an additional Dart define; repeat as needed. |

```bash
scripts/sb-dev.sh start \
  --connect-machine MockDe1 \
  --connect-scale MockScale
```

For real hardware, `--connect-machine DE1` can match the advertised name during scanning but does not set a saved preference. Supply the actual BLE device ID separately when needed:

```bash
scripts/sb-dev.sh start \
  --platform 8734SCCFAC00000747 \
  --real \
  --adb-forward \
  --connect-machine DE1 \
  --preferred-machine-id D9:11:0B:E6:9F:86
```

`--real` does not clear simulations enabled in Settings. After settings load, the app combines dart-define devices with the persisted `simulatedDevices` selection. Before a hardware smoke test, verify that the persisted selection is empty:

```bash
curl -sf http://localhost:8080/api/v1/settings \
  | jq -e '.simulatedDevices == []'
```

If the check fails, clear the selection and restart with the saved `--real` flags before testing hardware:

```bash
curl -sf -X POST http://localhost:8080/api/v1/settings \
  -H 'content-type: application/json' \
  -d '{"simulatedDevices":[]}'
scripts/sb-dev.sh restart
curl -sf http://localhost:8080/api/v1/settings \
  | jq -e '.simulatedDevices == []'
```

### Status and logs

```bash
scripts/sb-dev.sh status
scripts/sb-dev.sh logs -n 200
scripts/sb-dev.sh logs --filter scale
```

`status` reports the process, REST reachability, and current device list. `logs` reads `$SB_RUNTIME_DIR/flutter.log`; `-n` defaults to 50 lines.

### Reload and restart

```bash
scripts/sb-dev.sh reload
scripts/sb-dev.sh hot-restart
scripts/sb-dev.sh restart
```

- `reload` preserves widget and app state.
- `hot-restart` rebuilds from `main()` while keeping the Flutter process.
- `restart` stops and starts the app with the last saved flags. Use it for native code, plugin registration, initialization, or suspect process state.

### Stop

```bash
scripts/sb-dev.sh stop
```

`stop` asks Flutter to quit, waits five seconds, then terminates it and removes runtime files and any adb forward.

## Runtime state

Runtime files live under `$SB_RUNTIME_DIR` (default `/tmp/decent-$USER/`):

- `flutter.pid`
- `holder.pid`
- `stdin`
- `flutter.log`
- `last-flags`
- `adb-forwarded`

`SB_HOST` and `SB_PORT` override the REST health-check address, which defaults to `localhost:8080`.

## Recovery

```bash
scripts/sb-dev.sh stop || true
rm -rf "${SB_RUNTIME_DIR:-/tmp/decent-$USER}"
```

See `troubleshooting.md` for platform-specific build failures.

## Windows

`sb-dev.sh` depends on POSIX named pipes. On Windows, run `flutter run --dart-define=simulate=1` in a terminal instead.
