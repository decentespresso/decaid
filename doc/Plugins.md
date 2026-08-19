
# Decaid Plugin Development Guide

## Overview

> **Note on naming:** Plugin JS APIs use `Rea`-prefixed names (`fetchReaSettings`, `updateReaSetting`, `convertReaToVisualizerFormat`) for backwards compatibility with existing plugins. These were not renamed during the app rename from ReaPrime to Decaid.

Decaid plugins are JavaScript modules that extend the functionality of Decaid.
Plugins run in a sandboxed JavaScript environment and can react to machine events,
store data, make HTTP requests, and emit events through the Decaid API.

## Plugin Structure

A Decaid plugin consists of two required files:

### 1. `manifest.json` - Plugin metadata and configuration

> **`id` restrictions:** The plugin id becomes a directory name under the app's `plugins/` folder, so it must be a single safe filesystem path component: no `/` or `\` separators, no `.` or `..`, no leading drive letter or NUL byte, and no Windows-reserved characters. Unsafe ids are rejected with a clear error and the plugin is not installed.

```json
{
  "id": "unique.plugin.id",
  "author": "Your Name",
  "name": "Plugin Display Name",
  "description": "What your plugin does",
  "version": "1.0.0",
  "apiVersion": 1,
  "permissions": [
    "log",
    "api",
    "emit",
    "pluginStorage",
    "events.machine"
  ],
  "settings": {
    "SettingName": {
      "type": "string",
      "secure": false,
      "description": "Setting description"
    },
    "Roast": {
      "type": "enum",
      "values": ["Light", "Medium", "Dark"],
      "default": "Medium",
      "description": "Roast degree"
    }
  },
  "api": [
    {
      "id": "eventName",
      "type": "websocket",
      "data": {
        "field1": {
          "type": "number",
          "description": "Field description"
        }
      }
    }
  ]
}
```

#### Manifest Fields

- **id**: Unique identifier using reverse domain notation (e.g., `com.example.plugin`)
- **permissions**: Array of capabilities the plugin needs:
  - `log`: Call `host.log`
  - `api`: Use plugin `fetch` and expose declared HTTP endpoints
  - `emit`: Call `host.emit`
  - `pluginStorage`: Call `host.storage`
  - `events.machine`: Receive `stateUpdate`
  - `events.shots`: Receive `shotStored` and `shotUpdated`
  - `proxy.decent_api`: Send read requests through `host.decentProxy`
  - `proxy.decent_api.write`: Send allowlisted write requests through `host.decentProxy`
- **settings**: User-configurable options with `type` (`string`, `number`, `boolean`, `enum`) and optional `secure` flag for credentials such as passwords. Enum `values` are a JSON array of strings. Secure values use platform credential storage, are supplied in memory to `onLoad(settings)`, and are never returned by the REST API.
- **api**: HTTP and WebSocket endpoints exposed by the plugin

Unknown permission names make the manifest invalid. Calls without their required
permission throw or reject with `PluginPermissionError` and are logged by Decaid.
`setTimeout` and `clearTimeout` are baseline runtime facilities and need no
manifest permission.

### 2. `plugin.js` - Main plugin implementation

```javascript
function createPlugin(host) {
  "use strict";

  // Internal state
  let state = {};

  function log(msg) {
    host.log(`[plugin-id] ${msg}`);
  }

  return {
    id: "unique.plugin.id",
    version: "1.0.0",

    onLoad(settings) {
      // Called when plugin loads
      // `settings` contains user-configured values
    },

    onUnload() {
      // Clean up resources
    },

    onEvent(event) {
      // Handle events from Flutter app
      // event.name: string, event.payload: object
    }
  };
}
```

## Host API

The `host` object provides these methods:

### `host.log(message)`
Log messages to the Flutter app's logger. Requires `log`.

### `host.emit(eventName, payload)`
Emit events to the Flutter app. Requires `emit`.

### `host.storage(command)`
Interact with persistent storage. Requires `pluginStorage`. Commands:
```javascript
// Read from storage
host.storage({
  type: "read",
  key: "keyName",
  namespace: "plugin.id"
});

// Write to storage
host.storage({
  type: "write",
  key: "keyName",
  namespace: "plugin.id",
  data: { foo: "bar" }
});
```

