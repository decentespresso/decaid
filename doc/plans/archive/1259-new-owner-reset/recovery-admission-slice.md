# New-owner reset: recovery durability and startup admission (slice 2)

Second bounded slice of #1259. It turns the isolated journal from
[journal-slice.md](journal-slice.md) into startup infrastructure: an owned on-disk location, one
authoritative owner per process, conservative persistence with explicit ambiguous outcomes, and a
fail-closed admission decision that runs before normal Decaid services. It still performs **no**
destructive work and exposes **no** reset entry point. The retention policy, store inventory and
native capability limits in [inventory.md](inventory.md) and [capabilities.md](capabilities.md)
remain prerequisites to enabling destructive reset and are not satisfied by this slice.

## What this slice adds

| Piece | File |
| --- | --- |
| Owned location | `lib/src/services/storage/app_directories.dart` |
| Marker schema, file store, journal transitions, fault seam | `lib/src/services/storage/new_owner_reset_journal.dart` |
| Process-session identity (kernel facts + native channel) | `lib/src/services/storage/process_session_identity.dart` |
| Admission decision | `lib/src/services/storage/new_owner_recovery_admission.dart` |
| Single owner: advisory lock, exclusive claim, startup seam | `lib/src/services/storage/new_owner_recovery_owner.dart` |
| Blocked/terminal presentation | `lib/src/new_owner_recovery_view.dart` |
| Normal-startup composition + gate call | `lib/main.dart` |
| Native plugin admission contract | `lib/src/services/storage/native_plugin_admission.dart` |
| Deferred generated plugin registration | `android/app/src/main/kotlin/net/tadel/reaprime/MainActivity.kt` |
| Native process identity channel (iOS, macOS) | `ios/Runner/AppDelegate.swift`, `macos/Runner/AppDelegate.swift`, `macos/Runner/MainFlutterWindow.swift` |

## Location and namespace boundary

`AppDirectories.newOwnerRecovery` resolves `<support>/new-owner-recovery`, holding
`new-owner-reset-journal.json`, `owner.lock` and one `owner-<encoded identity>.claim` per owning
process identity. `<support>` is Application Support on desktop and the app Documents directory on
mobile, as `doc/AI_STORAGE_NOTES.md` requires; the app has no other resolver.

- The directory is its own namespace, so a future app-data cleanup can exclude it instead of
  treating it as user data. It holds no credential, consent, queue, shot or profile payload.
- It is **not** preserved by an OS app-data clear, an app uninstall/reinstall, or a platform backup
  restore that drops app-private files. "Survives app-data cleanup" therefore means "our cleanup
  code must not delete it"; it does not mean the OS preserves it.
- On Android `<support>` is app-private storage, so the marker is not user-visible. On iOS the
  Documents directory can be user-visible through Files when file sharing is enabled; the marker
  carries only machine/scale IDs, a skin ID/package ID and an opaque session ID, and a tampered
  marker fails closed as unreadable.
- A launch with no marker reads one path and creates nothing: no directory, lock file or claim.

## Authoritative ownership and the concurrency boundary

`NewOwnerRecoveryStartup.open()` is the only place that constructs a journal. `main()` calls it once,
before Firebase, telemetry, the multicast lock, Hive, Drift, the web server, the plugin loader,
account services and skin serving. Ownership is established **before** the authoritative marker read
and before any admission decision:

1. The marker is read once without ownership. If it is absent, the admission is `normalStartup` and
   no file is created.
2. A process-session identity must resolve (see below). Without one, the admission is `uncertain`:
   no instance can prove it owns recovery state.
3. `owner-<encoded identity>.claim` is created with an exclusive create, so exactly one engine per
   process identity wins; the losers are `uncertain` ("another engine in this Decaid process"). The
   claim is never deleted by another identity's owner. The claim is deliberately taken **before** the
   lock: a refused engine must never open the lock file, because closing any descriptor for it drops
   every lock this process holds on that inode, which would hand the lock to another process.
