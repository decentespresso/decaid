# App startup ownership (#1178)

## Scope and dependencies

This is an extraction, not onboarding v2 UI. Keep shot-upload persisted JSON reads in main(), prepareShotUploadStartup(), pending consent and PluginLoaderService.applyPendingSettings unchanged. #1141 and #1146 were inspected on GitHub on 2026-11-17: both OPEN; they own scan presentation and broad styling respectively. Do not modify ScanFlowView, scan policy, copy or shared scaffolding.

Current dependency map:

1. main() constructs settings, discovery services and DeviceController, then ConnectionManager (including adapter/USB attach recovery subscriptions). It restores account/consent state and reads persisted shot-upload JSON before PluginLoaderService initialization. CLI force/bypass flags alter one-time settings, not permission safety; --direct alters only scan picker policy. Simulation is an existing discovery service configuration.
2. AppRoot holds service instances while its keyed MyApp subtree can restart. MyApp installs applyPendingSettings before any plugin startup. Welcome/login/shot-upload remain ahead of permissions.
3. Permissions shouldShow queries OS grants without prompting. The permissions view requests BLE/location, notifications and battery exemption. DeviceController.initialize must not run before this stage resolves. Desktop permission gating is currently a no-op in shouldShow; preserve that and the discovery service adapter checks.
4. Initialization currently launches device initialization concurrently with local WebUI storage (downloadRemote: false), then serves a readable --skin-path or falls back to the registry default. Await devices, mark init_ready, start/watch Android foreground service, mark scan_start, advance. DeviceController currently logs/swallow service failures; readiness must retain those failures rather than inventing successful BLE state.
5. ScanFlowView alone calls ConnectionManager.connect; ConnectionManager owns automatic/explicit scans, recovery, selection and cancellation. USB attach hints emitted during service initialization retain their existing recovery path. No coordinator scan/connection calls.
6. Plugin initialization and remote-skin refresh launch after core readiness and never gate scan, launcher or skin navigation. Their pending/failure outcomes are observable but are not BLE/skin/plugin live-state caches.

## Design decisions

Introduce AppStartupCoordinator alongside existing services (there is no existing general startup owner). Its constructor is inert; a memoized ensureInitialized Future coalesces all callers. Keep it at AppRoot lifetime, injected into MyApp and the initialization step. An app-level onboarding stage subscription triggers it when pre-initialization steps have resolved, independently of whether the initialization view mounts; do not launch from shouldShow because all predicates are evaluated eagerly. Ensure future hidden/replayed initialization cannot suppress startup: a post-permissions boundary hook owned by MyApp, not the loading widget, must trigger initialization and gate later scan presentation. Preserve current first-run ordering.

Core outcomes: initializing until devices/local WebUI/foreground setup settle; ready when successful; degraded with subsystem reasons when safe fallbacks permit the launcher/scan to continue (including no bundled skin). A truly blocking unexpected core failure is failed and recoverable by explicit user action only. Never automatically retry or replay successful device initialization; retry only failed, safely repeatable subsystems. Expose discovery initialization failures from DeviceController without duplicating authoritative live adapter state. Optional tasks have separate pending/completed/failed observations and can degrade status without retracting core readiness.

Foreground start/watch has exactly one startup owner: the coordinator. Permissions retains notification and battery prompts; remove its start/watch calls and guard its late advance after disposal. Preserve existing foreground grace timer behavior. Disposal fences late status, new side effects and UI navigation; it does not claim to cancel native operations already dispatched. AppRoot subtree restart must reuse the coordinator so WebUI and optional tasks do not repeat.

The initialization view only observes/awaits readiness, shows the existing loading/error presentation and a minimal explicit recovery affordance if needed, and advances once while mounted and still owning the active step. Do not redesign OnboardingController/back navigation/persistence.

## Verification matrix and baseline

Pinned local SDK matches CI: Flutter 3.47.9 / Dart 3.13.7. Baseline command `flutter test test/onboarding test/scan_flow_view_test.dart --reporter expanded` passed: `00:05 +125: All tests passed!`.

Deterministic fake-service/completer coverage must prove concurrent Future identity and single core execution, no construction-time permission/BLE/foreground work, one trigger after permission resolution (including an omitted initialization view), returning/bypass and force stage ordering, remount/revisit and AppRoot keyed restart reuse, pending/failing optional tasks not gating advancement, accurate local/device/foreground failures and selective explicit recovery, path fallback, and disposed UI/coordinator late completion fences. Existing scan/direct/demo/cancellation and shot-upload consent tests stay unchanged where possible.

Final gates: changed Dart formatting only with pinned SDK (AGENTS.md overrides repo-wide candidate in .lane/gate.md), focused startup/onboarding/scan/consent tests, flutter analyze, full flutter test. Capture actual red/green and parent gate transcripts under .lane/. Android permission/foreground behavior is verified with fakes/platform channels and source ownership checks, not physical BLE. No physical devices are authorized. Archive this design note before commit and populate every PR-template section in .lane/pr-body.md.

## Final recovery and lifecycle decisions

The production onboarding adapter installs the entry hook and wraps import/scan with the same loading/recovery presentation. This starts work without mounting the initialization widget, while an omitted initialization stage cannot expose a pending or failed scan. Generic OnboardingController commits an entered step only after its hook settles. Optional failures preserve initializing/failed core status; published observations are immutable. Successful local storage and skin-serving work are retained across explicit retries, including a working fallback after an invalid override. Reasons describe startup outcomes, not a parallel live-service status cache. Post-onboarding skin opening checks both its owner and navigator after serving completes.

Two worker passes supplied the initial extraction but missed lifecycle/recovery cases. Lead-authored correction tests demonstrated actual assertion reds before fixes; an independent reviewer then identified four further blockers, also reproduced with assertion reds. Platform checks remain deterministic/fake-boundary checks, not physical Android/BLE claims. The full-suite baseline has two reproducible bundled-plugin failures and isolated-green timing-sensitive cases, recorded in the local PR evidence.
