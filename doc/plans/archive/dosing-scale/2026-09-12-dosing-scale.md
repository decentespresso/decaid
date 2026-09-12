# Dosing scale — a second scale, alongside the brew scale

Branch: `feat/dosing-scale`. Additive: a second scale for weighing the dose, with the brewing path left as it is.

## Context

`ScaleController` holds one scale:

```dart
class ScaleController {
  Scale? _scale;
```

Everything that reads weight hangs off that single slot — `connectionGeneration`, `currentWeightSnapshot`, `weightSnapshot`, and through them `ShotSequencer` (tare at shot start, stop-at-weight, the shot record). The REST and WebSocket surface is singular to match: `PUT /api/v1/scale/tare`, `ws/v1/scale/snapshot`, with no way to name a scale.

Baristas weigh the dose on one scale and the shot on another. Today the second one cannot be connected at all. Concurrent multi-scale streams are a known gap, logged as P2 during the Bengle work (`archive/bengle-integrated-scale/2026-05-05-bengle-integrated-scale.md`, D1) and confirmed by upstream as not currently planned.

Two scales connected at once has been verified on hardware by the reporter; BLE adapter contention is not the open question here.

## Decisions

### D1 — A separate controller, not a role map inside `ScaleController`

`DosingScaleController` is a new class with its own slot, its own connection subscription and its own snapshot stream. `ScaleController` is not modified.

**Rationale.** The alternative — turning `_scale` into `Map<ScaleRole, Scale>` — is the design upstream will presumably land eventually, and it is the better end state. It is also a change to the class every part of the brewing path reads from, which puts tare-before-pour, stop-at-weight and shot recording on the diff. The value here is a dosing readout, which no part of brewing consumes. Paying for it with regression risk in the shot path is the wrong trade.

**Trade-off accepted.** Two classes share shape without sharing code. If upstream lands role-keyed multi-scale, this becomes redundant and should be removed rather than kept alongside it.

**Rejected — reuse `ScaleController` with a second instance.** It carries flow smoothing, a display estimator and a snapshot session built for the shot path; a dosing readout needs a weight and a tare. A second instance would also pull `ShotSequencer` wiring in by construction.

### D2 — The dosing scale is chosen by id, and the brewing path only learns to skip it

A `dosingScaleId` setting sits beside the existing `preferredScaleId`. Selection changes in exactly one place:

```dart
bool acceptsScale(Scale scale) =>
    isActive &&
    scale.deviceId != dosingScaleId &&        // <- added
    scales.any((candidate) => candidate.deviceId == scale.deviceId);
```

The brewing path's rule becomes "every scale except the one reserved for dosing". The dosing controller takes that id and nothing else.

**Rationale.** This is the one place where two scales are ambiguous, and it is the whole of the brewing path's exposure: a single exclusion, no change to what happens after a scale is accepted.

**Rejected — first-come-first-served with a role assigned afterwards.** Whichever scale advertises first would become the brew scale, so the shot would be weighed on whichever scale woke up first.

### D3 — New endpoints beside the existing ones, never changing them

```
ws/v1/scale/snapshot              unchanged
ws/v1/scale/dosing/snapshot       new
PUT /api/v1/scale/tare            unchanged
PUT /api/v1/scale/dosing/tare     new
```

**Rationale.** Other skins read the existing surface. Adding a role parameter to `PUT /api/v1/scale/tare` would be tidier but changes a request every skin already sends; a separate path cannot.

**Rejected — a `role` query parameter on the existing endpoints.** Tidier and closer to where upstream will land, but it puts every existing skin's tare call on the diff for a feature none of them use.

### D4 — Disabled while a Bengle is connected

A Bengle's integrated scale takes the brew slot and external scale discovery is skipped for the duration (`archive/bengle-integrated-scale`, D3). The dosing scale is unavailable in that state and reports as disconnected.

**Rationale.** The alternative is to re-enter external discovery for the dosing scale alone while the Bengle path deliberately avoids it, which contradicts a decision taken for that machine.

### D5 — No part of a shot reads the dosing scale

`ShotSequencer`, stop-at-weight, tare-before-pour and the shot record continue to read `ScaleController` only. The dosing weight reaches the skin over its own socket and goes into the workflow as `targetDoseWeight` the way a typed dose does.

**Rationale.** A dose is weighed before the shot. Nothing during extraction needs it, so nothing during extraction should be able to be broken by it.

## Scope

| Work | Size | Touches the brewing path |
|---|---|---|
| `DosingScaleController` | ~150 lines | no |
| `dosingScaleId` setting + device-management surface | ~80 | no |
| `acceptsScale` exclusion | ~5 | **yes, here only** |
| `/api/v1/scale/dosing/tare`, `ws/v1/scale/dosing/snapshot`, specs | ~120 | no |
| Tests | ~200 | — |

## Verification

- The exclusion: a scale whose id is `dosingScaleId` is refused by the brewing selection, and every other scale is still accepted.
- Both connected at once: brew and dosing snapshots arrive on their own sockets, taring one does not tare the other.
- One scale only: with no `dosingScaleId` set, the brewing path behaves exactly as it does today — this is the regression that matters.
- A Bengle machine: the dosing surface reports disconnected and external discovery is untouched.
- `flutter test` in full, and `flutter analyze`.

## Upstream

Offered to `decentespresso/decaid` as a PR. If role-keyed multi-scale lands there instead, this comes out rather than sitting beside it.

## Open

- Whether the dosing weight should be able to fill `targetDoseWeight` automatically on settle, or only when the skin asks for it. Proposed: only when asked, since a scale left switched on would otherwise keep rewriting the recipe.
