# BLE binding and Sensor checkpoint

Status: draft checkpoint. Follows merged PR #813; does not complete #809.
Baseline: 4939dbb799c60ddf47a7db0a0388859201af572e (origin/main).
Branch: odev/issue-809-ble-sensor-checkpoint.
Contract: #809 and the assignment amendments A-D, reviewed 2026-09-08.
The user authorized a new checkpoint and a draft PR instead of the assignment's
original single-PR delivery. Existing unrelated work remains untouched.

## Design

Reuse PluginBleRegistry, PluginBleSession, PluginDeviceService and the existing
manager invocation bridge. One host-owned binding holds immutable physical and
driver identity; each connection creates a new GATT session. Sensor and Scale
adapters compose the binding rather than placing protocol logic in discovery.

The factory runs once per candidate binding and returns handlers plus Sensor
metadata (vendor, dataChannels, commands). It receives frozen identity and
advertisement metadata, not GATT authority. Publication and failure methods are
provided only on the connection context, as required by amendment C; persistent
factory metadata cannot redirect an old callback into a replacement session.
Cleanup receives a distinct GATT context with invocation-scoped authority.

Discovery retains its scanner and scan ownership. Whole observations enter the
generation-owned evidence cache before the native empty-name gate. All paths,
including system results, background scans and remembered native connections,
arbitrate against the same registry. Registry changes reconcile unconnected
candidates; occupied connections remain stable. Connection admission rechecks
current ownership, and physical exclusion survives unconfirmed native teardown.

Startup waits for initial loader settlement, including failed/disabled plugins.
Factory registration cannot wait on hardware. Unload and shutdown retire sessions
before clearing callbacks; forced process death has no Dart cleanup guarantee.

## Verification

The real-JS tests cover advertisement -> existing selection -> factory/connect ->
fake GATT -> Sensor inventory, commands, and WebSocket snapshots. Discovery tests
cover both evidence orders, conflicts/pending deadline, startup settlement after
load failure, driver load/unload, native admission fencing, and failed-handshake
exclusion. Lifecycle tests cover permanently suspended initialization, throwing
and hanging cleanup, unconfirmed teardown, stale authority, production capacity,
injected two-device isolation, and link-loss/revocation terminal delivery.

UniversalBleTransport integration proves native CCCD reset, logical subscription
replacement, missing-attribute errors, cancellation, and no acknowledged-write
downgrade. Existing Scale and non-BLE Sensor tests remain part of the full suite.

Broad timing/interleaving fuzzing, exhaustive reload-during-selection coverage,
and physical BLE acceptance remain merge-readiness work. The PR records the final
format, analysis, full-test, native-build, and runtime-smoke evidence.

Bookoo protocol/hardware, Scale measurement timing acceptance, optional automatic
Scale operations and sleep policy remain subsequent #809 checkpoints, not claims
of this draft. Existing Scale and non-BLE Sensor compatibility must remain green.
