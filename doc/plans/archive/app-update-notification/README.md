# App update notification

Issue: #1159. The #1090 dashboard transition is already present, but View still
opens release notes and Download uses a separate updater instance.

Use one host-provided View action. Dismiss Notification Center, remove the skin
presentation, and open Settings with the confirmed update version. Settings uses
the same update dialog for manual checks and notifications, backed by the
existing UpdateCheckService for download progress and installation. Opening the
dialog does not start a download. Retain unconfirmed-notice revalidation and
plugin action routing. Android install authorization remains #320's concern.

Regression coverage must exercise dashboard and skin navigation, stale notices,
explicit download confirmation, shared progress, retries, and re-entry without
duplicate operations. Verify with the pinned SDK, focused tests, analysis, and
the full suite. Physical Android UI evidence is reported separately and must not
be inferred from simulated or widget tests.

Android reports an installer launch, not a completed installation. Retain
attempt deduplication until app resume, then release the attempt for explicit
retry with the cached APK. Remember an early resume until the pending launch
returns, but never launch an installer from a resume callback. Installation
permission coordination remains owned by #320.

Download and Install are disabled while checking. Dialog-local validation
feedback must not overwrite the shared operation state. Download progress is
indeterminate until a valid measured percentage arrives.