4. `owner.lock` is opened and `FileLock.exclusive` is taken for the life of the process. Failure is
   `uncertain` (another Decaid process), never absent; a failure releases only the claim this engine
   has just created.
5. Only now is the marker re-read and the admission decided. If recovery state disappeared between
   steps 1 and 5, the admission is `uncertain`.

Two independent boundaries are needed because they exclude different things:

- **Cross-process:** the advisory lock. POSIX record locks are per process, so a second Decaid
  process cannot hold it; a real second process holding the same lock (`python3` + `fcntl.lockf`)
  makes admission `uncertain` in the tests.
- **Same process, second engine:** the claim. POSIX record locks do not conflict inside one process,
  so the lock cannot exclude another Flutter engine; the exclusive create is atomic at the
  filesystem level and does conflict. Two engines resolve the same process identity, so the first
  claims and the second fails closed. Because the claim comes first, the refused engine never opens
  or closes the lock descriptor, so the winner's per-process lock survives the rejection.

A claim left by a crashed process is not a lock: its identity differs from the new process's
identity, the new process holds the advisory lock (which proves the old process is gone), and no
owner ever deletes another owner's claim. Claims are therefore harmless garbage rather than a
reusable token, and no owner can adopt one: only an exclusive create can hand out ownership.

`NewOwnerRecoveryClaim` records a per-instance token in the claim it created. `release()` is
idempotent and token-bound: it removes the claim only on its first call and only while the file still
carries that token, so a stale release can never delete the claim of a successor that already owns
the same process identity.

`NewOwnerRecoveryStartup.release()` revokes the journal lease first, releases the lock descriptor
second and removes the claim third, and every step is a no-op on repeat. The journal handle published
to callers is bound to that lease ([NewOwnerResetJournalLease], required by the
`NewOwnerResetJournal` constructor), and every mutator — `beginReset`, `completeStage` including its
no-op duplicate branch, `acknowledgeHandoff` and `consumeHandoff` — refuses to run once the lease is
revoked, throwing `NewOwnerResetJournalLeaseRevokedException` before any read or write of the marker.
Revocation is monotonic and lives outside the handle, so `load()` can refresh the record from disk but
can never reissue authority: an owner that has released ownership cannot advance a successor's record
even when that successor owns the unchanged marker on disk. Lock and claim are private inside
`NewOwnerRecoveryStartup`, so the only way to drop ownership is `release()`; a caller cannot release
the claim directly and leave a live handle with mutation authority.

