# Native plugin-owned device settings

Native device management consumes the validated driver-level surface with
`role: "settings"` through `PluginDeviceSurfaceAuthority`. The same authority
already belongs to Scale, Sensor, and Grinder adapters and fixes explicit plugin
ownership before a device instance exists; no parallel settings primitive is needed.

The native action resolves the host-built relative href against the app origin
`http://localhost:8080`, without rebuilding or re-encoding its query. Declared
surfaces are used without session availability filtering so a discovered device
can open settings before connecting. Activation checks device instance identity,
not just its public ID, to fence retired, replaced, and unloaded bindings.

The query is `ui=1`, `deviceId`, plus an optional display-only `deviceName`. Native
device management supplies the name to the shared authority so all query values
are encoded once. Names never select storage or establish ownership. Omitting the
name preserves existing hrefs, including connected Grinder info surfaces; an empty
name remains present as a bare `deviceName` query key, decoded as an empty string.
Existing plugin HTTP routing and namespaced KV storage own identity validation and
persistence. Native preferences only own
auto-connect selection; there is no native mirror store or device-ID-prefix routing.
