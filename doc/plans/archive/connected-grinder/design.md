# Connected Grinder design

## Context

Decaid already had persisted Grinder records for workflow metadata, but no
runtime abstraction for a connected grinder. The two identities remain
separate: persisted records use a Grinder UUID, while connected devices use a
transport-owned `deviceId` and the preferred connection is stored as
`preferredGrinderDeviceId`.

## Decisions

- `GrinderDevice` is the transport-independent runtime contract. It owns typed
  state, capabilities, snapshots, and operations without depending on BLE or a
  specific grinder protocol.
- `PluginGrinder` is the only plugin adapter. Both plugin-created network
  devices and BLE driver bindings construct it so session fencing, readiness,
  validation, and command behavior stay identical.
- `GrinderController` owns one selected grinder. Its subscriptions are replaced
  as a generation so publications from a retired instance cannot update the
  current state.
- Generic device connect and disconnect routes own the connection lifecycle.
  There is no grinder-specific connection route or reconnect scheduler.
- Preferred grinder auto-connect uses devices already returned by the normal
  full scan. It does not add a scanner or transport-specific discovery path.
- The singular `/api/v1/grinder` REST surface describes only the connected
  runtime device. The existing plural `/api/v1/grinders` CRUD surface remains
  the persisted workflow catalog.
- The Grinder WebSocket subscribes to the controller rather than a device
  instance. It stays open across disconnect and replacement and emits only
  validated `GrinderSnapshot` objects.

## Validation boundaries

Plugin publications accept only `state`, `setting`, and `rpm`. State is
required, optional fields require their declared capability, RPM is a
non-negative integer, the host supplies timestamps, and stale sessions are
rejected. Optional commands fail with `unsupported_operation` before invoking
plugin code. REST validates its request values before reaching the controller.

## Deliberate exclusions

This design adds no production grinder driver, vendor fields, presets,
workflow synchronization, new discovery mechanism, reconnect scheduler, or
support for multiple selected grinders. Those belong in later work with their
own protocol and product requirements.
