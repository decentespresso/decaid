# AI Testing Notes

Read this when writing tests, choosing test tiers, debugging widget tests, or adding test helpers. Skip it for pure doc/config changes.

## Test Commands

```bash
flutter test                              # All tests
flutter test test/path/to_test.dart       # Specific file
flutter test --name "test pattern"        # Specific test
flutter analyze                           # Static analysis (required before commit)
```

## Test Tiers

| Tier | What | Mock boundary |
|------|------|---------------|
| **Unit** | Single controller, model, DAO, handler | Direct collaborators mocked |
| **Integration** | Multi-component flows (e.g., scan → connect → measure) | Only hardware/transport edge mocked |
| **End-to-end** | API surface, WebSocket streams, full-stack through running app | App in simulate mode (MockDe1, MockScale) |

All Dart tests (unit + integration) live in `test/` and run via `flutter test`. End-to-end regression recipes live under `.agents/skills/decent-app/scenarios/` — run them via `scripts/sb-dev.sh` + `curl` / `websocat`.

## Test Helpers (`test/helpers/`)

- **`FakeBleTransport`:** `queueOnConnectResponses()` also queues `MMRItem.calFlowEst` (raw `1000` = `1.0`; override via `calFlowEst:`). Without it, every `onConnect()` pays the full MMR timeout (~12.6s: 3 x 4s + 2 x 300ms) because `UnifiedDe1.onConnect()` reads flow calibration last. `emitNotification(Endpoint, bytes)` pushes a characteristic notification through the registered subscriber (e.g. `Endpoint.shotSample`), keeping notification/input boundary tests out of private internals.
- **`MockDeviceDiscoveryService`:** Controllable discovery for widget tests. Add/remove specific devices at specific times via `addDevice()`, `removeDevice()`, `clear()`.
- **`TestScale`:** Use instead of `MockScale` — `MockScale` has `Timer.periodic` that conflicts with `pumpAndSettle()`.
- **`MockSettingsService`:** In-memory `SettingsService`. Sets `telemetryPromptShown` and `telemetryConsentDialogShown` to `true` to skip dialogs.

## Widget Test Patterns

