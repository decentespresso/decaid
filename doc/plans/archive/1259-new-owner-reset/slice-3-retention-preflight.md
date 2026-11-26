# Slice 3: read-only new-owner retention preflight

Approved bounded scope for [#1259](https://github.com/decentespresso/decaid/issues/1259), following merged #1265 at base `5b8907c02e743548186fb9044ae529a030b3387f`. Destructive reset remains disabled; the umbrella issue stays open.

## Goal and exclusions

Read existing owners to determine whether preferred machine, PRIMARY scale and actual selected managed skin can be retained. Immutable typed accepted/rejected output contains only selected necessary reconnect metadata and a managed runnable package reference. No credentials, accounts, registry snapshots, personal skin/browser state or package contents. No settings writes, migration writes, journal arming/consumption, package copying, cleanup, reset UI/API, startup/recovery integration, device operations, cloud actions or native/build changes.

## Current-source findings

- `settings/settings_service.dart:246-298`: preferred IDs are direct reads; `defaultSkinId()` defaults absence to `streamline.js` and WRITES a `streamline_project-main` migration. A separate narrow read-only query must perform that same normalization without mutation and preserve read failures.
- `controllers/remembered_devices_controller.dart:38-100`: initialization migrates/persists records and subscribes to live streams. Do not initialize it for preflight. `models/device/remembered_device.dart` supplies immutable metadata, but its permissive decoder loses malformed-record information; strict validation must not mistake errors for absence.
- `controllers/connection/policy_resolver.dart`: null preferences mean automatic selection, not a concrete currently connected device. `models/device/scale_preference.dart` owns the PRIMARY scale selector. Reuse its role-appropriate semantics rather than inventing sentinel values.
- `webui_support/webui_storage.dart:211-243`: initialization creates/copies/downloads. `defaultSkin` at 259-287 falls back silently. Neither path is suitable. Add an owner-local read-only query for the exact normalized selected ID, with managed-root/package validation.
- `webui_support/webui_service.dart:14-24,206` owns runtime registry/path/id overrides. Preflight receives an explicit runtime selection snapshot, never constructs a serving service or listener. Existing persisted selection keys must be reconciled, not silently repaired.

## Supervisor-approved policy refinement

Absent persisted skin selection and the documented legacy alias normalize purely to `streamline.js`; require precisely that installed managed package. Missing alias target rejects. Failed reads reject rather than default. No fallback skin is permitted.

Runtime selection must be explicitly known. Non-registry selection is accepted only when existing-owner canonical identity/provenance establishes the same managed selected package AND serving root; basename/ID equality alone is insufficient. Reject external/unmanaged/escaped/missing/conflicting roots without traversing arbitrary user folders or contacting URLs. Reject symlink escape.

Preserve null device IDs as auto-selection, without materializing a device. Preserve supported role-appropriate selectors such as PRIMARY scale `usb-hds:any` without a fabricated remembered row. Concrete identities require exact selected ID/role and consistent necessary reconnect metadata. Do not impose a row requirement on documented manual transport forms legitimately resolved without one; unresolved source-backed cases require a batched recommendation before coding. Never scan, pair, connect or create device controllers.

Result is valid only at observation; it is not atomic reset eligibility or durable package escrow. A future guarded operation must revalidate. Static package validation does not prove serving, personal-state cleanup, copying or recovery durability.

## Acceptance criteria

1. Preferred device selections and required reconnect metadata follow existing semantics without scan, pair, connect or controller creation side effects.
2. A selected managed skin is resolved and validated through its owner; ambiguous or unsupported selections reject without fallback or mutation.
3. Accepted output contains only the explicit retention allowlist. Rejected/read-failure output cannot be mistaken for successful reset eligibility.
4. Actual production read paths have regression and negative-path coverage; all seeded state remains unchanged.
5. Normal startup/replay/CLI, primary-versus-auxiliary scale ownership and existing recovery journal behavior remain unchanged.
6. Destructive reset remains disabled. Lost-marker/directory/power-loss durability, native queued-state purge, storage cleanup/readback, guarded customer handoff and physical end-to-end acceptance remain separate prerequisites.

## Current read-only ownership boundary

`NewOwnerRetentionPreflight` reads preferred IDs and the raw persisted skin ID from the injected settings owner; the raw skin query does not execute the legacy migration. It reads remembered records only for concrete selections. Role/transport/implementation validation admits only supported reconnect combinations. A selected manual WiFi scale with no remembered row resolves through the injected `WifiManualEndpointLookup`, implemented by the existing `SharedPrefsWifiManualEndpointStore`. That legacy owner loads its preference cache, but consumes only `wifi_scale_manual_hosts`; the returned allowlist contains the selected ID and transport/implementation, not the list. Corrupt registry or conflicting metadata rejects rather than falling back to a manual endpoint.

The managed skin query stays inside `WebUIStorage`, separate from its ordinary scan. It resolves manifest IDs and canonical-directory precedence, returns the selected managed-relative directory and ID, and never populates the runtime registry. The preflight-only access seam records real read/metadata operations for tests. Non-following enumeration, bounded manifest reads, readable regular entrypoint probes and component-by-component link checks reject external targets and cycles before canonical follow. A 32-iteration link resolution bound fails closed. Root read failure is unreadable, not absence. Ordinary `_scanInstalledSkins` remains byte-identical to the pinned base, including its existing permissive scan semantics; this slice does not harden runtime scan behavior.

The managed directory reference is an observation, not a persisted package identity, provenance guarantee or escrow handle. Read/metadata spies are application-level evidence, not syscall tracing. State snapshots and write spies separately cover async/legacy preferences, packages, unrelated state and journal/database canaries. Mutable filesystem or preference races cannot be made atomic by this observer; future guarded reset must revalidate. No production caller, startup/reset integration or reset authority is added.

Read-only skin lookup uses only the owner's explicit root override or its successfully initialized cached root. An uninitialized owner without an override rejects unreadable before any platform path lookup. The pinned Foundation2.6.0 support-path provider creates the support directory while resolving it, so calling `AppDirectories.webUi` is not read-only. Tests model that exact provider boundary using an owned temporary support directory, not native app storage, and require zero calls/no directory creation. Known-root control succeeds without provider access. Ordinary alias positives isolate alias enumeration over a real owned target so rejecting every alias cannot pass via direct-target discovery.

The reserved `.webui-install-staging` directory is not an installed managed package. A normal package alias whose canonical target is that direct-root staging directory rejects before manifest or entrypoint content reads. Normal owned aliases still resolve the actual canonical installed directory and selected manifest ID.

Strict inspection cannot silently substitute a lower-precedence package. Failure to inspect the canonical directory named by the selected ID rejects before considering legacy candidates. Without a validated selected canonical directory, any skipped package leaves a possible competing manifest identity, so legacy selection rejects uncertainty. This conservative observer-only limitation avoids unsafe or unbounded identity reads; a validated canonical selection remains authoritative despite unrelated broken legacy packages. Tests force both enumeration orders and assert the exact retained directory.

Matching remembered-record malformation or wrong role is distinct from absence and cannot trigger manual WiFi fallback. Every registry list element must be an object; unrelated legacy map contents are not migrated. Owner-built Bengle virtual primary-scale records retain their exact IDs and inherited serial/BLE metadata, while sensor-role/unknown transport records do not become primary scales.

A separate two-line test-fixture lifetime correction registers the local serial test controller's disposal before its machine is disposed (LIFO teardown); a one-second post-disposal observation catches the previously unowned timer. The tracked original callsite failed with stream-add-after-close before cleanup and passed afterwards with identical assertions. ROOT also reproduced this mechanism on source-identical main. No production controller/transport code or exception masking was changed. Old full-run failures remain recorded, not retroactively relabelled as passing.

Device names and account mappings are not returned. Preferred IDs themselves retain existing semantics; the primary WiFi ID carries its selected host. OS permissions, hardware and all other persistence owners remain untouched. No API, plugin event, profile or device-flow contract changes are made. Destructive erasure, secret cleanup, durable package retention, recovery and physical end-to-end acceptance remain future work under #1259.
