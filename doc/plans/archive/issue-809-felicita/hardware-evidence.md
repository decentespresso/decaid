## Hardware evidence — Felicita Arc plugin driver + host BLE recovery fix

Tablet: M50Mini (adb 8734SCCFAC00000747, Android 14/SDK 34). App: debug `flutter run --real --dart-define simulate=machine --preferred-machine-id MockDe1 --preferred-scale-id felicita-test-awaiting-selection --adb-forward`; MockDe1 simulated machine connected throughout; no real machine.

Plugin: `examples/plugins/felicita-arc.reaplugin` v0.1.0 installed via `PUT /api/v1/plugins/felicita-arc.reaplugin/source` and enabled. Device ID `plugin:felicita-arc.reaplugin:felicita:e0:ff:f1:40:51:74`.

### Driver protocol checks (first session, pre-fix build)

- Initial scan with Felicita powered on found only the plugin candidate (native Bookoo/Felicita absent from matcher); connect HTTP 200.
- Zero weight: 100 samples all 0.0, battery fluctuated 34/38, spacing median 104.7 ms, max 271 ms.
- Loaded 62.1 g: 20/20 samples exactly 62.1 (display 62.1 g confirmed by user).
- Tare: HTTP 200, 20/20 samples 0.0; display zero confirmed.
- Remove object after tare: 20/20 samples -62.1; display -62.1 confirmed.
- Timer start HTTP 200, display counting (user); stop HTTP 200, display stopped (user); reset HTTP 200, display 0 (user).
- Deliberate disconnect HTTP 200; display stayed on, radio off the air (no advertisement observed at OS scan level; user confirms device on/advertising only after power cycle). Matches native sleep-display-as-disconnect semantics.

### Host BLE recovery defect found and fixed

Reproduced: after deliberate disconnect, repeated scans never re-adopted the advertising Felicita; candidate stayed disconnected/unavailable; connect returned 404; cold app restart always recovered it.

Root cause (`lib/src/plugins/plugin_ble_service.dart` `createCandidate`): the binding dedupe reused the retired binding/device whose `PluginProtocolDevice._state` BehaviorSubject replays `disconnected`. The discovery service's adopt listener removes the device on `disconnected`, so every fresh advertisement re-adopted and immediately re-removed the same stale object (infinite bounce, `available:false`). Native devices build a fresh device per advertisement and never bounce.

Fix: `createCandidate` now reuses a binding only while its session is occupied; a closed/retired binding is discarded so the next observation creates a fresh candidate. Regression tests added: `test/plugins/plugin_ble_candidate_recovery_test.dart` (fresh candidate after disconnect; reuse while connected; retired callback/command fencing).

Hardware verification of fix (same running app, no restart): connect HTTP 200, deliberate disconnect HTTP 200, Felicita power cycle, scan -> candidate discovered/available, connect HTTP 200, 15 live samples 0.0 g, spacing median 90 ms. In-process recovery now works.

Local suite after fix: full `test/plugins/` 340 passed, 1 failed. The one failure is pre-existing (also fails on the pre-change baseline): `test/plugins/bookoo_plugin_test.dart` "Bookoo reload preserves identity and fences the retired generation" expects samples `[2,3]`, gets `[2.0]`.

### Second, separate host bug (historical checkpoint; since resolved)

At this checkpoint, post-reconnect live notifications were lost: only the subscribe-time first packet published; later notifications from the replacement session never reached the domain device. This matched the failing Bookoo reload test above. The follow-up reconnect work fixed this host issue and added deterministic live-notification coverage.

### Follow-up hardware verification — 2026-09-10

- Ran Decaid on the same Android tablet in real mode with persisted simulations disabled.
- The first Felicita connect returned Android GATT status 133. Scale Debug showed a retryable connection error; no `stale_session` exception escaped.
- Retry succeeded without rescanning. Android completed service discovery and enabled FFE1 notifications.
- The run exposed a separate Scale Debug omission: direct plugin-scale debugging did not activate `ScaleSnapshotHandoff`, so delivered samples eventually failed with `Scale handoff buffer full`. Scale Debug now activates the handoff after `onConnect()` succeeds, matching `ScaleController` ordering.
- After hot restart, Felicita connected on the first attempt. Weight continued updating, and tare plus timer start, stop and reset all worked.
- Explicit Disconnect returned immediately. Android logged `GATT_Disconnect`, a status-0 connection-state callback, `BluetoothGatt.close()` and `unregisterApp()`; the physical connection indicator turned off about one second later. No teardown timeout or retained-ownership warning occurred.
- Focused reconnect/debug tests: 45 passed. `flutter analyze`: no issues. Serialized full suite: 4051 passed, one skipped. `git diff --check`: clean.

### Acceptance conclusion

PR #823's current hardware gate requires the Felicita plugin path rather than
Bookoo hardware. The recorded connection/readiness, continuous weight, supported
commands, disconnect/reconnect, restart/reselection, and cadence results satisfy
that gate. Bookoo physical testing was not performed and is not claimed.

### Non-blocking caveats

- No native-vs-plugin Felicita A/B on the same hardware in separate sessions was run; native Felicita path untouched. Plugin weight/negative/tare/timer values matched the scale display exactly.
- Battery only observed in 34/38 range; no display-side battery value available for cross-check.
- Two-second silence watchdog: observed cadence median ~90-105 ms, max ~270 ms, far below threshold; cadence on this unit supports the provisional threshold but firmware/model unknown.
- MockDe1 is the simulated machine; no real DE1/Bengle session ran.
