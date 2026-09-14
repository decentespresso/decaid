# Skale plugin scale — stage 1 rationale

Stage 1 ships one Skale plugin scale at a time through the host's existing
binding quota. It follows only the currently selected brewing scale. The
plugin retains session-scoped protocol state, per-device settings, metadata,
button handling, and connection-epoch fencing so disconnect and reconnect
cannot let a retired session publish or act.

Dart owns discovery, BLE I/O, permissions, binding lifetime, teardown,
reconnect, and quotas. JavaScript owns Skale protocol parsing, per-instance
timers and callbacks, settings, and button policy. The plugin uses the
brewing entry from `GET /api/v1/scale/connections` when sending a guarded
action, including the session connection and selection tokens.

USB power remains an explicit default-off per-device setting persisted through
the plugin KV authority. The plugin-owned settings endpoint is the authority
for USB and square-action settings. A circle press tares the currently
assigned brewing scale. A brewing square press may request a guarded espresso
or idle transition under the machine-state and GHC rules; unsupported or
uncertain state is ignored.

Multiple same-model scales, dosing-role routing, and any expanded binding
quota are reserved for the follow-up stage. The complete multi-device source
and test inventory is recorded in the stage handoff rather than included in
this stage.
