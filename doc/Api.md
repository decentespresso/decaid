# API Reference

Decaid exposes REST and WebSocket APIs on port 8080. Full OpenAPI specs are in [`assets/api/rest_v1.yml`](../assets/api/rest_v1.yml) and [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml). Interactive docs are available at port 4001 when the app is running.

For skin development, see [`doc/Skins.md`](Skins.md). For plugin development, see [`doc/Plugins.md`](Plugins.md).

---

## Conditional GETs (ETag / If-None-Match)

The following list endpoints set a strong `ETag` on every `200 OK` response and honour `If-None-Match` with `304 Not Modified` (empty body) when the client's tag matches:

- `GET /api/v1/beans`
- `GET /api/v1/beans/{beanId}/batches`
- `GET /api/v1/grinders`
- `GET /api/v1/profiles`
- `GET /api/v1/shots` (per query-param combination — filters and pagination are part of the tag)

Usage:

```bash
# First request — note the ETag
curl -is http://localhost:8080/api/v1/beans

# Re-request with If-None-Match — 304 if nothing changed
curl -is -H 'If-None-Match: "abc123…"' http://localhost:8080/api/v1/beans
```

Tags are SHA-256 derived from the encoded response body. Single-resource GETs and mutation routes do **not** emit ETags.

For browser clients on a different origin, `ETag` is exposed via `Access-Control-Expose-Headers`.

---

## REST API

### Machine

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/machine/info` | Machine model, firmware, features | `de1handler.dart` |
| GET | `/api/v1/machine/state` | Current machine state + substate | |
| PUT | `/api/v1/machine/state/{newState}` | Request state change (`idle`, `sleep`, `espresso`, …) | |
| GET | `/api/v1/machine/settings` | DE1 machine settings (temps, flows) | |
| POST | `/api/v1/machine/settings` | Update machine settings (one grouped, serialized device write per request) | |
| POST | `/api/v1/machine/shotSettings` | Update shot settings (steam temp, hot water, target volume, group temp) | |
| GET | `/api/v1/machine/settings/advanced` | Advanced heater/phase settings | |
| POST | `/api/v1/machine/settings/advanced` | Update advanced settings (heater phase flows/timeouts, idle temp, `heaterVoltage`, `refillKitSetting`) | |
| DELETE | `/api/v1/machine/settings/reset` | Reset machine settings to defaults (fan, heater idle/phase flows + ph2 timeout, refill kit auto, flow multiplier 1.0, steam purge 0) — one grouped, serialized device write | |
| GET | `/api/v1/machine/calibration` | Flow estimation calibration (`flowMultiplier`, calFlowEst MMR) | |
| POST | `/api/v1/machine/calibration` | Update flow estimation calibration | |
| GET | `/api/v1/machine/calibration/{target}` | Read DE1 sensor calibration for `flow`/`pressure`/`temperature`, `?source=current\|factory` | |
| PUT | `/api/v1/machine/calibration/{target}` | Write DE1 sensor calibration for `flow`/`pressure`/`temperature` | |
| POST | `/api/v1/machine/profile` | Upload profile to machine | |
| GET | `/api/v1/machine/firmware` | Firmware catalog with per-artifact eligibility | `firmware_handler.dart` |
| POST | `/api/v1/machine/firmware` | Raw firmware upload (NDJSON progress stream) | `firmware_handler.dart` |
| DELETE | `/api/v1/machine/firmware` | Cancel in-progress firmware update (idempotent) | `firmware_handler.dart` |
| POST | `/api/v1/machine/firmware/apply` | Managed firmware apply: resolve, validate, upload | `firmware_handler.dart` |
| — | USB charger | Controlled via `POST /api/v1/machine/settings` with `{"usb": "enable"}` or `{"usb": "disable"}` | |
| POST | `/api/v1/machine/waterLevels` | Update water level threshold | |
| GET | `/api/v1/machine/capabilities` | List capability identifiers supported by the connected machine. Bengle returns the full set: `cupWarmer`, `integratedScale`, `stopAtWeight`, `ledStrip`, `scaleCalibration`, `preheat`, `wakeSchedule`; plain DE1 returns an empty list | |
| GET | `/api/v1/machine/cupWarmer` | Read cup-warmer state: setpoint (whole °C), manual `enabled`, live `currentTemperature` — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/cupWarmer` | Set setpoint (whole °C, 0–80) and/or `enabled`; temperature-only requests also enable manual heating (back-compat), `enabled:false` keeps the setpoint — Bengle only | |
| GET | `/api/v1/machine/cupWarmer/preheat` | Read scheduled pre-warm `enabled`/`leadMinutes`/`active` (firmware-owned timing) — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/cupWarmer/preheat` | Set pre-warm `enabled` and/or `leadMinutes` (0–120, persisted in firmware) — Bengle only | |
| GET | `/api/v1/machine/ledStrip` | Read LED strip palette (3 zones × 2 modes, 16-bit RGB; `frontSwitch` derived, not a hardware control); 503 until firmware hydration succeeds — Bengle only | |
| PUT | `/api/v1/machine/ledStrip` | Write palette write-through to FW registers (persisted immediately; `frontSwitch` ignored) — Bengle only | |
| POST | `/api/v1/machine/ledStrip/commit` | Compatibility no-op (palette writes are already persisted) — Bengle only | |
| POST | `/api/v1/machine/ledStrip/reset` | Re-read palette from FW and return refreshed state (truthful reload, not a rollback) — Bengle only | |
| GET | `/api/v1/machine/scaleCalibration` | Read decoded scale-calibration state (step, cell, sub-state, seconds remaining, status) — Bengle only, 404 elsewhere | |
| PUT | `/api/v1/machine/scaleCalibration` | Start `zero`/`latch`/`abort` calibration step (`weightGrams` 1–10000 required for `latch`); 202 accepted / 409 rejected (busy or shot in progress) — Bengle only | |

#### Firmware updates

The catalog endpoint is available offline and without a connected machine. It returns bundled artifact metadata, compatibility and version eligibility, the recommended artifact, tri-state `updateAvailable`, and the shared machine operation state. The bundled Phase 1 artifact is official DE1 firmware build 1352 for `DE1Pro`, `DE1XL`, `DE1XXL`, and `DE1XXXL`.

Managed apply accepts `{"artifactId":"de1-1352","force":false}`. The complete image is checked against its manifest, SHA-256 digest, canonical DE1 header, and connected model before erase. `force` permits reinstall or downgrade, including when the installed build is unknown, but never bypasses integrity or model checks. The raw endpoint retains its developer/recovery role and accepts `application/octet-stream`.

Raw and managed updates return `application/x-ndjson`. Events are ordered `erasing`, zero or more `uploading`, then `done`; failures after streaming starts terminate with `error`. Upload progress is emitted in approximately one-percent increments. The stream remains open during final machine verification, and `done` is sent only after the DE1 reports `FF FF FD`. Client disconnect and `DELETE` request cancellation through the shared machine operation.

Pre-stream responses are `400` for malformed input, `404` for an unknown artifact, `409` for an active update, `422` for validation or policy rejection, and `503` when apply requires a machine. Idempotent cancellation returns `202` with `{"operation":{"state":"idle"}}` when no update remains active.

### Scale

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| PUT | `/api/v1/scale/tare` | Tare the connected scale | `scale_handler.dart` |
| PUT | `/api/v1/scale/timer/start` | Start scale timer | |
| PUT | `/api/v1/scale/timer/stop` | Stop scale timer | |
| PUT | `/api/v1/scale/timer/reset` | Reset scale timer | |

### Devices

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/devices` | List devices (present + remembered) | `devices_handler.dart` |
| GET | `/api/v1/devices/scan` | Scan and fill missing device slots; set `?connect=false` for discovery only | |
| PUT | `/api/v1/devices/connect` | Connect to device by ID | |
| PUT | `/api/v1/devices/disconnect` | Disconnect device | |
| PUT | `/api/v1/devices/forget` | Forget a remembered device | |
| GET | `/api/v1/devices/wifi` | List manually-added WiFi scale endpoints | `wifi_scale_handler.dart` |
| POST | `/api/v1/devices/wifi` | Add a WiFi scale by IP/hostname (`{host}`) | |
| DELETE | `/api/v1/devices/wifi` | Remove a manual WiFi endpoint (`{host}` body or `?host=`) | |

