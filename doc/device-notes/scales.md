# Scale Device Notes

Named scale protocols, readiness gates, and hardware-specific troubleshooting.
Generic scale lifecycle and connection policy remain in
[`DeviceManagement.md`](../DeviceManagement.md).

## Optional GATT attributes

`characteristicNotFound` and `serviceNotFound` do not prove that a device is
gone. Solo Barista (`LSJ-001`) is routed to `EurekaScale` but has no `0x180F`
battery service. Optional reads must be gated on discovered services.
`UniversalBleTransport` probes OS link state before declaring a stale GATT
cache disconnected.

## Decent Scale and Half Decent Scale

An awake BLE Decent Scale requires a recognized FFF4 status or weight frame
after subscription and a status request. Two seconds of silence triggers one
resubscribe and status request; a second silent window tears down the transport
without sending physical power-off. A sleeping reconnect restores the
subscription and defers readiness verification until wake.

USB `HDSSerial` enables the 10 Hz OpenScale binary stream and remains
`connecting` until a checksum-valid weight frame arrives. Its decoder accepts
fragmented or coalesced frames mixed with firmware text.

WiFi HDS uses JSON over WebSocket:

- Discovery browses `_decentscale._tcp`; manual endpoints are persisted as a
  fallback.
- Device identity is `wifi:<host>`, distinct from BLE and USB identities.
- Connect sends `rate 10k`, `events on`, then `status`.
- A `grams` or `status` frame must prove the endpoint is an HDS before it is
  reported connected.
- A silent socket emits `disconnected`; `ConnectionManager` owns reconnects.
- Reconnect tries the cached IPv4 address before resolving again.
- iOS/macOS require the Bonjour service and local-network declarations; Linux
  discovery requires Avahi or a manual endpoint.

## Acaia

Parsing is frame-bounded. Payloads over 64 bytes and impossible lengths for
known settings or weight events trigger `EF DD` header resynchronization.
Complete unsupported frames are consumed whole. Only accepted settings,
weight, or timer frames refresh liveness.

Event 11 selector 5 carries weight; selector 7 carries timer data. Readiness
requires a valid decoded weight frame, not an arbitrary notification.

## AtomHeart Eclair

- Service: `B905EAEA-2E63-0E04-7582-7913F10D8F81`
- Data/status: `AD736C5F-BBC9-1F96-D304-CB5D5F41E160`
- Command: `4F9A45BA-8E1B-4E07-E157-0814D393B968`
- Commands: timer reset `520101`, start `530101`, stop `450101`, tare `540101`

The device remains `connecting` until a valid checksummed `0x57` weight frame
arrives. The frame is exactly ten bytes: header, four little-endian weight bytes
in milligrams, four timer bytes, and an XOR checksum over bytes 1 through 8.

Silence for 800 ms resets the notification subscription at most twice. A third
silent window tears down the transport for `ConnectionManager` recovery.

## Scale maintenance

Use self-scheduling one-shot timers and own each asynchronous operation before
scheduling the next cycle. Do not issue asynchronous BLE writes directly from
`Timer.periodic`. Decent Scale notification recovery remains single-flight
across connection generations.

## Troubleshooting

If a scale is found but does not connect, check the preferred scale ID, existing
scale occupancy, `DeviceMatcher`, BLE permissions, stale discovery entries, and
`connectionStatus.pendingAmbiguity` on `/ws/v1/devices`.

For Acaia weight errors, inspect frame length, event type, and event-11 selector.
Timer frames and information frames must not establish readiness.
