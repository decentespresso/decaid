# #1258 — non-destructive onboarding replay

Risk: L3, persisted presentation progress crossing startup and consent boundaries. No externally
callable API, no ownership transfer, no onboarding-v2 redesign.

## Observed machinery

- Advanced is a native page and already owns Exit Decaid; settings mutate through
  `SettingsController`, which caches every preference.
- Presentation progress lives in four separate preferences: `onboardingCompleted` (welcome + import),
  `accountStepSeen` (login), `androidWarningDismissed` (platform warning) and the shot-upload step's
  `seen` flag. Shot upload additionally keeps a JSON decision record
  (`{answer, pending, seen}`), a pre-loader legacy `AutoUpload` migration and a pending-decision
  handoff in `PluginLoaderService`.
- `main()` loads settings, runs `prepareShotUploadStartup` (legacy migration plus CLI shot-upload
  flags) and later the CLI onboarding block. `AppRoot.restart` only recreates the keyed `MyApp`, so it
  never re-runs `main()`.
- `OnboardingController` decides visibility from those same cached settings, so an eligible step
  appears purely because its preference was cleared.

## Decisions

1. **One-shot marker, consumed only by cold startup.** `requestOnboardingReplay()` writes
   `onboardingReplayRequested` and nothing else: the current session keeps its state, and a keyed
   `MyApp`/`AppRoot` restart cannot consume the request. `loadSettings()` deliberately does not read
   the marker.
2. **Narrowly named presentation reset shared with #1259.** `consumeOnboardingReplayRequest()` (cold
   startup) delegates to `resetOnboardingPresentationProgress()`, which writes only the four
   presentation preferences and updates the cache after every write lands. A failing write throws,
   leaves the marker armed and leaves cached progress untouched, so the next launch retries. #1259
   reuses that entry point for its non-destructive half instead of duplicating wizard bookkeeping.
3. **Startup order** in `prepareOnboardingStartup` (renamed from `prepareShotUploadStartup`): legacy
   `AutoUpload` migration, then an armed replay, then the CLI shot-upload flags. The CLI onboarding
   block later in `main()` keeps the last word, so `--force-onboarding` and `--bypass-onboarding`
   behave as documented, including "force wins" when both are passed.
4. **No invented shot-upload answer.** The replayed screen resolves the real prior state as pending
   decision, else the recorded JSON `answer`, else a legacy `AutoUpload: true` (read through the
   existing `persistedShotUploadAutoUploadEnabled` helper, injected into the step so tests never call
   platform channels). Continuing or skipping with that value unchanged writes only `seen`; only an
   explicitly changed toggle records a new pending decision, keeping the existing validated apply and
   retry contract. A genuine pending decision therefore survives the replay.
5. **Preservation.** Accounts, consent, plugin settings, preferences, profiles, workflows, data,
   devices, skins and OS permissions are untouched; the tests assert the exact set of preference keys
   the replay writes and that unrelated values survive.
6. **Advanced action.** A native `ListTile` next to Exit Decaid opens an `AlertDialog` that states the
   screens return on the next cold launch and that configuration is kept. Cancel writes nothing,
   duplicate confirms are idempotent, a failed write reports an error snackbar instead of success.

## #1179 integration contract

When versioned step-ID progress arrives, the replay resets that progress through
`resetOnboardingPresentationProgress()` rather than the underlying settings. The future bundled-skin
chooser and the device chooser must preselect the real current value, and skipping or continuing them
unchanged must write nothing.

## Verification

Focused: `flutter test test/onboarding/` plus the advanced-page, settings-controller and
main-startup suites; `flutter analyze`; changed-Dart-only `dart format`. Full suite and physical
Android walkthrough belong to the lead and the operator respectively: no physical device was accessed,
so the tablet walkthrough stays a merge-readiness blocker until supplied.
