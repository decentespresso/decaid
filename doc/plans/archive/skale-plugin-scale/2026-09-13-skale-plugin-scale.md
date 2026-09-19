# Skale plugin scale runtime consumer

The reference driver validates host-owned BLE bindings, Skale weight parsing,
readiness, reconnect fencing, display/timer/tare commands and session-scoped
firmware/battery metadata. USB power remains an explicit per-device setting
persisted through the plugin endpoint and existing KV store.

Physical button behavior is staged separately from this runtime consumer.
Guarded machine actions remain held for human review in #845/#853 and are not
an implementation or merge prerequisite for this driver. This branch does not
change the machine-control API or issue machine-control requests.

The host owns connection selection, lifecycle and resource limits. Concurrent
Skale sessions are validated by the separate multi-binding consumer in #859.
