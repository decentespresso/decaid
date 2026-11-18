# Startup recovery and route ownership follow-up (#1178 / PR #1186)

## Bounded decisions

Reviewed head: a5eb1d6e9513ed04441d0628a20c7fda2dfafd2f. Keep the existing AppRoot owner, permission/setup sequence, successful-service idempotence, optional background work, scan ownership and persisted shot-upload consent semantics. This follow-up changes no external API contracts or extension-management authorization policy.

DeviceController initialization can complete normally with failures. The coordinator must distinguish an actual blocking discovery initialization failure from useful partial availability. The supervisor approved a pure constructor-injected startup-relevance predicate: successful no-op iOS serial, disabled simulation and empty plugin placeholders do not rescue failed real discovery. Initialized WiFi scale capability counts even without current endpoints; enabled simulation and registered plugin adapters count. No relevant configured service by itself is not a failure. Only actual relevant failures with no relevant successful service block startup. Unknown/custom discovery services default relevant. Track startup outcomes at the existing owner, not a second live adapter/device cache.

All-relevant-failed remains on loading/error/Retry. Partial discovery failures advance but retain a small explicit recovery notice in the existing guarded presentation. Retrying must keep the same scan child/key/subscriptions, initialize only failed services, coalesce pending callers and never initiate another scan. Local WebUI, optional plugin and remote-skin failures remain nonblocking; recovery clears only matching diagnostics.

Automatic skin opening owns the Launcher route, not the whole Navigator. Capture production route identity or a navigation-generation lease before awaiting serving; invalidate it if navigation goes to Settings (including notification View -> shared updater), or the owner/navigator is disposed/rekeyed. Unchanged Launcher opens once. Use real Navigator-route regressions, not an arbitrary false predicate.

## External scan compatibility and siblings

REST/devices-WebSocket startup scanning is inspected and pinned, not gated here. Write a separately scoped proposal in .lane/external-scan-followup.md if lifecycle/permission hardening is warranted. Do not change Home Assistant/MCP compatibility or discovery policy.

GitHub snapshots inspected: #1193 7822ad903c2d4a050a5a372011e2b9b223e55ed0; #1185 8f252f41b77e3eaeff4a1d6ce4799188e2f3a4ea; #1181 1ab0f137eda66e335519a07352ed6cc229b5dacf. Do not import sibling commits; #1185 explicitly waits for #1193 merge. Preserve future integration of both lifecycle resume hooks: native security-settings refresh and shared updater refresh. Security settings must load before startWebServer in that integration, no indefinite security-mode cache or settings writes during keyed relaunch. Trusted skin origins must follow actual WebUIService.port after startup/retry/switch. #1185 owns strict archive staging/rollback/expected-ID work; this lane does not touch archive machinery.

## Verification goals

Before fixes reproduce both P1 symptoms with actual DeviceController initialization and real Navigator routes. Test all-failed, mixed success, placeholders, zero relevant, pending retry coalescing, failed-only recovery, diagnostics retention, optional/nonessential progression and no duplicate scan/attach subscriptions. Test Settings navigation, updater-route equivalent, owner disposal/restart and unchanged Launcher. Use only fake/completer/channel boundaries; no physical BLE/Android access.

Run pinned SDK changed-Dart format/check, focused startup/device/navigation/scan/connection/lifecycle tests, flutter analyze --no-pub, then coordinated full flutter test --no-pub --machine --concurrency=4 and timing summary. Ask root before heavy full gates. Use current ignored shot-upload v0.2.4 bundle, not the stale primary copy. Archive this rationale before local commit; populate all PR-template sections in .lane/pr-body-followup.md. Root alone validates/publishes; no merge.

## Recovery placement and navigation ownership

A partial-success scan can finish normally, so scan-only recovery would disappear on Launcher and reproduce the accessibility defect. The supervisor explicitly approved reusing one recovery widget/action above native Launcher as well as guarded import/scan. It observes the shared coordinator, keeps useful child content mounted, and offers no discovery banner for optional-only failures. Skin and Settings need no such banner.

Startup navigation uses a small NavigatorObserver lease: top-route identity plus generation, invalidated only on genuine top changes. This preserves Settings/update navigation, including push-then-pop, while removal below Launcher does not cancel a legitimate startup open. Owner/navigator disposal guards remain.

Current source starts the server before installing the simulation listener and loading settings. The upcoming sibling security change must move that existing listener/load block together before the server; it is not already present here. Later integration must retain security refresh AND updater refresh on resume and live dynamically assigned skin origins. No sibling commits or lifecycle/auth edits are included in this correction.
