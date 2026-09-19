# Generic native device settings

This archive records the design for the generic native device-settings entry.

Plugin drivers may opt in by naming one declared HTTP API endpoint as
`settingsEndpoint`. The host validates the plugin's `api` permission and the
endpoint type before exposing the action. The device descriptor is native-only
and carries the plugin ID and endpoint ID; public inventory does not gain a
second settings field.

The native device page constructs a localhost URL from validated path
components and passes the stable public device ID and name. It opens the
plugin-owned HTML page with the existing `url_launcher` in-app browser mode,
whose platform fallback avoids a custom WebView lifecycle. The plugin endpoint
continues to own per-device validation and persistence through its existing
store. Plugin-global settings remain a separate authority.

Eligibility follows the live device object. A retired or replaced binding
cannot be opened through a stale settings action. Same-model instances retain
independent descriptors and public IDs; plugin-generation teardown removes all
of that generation's eligible devices while sibling plugins remain unaffected.