`/api/v1/devices/scan` keeps the existing query shape and defaults:
`connect=true` when omitted and `quick=false` when omitted. With connection
enabled, the request scans first, preserves occupied slots, then fills missing
machine and scale slots; this may take longer than the former quick-connect
behavior. `quick=true` returns immediately but does not change that policy.

`PUT /api/v1/devices/connect` waits for the attempt and returns `deviceId`,
`operation`, `outcome`, the resulting device `state`, and a structured
`connectionError` when applicable. Connected and already-connected devices return
200; conflicting or stale requests return 409; transport failures return 503;
and connection timeouts return 504. The devices WebSocket returns the same result
after each connect command.

Each device entry carries an **`available`** boolean. `true` = currently present
in discovery; `false` = a **remembered** device that isn't present (reported with
`state: "disconnected"`). Devices the user connects to are remembered and persist
across restarts, shown as unavailable when offline, until forgotten via
`PUT /api/v1/devices/forget` (deviceId in the JSON body or `?deviceId=` query).
The same `available` field is on each device in the `ws/v1/devices` snapshot.

**Manual WiFi scale endpoints.** Auto-discovered (DNS-SD) WiFi scales appear in
`GET /api/v1/devices` like any other device and need no extra calls. The
`/api/v1/devices/wifi` routes are only for *manually* entering a scale by IP or
hostname (e.g. on networks where mDNS is blocked). All three return
`{ "endpoints": [<host>, ...] }`. An added endpoint surfaces in the device list
as a "Half Decent Scale (WiFi)" entry and validates through the normal
recognition gate — a bad/unreachable address shows as a scale that never
reaches `connected`.