### fake_async
`fakeAsync` does not cooperate with rxdart `BehaviorSubject` seed delivery (the `StartWithStreamTransformer` seed event never reaches the fake zone's microtask queue). Prefer a plain `Stream.multi` replay (e.g. `Stream.multi((c) { c.add(value); c.close(); })`) for test doubles whose connection state must be visible under `fakeAsync`.

Standard stream subscription `cancel()` futures also never complete under `fakeAsync` (plain `StreamController`, broadcast, single-sub, and rxdart alike). If a test double's `cancel()` hangs, fix the test double or its stream implementation — do not weaken production to accommodate it. `test/helpers/completing_cancel_stream.dart` exposes any controller-backed stream through a subscription whose `cancel()` completes immediately while delegating event delivery; Acaia and DecentScale tests use it for their connection-state streams. Production code should keep `await subscription.cancel()` unless the lifecycle semantics explicitly do not require cancellation completion (then `unawaited` is fine, but that is a production decision, not a fake-time workaround).

### fakeAsync + wall clock
`fakeAsync` virtualizes timers but code that reads `DateTime.now()` still sees real time. When watchdog/throttle logic combines timers and wall-clock comparisons, make both controllable: inject `DateTime Function() now` at the device boundary, defaulting to `clock.now` (`package:clock` is fake_async-aware, and identical to `DateTime.now` outside a fake zone). Then `fakeAsync` tests get deterministic liveness/watchdog coverage with production durations, no manual clock bookkeeping.

### Hardware settle delays
Hardware/protocol settle delays (e.g. Acaia `100/200/500ms` init steps, Skale2 `1s` init steps) should be configurable at the device implementation boundary (immutable timing object or optional constructor durations). Production keeps the real hardware-safe defaults. Unit tests that merely need an initialized device inject zero durations. Only tests specifically validating timing should exercise the actual durations — virtually via `fakeAsync`.

### Backoff semantics vs post-backoff behavior
Distinguish: (1) tests proving the duration/backoff policy itself — use `fakeAsync` and keep production durations virtually; and (2) tests proving behavior that occurs *after* a delay (e.g. `ConnectionManager` scale reacquisition) — inject a zero/small base delay (`scaleReconnectBaseDelay`, `machineReconnectBaseDelay` are `@visibleForTesting` seams) and synchronize on the resulting event. Do not spend real seconds merely to reach the state being asserted.

### Expensive setup inside parameterized tests
A loop that re-constructs and fully initializes a simulated hardware device per case multiplies protocol settle time by the number of cases. When the subject is parsing/encoding rather than connection init, use a cheap deterministic initialized fixture (`Duration.zero` settles). Do not shrink the test matrix because its setup was accidentally expensive.

### UnifiedDe1 connect fixtures
A silent DE1 transport that intentionally causes the MMR timeout is appropriate only when timeout/retry behavior is the subject. Unrelated parser, state, notification, or error-surfacing tests should provide complete connect responses — normally `FakeBleTransport.queueOnConnectResponses()` — then emit input through `emitNotification()`/`queueRead()`.

### Suite wall span vs active test time
Under concurrent `flutter test` runs, a suite's wall span (first test start to last test end) is not equivalent to its CPU/active cost — an isolate can sit idle waiting on the scheduler while another suite runs. When identifying optimization candidates use the cumulative sum of individual test durations (the `duration_ms` field in `--machine` events), not the suite wall span. Inspect the individual tests in a file before assuming a long suite span means expensive tests.

### Mock simulator tick cadence
Mock device simulators (`MockDe1` et al.) drive their state machine with a periodic tick whose model time-step is fixed (100ms of simulated time per tick). The wall-clock tick cadence is injectable (`MockDe1(simulationTickInterval: ...)`): shortening it makes simulated time run faster than wall time without changing generated values, because trajectories are per-tick-count functions. When a simulation test asserts on curve shape or trajectory, shorten the tick and scale wall delays accordingly (e.g. 9000ms wait at 100ms ticks becomes 900ms at 10ms ticks — same 90 ticks, same simulated 9s). Do not scale wall delays alone (that changes the simulated trajectory) or change the model time-step (that changes the calibration). Tests that validate realistic elapsed-time behavior (e.g. a power-off timeout window measured with a Stopwatch) should keep real durations.

### Stream Propagation
Add devices to mock service *before* building widgets, then `await tester.pump()` to flush microtasks before `pumpWidget()`.

### ShadApp Wrapping
Use `ShadApp(home: Scaffold(body: child))` — `Scaffold` provides `Material` ancestor for `ListTile`/`Checkbox`.

### Animations
Use `pump()` not `pumpAndSettle()` when tree has `CircularProgressIndicator` or ongoing animations.

### DeviceDiscoveryView
Use `tester.runAsync()` — it uses real `Future.delayed` and stream microtask propagation.

### StreamBuilder Patterns
- Check both `hasData` AND `data != null` for nullable streams (e.g., `De1Interface?`)
- Use explicit type parameters: `StreamBuilder<De1Interface?>`
- Lifecycle-aware widgets: implement `WidgetsBindingObserver`, set stream to `null` when backgrounded

## Simulated Devices

Available via `--dart-define=simulate=1` or settings UI toggle. For end-to-end API smoke tests, use `scripts/sb-dev.sh start` which defaults to simulate mode.

| Flag value | Devices |
|------------|---------|
| `1` | All: `MockDe1`, `MockScale`, `MockBengle`, `MockSensor` |
| `machine` | `MockDe1` only |
| `scale` | `MockScale` only |
| `bengle` | `MockBengle` only |
| `sensor` | `MockSensor` only |
| `replay` | `MockReplayDe1` (single device: replays recorded shots matched to the profile) |

## Pre-Commit Checklist

1. Run relevant tests + `flutter analyze`. Fix immediately if anything fails.
2. Run full `flutter test` before committing and before claiming done.
3. Evidence before assertions — show test output, not just "tests pass."

## Verification Tiers (non-code changes)

- **Analyze only** — `flutter analyze`. Minimum for any change.
- **Run app** — run with `simulate=1` so user can visually verify. For GUI/UX changes.
- **End-to-end smoke test** — use `scripts/sb-dev.sh` + `curl` / `websocat` to exercise affected endpoints.
- **Custom check** — user specifies (e.g., real hardware test, WebSocket stream check).

## Keeping Notes Fresh

Add widget test gotchas, mock helper changes, and test infrastructure patterns. Prune when test APIs change.

## Plugin transport tests (`test/plugins/plugin_manager_transport*_test.dart`)

`PluginManager` accepts optional `connectWebSocket` / `connectSocket` /
`connectSecureSocket` connectors (defaulting to `WebSocket.connect` /
`Socket.connect` / `SecureSocket.connect`) forwarded to
`PluginTransportService`. Tests use them for:

- **Backpressure accounting:** `_BlockingWebSocket` never completes
  `addStream`, so the test deterministically exercises the outbound byte
  limit without depending on kernel socket-buffer sizes.
- **TLS/WSS positive paths:** platform trust validation cannot be exercised
  offline. Verified empirically that dart:io on this platform ignores
  user-supplied trust anchors: `SecureSocket.connect(context:
  SecurityContext()..setTrustedCertificates(ca))` and
  `WebSocket.connect(customClient: HttpClient(context: ...))` both fail with
  CERTIFICATE_VERIFY_FAILED for a CA-signed local server cert. The rejection
  tests prove the default connectors validate against the platform store; the
  positive tests inject connectors that accept the local self-signed
  certificate (`onBadCertificate` / `badCertificateCallback`) and still run a
  real TLS / TLS-wrapped-WebSocket round trip.
