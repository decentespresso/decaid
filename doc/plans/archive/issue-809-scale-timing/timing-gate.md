# Scale Timing Gate

Keep the existing ScaleController estimators and tuning unchanged. Use 100 ms
cadence, as in the native estimator fixtures, with identical 0.1 g increments.
Require exact sample order and timestamps, and display/control flow equality
within 1e-9 (identical inputs into the same deterministic estimators).

Exercise immediate delivery, dispatch held for a four-notification burst, and
publication delayed asynchronously after callback dispatch. Compare every accepted
sample, not just final flow. Record delivery age separately from sample time;
correct timestamps do not recover real-time decisions missed during a stall.

The shot sequencer's existing freshness window is two seconds. Provenance must
expire at that boundary, reject clock rollback/future timestamps, be single-use,
and reject foreign/session/out-of-order tokens. Bound retained tokens to 256 per
session. Retirement clears them. Non-BLE/synthetic publications retain host
publication-ingress time. JS must never supply authoritative timestamps.

Ingress timestamps failed: the first 100 ms sample in a four-event batch was
published at 400 ms. Added only an optional opaque notification token as
the second callback argument and second publish argument. Validate it host-side
before forwarding to the shared Scale adapter. Keep protocol decoding in JS.

The regression now compares the full JS path with native ScaleController output
for batches of one/four and asynchronous delays of zero/150 ms over four recovery
cycles. Recorded accepted samples drive the existing ShotSequencer: the stop
sample agrees, while samples delivered three seconds late cannot trigger SAW.
This replay proves timestamp/control-input equivalence, not that stalled delivery
can stop hardware on time. Live device latency remains a hardware gate.

Live QuickJS callbacks also remain suspended while the injected host clock advances
three seconds. Expired publication rejects with `stale_sample` without retiring
the subscription; a fresh notification still publishes. Unrelated callback
failures remain fatal. Clock rollback at either capture or publication retires
the BLE session, and reconnect accepts the earlier timestamp in a new connection.
Capture happens before notification encoding.