### Shots

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/shots` | Paginated list with filtering | `shots_handler.dart` |
| GET | `/api/v1/shots/ids` | All shot IDs | |
| GET | `/api/v1/shots/latest` | Most recent shot | |
| GET | `/api/v1/shots/:id` | Get shot by ID (with measurements) | |
| PUT | `/api/v1/shots/:id` | Update shot annotations | |
| DELETE | `/api/v1/shots/:id` | Delete shot | |

### Steams

Recorded milk-steaming sessions. Each record is opened when the machine
enters `steam` and finalized when it leaves. Today no probe is wired in
production, so `SteamSnapshot.milkTemperature` is `null` on every frame —
the API surface is scaffolding for skin developers and for future
probe / FW support. `SteamSettings.stopAtTemperature` (in
`/api/v1/workflow`) is the target the future FW-autonomous stop or
in-app stop will trigger on.

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/steams` | List all steam records (no measurements) | `steams_handler.dart` |
| GET | `/api/v1/steams/ids` | All steam record IDs | |
| GET | `/api/v1/steams/latest` | Most recent steam record (no measurements) | |
| GET | `/api/v1/steams/:id` | Get steam record by ID (with measurements) | |
| PUT | `/api/v1/steams/:id` | Update steam record annotations | |
| DELETE | `/api/v1/steams/:id` | Delete steam record | |

### Profiles

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/profiles` | List all profiles | `profile_handler.dart` |
| GET | `/api/v1/profiles/defaults` | List bundled default profiles (filename + metadata) | |
| GET | `/api/v1/profiles/:id` | Get profile by content-hash ID | |
| POST | `/api/v1/profiles` | Create new profile | |
| PUT | `/api/v1/profiles/:id` | Update profile (in-place; hash change replaces the record) | |
| DELETE | `/api/v1/profiles/:id` | Soft-delete profile (defaults hidden, user profiles soft-deleted) | |
| PUT | `/api/v1/profiles/:id/visibility` | Change profile visibility | |
| GET | `/api/v1/profiles/:id/lineage` | Get profile version history | |
| DELETE | `/api/v1/profiles/:id/purge` | Permanently delete (user profiles only) | |
| GET | `/api/v1/profiles/export` | Export all profiles as JSON | |
| POST | `/api/v1/profiles/import` | Import profiles from JSON | |
| POST | `/api/v1/profiles/restore/:filename` | Restore a bundled default by manifest filename | |

### Workflow

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/workflow` | Get current workflow (profile + context) | `workflow_handler.dart` |
| PUT | `/api/v1/workflow` | Update workflow (one ordered deep-merge mutation) | `workflow_handler.dart` |

Each `PUT /api/v1/workflow` is one independent mutation. Requests run in FIFO order without
cross-request or cross-client coalescing. Partial updates are deep-merged against the latest
workflow state when each request executes, and each response contains that request's resulting
workflow. Requests may wait behind machine I/O; the server does not debounce high-frequency
input, so clients should throttle controls themselves. Bodies larger than 1 MiB return `413`,
requests beyond the eight-entry active/queued limit return `429`, and requests waiting more
than 30 seconds for execution return `503` without being applied. Machine-write failures
return an error before the controller workflow is committed. Multi-step machine writes may
be partially applied, and retrying the same request re-attempts the requested settings.
Request bodies have a 30-second read timeout; body-read failures return `408`
without poisoning later queued mutations. If the machine disconnects while a
workflow device write is in flight, the write is retried once on the replacement
machine (waiting up to 10 seconds for one to appear); if no replacement arrives the
request returns `503` and the workflow is not committed. A `stopAtTemperature`-only
workflow change never touches the DE1 directly — the Bengle bridge applies it
asynchronously — so it commits even while no machine is connected.

### Beans

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/beans` | List all beans | `beans_handler.dart` |
| POST | `/api/v1/beans` | Create bean | |
| GET | `/api/v1/beans/:id` | Get bean | |
| PUT | `/api/v1/beans/:id` | Update bean | |
| DELETE | `/api/v1/beans/:id` | Delete bean | |
| GET | `/api/v1/beans/:id/batches` | List batches for a bean | |
| POST | `/api/v1/beans/:id/batches` | Create batch | |
| GET | `/api/v1/bean-batches/:id` | Get batch | |
| PUT | `/api/v1/bean-batches/:id` | Update batch | |
| DELETE | `/api/v1/bean-batches/:id` | Delete batch | |

### Grinders

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/grinders` | List all grinders | `grinders_handler.dart` |
| POST | `/api/v1/grinders` | Create grinder | |
| GET | `/api/v1/grinders/:id` | Get grinder | |
| PUT | `/api/v1/grinders/:id` | Update grinder | |
| DELETE | `/api/v1/grinders/:id` | Delete grinder | |

