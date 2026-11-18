# App update notification

Issue: #1159. The #1090 dashboard transition is already present, but View still
opens release notes and Download uses a separate updater instance.

Use one host-provided View action. Dismiss Notification Center, remove the skin
presentation, and open Settings with the confirmed update version. Settings uses
the same update dialog for manual checks and notifications, backed by the
existing UpdateCheckService for download progress and installation. Opening the
dialog does not start a download. Retain unconfirmed-notice revalidation and
plugin action routing.

The dialog is a view of shared state, not an owner of it. That is why Settings
never opens a temporary updater for the notification path: a transfer outliving
the dialog is the point of the change, so a short-lived updater would reintroduce
the lost-download bug it removes. A temporary updater remains correct only where
it is genuinely temporary (the quick-update route from #1174), and that route
disposes it after use.

Android install authorization (#320, merged through #1174) is composed with, not
reimplemented. Its `ApkInstallOutcome` contract is the boundary: the coordinator
inside the updater is the sole permission authority and continues an authorized
launch automatically after the user returns from Android's install-source
settings. This change only decides what to show for each outcome, and one
notification View route exists for both permission-clean and permission-missing
devices.

Android reports an installer launch, not a completed installation. `launched`
means the prompt opened; feedback says installation started and never claims
success, and the uninstalled update stays retryable. `permissionRequired` is
neutral guidance plus Retry from the cached APK, not a generic installation
error, and it never re-downloads. `cancelled` keeps the explicit Install
affordance so the native installer's own cancellation is not auto-relaunched.

Attempt ownership spans three lifetimes that used to be confused: the dialog, the
Settings route, and the service. Deduplication lives with the service and the
coordinator, so repeated taps, resumes and re-entry coalesce onto one transfer and
one launch; only an explicit retry after the attempt ended can launch again.
Dismissing a download keeps it running; a pending install is the one state that
resists dismissal, because closing it would orphan a continuation the user cannot
see.

Cancellation during the window between the explicit tap and the coordinator's
first await is what makes route removal safe. The updater validates the cached
APK natively before it builds an install continuation, so a cancel that only
disposed an existing coordinator would still allow a launch created after the
validation returned. Cancellation therefore advances a per-updater attempt
generation that the pending install compares against when its validation
completes, and the generation is compared, not latched: the next explicit Install
captures the current generation and proceeds normally. Disposal reuses the same
path, so a disposed updater cannot launch anything either.

An early resume is remembered rather than acted on: the app lifecycle observer may
report a resume while the permission round trip is still open, and the attempt
must then settle once the launch returns instead of hanging in `installing`.
Resume recovers presentation only. It never requests permission, never launches an
installer, and never becomes a second permission coordinator.

Lifetime belongs to the application, so ownership of disposal does too. Nothing
the keyed app tree or the dialog owns disposes the service: the keyed root only
unregisters the notification presenter it created, and the dialog only cancels an
attempt it owns. Terminal app shutdown is the single disposal site, and it
releases the service before the awaited connection and plugin shutdowns that can
block, so a pending permission or validation round trip is cancelled instead of
launching behind a hung shutdown. The delayed startup initialization is a
cancellable service timer whose every await re-checks disposal, so a shutdown
during initialization neither starts periodic checks nor leaves a timer behind.
An install failure commits its state only after the cache existence inspection
returns and the attempt is still the current one, so a superseded failure cannot
clear a replacement attempt or its accepted state.

Regression coverage must exercise dashboard and skin navigation, stale notices,
explicit download confirmation, shared progress, retries, and re-entry without
duplicate operations, plus the composed installer outcomes through the real
coordinator: permission granted, missing then granted, denied, native
cancellation, resume during the permission round trip, and route removal during
both the permission wait and the native cache validation. Verify with the pinned
SDK, focused tests, analysis, and the full suite. Physical Android UI evidence is
reported separately and must not be inferred from simulated or widget tests.

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
