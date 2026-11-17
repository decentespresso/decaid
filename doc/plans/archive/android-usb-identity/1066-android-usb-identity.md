# Android USB attachment identity (#1066)

## Refinement

The issue and lane brief govern this work. No physical machine will be attached or driven; Android descriptor timing and operator-approved inventory/reconnect verification remain a hardware gap.

Inspection confirms that attach probing, preferred quick-connect and scans independently derive IDs before creating AndroidSerialPort, whose getter derives the ID again from its original descriptor. Logical-ID-only checks do not reconcile descriptor changes. Physical ownership exists but is currently used for detach/orphan cleanup, not admission. Attach detection publishes only after onConnect, leaving a window for scans to start another detection. Preferences are written in ConnectionManager's adopt and normal-connect paths; remembered connections are persisted by RememberedDevicesController. De1Controller uses device ID as a settings fallback when the MMR serial is absent.

## Chosen boundaries

- Retain descriptor-serial USB IDs as canonical. Use an explicitly recognizable, attachment-scoped fallback containing physical identity when no serial is readable. Do not alter desktop identity derivation or BLE IDs.
- Reconcile and serialize machine admission using the Android service's physical ownership, across attach, quick-connect and scan; preserve tap/interface ownership separately.
- Preserve a healthy live object's immutable identity and transport. A later serial is rebound at a safe disconnected/re-detection boundary, not by forcing a reconnect. Retain enough attachment-local descriptor knowledge to avoid downgrading a known canonical ID. Remove attachment knowledge on detach.
- Exclude ephemeral/unverified USB machine IDs from preference/remembered persistence and the device-ID settings fallback; retain valid MMR settings identities and historical canonical IDs.
- Keep API routes/schema unchanged; exercise inventory using existing availability serialization. Document fallback/rebind semantics in both required docs.

No blocking product decision remains: the issue explicitly permits deferring a canonical rebind until safe reconnect. No USB protocol changes, machine-settings migrations unrelated to identity, BLE-ID changes, or forced healthy-session reconnects are planned.

## Implementation and verification

1. Worker adds fake-UsbDevice identity/admission/persistence regressions first and captures red output, then implements only the scoped Android identity and persistence guards.
2. Lead independently inspects changes, runs focused serial/controller tests, `dart format lib test`, `dart format --output=none --set-exit-if-changed lib test`, `flutter analyze`, and full `flutter test` (matching the repository gates confirmed in .github/workflows/pr-checks.yml). Restore unrelated formatter/tool churn.
3. Supply source, diff and exact transcripts to independent read-only review; address blockers and repeat verification.
4. Archive this design, fill the PR template as a lane artifact, commit locally only; orchestrator owns publication. Explicitly report the unrun real-hardware gate.

## Implementation outcome

Two worker passes were independently rejected for incomplete race handling and behavioral evidence; the lead used the protocol's two-failed-passes direct-author exception. Admission is serialized within SerialServiceAndroid across scan, attach probing and preferred quick-connect. This replaces overlapping detection/connection futures rather than adding a global identity registry. Detach invalidates pending admissions immediately; queued cleanup and revision checks prevent late detection or connection completion from republishing detached transports. Physical ownership remains authoritative for live coalescing, while canonical serial knowledge is attachment-local. A healthy session is not relabeled; disconnected redetection applies the best descriptor seen in that attachment. The ConnectionManager phases and serial protocols are unchanged.

The full test gate reports two bundled shot-upload reconciliation failures, reproduced with the entire lane diff stashed at the original HEAD. Focused identity/controller tests and analysis pass. No real Android hardware verification was performed, as the brief forbids it.

Independent panel review found and corrected three additional paths: canonical quick-connect now consults physical ownership even while the live ID is session-only; SettingsController is the common durable preference guard (UI selection is kept local); and an optional CanonicalDeviceIdentity capability carries attachment-proven equivalence from the serial transport through UnifiedDe1 into preferred selection and remembered inventory coalescing. This is per-attachment knowledge, not a global registry or VID/PID alias. The existing REST schemas are unchanged; their descriptions document session preference/inventory semantics. A hardware-free local Shelf HTTP smoke was approved by the supervisor instead of sb-dev because the normal app unconditionally registers the real serial service even in simulation. The smoke logs request/response pairs for devices and settings; Android timing and operator-approved real-machine verification remain unrun.