### Settings

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/settings` | All app settings (gateway, theme, charging, devices, etc.) | `settings_handler.dart` |
| POST | `/api/v1/settings` | Update settings (partial, key-by-key) | |

Settings fields include: `gatewayMode`, `themeMode`, `logLevel`, `weightFlowMultiplier`, `volumeFlowMultiplier`, `hotWaterFlowMultiplier`, `scalePowerMode`, `blockOnNoScale`, `blockTareDuringShot`, `stopHotWaterAtWeight`, `preferredMachineId`, `preferredScaleId`, `defaultSkinId`, `automaticUpdateCheck`, `chargingMode`, `nightModeEnabled`, `nightModeSleepTime`, `nightModeMorningTime`, `lowBatteryBrightnessLimit`, `keepAwake`, `simulatedDevices`.

`stopHotWaterAtWeight` (boolean, default `true`): when on and a scale is connected, hot-water dispensing tares the scale and stops at the configured hot-water `volume` target treated as grams (mirrors the espresso stop-at-weight). The machine's own volume/time stop remains a backstop, and the value is ignored in `full` gateway mode (a skin owns the machine). `hotWaterFlowMultiplier` (number, default `0.3`) is the seconds-of-lookahead applied to scale weight flow for that stop — separate from `weightFlowMultiplier` because hot water dispenses with a different pump/flow profile than espresso. See [DeviceManagement.md](DeviceManagement.md#hot-water-stop-at-weight).

`blockTareDuringShot` (boolean, default `false`): when on, `PUT /api/v1/scale/tare` is rejected with `400` (`type: "block_tare_during_shot"`) while an **app-tracked** espresso shot is actively brewing (any `ShotState` other than `idle`/`finished`). Prevents a stray programmatic tare (skin, external client) from re-zeroing the scale mid-pour and wrecking stop-at-weight. Does not affect the shot sequencer's own arm-before-pour tare or a manual tare via the scale's physical button — those never go through this endpoint. **`full` gateway mode is an explicit policy exemption**: the skin owns the shot there, so this lockout never blocks a tare in that mode, regardless of any app-tracked (including stale or unexpected) shot state.

### WebUI & Skins

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/webui/skins` | List installed skins | `webui_handler.dart` |
| GET | `/api/v1/webui/skins/:id` | Get skin details | |
| GET | `/api/v1/webui/skins/default` | Get default skin | |
| PUT | `/api/v1/webui/skins/default` | Set default skin (`{skinId}`) | |
| POST | `/api/v1/webui/skins/install/github-release` | Install from GitHub release | |
| POST | `/api/v1/webui/skins/install/github-branch` | Install from GitHub branch and persist its source for update checks | |
| POST | `/api/v1/webui/skins/install/url` | Install from ZIP URL | |
| DELETE | `/api/v1/webui/skins/:id` | Remove installed skin | |
| POST | `/api/v1/webui/skins/update` | Check all skins for updates from remote sources | |
| GET | `/api/v1/webui/server/status` | Server status (`{serving, path, port, ip}`) | |
| POST | `/api/v1/webui/server/start` | Start serving default skin on port 3000 | |
| POST | `/api/v1/webui/server/stop` | Stop serving | |
| GET | `/api/v1/webui/skin-assets/:id/:filepath` | Fetch a file from another installed skin (cross-skin asset sharing) | |

### Plugins

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/plugins` | List all plugins (with `loaded`, `autoLoad` fields) | `plugins_handler.dart` |
| GET | `/api/v1/plugins/:id/settings` | Get plugin settings; secure fields return `{isSet}` only | |
| POST | `/api/v1/plugins/:id/settings` | Patch plugin settings (omitted preserves, `null` clears) and return a redacted result | |
| POST | `/api/v1/plugins/:id/enable` | Load plugin + enable auto-load | |
| POST | `/api/v1/plugins/:id/disable` | Unload plugin + disable auto-load | |
| DELETE | `/api/v1/plugins/:id` | Remove plugin (unload + delete files) | |
| POST | `/api/v1/plugins/install` | Install from URL (not yet implemented — returns 501) | |
| ANY | `/api/v1/plugins/:id/:endpoint` | Plugin HTTP endpoint; requires `api` and returns 403 without it | |
| WS | `/ws/v1/plugins/:id/:endpoint` | Plugin WebSocket endpoint | |

Plugin setting updates use patch semantics for every field: an omitted field
preserves the existing value, a field sent as `null` clears it, and a secure
field sent as its returned `{ "isSet": true|false }` object preserves the
stored credential. Secure values are never returned by either endpoint,
including the POST response.

### Display

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/display` | Display state (brightness, wakelock) | `display_handler.dart` |
| POST | `/api/v1/display/brightness` | Set brightness | |
| POST | `/api/v1/display/wakelock` | Request wakelock override | |
| DELETE | `/api/v1/display/wakelock` | Release wakelock override | |

### Presence & Sleep

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| POST | `/api/v1/machine/heartbeat` | Signal user presence (keep-alive) | `presence_handler.dart` |
| GET | `/api/v1/presence/settings` | Get presence/sleep settings | |
| POST | `/api/v1/presence/settings` | Update presence/sleep settings (validated — see below) | |
| GET | `/api/v1/presence/schedules` | List wake schedules | |
| POST | `/api/v1/presence/schedules` | Create wake schedule | |
| PUT | `/api/v1/presence/schedules/:id` | Update wake schedule | |
| DELETE | `/api/v1/presence/schedules/:id` | Delete wake schedule | |

