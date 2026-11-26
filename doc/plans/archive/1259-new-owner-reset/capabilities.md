# New-owner reset: native capability findings

## Latest Apple verification boundary

After the approved Apple registration deferral, a disposable macOS verification copy used a unique
bundle/container identity, ad-hoc App Sandbox signing and no network/device/keychain-group entitlements
(allow-jit retained). A separate harmless probe first established isolated Foundation paths and denied
an owned localhost connection. Synthetic resetting, ready, earlier-process armed and invalid-UTF8
launches reached the expected Dart block without Firebase indicators in captured process logs. An
absent marker reached deferred native Firebase/Analytics/Crashlytics initialization; native request
attempts failed under the sandbox and normal API binding was deliberately denied. This is instrumented
runtime evidence, not unmodified production-path acceptance, no-attempt/no-send proof or payload purge.
The source debug dylib matched the built artifact; only copied packaging/signing changed. Owned
containers were removed afterwards, verification artifacts retained privately.

Subsequently, an operator-authorized disposable iOS simulator used a legitimate Firebase TEST project
with matching verification-only plist and Dart options, while production configuration stayed unchanged.
Current debug startup reached Welcome for an absent marker; resetting, ready, earlier-process armed,
invalid UTF-8 and unreadable markers showed the expected blocked states without Firebase initialization
indicators in captured native process logs. Native identity was observed before generated registration,
and supported Flutter hot restart preserved the process identity and admission-channel readiness.
Background/foreground returned to Welcome in the same process. Verification stopped before login,
permissions, initialization/import/scan and remote skin/device work. The synthetic automatic-update
preference was disabled. Profile/release simulator modes were refused by Flutter, so their explicit
Dart Firebase initialization path remains untested. These are TEST-project debug observations, not
production-project integration or full onboarding/device-lifecycle acceptance. Native SDK request
attempts occurred; no absence-of-attempts/transmission or payload-purge claim follows. The owned iOS
simulator/data and large verification copy were deleted afterwards; original simulators were preserved.
Older no-runtime statements below describe earlier evidence stages, superseded only to this bounded
extent by the latest macOS instrumentation and iOS TEST-project observations.


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

## Native pollution before Dart on Android

Pinned sources inspected for slice 2: `firebase_core` 4.10.0 (pub cache), and the Gradle artifacts
`com.google.firebase:firebase-common` 22.0.1, `firebase-analytics` 23.2.0, `firebase-crashlytics`
20.0.6 and `firebase-perf` 22.0.5 (Gradle cache AARs). This is source-level evidence of ordering, not
a device observation.

- `firebase_core` 4.10.0's Android plugin manifest declares only a
  `ComponentDiscoveryService` entry for `FlutterFirebaseCoreRegistrar`; it declares no provider.
- `firebase-common` 22.0.1 declares
  `<provider android:name="com.google.firebase.provider.FirebaseInitProvider"
  android:authorities="${applicationId}.firebaseinitprovider">`. Android creates content providers
  *before* `Application.onCreate` and before the first activity: in the pinned Android 35 source
  `/Users/vid/Library/Android/sdk/sources/android-35/android/app/ActivityThread.java`,
  `handleBindApplication` calls `installContentProviders(app, data.providers)` at line 7482 and only
  afterwards `mInstrumentation.callApplicationOnCreate(app)` at line 7498. This runs before any
  Flutter engine, before `FlutterActivity`, before Dart `main()`, and before any app-defined
  `Application.onCreate` body; `Firebase.initializeApp` in `lib/main.dart` is later still. With
  `android/app/google-services.json` present and the `com.google.gms.google-services` plugin
  applied (plus the `firebase-perf` and `crashlytics` Gradle plugins), the default app and its
  registered components (analytics, crashlytics, performance) are created at that point.
- `firebase-analytics` 23.2.0 declares no provider and no collection meta-data. `firebase-perf`
  22.0.5 declares no provider, but its manifest shows the build-time key it checks:
  `firebase_performance_collection_enabled` (present as a comment). `firebase-crashlytics` 20.0.6
  declares a `ComponentRegistrar` service only.
- The app's own Dart guard (`if (!Platform.isLinux && !Platform.isWindows && !isDebugOrSimulate)`)
  and `TelemetryService.initialize()`'s Dart collection toggles both run *after* native Android
  initialisation, and Dart-only toggles cannot purge a payload the native SDK already queued. This
  matches the telemetry finding above.
