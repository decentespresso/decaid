# Android APK Installation Permission

## Local Attempts

For #320, both existing local dialog implementations delegate installation to
AndroidUpdater. Each updater owns an in-memory permission coordinator. An attempt
checks the downloaded APK before checking permission or opening Android's per-source
installation settings. Returning from that screen rechecks permission and either
launches the native installer once or returns a neutral permission-required
outcome. Both dialogs retain their downloaded path for Retry after denial.

Permission-required, cancelled and installer-launched outcomes are distinct from
genuine installation errors. An invalid cached APK is discarded by the dialog;
the next Retry downloads again. Launching the native installer does not mean the
update was installed.

## Remote Requests

Remote installation preflights permission before release checks or download work.
Missing authorization produces a structured reply only to the requesting socket,
without opening local settings or changing the shared update state. The remote
installation path never requests local permission, even if authorization changes
during its download.

## Lifecycle Boundaries

The coordinator observes lifecycle events only while a permission attempt is
pending. It requires the app to leave and return, coalesces repeated calls during
that attempt, and unregisters its observer afterward. Disposal cancels the pending
attempt; ordinary process startup has no saved attempt to replay. Neither an
unrelated resume nor a previous launch can automatically open another installer.

Existing notification actions and Settings navigation remain unchanged. No pending
installation state is persisted, and native installer acceptance/cancellation
detection remains outside this change.