`POST /api/v1/presence/settings` validates its body before persisting anything:

| Field | Accepted | On anything else |
|---|---|---|
| `userPresenceEnabled` | a boolean | `400`, nothing stored |
| `sleepTimeoutMinutes` | a JSON integer | `400`, nothing stored |

Integer values for `sleepTimeoutMinutes` are normalized into **0..240**. `0` disables the app-side
idle sleep timer. Partial updates are supported — fields are optional. Invalid field types in the
same request prevent all fields from being stored (validation is atomic).

### Sensors

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/sensors` | List connected sensors | `sensors_handler.dart` |
| GET | `/api/v1/sensors/:id` | Get sensor manifest | |
| POST | `/api/v1/sensors/:id/execute` | Execute sensor command | |

### Key-Value Store

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/store/:namespace` | List keys in namespace (or `?full=1` for the whole namespace) | `kv_store_handler.dart` |
| GET | `/api/v1/store/:namespace/:key` | Get value | |
| POST | `/api/v1/store/:namespace/:key` | Set value | |
| DELETE | `/api/v1/store/:namespace/:key` | Delete key | |

`GET /api/v1/store/:namespace?full=1` returns the entire namespace as a `{key: value}` map in one request instead of one GET per key. It sends an `ETag`, so a repeat request with `If-None-Match` returns `304 Not Modified` when nothing changed — cheap to poll. Without the flag the endpoint returns just the array of keys.

### Data Management

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/data/export` | Export full backup as ZIP | `data_export_handler.dart` |
| POST | `/api/v1/data/import` | Import from ZIP (raw bytes, `Content-Type: application/zip`) | |
| POST | `/api/v1/data/sync` | Sync with another Bridge instance | `data_sync_handler.dart` |

Sync accepts `target` (URL), `mode` (`pull`, `push`, `two_way`), `onConflict` (`skip` or `overwrite`), and `sections` (profiles, shots, workflow, settings, store, steams, beans, grinders). The `target` must be an HTTP/HTTPS origin with no path, query, or fragment; a trailing slash is accepted and equivalent, and IPv4, hostname, and IPv6 hosts are supported. Other forms return `400` before any network request. `sections` is optional for all three modes; omission means all locally registered sections. An explicitly empty or malformed list, or unknown section, returns `400` before any network request. Duplicate names are deduplicated in first-occurrence order.

Sync responses use semantic results rather than transport status alone. Each direct section under `pull.<section>` and `push.<section>` remains available and gains `status` (`complete`, `partial`, or `failed`). Additive phase metadata is under `phases.<phase>` with `status`, `complete`, and `partial`; fatal phase details remain available at the legacy `pull` or `push` path and are repeated under `phases`. Skipped-push reasons are reported under `phases`. A phase is complete only when every expected section is represented without errors. Warnings, conflict skips, and zero imported records do not make a valid section partial. Section errors with progress are partial; errors without progress are failed. Partial imports are not transactional.

In `two_way` mode, push runs only after every expected pull section completes by default. Set `continueOnPullFailure: true` to explicitly continue after a partial or failed pull; the option is limited to `two_way` and is never inferred from overwrite handling. A complete operation returns `200`, an incomplete single-direction operation returns `502`, and an incomplete two-way operation with meaningful progress returns `207`; a two-way operation with no complete or partial phase returns `502` (its body may still report `partial` only when meaningful progress exists). Legacy flat and structured remote import responses are supported, but malformed, contradictory, hybrid, missing-section, and HTTP `200` responses with embedded errors are not treated as success.

Backups are ZIP archives with one JSON file per registered section:
`profiles.json`, `shots.json`, `workflow.json`, `settings.json`, `store.json`,
`steams.json`, `beans.json`, and `grinders.json`. Import matches files by their
registered section names; unknown files are ignored, but an archive must contain
at least one recognized selected section. `metadata.json` is not payload:
metadata-only, empty, and unknown-only archives return `400`. Metadata is
optional for legacy archives without it. When present, its JSON and
`formatVersion` are validated before any section is imported. ZIP integrity and
structural JSON are validated for every selected section before storage is
mutated; any failure returns `400` without importing a section. Semantic record
errors are processed independently and are not transactional, so successful
sections are not rolled back when another section reports semantic errors.
Export is atomic: if any requested
section fails to export, the request returns an error identifying the failed
section(s) and no partial ZIP is returned.

`POST /api/v1/data/import` preserves its section-keyed response body. `200`
means at least one recognized section was processed and every processed section
completed without errors. `207 Multi-Status` means at least one processed
section contains errors; successful sections, counts, warnings, and errors are
all retained. Warnings and conflict-strategy skips alone still return `200`.
Clients must inspect both the HTTP status and each section result.

Data sync preserves the same phase distinction. A complete pull or push is
represented by `200`. An incomplete single-direction sync returns `502`, even
when its body reports semantic `partial` progress. A two-way sync returns `207`
when it has meaningful progress but is incomplete; a two-way sync with no
complete or partial phase returns `502`. Phase results remain under `pull` and
`push`, including successful sections and fatal error details.

### Bounded-memory transfer (issue #555)

Backup export, import, and sync stream data instead of buffering whole
archives in memory; peak memory scales with one page of records and one JSON
record, never with backup size.

- **Export** streams each section (records paged via stable keyset cursors)
  through a file-backed ZIP writer (raw deflate via `dart:io`, data
descriptors, central directory written last) and serves the completed
temporary ZIP with `Content-Type: application/zip`, `Content-Disposition:
attachment`, and `Content-Length`. The archive is atomic: a failing section
returns an error and no partial ZIP.
- **Import** streams the request body into a temporary ZIP (never
`read().toList()`), opens it with `InputFileStream` / `ZipDecoder`, and writes
one selected entry at a time to a bounded temporary JSON file for incremental
parsing. Every selected entry is structurally validated before the record-import
pass begins. ZIP bombs, duplicate names, encrypted/unsupported entries, CRC
failures, truncation, Zip64, and malformed JSON all fail safely.
- **Sync** pulls stream the remote response into a temporary ZIP; pushes
export locally and stream the file with a known content length.
- **Native transfer** downloads the localhost export into a temporary file
(validating HTTP status and `application/zip` before presenting a
destination), shares it via the OS share sheet on iOS/Android, and streams
picked files into the import request.

Limits (documented in `assets/api/rest_v1.yml`): request body 2 GiB, entry
count 4096, per-entry uncompressed 1 GiB, total uncompressed 2 GiB,
metadata 64 KiB, per-record 64 MiB (measured in UTF-8 bytes), ZIP header
fields 256 B/64 KiB/64 KiB; sync request body 1 MiB, target response
8 MiB; connection 10 s (TCP establishment only — server-side
export/import processing is not counted against it), idle 30 s, and one
deadline (10 min) per phase covering the network stages (upload/download
and response). Timeouts abort the request at the transport level: a
timed-out pull is cut off even while the target is still generating its
export (before headers) and never starts its import; a timed-out push
aborts its upload, and the upload is backpressured so the archive file
is never read ahead of the network. Local export and the pull-side
import run to completion and report their actual results. If the archive
was already fully uploaded before the deadline, the remote outcome is
unknown and the phase reports reason `timeout_unknown`. A generated
archive is also bounded by the 2 GiB import request limit.

### Account

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/account/decent` | Decent account link status: `{loggedIn}` | `account_handler.dart` |
| GET | `/api/v1/account/proxy/<path>` | Auth-enriching proxy to `decentespresso.com/<path>` | `account_proxy_handler.dart` |
| POST | `/api/v1/account/proxy/<path>` | Auth-enriching write proxy (relays body) | `account_proxy_handler.dart` |
| PUT | `/api/v1/account/proxy/<path>` | Auth-enriching write proxy (relays body) | `account_proxy_handler.dart` |

