# Example plugin guidance

This directory contains opt-in reference plugins. Keep each example small,
protocol-focused, and consistent with the host contracts documented in
[`doc/Plugins.md`](../../doc/Plugins.md). The Bookoo and Felicita examples are
reference implementations; preserve their notes and scope when adding another
example.

## Instance ownership

- For BLE drivers, `create()` must return an independent driver instance for
  one physical device. Every timer, subscription, pending read, callback,
  connection context, publication state, command state, and generation belongs
  to that instance. Sensor registrations use the same per-instance ownership
  rule in their `onLoad` and registration state.
- A single-device stage must still keep one physical instance's state isolated
  and reject a second binding under the existing device quota. When concurrent
  same-model support is introduced, the plugin must support two physical
  devices at the same time. Never key mutable state only by model, driver id,
  or a single module-level `active` value.
- Persisted settings and published data use the physical identity supplied by
  the host. Reconnecting or retiring one binding must not alter its sibling.

## Session and transport boundary

JavaScript owns protocol decoding and encoding, readiness, protocol timers,
validated device values, and plugin commands. Dart and the host own physical
I/O, discovery, BLE permissions, connection ownership, quotas, teardown,
reconnect, and publication enforcement. Use the host's existing transport and
session APIs; do not add a second BLE or settings authority in an example.

Capture the connect context and its generation in every asynchronous callback.
Before publishing, completing a command, or scheduling the next read, verify
that the instance and session are still current. A retired session must not
publish into a replacement session, report a failure for it, or send a stale
command. Retiring one binding must cancel only that binding's timers and
subscriptions; sibling bindings from the same plugin remain active. Unloading
a whole plugin generation retires all of its bindings, while bindings owned by
other plugins remain active.

## Primary and auxiliary scale connections

The connected primary scale remains the singular brewing scale. Additional
connections are generic runtime-only auxiliary devices under the architecture
decision in [#833](https://github.com/decentespresso/decaid/issues/833). A
client may use an auxiliary connection for dosing, grinder comparison, or
diagnostics, but Decaid does not persist `dosingScaleId`, define a dosing role,
or add `/api/v1/scale/dosing/*` routes. The later multi-device work in #859 is
the consumer of the generic auxiliary registry supplied by a separate core/API
change; #843 supplies the bounded host binding capability and #858 supplies
the opaque-ID route boundary.

The #846 single-device Skale stage stays independently reviewable on the
primary brewing path. Guarded machine actions from #845 are primary-only:
auxiliary connections cannot invoke them. In that stage, circle is a tare for
the active primary scale. In the later multi-device stage, circle follows the
active primary or auxiliary binding, while brewing square remains primary-only
and follows the documented machine-state, generation, identity, and GHC checks
at dispatch and immediately before the machine write. There is no sleeping
start path or retry against a replacement session.

The earlier #834 `DosingScaleController` proposal is historical context and is
superseded by [#833](https://github.com/decentespresso/decaid/issues/833). Do
not use it as a current host or plugin contract.

## Required verification matrix

Write behavior tests before implementation and choose the smallest applicable
test tiers. Keep outside-in test-first ordering: start at public plugin/API
behavior, then cover instance integration when concurrent support is
introduced, then unit parsing and command details.

For an initial single-device stage, cover zero and one instance, a second
binding rejected under the existing quota, the physical ID, per-instance
state, disconnect, reconnect, stale callbacks, permission revocation, and
whole-plugin unload isolation. When concurrent same-model support is added,
expand the matrix to one primary plus at least two auxiliary physical IDs,
concurrent primary/auxiliary connections, release of an auxiliary binding back
to primary eligibility after disconnect, and retirement of one binding while its sibling stays
active. Use deterministic fake GATT and
two simulator instances only when the host boundary supports that concurrent
case. Add command, timer, settings, and publication cases when the plugin
declares those contracts, and report real hardware validation separately.

When working on scale buttons, cover primary circle tare, auxiliary circle
binding, primary-only square routing, same-ID reconnect, and queued machine
replacement. Do not add tests for
a persisted dosing role or dosing-specific endpoint. When working on E64
sensors, cover two E64 instances alongside the primary/auxiliary scale
connections and a milk probe.

For per-device plugin settings, draft PR #849 proposes declaring a driver
`settingsEndpoint` that names an `api` HTTP endpoint. Verify the live accepted
branch contract before relying on it. When available, the native Device
Management page routes that action to `/api/v1/plugins/:id/:endpoint` with
`ui=1`, `deviceId`, and `deviceName`; the page uses `url_launcher` with
`LaunchMode.inAppBrowserView`, while the plugin owns validation and persistence.
