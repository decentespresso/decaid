# Plugin Permission Enforcement

## Capability model

- `log` gates `host.log`.
- `api` gates plugin `fetch` and declared HTTP endpoints.
- `emit` gates `host.emit`.
- `pluginStorage` gates `host.storage`.
- `proxy.decent_api` and `proxy.decent_api.write` retain their existing read and allowlisted-write rules.
- `events.machine` gates `stateUpdate` delivery.
- `events.shots` gates `shotStored` and `shotUpdated` delivery.
- Timers remain baseline runtime facilities.
- `pluginNotify` is removed until a notification host API exists.

## Implementation

1. Reject undeclared calls at the plugin JS surface with `PluginPermissionError`.
2. Recheck every capability in Dart and log denials with plugin ID and wire name.
3. Reject unknown manifest permission names.
4. Correct bundled manifests and validate the pinned DYE2 manifest after download.
5. Add allowed and denied tests for each capability and event subscription.
6. Update plugin documentation and the REST schema permission enum.

## Verification

Run formatting, focused plugin tests, `flutter analyze`, and the full Flutter test suite.
