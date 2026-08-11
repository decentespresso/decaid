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

- **`MockDeviceDiscoveryService`:** Controllable discovery for widget tests. Add/remove specific devices at specific times via `addDevice()`, `removeDevice()`, `clear()`.
- **`TestScale`:** Use instead of `MockScale` — `MockScale` has `Timer.periodic` that conflicts with `pumpAndSettle()`.
- **`MockSettingsService`:** In-memory `SettingsService`. Sets `telemetryPromptShown` and `telemetryConsentDialogShown` to `true` to skip dialogs.

## Widget Test Patterns

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
| `replay` | `MockReplayDe1` + `MockReplayScale` (replay recorded shots, matched to the selected profile) |

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
