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
understand it and grant SoftSleep the scale does not have.

SoftSleep is therefore gated on a second, independent signal: HDS identity
**and** a decoded firmware version with major `>= 3`. HDS firmware before 3.0.1
does not report a version at all, so 2.6.3-3.0.0 HDS has no decoded version and
uses the shared display-off command instead. That is the conservative failure
mode: an unsupported `0A 04` is a protocol error on a scale whose real
capabilities we cannot prove, while display-off is safe on every family.

The capability set is split accordingly: `hdsExtended` (extended commands,
power off) for HDS without proven firmware, `halfDecent` (adds SoftSleep) for
HDS with firmware major `>= 3`.

## Superseded: a failed SoftSleep write disconnects

`_sendOledOff()` used to discard both write results, and `sleepDisplay()` only
fell back to disconnect when the *native* connection state had changed. A GATT
write that times out while Android still reports `connected` left Decaid with
`_isSleeping = true`, the notification watchdog cancelled, and the scale wide
awake - a logical/asleep divergence that only a manual reconnect clears.

This revision made `_sendOledOff()` report success and `sleepDisplay()`
disconnect on failure. **That policy is superseded by #874 below.** Disconnect
was only ever the fallback because it was the sole protocol-safe alternative;
the shared `0A 00` display-off command is a better one. A failed SoftSleep now
falls back to display-off and keeps the connection.

## Field evidence (#874): detection was right, the sleep policy was wrong

A field run identified a real original full-height Decent Scale exactly as
expected:

```
status response: original-fw=0x02 fw=1.1
HDS voltage probe: no response
profile=originalDecentScale
SoftSleep withheld
```

One healthy connection streamed for roughly 30 minutes
(`notifications=17136, uptime=1792s`), then, the moment the DE1 entered sleep,
Decaid logged `Decent scale: disconnecting for sleep (SoftSleep unavailable)`
and dropped the scale. The reconnect churn that followed is the Android GATT
133 pressure this work set out to reduce. Profile detection was correct; the
sleep-policy decision was not.

## Decision (supersedes failed-SoftSleep-disconnect): display off, SoftSleep, power off and disconnect are separate

Lack of HDS SoftSleep does not mean a Decent Scale must disconnect when
`ScalePowerMode.displayOff` is requested. The original Decent Scale protocol has
a normal LED/display-off command and keeps weighing while the display is dark.

| Concept | Command | Scope |
| --- | --- | --- |
| Display off | `0A 00 00 00 00` | shared Decent protocol, every family |
| SoftSleep | `0A 04 01` / `0A 04 00` | HDS extension, capability-gated |
| Power off | `0A 02` | separately capability-gated |
| BLE disconnect | - | transport/lifecycle recovery only |

Behaviour matrix:

```
                       displayOff           HDS SoftSleep       disconnect
unknown/base           yes                  no                  only on real link loss
original DS            yes                  no                  only on real link loss
HDS, SoftSleep unknown yes                  no                  only on real link loss
HDS, SoftSleep proven  yes/fallback         yes                 only on real link loss
```

`sleepDisplay()` now:

- sends the shared `0A 00` display-off and keeps the connection for every
  profile without proven SoftSleep (unknown, original, pre-modern HDS);
- enters HDS SoftSleep when it is proven, and on a failed SoftSleep write falls
  back to `0A 00` rather than disconnecting;
- never intentionally disconnects on the successful display-off path.

A failed display-off write is logged and the healthy connection is retained;
the transport watchdog is the only thing allowed to tear down an actually dead
link. The old "failed SoftSleep => disconnect even if the native link is
connected" policy is retracted: it existed only because disconnect was the sole
safe fallback.

Wake restores the same physical connection: `0A 01` LED-on for a display-off
sleep, `0A 04 00` plus `0A 01` for a SoftSleep sleep. There is no renegotiation
or re-probe merely because the display was toggled; capabilities are
re-established only on a genuinely new physical connection.

`DecentScale` no longer implements `DisconnectToSleepScale`, so `De1StateManager`
never calls `markScaleSleeping` for a Decent Scale in `displayOff` mode.
`disconnectsToSleep` was semantically wrong: a missing SoftSleep capability no
longer predicts an intentional transport disconnect.

## Firmware byte decode notes

For modern HDS, status bytes 5-6 are a version: byte 5 is BCD
(`majorTens << 4 | majorUnits`), byte 6 packs `minor << 4 | patch`. The low
nibbles are raw 0-15, not decimal BCD digit pairs, so current OpenScale 3.1.14
legitimately arrives as `0x03 0x1E`. Rejecting nibbles above 9 discarded a real
firmware version and, with SoftSleep gated on it, would have withheld SoftSleep
from the current stable release.

The decoded major is capped at 30. HDS majors are single digits, so the cap is a
sanity guard: a status byte corrupted into an implausible version is treated as
no version, which keeps the conservative display-off fallback.

The original-scale firmware marker table (`{0xFE: 1.0, 0x02: 1.1, 0x03: 1.2}`)
comes from the public `pydecentscale` client, not Decent firmware source, and is
kept as a known gap: the timestamped 10-byte weight frame independently proves
v1.2+, so only the duplicate-write and power-off gates depend on the table.

## Command reliability and evidence integrity

- The tare sequence byte advances once per logical tare. On profiles that need
  the v1.0 dropped-command workaround, the retry reuses the exact same frame and
  therefore the same sequence byte.
- There is no global XOR enforcement on ordinary 7-byte weight/status traffic;
  existing BLE compatibility remains tolerant. Frames that widen capabilities
  are stricter: HDS `0x22` responses and 10-byte timestamped-weight evidence
  must have a valid XOR checksum before they can promote the profile.

## Deferred

- HDS 2.6.3-3.0.0 uses shared display-off until a reliable capability probe for
  SoftSleep exists (they report no version, so the `>= 3` gate is never
  satisfied).
