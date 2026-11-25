# New-owner reset: native capability findings

Source-level findings for #1259 at `2aad5d145fc16f48c70abc660bb6e8ff2df22242`, using cached
sources matching `pubspec.lock`. They establish available APIs, not successful native erasure.
No platform is proven to satisfy the entire live-reset contract. The inactive journal slice does
not remove these blockers or authorize a platform downgrade.

## Browser stores

- Android inappwebview 1.2.0-beta.3 uses legacy `WebStorage.deleteAllData()` with immediate return
  (`MyWebStorage.java`); cookie deletion has a separate callback/flush (`MyCookieManager.java`).
  Plugin build.gradle uses AndroidX WebKit 1.14.0, but does not expose comprehensive
  `WebStorageCompat.deleteBrowsingData`. That API, added in 1.13.0, covers cache, cookies and
  JavaScript-readable storage, requires runtime `DELETE_BROWSING_DATA`, and has a completion
  callback. It is non-atomic: views/workers must stop before deletion. Runtime capability and
  service-worker/auth/session canaries still require proof.
- iOS/macOS inappwebview fork `fc33a449b9290b127a471808e22eb7b0edebad92` exposes default
  `WKWebsiteDataStore` fetch/remove callbacks through `MyWebStorageManager.swift`. Interface
  1.4.0-beta.3 `WebsiteDataType.ALL` lists cookies, local/session storage, IndexedDB, fetch caches
  and service-worker registrations; this static list is not a dynamic list of every OS data type.
- Android also owns `CredentialDatabase.db` v2, separately from website data.
  `CredentialDatabaseHandler.clearAllAuthCredentials` clears its tables and native
  `WebViewDatabase` HTTP credentials. Client-cert preferences and SSL decisions have separate
  methods. Apple `CredentialDatabase.swift` uses `URLCredentialStorage.shared`; prove scoped
  protection-space ownership before removal. No current app HTTP-auth callback does not prove
  historical credential absence. Never clear OS-wide passwords/certificates.
- Windows inappwebview 0.7.0-beta.3 accepts `userDataFolder`, but app code establishes no explicit
  owned profile and the plugin has no `ClearBrowsingData` binding. Current/legacy profile paths
  and WebView2 credential scope remain unproven; never delete a guessed directory.
- Linux overrides WebView with `flutter_inappwebview_linux_noop`. External browser profiles belong
  to other applications and cannot be erased by this feature. Host-side sessions/tokens/storage
  still require reset; external/unmanaged skins are not preservable selections.

Reference: <https://developer.android.com/reference/androidx/webkit/WebStorageCompat>.

## Telemetry

Analytics 12.4.2 exposes `resetAnalyticsData()` to clear device analytics data/reset instance ID.
Crashlytics 5.2.3 exposes unsent-report check/delete, but deletion queues work and is a no-op with
automatic collection enabled. Its Flutter native wrappers do not await disk-deletion acknowledgement.
Official Android documentation says disabling collection takes effect on the next run; checking
unsent reports while collection is enabled is not an erasure check. Performance 0.11.4+2 exposes
collection toggles, not a purge acknowledgement API.

The app telemetry queue has no stop/clear/drain API; crash handlers bypass it, and Firebase native
initialization precedes Dart consent disabling. Current inspected Android/iOS configuration has no
collection-disable key. A Dart-only recovery barrier cannot prove native uploads are fenced.
Required evidence remains pinned native initialization/transport behavior, current-session/queued
payload purge completion, and isolation showing later consent cannot send factory payloads.
Build-time deactivation prevents future collection; it does not prove retroactive erasure.

References: <https://firebase.google.com/docs/reference/android/com/google/firebase/crashlytics/FirebaseCrashlytics>
and <https://firebase.google.com/docs/perf-mon/disable-sdk>.

## Secret-store isolation

FlutterSecureStorage 10.3.1 offers `readAll`/`deleteAll`; the app wrapper does not. Orphan plugin keys
therefore require namespace enumeration, not only manifests of currently installed plugins.

| Backend | Verified limitation |
|---|---|
| Android 10.3.1 | Default app-private `FlutterSecureStorage` prefs and separate `decaid_github_pat` prefs. Enumeration decrypts prefixed values; deleteAll uses asynchronous `apply()`. PAT legacy file isolation does not isolate every key alias. Corruption, migration remnants and durable readback need strict owned-scope handling. |
| Darwin 0.3.2 | Default service `flutter_secure_storage_service`; deletion tries both synchronizable states and may report success when either succeeds. Verify exact accessible service/group scope and both states; partial/inaccessible results must block ready. |
| macOS app file stores | Owned account `secure_storage_v1.dat`/`.tmp` and separate PAT `github_pat_secure_storage_v1.dat`/private mktemp remnants. Non-strict account decoding can read corrupt ciphertext as empty, making keyed delete/readback insufficient. |
| Linux 3.0.1 | One scoped JSON item: `${APPLICATION_ID}/FlutterSecureStorage`, account `${APPLICATION_ID}.secureStorage`; current CMake ID is `net.tadel.reaprime`. deleteKeyring writes empty JSON, not the OS keyring. Keyed delete swallows some errors; migration namespaces need provenance. |
| Windows 4.1.0 | App-support `*.secure` files plus legacy Credential Manager entries filtered by binary/STORAGE_PREFIX. readAll/deleteAll return early when no files exist, skipping legacy-only credentials. Current binary name is `Decaid`; historical namespaces need provenance. Never clear all Credential Manager entries. |

## Literal paths and lifecycle seams

logging_appenders 2.0.0+1 defaults to three rotations/10 MiB, but its loop produces `log.txt` and
`.1`, `.2`, `.3`; getAllLogFiles omits `.3`. App upload reads `.1..10`. Retain the appender handle
before teardown: dispose flushes/closes but catches errors. `webview_console.log` is one
self-truncated file; its void dispose does not await close.

Known temporary names include `api`, `import_report.txt`, `de1app_import_staging`,
`update_<version>.apk`/UUID `.part`, `webui_install*`, `webui_extract*`, `decaid_plugin_*`,
`reaprime-native-export-*`, `reaprime-export-*`, and sync pull/push prefixes. Plugin folder install
also uses unprefixed systemTemp staging; it has finally cleanup, but process death can leave it.
Managed skin candidates live under `<web-ui>/.webui-install-staging`. Windows path_provider 2.3.0
uses shared GetTempPath; Linux 2.2.1 uses TMPDIR or /tmp. Names/prefixes are not ownership proof.
Future staging receipts solve future cases only; legacy leftovers require attribution or failure.

`ConnectionManager.shutdown` is one-way and disconnects machine/scale/grinder. Plugin disposal is
also terminal; WebUI can stop serving. API startup discards listener handles, requiring retained
close/request-drain ownership. Wi-Fi stopScan is a no-op while liveness runs. Firmware admission
includes private pending state. App-log uploadNow can start an upload: it must not be used as drain.

Normal reconnect writes fan and workflow steam/hot-water/rinse settings
(`de1_controller.defaults.dart:8–52`); absent saved refill settings skip their replay. Retaining IDs
is not proof of unchanged hardware. Provisioning recovery must not apply old overrides or stock
workflow defaults as a side effect. This conflict requires a bounded existing-owner policy and
transport-fake/authorized observation evidence, not retaining the whole machine-settings map.

Complete native cleanup, early startup fencing, lifecycle draining, historical namespace coverage,
reconnect invariance and platform/physical acceptance remain prerequisites to any live reset.