- **Correction, reviewed against the locked dependency source.** An earlier revision of this bullet
  claimed that on Darwin `firebase_core` 4.10.0's `FLTFirebaseCorePlugin.m` "configures the default
  app only from the Dart `initializeApp` channel call", so the SDK could be ordered behind a Dart
  gate. That claim is wrong and is retracted here. In `firebase_core` 4.10.0 the plugin's
  `registerWithRegistrar` calls `sharedInstance` (`FLTFirebaseCorePlugin.m:29-30`), and
  `sharedInstance`'s `dispatch_once` reads `FIROptions defaultOptions` and calls
  `FIRApp configureWithOptions` whenever those options are non-nil and no default app exists yet
  (`:44-61`); the macOS counterpart is identical (`:59`, `:61`). Both
  `ios/Runner/GoogleService-Info.plist` and `macos/Runner/GoogleService-Info.plist` exist and are
  packaged `in Resources` by their `project.pbxproj`, so `defaultOptions` is non-nil and that branch
  fires at plugin attach: on Apple the default `FIRApp` is configured by the engine-attach generated
  registrant, before `main()` and before this slice's Dart gate. When this bullet was written the
  slice's plugin deferral was Android-only (`MainActivity` plus the `admitPlugins` channel); the
  operator-approved Apple deferral recorded in
  [Adopted change: deferred plugin registration on iOS and macOS](#adopted-change-deferred-plugin-registration-on-ios-and-macos)
  now moves both Apple registrants behind the same channel and authority.
- **Apple status: superseded by the approved deferral below (still no runtime evidence).** The
  source finding stands — the default `FIRApp` is configured at plugin attach, before the gate — and
  it is the reason the Apple deferral exists. It is a source finding about *configuration* ordering,
  not a runtime, transmission or purge finding: it shows the default app would be configured before
  the gate on a blocked cold launch, and it shows nothing about uploads, queued payloads or
  successful sends on Apple hardware. Destructive reset stays disabled on both Apple platforms until
  runtime evidence exists.
- Re-checked for this correction against the same pinned artifacts: `android/app/build.gradle.kts`
  applies `com.google.gms.google-services` 4.3.15, `com.google.firebase.firebase-perf` 1.4.1 and
  `com.google.firebase.crashlytics` 2.8.1, and `android/app/google-services.json` exists. Across the
  resolved `com.google.firebase.*` and `com.google.android.gms.*` AARs in the local Gradle cache,
  `firebase-common` 22.0.1 is the **only** one that declares a `ContentProvider`:
  `com.google.firebase.provider.FirebaseInitProvider` with `directBootAware="true"`,
  `initOrder="100"` and authority `${applicationId}.firebaseinitprovider`. `firebase-analytics`
  23.2.0, `firebase-crashlytics` 20.0.6 and `firebase-perf` 22.0.5 declare only
  `ComponentDiscoveryService` registrars. `firebase_core` 4.10.0's
  `FlutterFirebaseCorePlugin.initializeApp` calls
  `FirebaseApp.initializeApp(applicationContext, options, appName)`, so an explicit Dart-side
  initialisation is a working path once the provider is out of the merged manifest.

Consequence for #1259: a Dart startup barrier alone cannot fence Android native initialisation.
Enabling destructive reset requires a native decision in one of these shapes, none adopted here:

1. Build-time collection disable for crashlytics/analytics/performance. Prevents future collection
   but cannot prove retroactive erasure of already-queued payloads.
2. Remove `FirebaseInitProvider` from the merged manifest and configure explicitly from
   `MainActivity`/`Application` after a native recovery-pending check. Controls ordering, still needs
   evidence that a prior process cannot have queued a payload.
3. A native boot gate that reads the recovery marker, with a native process identity: treats
   marker-read failures as "do not initialise". On its own it does not fence
   `FirebaseInitProvider`, because providers run before `Application.onCreate` (see above), so it
   only works combined with shape 2 or with a provider ordered ahead of `FirebaseInitProvider`.

All three need on-device verification (process start, cold start after pending recovery, queued
payload inspection) and maintainer authorisation; none may be simulated by a Dart test.

## Decision brief: native startup admission

Status: **option B adopted** on explicit operator approval ("Approve delayed firebase startup") and
implemented in this slice's app manifest. Options A and C remain unadopted.

Mechanism, precisely:

- `Application.onCreate` runs *after* Android creates content providers, so a custom `Application`
  class cannot run before `FirebaseInitProvider` and cannot stop it. The ordering is fixed in the
  framework: `handleBindApplication` calls `installContentProviders(app, data.providers)` at pinned
  Android 35 `ActivityThread.java:7482`, then `mInstrumentation.callApplicationOnCreate(app)` at
  `:7498`, i.e. every declared provider is instantiated before any app `Application.onCreate` body.
  The provider is declared by `firebase-common` and is instantiated regardless of what
  `Application.onCreate` decides.
- The only lever that prevents the default app from being created is taking the provider out of the
  merged manifest, i.e. `android/app/src/main/AndroidManifest.xml` declaring
  `<provider android:name="com.google.firebase.provider.FirebaseInitProvider"
  tools:node="remove"/>` with `xmlns:tools`, and then initialising Firebase explicitly with
  `Firebase.initializeApp(options: ...)` from Dart behind the admission gate.
- A native marker check before SDK work would need a native resolver for
  `<support>/new-owner-recovery/new-owner-reset-journal.json` plus its own JSON validation, so the
  native layer and the Dart admission cannot disagree about "pending". That is new native surface,
  not a manifest edit.

Options considered:

| Option | What it fixes | Why it is not adopted here |
| --- | --- | --- |
| A: manifest meta-data `firebase_analytics_collection_enabled`, `firebase_crashlytics_collection_enabled`, `firebase_performance_collection_enabled` set to `false` | future collection from the first millisecond | changes normal telemetry/consent startup behaviour, keeps SDK initialisation, and proves nothing about already-queued payloads |
| B: remove `FirebaseInitProvider`, initialise explicitly behind the Dart gate | default app and component creation move behind the gate; no analytics/crashlytics/perf registrar exists before it | needs a new native ordering guarantee, changes normal startup and crash-reporting of earliest failures, and still does not purge a payload queued by a previous process |
| C: native `Application`/`MainActivity` gate reading the marker before any SDK work | not stand-alone: `Application.onCreate` runs after content providers, so `FirebaseInitProvider` has already created the default app unless C also removes the provider (B) or declares a provider ordered ahead of it (`initOrder` above 100; Android 35 `ProviderInfo.java:81–83` specifies higher values first) | largest native surface (native marker parser, second source of truth), needs a new `Application` class outside this slice's file scope, and needs on-device proof |

Recommendation as recorded before approval: do **not** ship B or C without a dedicated, separately
authorised step. That approval was then given for the bounded form of B described above, and B is
what this slice now implements.

## Adopted change: option B

`android/app/src/main/AndroidManifest.xml` declares the `tools` namespace and removes the provider:

```xml
<provider
    android:name="com.google.firebase.provider.FirebaseInitProvider"
    tools:node="remove" />
```

The removal matches the provider by name, so no `authorities` attribute is repeated; the merged
output is byte-identical with or without it (same sha256 `f3434b3e…c54b7`).

No other startup code changed. `Firebase.initializeApp(options: ...)` stays inside
`startDecaidNormalServices`, i.e. it runs only for an `absent` marker whose admission is
`normalStartup`; every blocked or uncertain admission presents the recovery view instead and never
reaches it. Telemetry/consent toggles (`setCrashlyticsCollectionEnabled(false)` and the two
analytics/performance equivalents) are unchanged and still run on the normal startup path only.

What the merged manifest proves, on this host:

| Artifact | Observation |
| --- | --- |
| `:app:processDebugMainManifest` before the change | merged manifest (sha256 `457c4a17…ab87`) declares `com.google.firebase.provider.FirebaseInitProvider` with `directBootAware="true"`, `initOrder="100"`, authorities `net.tadel.reaprime.firebaseinitprovider` |
| `:app:processDebugMainManifest` after the change | merged manifest (sha256 `f3434b3e…c54b7`) has no `FirebaseInitProvider` entry; the whole diff against the baseline is those six lines, so nothing else was added or dropped |
| `:app:assembleDebug` after the change | debug APK built and packaged with the removal node (manifest merger and AAPT2 accept it); its binary `AndroidManifest.xml` (`aapt2 dump xmltree`) contains no `FirebaseInitProvider`/`firebaseinitprovider` entry, and the remaining providers are `FileProvider`, `InAppWebViewFileProvider`, `ShareFileProvider` and `androidx.startup.InitializationProvider` |

Remaining auto-init surfaces in the merged manifest, none of which creates a Firebase app:

- `androidx.startup.InitializationProvider` with `EmojiCompatInitializer`,
  `ProcessLifecycleInitializer` and `ProfileInstallerInitializer`.
- GMS measurement `AppMeasurementReceiver`, `AppMeasurementService`, `AppMeasurementJobService`,
  `GoogleApiActivity` and the `google_play_services_version` metadata.
- Firebase `ComponentDiscoveryService` registrars (analytics, crashlytics, performance, sessions,
  installations, remoteconfig, transport, abt, core). Registrars are discovered only when a
  `FirebaseApp` is initialised, which now happens only behind the gate.
- `com.google.firebase.sessions.SessionLifecycleService` (`android:enabled="false"`).

Tradeoff accepted with the approval: the earliest failures are no longer reported. Firebase
Crashlytics now starts only after the Dart admission, so a crash in native startup, in the Flutter
engine before `main()` reaches the gate, or inside the gate itself is not queued to Crashlytics.
That window used to be covered by provider-time initialisation and is now unreported telemetry.

What the change does not establish:

- No runtime observation exists for this change itself. Nobody ran the app for option B: no cold
  start with a `resetting` marker, no dump of the process' provider list, no app-private queue
  contents. The manifest scan shows what is declared and the Gradle run shows what the merger
  produced; neither shows what executed. A later authorised offline-emulator run did observe the
  deferred-registration behaviour on Android, and it is recorded in "Android emulator observations
  after deferral" below together with what it does and does not cover; it did not isolate option B,
  and it says nothing about Apple.
- Fencing initialisation is not purging payloads. A payload queued by a previous process (before this
  change, or before a reset) is untouched, and consent/telemetry data is untouched. This is an
  ordering guarantee for future SDK starts, not erasure.
- Whether any Firebase/GMS component transmits during a cold start with the provider removed and the
  gate blocked is modelled from the merged manifest and the registrars rather than proven. The later
  emulator run adds bounded log evidence that blocked launches logged no such component, which is not
  proof that none attempted a send. Until it is observed on a device, the native boundary stays a
  documented prerequisite for enabling destructive reset rather than a solved problem.

Required device verification for option B (the Android plugin-attach half of this requirement was
later observed on an offline emulator after the registration deferral, see below; option B in
isolation and every Apple platform remain unobserved): build a **profile or release**
APK first, because a debug build never initialises Firebase at all (`isDebugOrSimulate` includes
`kDebugMode`, so `Firebase.initializeApp` is skipped in debug and a debug run could not distinguish
fencing from that skip). Then cold start it with a `resetting` marker, an unreadable marker and an
absent marker; for each, read the running process' provider list and Firebase state (for example
`adb shell dumpsys activity <package>` plus app logcat with Firebase log tags), and confirm the
blocked cases create no `FirebaseApp` and open no network connection while the absent case still
initialises the default app once. That evidence is what promotes the table above from declaration
evidence to runtime evidence.

