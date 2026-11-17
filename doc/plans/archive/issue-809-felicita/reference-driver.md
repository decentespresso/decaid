# Felicita Arc plugin reference

## Context and scope

Prepare Felicita hardware validation on the locally connected Android tablet using the host-owned BLE and Scale stack from #809 / #823. Current branch: `odev/issue-809-bookoo-reference`, starting at `e45ec020`. Add `examples/plugins/felicita-arc.reaplugin/` beside Bookoo; retain Bookoo and native implementations unchanged. This does not claim completion of #809's explicitly Bookoo-specific hardware gate.

## Design

Use the existing Bookoo example's factory/session pattern, not a new driver framework. The manifest declares `transport.ble`, driver `felicita`, Scale capabilities battery/tare/timerControl/disconnectToSleep. Match case-insensitive name prefix `felicita`, matching native DeviceMatcher; verify canonical FFE0 service at connect rather than requiring advertised services (FFE0 is shared by unrelated hardware).

Port protocol facts from `lib/src/models/device/impl/felicita/arc.dart`: FFE0 service, FFE1 notifications and acknowledged writes; 18-byte notifications; sign at offset 2, six ASCII digits at offsets 3..8, hundredths of grams; battery byte 15 mapped from 129..158 to rounded 0..100. Reject malformed lengths and non-digit weight fields without publishing. Do not invent checksums or undocumented header constraints. Preserve native sign semantics unless repository evidence establishes a stricter encoding. Retain last valid battery on out-of-range raw values, initially null; reset battery on reconnect. No timer telemetry or flow estimation.

Commands are one byte: tare 54, start 52, stop 53, reset 43 (hex). Preserve acknowledged semantics and propagate bridge failures, without retries or reconnect loops.

Resolve connect only after subscription succeeds and a valid `session.publish(snapshot, sample)` is accepted. Preserve opaque host sample provenance. Per-session cleanup cancels watchdogs, fences stale callbacks and pending readiness; disconnect/sleep stays host-owned. Reuse the Bookoo provisional two-second valid-packet watchdog, starting after subscription (or earlier first valid packet), naming the threshold for hardware tuning and explicitly documenting that cadence is unverified. Ensure failures during service discovery/subscription/publication do not leak timers or unhandled readiness rejections.

## Implementation and review

1. Worker (`openai-codex/gpt-5.6-luna`, medium): establish test baseline, write focused failing real-JS tests, implement manifest/plugin/README, and add concise example links to relevant documentation. Reuse existing generic fake BLE edges; do not generalize or alter Bookoo solely to share a few lines.
2. Cover positive/negative/zero weight, malformed frames, battery endpoints/retention, exact canonical GATT and command bytes, first-sample handoff, missing service, subscription delay/failure, silence, reconnect, stale callbacks and plugin/native matcher ownership. Compare representative valid packets and commands against the unchanged native Felicita driver where practical.
3. Worker runs focused tests, `dart format lib test`, `flutter analyze`, full `flutter test`, and reports actual evidence and any pre-existing failures. No commits/push/PR edits; leave unrelated `.codegraph/` untouched.
4. Parent reviews implementation, tests and contract compliance, requesting worker corrections when needed. Finalize the required PR-template evidence locally and archive this design when software work is accepted. No endpoint/spec changes expected.

## Hardware phase (after implementation review)

Do not deploy or operate hardware during implementation. Together with the user, use existing sb-dev/ADB and plugin source-loading paths on this machine and the connected Android tablet. Record model/firmware where available, native and plugin ownership in separate sessions, first weight, positive/negative weights, battery, tare, timer start/stop/reset, deliberate disconnect, reconnect, reload and restart with persisted plugin preference. Record notification cadence/latency to accept or tune the watchdog. Keep software evidence separate from hardware acceptance; Felicita verification is not Bookoo verification.