Linking/unlinking a Decent account is **native-only** — there are no network login/logout routes. The webserver is unauthenticated with `Access-Control-Allow-Origin: *`, so exposing credential operations would let any LAN client or browser origin store attacker credentials or unlink the account. The status response omits the linked email (PII).

The **proxy** lets clients *use* the account without ever seeing the credentials: it attaches the linked account's Basic auth server-side, forwards to `decentespresso.com`, and relays the upstream status + body verbatim. It requires `Authorization: Bearer <token>` and is enforced only on this path. `GET` requires `account:proxy` (including the skin token injected into served skin pages); `POST`/`PUT` require the stronger `account:proxy:write` scope, so the read-only skin token cannot write. Forwarding is restricted to the `support/api/` prefix. The OpenAPI spec documents the generated-client-safe `/support/api/{endpoint}` form; use this raw catch-all route when a Decent backend path contains additional slashes. Responses: 401 (missing/invalid token or no linked account), 403 (token unscoped or path not allowed). Write-scoped tokens are minted from the account page's API-token UI by enabling "Allow write access".

### Other

| Method | Path | Description | Handler |
|--------|------|-------------|---------|
| GET | `/api/v1/info` | Build metadata (version, commit, branch) + gateway LAN IP (`localIp`) | `info_handler.dart` |
| GET | `/api/v1/update` | App-update state snapshot (`phase`, `latestVersion`, `releaseNotes`, `releaseUrl`, `installable`). Pure read — no network call; force a re-check via `/ws/v1/update`. | `update_handler.dart` |
| POST | `/api/v1/feedback` | Submit feedback (creates GitHub issue) | `feedback_handler.dart` |
| GET | `/api/v1/logs` | Recent log entries, newest first. Live log + rotated files `log.txt.1..N` are always stitched chronologically; response is a size-bounded tail window (`?kb=N`, default 1024 KB, clamped to 4096 KB). `?order=asc` for original chronological order | `logs_handler.dart` |
| GET | `/api/v1/webview/logs` | WebView console log forwarding, newest first (`?order=asc` for original chronological order) | `webview_logs_handler.dart` |
| POST | `/api/v1/derek/answers/stream` | Relay to the Derek RAG assistant: forwards the JSON body verbatim to `derek.decentespresso.com/api/answers/stream` and pipes the SSE response back unbuffered. No auth (public data). Exists so browser skins avoid Derek's failing CORS preflight. | `derek_handler.dart` |

