# Persistent Native Notification Center

## Design

The app owns one constructor-injected NotificationCenter. A versioned private
SharedPreferences snapshot retains source identity, approved action descriptors,
ordering and read state. Plugin validation and targeted events remain at the
plugin boundary. No skin API, Hive namespace or database change is needed.

Storage mutations are serialized and published only after saving. Failed writes
leave the previous state visible. Invalid snapshots remain untouched and report
an error rather than resetting user data. Restoration finishes before plugins
can publish.

Runtime action bindings are separate from retained data. Restored notices are
immediately visible, awaiting confirmation, with disabled actions. A current
plugin generation or successful update check revalidates them. Read changes do
not retire actions; replacement, removal and generation retirement do. Shutdown
and reload retain notices, while explicit unload, disable, uninstall, permission
removal and condition resolution remove them.

The skin opens a compact unread-at-opening snapshot; the launcher opens all
current conditions with approved actions. Both reuse shadcn rows and dialogs.
Reading does not empty or close the compact snapshot. Its Go to notification
center control closes the compact route before opening the full center.
Opening marks only captured content revisions read. The skin's circular bell occupies its existing
Scaffold floating-button slot without wrapping or resizing the WebView. The
dashboard destination remains available for read notices and the empty state.
Browser launch and return tracking belong to an app-lifetime controller, not the
dialog. Existing transient SnackBars remain independent.
The bell reserves 64 logical pixels below its safe area within the floating-button
slot. Runtime checks found that the default position covered Insight's settings
control. This spacing clears that bottom control row without changing the WebView
or adding skin-specific detection or configuration.

Plugin capacity remains five per source and twenty overall, without eviction.
One separate host update entry cannot be consumed by plugins. Notification
results acknowledge durable acceptance, not presentation or acknowledgment.
The uploader retries rejected notices independently of its upload pause policy.

Update notices are bound to a specific version. Startup without a successful
check and network failures preserve retained notices; installed, skipped or
confirmed-obsolete versions are removed. Repeated identical checks preserve
read state. Skip this version is an explicit host-approved action, bound to the
displayed version, not a side effect of reading or generic removal. Restored
actions, including Skip, stay unavailable until the source revalidates them.
Confirmation remains runtime-only, and revalidation replaces an unconfirmed
binding even when the source and content are unchanged.
An unconfirmed host update shows Check for updates instead of disabled saved
View/Download controls. The existing manual update service is constructor-injected
into the action owner. Its current stream state disables duplicate checks and
reports failure while allowing retry. Confirmation restores trusted actions;
obsolete updates are removed and newer versions replace the old entry. Closing
the overlay does not cancel the service request. This is app-update-only and
does not change the delayed background checks or update skins/plugins. The check
control is neither persisted nor available to plugin-authored notices.
The Android Download action opens the existing UpdateDialog, with Cancel before
download and a separate Install action. It must not use the automatic quick
updater, which downloads and attempts installation as soon as it opens.
The notification route finishes closing before that confirmation opens, avoiding
stacked dialogs. The app-lifetime action controller holds its busy guard across
this handoff and rechecks the notice binding afterward, preventing duplicate
navigation and activation of a notice retired during the transition. Cancel
leaves the read update entry available from the dashboard.

## Boundaries

Plugins keep one approved action. The host owns View, Download and Skip for its update
entry; those actions do not expand plugin permissions. Credential-free HTTPS and
current-generation checks remain at the plugin boundary. The center stores data
and runtime bindings separately so reading a notice cannot retire a Support
return or run an action restored from disk.

The native destination card keeps dashboard access available after the unread
bell disappears. The dashboard grid allocates space for long labels and scaled
text. The dialog fixes the heading and Close control above the scrollable rows.
It is capped at 720 logical pixels wide and 85% of available height, so a full
21-entry list scrolls without moving the heading controls.
Its barrier and action controls have accessible labels and touch targets.
The heading keeps an X for closing the dialog. Neither view has generic trash,
delete or Dismiss all controls. Notifications are current actionable conditions,
not a history or a queue of transient messages. Reading retains them; their
source withdraws them on resolution. Plugin IDs or messages cannot claim
host-update actions.
The close tooltip uses Flutter's Material localization. This does not enable new
native locales or translate plugin content; the native app currently enables
English only. Retained and newly published entries share the same controls.

The compact view is capped at 480 logical pixels wide; the full center at 720.
Both retain the 85% height limit. Source withdrawal or supersession removes
stale compact entries, but reading alone never changes snapshot membership.

The uploader owns its pending, accepted and rejected delivery state. Its 60-second notice
retry handles capacity/storage rejection without running upload reconciliation.
Changing upload eligibility, publishing generated plugin bundles, and introducing
a skin notification contract are outside this design.

## Windows Storage

The installed Windows preferences package caches whole-file maps independently
for its legacy and Async APIs. Mixing notification/plugin legacy writes with
Async settings writes was observed overwriting the notification snapshot and
skipped-version settings. The center's serialized model writes do not fix this
cross-backend issue. Windows startup now warms the legacy backend and adapts
the Async platform API to that same backend before creating preferences clients.
This preserves existing raw keys and file format without migrating settings.
Only already-resolved preference platform packages are promoted to direct/test
dependencies. A native file-backend test reproduces the loss without the adapter
and verifies notifications, read state, skipped versions and unrelated keys after
interleaving writes and reconstructing both APIs. See `doc/AI_STORAGE_NOTES.md`.