**Note:** namespace is not used by Decaid internally, the plugin storage is namespaced to the plugins' identifier.

### `host.decentProxy(path, options)`
Call the Decent account proxy without exposing stored credentials to plugin code. `GET` requires the read-only `proxy.decent_api` permission. `POST` requires the distinct write permission `proxy.decent_api.write` **and** is restricted to an explicit path allowlist (currently only `support/api/shot_upload`); other methods/paths are rejected and logged. The first request from each plugin id pauses for approval in Decaid's native UI. Explicit allow and deny decisions are remembered; denial or timeout rejects the call before any upstream request.

```javascript
const response = await host.decentProxy("support/api/sn", {
  method: "GET",
  query: { onlyespressomachines: "1" }
});

if (response.status === 200) {
  const serials = response.body.trim().split("\n");
}

// POST with a body (needs proxy.decent_api.write; only allowlisted write paths)
const upload = await host.decentProxy("support/api/shot_upload", {
  method: "POST",
  body: JSON.stringify(shot),
  contentType: "application/json"
});
```

The returned object has `{ status, headers, body }`. `GET` (read) needs `proxy.decent_api`; `POST` (write) needs `proxy.decent_api.write` and a path on the write allowlist. Credentials are attached in Dart and never exposed to plugin JS.

## Events System

### Events from Flutter → Plugin

Plugins receive events in the `onEvent` method:

Machine broadcasts require `events.machine`. Shot lifecycle broadcasts require
`events.shots`.

- **`stateUpdate`**: Machine state changes (temperature, pressure, flow, etc.)

  ```javascript
  {
    name: "stateUpdate",
    payload: {
      groupTemperature: 93.5,
      targetGroupTemperature: 94.0,
      pressure: 9.2,
      flow: 2.1,
      // ... other machine metrics
    }
  }
  ```

- **`shutdown`**: Plugin is about to be unloaded
- **`storageRead`**: Response to a storage read request

  ```javascript
  {
    name: "storageRead",
    payload: {
      key: "lastUploadedShot",
      value: "shot-12345"
    }
  }
  ```

- **`storageWrite`**: Confirmation of storage write
- **`shotStored`**: A shot finished persisting
- **`shotUpdated`**: A stored shot was edited via `PUT /api/v1/shots/<id>` (e.g. metadata changes — notes, enjoyment, bean/grinder). Broadcast to every plugin so they can react to edits (the Visualizer plugin uses it to forward-sync edited metadata).

  ```javascript
  {
    name: "shotUpdated",
    payload: {
      id: "shot-12345",       // local shot id
      shot: { /* full shot without measurements */ },
      patch: { /* the partial update body that was PUT */ }
    }
  }
  ```

#### Visualizer Forward Sync

The bundled Visualizer plugin merges recipe and shot-review tags, reads the current Visualizer tags before replacing them, and forwards later local edits in order. Visualizer tag writes require a Visualizer Premium account. The upload endpoint returns `202` with `visualizer_id` after the Visualizer upload succeeds while the tag PATCH continues in memory. Follow-up failures, including Visualizer's premium-account rejection, are reported through `shotForwardSyncError` and `forwardSyncStatus`; tag ownership is restored after an app or plugin restart. Pending work is not restored though.

### Events from Plugin → Flutter

Plugins can emit custom events that the Flutter app can listen to:

```javascript
host.emit("timeToReady", {
  remainingTimeMs: 120000,
  heatingRate: 0.5,
  status: "heating",
  message: "02:00 remaining"
});
```

The event name is tied to the api endpoint, defined in the plugin manifest.
When Decaid matches an external request to an endpoint that is defined in the
plugins manifest,
it will send over events emitted by the plugin.

Example:

```bash
npx wscat -c ws://localhost:8080/ws/v1/plugins/time-to-ready.reaplugin/timeToReady

```
Will open a websocket through which Decaid will forward all the `timeToReady` events

## HTTP Requests

Plugins can make HTTP requests using the standard `fetch` API (polyfilled by the host):

