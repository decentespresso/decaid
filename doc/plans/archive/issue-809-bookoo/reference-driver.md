# Bookoo Reference Checkpoint

Baseline #822 at f92ed9b6. Port the existing native 20-byte Bookoo Mini packet
contract and six-byte commands into an opt-in example plugin. Keep native code
enabled. Use the shared BLE factory, Scale readiness and timestamp provenance.

Use shared byte fixtures for positive/negative weights, checksum/header/sign/
length rejection, battery retention and exact acknowledged timer/tare commands.
Unknown battery before the first valid percentage is null rather than native's
historical zero. Each connect resets protocol state; callbacks capture that session.

Test advertisement selection, first valid packet readiness, failed handshake,
sleep/disconnect/reconnect, unload/native fallback and deterministic persisted
preference restoration. No protocol reconnect loop; a two-second valid-packet
watchdog reports failure to host recovery. Document this provisional hardware
threshold separately from native operation deadlines.
Arm it after successful notification subscription and reset it on valid decoding,
not successful publication. A valid packet arriving before subscription completion
can start the watchdog; completion must not reset that existing deadline or rearm
a stopped session. Initial silence and malformed-only input must fail on the
protocol deadline, while readiness still requires successful publication.
Native subscription setup retains its own GATT deadline; a 2.3-second setup delay
must not trigger protocol-silence failure.

This checkpoint is a draft stacked on #822 with explicit hardware/full-app acceptance gaps.
No available hardware is assumed, no bundled distribution policy is introduced,
and #809 remains open.