### Debug (debug builds only)

Only registered when the app is launched with a non-empty `simulate` Dart define. Use `--dart-define=simulate=0` to enable the routes without selecting simulated devices. Returns 404 on production builds.

| Method | Endpoint | Description | Handler |
|--------|----------|-------------|---------|
| POST | `/api/v1/debug/update/force` | Force a fake "update available" so the update API/UI can be tested without a real newer release. Optional query: `version` (default `99.0.0`), `downloadUrl` (default = real latest APK, so the download/install path runs end-to-end). | `debug_handler.dart` |
| GET | `/api/v1/debug/flow-smoothing` | Read process-local display-flow smoothing (`windowMs`, `movingAverageSamples`). | `debug_handler.dart` |
| POST | `/api/v1/debug/flow-smoothing` | Atomically update and reset display-flow smoothing; accepts integer `windowMs` (100–2000) and `movingAverageSamples` (1–50). | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/stall` | Pause mock scale weight emission (stays "connected") | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/resume` | Resume weight emission after stall | `debug_handler.dart` |
| POST | `/api/v1/debug/scale/disconnect` | Simulate scale disconnect (emits disconnected state, stops data) | `debug_handler.dart` |
| POST | `/api/v1/debug/machine/disconnect` | Simulate mock machine disconnect (emits disconnected state, no auto-reconnect) | `debug_handler.dart` |
| GET | `/api/v1/debug/replay/shots` | List the replay simulator's bundled recordings (stable `id` + `profileTitle`) and the current forced selection (`simulate=replay`). | `debug_handler.dart` |
| POST | `/api/v1/debug/replay/shot/{id}` | Force ReplayDE1 to play recording `id` on subsequent pulls (session-only); overrides profile-match/fallback. | `debug_handler.dart` |
| DELETE | `/api/v1/debug/replay/shot` | Clear the forced recording, returning to profile-match/fallback selection. | `debug_handler.dart` |

Mock-scale command endpoints return 400 if no scale is connected or the connected scale is not a `MockScale`. The machine command endpoint returns 400 if no machine is connected or the connected machine is not a `MockDe1`, and 404 for unknown commands (any debug route 404s on production builds).

---

## WebSocket API

All WebSocket endpoints are on port 8080 at `/ws/v1/...`. See [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml) for full schemas.

