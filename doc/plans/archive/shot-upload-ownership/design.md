# Plugin Notifications And Upload Ownership

## Boundary

Ownership and upload policy belong in the source-of-truth shot-upload plugin.
Decaid provides authenticated proxy access, credential-free account-change events,
and a generic permissioned notification API. No uploader-specific event, serial,
message, support URL, or recovery rule is interpreted by native UI.

## Host Contract

`notifications` grants plugin-scoped show/update/dismiss operations. Notifications
are attributed to their originating manifest and have bounded text and queue
sizes. A dedicated, scrollable banner occupies at most 40% of the viewport;
it never clears, replaces, or queues behind Decaid snackbars. Each plugin can
update or dismiss only its own notices. Unload removes that plugin's notices.

Actions require a user gesture and are limited to opening native Decent account
settings (also requiring account-proxy permission) or an external HTTPS URL
without embedded credentials. The link's destination hostname is visible.
Action and application-return events target only the originating live plugin
generation and current notification. Plugins choose what those events mean.
The executable API and its bounds are documented in `doc/Plugins.md`.

The native close button reports a targeted `notificationDismissed` event after
removal. Programmatic removals stay silent. The uploader tracks an outstanding
ownership notice separately from paused serials: closing a notice acknowledges
it without allowing uploads, and a newly paused serial can then alert the user.
Additional paused serials must not replace a still-current notice, because that
would invalidate a pending Support browser-return callback.

## Consumer Policy

Shot-upload checks each shot's original machine serial before POST. Missing
serials and HTTP 403 pause that serial; HTTP 401 pauses the account. Outages use
backoff without claiming the machine is unlinked. Original shot identity and
history are preserved; ownership and authentication failures are not permanent
shot rejections.

The plugin supplies pause wording and Support/Sign In actions. Returning from
its Support link or receiving an account-change event invalidates its ownership
cache. Restart is another check trigger, not a recovery prerequisite. Only a new
lookup can authorize resuming uploads; stale account failures cannot affect a
newer generation.

The proxy independently protects newer logins from stale HTTP 401 responses,
including logins that reuse credentials. The final post-consent credential
snapshot determines the authentication generation; a failed post-response
credential read cannot replace the upstream response.

## Delivery

The plugin requires a host that recognizes the notification permission. Its
release and checksum-verified Decaid bundle pin are separate from the host API
change. Historical ownership authorization remains server policy, not a reason
to rewrite shots or add plugin-specific native exceptions.