Bounded verification plan for option B, implemented to the extent this environment allows:

| Case | Required observation |
| --- | --- |
| marker absent | reproduces today's normal startup exactly: default app created, Dart `Firebase.initializeApp` still runs, existing telemetry/consent behaviour unchanged |
| marker `resetting` | no Firebase app, no analytics/crashlytics/performance component, no transport |
| marker `ready`, `handoffArmed` by this process, `handoffArmed` by a later process | same as `resetting`: no Firebase app and no transport, because the gate stays terminal |
| marker unreadable or otherwise uncertain | same as `resetting`, plus the visible recovery error; failure to read is never "absent" |
| explicit Dart initialisation path | `Firebase.initializeApp(options: ...)` still works once the provider is gone, and is the only creator of the default app |
| other SDK auto-init surfaces | each remaining provider/registrar outside Firebase (GMS tasks, any future vendor SDK) observed individually; no uninspected initialiser may run before the gate |

The plan distinguishes evidence classes. Actual native observations (process and provider start
trace, app logs, app-private queue contents) are separate from manifest/AAR scans and from Dart unit
tests, and neither of the latter two stands in for the former. Verification uses no cloud traffic,
no account sign-in and no credentials: a run must prove the absence of an SDK initialiser and of a
send, never by connecting to a backend.

