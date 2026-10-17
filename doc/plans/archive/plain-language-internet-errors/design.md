# Plain-Language Internet Errors

Use typed, action-specific errors for skins, plugins, app updates, feedback, and
host-owned proxies. Only explicitly user-facing validation messages pass through;
parser/transport details stay in logs. Preserve downgrade and storage guidance.

Keep `Future<void>` updater contracts. Attempt every item, retain successes, then
throw immutable `RemoteUpdateException` with attempted count and item/error pairs.
Manual failures warn and return existing HTTP 500 envelopes; background failures
stay quiet. Deduplicate remote downloads at shared storage, not just UI buttons.

Manual Retry retains inputs and respects disposal. Permission approval must match
the current candidate; changed candidates require a new review. Feedback retains
its form and never resubmits known-successful submissions.

Preserve shared GitHub cooldowns and the native rate-limit release-page action.
Keep diagnostic HTTP statuses separate from user-facing rate-limit guidance.
Account/onboarding handling and upstream HTTP/streaming passthrough stay unchanged.
No probes, dependencies, automatic retries, TLS bypasses, or migrations.

Reuse the same guidance for local skin ZIP installs, plugin folder installs, and
plugin removal. Keep paths and exception details in logs. Do not add Retry to
these catches: a folder install's temporary staging directory has been removed.

Keep the `remote_error.dart` import in `webserver_service.dart`: its `part` files
share that library's imports and call `remoteErrorMessage`.
