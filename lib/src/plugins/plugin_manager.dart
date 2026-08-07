import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_js/flutter_js.dart';
import 'package:logging/logging.dart';

import 'plugin_manifest.dart';
import 'plugin_decent_proxy_bridge.dart';
import 'plugin_runtime.dart';
import 'plugin_types.dart';
import '../services/storage/kv_store_service.dart';
import '../controllers/de1_controller.dart';
import '../models/device/de1_interface.dart';
import '../models/device/machine.dart';
import '../services/account/decent_proxy_service.dart';

enum _PendingOpKind { fetch, pluginHttp, decentProxy }

enum PluginManagerLifecycle { active, disposing, disposed }

class _PendingOp {
  _PendingOp({
    required this.kind,
    required this.pluginId,
    required this.generation,
    required this.requestId,
  });

  final _PendingOpKind kind;
  final String pluginId;
  final int generation;
  final String requestId;

  Timer? timeout;
  HttpClientRequest? request;
  Completer<Map<String, dynamic>>? completer;

  String get key => '${kind.name}:$requestId';
}

class PluginHttpError implements Exception {
  final String message;

  const PluginHttpError(this.message);

  @override
  String toString() => message;
}

class PluginManager {
  final _log = Logger("PluginManager");

  final Map<String, PluginRuntime> _plugins = {};
  final JavascriptRuntime js;
  final KeyValueStoreService kvStore;
  final DecentProxyService? decentProxyService;
  late final PluginDecentProxyBridge _decentProxyBridge;
  final Map<String, String> _decentProxyBridgeTokens = {};

  final StreamController<Map<String, dynamic>> _emitController =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get emitStream => _emitController.stream;

  final Duration fetchTimeout;
  final int maxFetchResponseBytes;
  final Duration pluginHttpTimeout;
  final Duration decentProxyTimeout;

  De1Controller? _de1controller;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  Future<void> _attachmentQueue = Future.value();
  Future<void> _snapshotQueue = Future.value();
  int _attachmentGeneration = 0;
  PluginManagerLifecycle _lifecycle = PluginManagerLifecycle.active;
  Future<void>? _disposeFuture;

  De1Controller? get de1Controller => _de1controller;
  PluginManagerLifecycle get lifecycle => _lifecycle;
  int get attachmentGeneration => _attachmentGeneration;
  int get activeSubscriptionCount =>
      (_de1Subscription == null ? 0 : 1) +
      (_snapshotSubscription == null ? 0 : 1);
  int get trackedPluginGenerationCount => _pluginGenerations.length;
  int get bridgeTokenCount => _decentProxyBridgeTokens.length;
  int? pluginGeneration(String pluginId) => _pluginGenerations[pluginId];

  PluginManager({
    required this.kvStore,
    this.decentProxyService,
    this.fetchTimeout = const Duration(seconds: 30),
    this.maxFetchResponseBytes = 10 * 1024 * 1024,
    this.pluginHttpTimeout = const Duration(seconds: 30),
    this.decentProxyTimeout = const Duration(seconds: 30),
    JavascriptRuntime? js,
  }) : js = js ?? getJavascriptRuntime(xhr: false) {
    _decentProxyBridge = PluginDecentProxyBridge(
      decentProxyService: decentProxyService,
      log: _log,
    );
    // js.enableHandlePromises();
    // js.enableXhr();
    // js.enableFetch();
    _bootstrapJs();
  }