Where that matrix stands in this slice:

| Case | Evidence held | Missing |
| --- | --- | --- |
| marker absent | admission test asserts `normalStartup` and that `Firebase.initializeApp` appears exactly once, inside `startDecaidNormalServices`; merged manifest no longer auto-creates the app | runtime confirmation on a device |
| marker `resetting`, `ready`, `handoffArmed`, unreadable | admission tests assert the gate blocks every one of these and never runs a normal service, so the explicit init is unreachable | a device trace showing no `FirebaseApp` and no transport |
| explicit Dart initialisation path | `FlutterFirebaseCorePlugin.initializeApp` in firebase_core 4.10.0 calls `FirebaseApp.initializeApp(applicationContext, options, appName)`; `:app:assembleDebug` builds with the provider removed | an actual initialisation observed after removal |
| other SDK auto-init surfaces | the post-removal merged manifest lists every remaining provider, service and registrar (see the list above) | runtime observation of each |

Nothing in the table is runtime evidence, and the manifest scan must not be quoted as if it were.
The "missing" column is the state before the authorised emulator run recorded in the next section.

## Android emulator observations after deferral

Two emulator runs exist and must not be conflated. The **superseded** run is the pre-deferral one
recorded under "Adopted change: deferred plugin registration": with `resetting` set, a debug build
logged `FA: App measurement initialized` before the gate because plugins were still registered at
engine attach. That counterexample is what motivated the deferral and is history, not current
behaviour. The **current** run is the matrix below, on a build that defers the generated registrant.

