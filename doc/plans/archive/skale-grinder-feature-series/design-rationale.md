# Plugin scale and grinder feature-series rationale

This document records the architecture decisions behind the new feature series. It is a lasting rationale archive, not an implementation checklist.

## Phase ordering

The first Skale driver stage (#846) is single-device and depends on metadata
#844 plus the primary-scale machine-action contract in #845. It is independently
reviewable and excludes host multi-binding #843 and the superseded dosing draft
#834. This stage retains per-physical-instance state and reconnect/session
fencing, and rejects a second binding under the existing one-binding quota.

A later multi-device stage (#859) depends on the accepted single-device stage,
the bounded host capability in #843, the opaque-ID routing boundary in #858,
and the primary/auxiliary decision in #833. It consumes the generic
runtime-only auxiliary connection registry supplied by the separate core/API
change and covers independent same-model instances. A client may use an
auxiliary connection for dosing, grinder comparison, or diagnostics; Decaid
does not persist a dosing selection or expose a dosing-specific role or
endpoint. The generic native settings entry in #849 remains a separate,
client-facing settings surface and does not own connection roles.

The earlier #834 proposal for `DosingScaleController`, `dosingScaleId`, and
`/api/v1/scale/dosing/*` is retained as historical context only. The later
maintainer decision in [#833](https://github.com/decentespresso/decaid/issues/833)
supersedes that shape; no current series stage may treat it as an accepted
dependency.

## Ownership and identity

Dart owns discovery, physical I/O, permissions, binding lifetime, teardown, reconnect, quotas, and host routing. JavaScript owns protocol parsing, per-instance timers and callbacks, plugin settings, and device-specific button policy. A same-model device is still a distinct physical/public instance: mutable state, settings, metadata, callbacks, request IDs, and connection epochs are never keyed only by model or driver.

The host's bounded multi-binding registry is therefore a prerequisite for two identical Skale devices. Connected firmware and battery metadata is session-scoped and uses the existing narrow scale-info projection. `PluginProtocolDevice.connectionId` is a typed identity for the active plugin connection; it is not an inventory extension and does not carry USB provenance. Retired sessions lose publication authority before a replacement can publish.

Guarded machine actions are primary-scale actions. They carry the expected
machine identity and connection generation, public device ID, connection ID,
and selection generation. The queued start rechecks those values, machine
state, definite GHC state, and gateway mode before writing. Auxiliary
connections cannot invoke the machine-action contract. Stop bypasses the
command queue and the full-gateway start restriction; the hardware request
itself remains asynchronous. A stop advances the shared cancellation epoch so
an older queued start cannot issue a later espresso request after the stop.

## Settings authority

USB power is an explicit default-off per-device declaration. It is not inferred charging state and is not published as arbitrary scale metadata. Settings are persisted by the plugin through the existing KV authority, keyed by the stable public device identity; the native settings flow, when implemented, must call that same plugin endpoint. Plugin-global settings remain separate from per-device settings. A native UI must validate a driver-declared endpoint against the loaded manifest and API permission rather than infer URLs from ID prefixes or create a second store.

## Button safety

In the single-device stage (#846), circle is a tare for the active primary
scale. In the later multi-device stage, circle targets the active binding's
scale, whether that binding is primary or auxiliary; brewing square remains a
primary-scale action. Brewing square is a guarded state transition with a
narrow contract: inactive-GHC idle can request espresso; active espresso can
request idle. Sleeping, unknown or missing machine, active or unknown GHC for
start, stale source identity, replacement generation, and full gateway start
conditions are safe no-ops/rejections. Stop uses the direct path and may
proceed through a full gateway. This preserves legacy unguarded machine
requests while making plugin opt-in actions intent- and identity-fenced.

## Grinder read-only boundary

The E64 integration is an opt-in sensor plugin over the existing host-owned WebSocket transport. Each configured grinder owns an independent registration, socket, request counter, pending map, timer, and epoch. The initial contract has four reads: state, config, machine info, and log messages. Unknown and action/write commands are rejected before transmission. No motor, calibration, brew-event, GBS, TLS-trust-bypass, or configuration-write surface is introduced. The #831 SteamSequencer selection fix is a prerequisite so an E64 object channel cannot steal the declared milk-temperature source.

## Review and release posture

The retained native PRs remain independent feature boundaries. New host, metadata, guarded-action, Skale, sensor, E64, settings, and devloop artifacts are prepared as separate review units with explicit prerequisites. Simulator and fake-GATT evidence is useful for deterministic behavior; the captured environment has no real Skale or grinder hardware, so hardware validation remains a maintainer gate. Full-suite and publication status stays in the component handoffs and progress record rather than being inferred from these bodies.
