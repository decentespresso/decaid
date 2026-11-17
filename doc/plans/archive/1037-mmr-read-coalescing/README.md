# DE1 settings MMR read coalescing (#1037)

## Decision and hardware boundary

Batch live settings reads at the device layer, preserving JSON keys, numeric
scaling, signed values, booleans and error propagation. The original target was
9 → 4 normal-settings requests and 4 → 2 advanced-settings requests. Hardware
validation changed the normal route to **9 → 5**, approved by the maintainer:
the proposed steam-purge/USB pair is unsupported as a multi-word read. Keep those
two single-word getters; do not replace failed or missing data with defaults.

Validation used a DE1Pro, firmware v1358, serial 9486, GHC, 220 V, over BLE from
an Android tablet. The firmware observations, including the unsupported pair's
single-word versus multi-word USB result and observed response-header bytes,
are recorded in [`doc/device-notes/de1.md`](../../../device-notes/de1.md#multi-word-mmr-reads).
That is also the provenance of hardware-shaped frame bytes retained in the BLE
fake and serial fixtures; those bytes are fixture data, not a response-length
matching rule. A working group does not validate any neighbouring group.

| Route | Start address | Request `length` | Fields | Validation |
|---|---|---:|---|---|
| Normal | `0x00803808` | 1 | fan threshold, tank temperature | Verified |
| Normal | `0x00803828` | 0 | steam flow | Single-word |
| Normal | `0x00803840` | 3 | flush flow, temperature, timeout, hot-water flow | Verified |
| Normal | `0x00803850` | 0 | steam purge mode | Single-word; proposed pair unsupported |
| Normal | `0x00803854` | 0 | USB charging | Single-word; proposed pair unsupported |
| Advanced | `0x00803810` | 2 | heater phase 1/2 flow, idle temperature | Verified |
| Advanced | `0x00803838` | 0 | heater phase 2 timeout | Single-word |

Thus normal settings use two multi-word plus three single-word reads; advanced
settings use one multi-word plus one single-word read. Each request's `length`
is the number of additional words after the first, not a payload byte count.

## Compatibility and ownership

Typed snapshots keep MMR addresses and wire decoding out of HTTP handlers.
`De1SettingsSnapshots` retains sequential getter composition for simulated,
replay and test devices. The handlers explicitly select the coalesced methods
because Dart extensions dispatch statically. Bengle inherits `UnifiedDe1` but
is excluded through `BengleInterface` until its register groups are validated
on hardware. Serial DE1 uses the shared coalesced path; no serial-specific
behaviour change was needed. Advanced heater voltage and refill-kit setting
remain local-state reads. Individual getters and writes remain available.

MMR reads and writes share one exclusive FIFO permit at the existing
`_firmwareMmrGate`, held through response handling, retries and settling. Address
correlation alone allowed overlapping single-word and multi-word reads at the
same address to consume the same response, silently decoding a padded second
word as zero. Serialisation was chosen over per-address locking: one owner at
the existing boundary also orders writes and firmware work without introducing
a second lock scheme. Response-length matching was rejected because fixed-size
frames and the observed header byte cannot reliably distinguish word counts.
The only permit acquisitions are raw reads and writes; permitted bodies do not
nest MMR operations.

Firmware remains exclusive and has priority over queued MMR work after the
active operation completes. Firmware release, including failure, resumes queued
MMR operations one at a time in FIFO order after any waiting firmware owners.
Timeouts, retries and retry-settle delay are unchanged. There is no settings
cache, new REST contract, write coalescing or transport abstraction.

## Measurements

Existing PR #1057 hardware evidence compares builds back-to-back on the same
machine; these ranges are observations, not performance guarantees.

| Endpoint | Before | After | MMR requests |
|---|---|---|---|
| `/machine/settings` | 1.37–1.60 s | 0.83–0.87 s | 9 → 5 |
| `/machine/settings/advanced` | 0.62–0.81 s | 0.35–0.49 s | 4 → 2 |

Transport logs confirmed the request groups above. Returned values matched the
single-word build, including distinct non-zero fan, tank, flush temperature,
timeout, flow and hot-water values. The unsupported-pair probe held machine
state unchanged between framings; its exception is preserved in the device
notes rather than treated as a performance trade-off.

## Verification and limits

- Snapshot tests cover distinct non-zero words, negative signed values,
  endianness, offsets, per-field scaling, boolean conversion, all four payload
  words, exact addresses/lengths/counts, malformed/truncated frames, trailing
  bytes, missing responses and single-word compatibility.
- Handler tests assert unchanged normal/advanced JSON and fallback selection,
  including actual Bengle and simulated-device coverage.
- Overlap regressions check a single-word and two-word read at one address and
  two coalesced snapshots. Before serialisation the observed failures were
  `Expected: <-7> Actual: <0>` and `Expected: <-6> Actual: <-7>` respectively.
- Firmware coordination tests check exclusivity, firmware priority over already
  queued MMR work, and one-at-a-time FIFO resumption after firmware failure.
  Calibration cache-race tests retain stale-read checks using read/write barriers
  compatible with serialised I/O.
- Positive serial transport injection checks complete request framing and
  decoded settings, including a four-word response. A first-word-only decoder
  mutation failed with `Expected: <-7> Actual: <42>`, demonstrating non-vacuity.
  Missing-response tests use SDK streams with fake time; replaying rxdart
  subjects did not deliver under `fakeAsync` in that fixture.
- Format, analysis, focused suites, full Flutter tests and the 20-second
  suite-active-time guard passed in review round 2. Round 3 is documentation and
  comment cleanup only; it does not claim fresh hardware measurements.

Serial hardware: the sequential (non-coalesced) settings path was exercised on
Bengle over USB serial from an Android tablet, and both endpoints returned
correct values, so single-word MMR framing decodes correctly on that transport.
Coalesced multi-word reads over serial are still unvalidated, because Bengle is
excluded from coalescing and no DE1 was available over serial.

Bengle coalescing remains unvalidated. LED hydration, cup-warmer preheat and
on-connect identity reads are follow-up candidates only;
see the device notes for their unverified ranges. This work does not validate
those groups or other firmware versions. Enduring ownership and decoding rules
live in [`doc/AI_BLE_NOTES.md`](../../../AI_BLE_NOTES.md#mmr-read-architecture).
