# Decision: Drop the Bengle old-firmware compat layer

Status: **implemented** (PR #612, 2026-08-15).

## Context

PR #612 originally introduced a single-surface contract with a firmware
compatibility probe: a current-firmware Bengle advertised the full 7-item
capability list; older firmware got an empty list, 404s on every Bengle
endpoint, and an `extra.bengleFirmwareSurface: outdated` marker.

The compat layer cost more than it protected: per-endpoint gates, nullable
API schemas, an outdated-state mock flag, a whole test axis — and the
self-review of #612 showed the contract leaked (integrated-scale attach,
SAW bypass, and SAW bridge all treated any `BengleInterface` as
current-firmware).

## Decision

**Option A — delete the probe and all old-firmware support entirely.**
Every Bengle is assumed to run the current firmware surface
(`BengleMainCPUFirmware` at `2377c7e0`, MMR rows 39+). No probe, no
per-endpoint gating, no reduced capability set:

- `BengleFirmwareProbe` mixin and `supportsCurrentBengleFirmwareSurface`
  removed everywhere (interface, impls, mocks, controllers, handlers).
- Capabilities: the full 7-item set for every Bengle, empty for plain DE1s.
- Bengle endpoints 404 only on non-Bengle machines.
- `extra.bengleFirmwareSurface` removed from `/machine/info`.
- Temporary internal-surface guards added during the self-review fixes
  (virtual-scale attach, SAW bypass, SAW-bridge write) reverted — dead once
  the surface is assumed.

Option B (probe failure refuses the connection with a clear error) was
rejected: **no pre-`2377c7e0` Bengles exist in the field**, so there is no
old firmware to refuse and no error message to write.

## Rationale

- No real old-firmware Bengles exist (confirmed 2026-08-15).
- Decaid has no Bengle firmware-update path, so a connected-but-degraded
  state had no escape route for the user anyway.
- Scattered MMR timeouts on hypothetical old firmware are acceptable: the
  LED hydration path already degrades to 503 on failed reads, and the
  remaining surfaces fail loudly rather than silently.

## Verification

- `rg 'supportsCurrentBengleFirmwareSurface|bengleFirmwareSurface|BengleFirmwareProbe'`
  returns nothing in `lib/`, `test/`, `assets/api/`, `doc/Api.md`,
  `doc/DeviceManagement.md`, `doc/AI_BENGLE_NOTES.md`.
- Spec (`rest_v1.yml`), `doc/Api.md`, `doc/DeviceManagement.md`,
  `doc/AI_BENGLE_NOTES.md` updated in the same commit.
- Full test suite green; probe and outdated-firmware tests deleted.
