import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_js/flutter_js.dart';
import 'package:logging/logging.dart';

import 'plugin_manifest.dart';
import 'plugin_decent_proxy_bridge.dart';
import 'plugin_runtime.dart';
import 'plugin_transport_service.dart';
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
  final Map<String, String> _pluginBridgeTokens = {};
  final Map<String, String> _pluginIdsByBridgeToken = {};
  final Set<String> _loggedPermissionDenials = {};
  final Map<String, Set<PluginPermissions>> _closingPluginPermissions = {};

  final StreamController<Map<String, dynamic>> _emitController =
      StreamController.broadcast();

  Stream<Map<String, dynamic>> get emitStream => _emitController.stream;

  final Duration fetchTimeout;
  final int maxFetchResponseBytes;
  final Duration pluginHttpTimeout;
  final Duration decentProxyTimeout;
  final Duration transportCloseTimeout;

  De1Controller? _de1controller;
  StreamSubscription<De1Interface?>? _de1Subscription;
  StreamSubscription<MachineSnapshot>? _snapshotSubscription;
  Future<void> _attachmentQueue = Future.value();
  Future<void> _snapshotQueue = Future.value();
  int _attachmentGeneration = 0;
  int _snapshotGeneration = 0;
  PluginManagerLifecycle _lifecycle = PluginManagerLifecycle.active;
  Future<void>? _disposeFuture;
  final Map<String, int> _retiringPluginGenerations = {};
  final Map<(String, int), Set<Future<void>>> _pluginStorageOperations = {};
  late final PluginTransportService _transportService;

  De1Controller? get de1Controller => _de1controller;
  PluginManagerLifecycle get lifecycle => _lifecycle;
  int get liveTransportCount => _transportService.liveTransportCount;
  int get attachmentGeneration => _attachmentGeneration;
  int get activeSubscriptionCount =>
      (_de1Subscription == null ? 0 : 1) +
      (_snapshotSubscription == null ? 0 : 1);
  int get trackedPluginGenerationCount => _pluginGenerations.length;
  int get bridgeTokenCount => _pluginBridgeTokens.length;
  int? pluginGeneration(String pluginId) => _pluginGenerations[pluginId];

  PluginManager({
    required this.kvStore,
    this.decentProxyService,
    this.fetchTimeout = const Duration(seconds: 30),
    this.maxFetchResponseBytes = 10 * 1024 * 1024,
    this.pluginHttpTimeout = const Duration(seconds: 30),
    this.decentProxyTimeout = const Duration(seconds: 30),
    JavascriptRuntime? js,
    WebSocketConnector? connectWebSocket,
    SocketConnector? connectSocket,
    SecureSocketConnector? connectSecureSocket,
    this.transportCloseTimeout = const Duration(seconds: 5),
  }) : js = js ?? getJavascriptRuntime(xhr: false) {
    _decentProxyBridge = PluginDecentProxyBridge(
      decentProxyService: decentProxyService,
      log: _log,
    );
    _transportService = PluginTransportService(
      eventSink: _dispatchTransportEvent,
      connectWebSocket: connectWebSocket,
      connectSocket: connectSocket,
      connectSecureSocket: connectSecureSocket,
      closeTimeout: transportCloseTimeout,
    );
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
      _retiringPluginGenerations.clear();
      _pluginStorageOperations.clear();
      _pluginBridgeTokens.clear();
      _pluginIdsByBridgeToken.clear();
      _de1Subscription = null;
      _snapshotSubscription = null;
      _de1controller = null;
      _lifecycle = PluginManagerLifecycle.disposed;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  bool _hasPermission(String pluginId, PluginPermissions permission) {
    final permissions =
        _plugins[pluginId]?.manifest.permissions ??
        _closingPluginPermissions[pluginId];
    final allowed = permissions?.contains(permission) ?? false;
    if (!allowed) {
      final denial = '$pluginId:${permission.wireName}';
      if (_loggedPermissionDenials.add(denial)) {
        _log.warning(
          'Plugin $pluginId denied permission ${permission.wireName}',
        );
      }
    }
    return allowed;
  }

  String _permissionError(String pluginId, PluginPermissions permission) =>
      'PluginPermissionError: Plugin $pluginId requires manifest permission ${permission.wireName}';

  String? _pluginIdForBridgeMessage(Map<String, dynamic> msg, String channel) {
    final token = msg['bridgeToken'];
    final pluginId = token is String ? _pluginIdsByBridgeToken[token] : null;
    if (pluginId == null) {
      _log.warning(
        'Rejected $channel message with invalid plugin bridge token',
      );
      return null;
    }
    final claimedPluginId = msg['pluginId'];
    if (claimedPluginId != null && claimedPluginId != pluginId) {
      _log.warning(
        'Rejected $channel message claiming plugin $claimedPluginId as $pluginId',
      );
      return null;
    }
    return pluginId;
  }

  void _removePluginBridgeToken(String pluginId) {
    final token = _pluginBridgeTokens.remove(pluginId);
    if (token != null) _pluginIdsByBridgeToken.remove(token);
  }

  void _bootstrapJs() {
    js.evaluate(r'''
      (function () {
        "use strict";
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
        const __nativePromiseResolve = Promise.resolve;
        const __nativePromiseCatch = Promise.prototype.catch;
        const __nativePromiseFinally = Promise.prototype.finally;
        const __nativeMapHas = Map.prototype.has;
        const __nativeMapGet = Map.prototype.get;
        const __nativeMapSet = Map.prototype.set;
        const __nativeMapDelete = Map.prototype.delete;
        const __nativeMapClear = Map.prototype.clear;
        const __nativeMapForEach = Map.prototype.forEach;

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

        function __mapClear(map) {
          return __nativeReflectApply(__nativeMapClear, map, []);
        }

        function __mapForEach(map, callback) {
          return __nativeReflectApply(__nativeMapForEach, map, [callback]);
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
            const error = new __NativeError(response.error);
            if (response.code) error.code = response.code;
            pending.reject(error);
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
        
        function __sendApiResponse(bridgeToken, generation, requestId, response) {
          __sendHostMessage({
            bridgeToken: bridgeToken,
            generation: generation,
            type: "httpResponse",
            requestId: requestId,
            payload: response
          });
        }

        function __sendApiError(bridgeToken, generation, requestId, error) {
          __sendApiResponse(bridgeToken, generation, requestId, {
            status: 500,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ error: String(error) })
          });
        }

        Object.defineProperty(globalThis, "__dispatchPluginHttp", {
          value: function (pluginId, bridgeToken, generation, requestId, event) {
            const plugin = globalThis.__plugins__[pluginId];
            if (!plugin || typeof plugin.__httpRequestHandler !== "function") return;
            try {
              const response = plugin.__httpRequestHandler(event);
              if (response && typeof response.then === "function") {
                const promise = __nativeReflectApply(
                  __nativePromiseResolve,
                  __NativePromise,
                  [response]
                );
                __nativeReflectApply(__nativePromiseThen, promise, [
                  (result) => __sendApiResponse(bridgeToken, generation, requestId, result),
                  (error) => __sendApiError(bridgeToken, generation, requestId, error)
                ]);
              } else if (response) {
                __sendApiResponse(bridgeToken, generation, requestId, response);
              }
            } catch (error) {
              __sendApiError(bridgeToken, generation, requestId, error);
            }
          },
          writable: false,
          configurable: false,
          enumerable: false
        });

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
        Object.defineProperty(globalThis, "__debugTimerCount", {
          value: () => __timers.size,
          writable: false,
          configurable: false,
          enumerable: false
        });
        globalThis.__timerSet = function (bridgeToken, generation, callback, delay) {
          const id = ++__timerSeq;
          __timers.set(id, { bridgeToken: bridgeToken, generation: generation, callback: callback });
          __sendHostMessage({
            bridgeToken: bridgeToken,
            generation: generation,
            type: "timerSet",
            timerId: id,
            delay: Math.max(0, Math.trunc(Number(delay) || 0))
          });
          return id;
        };
        globalThis.__timerClear = function (bridgeToken, id) {
          const record = __timers.get(id);
          if (record && record.bridgeToken === bridgeToken && __timers.delete(id)) {
            __sendHostMessage({
              bridgeToken: bridgeToken,
              generation: record.generation,
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
        Object.defineProperty(globalThis, "__cancelTimersForBridgeToken", {
          value: function (bridgeToken) {
            for (const [id, record] of __timers) {
              if (record.bridgeToken === bridgeToken) __timers.delete(id);
            }
          },
          writable: false,
          configurable: false,
          enumerable: false
        });
        globalThis.__cancelAllTimers = function () {
          __timers.clear();
        };

        const __transportListeners = new Map();
        const __transportPending = new Map();
        function __sendTransportMessage(message) {
          __nativeSendMessage("transport", __nativeJsonStringify(message));
        }

        const __frozenTransportGlobal = (name, value) => {
          Object.defineProperty(globalThis, name, {
            value: value,
            writable: false,
            configurable: false,
            enumerable: false
          });
        };
        __frozenTransportGlobal("__transportRequest", function (bridgeToken, generation, requestId, type, payload) {
          __sendTransportMessage({
            bridgeToken: bridgeToken,
            generation: generation,
            requestId: requestId,
            type: type,
            payload: payload
          });
        });
        __frozenTransportGlobal("__transportRegister", function (requestId, entry) {
          __mapSet(__transportPending, requestId, entry);
        });
        __frozenTransportGlobal("__transportSetListener", function (handle, pluginId, listener) {
          __mapSet(__transportListeners, handle, { pluginId: pluginId, listener: listener });
        });
        __frozenTransportGlobal("__transportRemoveListener", function (handle) {
          __mapDelete(__transportListeners, handle);
        });
        __frozenTransportGlobal("__handleTransportReply", function (msg) {
          const pending = __mapGet(__transportPending, msg.requestId);
          if (!pending || pending.bridgeToken !== msg.bridgeToken) return;
          __mapDelete(__transportPending, msg.requestId);
          if (msg.error) {
            const error = new __NativeError(msg.error);
            if (msg.code) error.code = msg.code;
            pending.reject(error);
            return;
          }
          pending.resolve(msg.result || {});
        });
        __frozenTransportGlobal("__dispatchTransportEvent", function (pluginId, handle, event) {
          const record = __mapGet(__transportListeners, handle);
          if (!record || record.pluginId !== pluginId || !record.listener) return;
          try {
            record.listener(event);
          } catch (e) {
            console.error("Transport listener error", pluginId, e);
          }
        });
        __frozenTransportGlobal("__rejectTransportPendingForToken", function (bridgeToken, error) {
          __mapForEach(__transportPending, (pending, requestId) => {
            if (pending.bridgeToken !== bridgeToken) return;
            __mapDelete(__transportPending, requestId);
            pending.reject(new __NativeError(error));
          });
        });
        __frozenTransportGlobal("__rejectAllTransportPending", function (error) {
          __mapForEach(__transportPending, (pending) => {
            pending.reject(new __NativeError(error));
          });
          __mapClear(__transportPending);
        });
        __frozenTransportGlobal("__clearTransportListenersForPlugin", function (pluginId) {
          __mapForEach(__transportListeners, (record, handle) => {
            if (record.pluginId === pluginId) __mapDelete(__transportListeners, handle);
          });
        });
        __frozenTransportGlobal("__clearAllTransportListeners", function () {
          __mapClear(__transportListeners);
        });

        Object.defineProperty(globalThis, "host", {
          value: __nativeFreeze({
            log(bridgeToken, generation, message) {
              __sendHostMessage({
                bridgeToken: bridgeToken,
                generation: generation,
                type: "log",
                payload: { message: String(message) }
              });
            },
            emit(bridgeToken, generation, eventName, payload) {
              __sendHostMessage({
                bridgeToken: bridgeToken,
                generation: generation,
                type: "emit",
                event: eventName,
                payload: payload
              });
            },
            storage(bridgeToken, generation, command) {
              __sendHostMessage({
                bridgeToken: bridgeToken,
                generation: generation,
                type: "pluginStorage",
                payload: command
              });
            },
            permissionDenied(bridgeToken, generation, permission) {
              __sendHostMessage({
                bridgeToken: bridgeToken,
                generation: generation,
                type: "permissionDenied",
                payload: permission
              });
            }
          }),
          writable: false,
          configurable: false,
          enumerable: true
        });
      })();
  ''');

    js.evaluate(r'''
      (function () {
        "use strict";
        if (globalThis.fetch) return;

        const nativeSendMessage = sendMessage;
        const nativeJsonStringify = JSON.stringify.bind(JSON);
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

        globalThis.__fetchFor = function (bridgeToken, generation, input, init = {}) {
          const id = ++_fetchSeq;
          return new Promise((resolve, reject) => {
            if (!bridgeToken) {
              reject(new Error("fetch is only available to plugins"));
              return;
            }
            _pendingFetches.set(id, { bridgeToken: bridgeToken, generation: generation, resolve: resolve, reject: reject });

            nativeSendMessage("fetch", nativeJsonStringify({
              id,
              bridgeToken,
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

        globalThis.__cancelFetchesForBridgeToken = function (bridgeToken, error) {
          for (const [id, pending] of _pendingFetches) {
            if (pending.bridgeToken !== bridgeToken) continue;
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

        Object.defineProperty(globalThis, "__lockPluginHostBridge", {
          value: function () {
            if (globalThis.__reaprimePluginHostBridge) return;
            Object.defineProperty(globalThis, "__reaprimePluginHostBridge", {
              value: Object.freeze({
                log: globalThis.host.log,
                emit: globalThis.host.emit,
                storage: globalThis.host.storage,
                permissionDenied: globalThis.host.permissionDenied,
                fetch: globalThis.__fetchFor,
                timerSet: globalThis.__timerSet,
                timerClear: globalThis.__timerClear,
                transportRequest: globalThis.__transportRequest
              }),
              writable: false,
              configurable: false,
              enumerable: false
            });
          },
          writable: false,
          configurable: false,
          enumerable: false
        });
      })();
    ''');

    js.onMessage("host", (raw) {
      try {
        _log.finest("receiving: $raw");
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(msg, 'host');

        if (pluginId == null) {
          return;
        }

        final operation = _handleMessageSafely(pluginId, msg);
        final generation = _messageGeneration(pluginId, msg);
        if (msg['type'] == 'pluginStorage' && generation != null) {
          _trackPluginStorageOperation(pluginId, generation, operation);
        } else {
          unawaited(operation);
        }
      } catch (e, st) {
        _log.warning("Invalid JS message", e, st);
      }
    });

    js.onMessage("fetch", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(msg, 'fetch');
        if (pluginId != null) {
          unawaited(_handleFetchSafely(pluginId, msg));
        }
      } catch (e, st) {
        _log.warning("Invalid fetch message", e, st);
      }
    });

    js.onMessage("transport", (raw) {
      try {
        final msg = raw as Map<String, dynamic>;
        final pluginId = _pluginIdForBridgeMessage(msg, 'transport');
        if (pluginId != null) {
          unawaited(_handleTransportSafely(pluginId, msg));
        }
      } catch (e, st) {
        _log.warning("Invalid transport message", e, st);
      }
    });
  }

  Future<void> _handleMessageSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final retiringStorageWrite = _isRetiringPluginStorageWrite(pluginId, msg);
    if (_lifecycle != PluginManagerLifecycle.active && !retiringStorageWrite) {
      return;
    }
    try {
      final type = msg['type'];
      if (type == 'log') {
        if (_messageGeneration(pluginId, msg) != _pluginGenerations[pluginId] ||
            !_plugins.containsKey(pluginId)) {
          return;
        }
        if (_hasPermission(pluginId, PluginPermissions.log)) {
          _log.finest("[JS:$pluginId] ${msg['payload']?['message']}");
        }
        return;
      }
      await Future<void>.delayed(Duration.zero);
      if (type == 'decentProxy') {
        await _handleDecentProxyMessage(pluginId, msg);
        return;
      }
      if (!_isCurrentPluginMessage(pluginId, msg) && !retiringStorageWrite) {
        return;
      }
      if (type == 'httpResponse') {
        if (_hasPermission(pluginId, PluginPermissions.api)) {
          _handlePluginApiResponse(pluginId, msg);
        }
        return;
      }
      final permission = switch (type) {
        'emit' => PluginPermissions.emit,
        'pluginStorage' => PluginPermissions.pluginStorage,
        _ => null,
      };
      if (permission == null || _hasPermission(pluginId, permission)) {
        await _handleMessage(pluginId, msg);
      }
    } catch (e, st) {
      _log.warning("Error handling message from $pluginId", e, st);
    }
  }

  Future<void> _handleFetchSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    await Future<void>.delayed(Duration.zero);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    try {
      await _handleFetch(pluginId, msg);
    } catch (e, st) {
      _log.warning("Invalid fetch message", e, st);
    }
  }

  Future<void> _handleTransportSafely(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    await Future<void>.delayed(Duration.zero);
    if (_lifecycle != PluginManagerLifecycle.active) return;
    try {
      await _handleTransportMessage(pluginId, msg);
    } catch (e, st) {
      _log.warning("Invalid transport message", e, st);
    }
  }

  Future<void> _handleTransportMessage(
    String pluginId,
    Map<String, dynamic> msg,
  ) async {
    final requestId = msg['requestId'];
    if (requestId is! String) {
      _log.warning('Transport message from $pluginId missing requestId');
      return;
    }
    final bridgeToken = msg['bridgeToken'];
    final generation = msg['generation'] is num
        ? (msg['generation'] as num).toInt()
        : 0;
    if (generation != _pluginGenerations[pluginId] ||
        _plugins[pluginId]?.isAlive != true) {
      _replyTransport(
        requestId,
        bridgeToken,
        error: 'Plugin generation changed',
      );
      return;
    }
    final type = msg['type'];
    final payload = msg['payload'];
    if (payload is! Map) {
      _replyTransport(
        requestId,
        bridgeToken,
        error: 'Invalid transport message payload',
      );
      return;
    }
    try {
      switch (type) {
        case 'open':
          final kind = payload['kind'];
          final permission = switch (kind) {
            'websocket' => PluginPermissions.networkWebsocket,
            'tcp' => PluginPermissions.networkTcp,
            'tls' => PluginPermissions.networkTls,
            _ => null,
          };
          if (permission == null) {
            _replyTransport(
              requestId,
              bridgeToken,
              error: 'Unknown transport kind',
            );
            return;
          }
          if (!_hasPermission(pluginId, permission)) {
            _replyTransport(
              requestId,
              bridgeToken,
              error: _permissionError(pluginId, permission),
            );
            return;
          }
          final result = await _transportService.open(
            pluginId: pluginId,
            generation: generation,
            options: Map<String, dynamic>.from(payload),
          );
          if (!_isCurrentPluginMessage(pluginId, {'generation': generation})) {
            unawaited(
              _transportService
                  .close(pluginId, generation, result.handle)
                  .catchError((Object _) {}),
            );
            return;
          }
          _replyTransport(
            requestId,
            bridgeToken,
            result: {
              'handle': result.handle,
              if (result.protocol != null) 'protocol': result.protocol,
            },
          );
        case 'send':
          final handle = payload['handle'];
          final sendPayload = payload['payload'];
          if (handle is! String || sendPayload is! Map) {
            _replyTransport(
              requestId,
              bridgeToken,
              error: 'Invalid transport send message',
            );
            return;
          }
          await _transportService.send(
            pluginId,
            generation,
            handle,
            Map<String, dynamic>.from(sendPayload),
          );
          _replyTransport(requestId, bridgeToken, result: const {});
        case 'close':
          final handle = payload['handle'];
          if (handle is! String) {
            _replyTransport(
              requestId,
              bridgeToken,
              error: 'Invalid transport close message',
            );
            return;
          }
          await _transportService.close(pluginId, generation, handle);
          _replyTransport(requestId, bridgeToken, result: const {});
        case 'onEvent':
          final handle = payload['handle'];
          if (handle is String) {
            try {
              _transportService.onEventRegistered(pluginId, generation, handle);
            } on PluginTransportException {
              _removeTransportListener(handle);
            }
          }
        default:
          _log.warning('Unknown transport message type from $pluginId: $type');
      }
    } on PluginTransportException catch (e) {
      _replyTransport(requestId, bridgeToken, error: e.message, code: e.code);
    } catch (e) {
      _replyTransport(requestId, bridgeToken, error: e.toString());
    }
  }

  void _replyTransport(
    String requestId,
    Object? bridgeToken, {
    Map<String, dynamic>? result,
    String? error,
    String? code,
  }) {
    try {
      js.evaluate(
        'globalThis.__handleTransportReply('
        '${jsonEncode({'requestId': requestId, 'bridgeToken': ?bridgeToken, 'result': result, 'error': error, 'code': code})});',
      );
      while (js.executePendingJob() > 0) {}
    } catch (e, st) {
      _log.warning('Failed to deliver transport reply', e, st);
    }
  }

  void _dispatchTransportEvent(
    String pluginId,
    int generation,
    String handle,
    Map<String, dynamic> event,
  ) {
    if (_lifecycle != PluginManagerLifecycle.active) return;
    if (_plugins[pluginId]?.isAlive != true) return;
    if (_pluginGenerations[pluginId] != generation) return;
    try {
      js.evaluate(
        'globalThis.__dispatchTransportEvent('
        '${jsonEncode(pluginId)}, ${jsonEncode(handle)}, ${jsonEncode(event)});',
      );
      while (js.executePendingJob() > 0) {}
      if (event['type'] == 'close') {
        _removeTransportListener(handle);
      }
    } catch (e, st) {
      _log.warning('Failed to dispatch transport event to $pluginId', e, st);
    }
  }

  void _removeTransportListener(String handle) {
    try {
      js.evaluate(
        'globalThis.__transportRemoveListener(${jsonEncode(handle)});',
      );
      while (js.executePendingJob() > 0) {}
    } catch (e, st) {
      _log.warning('Failed to remove transport listener', e, st);
    }
  }

  int? _messageGeneration(String pluginId, Map<String, dynamic> msg) {
    final generation = msg['generation'];
    if (generation is num) return generation.toInt();
    final bridgeToken = msg['bridgeToken'];
    if (bridgeToken is! String ||
        _pluginIdsByBridgeToken[bridgeToken] != pluginId) {
      return null;
    }
    return _retiringPluginGenerations[pluginId] ?? _pluginGenerations[pluginId];
  }

  bool _isCurrentPluginMessage(String pluginId, Map<String, dynamic> msg) {
    return _messageGeneration(pluginId, msg) == _pluginGenerations[pluginId] &&
        _plugins[pluginId]?.isAlive == true;
  }

  bool _isRetiringPluginStorageWrite(
    String pluginId,
    Map<String, dynamic> msg,
  ) {
    final payload = msg['payload'];
    return msg['type'] == 'pluginStorage' &&
        _messageGeneration(pluginId, msg) ==
            _retiringPluginGenerations[pluginId] &&
        payload is Map &&
        payload['type'] == 'write' &&
        _plugins[pluginId]?.state == PluginRuntimeState.stopping;
  }

  void _trackPluginStorageOperation(
    String pluginId,
    int generation,
    Future<void> operation,
  ) {
    final key = (pluginId, generation);
    final operations = _pluginStorageOperations.putIfAbsent(key, () => {});
    operations.add(operation);
    unawaited(
      operation.whenComplete(() {
        operations.remove(operation);
        if (operations.isEmpty) _pluginStorageOperations.remove(key);
      }),
    );
  }

  Future<void> _drainPluginStorageOperations(
    String pluginId,
    int generation,
  ) async {
    final key = (pluginId, generation);
    while (true) {
      final operations = _pluginStorageOperations[key]?.toList() ?? const [];
      if (operations.isEmpty) return;
      await Future.wait(operations);
    }
  }

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
    js.evaluate('globalThis.__lockPluginHostBridge();');

    final runtime = PluginRuntime(pluginId: id, manifest: manifest);
    final pluginBridgeToken = _newBridgeToken();

    _plugins[id] = runtime;
    _pluginBridgeTokens[id] = pluginBridgeToken;
    _pluginIdsByBridgeToken[pluginBridgeToken] = id;

    try {
      final wrapperCode =
          '''
      (function () {
        const pluginId = "$id";
        const pluginGeneration = $generation;
        const pluginBridgeToken = ${jsonEncode(pluginBridgeToken)};
        const pluginHostBridge = globalThis.__reaprimePluginHostBridge;
        class PluginPermissionError extends Error {
          constructor(permission) {
            super("Plugin " + pluginId + " requires manifest permission " + permission);
            this.name = "PluginPermissionError";
          }
        }
        const requirePermission = (permission) => {
          pluginHostBridge.permissionDenied(pluginBridgeToken, pluginGeneration, permission);
          throw new PluginPermissionError(permission);
        };
        const rejectPermission = (permission) => {
          pluginHostBridge.permissionDenied(pluginBridgeToken, pluginGeneration, permission);
          return Promise.reject(new PluginPermissionError(permission));
        };
        const setTimeout = (callback, delay) => pluginHostBridge.timerSet(pluginBridgeToken, pluginGeneration, callback, delay);
        const clearTimeout = (id) => pluginHostBridge.timerClear(pluginBridgeToken, id);
        const fetch = ${manifest.permissions.contains(PluginPermissions.api)}
          ? (input, init) => pluginHostBridge.fetch(pluginBridgeToken, pluginGeneration, input, init)
          : () => rejectPermission("api");
        
        let __transportSeq = 0;
        const __transportNonce = Math.random().toString(36).slice(2);
        const __transportCall = (type, payload) => {
          return new Promise((resolve, reject) => {
            const requestId = pluginId + "_" + pluginGeneration + "_" + __transportNonce + "_" + (++__transportSeq);
            __transportRegister(requestId, { bridgeToken: pluginBridgeToken, resolve: resolve, reject: reject });
            pluginHostBridge.transportRequest(pluginBridgeToken, pluginGeneration, requestId, type, payload);
          });
        };
        const transport = {
          open(options) {
            const kind = options && options.kind;
            if (kind === "websocket" && !${manifest.permissions.contains(PluginPermissions.networkWebsocket)}) {
              return rejectPermission("network.websocket");
            }
            if (kind === "tcp" && !${manifest.permissions.contains(PluginPermissions.networkTcp)}) {
              return rejectPermission("network.tcp");
            }
            if (kind === "tls" && !${manifest.permissions.contains(PluginPermissions.networkTls)}) {
              return rejectPermission("network.tls");
            }
            if (kind !== "websocket" && kind !== "tcp" && kind !== "tls") {
              return Promise.reject(new Error("transport.open: unknown transport kind"));
            }
            return __transportCall("open", options || {});
          },
          onEvent(handle, callback) {
            if (typeof callback !== "function") {
              throw new Error("transport.onEvent: callback must be a function");
            }
            __transportSetListener(handle, pluginId, callback);
            pluginHostBridge.transportRequest(
              pluginBridgeToken, pluginGeneration, "onEvent_" + (++__transportSeq), "onEvent", { handle: handle }
            );
          },
          send(handle, payload) {
            return __transportCall("send", { handle: handle, payload: payload });
          },
          close(handle) {
            return __transportCall("close", { handle: handle });
          }
        };
        
        // Create the host object for this plugin
        const host = {
          log: ${manifest.permissions.contains(PluginPermissions.log)}
            ? (msg) => pluginHostBridge.log(pluginBridgeToken, pluginGeneration, msg)
            : () => requirePermission("log"),
          emit: ${manifest.permissions.contains(PluginPermissions.emit)}
            ? (type, payload) => pluginHostBridge.emit(pluginBridgeToken, pluginGeneration, type, payload)
            : () => requirePermission("emit"),
          storage: ${manifest.permissions.contains(PluginPermissions.pluginStorage)}
            ? (cmd) => pluginHostBridge.storage(pluginBridgeToken, pluginGeneration, cmd)
            : () => requirePermission("pluginStorage"),
          decentProxy: (path, options = {}) => {
            const method = String(options.method || "GET").toUpperCase();
            if (method === "GET" && !${manifest.permissions.contains(PluginPermissions.proxyDecentApi)}) {
              return rejectPermission("proxy.decent_api");
            }
            if (method === "POST" && !${manifest.permissions.contains(PluginPermissions.proxyDecentApiWrite)}) {
              return rejectPermission("proxy.decent_api.write");
            }
            return globalThis.__reaprimePluginBridge.decentProxy(
              pluginId,
              pluginGeneration,
              pluginBridgeToken,
              path,
              options.method || "GET",
              options.query || {},
              options.body ?? null,
              options.contentType ?? null
            );
          },
          transport: transport
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
      _log.warning("Failed to load plugin $id", e, st);
      rethrow;
    }
  }

  Future<void> unloadPlugin(String id) async {
    _ensureActive();
    await _unloadPlugin(id);
  }

  Future<void> _unloadPlugin(String id) async {
    _loggedPermissionDenials.removeWhere((denial) => denial.startsWith('$id:'));
    final pluginBridgeToken = _pluginBridgeTokens[id];
    final runtime = _plugins[id];
    if (runtime == null) {
      _removePluginBridgeToken(id);
      return;
    }
    _closingPluginPermissions[id] = runtime.manifest.permissions;

    final retiringGeneration = _pluginGenerations[id] ?? 0;
    runtime.markStopping();
    _retiringPluginGenerations[id] = retiringGeneration;
    _pluginGenerations[id] = retiringGeneration + 1;

    try {
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
        await _cleanupPluginResources(
          id,
          pluginBridgeToken,
          retiringGeneration,
        );
      } finally {
        await _drainPluginStorageOperations(id, retiringGeneration);
      }
    } finally {
      _retiringPluginGenerations.remove(id);
      runtime.markDisposed();
      _plugins.remove(id);
      _closingPluginPermissions.remove(id);
      _removePluginBridgeToken(id);
      _log.info("unloaded: $id");
    }
  }

  Future<void> _cleanupPluginResources(
    String pluginId,
    String? pluginBridgeToken,
    int retiringGeneration,
  ) async {
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
      final fetchCancellation = pluginBridgeToken == null
          ? ''
          : '''globalThis.__cancelFetchesForBridgeToken(
            ${jsonEncode(pluginBridgeToken)}, "plugin unloaded"
          );''';
      js.evaluate('''
        $fetchCancellation
        globalThis.__reaprimePluginBridge.cancelForPlugin(
          ${jsonEncode(pluginId)}, "plugin unloaded"
        );
        globalThis.__rejectTransportPendingForToken(
          ${jsonEncode(pluginBridgeToken)}, "plugin unloaded"
        );
        globalThis.__clearTransportListenersForPlugin(
          ${jsonEncode(pluginId)}
        );
      ''');
      while (js.executePendingJob() > 0) {}
    });
    attempt(() => _cancelTimersForPlugin(pluginId, pluginBridgeToken));
    try {
      await _transportService.closeAllForPlugin(pluginId, retiringGeneration);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

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
    final permission = switch (name) {
      'stateUpdate' => PluginPermissions.eventsMachine,
      'shotStored' || 'shotUpdated' => PluginPermissions.eventsShots,
      _ => null,
    };
    if (permission != null && !_hasPermission(pluginId, permission)) return;

    final requestIdValue = payload is Map<String, dynamic>
        ? payload['requestId']
        : null;
    final requestId = requestIdValue is String ? requestIdValue : null;
    final pluginBridgeToken = _pluginBridgeTokens[pluginId];
    final httpDispatch =
        name == 'httpRequest' && requestId != null && pluginBridgeToken != null
        ? '''globalThis.__dispatchPluginHttp(
          ${jsonEncode(pluginId)},
          ${jsonEncode(pluginBridgeToken)},
          $generation,
          ${jsonEncode(requestId)},
          ${jsonEncode(payload)}
        );'''
        : '';

    js.evaluate('''
    __dispatchToPlugin("$pluginId", {
      name: "$name",
      payload: ${jsonEncode(payload)}
    });
    $httpDispatch
  ''');
    while (js.executePendingJob() > 0) {}
  }

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
        final generation = _messageGeneration(pluginId, msg);
        if (generation == null) return;
        await _handlePluginStorage(pluginId, generation, cmd);
        break;

      case 'permissionDenied':
        final permission = payload is String
            ? PluginPermissions.fromString(payload)
            : null;
        if (permission != null) _hasPermission(pluginId, permission);
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
        _clearTimer(pluginId, (msg['timerId'] as num?)?.toInt() ?? 0);
        break;

      case 'decentProxy':
        await _handleDecentProxyMessage(pluginId, msg);
        break;
    }
  }

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
    if (generation != (_pluginGenerations[pluginId] ?? 0)) return;
    final existing = _timers[id];
    if (existing != null && existing.pluginId != pluginId) return;
    existing?.timer.cancel();
    _timers[id] = (
      pluginId: pluginId,
      timer: Timer(Duration(milliseconds: delayMs < 0 ? 0 : delayMs), () {
        _fireTimer(id);
      }),
    );
  }

  void _clearTimer(String pluginId, int id) {
    final record = _timers[id];
    if (record?.pluginId != pluginId) return;
    _timers.remove(id)?.timer.cancel();
  }

  void _fireTimer(int id) {
    final record = _timers.remove(id);
    if (record == null) return;
    if (_lifecycle != PluginManagerLifecycle.active) return;
    js.evaluate('globalThis.__fireTimer($id);');
    while (js.executePendingJob() > 0) {}
  }

  void _cancelTimersForPlugin(String pluginId, String? pluginBridgeToken) {
    _timers.removeWhere((id, record) {
      if (record.pluginId == pluginId) {
        record.timer.cancel();
        return true;
      }
      return false;
    });
    if (pluginBridgeToken != null) {
      js.evaluate(
        'globalThis.__cancelTimersForBridgeToken('
        '${jsonEncode(pluginBridgeToken)});',
      );
    }
    while (js.executePendingJob() > 0) {}
  }

  void cancelAllOperations() {
    _ensureActive();
    unawaited(
      _cancelAllOperations().catchError((Object error, StackTrace stackTrace) {
        _log.warning('cancelAllOperations failed', error, stackTrace);
      }),
    );
  }

  Future<void> _cancelAllOperations() async {
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
          globalThis.__rejectAllTransportPending("manager disposal");
          globalThis.__clearAllTransportListeners();
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
    try {
      await _transportService.dispose();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

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
    String? errorCode,
  }) {
    op.timeout?.cancel();
    if (_pendingOps.remove(op.key) == null) return;
    final payload = error != null
        ? {'error': error, 'code': ?errorCode}
        : result;
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
    if (msg['bridgeToken'] != _pluginBridgeTokens[pluginId]) {
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
    } on DecentProxyConsentDeniedException catch (e) {
      _completeOp(
        op,
        error: e.toString(),
        errorCode: DecentProxyConsentDeniedException.code,
      );
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
    final generation = _messageGeneration(pluginId, msg);
    if (op.pluginId != pluginId) {
      _log.warning(
        'Rejected HTTP response for $requestId from $pluginId; owned by ${op.pluginId}',
      );
      return;
    }
    if (generation != op.generation ||
        generation != _pluginGenerations[pluginId]) {
      _log.warning(
        'Rejected stale HTTP response for $requestId from $pluginId',
      );
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
      final snapshotGeneration = ++_snapshotGeneration;
      if (_lifecycle != PluginManagerLifecycle.active ||
          generation != _attachmentGeneration) {
        return;
      }
      final replacement = _snapshotQueue.then(
        (_) =>
            _replaceSnapshotSubscription(de1, generation, snapshotGeneration),
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
    int attachmentGeneration,
    int snapshotGeneration,
  ) async {
    final previous = _snapshotSubscription;
    _snapshotSubscription = null;
    await previous?.cancel();
    if (_lifecycle != PluginManagerLifecycle.active ||
        attachmentGeneration != _attachmentGeneration ||
        snapshotGeneration != _snapshotGeneration ||
        de1 == null) {
      return;
    }

    _snapshotSubscription = de1.currentSnapshot.listen((snapshot) {
      if (_lifecycle != PluginManagerLifecycle.active ||
          attachmentGeneration != _attachmentGeneration ||
          snapshotGeneration != _snapshotGeneration) {
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

  Future<void> _handleFetch(String pluginId, Map<String, dynamic> msg) async {
    _ensureActive();
    final id = msg['id'];
    if (id is! int) {
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
    if (generation != (_pluginGenerations[pluginId] ?? 0)) {
      js.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': 'plugin generation changed'})});',
      );
      while (js.executePendingJob() > 0) {}
      return;
    }
    if (!_hasPermission(pluginId, PluginPermissions.api)) {
      js.evaluate(
        'globalThis.__handleFetchResponse('
        '${jsonEncode({'id': id, 'error': _permissionError(pluginId, PluginPermissions.api)})});',
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
