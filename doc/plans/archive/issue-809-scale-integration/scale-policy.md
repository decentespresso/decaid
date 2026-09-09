# Scale Integration Checkpoint

Builds on merged #820 at c957e2b1. The existing adapter and public registration
remain transport-independent. A real QuickJS in-memory protocol exercises inventory,
connection selection/preference, first-sample handoff, Scale REST commands,
WebSocket weights, unknown battery, unsupported timer errors, and unload/reload
without BLE permission.

Automatic timer calls follow the existing automatic tare error-handling pattern:
observe the future and log failure without aborting shot sequencing. Explicit
REST commands still fail, and plugin errors expose their stable code alongside
the existing message through a Scale-domain operation error. Native no-op timer
behavior is unchanged.

Disconnect-to-sleep is a domain capability, not a dependency from host controllers
onto the plugin implementation. Before display sleep disconnects the Scale, the
host marks deliberate sleep and pauses normal Scale reacquisition. An observed
awake machine state releases this pause. Display-control devices retain their
existing independent sleep/wake commands.

Disconnect classification retains connection history across `disconnecting`,
so protocol cleanup cannot suppress unexpected-failure recovery. Terminal sleep
disconnects consume the existing expectation instead. Tare and timer failures
share an OpenAPI error schema, including the optional operation error code.

Measurement timing and the Bookoo protocol remain separate checkpoints.
HTTP/WebSocket and controller tests use test-owned servers and fake devices;
they do not claim full application UI or hardware acceptance.
