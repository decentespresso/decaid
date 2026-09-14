# Auxiliary scales

Reworks #834 around the generic model asked for on #833: Decaid keeps exactly
one semantically special scale — the primary scale used for brewing — and gains
a way for a client to hold additional scales open with no gateway-defined
meaning attached to them.

The dosing workflow that motivated #834 becomes a client of that API rather
than something the gateway knows about.

## What is removed from #834

The dosing-scale picker #834 added to `device_management_page.dart` goes with
them. Under this model there is no app-level dosing scale to pick: the hold is
made by whichever client wants the scale, for as long as it wants it, and the
app has no setting to store.

- `DosingScaleController`, a second singleton beside `ScaleController`.
- `dosingScaleId` as a persisted setting, and its settings service/controller
  surface.
- `/api/v1/scale/dosing/tare` and `/ws/v1/scale/dosing/snapshot`.
- The Bengle restriction: an integrated primary scale no longer stops a client
  connecting an external scale as auxiliary.

## What it becomes

### Connection role

`PUT /api/v1/devices/connect` takes an optional `connectionRole`:

```json
{ "deviceId": "...", "connectionRole": "auxiliary" }
```

Omitted, or `"primary"`, is exactly today's behaviour. `"auxiliary"` is
accepted for scales only.

The device inventory reports the current local relationship for connected
scales:

```json
{ "id": "...", "type": "scale", "state": "connected", "connectionRole": "auxiliary" }
```

`connectionRole` is the connection's semantics, not the application's purpose
for the device. The two are deliberately separate: a scale provided by another
Decaid instance could still be either the local primary or a local auxiliary.

### Registry rather than a second controller

`AuxiliaryScaleRegistry` holds zero or more `AuxiliaryScaleSession`s keyed by
device id. A session is the per-scale lifecycle that #834 reviewed as
`DosingScaleController`: connect, adopt, independent snapshot stream,
independent tare, disconnect, and a connection generation that fences a slow
connect against a newer one.

`ScaleController` is untouched and remains the only thing `ShotSequencer`,
tare-before-shot, stop-at-weight and shot recording ever read.

### Addressing a scale by id

```text
ws/v1/scales/{id}/snapshot
PUT /api/v1/scales/{id}/tare
```

These address that connected scale whether it is primary or auxiliary. The
existing `/scale/...` routes stay as the convenience API for the primary.

Ids are opaque: encoded once by the client, decoded once at the route boundary
with `decodeOpaquePathComponent`, per the convention #858 is establishing.
That PR is not merged yet, so this branch carries the helper file; if #858
lands first the duplicate is dropped on rebase.

### Runtime only

An auxiliary connection never writes `preferredScaleId` and has no persisted
equivalent. It does not survive a restart. Disconnecting it returns the device
to ordinary primary eligibility.

## Rules the implementation has to keep

1. A device is primary or auxiliary, never both. Claiming a device that is
   already the other way round is a conflict, and claiming it the same way
   again is idempotent.
2. While a device is held as auxiliary, primary auto-selection skips it. This
   is the only thing standing between "two scales in range" and the shot being
   weighed on the wrong one.
3. Nothing in the brewing path may reach an auxiliary session.
4. A slow auxiliary connect is bounded and counted as connection work, so a
   scan cannot start on top of it.

## Acceptance

Mirrors the eleven points asked for on #833:

1. With no auxiliary scale connected, primary selection, persistence, REST/WS
   and shot behaviour are unchanged.
2. A client can connect an additional scale as auxiliary without touching
   `preferredScaleId`.
3. Primary and auxiliary publish independent snapshots; a tare reaches only the
   addressed device.
4. Two auxiliary sessions coexist; one disconnect does not disturb the other.
5. An auxiliary-held device is excluded from primary auto-selection, and
   eligible again after disconnect.
6. The same device cannot be claimed both ways; conflict and idempotency are
   deterministic.
7. Auxiliary state is not restored after restart.
8. Bengle integrated primary plus external auxiliary works without weakening
   Bengle's primary-selection policy.
9. `{id}` routes encode/decode once, including ids containing reserved
   characters.
10. `ShotSequencer`, tare-before-shot, stop-at-weight and shot recording read
    only `ScaleController`.
11. `assets/api/rest_v1.yml`, `assets/api/websocket_v1.yml`, `doc/Api.md` and
    `doc/DeviceManagement.md` change with the code.

### Where each point is checked

| # | Checked by |
|---|---|
| 1 | The pre-existing suites are unchanged apart from one inventory expectation that now carries `connectionRole: primary`; `availability_device_list_test.dart` asserts the field is absent when nothing is held. |
| 2 | `devices_handler_test.dart` - "auxiliary holds the scale without making it the primary". No code path writes `preferredScaleId` from the auxiliary route. |
| 3 | `auxiliary_scale_registry_test.dart` - "two scales coexist, each with its own readings"; `scales_handler_test.dart` - tare reaches only the addressed scale. |
| 4 | `auxiliary_scale_registry_test.dart` - "releasing one leaves the other connected". |
| 5 | `auxiliary_scale_registry_test.dart` - the "a held scale is not a candidate for brewing" and "the list brewing is offered" groups, plus "a released scale becomes an ordinary brewing candidate". |
| 6 | `devices_handler_test.dart` - "the brewing scale cannot also be held as auxiliary" and "asking twice is the same request twice"; `auxiliary_scale_registry_test.dart` - "holds a scale and hands the same session back". |
| 7 | Nothing writes a setting or a database row; `ConnectionManager.shutdown()` calls `releaseAll()`, covered by "shutdown lets go of every hold". |
| 8 | `devices_handler_test.dart` - "a machine-held primary and an auxiliary coexist". |
| 9 | `scales_handler_test.dart` - "an id encoded once is decoded exactly once", using an id containing a literal `%`, which is the only case that distinguishes one decode from two. |
| 10 | `AuxiliaryScaleRegistry` is referenced only by `ConnectionManager`, `ConnectionSelectionSession`, the two web handlers and `main.dart`; nothing in the shot path names it. |
| 11 | Done in this change.
