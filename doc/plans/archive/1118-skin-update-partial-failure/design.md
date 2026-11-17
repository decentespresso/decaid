# Issue #1118 — Skin update check returns HTTP 500 on partial remote failure

## Root cause (established, not re-derived)

`WebUIStorage.updateAllSkins()` and `PluginSourceService.updateAllPlugins()` collapse
every per-item result into one aggregate `RemoteUpdateException` whenever *any* item
fails. Both REST handlers catch that exception and return a blanket HTTP 500, so a
single dead remote source out of eleven discards the other ten results and hides which
item failed and why.

## Decision

Both update endpoints return per-item results instead of a blanket 500 on partial
failure:

- The update check itself "completes" even when individual items fail, so the endpoint
  returns **HTTP 200** with a `results` array as long as the check ran to completion.
- Only a failure of the check machinery itself (unable to load the remote-source list,
  unable to rescan installed skins, etc.) still returns HTTP 500.
- Existing non-REST callers (`skin_selector_page.dart`, `update_check_service.dart`,
  native settings views) keep calling the existing `updateAllSkins()` /
  `updateAllPlugins()` methods, which keep throwing `RemoteUpdateException` on any
  failure. Their behaviour is unchanged.

### Per-item result shape

A new shared result type in `lib/src/util/remote_update_report.dart`:

```dart
enum RemoteUpdateStatus { updated, alreadyCurrent, failed, pendingApproval }

class RemoteUpdateItemResult {
  final String item;
  final RemoteUpdateStatus status;
  final Object? error; // original exception, failed items only
}
```

JSON for each item:

```json
{"item": "allofmeng/streamline_project", "status": "alreadyCurrent"}
{"item": "tadelv/passione", "status": "updated"}
{"item": "deadexample/dead", "status": "failed", "error": "The service could not complete the request. Try again later."}
```

Statuses map to the issue's vocabulary; `pendingApproval` is added for plugins whose
candidate update asks for new permissions (an existing successful outcome that is
neither "updated" nor "already current"). Skins never emit `pendingApproval`.

### Endpoint responses

Both `POST /api/v1/webui/skins/update` and `POST /api/v1/plugins/update` return:

```json
{
  "message": "Skin update check completed",  // unchanged legacy field
  "results": [ ... ]
}
```

The `message` field is retained verbatim so a caller that only reads it still works.

## Implementation

### `WebUIStorage` (`lib/src/webui_support/webui_storage.dart`)

- `_installFromGitHubRelease` and `_installFromUrlAsRemoteBundled` return
  `Future<RemoteUpdateStatus>` (`alreadyCurrent` when metadata/ETag/Last-Modified
  matches, `updated` after install). Public install entry points ignore the return.
- Extract the remote-bundled loop into `checkRemoteBundledSkins()` (public and
  overridable, so tests can isolate it) returning `List<RemoteUpdateItemResult>`;
  `_downloadRemoteSkins()` derives its `RemoteUpdateException` from those results
  (preserving the existing throwing `downloadRemoteSkins()` behaviour).
- `_runSkinUpdates()` combines `checkRemoteBundledSkins()` + `_checkUserSkins()` +
  rescan into one `Future<RemoteUpdateReport>`.
- `checkForSkinUpdates()` is the single-flighted report entry point: it shares one
  in-flight report (`_updateCheckReport`) across concurrent callers and drives the
  existing `_updateCheck` notifier so the native UI observes REST-triggered checks.
- `updateAllSkins()` awaits `checkForSkinUpdates()` and rethrows as
  `RemoteUpdateException` when any item failed, so both entry points coordinate.

### `PluginSourceService` (`lib/src/plugins/plugin_source_service.dart`)

- `_updatePlugin` returns `Future<RemoteUpdateStatus>` (unchanged → `alreadyCurrent`,
  installed → `updated`, approval recorded → `pendingApproval`).
- `checkForPluginUpdates()` is the single-flighted report entry point (shared
  `_updateCheckReport`, drives `_updateCheck`), built on `_runPluginUpdates()`.
- `updateAllPlugins()` awaits it and rethrows on failure.

### Handlers

- `webui_handler.dart` `_handleUpdateSkins` and `plugins_handler.dart` update route call
  the new `checkFor*Updates()` methods and return `jsonOk({message, results})`; the
  catch still returns 500 for a check that could not run at all.

### Error reasons

Add a public `remoteErrorReason(Object error)` helper in `lib/src/util/remote_error.dart`
exposing the existing `_errorAdvice` mapping so per-item `error` fields carry the same
plain-language text as today's aggregate messages, without the "Couldn't ..." prefix.

## Contract and docs (same commit)

- `assets/api/rest_v1.yml`: rewrite the `200` responses for both endpoints to document
  `results`, and change the `500` description to "the update check could not run".
- `doc/Api.md`: update both endpoint rows / add the per-item result shape.

## Non-goals

- No change to the throwing behaviour of `updateAllSkins()` / `updateAllPlugins()`.
- No new HTTP status codes; 200 carries per-item failures.
- No retry/backoff or per-item retry logic.
- No change to the tokenless-loopback admission rules or throttling.

## Test matrix

- New: `WebUIStorage.checkForSkinUpdates` returns per-item `updated` / `alreadyCurrent`
  / `failed` with a partial failure (one source dead, one live) and does not throw.
- New: `PluginSourceService.checkForPluginUpdates` returns per-item statuses including
  `pendingApproval`, and does not throw on partial failure.
- New: both REST endpoints return 200 with a `results` array when one item fails.
- New: `remoteErrorReason` unit coverage for the failure classes already covered by
  `remoteErrorMessage`.
- Existing `updateAllSkins()` / `updateAllPlugins()` throwing tests must stay green
  (they exercise the retained wrapper path).
