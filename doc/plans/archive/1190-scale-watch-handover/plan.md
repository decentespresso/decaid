# Preferred plugin-scale watch handover

Design for [#1190](https://github.com/decentespresso/decaid/issues/1190), following the accepted 2026-11-26 contract.

## Failure and authority boundary

Stopping the background BLE watch retires its scan generation and advertisement evidence. A plugin scale sighted by that watch then fails PluginBleBinding admission with `stale_session: BLE ownership changed`. Native-driver candidates do not use that admission closure. Keeping ordinary evidence alive globally would weaken the #809 ownership boundary.

The implemented scanner capability captures one bounded handover for the selected candidate before stopping the watch. DeviceController forwards claims to their originating discovery service. Discovery preserves only that claim across watch teardown while retiring ordinary scan evidence. Admission consumes it once and rechecks physical identity, plugin driver identity, registry revision, runtime availability, adapter generation, scan generation, ownership and a five-second expiry. Cancellation removes the claim; competing scan ownership, registry changes, adapter shutdown and disposal invalidate it. PluginBleBinding retains its existing registry reservation and runtime checks.

ScaleWatch owns cancellation and retry timing, not BLE authority. Failed watch-driven attempts delay scan restart by 1, 2, 5 and then capped 15 seconds. Repeated sightings coalesce. Disarming and successful recovery clear retry work. The existing shouldWatch callback remains the authoritative success signal: a void connect callback can return after a swallowed failure and is not evidence of connection success.

## Compatibility and evidence limits

Preferred-scale policy, auxiliary reservations and native-driver connection admission are unchanged. Deterministic tests exercise the real Felicita reference JavaScript driver through discovery, DeviceController, ScaleWatch and PluginBleBinding with a fake transport. Negative paths cover cancellation, physical binding, single-use consumption, expiry, foreground supersession, registry/plugin replacement, runtime shutdown and adapter shutdown. Virtual-time controller tests cover backoff boundaries, cap and cancellation; the ConnectionManager integration test checks immediate non-rearm and eventual retry.

This is L3 BLE lifecycle and ownership work. Automated tests do not establish Android radio timing or physical scale firmware behavior. Bookoo-specific physical verification is unavailable because no Bookoo scale is available. The existing opt-in Felicita Arc reference plugin can exercise the same admission route if the operator confirms a compatible model and authorizes a future connection. It has not been physically verified here; its provisional two-second packet-silence watchdog also needs hardware validation. Native Felicita or Decent scales provide comparison evidence, not proof of plugin handover. No physical-device operation is authorized by this design.
