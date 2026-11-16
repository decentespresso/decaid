# Android APK Installation Permission

## Local Attempts

For #320, both existing local dialog implementations delegate installation to
AndroidUpdater. Each updater owns an in-memory permission coordinator. An attempt
checks the downloaded APK before checking permission or opening Android's per-source
installation settings. Its native activity result rechecks permission and either
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

The coordinator waits for the native settings activity result, not inferred
Flutter paused/resumed events. This also handles translucent settings screens
whose lifecycle never reaches paused. Repeated calls coalesce while an attempt is
pending. Disposal immediately cancels a pending permission wait. Disposal during
initial APK validation prevents subsequent permission or installer work, and a
later native result cannot launch an abandoned installation.
Activity destruction cancels the native request; ordinary startup has no saved
attempt to replay. Unrelated resumes never open an installer.

The Settings dialog owns and disposes its updater. Busy dialogs block barrier and
system-back dismissal; programmatic route removal still disposes the owner and
cancels the attempt. The cached APK is revalidated after permission returns. Native
invalid-file failures have a stable type so either local dialog discards the path
and its next Retry downloads a replacement.

Archive preflight checks package identity and signing information against the
installed application. Matching signer sets and single-signer forward rotation
are accepted; unsigned or unrelated signing identities are rejected. Android's
package installer remains the authority for full signature integrity and update
policy. No new version-code or reinstall policy is introduced.

Existing notification actions and Settings navigation remain unchanged. No pending
installation state is persisted, and native installer acceptance/cancellation
detection remains outside this change.
