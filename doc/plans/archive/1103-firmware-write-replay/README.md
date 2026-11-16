# Firmware write timeout replay policy (#1103)

## Problem

Both UnifiedDe1Transport write APIs previously reconnected and recursively
resent the same BLE frame after every timeout, without an attempt budget. A
write timeout does not establish that the receiver did not accept the frame.
Replaying a firmware-map erase request or image chunk is therefore unsafe to
assume, even when reconnect succeeds.

## Decision

Firmware map commands (erase and verification) and image chunks opt out of
transparent timeout recovery at their dispatch sites. They surface the original
failure without reconnecting or replaying. The existing firmware operation owns
failure classification and cleanup.

Both transport write APIs otherwise allow one reconnect-and-retry per call,
then surface failure. The retry budget is local, not shared across operations.
The response-arming callback still runs immediately before each actual dispatch.
Serial framing and dispatch remain unchanged.

Firmware chunks and ordinary settings share writeToMMR. The caller must declare
no-replay intent; excluding the endpoint globally would break settings recovery.
No timeout values or read-recovery policy change.

## Validation and limits

Regression tests record a write before injecting a BLE timeout, reproducing
duplicate firmware frames and a third ordinary dispatch before implementation.
They cover firmware erase/image failures, both write APIs' single retry budget,
explicit opt-out and ordinary settings framing/caller compatibility.

The initial hardware prerequisite was escalated before implementation. The
operator subsequently approved a local candidate and Android BLE testing against
an existing ESP32 emulator only, without reflashing it or using a physical DE1.
The normal emulated upload reached complete byte/CRC verification. Temporary
app-boundary faults after successful real BLE writes demonstrated erase/image
failure without replay and bounded ordinary settings recovery. The faults were
synthetic, not naturally lost ATT acknowledgements, and were removed afterward.
Receiver erase logs corroborated one erase; exact per-address receiver chunk
and settings counters were unavailable. App-side counts are weaker evidence.

This does not establish production bootloader duplicate-erase safety, real
flashing recovery, or the root cause of #1084. Physical DE1 validation remains
separate and operator-gated.