Plugin `fetch` requires `api`. Declared HTTP endpoints also require `api` before
Decaid dispatches a request to the plugin.

```javascript
// Basic GET request
const response = await fetch("https://api.example.com/data");
const data = await response.json();

// POST with authentication
const authHeader = "Basic " + btoa(username + ":" + password);
const upload = await fetch("https://api.example.com/upload", {
  method: "POST",
  headers: {
    "Authorization": authHeader,
    "Content-Type": "application/json"
  },
  body: JSON.stringify(data)
});
```

**Note**: The JavaScript environment has limited APIs. Currently available:

- `fetch()` for HTTP requests
- `btoa()` for base64 encoding (polyfilled)
- Standard JavaScript language features

## Plugin Lifecycle

1. **Initialization**: Plugin directory is copied to app storage
2. **Loading**: `createPlugin()` is called, then `onLoad(settings)`
3. **Running**: Plugin receives events via `onEvent()` and can emit events
4. **Unloading**: `onUnload()` is called for cleanup
5. **Removal**: Plugin files are deleted from storage

### Load watchdog

Decaid records consecutive load failures for each plugin. After three failures, auto-load is disabled so the plugin no longer runs on subsequent launches. A plugin whose load was interrupted by an app exit is disabled on the next launch immediately, which also covers JavaScript evaluation that blocks before Dart's one-second timeout can fire.

Disabled plugins remain installed and can be re-enabled from plugin settings or `POST /api/v1/plugins/:id/enable`. Re-enabling clears the failure count and gives the plugin a fresh attempt; a successful load also clears it.

## Example: Temperature Monitoring Plugin

```javascript
function createPlugin(host) {
  "use strict";

  let temperatureHistory = [];

  function log(msg) {
    host.log(`[temp-monitor] ${msg}`);
  }

  return {
    id: "com.example.tempmonitor",
    version: "1.0.0",

    onLoad(settings) {
      log("Temperature monitor loaded");
      // Load previous state from storage
      host.storage({
        type: "read",
        key: "history",
        namespace: "com.example.tempmonitor"
      });
    },

    onUnload() {
      log("Saving temperature history");
      host.storage({
        type: "write",
        key: "history",
        namespace: "com.example.tempmonitor",
        data: temperatureHistory
      });
    },

    onEvent(event) {
      if (event.name === "stateUpdate") {
        const temp = event.payload.groupTemperature;
        temperatureHistory.push({
          timestamp: Date.now(),
          temperature: temp
        });

        // Keep only last 100 readings
        if (temperatureHistory.length > 100) {
          temperatureHistory.shift();
        }

        // Emit if temperature exceeds threshold
        if (temp > 95) {
          host.emit("highTemperature", {
            temperature: temp,
            timestamp: Date.now()
          });
        }
      } else if (event.name === "storageRead") {
        if (event.payload.key === "history") {
          temperatureHistory = event.payload.value || [];
        }
      }
    }
  };
}
```

## Best Practices

1. **Error Handling**: Always wrap async operations in try-catch
2. **Resource Cleanup**: Clear timeouts/intervals in `onUnload()`
3. **Storage**: Use the plugin's ID as namespace for storage isolation
4. **Logging**: Use descriptive log messages with plugin identifier prefix
5. **Settings Validation**: Validate user settings in `onLoad()`
6. **State Management**: Keep plugin state in memory; persist to storage only what's necessary

## Development Workflow

1. Create a directory with your plugin ID (e.g., `myplugin.reaplugin/`)
2. Add `manifest.json` and `plugin.js` files
3. Test locally by placing in the app's plugin directory
4. Use `host.log()` for debugging
5. Package as a `.reaplugin` directory (or zip file) for distribution

## Machine Data Structure

When receiving `stateUpdate` events, the payload contains:

```javascript
{
  groupTemperature: 93.5,        // Current group head temperature (°C)
  targetGroupTemperature: 94.0,  // Target temperature (°C)
  mixTemperature: 92.8,          // Mix temperature (°C)
  targetMixTemperature: 93.5,    // Target mix temperature (°C)
  pressure: 9.2,                 // Current pressure (bar)
  targetPressure: 9.0,           // Target pressure (bar)
  flow: 2.1,                     // Current flow rate (ml/s)
  targetFlow: 2.0,               // Target flow rate (ml/s)
  state: {                       // Machine state
    substate: "preinfusion"      // Current substate
  },
  // Scale data if available
  scale: {
    weight: 18.5,                // Current weight (g)
    weightFlow: 1.8              // Weight-based flow rate (g/s)
  }
}
```

## Troubleshooting

### Common Issues

1. **Plugin not loading**: Check manifest `id` matches plugin directory name
2. **Storage not working**: Ensure `pluginStorage` permission is in manifest
3. **HTTP requests failing**: Verify network connectivity and CORS headers
4. **Events not received**: Check event names match exactly (case-sensitive)

### Debugging

- Use `host.log()` extensively during development
- Check Flutter app logs for JavaScript errors
- Test with simple plugins first, then add complexity
- When iterating, it helps to debug on a platform that can access Decaid
documents. This way, you can edit plugin source directly and simply reload
it in Decaid UI.

## API Reference

### Available in JavaScript Runtime

- **Global Functions**: `fetch()`, `btoa()`, `setTimeout()`, `clearTimeout()`
- **Objects**: `Promise`, `JSON`, `Math`, `Date`, `Array`, `Object`
- **Constants**: `undefined`, `null`, `Infinity`, `NaN`

### Not Available

- `XMLHttpRequest`, `FormData`, `Blob`, `FileReader`
- `localStorage`, `sessionStorage`, `indexedDB`
- DOM APIs (`document`, `window`, etc.)
- Node.js modules (`require`, `module`, `process`)

## Security Considerations

- Plugins run in a sandboxed JavaScript environment
- HTTP requests are proxied through Flutter (respects system proxy settings)
- Storage is isolated per plugin
- No filesystem access beyond the plugin's own directory
- No network access to localhost/private IPs (except for Decaid API)

## Reference Implementation: DYE2 Plugin