  void _ensureActive() {
    if (_lifecycle != PluginManagerLifecycle.active) {
      throw StateError('PluginManager is ${_lifecycle.name}');
    }
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;

    _lifecycle = PluginManagerLifecycle.disposing;
    _attachmentGeneration += 1;
    final disposal = _dispose();
    _disposeFuture = disposal;
    return disposal;
  }

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> runStage(String name, FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
        _log.warning(
          'PluginManager disposal failed during $name',
          error,
          stackTrace,
        );
      }
    }

    try {
      await runStage('attachment queue', () => _attachmentQueue);
      await runStage('snapshot queue', () => _snapshotQueue);
      await runStage('controller detachment', _cancelControllerSubscriptions);
      for (final pluginId in _plugins.keys.toList()) {
        await runStage(
          'plugin unload: $pluginId',
          () => _unloadPlugin(pluginId),
        );
      }
      await runStage('async operation cleanup', _cancelAllOperations);
      await runStage('bridge cleanup', () {
        JavascriptRuntime.channelFunctionsRegistered.remove(
          js.getEngineInstanceId(),
        );
      });
      await runStage('event stream closure', _emitController.close);
      await runStage('JavaScript runtime disposal', js.dispose);
    } finally {
      for (final record in _timers.values) {
        record.timer.cancel();
      }
      _timers.clear();
      for (final op in _pendingOps.values) {
        op.timeout?.cancel();
        try {
          op.request?.abort();
        } catch (_) {}
      }
      _pendingOps.clear();
      _httpClient?.close(force: true);
      _httpClient = null;
      _plugins.clear();
      _pluginGenerations.clear();
      _decentProxyBridgeTokens.clear();
      _de1Subscription = null;
      _snapshotSubscription = null;
      _de1controller = null;
      _lifecycle = PluginManagerLifecycle.disposed;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  // ─────────────────────────────────────────────
  // JS bootstrap (ONCE)
  // ─────────────────────────────────────────────

  void _bootstrapJs() {
    js.evaluate(r'''
      (function () {
        if (globalThis.__plugins__) return;

        globalThis.__plugins__ = Object.create(null);
        
        // Add HTTP response handling
        const __nativeSendMessage = sendMessage;
        const __nativeJsonStringify = JSON.stringify.bind(JSON);
        const __NativePromise = Promise;
        const __NativeError = Error;
        const __nativeFreeze = Object.freeze.bind(Object);
        const __nativeReflectApply = Reflect.apply.bind(Reflect);
        const __nativePromiseThen = Promise.prototype.then;
        const __nativePromiseCatch = Promise.prototype.catch;
        const __nativePromiseFinally = Promise.prototype.finally;
        const __nativeMapHas = Map.prototype.has;
        const __nativeMapGet = Map.prototype.get;
        const __nativeMapSet = Map.prototype.set;
        const __nativeMapDelete = Map.prototype.delete;

        const __pendingDecentProxyRequests = new Map();
        let __decentProxySeq = 0;
        const __decentProxyNonce =
          Date.now().toString(36) + "_" + Math.random().toString(36).slice(2);

        function __mapHas(map, key) {
          return __nativeReflectApply(__nativeMapHas, map, [key]);
        }

        function __mapGet(map, key) {
          return __nativeReflectApply(__nativeMapGet, map, [key]);
        }

        function __mapSet(map, key, value) {
          return __nativeReflectApply(__nativeMapSet, map, [key, value]);
        }

        function __mapDelete(map, key) {
          return __nativeReflectApply(__nativeMapDelete, map, [key]);
        }

        function __pendingDecentProxyByPlugin(pluginId) {
          if (!__mapHas(__pendingDecentProxyRequests, pluginId)) {
            __mapSet(__pendingDecentProxyRequests, pluginId, new Map());
          }
          return __mapGet(__pendingDecentProxyRequests, pluginId);
        }

        function __sendHostMessage(message) {
          __nativeSendMessage("host", __nativeJsonStringify(message));
        }

        function __wrapDecentProxyPromise(promise) {
          const wrapped = {
            then(onFulfilled, onRejected) {
              return __nativeReflectApply(__nativePromiseThen, promise, [
                onFulfilled,
                onRejected
              ]);
            },
            catch(onRejected) {
              return __nativeReflectApply(__nativePromiseCatch, promise, [
                onRejected
              ]);
            }
          };
          if (typeof __nativePromiseFinally === "function") {
            wrapped.finally = function (onFinally) {
              return __nativeReflectApply(__nativePromiseFinally, promise, [
                onFinally
              ]);
            };
          }
          return __nativeFreeze(wrapped);
        }

        function __decentProxy(pluginId, generation, bridgeToken, path, method, query, body, contentType) {
          const requestId = "__decent_proxy_" + __decentProxyNonce + "_" + (++__decentProxySeq);
          const promise = new __NativePromise((resolve, reject) => {
            const pendingByPlugin = __pendingDecentProxyByPlugin(pluginId);
            __mapSet(pendingByPlugin, requestId, { generation: generation, resolve: resolve, reject: reject });
            try {
              __sendHostMessage({
                pluginId: pluginId,
                generation: generation,
                bridgeToken: bridgeToken,
                type: "decentProxy",
                requestId: requestId,
                path: path,
                method: method,
                query: query,
                body: body,
                contentType: contentType
              });
            } catch (e) {
              __mapDelete(pendingByPlugin, requestId);
              reject(e);
            }
          });
          return __wrapDecentProxyPromise(promise);
        }

        function __completeDecentProxyRequest(pluginId, requestId, response) {
          const pendingByPlugin = __mapGet(__pendingDecentProxyRequests, pluginId);
          if (!pendingByPlugin) return;
          const pending = __mapGet(pendingByPlugin, requestId);
          if (!pending) return;
          __mapDelete(pendingByPlugin, requestId);
          if (pendingByPlugin.size === 0) {
            __mapDelete(__pendingDecentProxyRequests, pluginId);
          }
          if (response && response.error) {
            pending.reject(new __NativeError(response.error));
            return;
          }
          pending.resolve(response);
        }

        function __cancelDecentProxyRequestsForPlugin(pluginId, error) {
          const pendingByPlugin = __mapGet(__pendingDecentProxyRequests, pluginId);
          if (!pendingByPlugin) return;
          __mapDelete(__pendingDecentProxyRequests, pluginId);
          for (const pending of pendingByPlugin.values()) {
            pending.reject(new __NativeError(error));
          }
        }

        function __cancelAllDecentProxyRequests(error) {
          for (const pluginId of Array.from(__pendingDecentProxyRequests.keys())) {
            __cancelDecentProxyRequestsForPlugin(pluginId, error);
          }
        }

        Object.defineProperty(globalThis, "__reaprimePluginBridge", {
          value: __nativeFreeze({
            decentProxy: __decentProxy,
            completeDecentProxyRequest: __completeDecentProxyRequest,
            cancelForPlugin: __cancelDecentProxyRequestsForPlugin,
            cancelAll: __cancelAllDecentProxyRequests
          }),
          writable: false,
          configurable: false,
          enumerable: false
        });
        
        globalThis.__sendApiResponse = function (pluginId, generation, requestId, response) {
          console.log("sending plugin api response", pluginId);
          sendMessage("host", JSON.stringify({
            pluginId: pluginId,
            generation: generation,
            type: "httpResponse",
            requestId: requestId,
            payload: response
          }));
        };

        // Provide btoa function if not available
        if (typeof globalThis.btoa === 'undefined') {
            globalThis.btoa = function (input) {
              // 1. Convert to string (per spec)
              const str = String(input);

              // 2. Reject non-Latin-1 characters
              for (let i = 0; i < str.length; i++) {
                if (str.charCodeAt(i) > 0xFF) {
                  throw new DOMException(
                    "The string to be encoded contains characters outside of the Latin1 range.",
                    "InvalidCharacterError"
                  );
                }
              }

              const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
              let output = "";
              let i = 0;

              // 3. Encode
              while (i < str.length) {
                const byte1 = str.charCodeAt(i++);
                const byte2 = i < str.length ? str.charCodeAt(i++) : undefined;
                const byte3 = i < str.length ? str.charCodeAt(i++) : undefined;

                const enc1 = byte1 >> 2;
                const enc2 = ((byte1 & 0x03) << 4) | (byte2 !== undefined ? byte2 >> 4 : 0);
                const enc3 = byte2 !== undefined
                  ? ((byte2 & 0x0f) << 2) | (byte3 !== undefined ? byte3 >> 6 : 0)
                  : 64;
                const enc4 = byte3 !== undefined ? (byte3 & 0x3f) : 64;

                output +=
                  chars.charAt(enc1) +
                  chars.charAt(enc2) +
                  (enc3 === 64 ? "=" : chars.charAt(enc3)) +
                  (enc4 === 64 ? "=" : chars.charAt(enc4));
              }

              return output;
            };
        }

        globalThis.__dispatchToPlugin = function (pluginId, evt) {
          const plugin = globalThis.__plugins__[pluginId];
          if (!plugin || typeof plugin.onEvent !== "function") return;
          try {
            plugin.onEvent(evt);
          } catch (e) {
            console.error("Plugin error", pluginId, e);
          }
        };

        // Timer bridge: JS holds callbacks, Dart owns real Timers.
        const __timers = new Map();
        let __timerSeq = 0;
        globalThis.__debugTimers = __timers;
        globalThis.__timerSet = function (pluginId, generation, callback, delay) {
          const id = ++__timerSeq;
          __timers.set(id, { pluginId: pluginId, generation: generation, callback: callback });
          __sendHostMessage({
            pluginId: pluginId,
            generation: generation,
            type: "timerSet",
            timerId: id,
            delay: Math.max(0, Math.trunc(Number(delay) || 0))
          });
          return id;
        };
        globalThis.__timerClear = function (pluginId, generation, id) {
          if (__timers.delete(id)) {
            __sendHostMessage({
              pluginId: pluginId,
              generation: generation,
              type: "timerClear",
              timerId: id
            });
          }
        };
        globalThis.__fireTimer = function (id) {
          const record = __timers.get(id);
          if (!record) return;
          try {
            record.callback();
          } finally {
            __timers.delete(id);
          }
        };
        globalThis.__cancelTimersForPlugin = function (pluginId) {
          for (const [id, record] of __timers) {
            if (record.pluginId === pluginId) __timers.delete(id);
          }
        };
        globalThis.__cancelAllTimers = function () {
          __timers.clear();
        };

        globalThis.host = {
          log(pluginId, generation, message) {
            sendMessage("host", JSON.stringify({
              pluginId: pluginId,
              generation: generation,
              type: "log",
              payload: { message: String(message) }
            }));
          },
          emit(pluginId, generation, eventName, payload) {
            sendMessage("host", JSON.stringify({
              pluginId: pluginId,
              generation: generation,
              type: "emit",
              event: eventName,
              payload: payload
            }));
          },
          storage(pluginId, generation, command) {
            sendMessage("host", JSON.stringify({
              pluginId: pluginId,
              generation: generation,
              type: "pluginStorage",
              payload: command
            }));
          }
        };
      })();
  ''');

    js.evaluate(r'''
      (function () {
        if (globalThis.fetch) return;

        let _fetchSeq = 0;
        const _pendingFetches = new Map();

        function makeHeaders(headersObj) {
          const map = new Map();
          for (const k in headersObj || {}) {
            map.set(k.toLowerCase(), String(headersObj[k]));
          }
          return {
            get(name) {
              return map.get(name.toLowerCase()) ?? null;
            }
          };
        }

        globalThis.__fetchFor = function (pluginId, generation, input, init = {}) {
          const id = ++_fetchSeq;
          return new Promise((resolve, reject) => {
            if (!pluginId) {
              reject(new Error("fetch is only available to plugins"));
              return;
            }
            _pendingFetches.set(id, { pluginId: pluginId, generation: generation, resolve: resolve, reject: reject });

            sendMessage("fetch", JSON.stringify({
              id,
              pluginId,
              generation,
              url: String(input),
              method: init.method || "GET",
              headers: init.headers || {},
              body: init.body ?? null
            }));
          });
        };

        globalThis.fetch = function fetch(input, init = {}) {
          return globalThis.__fetchFor(null, 0, input, init);
        };

        globalThis.__handleFetchResponse = function (msg) {
          const pending = _pendingFetches.get(msg.id);
          if (!pending) return;
          _pendingFetches.delete(msg.id);

          if (msg.error) {
            pending.reject(new Error(msg.error));
            return;
          }

          const headers = makeHeaders(msg.headers);

          const response = {
            status: msg.status,
            ok: msg.status >= 200 && msg.status < 300,
            headers,
            text: async () => msg.body ?? "",
            json: async () => JSON.parse(msg.body ?? "null")
          };
          pending.resolve(response);
        };

        globalThis.__cancelFetchesForPlugin = function (pluginId, error) {
          for (const [id, pending] of _pendingFetches) {
            if (pending.pluginId !== pluginId) continue;
            _pendingFetches.delete(id);
            pending.reject(new Error(error));
          }
        };

        globalThis.__cancelAllFetches = function (error) {
          for (const pending of _pendingFetches.values()) {
            pending.reject(new Error(error));
          }
          _pendingFetches.clear();
        };
      })();
    ''');

    js.onMessage("host", (raw) {
      try {
        _log.finest("receiving: $raw");
        final msg = raw as Map<String, dynamic>;
        final pluginId = msg['pluginId'] as String?;

        if (pluginId == null) {
          _log.warning("JS message missing pluginId");
          return;
        }

        unawaited(_handleMessageSafely(pluginId, msg));
      } catch (e, st) {
        _log.warning("Invalid JS message", e, st);
      }
    });

    js.onMessage("fetch", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        unawaited(_handleFetchSafely(msg));
      } catch (e, st) {
        _log.warning("Invalid fetch message", e, st);
      }
    });
  }

  Future<void> _handleMessageSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    // Yield before processing: channel callbacks run inside the JS evaluate
    // that sent the message, and a nested evaluate + job drain does not
    // settle promises on QuickJS (unhandled-rejection hang).
    await Future<void>.delayed(Duration.zero);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    try {
      final type = msg['type'];
      if (type == 'decentProxy') {
        await _handleDecentProxyMessage(pluginId, msg);
        return;
      }
      if (!_isCurrentPluginMessage(pluginId, msg)) return;
      if (type == 'log') {
        _log.finest("[JS:$pluginId] ${msg['payload']?['message']}");
        return;
      }
      if (type == 'httpResponse') {
        _handlePluginApiResponse(pluginId, msg);
        return;
      }
      await _handleMessage(pluginId, msg);
    } catch (e, st) {
      _log.warning("Error handling message from $pluginId", e, st);
    }
  }

  Future<void> _handleFetchSafely(Map<String, dynamic> msg) async {
    await Future<void>.delayed(Duration.zero);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    try {
      await _handleFetch(msg);
    } catch (e, st) {
      _log.warning("Invalid fetch message", e, st);
    }
  }

  bool _isCurrentPluginMessage(String pluginId, Map<String, dynamic> msg) {
    final generation = msg['generation'];
    return generation is num &&
        generation.toInt() == _pluginGenerations[pluginId] &&
        _plugins[pluginId]?.isAlive == true;
  }

  // ─────────────────────────────────────────────
  // Plugin lifecycle
  // ─────────────────────────────────────────────

  Future<void> loadPlugin({
    required String id,
    required PluginManifest manifest,
    required String jsCode,
    required Map<String, dynamic> settings,
  }) async {
    _ensureActive();
    await _unloadPlugin(id);
    _ensureActive();
    final generation = (_pluginGenerations[id] ?? 0) + 1;
    _pluginGenerations[id] = generation;

    final runtime = PluginRuntime(pluginId: id, manifest: manifest);
    final decentProxyBridgeToken = _newBridgeToken();

    _plugins[id] = runtime;
    _decentProxyBridgeTokens[id] = decentProxyBridgeToken;

    try {
      // Direct injection approach with standard factory name
      final wrapperCode =
          '''
      (function () {
        const pluginId = "$id";
        const pluginGeneration = $generation;
        const setTimeout = (callback, delay) => globalThis.__timerSet(pluginId, pluginGeneration, callback, delay);
        const clearTimeout = (id) => globalThis.__timerClear(pluginId, pluginGeneration, id);
        const fetch = (input, init) => globalThis.__fetchFor
          ? globalThis.__fetchFor(pluginId, pluginGeneration, input, init)
          : globalThis.fetch(input, init);
        
        // Create the host object for this plugin
        const host = {
          log: (msg) => globalThis.host.log(pluginId, pluginGeneration, msg),
          emit: (type, payload) => globalThis.host.emit(pluginId, pluginGeneration, type, payload),
          storage: (cmd) => globalThis.host.storage(pluginId, pluginGeneration, cmd),
          decentProxy: (path, options = {}) => {
            return globalThis.__reaprimePluginBridge.decentProxy(
              pluginId,
              pluginGeneration,
              ${jsonEncode(decentProxyBridgeToken)},
              path,
              options.method || "GET",
              options.query || {},
              options.body ?? null,
              options.contentType ?? null
            );
          }
        };
        
        // Inject and evaluate the plugin code
        $jsCode
        
        // The plugin must export a function named 'createPlugin'
        if (typeof createPlugin !== 'function') {
          throw new Error("Plugin must export a 'createPlugin' function. Got: " + typeof createPlugin);
        }
        
        // Call the factory function with the host object
        const plugin = createPlugin(host);
        
        if (!plugin || typeof plugin !== "object") {
          throw new Error("createPlugin did not return an object, got: " + typeof plugin);
        }
        
        // Verify the plugin has the required id
        if (plugin.id !== pluginId) {
          throw new Error("Plugin ID mismatch. Expected: " + pluginId + ", Got: " + plugin.id);
        }
        
        // Store the plugin object
        globalThis.__plugins__[pluginId] = plugin;
        
        // Add HTTP API handler if the plugin defines one
        if (typeof plugin.handleHttpRequest === "function") {
          // Register HTTP request handler
          plugin.__httpRequestHandler = plugin.handleHttpRequest;
        }
        
        // Call onLoad if it exists
        if (typeof plugin.onLoad === "function") {
          plugin.onLoad(${jsonEncode(settings)});
        }
        
        return plugin;
      })();
    ''';

      final result = js.evaluate(wrapperCode);
      _log.fine("Plugin evaluation result: ${result.stringResult}");
      _log.fine("Is error: ${result.isError}");

      if (result.isError) {
        throw Exception("JS evaluation error: ${result.stringResult}");
      }
      // Settle promise chains created synchronously during onLoad (e.g. a
      // rejected fetch or an already-resolved promise) regardless of engine.
      while (js.executePendingJob() > 0) {}

      runtime.markRunning();
      _log.info("loaded: $id");
    } catch (e, st) {
      try {
        await _unloadPlugin(id);
      } catch (cleanupError, cleanupStackTrace) {
        _log.warning(
          'Failed to clean up plugin after load failure: $id',
          cleanupError,
          cleanupStackTrace,
        );
      }
      // WARNING, not SEVERE: a plugin failing to load is almost always a
      // user-installed third-party plugin with a bad manifest id or a JS
      // syntax error, not an app defect. The caller (e.g. PluginsSettingsView)
      // surfaces the failure to the user. Keeping this at SEVERE escalated
      // every broken user plugin into Crashlytics crash signal (issue
      // e396ab1d — a catch-all cluster of unrelated plugin-load failures).
      _log.warning("Failed to load plugin $id", e, st);
      rethrow;
    }
  }

  Future<void> unloadPlugin(String id) async {
    _ensureActive();
    await _unloadPlugin(id);
  }

  Future<void> _unloadPlugin(String id) async {
    final runtime = _plugins[id];
    if (runtime == null) return;

    runtime.markStopping();
    _pluginGenerations[id] = (_pluginGenerations[id] ?? 0) + 1;
    _decentProxyBridgeTokens.remove(id);

    try {
      final result = js.evaluate('''
        (function () {
          const plugin = globalThis.__plugins__["$id"];
          try {
            plugin?.onUnload?.();
          } finally {
            delete globalThis.__plugins__["$id"];
          }
        })();
      ''');
      if (result.isError) {
        _log.warning('Plugin onUnload failed: $id: ${result.stringResult}');
      }
    } catch (e, st) {
      _log.warning("Error during plugin unload: $id", e, st);
    }

    try {
      _cleanupPluginResources(id);
    } finally {
      runtime.markDisposed();
      _plugins.remove(id);
      _log.info("unloaded: $id");
    }
  }

  void _cleanupPluginResources(String pluginId) {
    // Reject operations first: settling promises drains pending jobs, which
    // can run plugin rejection handlers that schedule new timers. The timer
    // sweep after must be the last word.
    Object? firstError;
    StackTrace? firstStackTrace;

    void attempt(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    attempt(() => _rejectOpsForPlugin(pluginId));
    attempt(() {
      js.evaluate('''
          globalThis.__cancelFetchesForPlugin(
            ${jsonEncode(pluginId)}, "plugin unloaded"
          );
          globalThis.__reaprimePluginBridge.cancelForPlugin(
            ${jsonEncode(pluginId)}, "plugin unloaded"
          );
        ''');
      while (js.executePendingJob() > 0) {}
    });
    attempt(() => _cancelTimersForPlugin(pluginId));

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  // ─────────────────────────────────────────────
  // Dart → JS events
  // ─────────────────────────────────────────────

  void broadcastEvent(String name, dynamic payload) {
    _ensureActive();
    for (final plugin in _plugins.values) {
      if (plugin.isAlive) {
        dispatchEvent(plugin.pluginId, name, payload);
      }
    }
  }

  void dispatchEvent(String pluginId, String name, dynamic payload) {
    _ensureActive();
    final runtime = _plugins[pluginId];
    if (runtime?.isAlive != true) return;
    final generation = _pluginGenerations[pluginId] ?? 0;

    String requestId = "";
    if (payload is Map<String, dynamic> && payload['requestId'] is String) {
      requestId = payload['requestId'];
    }

    js.evaluate('''
    __dispatchToPlugin("$pluginId", {
      name: "$name",
      payload: ${jsonEncode(payload)}
    });
    
    // Special handling for HTTP requests
    if ("$name" === "httpRequest") {
      const plugin = globalThis.__plugins__["$pluginId"];
      if (plugin && typeof plugin.__httpRequestHandler === "function") {
        try {
          const response = plugin.__httpRequestHandler(${jsonEncode(payload)});
          const responseThen = response.then;
          if (response &&  responseThen) {
            // Handle async response
            response.then((res) => {
              if (globalThis.__sendApiResponse) {
                globalThis.__sendApiResponse("$pluginId", $generation, "$requestId", res);
              }
            }).catch((err) => {
              console.error("HTTP request handler error:", err);
              if (globalThis.__sendApiResponse) {
                globalThis.__sendApiResponse("$pluginId", $generation, "$requestId", {
                  status: 500,
                  headers: {'Content-Type': 'application/json'},
                  body: JSON.stringify({error: err.toString()})
                });
              }
            });
          } else if (response) {
            // Handle sync response
            if (globalThis.__sendApiResponse) {
              globalThis.__sendApiResponse("$pluginId", $generation, "$requestId", response);
            }
          }
        } catch (e) {
          console.error("HTTP request handler error:", e);
          if (globalThis.__sendApiResponse) {
            globalThis.__sendApiResponse("$pluginId", $generation, "$requestId", {
              status: 500,
              headers: {'Content-Type': 'application/json'},
              body: JSON.stringify({error: e.toString()})
            });
          }
        }
      }
    }
  ''');
    while (js.executePendingJob() > 0) {}
  }

  // ─────────────────────────────────────────────
  // JS → Dart messages
  // ─────────────────────────────────────────────

  Future<void> _handleMessage(String pluginId, Map<String, dynamic> msg) async {
    _log.finest("handle message: $msg");
    final type = msg['type'];
    final payload = msg['payload'];

    switch (type) {
      case 'emit':
        final Map<String, dynamic> eventData = {
          'pluginId': pluginId,
          'event': msg['event'],
          'payload': payload,
        };
        _log.finest("emitting: $eventData");
        _emitController.add(eventData);
        break;

      case 'pluginStorage':
        final cmd = PluginStorageCommand.fromPlugin(payload);
        await _handlePluginStorage(
          pluginId,
          (msg['generation'] as num).toInt(),
          cmd,
        );
        break;

      case 'timerSet':
        _setTimer(
          pluginId,
          msg['generation'] is num ? (msg['generation'] as num).toInt() : 0,
          (msg['timerId'] as num?)?.toInt() ?? 0,
          (msg['delay'] as num?)?.toInt() ?? 0,
        );
        break;

      case 'timerClear':
        _clearTimer((msg['timerId'] as num?)?.toInt() ?? 0);
        break;

      case 'decentProxy':
        await _handleDecentProxyMessage(pluginId, msg);
        break;
    }
  }

  // ─────────────────────────────────────────────
  // Timers (JS callbacks, Dart-owned Timers)
  // ─────────────────────────────────────────────

  final Map<int, ({String pluginId, Timer timer})> _timers = {};

  int get activeTimerCount => _timers.length;

  Map<String, int> get activeTimersByPlugin {
    final counts = <String, int>{};
    for (final record in _timers.values) {
      counts[record.pluginId] = (counts[record.pluginId] ?? 0) + 1;
    }
    return counts;
  }

  void _setTimer(String pluginId, int generation, int id, int delayMs) {
    if (!_plugins.containsKey(pluginId)) return;
    // Deferred bridge messages can arrive after a reload; a timer from an
    // older generation must not register against the current plugin.
    if (generation != (_pluginGenerations[pluginId] ?? 0)) return;
    _timers[id] = (
      pluginId: pluginId,
      timer: Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), () {
        _fireTimer(id);
      }),
    );
  }

  void _clearTimer(int id) {
    _timers.remove(id)?.timer.cancel();
  }

  void _fireTimer(int id) {
    final record = _timers.remove(id);
    if (record == null) return;
    if (_lifecycle != PluginManagerLifecycle.active) return;
    js.evaluate('globalThis.__fireTimer($id);');
    while (js.executePendingJob() > 0) {}
  }

  void _cancelTimersForPlugin(String pluginId) {
    _timers.removeWhere((id, record) {
      if (record.pluginId == pluginId) {
        record.timer.cancel();
        return true;
      }
      return false;
    });
    js.evaluate('globalThis.__cancelTimersForPlugin(${jsonEncode(pluginId)});');
    while (js.executePendingJob() > 0) {}
  }

  void cancelAllOperations() {
    _ensureActive();
    _cancelAllOperations();
  }

  void _cancelAllOperations() {
    Object? firstError;
    StackTrace? firstStackTrace;

    void attempt(void Function() action) {
      try {
        action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    for (final op in _pendingOps.values.toList()) {
      attempt(() {
        _completeOp(op, error: 'manager disposal');
      });
    }
    attempt(() {
      _httpClient?.close(force: true);
      _httpClient = null;
    });
    attempt(() {
      js.evaluate('''
          globalThis.__cancelAllFetches("manager disposal");
          globalThis.__reaprimePluginBridge.cancelAll("manager disposal");
        ''');
      while (js.executePendingJob() > 0) {}
    });
    for (final record in _timers.values) {
      record.timer.cancel();
    }
    _timers.clear();
    attempt(() {
      js.evaluate('globalThis.__cancelAllTimers();');
      while (js.executePendingJob() > 0) {}
    });

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  // ─────────────────────────────────────────────
  // Pending operations (fetch, plugin HTTP, Decent proxy)
  // ─────────────────────────────────────────────

  final Map<String, _PendingOp> _pendingOps = {};
  final Map<String, int> _pluginGenerations = {};
  HttpClient? _httpClient;

  int get activePendingOpCount => _pendingOps.length;

  Map<String, int> get activePendingOpsByType {
    final counts = <String, int>{};
    for (final op in _pendingOps.values) {
      counts[op.kind.name] = (counts[op.kind.name] ?? 0) + 1;
    }
    return counts;
  }

  Map<String, int> get activePendingOpsByPlugin {
    final counts = <String, int>{};
    for (final op in _pendingOps.values) {
      counts[op.pluginId] = (counts[op.pluginId] ?? 0) + 1;
    }
    return counts;
  }

  HttpClient _getHttpClient() {
    return _httpClient ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
  }

  void _rejectOpsForPlugin(String pluginId) {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final op
        in _pendingOps.values.where((op) => op.pluginId == pluginId).toList()) {
      try {
        _completeOp(op, error: 'plugin unloaded');
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  void _completeOp(
    _PendingOp op, {
    Map<String, dynamic>? result,
    String? error,
  }) {
    op.timeout?.cancel();
    if (_pendingOps.remove(op.key) == null) return;
    final payload = error != null ? {'error': error} : result;
    switch (op.kind) {
      case _PendingOpKind.fetch:
        if (error != null) {
          try {
            op.request?.abort();
          } catch (_) {}
        }
        final fetchPayload = error != null
            ? {'id': int.parse(op.requestId), 'error': error}
            : result;
        js.evaluate(
          'globalThis.__handleFetchResponse(${jsonEncode(fetchPayload)});',
        );
        while (js.executePendingJob() > 0) {}
      case _PendingOpKind.pluginHttp:
        final completer = op.completer;
        if (completer == null || completer.isCompleted) return;
        if (error != null) {
          completer.completeError(PluginHttpError(error));
        } else {
          completer.complete(result);
        }
      case _PendingOpKind.decentProxy:
        js.evaluate(
          'globalThis.__reaprimePluginBridge.completeDecentProxyRequest('
          '${jsonEncode(op.pluginId)}, ${jsonEncode(op.requestId)}, '
          '${jsonEncode(payload)});',
        );
        while (js.executePendingJob() > 0) {}
    }
  }

  Future<void> _handleDecentProxyMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'] as String?;
    if (requestId == null) {
      _log.warning('Decent proxy message from $pluginId missing requestId');
      return;
    }
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    if (msg['bridgeToken'] != _decentProxyBridgeTokens[pluginId]) {
      _log.warning('Decent proxy message from $pluginId has invalid token');
      final op = _PendingOp(
        kind: _PendingOpKind.decentProxy,
        pluginId: pluginId,
        generation: generation,
        requestId: requestId,
      );
      _pendingOps[op.key] = op;
      _completeOp(op, error: 'Invalid plugin proxy caller');
      return;
    }

    if (generation != _pluginGenerations[pluginId] ||
        _plugins[pluginId]?.isAlive != true) {
      final op = _PendingOp(
        kind: _PendingOpKind.decentProxy,
        pluginId: pluginId,
        generation: generation,
        requestId: requestId,
      );
      _pendingOps[op.key] = op;
      _completeOp(op, error: 'Plugin generation changed');
      return;
    }

    final op = _PendingOp(
      kind: _PendingOpKind.decentProxy,
      pluginId: pluginId,
      generation: generation,
      requestId: requestId,
    );
    op.timeout = Timer(decentProxyTimeout, () {
      _completeOp(op, error: 'Decent proxy request timed out');
    });
    _pendingOps[op.key] = op;

    try {
      final response = await proxyDecentApiForManifest(
        pluginId: pluginId,
        manifest: _plugins[pluginId]?.manifest,
        path: msg['path'] as String?,
        method: (msg['method'] as String?) ?? 'GET',
        query: _stringMap(msg['query']),
        body: msg['body'] as String?,
        contentType: msg['contentType'] as String?,
      );
      _completeOp(op, result: response);
    } catch (e) {
      _completeOp(op, error: e.toString());
    }
  }

  String _newBridgeToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  Future<Map<String, dynamic>> proxyDecentApiForManifest({
    required String pluginId,
    required PluginManifest? manifest,
    required String? path,
    String method = 'GET',
    Map<String, String>? query,
    String? body,
    String? contentType,
  }) async {
    _ensureActive();
    return _decentProxyBridge.proxyForPlugin(
      pluginId: pluginId,
      manifest: manifest,
      path: path,
      method: method,
      query: query,
      body: body,
      contentType: contentType,
    );
  }

  Map<String, String>? _stringMap(dynamic value) {
    if (value is! Map) return null;
    final out = <String, String>{};
    value.forEach((key, value) {
      if (value != null) {
        out[key.toString()] = value.toString();
      }
    });
    return out.isEmpty ? null : out;
  }

  Future<void> _handlePluginStorage(
    String pluginId,
    int generation,
    PluginStorageCommand cmd,
  ) async {
    // Use pluginId as namespace for storage isolation
    final namespace = pluginId;

    switch (cmd.type) {
      case PluginStorageCommandType.read:
        final value = await kvStore.get(key: cmd.key, namespace: namespace);
        if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
          return;
        }
        dispatchEvent(pluginId, "storageRead", {
          "key": cmd.key,
          "value": value,
        });
        break;

      case PluginStorageCommandType.write:
        await kvStore.set(key: cmd.key, namespace: namespace, value: cmd.data);
        if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
          return;
        }
        dispatchEvent(pluginId, "storageWrite", cmd.data);
        break;
    }
  }

  void _handlePluginApiResponse(String pluginId, Map<String, dynamic> msg) {
    final requestId = msg['requestId'] as String?;
    final response = msg['payload'] as Map<String, dynamic>?;

    if (requestId == null || response == null) {
      _log.warning("Invalid HTTP response from plugin $pluginId");
      return;
    }

    final op = _pendingOps['${_PendingOpKind.pluginHttp.name}:$requestId'];
    if (op == null) {
      _log.fine(
        'Late or unknown HTTP response for request $requestId from $pluginId',
      );
      return;
    }
    final generation = msg['generation'];
    if (op.pluginId != pluginId ||
        generation is! num ||
        generation.toInt() != op.generation ||
        generation.toInt() != _pluginGenerations[pluginId]) {
      return;
    }
    _completeOp(op, result: response);
  }

  Future<Map<String, dynamic>> registerPendingHttp(
    String pluginId,
    String requestId,
  ) {
    _ensureActive();
    if (_plugins[pluginId]?.isAlive != true) {
      throw StateError('Plugin is not loaded: $pluginId');
    }
    final op = _PendingOp(
      kind: _PendingOpKind.pluginHttp,
      pluginId: pluginId,
      generation: _pluginGenerations[pluginId] ?? 0,
      requestId: requestId,
    );
    final completer = Completer<Map<String, dynamic>>();
    op.completer = completer;
    op.timeout = Timer(pluginHttpTimeout, () {
      _completeOp(op, error: 'Plugin did not respond in time');
    });
    _pendingOps[op.key] = op;
    return completer.future;
  }

  // ─────────────────────────────────────────────
  // External API (UNCHANGED)
  // ─────────────────────────────────────────────

  List<PluginRuntime> get loadedPlugins => _plugins.values.toList();

  Future<void> attachDe1Controller(De1Controller? controller) {
    _ensureActive();
    final generation = ++_attachmentGeneration;
    final attachment = _attachmentQueue.then(
      (_) => _replaceDe1Controller(controller, generation),
    );
    _attachmentQueue = attachment.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return attachment;
  }

  Future<void> _replaceDe1Controller(
    De1Controller? controller,
    int generation,
  ) async {
    await _cancelControllerSubscriptions();
    if (_lifecycle != PluginManagerLifecycle.active ||
        generation != _attachmentGeneration) {
      return;
    }

    _de1controller = controller;
    if (controller == null) return;

    _de1Subscription = controller.de1.listen((de1) {
      if (_lifecycle != PluginManagerLifecycle.active ||
          generation != _attachmentGeneration) {
        return;
      }
      final replacement = _snapshotQueue.then(
        (_) => _replaceSnapshotSubscription(de1, generation),
      );
      _snapshotQueue = replacement.then<void>(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          _log.warning(
            'Failed to replace plugin snapshot subscription',
            error,
            stackTrace,
          );
        },
      );
    });
  }

  Future<void> _replaceSnapshotSubscription(
    De1Interface? de1,
    int generation,
  ) async {
    final previous = _snapshotSubscription;
    _snapshotSubscription = null;
    await previous?.cancel();
    if (_lifecycle != PluginManagerLifecycle.active ||
        generation != _attachmentGeneration ||
        de1 == null) {
      return;
    }

    _snapshotSubscription = de1.currentSnapshot.listen((snapshot) {
      if (_lifecycle != PluginManagerLifecycle.active ||
          generation != _attachmentGeneration) {
        return;
      }
      broadcastEvent('stateUpdate', snapshot.toJson());
    });
  }

  Future<void> _cancelControllerSubscriptions() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final snapshot = _snapshotSubscription;
    _snapshotSubscription = null;
    try {
      await snapshot?.cancel();
    } catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }

    final de1 = _de1Subscription;
    _de1Subscription = null;
    try {
      await de1?.cancel();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    _de1controller = null;

    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _handleFetch(Map<String, dynamic> msg) async {
    _ensureActive();
    final id = msg['id'];
    final pluginId = msg['pluginId'] as String?;
    if (id is! int || pluginId == null) {
      _log.warning('Invalid fetch message');
      return;
    }
    if (!_plugins.containsKey(pluginId)) {
      js.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': 'plugin not loaded'})});',
      );
      while (js.executePendingJob() > 0) {}
      return;
    }
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    // Deferred bridge messages can arrive after a reload; a fetch from an
    // older generation must not start network work against the new plugin.
    if (generation != (_pluginGenerations[pluginId] ?? 0)) {
      js.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': 'plugin generation changed'})});',
      );
      while (js.executePendingJob() > 0) {}
      return;
    }

    final op = _PendingOp(
      kind: _PendingOpKind.fetch,
      pluginId: pluginId,
      generation: generation,
      requestId: id.toString(),
    );
    op.timeout = Timer(fetchTimeout, () {
      _completeOp(op, error: 'fetch timeout');
    });
    _pendingOps[op.key] = op;

    try {
      final response = await _performFetch(op, msg);
      _completeOp(op, result: response);
    } catch (e) {
      _completeOp(op, error: e.toString());
    }
  }

  Future<Map<String, dynamic>> _performFetch(
    _PendingOp op,
    Map<String, dynamic> msg,
  ) async {
    final uri = Uri.parse(msg['url'] as String);
    final method = ((msg['method'] as String?) ?? 'GET').toUpperCase();
    final headers = msg['headers'] as Map? ?? {};
    final body = msg['body'];

    final request = await _getHttpClient().openUrl(method, uri);
    op.request = request;
    headers.forEach((k, v) {
      request.headers.set(k.toString(), v.toString());
    });
    if (body != null) {
      request.add(
        body is String ? utf8.encode(body) : utf8.encode(jsonEncode(body)),
      );
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (acc, chunk) {
      if (acc.length + chunk.length > maxFetchResponseBytes) {
        throw StateError(
          'response exceeds maxFetchResponseBytes ($maxFetchResponseBytes)',
        );
      }
      return acc..addAll(chunk);
    });

    final responseHeaders = <String, String>{};
    response.headers.forEach((name, values) {
      responseHeaders[name] = values.join(', ');
    });
    return {
      'id': int.parse(op.requestId),
      'status': response.statusCode,
      'headers': responseHeaders,
      'body': utf8.decode(bytes, allowMalformed: true),
    };
  }
}
