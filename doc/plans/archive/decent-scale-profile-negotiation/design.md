# Decent Scale / HDS profile negotiation (#839)

Issue: decentespresso/decaid#839 · PR: #867 · 2026-09-10

## Problem

`DecentScale` mixed the shared Decent Scale protocol with HDS-only behaviour:
unconditional HDS SoftSleep (`0A 04`), a LED/status write on every other 4s
maintenance tick, and a trailing heartbeat byte of `01` on tare while heartbeat
support is disabled. An original full-height Decent Scale connects, streams
weight, then drops with Android GATT 133 during one of those periodic writes and
repeatedly disconnects after the DE1 sleeps.

## Decision: identity is evidence, capabilities control behaviour

`profile.dart` holds pure frame parsers plus `DecentScaleIdentity` and
`DecentScaleCapabilities`. A connection starts conservative and only widens on
positive protocol evidence. Unidentified scales get shared weighing/tare/timer
only: never `0A 04`, never power off, never an extra periodic write.

- A `0x0A` status response or a 10-byte timestamped weight frame identifies an
  original Decent Scale; the timestamped variant adds power off and drops the
  unreliable command buffer.
- A valid `0x22` voltage response identifies HDS and enables extended commands
  and power off.

## Decision: `0x22` is not SoftSleep evidence

An early revision promoted any `0x22` response straight to full HDS
capabilities including SoftSleep. That proves too much. HDS firmware history is
explicit: **v2.5.8 introduced `0x22`, SoftSleep only arrived in v2.6.3.**
Negotiation would then send `0A 04` to a 2.5.8-2.6 scale that does not
understand it and mark the link as not-disconnect-on-sleep.

SoftSleep is therefore gated on a second, independent signal: HDS identity
**and** a decoded firmware version with major `>= 3`. HDS firmware before 3.0.1
does not report a version at all, so 2.6.3-3.0.0 HDS has no decoded version and
temporarily falls back to disconnect-on-sleep. That is the conservative failure
mode: a disconnect is recoverable, an unsupported `0A 04` is a protocol error on
a scale whose real capabilities we cannot prove.

The capability set is split accordingly: `hdsExtended` (extended commands,
power off) for HDS without proven firmware, `halfDecent` (adds SoftSleep) for
HDS with firmware major `>= 3`.

## Decision: a failed SoftSleep write disconnects

`_sendOledOff()` used to discard both write results, and `sleepDisplay()` only
fell back to disconnect when the *native* connection state had changed. A GATT
write that times out while Android still reports `connected` left Decaid with
`_isSleeping = true`, the notification watchdog cancelled, and the scale wide
awake - a logical/asleep divergence that only a manual reconnect clears.

`_sendOledOff()` now reports whether the sequence succeeded, and
`sleepDisplay()` disconnects whenever it did not, regardless of the native GATT
state. The regression test covers the hard case where the write fails while the
native state stays `connected`, not just the easy case where the fake flips to
disconnected before throwing.

## Firmware byte decode notes

For modern HDS, status bytes 5-6 are a version: byte 5 is BCD
(`majorTens << 4 | majorUnits`), byte 6 packs `minor << 4 | patch`. The low
nibbles are raw 0-15, not decimal BCD digit pairs, so current OpenScale 3.1.14
legitimately arrives as `0x03 0x1E`. Rejecting nibbles above 9 discarded a real
firmware version and, with SoftSleep gated on it, would have withheld SoftSleep
from the current stable release.

The decoded major is capped at 30. HDS majors are single digits, so the cap is a
sanity guard: a status byte corrupted into an implausible version is treated as
no version, which keeps the conservative disconnect-on-sleep fallback.

The original-scale firmware marker table (`{0xFE: 1.0, 0x02: 1.1, 0x03: 1.2}`)
comes from the public `pydecentscale` client, not Decent firmware source, and is
kept as a known gap: the timestamped 10-byte weight frame independently proves
v1.2+, so only the duplicate-write and power-off gates depend on the table.

## Deferred

- No tare-counter increment: the official protocol marks the incremented integer
  optional and always-zero is valid.
- No global XOR checksum enforcement on HDS weight frames: official DS
  documentation marks XOR validation over BLE deprecated. Integrity checking is
  confined to using a frame as capability evidence.
- HDS 2.6.3-3.0.0 stays on disconnect-on-sleep until a reliable capability
  probe for SoftSleep exists (they report no version, so the `>= 3` gate is
  never satisfied).
