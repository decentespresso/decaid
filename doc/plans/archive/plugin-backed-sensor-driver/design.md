# Plugin-backed sensor driver

**Date:** 2026-09-03
**Discussion:** [#749](https://github.com/decentespresso/decaid/discussions/749)

## Goal

Prove the plugin device boundary with a humidity sensor whose protocol runs in JavaScript over the existing permission-gated WebSocket transport.

## Decisions

- Add static `drivers` contributions to plugin manifests; they are not permissions.
- The first supported driver type is `sensor`.
- A plugin may register only instances of drivers declared by its manifest.
- Device identity is stable across reloads and derived from plugin id, driver id, and plugin-local instance id; generation is ownership metadata, not identity.
- `ConnectionState.connected` means the plugin's connect handler completed protocol initialization and the sensor is ready.
- Decaid invokes plugin connect, disconnect, and command handlers. Plugins own protocol framing, handshakes, and transport use.
- Registered devices enter `DeviceController` through a plugin-backed `DeviceDiscoveryService`, so existing device inventory and Sensor APIs see them without new REST or WebSocket routes.
- Registration definitions are immutable. State publications are complete, bounded snapshots.
- Registrations, callbacks, and pending commands are owned by plugin id plus generation and are removed or rejected during unload even when `onUnload()` fails.

## Public seams

1. `PluginManifest.fromJson()` validates `drivers`.
2. `host.devices.register(definition, handlers)` registers a declared sensor.
3. The returned device publishes snapshots and reports unsolicited disconnects.
4. Existing `/api/v1/devices`, `/api/v1/sensors`, `/api/v1/sensors/{id}/execute`, and `/ws/v1/sensors/{id}/snapshot` expose the device.
5. Plugin unload/reload/disposal removes stale registrations and closes associated transports.

## Tracer fixture

A test-local WebSocket server:

- sends `{"relativeHumidity":52.4}`;
- accepts `{"command":"sampleNow"}`;
- replies with a fresh humidity sample.

The test plugin declares `network.websocket` plus one `sensor` driver, connects through `host.transport`, registers the sensor, publishes readings, and translates `sampleNow` commands.

## Implementation order

1. Manifest driver parsing and rejection tests.
2. Plugin device service and DeviceController inventory test.
3. `host.devices` registration/publication/command tests.
4. End-to-end fake-WebSocket humidity sensor test through existing Sensor APIs.
5. Generation, unload, malformed input, timeout, and resource-bound tests.
6. Update `doc/Plugins.md`, `doc/DeviceManagement.md`, and correct affected REST schema mismatches.

## Out of scope

- Grinder semantics or `DeviceType.grinder`.
- BLE scanning, matching, GATT access, or probing.
- Migrating existing native devices.
- Remembered/preferred plugin devices.
- Generic device settings/debug UI.
- New generic REST or WebSocket endpoints.
- Shared JavaScript runtime isolation hardening.
