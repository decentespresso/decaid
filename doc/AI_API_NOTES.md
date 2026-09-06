# AI API Notes

Read this when changing REST endpoints, WebSocket topics, API specs, auth proxy, or Decent binary protocol handling. Skip it for pure UI, BLE transport, or plugin changes.

## Source Of Truth

- REST spec: `assets/api/rest_v1.yml` (OpenAPI 3.0). Always read before making calls.
- WebSocket spec: `assets/api/websocket_v1.yml` (AsyncAPI 3.0).
- Full endpoint reference: `doc/Api.md`.
- Handler implementations: `lib/src/services/webserver/`.
- Router registration: `lib/src/services/webserver/webserver_service.dart` `_init()`.

## Hard Rules

- Update the spec file in the same commit as endpoint changes. The spec is authoritative — stale spec = stale agent knowledge.
- Every handler has `addRoutes()`, registered in `webserver_service.dart` `_init()`.
- Most handlers use `part of webserver_service.dart`. Standalone imports: `shots_handler`, `beans_handler`, `grinders_handler`, `workflow_handler`, `data_export_handler`, `data_sync_handler`, `info_handler`.
- API docs served on port 4001. REST on port 8080.

## REST API Conventions

- Standard response envelope: `{ data, error, status }`.
- Error responses use `jsonBadRequest()` / `jsonError()` / `jsonNotFound()` helpers.
- Content-based hash IDs for profile deduplication (`ProfileController`).
- ETag / `If-None-Match` support on cacheable resources (#203).

### Admission Control

`/api/` requests pass through a process-local gate after authentication and inside
the existing logging/CORS middleware. Defaults are 128 concurrent and 1024 accepted
per second globally, 32 concurrent and 256 accepted per second per client, and 256
tracked clients. Per-client rejection returns `429`; global rejection returns `503`.
Both include `Retry-After: 1`. `OPTIONS`, static/WebUI, and `/ws/` requests bypass
this gate.

WebSocket upgrades use an independent gate: 128 open and 128 upgrades per second
globally, 32 open and 32 upgrades per second per client, and 256 tracked clients.
Every registered WebSocket uses it. A socket holds its slot until the channel sink
finishes; rejected upgrades use the same `429`/`503` and `Retry-After: 1` contract.

The raw firmware upload buffers at most 16 MiB and cancels body reading after 60
seconds. It returns `413` for either a declared or streamed overrun and `408` for a
stalled body. Workflow PUT retains its smaller semantic bounds.

### Backup Import and Sync Invariants

- A successful backup import requires at least one recognized selected payload; metadata alone is not payload.
- `200` means all processed import sections completed without errors. Any section error, including a returned `SectionImportResult.errors` list, means `207`.
- ZIP integrity and structural JSON for every selected section are validated before any section mutates storage. Any failure in that phase returns `400` and imports nothing.
- Semantic record and section errors remain isolated after validation, so other recognized sections may import. Those imports are not transactional and successful sections are not rolled back.
- `DataImportOutcome` (or its equivalent) is the source of import completeness classification; clients must not infer it by reparsing the section response map.
- Data sync preserves complete, partial, and fatal phase states. A remote import `207` is a partial push, not a target failure.
- UI clients must not collapse `207` into complete success.
- Backup export is atomic: a requested section export failure returns an error and never a partial ZIP. Native callers validate HTTP `200` and `application/zip` before opening a save picker.
- Remote sync clients accept legacy flat section maps and structured `sections` responses, but fail closed for missing sections, malformed semantic fields, contradictory declarations, or a hybrid representation.
- In every sync mode, omitted sections mean all locally registered sections; explicit empty, unknown, or malformed section lists are rejected before network activity.

## WebSocket Conventions

- WebSocket topics are path-based: `/ws/v1/machine/state`, `/ws/v1/machine/shotState`, `/ws/v1/scale/snapshot`, etc.
- `ShotSequencer` emits structured `ShotDecision`s (why a step advanced, why the shot stopped).
- `SteamSequencer` manages steam session lifecycle (start on entry, finalize on exit).
- Presence tracking via `PresenceController` — client keep-alive.

## Auth Proxy

**Design (PR #296):** Rea acts as an auth-enriching reverse proxy. Clients call Rea endpoints (e.g., `GET /api/v1/account/proxy/support/api/...`), Rea attaches Basic Auth from the secure store, forwards to `decentespresso.com`, returns response body + status as-is.

**Who is calling:** Every proxied request carries client identity (skin id, plugin id, API client token). Rea logs per-request for auditability.

**Scope:**
- Phase 1 (shipped): Read-only proxy (`GET` only).
- Phase 2 (shipped PR #366): Write proxy (`POST`/`PUT`) for shot upload, profile push.

**Permissions:**
- Skins (same-origin webview): implicit access.
- Cross-origin API clients: bearer token scoped to `account:proxy`.
- Plugins: must declare `proxy.decent_api` permission.
- Consent prompt (#300): pending, client consent over active view.

**Skin token bridge:** HTML served on port 3000 receives the account-proxy token only when the request host is loopback or an IP currently assigned to a local network interface. The live interface list is authoritative to avoid retaining stale DHCP addresses in the allowlist and to support Ethernet or multiple adapters. The WiFi IP cached for display is accepted only when interface enumeration fails. Hostnames never receive the token, which is what preserves the DNS-rebinding boundary: a rebound name resolves to a device address by construction, so honouring one for the token would hand it to the attacker's origin.

A hostname that resolves to a device address does pass the port-3000 entry redirect and receive the tokenless script tag (issue #699). The redirect only echoes the requested host on the current generation's port, and before 0.8.2 the entry served those requests as static files anyway; `window.decentApp` carries no secret and no-ops outside the embedded webview. Resolutions are cached per served generation under a short TTL and re-checked against the live interface list on every request, so a lookup that recovers, an address that moves, or an interface that disappears reclassifies without waiting for a restart. The cache is bounded so spoofed Host headers cannot grow it without limit or force a lookup per request.

## Decent Binary Protocol

The protocol is DE1-specific. See
[`device-notes/de1.md`](device-notes/de1.md#protocol-source-of-truth).

## Workflow Dual Representation

Workflow JSON has both `context` (new: `WorkflowContext` with `grinderModel`, `coffeeName`, etc.) and legacy fields (`grinderData`, `coffeeData`, `doseData`). `Workflow.fromJson()` backfills context from legacy fields. UI reads from `context`; API clients can write to either. Always keep both in sync when modifying serialization.

## Adding An Endpoint (Checklist)

1. Create/modify handler in `lib/src/services/webserver/`.
2. Add route in handler's `addRoutes()`.
3. Register in `webserver_service.dart` `_init()`.
4. Update `assets/api/rest_v1.yml` (or `websocket_v1.yml`) in the same commit.
5. Update `doc/Api.md` if user-facing.
6. Smoke-test via `scripts/sb-dev.sh` + `curl`/`websocat`.

## Focused Tests

```sh
flutter test test/services/webserver/
```

Device smoke tests:
```sh
scripts/sb-dev.sh start
curl http://localhost:8080/api/v1/info
websocat ws://localhost:8080/ws/v1/machine/state
```

## Machine WebSocket Re-bind (PR #453)

### Problem

A machine power-cycle drops the De1 object and builds a new one under the same device id (the USB stable id is derived from the SAMD21 factory serial, so it is byte-identical across a power-cycle). Machine sockets used to bind to one De1 instance at open and never re-bind, so a client that connected before the power-cycle sat on an open-but-silent socket forever (bench bug i14).

### Solution

`De1Handler._withDe1Ws` watches `De1Controller.de1` and re-attaches the payload subscription when the controller publishes a new instance. The socket stays open during the disconnect gap and frames resume automatically.

### Design Choices

- **Instance identity (`identical()`), not deviceId, is the swap signal.** The USB stable id is byte-identical across a power-cycle, so an id comparison would see "same machine" and never re-bind. `identical()` also keeps a duplicate emission of the same De1 from double-subscribing (which would double the frame rate).

- **No `{"status": ...}` frames.** Unlike the scale socket, the machine sockets carry a single typed payload per frame and existing clients parse every frame as that type; injecting a status frame would be a breaking change to the wire contract. Link state is already published, instance-independently, on `/ws/v1/devices`.

- **Initial attachment is deterministic.** When `connectedDe1OrNull` returns a machine, it is subscribed immediately before subscribing to the controller stream. When no machine exists, the socket starts detached and waits for the first non-null `De1Controller.de1` event. Telemetry sockets emit nothing until attachment, while raw commands still return the documented detached-command error.

- **Commands during disconnect produce an error frame.** `/ws/v1/machine/raw` commands sent while no machine is attached get a `{"error": "No machine connected"}` response rather than being silently dropped. The socket stays open. Raw commands are never queued for later delivery — a delayed raw read/write could be stale or unsafe.

- **Controller stream has explicit `onDone`/`onError`.** On controller shutdown the payload subscription is cleaned up and the socket is closed, rather than leaking subscriptions.

### Clients Affected

All four machine sockets: `/ws/v1/machine/snapshot`, `/ws/v1/machine/shotSettings`, `/ws/v1/machine/waterLevels`, `/ws/v1/machine/raw`.

## Tare Lockout During Shot (issue #499)

`PUT /api/v1/scale/tare` rejects with `400` (`type: "block_tare_during_shot"`) when the `blockTareDuringShot` setting is on and `De1Controller.currentShotState.state` is not `idle`/`finished`. The gate lives in `ScaleHandler`, not `ScaleController.tare()` — `ShotSequencer`/`HotWaterSequencer` call the controller method directly for legitimate in-app tares (arm-before-pour, stop-at-weight), and gating the controller method would break the shot itself.

**Full gateway mode is explicitly exempt**, checked via `settingsController.gatewayMode == GatewayMode.full` alongside the shot-state check — not left implicit. In `full` mode the skin owns the shot and `De1StateManager` normally never starts its own `ShotSequencer` for it, so `currentShotState` would usually stay idle anyway; but the launcher/home-screen path in `De1StateManager._handleEspressoState` starts an app-owned `ShotSequencer` "regardless of mode" whenever the app's own home screen is foregrounded, even under `full` gateway mode. Relying on ShotSequencer-absence alone would make the lockout accidentally engage in that edge case, which is out of scope for the setting's intent (it exists to protect app-tracked shots, not skin-owned ones) — hence the explicit gateway-mode check rather than an inferred one.

## Keeping Notes Fresh

Add protocol compatibility rules, API versioning decisions, and endpoint design rationale. Prune when specs are updated.

## Data Sync Invariants

- Sync phase success is derived from requested section semantics, not transport status alone.
- Existing direct `pull.<section>` and `push.<section>` paths are compatibility surfaces; semantic phase data is additive under `phases`.
- Pull, push, and two-way may omit sections; omission means all locally registered sections. Explicit empty lists are invalid in every mode. Missing requested archive or import sections prevent completion.
- Legacy HTTP `200` import bodies with embedded errors are partial or failed according to section progress.
- Two-way push requires a complete pull unless `continueOnPullFailure: true` is explicitly requested.
- Skipped push is represented as a `skipped` phase, and partial section processing is not transactional.

## Bounded Backup Streaming (issue #555)

The backup pipeline streams data end to end; peak memory scales with one page
of records and one JSON record, never with backup size. Rationale and traps:

- **ZIP export keeps the custom streaming writer because `archive`'s encoder
  buffers compressed entries.** Import uses `archive`'s file-backed
  `InputFileStream` / `ZipDecoder` path. Each selected `ArchiveFile` writes to
  one bounded temporary JSON file through `OutputFileStream`; size and CRC are
  verified before incremental parsing, and the file is deleted before the next
  entry. New exports remain byte-compatible with `ZipDecoder`, and old
  `ZipEncoder` backups still import.
- **JSON is parsed with a real incremental parser**
  (`util/incremental_json_parser.dart`): a token-level state machine that
  yields complete values at a configured depth (1 for array sections, 3 for
  the KV `namespaces` map, 0 for singletons), handles strings/escapes/UTF-8
  boundaries, and throws on truncation, trailing garbage, and bad tokens.
  Import first validates every selected section without mutation, then runs
  the record imports. Malformed JSON returns `400` without importing any
  section; valid JSON with individually invalid records keeps per-record error
  accounting.
- **Sections stream records** via injected page functions (keyset cursors for
  shots/steams on `(timestamp, id)`, beans/grinders on `(createdAt, id)`;
  profile ids and KV keys are small, documented exceptions). Storage
  interfaces are unchanged; `BackupDataSources` carries the DB-backed page
  functions from `main.dart`, and tests inject instrumented paging seams.
- **Limits** are centralized in `data_transfer_limits.dart` and injectable
  for tests: request body 2 GiB, entry count 4096, per-entry uncompressed
  1 GiB, total uncompressed 2 GiB, metadata 64 KiB, per-record 64 MiB, ZIP
  header fields 256 B/64 KiB/64 KiB, sync request 1 MiB, target response
  8 MiB; import request bodies have a 30 s idle timeout and sync command bodies
  have a 30 s read deadline; transfer timeouts are 10 s connection (TCP
  establishment only) / 30 s idle /
  10 min deadline per phase covering the NETWORK stages only (upload/
  download + response); local export and the pull-side import run to
  completion and report their actual results. Timeouts abort the request
  at the transport level via `http.AbortableRequest` /
  `AbortableStreamedRequest`: a timed-out pull is cut off even before
  headers (while the target is still generating its export) and never
  starts its import; a timed-out push aborts its upload so a push still
  uploading cannot complete remotely. The push body is fed with
  `sink.addStream`, which pauses the file read while the transport is
  backpressured (the archive is never read ahead of the network); the
  sink closes only after the file is fully read (`addStream` does not
  forward the source's done event). Once the archive is fully uploaded
  the remote outcome is unknowable and the phase reports reason
  `timeout_unknown` rather than claiming the push did not happen. The
  completed export archive is also bounded by the 2 GiB import request
  limit, and per-record caps are measured in UTF-8 bytes. All are below
  ZIP64 thresholds so Zip64 can be rejected outright.
- **Temp files**: every operation owns one unique temp directory
  (`util/temp_archive_files.dart`), deleted in `finally` or on stream
  cancel/done. Native export defers cleanup (grace timer) because the OS
  share sheet reads the file asynchronously.
- **Legacy compatibility**: entry names, JSON shapes (including
  `store.json`'s `namespaces` wrapper and beans' embedded `batches`),
  `metadata.json` semantics, conflict strategies, selected-section behavior,
  platform warnings, atomic export, non-transactional section isolation, and
  `200`/`207`/`400` + sync phase semantics are unchanged.

## Workflow PUT Queue

`PUT /api/v1/workflow` operations are serialized through one queue owned by
`WorkflowHandler`. One HTTP request is exactly one handler queue entry. The handler
reads the workflow base when that entry reaches execution, then applies only that
request's deep merge. Machine side effects from workflow PUTs, profile sync, Bengle
workflow bridges, and other callers share the `De1Controller` governor: one active
DE1 operation plus at most 32 pending operations. Pending rinse, steam, and hot-water
workflow setting writes coalesce by setting group; the displaced caller receives
`409 Conflict`, while unrelated and imperative writes remain FIFO. A failure must
not poison either queue tail.
Request bodies are read with a 30-second timeout before their queued operation
executes; body-read failures are observed immediately and do not poison the queue.
The body stream subscription is cancelled on completion, error, size rejection, or
timeout so expired readers cannot outlive admission accounting.
Admission is limited to 1 MiB per body and eight active or queued requests. A request
that waits 30 seconds for execution returns `503` and its queued mutation is skipped.

Direct machine writes complete before controller workflow state is committed. The
handler commits with a controller revision check; if another workflow source changes
the controller during device I/O, the request rebases its merge and repeats the
required writes before retrying the commit. A machine-write failure returns `500` and
leaves controller workflow state unchanged; multi-step device writes may still be
partially applied, so a retry re-attempts the requested settings. `WorkflowDeviceSync`
remains the owner of asynchronous profile upload after controller changes.

### Device-Write Retry and Machine Replacement

`De1Controller.runDeviceWrite()` is the single serialized boundary for imperative
DE1 operations. It captures the connection generation and physical-machine identity
when admitted. Imperative operations never replay: a generation change before or
during execution fails the operation after any in-flight native write settles.

Only `runReplaceableDeviceWrite()` operations for rinse, steam, and hot-water
workflow settings may reconcile once after a disconnect. Reconciliation waits up to
`ConnectionTimings.machineReplacementTimeout` (10 s), then requires the replacement
to have the same physical identity and its startup initialization to settle. Identity
uses the machine serial number when available and otherwise the device ID. A different
machine is rejected rather than receiving stale work. If the same machine does not
return within the bound, the handler returns `503 Machine unavailable`.

Caller cancellation or timeout does not release an active physical operation. The
governor advances only after that operation actually settles. Firmware upload uses
the same serialized boundary for its full duration; firmware cancellation remains a
direct command.

### REST Route Serialization Audit

Mutating machine routes in `de1handler.dart` route physical writes through the DE1
governor. Ordinary REST machine mutations enter as imperative operations; workflow
updates use replaceable setting groups. Bodies are parsed before admission and
controller streams are published only after the grouped write succeeds. The idle
safety path is the exception documented below:

- `PUT /api/v1/workflow` (workflow handler, device writes via `updateWorkflowSettings`)
- `POST /api/v1/machine/profile`
- `POST /api/v1/machine/shotSettings`
- `POST /api/v1/machine/settings` (all fields, one entry)
- `POST /api/v1/machine/settings/advanced`
- `DELETE /api/v1/machine/settings/reset` (complete reset, one entry)
- `POST /api/v1/machine/calibration`
- `POST /api/v1/machine/waterLevels`
- `PUT /api/v1/machine/cupWarmer`, `PUT /api/v1/machine/ledStrip`,
  `POST /api/v1/machine/ledStrip/commit`, `POST /api/v1/machine/ledStrip/reset`

Every endpoint above can return `503` when the 32-entry pending queue is full and
`400` for malformed JSON bodies
(machine settings, advanced, calibration, waterLevels, cupWarmer, ledStrip,
profile, and shot settings parse their complete body before reserving a queue entry).
Machine-write failures otherwise map to `500`.

Documented bypasses:

- `PUT /api/v1/machine/state/<newState>` routes non-idle requests through the governor.
  Only `idle` bypasses it so stop remains serviceable behind saturated or stalled work.
- Raw low-level MMR commands via `/ws/v1/machine/raw`: intentionally unqueued (see
  the machine WebSocket re-bind section); a delayed raw read/write could be stale.
- Diagnostic UI commands remain intentionally unqueued.

### Machine Disconnect Simulation (debug only)

`MockDe1.simulateDisconnect()` emits a disconnected connection state explicitly; it
does not schedule a reconnect. It is exposed only through the simulate-mode
`POST /api/v1/debug/machine/disconnect` route (via `DebugHandler`), mirroring the
scale debug commands. Writing `heaterPh2Timeout` is an ordinary MMR write on
`MockDe1`; on real hardware Decaid treats it as an ordinary MMR write — no reset
behavior is documented.

### Status Codes

| Code | Meaning |
|------|---------|
| 200 | Workflow updated and committed |
| 400 | Malformed or invalid JSON |
| 408 | Client did not finish sending the body within the timeout |
| 409 | A pending replaceable workflow setting write was superseded by a newer value |
| 413 | Body exceeds 1 MiB limit |
| 429 | Admission capacity full (8 active or queued requests) |
| 500 | A required direct machine write failed, or no machine was ever connected |
| 503 | Mutation timed out waiting for its execution turn, the 32-entry DE1 pending queue is full, or the same machine did not return within the bounded wait for a replaceable workflow write |
