# E64 WebSocket sensor

This opt-in example exposes one read-only sensor registration per configured
Mahlkoenig E64 grinder. It uses the existing host WebSocket transport and
publishes the complete driver state as the `state` object channel.

Use an ordinary setting for the instance list and the secure setting for the
tokens. Set `InstancesJson` to this JSON:

```json
[{"id":"e64-one","name":"Kitchen E64","scheme":"ws","host":"127.0.0.1","port":9997,"pollMs":1000}]
```

Set `TokensJson` to this JSON:

```json
{"e64-one":"replace-with-the-secure-session-token"}
```

Each instance needs a unique safe id, a non-empty name, `ws` or `wss`, a
hostname or bracketed valid IPv6 address, a port from 1 through 65535, and a
token. DNS labels cannot be empty or start/end with a hyphen. Malformed IPv6
literals such as `[.]`, `::::`, and `[12345::1]` are rejected.
At most eight instances are accepted. `pollMs` is optional: `0` disables
polling, otherwise it must be between 100 and 3,600,000 milliseconds. The
whole configuration is checked before any sensor registration or socket open;
an unknown token id or any invalid entry rejects the complete load.

The four exposed reads send only `RequestDriverState`, `RequestDriverConfig`,
`RequestNachineInfo`, and `RequestLogMessages`. The plugin has no motor,
configuration, calibration, or GBS write path. A device disconnect affects its
own instance. A settings reload is a whole-plugin operation and may reconnect
all configured instances; it is the supported way to change the list.

The corresponding result types are `RequestDriverStateResult`,
`RequestDriverConfigResult`, `RequestNachineInfoResult`, and
`RequestLogMessagesResult`. Results must carry the matching `refId`; the
documented JSON `pong` heartbeat is ignored and never published.

`ws` is suitable for a trusted network or a loopback fixture. `wss` uses the
platform's trusted TLS certificates and does not bypass certificate checks.
This example has been validated with the loopback simulator; it does not claim
hardware validation.