The lock is unlocked and its descriptor closed *before* the claim can disappear, so no second engine
can claim this identity and take the process lock inside the release and then have that lock dropped
by the outgoing owner's `unlockSync`/`closeSync`. POSIX record locks are per process, so the reverse
order let a same-process successor acquire the lock between the two steps and lose it to the
predecessor's close, leaving two processes believing they owned the directory. The lease revocation
comes before both, so the revoked handle is inert for the whole release window. The same order applies
to the internal releases in `open()` (the failed-lock paths and the "marker disappeared while
ownership was established" path).

Reproduction is deterministic rather than timing-based. `NewOwnerRecoveryStartup.releaseInterleaving`
is a `@visibleForTesting` hook that runs exactly once between the two release steps; the test's hook
mirrors what a second engine does in `open()` (try the claim, and only if that succeeds try the lock)
and then probes the file from a genuinely separate `python3` process with `fcntl.lockf(..., LOCK_NB)`.
With the old order the test observed the claim available, a same-process successor holding the lock,
and afterwards a competing process also holding it; with the corrected order the claim is still
present during the window, the successor is refused at the claim, and the completed release leaves no
lock behind. The hook is a test seam only: production never sets it, and the release path is the same
code either way.

Stale in-memory instances remain a third, weaker case: every mutation re-reads the marker and refuses
to continue when the on-disk record no longer matches what the instance loaded. That check is
defence in depth for a stale instance, not the source of authority, which is the lease plus the claim
above.

## Process-session identity

The acknowledging process must stay terminal and a later process must be distinguishable, so the
identity must outlive widget/AppRoot reconstruction, survive an engine/isolate restart inside one
process, and change across launches.

| Platform | Source | Isolate-independent | Destructive reset |
| --- | --- | --- | --- |
| Android, Linux | `/proc/sys/kernel/random/boot_id`, `/proc/self/stat` field 22 (start ticks), PID | yes: all are process-level facts | disabled |
| iOS, macOS | native `com.reaprime/recovery_identity` channel returning the kernel process start time and PID (`sysctl` `KERN_PROC_PID`) | yes: kernel fact for the process, so every engine resolves the same value | disabled |
| Windows | none | n/a | disabled |

Rules the implementation enforces:

- There is **no** PID-plus-isolate-clock fallback. If neither source resolves, `resolve()` returns
  null; a pending marker then fails closed and an absent marker still starts normally, because no
  recovery state exists to own.
- The identity is resolved once per isolate and cached, so AppRoot reconstruction and widget rebuilds
  reuse it. A hot restart re-derives the same process-level value from the kernel.
- A source that throws (`MissingPluginException`, `PlatformException`) is null, never a guess.
- Windows is unsupported for pending recovery: `windows/runner` is out of this slice, so a pending
  marker there is `uncertain` rather than admitted.
- A background isolate on Darwin cannot call the channel without an isolate token, so it resolves
  null and fails closed. The supported boundary is the engine that runs `main()`; that is enforced by
  failing closed rather than by trusting a second engine's good behaviour.
- Identity misidentification can only ever *block*: admission depends on identity solely for the
  `handoffArmed` cases, and `handoffEligible` is itself a blocked state. No identity error can admit
  normal startup or enable destructive reset.

Kernel-level evidence for the Darwin mechanism: the `sysctl`-based function was compiled with
`xcrun --sdk macosx swiftc` and run twice, returning one stable value per process
(`darwin:<pid>:<sec>.<usec>`) and a different value per launch; the same source also typechecks
against the iOS simulator SDK and the real `Flutter.xcframework`, and the whole macOS app builds with
`flutter build macos --debug`. The channel itself was not exercised on a device or simulator, and
iOS sandbox behaviour of `sysctl(KERN_PROC_PID)` for the caller's own PID is a device-verification
item.

The kernel branch is exercised across real processes without an engine: the focused test launches
`test/unit/services/storage/process_identity_probe.dart` as a plain-Dart child that resolves the same
production function (`kernelProcessSessionIdentity` in `process_identity_source.dart`), asserts both
launches are non-empty, differ from the parent's identity and differ from each other, and reports the
absence of a kernel source instead of skipping the launch on a host that has none. Re-run on a Linux
`aarch64` host with a checksum-verified Dart platform SDK, one long-lived parent and two child
launches produced three distinct `proc:<boot id>:<pid>:<ticks>` values sharing one boot id, and the
child values differed from the parent; the earlier expectation that a child resolves the parent's
identity was wrong and is corrected there.

## Startup admission

`decideNewOwnerRecoveryAdmission` is a pure function of the read result and the process-session
identity:

| Marker | Admission | Normal services |
| --- | --- | --- |
| absent | `normalStartup` | run exactly as before |
| `resetting` | `resetInProgress` | blocked; recovery presentation only |
| `ready` | `readyForNewOwner` | blocked; terminal until an explicit handoff |
| `handoffArmed`, armed by this process | `handoffArmedThisProcess` | blocked; terminal |
| `handoffArmed`, armed by another process | `handoffEligible` | blocked; eligibility only, never automatic admission or consumption |
| unreadable / unparsable / not a regular file | `uncertain` | blocked; visible recovery error |
| any marker, no process identity | `uncertain` | blocked; visible recovery error |
| any marker, lock held by another process | `uncertain` | blocked; visible recovery error |
| any marker, claim held by another engine | `uncertain` | blocked; visible recovery error |

`handoffEligible` is deliberately *not* admission. The marker records that a reset finished; it does
not prove any store was erased or restored, and an injected fixture proves nothing about app data.
Wiring a guarded customer startup needs the deletion/restoration/verification owners, which are
explicit non-goals here.

`runNewOwnerRecoveryStartup` is the production composition seam `main()` uses: it calls
`startNormalServices` only when the admission permits normal startup and calls `presentBlocked`
otherwise. `main()` passes its real normal-startup continuation
(`startDecaidNormalServices`), so the branch that starts Firebase, telemetry, the multicast lock,
Hive, the database, plugins, the web server, accounts and skins is chosen by production code rather
than by test scaffolding. Tests assert with counters that `startNormalServices` runs zero times for
every blocked or uncertain admission, and a structural test checks that `main()` reaches no sensitive
initialisation outside `startDecaidNormalServices`.

The blocked presentation (`NewOwnerRecoveryApp`) starts no account, upload, plugin, skin, API or
database service, has no reset action, and tells the operator not to clear app data because that
removes the marker. Normal startup, onboarding replay (`--force-onboarding`), `--bypass-onboarding`,
`--print-storage-paths`, `--no-account` and every other CLI path are untouched when the marker is
absent.

## Persistence and ambiguous outcomes

Writes stage the bytes in `<marker>.tmp`, write, flush, close, then rename over the marker. A
filesystem error is never trusted as "the previous state survived":

| Outcome | Detection | Journal behaviour |
| --- | --- | --- |
| replaced, then error | re-read returns the intended record byte-for-byte | treated as committed; record published |
| rejected before commit | re-read returns the previous record, or absent when absent was the previous state | `NewOwnerResetJournalWriteException`; in-memory state unchanged; staged file removed |
| unknown | re-read is unreadable, or the presence lookup itself fails | `NewOwnerResetJournalIndeterminateWriteException`; instance refuses all mutation until `load()`; admission treats the marker as uncertain |

Deletion is classified the same way: a delete that reports an error is committed only when the
marker is verifiably gone; a marker that is still present is a retryable failure; a marker that
became unreadable is indeterminate. `NewOwnerResetJournalIndeterminateWriteException` extends the
write exception, so existing callers keep catching a write failure while new callers can
distinguish "unknown" from "rejected".

Reads reject invalid UTF-8, invalid JSON, unknown schema versions, unknown states/stages, unexpected
fields at any level (including nested skin fields), missing fields, and inconsistent state/stage
combinations. None of those cases is ever reported as absent, and none is overwritten.

A leftover `<marker>.tmp` with no canonical marker is not an armed reset: the marker is written before
any destructive work, so a crash before the first committed replace cannot have started one. This is
the only case where an abandoned staging file is treated as harmless, and it depends on the
"marker first" ordering the reset adapters must keep.

## Durability capabilities versus power-loss guarantees

| Capability | Established here | Not established |
| --- | --- | --- |
| Creation, replacement and deletion survive normal process exit | yes, modelled injection tests plus a host `SIGKILL` probe run by the previous candidate | other filesystems/platforms |
| Marker survives process termination mid-write | yes: staged write, flush, close, then rename; a failed replace is classified committed/rejected/unknown | power loss between flush and rename, or after rename before directory metadata reaches the medium |
| Directory metadata durability (fsync of the containing directory) | **no** | Dart exposes no directory fsync, and this slice adds no native durability call |
| Power-loss durability on Android, iOS, macOS, Windows | **no** | none of these were observed; only the host filesystem (APFS) was exercised |
| Unsupported-platform recovery | pending marker on a platform without a process identity (Windows) fails closed | nothing is admitted |

Because of the last two rows, destructive reset stays disabled on **every** platform: a lost marker
after destructive work would strand the installation in a mixed-owner state, which the admission
design forbids. Process-termination evidence is never presented as power-loss evidence.

## Native initialization boundary

Source-level findings for the pinned packages are recorded in
[capabilities.md](capabilities.md#native-pollution-before-dart-on-android). The key consequence:
on Android the Firebase default app is created by
`com.google.firebase.provider.FirebaseInitProvider` at content-provider creation, which happens
before Dart `main()` and therefore before this admission gate; on iOS and macOS the same effect comes
from the generated registrant configuring the default app at plugin attach from the bundled plist. A
Dart-only barrier cannot fence native SDK initialisation or any queued crash/analytics payload on
either platform, and the app's current `TelemetryService.initialize()` collection toggles run after
that point.

This slice now changes one native startup input, under explicit operator approval: the Android app
manifest removes `com.google.firebase.provider.FirebaseInitProvider` with `tools:node="remove"`, so
the Firebase default app is no longer created during content-provider creation, i.e. before Dart
`main()` and before this admission gate. The explicit `Firebase.initializeApp(options: ...)` stays
inside `startDecaidNormalServices`, which only a `normalStartup` admission reaches. Verified: the
merged manifest produced by `:app:processDebugMainManifest` no longer declares the provider (the
diff against the pre-change merged manifest is exactly those six lines), `:app:assembleDebug` still
packages, and the `production wiring` tests keep every sensitive initialisation behind the gate.

The change is an initialisation-fencing change only. A payload queued by an earlier process, and any
consent/telemetry record, is untouched, and the earliest pre-admission crashes are no longer reported
to Crashlytics. No runtime observation exists for that change in isolation: it was made without a
device, and the user-visible provider list and Firebase state were not read from a running process at
that point. A later authorised offline-emulator run (debug and profile builds, all five synthetic
marker states) did read the app-process logs, and it is recorded in
[capabilities.md](capabilities.md#android-emulator-observations-after-deferral): the blocked launches
logged no plugin admission, Analytics measurement or `FirebaseApp` initialisation, and the absent
launch logged plugin admission followed by measurement, the default `FirebaseApp` and Crashlytics.
That is bounded cold-start log evidence for Android only. It is not proof of an absent attempted
transmission, not purging evidence, and it says nothing about Apple. Details, the accepted tradeoff, the
remaining auto-init surfaces and the required device verification are in
[capabilities.md](capabilities.md#adopted-change-option-b), together with the mechanism analysis
that stays a prerequisite: a Dart-only barrier cannot fence an SDK that a future change lets initialise
earlier again, and neither manifest scans nor Dart tests are runtime evidence.

The identity channel this slice adds on iOS and macOS is a read-only kernel-sourced value, which
neither initialises a vendor SDK nor transmits anything. It is not a deferral: on both Apple
platforms the default `FIRApp` is configured by the generated registrant at plugin attach, before
Dart `main()` reaches this gate, because `firebase_core` 4.10.0's `sharedInstance` runs
`FIRApp configureWithOptions` from the bundled `GoogleService-Info.plist`. That is a source finding
(a correction of an earlier claim in this archive that Apple configured only from the Dart channel
call), not a runtime, transmission or purge finding. Under a second explicit approval the same
channel and authority now defer both Apple registrants as well, together with the macOS
plugin-dependent window/preference setup that used to run before the gate; the mechanism, the Apple
engine-ordering audit and its limits are in
[capabilities.md](capabilities.md#adopted-change-deferred-plugin-registration-on-ios-and-macos).
Apple therefore has a source-and-build deferral and still has no runtime evidence, so destructive
reset stays disabled there.

That option-B change is not sufficient on its own. The first authorised offline emulator run, which
the deferred build described next supersedes, showed `FA: App measurement initialized` in the app
process 183 ms before the
admission gate, reached by plugin engine-attachment rather than by the provider. Under the same
explicit approval, and after that runtime counterexample, this slice also defers the generated plugin
registrant: `MainActivity.configureFlutterEngine` overrides without `super`, attaches only the `jni`
and `jni_flutter` FFI bridge that `path_provider` needs to resolve the marker directory, and answers a
`com.reaprime/recovery_plugins`/`admitPlugins` channel with
`GeneratedPluginRegister.registerGeneratedPlugins`. `startDecaidNormalServices` awaits that call as
its first statement and renders a visible failure screen instead of starting if it is refused. The
fence covers the activity engine of a fresh process only: a Dart hot restart keeps the registry, and
the `flutter_foreground_task` engine is a separate engine that this change does not fence, whose
current configuration makes it unreachable before admission. Mechanism, exact fence boundary,
receiver gating and the remaining runtime requirement are in
[capabilities.md](capabilities.md#adopted-change-deferred-plugin-registration-operator-approved-r1).

The same channel and authority also cover iOS and macOS: `didInitializeImplicitFlutterEngine` no
longer calls `GeneratedPluginRegistrant.register(with:)` and `MainFlutterWindow.awakeFromNib` no
longer calls `RegisterGeneratedPlugins(registry:)`; each installs the admission channel and the
app-owned recovery channels, and registers the generated set once per engine when Dart admits normal
startup. `lib/main.dart` no longer initialises `window_manager` or reads the simulated-WebView
preference before the gate: that plugin-dependent desktop block moved into
`startDecaidNormalServices` right after admission, so a blocked Apple launch opens no plugin channel
and keeps the native default window that presents the recovery view. Mechanism, the Apple
engine-ordering audit, the background-engine findings and the remaining runtime requirement are in
[capabilities.md](capabilities.md#adopted-change-deferred-plugin-registration-on-ios-and-macos).

## Verification

Focused suite (runs on the host filesystem; a real second process is used where the claim needs one):

```sh
flutter test test/unit/services/storage/
```

| Contract | Test group |
| --- | --- |
| invalid UTF-8 marker content | `marker encoding` |
| missing/unexpected nested skin fields | `retained skin shape` |
| mutation by the instance that loaded unreadable state | `unreadable owner` |
| byte-write, flush, close and rename fault injection | `staged write faults` |
| ambiguous commit after a failed replace/delete | `ambiguous persistence outcomes` |
| stale instances attempting conflicting operations | `competing journal owners` |
| admission for every marker state, no normal service on blocked states | `admission states`, `production wiring` |
| pending recovery without a process identity fails closed | `process identity requirement` |
| cross-process lock, same-process second engine, refused contender keeping the lock, release interleaving against a real competing process, repeated/stale release, earlier-process claim | `ownership boundary` |
| released owner retaining its handle, stale mutators after a successor owns the unchanged marker, reload never reissuing authority, no-op duplicate stage, revocation before the release window | `revocable owner lease` |
| marker/decision mapping | `decision` |
| Android manifest removes the automatic Firebase initialiser, and no sensitive initialisation precedes the gate in `main.dart` | `production wiring` |
| Android defers the generated registrant: no `super.configureFlutterEngine`, one registrant call site, two FFI bootstrap plugins and no copied plugin list, registrant presence check, per-engine guard, WebView debugging after admission, no receiver-triggered second engine under the current foreground-service options, `admitNativePlugins()` before every sensitive initialisation, refused admission renders a failure screen and returns | `native_plugin_admission_test.dart` (`Android deferred registration wiring`, `normal startup admission wiring`) |
| Android admission channel: Android-only, one call per request, refusal and missing handler both fail closed with `NativePluginAdmissionException` | `native_plugin_admission_test.dart` (`plugin admission call`) |
| Admission channel scope: Android, iOS and macOS defer registration; Linux, Windows and Fuchsia never open the channel; one call per request on every deferring platform | `native_plugin_admission_test.dart` (`platform deferral`) |
| Apple deferral: neither engine callback reaches a registrant, one call site per platform inside `admitPlugins`, engine guard before registration and mark after it, app-owned channels still registered before admission, no copied plugin list, no second registration site, both generated registrants still carry Firebase and still contain no path provider | `native_plugin_admission_test.dart` (`Apple deferred registration wiring`) |
| Plugin-dependent desktop window/preference setup and simulated-WebView restore run after admission and no longer in `main()`, while CLI parsing and path printing stay before the gate | `native_plugin_admission_test.dart` (`normal startup admission wiring`) |
| identity from kernel facts, native channel contract, fail-closed sources | `process-level identity`, `native identity channel`, `host identity` |
| blocked/terminal/error presentation, no reset action | `new_owner_recovery_view_test.dart` |

Evidence classes: journal, injection and admission tests are host-filesystem and modelled filesystem
platforms; the lock tests use a real second process (`python3` holding `fcntl` record locks); the
identity tests launch a real plain-Dart child process (and were re-run on a Linux `aarch64` host); the
Darwin identity mechanism was executed as a standalone native program; the Android merged manifest
and debug APK come from real Gradle tasks on this host and are declaration/build evidence only; and
the Android blocked/normal startup presentation is bounded cold-start evidence from an authorised
offline emulator run with synthetic markers. No test proves power-loss durability,
Android/iOS/Windows filesystem semantics, Apple native SDK ordering at runtime, the Dart-to-native
identity channel end to end, on-device SDK transmission behaviour, or customer onboarding.

The deferred-registration wiring tests are source assertions over the Kotlin activity, the manifest,
the foreground-service options, the two Apple runner sources and `main.dart`; they model no native
execution. Their guarantees come from three other places: the Kotlin compile (a removed or renamed
`jni`/`jni_flutter` class fails `:app:assembleDebug` instead of failing at runtime), the packaged
APK's dex (it contains `com.reaprime/recovery_plugins`, `admitPlugins`,
`PLUGIN_REGISTRATION_FAILED` and `io.flutter.plugins.GeneratedPluginRegistrant`), and the runtime
observation still outstanding. On Apple the comparable compile evidence is the Swift build itself:
both runner sources reference `GeneratedPluginRegistrant`/`RegisterGeneratedPlugins` as direct
symbols, so a missing generated registrant fails the link instead of reporting success at runtime;
`flutter build macos --debug` and `flutter build ios --simulator --debug` both succeed on this host,
and the built `Decaid.debug.dylib`/`Runner.debug.dylib` contain `com.reaprime/recovery_plugins`,
`admitPlugins`, the recovery identity channel and `GeneratedPluginRegistrant`. None of that is
runtime evidence for the Apple fence.

## Remaining prerequisites before destructive reset is enabled

1. Complete store-inventory cleanup owners (database, prefs, consent, credentials, plugins, skins,
   logs, browser stores) with readback verification ([inventory.md](inventory.md)).
2. Device evidence for the Android native boundary
   ([option B](capabilities.md#adopted-change-option-b) and
   [deferred registration](capabilities.md#adopted-change-deferred-plugin-registration-operator-approved-r1)):
   a cold start with a blocked marker must show the blocked screen and no app-PID `FA:`,
   `DynamiteModule` or `Phlogger` line, and an absent marker must still initialise the default app
   once after plugins are admitted; queued-payload and consent retention still need a retention
   decision, because fencing initialisation is not erasure. The second engine
   (`flutter_foreground_task`) and its receiver gating are source facts, not runtime observations, and
   must be re-audited if that fork, its options or the foreground-service manifest entry change.
   On-device confirmation of the process-identity channel on iOS, macOS and Android is still
   outstanding too.
3. Directory-metadata durability (or an accepted "power loss is unrecoverable" policy) and
   platform-specific rename/replace evidence.
4. Apple runtime evidence for the Apple deferral: a uniquely owned, no-egress macOS/iOS runtime with
   isolated app data, a blocked cold start showing the recovery presentation and no app-process
   Firebase/analytics initialization, an absent-marker launch showing admission before the first SDK
   configuration, and a background/secondary-engine check. The deferred registration and the moved
   macOS window/preference setup are source-and-build claims only; see
   [capabilities.md](capabilities.md#adopted-change-deferred-plugin-registration-on-ios-and-macos).
5. Handoff consumption wired to a guarded customer startup that re-verifies erased stores instead of
   trusting the marker.
6. Physical-device end-to-end evidence and the destructive confirmation UI from the parent issue.
