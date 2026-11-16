# App Update Notification Navigation

For #1159, the host app-update notice has one View action. It dismisses the
notification surface, returns to the launcher, opens Settings and presents the
existing updater for the current confirmed release. Merely opening it never
starts a download. Restored notices still require update revalidation.

The update service owns the transfer and downloaded path so re-entry observes
existing progress or results instead of starting a second download. Concurrent
operations join only when their release tag and download URL match. Installation
uses the existing boolean updater contract; native installation permission and
credential management are unchanged.

A completed installer launch is distinct from completed installation. Re-entry
can offer an explicit Retry, but cannot automatically relaunch the installer.
Failures retain safe messages and an available recovery action. Cached transfers
are reused only for the same release when the file still exists and is nonempty;
an installer exception discards the cached path so download can be retried.

Metadata checks can finish after a user starts a transfer or installation. A
revision counter fences results after each asynchronous settings/network boundary,
including error paths, so a stale check cannot overwrite that newer operation.
Reusing a valid cached file also restores the available phase, so invalidating a
pending metadata result cannot strand the service in checking. Cache inspection
failures discard the path and publish a recoverable error.

Once a metadata check confirms a release or its absence, downloads and cached
installations must match the current tag and asset URL before changing operation
ownership. An open Android dialog follows that confirmed selection, clears stale
cached controls and resolves release notes from the current release. Removing the
selected release retires its download and install controls.

Update notices contain availability and a live View action, not download progress.
An already-confirmed notice for the same version is retained without another
persistence write or listener update. Restored notices still require confirmation,
and removal permits a fresh notice for the same version to be published.

Desktop release-note behavior and plugin-provided notification actions remain
unchanged. No alternate notification-local downloader or progress state machine
is introduced. Widget tests cover launcher and skin routing, progress, stale
notices, repeated actions, selection changes and re-entry.