The DYE2 (Describe Your Espresso) plugin ships from its own repo, [decentespresso/dye2](https://github.com/decentespresso/dye2), as a release asset. CI and local setup install it by running `./scripts/fetch_dye2_plugin.sh`, which downloads a pinned release tag (`DYE2_VERSION` in the script), verifies its checksum (`DYE2_SHA256`) and manifest contract (`id`, `version`, `apiVersion`), and unpacks it into `assets/plugins/dye2.reaplugin/`. Bump the pinned version/checksum in a normal PR when DYE2 ships a new release.

`packages/dye2-plugin/` still holds the plugin's original TypeScript + Vite source and is useful as a reference for advanced patterns (REST API client, HTML template rendering, Vite dev server — see `packages/dye2-plugin/README.md`), but it is **not** built or bundled by Decaid anymore and is not authoritative for what ships. Treat [decentespresso/dye2](https://github.com/decentespresso/dye2) as the source of truth for the DYE2 plugin; update `packages/dye2-plugin/` only if it's being kept in sync deliberately.

## Distribution and Updates

A plugin can be installed from four sources:

| Source | Tracked | Updates |
|--------|---------|---------|
| GitHub release | yes | new release tag |
| GitHub branch | yes | new commit on the branch |
| Local ZIP | no | none, it is a snapshot |
| Local folder | no | none, it is a snapshot |

Every install goes through the same validation: the package must resolve to a
single plugin root holding both `manifest.json` and `plugin.js`, the manifest
must parse, and the id must be a single safe path component. A GitHub archive or
a release ZIP may wrap its content in one directory; more than one candidate
root is rejected rather than guessed.

Provenance for a tracked install is stored in a Decaid-owned
`.rea_source.json` inside the plugin directory. It is not part of your plugin
package, it is rewritten on every install, and it disappears when the plugin is
removed.

### Packaging a release

For a GitHub release install:

- tag the release `X.Y.Z` or `vX.Y.Z`;
- the tag must equal `manifest.json`'s `version` after removing the leading `v`,
  so `v1.4.0` requires `"version": "1.4.0"`. A mismatch is rejected;
- attach exactly one `.zip` asset holding the plugin, either flat or inside one
  wrapper directory. If a release carries several `.zip` assets, the installer
  refuses to guess and the caller must name the asset.

Branch installs have no tag rule. The resolved commit is the update signal, so a
branch-backed plugin updates when the branch moves even if `version` never
changes.

```bash
curl -X POST http://tablet:8080/api/v1/plugins/install/github-release \
  -H 'content-type: application/json' \
  -d '{"repo": "acme/my-plugin"}'

curl -X POST http://tablet:8080/api/v1/plugins/install/github-branch \
  -H 'content-type: application/json' \
  -d '{"repo": "acme/my-plugin", "branch": "dev"}'
```

### Update rules

Tracked plugins are checked on the app's normal update cadence, next to WebUI
skin updates, and on demand from the Plugins settings screen or
`POST /api/v1/plugins/update`. For each plugin:

- an unchanged tag or commit only refreshes `lastChecked`;
- a changed tag or commit is downloaded and validated before anything installed
  is touched. A branch is resolved to a commit first and that commit's archive
  is what gets downloaded, so a branch that moves mid-check cannot install
  contents the recorded SHA does not describe;
- an update must carry the plugin being updated: a candidate whose manifest id
  differs from the installed plugin is rejected before anything is touched;
- downgrade protection applies to release and branch updates alike: a lower
  version is rejected, and going back requires removing the plugin first. A
  moved branch whose manifest version is unchanged still updates;
- the swap is transactional. The plugin is unloaded only once the replacement is
  ready, and a failed copy or a failed reload restores the previous files,
  manifest and running plugin;
- settings, secure settings and the auto-load preference survive an update. A
  running plugin is restarted on the new version; a disabled one stays disabled;
- one plugin's failure never stops the others; the failure is recorded in
  `lastError`.

### Bundled plugins

A bundled plugin is copied out of the app at startup and stays the app-owned
floor: a newer bundled version replaces an older installed copy, an equal or
older one does not.

Bundled plugins published from a GitHub repo also take part in normal update
checks. `bundledPluginRepos` in `plugin_source_service.dart` maps the plugin id
to its canonical repo - today `dye2.reaplugin` to
[decentespresso/dye2](https://github.com/decentespresso/dye2) - and the first
update check or visit to the Plugins screen seeds `.rea_source.json` for it as
a `github_release` source tagged with the installed manifest version. Existing
installs from before source tracking are seeded the same way, so DYE2 starts
receiving releases without a reinstall. The seeder also realigns the recorded
tag when a newer bundled copy has been laid down, and never touches metadata
that points somewhere else, so a plugin the user pointed at their own fork or
branch keeps that source.

No asset name is recorded for a bundled seed: DYE2 names its release asset
after the version (`dye2.reaplugin-<version>.zip`), so pinning today's name
would break tomorrow's release. The installer picks the release's single
`.zip`, and a release with several zip assets asks for an explicit choice.

### Permission escalation

An automatic update installs only when the candidate manifest requests the same
permissions as the installed version or fewer. If it asks for anything new, the
update is not installed. It is recorded as a `pendingUpdate` carrying the
candidate version and the added permissions, shown in the Plugins settings
screen and in `GET /api/v1/plugins`, and installed only after explicit approval:

```bash
curl -X POST http://tablet:8080/api/v1/plugins/my.reaplugin/update/approve
```

Approval is bound to the exact candidate that was reviewed. The pending release
tag or commit is the fetch target, not "whatever is latest now", and the fetched
candidate is revalidated - same plugin id, same version, no permission beyond
the approved ones - before anything is installed. A source that moved between
detection and approval is refused with a 409, the new candidate is recorded as
the pending update, and its delta has to be approved in turn.

A pending update the app has already overtaken is cleared: when a newer bundled
copy lands at or above the pending version, the stale approval prompt goes away.
A genuinely newer pending update is kept.

Trusting a repository is not the same as trusting a new permission, so this
holds regardless of where the plugin came from.

## Plugin Lifecycle Management (REST API)

Plugins can be managed via REST API:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/v1/plugins` | List all plugins (includes `loaded`, `autoLoad`, `source`, `pendingUpdate` fields) |
| POST | `/api/v1/plugins/:id/enable` | Load plugin + enable auto-load on startup |
| POST | `/api/v1/plugins/:id/disable` | Unload plugin + disable auto-load |
| PUT | `/api/v1/plugins/:id/source` | Create or overwrite `manifest.json` + `plugin.js` |
| DELETE | `/api/v1/plugins/:id` | Remove plugin (unload + delete files) |
| POST | `/api/v1/plugins/install` | Not supported (501); use the GitHub endpoints below |
| POST | `/api/v1/plugins/install/github-release` | Install from a GitHub release asset |
| POST | `/api/v1/plugins/install/github-branch` | Install from a GitHub branch |
| POST | `/api/v1/plugins/update` | Check every GitHub-backed plugin for updates |
| POST | `/api/v1/plugins/:id/update/approve` | Install an update that requests new permissions |
| GET | `/api/v1/plugins/:id/settings` | Get plugin settings |
| POST | `/api/v1/plugins/:id/settings` | Update plugin settings |

`PUT /api/v1/plugins/:id/source` writes `manifest.json` and `plugin.js` for
that id, creating the plugin if it is not installed yet:

```bash
curl -X PUT http://tablet:8080/api/v1/plugins/my.reaplugin/source \
  -H 'content-type: application/json' \
  -d '{"manifest": {"id": "my.reaplugin", "name": "My plugin", "author": "me", "description": "", "version": "1.1.0", "apiVersion": 1, "permissions": ["log"], "settings": {}, "api": []}, "plugin": "function createPlugin() { return { id: \"my.reaplugin\", onLoad() {} }; }"}'
```

Rules:

- The manifest id must match the path id (400 otherwise).
- The update is partial. Only `manifest.json` and `plugin.js` are written; any
  other file in the plugin directory survives. Plugins that need new extra
  files still have to be installed from a directory.
- Downgrades are rejected with 409. The submitted version must be greater than
  or equal to the installed version; installing an older version requires
  removing the plugin first. Versions compare as semantic versions, so
  `1.0.0-rc.1` ranks below `1.0.0`. The same comparison decides whether a
  bundled plugin replaces an installed copy at startup.
- The swap is transactional for a loaded plugin: it is unloaded, replaced, and
  reloaded, and if the new source fails to load the previous manifest, source,
  and running plugin are restored and the request returns 500.
- A plugin that was not loaded stays unloaded, and its new source is not
  executed or validated.
- Stored settings and the auto-load preference are preserved.
- Overwriting a bundled plugin holds only until the next app start, where the
  bundled copy wins if its version is higher.
- Updates, installs, removals, loads, and unloads for one plugin id are
  serialized against each other.
- Like `/settings`, this path shadows a plugin-declared endpoint named
  `source`.

The endpoint accepts arbitrary JavaScript that Decaid then runs in-process. It
is not covered by the account-proxy bearer token, so anyone who can reach the
API server on the LAN can install or replace plugin code. Run the API server
only on networks you trust.

Settings updates are patches for every field: an omitted field preserves the
existing value, `null` clears it, and for secure fields a `{ "isSet":
true|false }` marker preserves the stored credential. GET and POST responses
contain only the marker for secure fields, never the submitted or stored
value. Existing cleartext secure fields are moved out of SharedPreferences on
first read.

The bundled **settings plugin** (`settings.reaplugin`) provides a web UI for plugin management at `/api/v1/plugins/settings.reaplugin/ui`. It includes an enable/disable toggle and remove button for each plugin, with a self-protection guard that prevents disabling itself.

## Next Steps

1. Review the example plugins in `assets/plugins/` and the DYE2 plugin at [decentespresso/dye2](https://github.com/decentespresso/dye2)
2. Start with a simple plugin that logs `stateUpdate` events
3. Add settings and persistent storage
4. Implement HTTP communication with external services
5. Emit custom events for the Flutter UI to display

For questions or issues, refer to the example plugins or check the app logs for error messages.
