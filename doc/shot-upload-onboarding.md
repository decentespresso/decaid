# Shot-upload onboarding

## Eligibility and ownership

Before plugin initialization, startup reads the ordinary persisted shot-upload
settings without constructing a loader or scanning manifests. Only the boolean
`AutoUpload: true` marks the new step seen. Existing installations with uploading
off or not configured remain eligible. Existing consent decisions and plugin
settings are not changed by this migration. `--force-onboarding` re-arms the
screen; `--bypass-onboarding` skips it unless force is also present.

The native screen captures a decision, the plugin loader hands it off before
autoload, and after successful consumption the plugin's own settings are
authoritative.

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
