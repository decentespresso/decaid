# 1108 — Embedded skin switching via `decentApp.switchSkin`

## Port-propagation audit (current `main`)

- `lib/src/app.dart:574` builds `SkinView(port: widget.webUIService.port)` once, inside the
  `onGenerateRoute` page builder. The route is built when `/skin` is pushed and is not rebuilt
  when the WebUI server restarts, so `widget.port` keeps the value read at push time.
- `SkinView` derives `_skinUrl` and every navigation decision
  (`classifySkinNavigation(..., skinPort: widget.port)`, `SkinExitCoordinator.tryStart`,
  `SkinCameraWebViewAccess` target match) from `widget.port`.
- `WebUIService.serveFolderAtPath` assigns a per-skin stable port and writes `this.port`
  (`webui_service.dart:340`). Nothing notifies the mounted `SkinView`.

Conclusion: a skin change made while the embedded view is mounted leaves the view on the old
port. The old page's navigation to the new origin is classified `openExternal`, which launches
the system browser — the reported bug.

## Design

1. `WebUIService` exposes `serveGeneration` (`ValueListenable<int>`), incremented after each
   successful `serveFolderAtPath`. `port` stays a plain field read after the bump.
2. `app.dart` wraps the `/skin` route in `skinViewForServeGeneration`, which rebuilds and
   re-keys the subtree on each generation. The new port becomes authoritative in that builder:
   a new `SkinView` (and therefore a new `InAppWebView`, new attempt token, new classification
   port) is created for the port the service is serving now. The old generation is disposed,
   so no stale callback can accept navigation.
3. The skin-api script gains `window.decentApp.switchSkin(skinId)`, which navigates the top
   frame to `/__decent/switch-skin?id=<skinId>` on its own origin. `classifySkinNavigation`
   classifies that URL as `SkinNavDecision.switchSkin` only for the active skin port; the
   navigation is always cancelled, so the page never unloads itself and the call needs no
   await. Trust is enforced natively: main frame only, top-level URI equal to the active skin
   origin, no user-info. `window.__DECENT_HOST__` is not consulted.
4. `SkinSwitchCoordinator` (single-flight) resolves the installed skin, no-ops on the already
   served skin, restarts the server through the existing `serveFolderAtPath`, persists the
   default skin, and re-serves the previous skin on failure.
5. No REST/WS command, no plugin capability, no generic reload API.

## Tests

- `webui_service`: `serveGeneration` bumps per serve; script contains `switchSkin`.
- `classifySkinNavigation`: switch URL on the active port, rejection for port 3000, other
  ports, other paths, external origins.
- `SkinSwitchCoordinator`: unknown id, same skin, single-flight, failure restore.
- `skinViewForServeGeneration`: rebuilds with the current port and discards old state.