On an isolated offline API 35 emulator, debug and profile cold launches with synthetic resetting,
ready, earlier-process handoffArmed and invalid UTF-8 markers presented the expected blocked states.
Their app-process logs showed no plugin admission, Analytics measurement or FirebaseApp initialization.
The absent-marker profile launch admitted plugins and then initialized measurement, the default
FirebaseApp and Crashlytics. Its settings request failed offline. These are bounded runtime observations,
not proof of no attempted transmission, queued-payload purge, physical-device behavior or power-loss
durability. Same-process handoff classification remains unit-test evidence. Private sanitized logs and
build fingerprints accompany the handoff; no credentials or account actions were used. The matrix is
Android-only at the time of that run: neither Apple platform had a deferral then, and the Apple
counterpart only exists as the source-and-build change recorded in
[Adopted change: deferred plugin registration on iOS and macOS](#adopted-change-deferred-plugin-registration-on-ios-and-macos)
below. Nothing in the emulator matrix is Apple evidence.

## Adopted change: deferred plugin registration (operator-approved R1)

Option B removed the provider, and the authorised offline emulator run still showed
`FA: App measurement initialized, version: 161000` in the app process 183 ms **before** the Dart
admission gate (`resetting` marker, debug APK `4c64f00a…cb97`). The reaching path is plugin
engine-attachment, not the provider: `firebase_analytics` 12.4.2
`FlutterFirebaseAnalyticsPlugin.initInstance` calls `FirebaseAnalytics.getInstance(context)`
(`android/src/main/kotlin/io/flutter/plugins/firebase/analytics/FlutterFirebaseAnalyticsPlugin.kt:33`)
from `onAttachedToEngine` (`:71-73`), and `GeneratedPluginRegistrant` runs during
`configureFlutterEngine`, which precedes `executeDartEntrypoint`. Manifest-level removal therefore
cannot fence GMS measurement initialisation.

The operator approved a bounded native registration deferral. `MainActivity.configureFlutterEngine`
no longer calls `super.configureFlutterEngine` and no longer registers the generated registrant at
engine attach. This is the seam the pinned embedding documents:

- `FlutterActivity.java:1335-1344`: "To avoid the automatic plugin registration for implicitly
  created FlutterEngines, override this method without invoking super()."
- `GeneratedPluginRegister.java:47-60`: "Disabling the automatic plugin registration or deferring it
  by calling this method explicitly may be useful…"

`FlutterFragmentActivity.configureFlutterEngine` (pinned `:757-764`) contains only an
injected-engine guard and the registrant call, and this activity never injects a pre-built engine,
so skipping `super` removes exactly the registrant.

What the deferral consists of:

| Piece | Mechanism |
| --- | --- |
| Early bootstrap | `flutterEngine.plugins.add(JniPlugin())` and `...add(JniFlutterPlugin())`, and nothing else. `path_provider_android` 2.3.1 is a Dart-FFI plugin (`dartPluginClass: PathProviderAndroid`, no Java plugin class) that resolves paths through `androidApplicationContext` (`lib/src/path_provider_android_real.dart:36-45`), which `JniFlutterPlugin.onAttachedToEngine` sets (`JniFlutterPlugin.java:44-49`) and whose class loader is set by `JniPlugin`'s static initialiser (`JniPlugin.java` static block → `dartjni.h` `load_class_platform`). The gate cannot read its own marker without them. |
| Late registration | One app-owned channel `com.reaprime/recovery_plugins`, method `admitPlugins`, whose handler calls `GeneratedPluginRegistrant.registerWith(flutterEngine)` as a compile-time reference. No plugin list is copied: the single generated call site stays authoritative, so adding a dependency needs no host change. |
| Idempotency | A per-engine latch (`PluginRegistrationAdmission`) marks an engine admitted only after `registerWith` returned normally, and marks it failed for the rest of its life if registration threw. Re-registration by the generated registrant of the two bootstrapped classes is a logged no-op, because `FlutterEngineConnectionRegistry.add` short-circuits on `has(plugin.getClass())` with `Log.w` (`FlutterEngineConnectionRegistry.java:129-141`). |
| Fail closed | The registrant is a compile-time link, so a missing generated registrant fails `:app:assembleDebug`; and a project-local build guard (`android/buildSrc/.../GuardedPluginRegistration.java`) rewrites the pinned generator's per-plugin `catch (Exception e)` wrappers into the bare `add` statement, so the first throwing plugin fails `registerWith` instead of being logged and skipped. Any failure becomes `result.error("PLUGIN_REGISTRATION_FAILED", …)`; Dart converts a refusal or a missing handler into `NativePluginAdmissionException`, logs it and renders a visible failure screen instead of starting a reduced app. Unsupported generator output fails the build rather than admitting a partly registered engine. |
| Admission point | `await admitNativePlugins()` is the first statement of `startDecaidNormalServices`, i.e. after the recovery gate admitted normal startup and before the multicast lock, Firebase, telemetry, Hive, Drift, the web server, the plugin loader and the Android foreground service. Blocked and uncertain admissions never reach it. |

`WebView.setWebContentsDebuggingEnabled(true)` moved from `MainActivity.onCreate` to the admission
path. In the pinned Android 35 sources that call is `getFactory().getStatics()…`
(`android/webkit/WebView.java:2020-2022`) and `getFactory()` is `WebViewFactory.getProvider()`
(`:2605-2607`), which loads the WebView package and the Chromium libraries. It is the only app-side
call that resolves the WebView factory, and in the authorised run those loads (log lines
`WebViewFactory: Loading com.google.android.webview`, `cr_LibraryLoader`, `cr_CachingUmaRecorder`)
appear before `MainActivity`'s own post-call log line. Deferring it removes a pre-gate Chromium load;
it is not browser-store cleanup and changes no WebView data.

What this fences, exactly:

- Fenced: the activity engine of a fresh process. With any blocked or uncertain marker, the generated
  registrant is never called, so no plugin attaches, so no attach-time vendor SDK initialises.
- Not fenced, same process: after an admitted run, a Dart hot restart re-runs `main()` but the engine
  keeps its registry; no supported API unregisters it. The guarantee is a fresh **process** launch.
- Not fenced, second engine: `flutter_foreground_task` (`fba972b2…`) creates its own engine with
  `FlutterEngine(context)` (`android/src/main/kotlin/com/pravera/flutter_foreground_task/service/ForegroundTask.kt:49`),
  which auto-registers the full generated list. In the current configuration that engine cannot be
  created before admission: its only production trigger is `FlutterForegroundTask.startService` from
  Dart inside `startDecaidNormalServices`; `ForegroundService.onStartCommand` returns
  `START_NOT_STICKY` while `android:stopWithTask="true"` is in effect; `onTaskRemoved` stops instead
  of arming a restart alarm under the same flag; `onDestroy` arms a restart alarm only when
  `allowAutoRestart` is set **and** the service was not correctly stopped **and** stopWithTask is not
  set; `RebootReceiver` returns early on the stopWithTask flag; and the app passes
  `autoRunOnBoot: false`, `autoRunOnMyPackageReplaced: false`, no `allowAutoRestart` and no
  `stopWithTask` override (`lib/src/services/foreground_service.dart`). A focused test pins those
  four options so the claim cannot silently drift with the app's own configuration, but the gating
  logic itself lives in the third-party plugin and is a precondition to re-audit if that fork,
  `flutter_foreground_task` options or the foreground-service manifest entry change.
- Not fenced, generated registrant internals: the generated `GeneratedPluginRegistrant` wraps every
  plugin add in `try { … } catch (Exception e) { Log.e(…) }`, so one plugin's attach-time exception is
  logged and skipped rather than failing admission. A later operator-approved guard closes this for
  constructor and `onAttachedToEngine` exceptions; see the correction below.
- Unchanged: initialisation fencing is not erasure. Queued GMS/Firebase payloads and consent records
  from earlier runs are untouched, and no consent or collection default changed. The accepted
  tradeoff of option B still applies: crashes before admission are reported to nothing.

Evidence held for this change (host only): focused tests
`test/unit/services/storage/native_plugin_admission_test.dart` cover the Dart channel contract
(Android-only, one call per request, refusal and missing-handler both fail closed) and pin the native
and startup wiring: no `super.configureFlutterEngine`, exactly one
`GeneratedPluginRegistrant.registerWith` call site, exactly two bootstrap `plugins.add`
calls and no copied plugin list, the registrant presence check before registration, the per-engine
guard, WebView debugging after admission, the foreground-service options, and the ordering of
`admitNativePlugins()` against every sensitive initialisation in `startDecaidNormalServices`. A debug
`flutter build apk --debug` compiles the Kotlin references (a removed or renamed `jni`/`jni_flutter`
class fails the build rather than the app at runtime), and the packaged APK's dex contains
`com.reaprime/recovery_plugins`, `admitPlugins`, `PLUGIN_REGISTRATION_FAILED` and
`io.flutter.plugins.GeneratedPluginRegistrant`; `aapt2 dump xmltree` shows the packaged manifest still
removes `FirebaseInitProvider` and still sets `android:stopWithTask="true"`.

Missing at the time this change was made: runtime observation. No device was used for that pass. An
authorised offline-emulator cold-start run against debug and profile builds came afterwards and is
recorded in "Android emulator observations after deferral": blocked launches logged no plugin
admission, Analytics measurement or `FirebaseApp` initialization, and the absent launch logged
`Plugins admitted for this engine` before the Firebase work. That run covers the Android
plugin-attach fence only; it is not proof of an absent attempted send, of any queued-payload purge,
of Apple behaviour or of power-loss durability. A debug build is a valid
counterexample check for the native attach path because the Dart side never calls
`Firebase.initializeApp` in debug (`isDebugOrSimulate`), so any `FA:`/`DynamiteModule`/`Phlogger`
line for the app PID could only come from plugin attach. Still required: the equivalent
Apple-platform observation, which no deferral currently makes reachable (see the Apple HOLD above).
The requirement as originally written was an offline emulator cold start with a blocked marker showing
no `FA:`/`DynamiteModule`/`Phlogger` line for the app PID, the visible blocked screen, and no
`MainActivity: Plugins admitted for this engine` line, plus an absent marker showing
`Plugins admitted for this engine` before `firebase_done`, on a profile or release build so the full
Firebase app is exercised. Debug and profile runs of that matrix now exist (see above); no run can
prove the absence of an attempted send, and none of it covers Apple.

### Correction: an effective registration-success postcondition (operator-approved guard)

An independent review found that the deferral above proved only that the registrant was *called*, not
that registration *succeeded*. The pinned generator wraps every plugin in
`try { flutterEngine.getPlugins().add(new Plugin()); } catch (Exception e) { Log.e(…) }`
(`packages/flutter_tools/lib/src/flutter_plugins.dart`,
`_androidPluginRegistryTemplateNewEmbedding`, Flutter 3.47.9), so a plugin whose constructor or
`onAttachedToEngine` throws is logged and skipped while `registerWith` returns normally.
`FlutterEngineConnectionRegistry.add` cannot stand in as the postcondition either: it does
`plugins.put(clazz, plugin)` **before** `plugin.onAttachedToEngine(pluginBinding)`, so `has()`/`get()`
stay `true` for a plugin that failed to attach and a retry of that registrant is skipped.

The operator approved a bounded correction that keeps the generated registrant authoritative:

- `MainActivity` calls `GeneratedPluginRegistrant.registerWith(engine)` directly (no reflective
  helper, no method-existence check), so a missing registrant is a compile error.
- One project-local, non-cacheable Gradle task
  (`android/buildSrc/src/main/java/net/tadel/reaprime/gradle/GuardedPluginRegistration.java`, wired in
  `android/app/build.gradle.kts`) runs before every Kotlin and Java compile task and rewrites only the
  per-plugin `catch (Exception e) { Log.e(…) }` wrappers into the bare `add` statement. `registerWith`
  therefore returns normally only if every generated constructor and `add` completed; the plugin
  list, its order and its classes stay exactly what Flutter generated.
- The guard fails the build on a Flutter version other than 3.47.9, a changed generator template, a
  missing, malformed, partly instrumented or duplicated registrant, and any body statement it does
  not recognise. The plugin blocks are derived from the generated input, never from a checked-in
  inventory, and only the gitignored generated file is edited, never the installed SDK.
- `PluginRegistrationAdmission` latches a failed engine: a retry on that engine returns the channel
  error and never marks admission, because a retry would skip the plugin the registry recorded before
  its attach threw. No throwable is retained, and a fresh engine is the only recovery boundary.
- Task ordering was checked against the real task graph for debug, profile and release: the guard
  precedes `compile*Kotlin` and `compile*JavaWithJavac` in each variant. Flutter regenerates the
  registrant in `verifyThenRunCommand` before Gradle starts and the guard re-instruments it on every
  build; a direct `./gradlew` build with no generated registrant fails closed.

Evidence (host only): 25 buildSrc JUnit tests over the transformation and every rejection path, 6 JVM
latch tests, the Dart wiring tests, the `GeneratedPluginRegistrant.class` produced by a real
`:app:compileDebugJavaWithJavac` (no exception handler and no `Log.e` call left in `registerWith`,
against 28 handlers before the guard), the real task graph, and end-to-end `flutter build apk --debug`
runs with 28 and with 29 plugins. The 29-plugin runs used a test-only local `path` plugin whose
constructor, and separately whose `onAttachedToEngine`, throws `IllegalStateException`; they prove the
block count is derived from generated input and that the fixture compiles. Those fixtures live outside
the repository build under `.lane/evidence/p2-1/fixtures/` and are applied and reverted by scripts
there.

Subsequent bounded Android API 35 debug runtime observations used a newly owned emulator with
inspected first-chain IPv4/IPv6 output drops, loopback and an exact host ADB exception only, and
non-loopback interfaces down. Enforcement was checked before and after every repeated launch.
Both fixture APKs reached the actual Dart `PLUGIN_REGISTRATION_FAILED` failure shell; the attach
fixture observed registry membership as true before throwing. The VM service invoked the existing
production Dart admission function, whose actual platform-channel retry returned the engine's
latched failure without entering either fixture a second time. A control APK reached Welcome.
An uncertain-journal launch with unavailable recovery diagnostics rendered recovery without entering
the installed fault plugin or changing nonempty normal log/WebView-log fingerprints.

Preliminary runs used asynchronous airplane-mode toggles without inspected enforcement at launch;
they are native-behaviour observations only, not no-egress evidence. No absence of cloud mutation can
be established for that interval. Repeated filtered observations supersede their isolation claim,
not that uncertainty. No credentials or account interactions were used. Owned AVDs and the newly
installed rootable image were removed; original AVDs were preserved.

Failure is not rollback: plugins earlier in generated order can initialise native SDKs before a later
constructor or attach throws. These runs observed native measurement initialisation during partial
registration. Ordinary Dart services stay blocked, but native side effects are not undone and no
absence-of-attempts, purge, release-mode or physical-device claim follows.

Boundary of the guard, exactly: it makes a constructor, `onAttachedToEngine`, class-initialisation or
other escaping throwable fail admission. It cannot detect a plugin that catches its own error and
returns normally, and it changes no other platform and no other lifecycle behaviour.

## Adopted change: deferred plugin registration on iOS and macOS

The operator approved a bounded Apple extension of the same admission channel after reviewing
`.lane/apple-deferral-proposal.md`. The reaching path is the one the native-boundary finding above
describes: `firebase_core` 4.10.0's `registerWithRegistrar` → `sharedInstance` → `FIROptions
defaultOptions` → `FIRApp configureWithOptions`, and both Apple targets bundle
`GoogleService-Info.plist` in `Resources`. The engine-attached generated registrant is what calls it,
so deferring that registrant is the only change that moves configuration behind the gate without a
native marker parser, a copied plugin list, a second lifecycle owner or a plist/package change.

What the change consists of:

| Piece | iOS | macOS |
| --- | --- | --- |
| Deferred call | `ios/Runner/AppDelegate.swift`: `didInitializeImplicitFlutterEngine` no longer calls `GeneratedPluginRegistrant.register(with:)` | `macos/Runner/MainFlutterWindow.swift`: `awakeFromNib` no longer calls `RegisterGeneratedPlugins(registry:)` |
| Early bootstrap | the two app-owned channels only: `com.reaprime/security_scoped` and `com.reaprime/recovery_identity`, plus the admission channel | the same identity channel, `com.reaprime/skin_camera`, the `net.tadel.reaprime/macos_updater` channel and the admission channel |
| Admission channel | `com.reaprime/recovery_plugins`, method `admitPlugins`, installed on the engine messenger during the implicit-engine callback | the same name and method, installed on the engine messenger during the nib load |
| Late registration | one call site, inside `PluginAdmission.admitPlugins` | one call site, inside `PluginAdmission.admitPlugins` |
| Idempotency | `NSLock` around a `Set<ObjectIdentifier>` of admitted engines; the engine is inserted only after a successful call | same mechanism, keyed on the `FlutterEngine` |
| Fail closed | a missing handler is a `MissingPluginException`, which Dart converts into `NativePluginAdmissionException` and a visible failure screen | same |

Dart side: `platformDefersGeneratedPluginRegistration` now covers `android`, `ios` and `macos`, so
`await admitNativePlugins()` opens the same channel on all three and still fails closed on a missing
or refused handler. `lib/main.dart` no longer touches `window_manager` or `shared_preferences` before
the gate: the desktop window sizing and the persisted simulated-WebView restore moved into
`startDecaidNormalServices` immediately after admission. That is a plugin-dependent block
(`WindowManagerPlugin`, `SharedPreferencesPlugin`), it used to run before the recovery gate, and it
is the reason a blocked Apple launch used to call plugin channels at all. The blocked presentation is
unaffected because the native window is created by the nib/window load with its default frame and the
recovery view renders inside it; the window is only resized or constrained once normal startup is
admitted. CLI parsing, `--print-storage-paths`, `--force`, `--bypass`, replay and `--noaccount`
handling stay where they were, ahead of and outside admission.

`AppDirectories` remains the sole path resolver and no native path channel was added. The correction
in `.lane/apple-deferral-proposal.md` is the reason: `pubspec.lock` pins
`path_provider_foundation` 2.6.0, whose `lib/path_provider_foundation.dart` exports
`src/path_provider_foundation_real.dart`; that file imports `dart:ffi` and `package:objective_c` and
reaches Foundation directly, and neither generated registrant contains a `PathProviderPlugin`. A
focused test pins both registrants against a future native path provider appearing, because that
would break the gate's own directory resolution.

Apple audit results, from the pinned sources on this host:

- iOS engine ordering: the Runner is scene-based (`ios/Runner/Info.plist` declares
  `UISceneDelegateClassName = FlutterSceneDelegate` and `UISceneStoryboardFile`, alongside
  `UIMainStoryboardFile = Main`). The storyboard `FlutterViewController` runs `awakeFromNib` →
  `sharedSetupWithProject` → `createShell` (`FlutterViewController.mm:256-262`, `:270-307`), then calls
  `performImplicitEngineCallback` (`:313`), which is what invokes `didInitializeImplicitFlutterEngine`.
  The Dart entrypoint runs later, from `_engineNeedsLaunch` (`:336`, launched from `viewDidAppear`).
  The channel handler therefore exists before `main()`, and the registrant does not run then.
- iOS scene path: `FlutterSceneDelegate.mm` and `FlutterSceneLifeCycle.mm` contain no reference to a
  plugin registrant or to the implicit-engine callback, so a scene connection cannot register the
  generated set behind the gate.
- macOS engine ordering: `MainFlutterWindow.awakeFromNib` runs during the nib load and creates the
  `FlutterViewController`; the engine is started later in `FlutterViewController.viewWillAppear`
  (`FlutterViewController.mm:409-412`, `:530-533`). The handler is installed before Dart runs.
- Deprecated iOS registrant path: `FlutterViewController.mm:316-321` also registers
  `appDelegate.pluginRegistrant` when the delegate responds to that selector. `FlutterAppDelegate`
  answers it with `_weakRegistrant`/`_strongRegistrant`, which are nil unless the app sets that
  property (`FlutterAppDelegate.mm:232-250`), and this app never sets it. The Apple fence therefore
  depends on that property staying unset, which the wiring tests make visible rather than silent.
- Background/secondary engines: `flutter_foreground_task` (pinned fork `fba972b2b9e085cc`) creates
  its own `FlutterEngine` on iOS (`ios/.../service/ForegroundTask.swift:65`) but only after
  `SwiftFlutterForegroundTaskPlugin.registerPlugins` is non-nil
  (`SwiftFlutterForegroundTaskPlugin.swift:7`); the app never calls
  `setPluginRegistrantCallback`, so the plugin returns before creating an engine. No other pinned
  plugin creates an engine or runs a generated registrant on either Apple platform.
- macOS updater: `MacOSUpdater.register` only installs a method channel and constructs
  `SPUStandardUpdaterController(startingUpdater: false)`; Sparkle starts on the Dart `configure`
  call, which only admitted normal startup reaches. Registering that channel early adds no
  initialization and no egress.

What this fences, exactly:

- Fenced: the engine of a fresh process. With any blocked or uncertain marker, neither Apple
  platform calls its generated registrant, so `firebase_core`'s `sharedInstance` never configures
  the default app and no other plugin attaches.
- Not fenced, same process: after an admitted run, a Dart soft restart re-runs `main()` while the
  engine keeps its registry; no supported API unregisters an attached plugin. The guarantee is a
  fresh process launch, and initialization fencing is not erasure.
- Unchanged: both `GoogleService-Info.plist` files stay packaged, every consent/collection default
  stays as it was, and no payload, credential or store is purged. The accepted tradeoff matches
  Android: the earliest pre-admission crashes on Apple are no longer captured by Crashlytics.
- Not proven: nothing was executed. No Apple app was launched for this change, so the ordering,
  the blocked presentation, the deferred registration and the absence of Apple-side SDK
  initialization at runtime are source and build claims only. Two Apple risks remain open and need
  runtime observation: a plugin registered after the implicit-engine callback may miss the
  app-lifecycle events `FlutterPluginAppLifeCycleDelegate` forwards only to already-registered
  plugins, and the fixture/plugin attach order of the deferred set is unobserved.

Evidence for this change, host only:

- Red then green: `test/unit/services/storage/native_plugin_admission_test.dart` grew
  `platform deferral`, `Apple deferred registration wiring` and three `normal startup admission
  wiring` cases. Before the implementation it failed on the unfixed sources; the same file passes
  afterwards. The Apple cases assert the engine callbacks do not reach a registrant, one call site
  per platform sits inside `admitPlugins`, the engine guard precedes registration and the mark
  follows it, the app-owned channels stay in the early callbacks, neither runner copies a plugin
  name, no other Apple runner source registers plugins, and both registrants still carry
  `FLTFirebaseCorePlugin` while still containing no path provider.
- Builds: `flutter build macos --debug` produced `build/macos/Build/Products/Debug/Decaid.app`
  (`Decaid.debug.dylib` contains `com.reaprime/recovery_plugins`, `admitPlugins`, the identity and
  skin-camera channels and `GeneratedPluginRegistrant`), and `flutter build ios --simulator --debug`
  produced `build/ios/iphonesimulator/Runner.app` (`Runner.debug.dylib` contains the same admission
  strings). Both are compile/typecheck evidence; a successful build is not runtime proof.
- Unchanged tracked files: no tracked plist, `Podfile.lock`, generated registrant or xcconfig changed
  across either build.

Still required before destructive reset can be enabled on Apple: a uniquely owned, no-egress Apple
runtime (isolated app data, verified process-specific network denial, real container untouched),
cold starts with a blocked marker showing the recovery presentation and no Firebase/analytics
initialization for the app process, an absent-marker launch showing admission before the first SDK
configures, and a second-engine/background-launch check. None of it may be simulated by a Dart test.