| Path | Description | Data |
|------|-------------|------|
| `/ws/v1/machine/snapshot` | Machine state stream (~10Hz). Re-binds across a machine reconnect — see [Machine sockets re-bind](#machine-sockets-re-bind-across-a-reconnect). | Temps, pressures, flow, state |
| `/ws/v1/scale/snapshot` | Scale weight/flow stream. Device-provided flow is passed through; weight-only scales use Decaid's estimator. Stays open across scale disconnects; emits `{"status":"connected"\|"disconnected"}` frames on state change. | Weight, flow, battery |
| `/ws/v1/machine/shotSettings` | Shot settings changes. Re-binds across a machine reconnect. | Target temp, volume, weight |
| `/ws/v1/machine/waterLevels` | Water level changes. Re-binds across a machine reconnect. | Current/limit levels |
| `/ws/v1/machine/raw` | Raw BLE characteristic data. Re-binds across a machine reconnect; writes go to the currently-bound machine. | Hex-encoded bytes |
| `/ws/v1/machine/shotState` | Shot sequencer state + decision feed: why a step advanced, why the shot stopped. Replays the latest frame on connect; idle between shots; not gated on a connected machine. | `event` (`state`\|`decision`\|`terminal`), `shotId`, shot phase, machine context, `decision {kind, reason, details, data}` |
| `/ws/v1/devices` | Device discovery + `ConnectionManager` status (phase, found devices, ambiguity, errors). Also accepts `scan`/`connect`/`disconnect` commands. | Device list, `connectionStatus` |
| `/ws/v1/sensors/:id/snapshot` | Sensor data stream | Sensor-specific |
| `/ws/v1/plugins/:id/:endpoint` | Plugin WebSocket proxy | Plugin-specific |
| `/ws/v1/logs` | App log stream | Timestamped log entries |
| `/ws/v1/webview/logs` | WebView console log stream | WebView console messages |
| `/ws/v1/display` | Display state changes | Brightness, wakelock |
| `/ws/v1/update` | App-update state stream. Also accepts `{"command":"check"}` and `{"command":"install"}` (Android installs; other platforms reply `{"error","url"}`). | `phase`, `progress`, `latestVersion`, `installable` |

### Machine sockets re-bind across a reconnect

When a machine reconnects — a power-cycle, a USB re-enumeration, a BLE drop — the app discards the
old machine object and builds a new one. The machine sockets
(`/ws/v1/machine/{snapshot,shotSettings,waterLevels,raw}`) **follow the swap**: the server re-attaches
each open socket to the new machine and frames resume on their own.

For clients this means:

- **Clients do not need to reconnect solely because the machine disconnects.** The socket stays open
  and goes quiet while no machine is connected, then resumes. This mirrors `/ws/v1/scale/snapshot`.
  The existing socket follows a normal machine instance swap, but clients should still reconnect after
  actual WebSocket closure, network failure, or according to their normal liveness policy.
  `/ws/v1/devices` is the authoritative source for machine connection state.
- **No status frame is emitted.** Unlike the scale socket, each machine socket carries exactly one
  payload type per frame, and existing clients parse every frame as that type — a `{"status": ...}`
  frame would break the wire contract. Track link state on `/ws/v1/devices` instead, which reports it
  independently of any machine instance.
- **A gap in frames is not a dead socket.** If a client needs a liveness signal, use `/ws/v1/devices`.
- `/ws/v1/machine/raw` writes are delivered to the machine the socket is *currently* bound to, not the
  one that was present when the socket was opened.
- If a raw command is sent while no machine is connected, the server replies with
  `{"error": "No machine connected"}` rather than silently dropping it. The socket stays open and
  resumes normal operation when a machine reconnects. Raw commands are not queued for later delivery.

Machine sockets opened before the first machine connection behave like any later disconnected gap:
the socket stays open and remains silent until a machine attaches. No error or status frame is emitted
on the typed telemetry sockets.

### `shotState` events

`/ws/v1/machine/shotState` streams the app's shot-sequencer decisions as a single event type
discriminated by `event`. Every frame carries the current shot phase (`state`) and machine context,
so a late joiner gets a coherent view from any single frame; `decision` is non-null only on
`decision`/`terminal` frames.

```json
{
  "event": "decision",
  "timestamp": "2026-06-17T10:32:18.903Z",
  "shotId": "a1b2c3d4-...",
  "state": "pouring",
  "machineState": "espresso",
  "machineSubstate": "pouring",
  "profileFrame": 2,
  "scaleConnected": true,
  "scaleLost": false,
  "machineHasAutonomousSAW": false,
  "decision": {
    "kind": "stop",
    "reason": "targetWeight",
    "details": "Target weight 36.0g reached (projected: 36.4). Stopping shot.",
    "data": {"targetYield": 36.0, "projectedWeight": 36.4}
  }
}
```

- `shotId` equals the persisted `ShotRecord.id`, so the stream can be correlated to the saved shot.
  The final stop reason is also persisted on the record as `stopReason`.
- `decision.reason` is an **open set** — tolerate unknown values. Known reasons: `targetWeight`,
  `targetVolume` (app-side targets), `profileSkip` (app-issued weight skip), `profileAdvance`
  (firmware-natural step exit), `apiStop` / `appStop` (stop command attributed to a REST client /
  the in-app Stop button), `machineEnded` (GHC stop or natural profile completion —
  indistinguishable), `noScale` (blocked by `blockOnNoScale`), `error` / `disconnected` (abnormal
  endings, `event: "terminal"`), `stoppingBackstop` (post-stop settling window closed by the safety
  timer; never the stop reason itself).
- Coverage: the feed reflects app-side sequencing only. In full gateway mode with the app
  backgrounded no sequencer runs (the feed stays `idle`), and on machines with autonomous
  stop-at-weight (Bengle) the final yield stop is firmware-side and reported as `machineEnded`.

### `connectionStatus.error`

When a BLE operation fails (connect timeout, mid-session disconnect, adapter off, permission denied, scan failure, or profile upload failure), the devices WebSocket emits an update with a structured `connectionStatus.error` object. `null` when no error is active.

```json
{
  "kind": "scaleConnectFailed",
  "severity": "error",
  "timestamp": "2026-04-19T07:49:29.025Z",
  "deviceId": "50:78:7D:1F:AE:E1",
  "deviceName": "Decent Scale",
  "message": "Scale Decent Scale failed to connect.",
  "suggestion": "Wake the scale and try again.",
  "details": {"fbp_code": 1}
}
```

See [`assets/api/websocket_v1.yml`](../assets/api/websocket_v1.yml) for the full `ConnectionError` schema. Full `kind` taxonomy, lifecycle rules, and the recommended skin handling pattern are in [`doc/Skins.md`](Skins.md#handling-connection-errors).

---

## Bundled Plugins

### Settings Plugin (`settings.reaplugin`)

Built-in settings dashboard accessible at `/api/v1/plugins/settings.reaplugin/ui`. Provides a web-based interface for managing all app settings, skins, plugins, data, and more.

**Query parameters:**
- `backName` — customizes the back button label. E.g., `/api/v1/plugins/settings.reaplugin/ui?backName=Extracto` shows "Back to Extracto" instead of "Back to WebUI".

**Sections:** REA Application Settings, Battery & Charging, Machine Settings, Machine Advanced Settings, Calibration, Presence & Sleep, Simulated Devices, Web Interface (skin management + server control), Data Management (export/import/sync), Plugin Management, Feedback, About.

**Self-protection:** The plugin management section prevents disabling or removing `settings.reaplugin` itself (UI guard).

### DYE2 Plugin (`dye2.reaplugin`)

Bean and grinder management. See [`packages/dye2-plugin/README.md`](../packages/dye2-plugin/README.md).
