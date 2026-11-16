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

Desktop release-note behavior and plugin-provided notification actions remain
unchanged. No alternate notification-local downloader or progress state machine
is introduced. Widget tests cover launcher and skin routing, progress, stale
notices, repeated actions and re-entry; independent physical verification of the
final extracted branch remains separate from earlier tablet evidence.
