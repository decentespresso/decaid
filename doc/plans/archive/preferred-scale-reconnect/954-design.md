# #954 preferred primary scale reconnect

Authority: `.lane/spec.md` wins over the issue body's broad early-connect suggestion. No blocking product choices remain.

## Design

Add a default-false `connectPreferredScaleEarly` wire option, independent of `quick` and ignored for discovery-only scans. Select a dedicated explicit connection policy; automatic and legacy explicit policies stay unchanged. Preserve the intent when explicit requests queue/coalesce behind active work or the post-wake lease (opt-in wins among coalesced connect requests).

Only a connected, non-Bengle machine with no pending selection, machine/USB work, primary scale claim, occupied primary slot, auxiliary claim, or sleeping-scale restriction is eligible. Capture eligibility before explicit scan cancels selection; recheck it on sighting and after teardown, along with the original machine identity and scan generation.

ScanOrchestrator latches one matching sighting and requests stop. It does not initiate GATT in the advertisement callback: it awaits the existing scan future, whose BLE service waits for native stop and teardown. DeviceController exposes service failures in ScanResult; for this narrow intent any failure or still-active scanner fails closed without post-scan GATT. On confirmed teardown the existing machine-first/post-scan policy connects the preferred scale, without restarting discovery. If eligibility expires after stopping, do not run the shortcut's post-scan connection policy.

## Validation rationale

Controlled scan completers separate stop request from teardown, making scan/GATT ordering observable without timers or hardware. Policy regression tests cover ineligible, absent, occupied and unresolved ownership cases. Native held-stop tests pin the completion contract that the opt-in relies on. REST/WS tests use real route/socket boundaries, while simulator smoke checks running-app compatibility. The full repository gate protects unchanged automatic and explicit flows.

No BLE transport changes, default changes, automatic startup changes, auxiliary policy additions, or Streamline changes. Real Android/BlueZ beta validation is deferred and explicitly reported.

## Implementation notes

The opt-in wire boolean stops at requestExternalScan; the internal explicit scan queue stores ConnectionAttemptPolicy. The published ConnectionIntent remains explicitDiscovery to preserve API status and selection-session claim semantics. Native in-app scanAndConnect remains parameterless and keeps the legacy policy.

Native regression tests hold system-device lookup and native stop independently. universal_ble serializes these commands, so a suspected lost stop before scan-duration setup was disproven; no BLE service product change was necessary. The existing native stop future propagates failure and releases burst ownership only after teardown. Platform beta validation is still required; simulator smoke proves wire compatibility, not real BLE latency or GATT reliability.

A lead source audit caught ScaleWatch rearm after failed scan teardown: its cached-device shortcut could bypass the new gate. Background-watch-enabled failure tests proved red; an unconfirmed-teardown latch now suppresses scale reacquisition and early automatic scale sightings until a later confirmed scan clears it. This quarantine is entered only by a failed opt-in request; normal automatic/default scan policies remain unchanged. A successful retry regression proves reacquisition recovers.

Panel review found that strict teardown rejection applied too broadly to ineligible or unmatched opt-in scans with unrelated service failures. Shortcut activation now gates rejection and fault-latching; normal full scans retain their existing partial-service-failure post-scan policy, unless a previous shortcut fault is still latched. New unresolved-machine/absent-preferred regressions proved red and now pass.
