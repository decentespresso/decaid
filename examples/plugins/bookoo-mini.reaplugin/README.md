# Bookoo Mini Reference Driver

Opt-in example for #809, not a bundled plugin or a replacement for native Bookoo.
Requires the host BLE binding, Scale integration, and sample-provenance checkpoints.
Use the existing plugin source-development endpoint or directory loader described
in `doc/Plugins.md`; this directory supplies its manifest and JavaScript source.

An enabled matching runtime binding overrides native Bookoo on subsequent discovery.
Disabling/unloading it permits native discovery again. A plugin handshake failure
does not switch protocol implementations during that attempt. Native/plugin IDs
are different and stored preferences are never silently rewritten.

## Protocol

- Service 0ffe, notifications ff11, acknowledged commands ff12, normalized to 128-bit UUIDs.
- Exactly 20 bytes, header 03 0b, sign 2b/2d, three-byte magnitude in hundredths of a gram, XOR checksum.
- Battery byte 13 retains the last valid 0..100 value; initial unknown battery is null, unlike native's historical zero.
- Tare 01 and timer start/stop/reset 04/05/06 use the existing six-byte command format.
- Readiness waits for a valid accepted weight. Notifications retain host sample provenance.
- Display sleep is a deliberate host disconnect; wake/reconnect remains host policy.
- The silence watchdog starts after successful notification subscription, or on the first valid packet if it arrives earlier, and resets on each valid packet. Native subscription setup has its own GATT deadline. Two seconds without a valid packet reports protocol failure, not a plugin reconnect attempt. This provisional threshold requires hardware confirmation.

## Evidence and Remaining Gates

Automated tests compare shared native/JS packet and command fixtures, real JS GATT
and ScaleController behavior, HTTP/WebSocket routes, sleep/reconnect, stale callbacks,
protocol silence, and persisted preference discovery after simulated process restart.

No physical Bookoo hardware has been tested in this checkpoint. Before readiness,
record separate native/plugin runs on the same device: model, firmware, host platform,
connection/first packet, loaded weight, tare, all timer controls, sleep, reconnect,
restart discovery and observed packet cadence/latency. No full application UI or
unverified-platform acceptance is implied by fake GATT tests.
