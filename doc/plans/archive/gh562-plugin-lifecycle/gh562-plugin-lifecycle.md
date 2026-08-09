# Plugin subsystem disposal

## Context

PluginManager previously owned a JavaScript runtime, host bridges, controller subscriptions, timers, pending operations, and an event stream without a terminal lifecycle. PluginLoaderService also accepted new work indefinitely and the process-level application lifecycle never released either service.

## Decisions

- PluginManager and PluginLoaderService expose `active`, `disposing`, and `disposed` states and cache one teardown future.
- Disposal becomes terminal synchronously. Public mutation is rejected once teardown starts, while private cleanup can continue using JavaScript until runtime disposal.
- DE1 controller attachment is serialized. Controller and snapshot subscriptions are cancelled before replacements are installed, and both callbacks validate one monotonic attachment generation.
- Each plugin generation is invalidated before `onUnload`. Host messages carry that generation, so deferred messages cannot target a replacement plugin or recreate state during teardown. Storage writes from the retiring generation are the only permitted teardown messages and finish before the runtime is removed.
- Plugin unload uses JavaScript `finally` for registry deletion, rejects pending work, cancels bridge promises and timers, removes bridge tokens, and marks the Dart runtime disposed after host cleanup.
- Manager disposal detaches controllers, unloads every plugin, cancels remaining work, removes runtime channel registrations, closes the event stream, and calls `JavascriptRuntime.dispose()` exactly once.
- Loader disposal waits for accepted initialization and queued load work before delegating to manager disposal.
- The process-wide loader is disposed only for `AppLifecycleState.detached`. Backgrounding and keyed application restarts continue to reuse it.

## Runtime boundary

The pinned `flutter_js` API exposes synchronous `JavascriptRuntime.dispose()`. Decaid now calls that contract exactly once, but native JavaScriptCore and QuickJS allocation behavior inside `flutter_js` remains owned by that dependency and is not repaired here.
