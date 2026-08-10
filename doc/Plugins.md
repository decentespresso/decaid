
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
    "pluginStorage"
  ],
  "settings": {
    "SettingName": {
      "type": "string",
      "secure": false,
      "description": "Setting description"
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
  - `log`: Access to logging
  - `api`: Ability to make HTTP requests
  - `emit`: Emit events to the Flutter app
  - `pluginStorage`: Persistent storage
  - `proxy.decent_api`: Call the linked Decent account proxy through `host.decentProxy`
- **settings**: User-configurable options with `type` (`string`, `number`, `boolean`) and optional `secure` flag for credentials such as passwords. Secure values use platform credential storage, are supplied in memory to `onLoad(settings)`, and are never returned by the REST API.
- **api**: Events this plugin emits, used for documentation and type checking

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
Log messages to the Flutter app's logger.

### `host.emit(eventName, payload)`
Emit events to the Flutter app. These can be listened to by other parts of the application.

### `host.storage(command)`
Interact with persistent storage. Commands:
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
Call the Decent account proxy without exposing stored credentials to plugin code. `GET` requires the read-only `proxy.decent_api` permission. `POST` requires the distinct write permission `proxy.decent_api.write` **and** is restricted to an explicit path allowlist (currently only `support/api/shot_upload`); other methods/paths are rejected and logged.

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

The bundled Visualizer plugin merges recipe and shot-review tags, reads the current Visualizer tags before replacing them, and forwards later local edits in order. Visualizer tag writes require a Visualizer Premium account. The upload endpoint returns `202` with `visualizer_id` after the Visualizer upload succeeds while the tag PATCH continues in memory. Follow-up failures, including Visualizer's premium-account rejection, are reported through `shotForwardSyncError` and `forwardSyncStatus`; tag ownership and pending work are not restored after an app or plugin restart.

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

The DYE2 (Describe Your Espresso) plugin ships from its own repo, [allofmeng/dye2](https://github.com/allofmeng/dye2), as a release asset. CI and local setup install it by running `./scripts/fetch_dye2_plugin.sh`, which downloads a pinned release tag (`DYE2_VERSION` in the script), verifies its checksum (`DYE2_SHA256`) and manifest contract (`id`, `version`, `apiVersion`), and unpacks it into `assets/plugins/dye2.reaplugin/`. Bump the pinned version/checksum in a normal PR when DYE2 ships a new release.

`packages/dye2-plugin/` still holds the plugin's original TypeScript + Vite source and is useful as a reference for advanced patterns (REST API client, HTML template rendering, Vite dev server — see `packages/dye2-plugin/README.md`), but it is **not** built or bundled by Decaid anymore and is not authoritative for what ships. Treat [allofmeng/dye2](https://github.com/allofmeng/dye2) as the source of truth for the DYE2 plugin; update `packages/dye2-plugin/` only if it's being kept in sync deliberately.

## Plugin Lifecycle Management (REST API)

Plugins can be managed via REST API:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/v1/plugins` | List all plugins (includes `loaded`, `autoLoad` fields) |
| POST | `/api/v1/plugins/:id/enable` | Load plugin + enable auto-load on startup |
| POST | `/api/v1/plugins/:id/disable` | Unload plugin + disable auto-load |
| DELETE | `/api/v1/plugins/:id` | Remove plugin (unload + delete files) |
| POST | `/api/v1/plugins/install` | Install from URL (not yet implemented) |
| GET | `/api/v1/plugins/:id/settings` | Get plugin settings |
| POST | `/api/v1/plugins/:id/settings` | Update plugin settings |

Settings updates are patches for every field: an omitted field preserves the
existing value, `null` clears it, and for secure fields a `{ "isSet":
true|false }` marker preserves the stored credential. GET and POST responses
contain only the marker for secure fields, never the submitted or stored
value. Existing cleartext secure fields are moved out of SharedPreferences on
first read.

The bundled **settings plugin** (`settings.reaplugin`) provides a web UI for plugin management at `/api/v1/plugins/settings.reaplugin/ui`. It includes an enable/disable toggle and remove button for each plugin, with a self-protection guard that prevents disabling itself.

## Next Steps

1. Review the example plugins in `assets/plugins/` and the DYE2 plugin at [allofmeng/dye2](https://github.com/allofmeng/dye2)
2. Start with a simple plugin that logs `stateUpdate` events
3. Add settings and persistent storage
4. Implement HTTP communication with external services
5. Emit custom events for the Flutter UI to display

For questions or issues, refer to the example plugins or check the app logs for error messages.
