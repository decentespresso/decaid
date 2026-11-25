# Shot-upload onboarding

## Eligibility and ownership

Before plugin initialization, startup reads the ordinary persisted shot-upload
settings without constructing a loader or scanning manifests. Only the boolean
`AutoUpload: true` marks the new step seen. Existing installations with uploading
off or not configured remain eligible. Existing consent decisions and plugin
settings are not changed by this migration. `--force-onboarding` re-arms the
screen; `--bypass-onboarding` skips it unless force is also present.

The native **Reset onboarding** action in Advanced replays the screen on the
next cold launch. It only arms a one-shot marker, and startup runs the legacy
`AutoUpload` migration before the replay so the migration cannot swallow it.
The replay never clears the pending JSON decision, and the CLI flags still take
precedence for the launch they were passed to. See `doc/DeviceManagement.md`
(Reset Onboarding) for the full reset contract.

The native screen captures a decision, the plugin loader hands it off before
autoload, and after successful consumption the plugin's own settings are
authoritative.

## Displaying a prior choice during replay

A replayed screen never invents an answer. It shows the real state in this
order: a genuine pending decision, otherwise the plugin's persisted
`AutoUpload` value, otherwise a previously recorded onboarding answer whose
plugin setting is absent. An explicit persisted `true` or `false` wins over a
consumed record, so a plugin setting changed after onboarding still displays its
current value. Continuing or skipping with that state unchanged writes only the
`seen` flag, so a genuine pending decision stays pending until the loader applies
it and an existing `AutoUpload` value is not rewritten. Only an explicitly
changed toggle records a new pending decision, which keeps the existing validated
apply and retry contract.

The installation counts as first run, and the screen captures the answer, only
when the plugin setting and any pending or recorded onboarding answer are all
absent. The onboarding reader is strict: an absent setting is distinguishable
from an explicit `false`, while malformed, wrongly typed or unreadable stored
settings throw so the screen shows its retry action instead of presenting a
fabricated off state and recording an answer from it. The legacy
`AutoUpload: true` startup migration keeps its best-effort behavior and treats a
failed read as not enabled.

An installation with no linked account advances before the screen reads the
plugin setting, so unreadable stored settings never trap it. A linked account
then resolves the strict state before the choice is presented, and a failed
read shows a retry distinct from the account-check retry.

## Persistence and retries

The screen saves completion and the pending answer in one JSON preference. It
does not grant consent. A failed decision write keeps the screen retryable.

Handoff writes the plugin setting, grants account-proxy consent for an affirmative
decision, then clears the pending marker. These stores are not transactional:
a later failure can leave earlier writes persisted. The plugin is suppressed for
the current session and the pending decision is retried on restart. In particular,
a marker-clear failure can leave the deliberately granted consent persisted.
A negative answer does not alter an existing account-consent decision. No answer
is replayed after its pending marker is successfully cleared.

Account-proxy consent is for `plugin:shot-upload.reaplugin`, covering all
account-proxy operations permitted by its manifest, not only the upload POST.
This uses the existing caller-level consent contract; it does not narrow or
redesign the permission system.

## Safe first-run persona testing

Use a separate OS user or disposable VM for GUI first-run testing. On macOS,
changing `HOME` alone does not isolate platform preferences. Never clear a
customer's settings to simulate first run. On Linux, use fresh XDG directories
in addition to an isolated desktop/keyring session:

```sh
XDG_CONFIG_HOME=/absolute/persona/config \
XDG_DATA_HOME=/absolute/persona/data \
XDG_CACHE_HOME=/absolute/persona/cache \
flutter run --debug --dart-define=simulate=1 \
  --dart-define=DECAID_ENABLE_DUMMY_ACCOUNT=true \
  --dart-entrypoint-args=--dummy-account \
  --dart-entrypoint-args=--force-onboarding
```

The dummy identity uses an in-memory credential store. Account and account-proxy
clients fail locally before sending any request. Synthetic credentials do not
survive restart; release and profile configurations cannot activate this mode.
The rest of application state is still persisted, hence the isolated environment.
Do not use trust-all-consent flags or real hardware for this exercise.

Advance past welcome and the already-linked account screen to Shot upload.
Capture a region containing only the application, first with the switch off
and **Not now** visible, then with the switch on and **Continue** visible. Use
the operating system's region-capture tool and save `shot-upload-off.png` and
`shot-upload-on.png`. Inspect both images for account information, other windows,
notifications, and desktop content before sharing.

In a Pi session in this worktree, ask it to launch the existing
`persona-new-customer` agent read-only with both absolute screenshot paths.
Ask for its specified PASS / PASS WITH NOTES / FAIL verdict, quoted visible
issues, and trust assessment. Record the reviewed commit, environment, image
paths or URLs, verdict, and evidence separately from deterministic test results.
A persona verdict is subjective screenshot review, not an accessibility or
persistence test.

Attach the sanitized images to the GitHub PR and use descriptive alt text such
as “Shot upload off; Not now button” and “Shot upload on; Continue button”.
Local paths are not reviewer-accessible evidence. This document describes the
procedure; it does not attest that GUI captures or persona review have run.
