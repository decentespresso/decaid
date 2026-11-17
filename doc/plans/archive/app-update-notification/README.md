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

The service owns a transfer independently of its dialog. Back, Cancel and the
modal barrier may close the dialog without cancelling that transfer. Re-entry
reads canonical progress, completion or failure rather than creating a new
downloader. Display, release notes and actions follow the current confirmed
release, identified by version and asset URL; withdrawal removes obsolete
actions, and feedback from an older release does not label a replacement Retry.

An accepted download or installation fences pending metadata checks at each
asynchronous boundary, including failures. Rejected stale requests do not claim
ownership. Cache reuse and native installation require a nonempty regular file;
unusable files are discarded so an explicit retry can download a replacement.

Retain unchanged confirmed notices without another persistence write. Restored
notices still need revalidation, read state survives host-action migration, and
removed notices may be recreated with a fresh activation binding.
