import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import 'plugin_test_helpers.dart';

Future<Object?> runPluginResult(
  PluginManager manager, {
  required String id,
  required String jsBody,
  Set<PluginPermissions>? permissions,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final result = Completer<Object?>();
  final sub = manager.emitStream.listen((e) {
    if (!result.isCompleted) result.complete(e['payload']);
  });
  addTearDown(sub.cancel);
  await manager.loadPlugin(
    id: id,
    manifest: permissions == null
        ? testManifest(id)
        : testManifest(id, permissions: permissions),
    settings: {},
    jsCode:
        '''
      function createPlugin(host) {
        return {
          id: "$id",
          onLoad() {
            $jsBody
          }
        };
      }
    ''',
  );
  return result.future.timeout(timeout);
}

Future<HttpServer> startWsServer(
  FutureOr<void> Function(WebSocket ws) handler, {
  String? Function(List<String>)? protocolSelector,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(
          req,
          protocolSelector: protocolSelector,
        );
        await handler(ws);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (_) {}
  });
  addTearDown(() async => server.close(force: true));
  return server;
}

Future<ServerSocket> startTcpServer(
  void Function(Socket socket) handler,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    try {
      handler(socket);
    } catch (_) {}
  });
  addTearDown(() async => server.close());
  return server;
}

class _GatedWebSocket implements WebSocket {
  final List<Object> written = [];
  final List<Completer<void>> addStreamGates = [];
  bool failWrites = false;
  bool closed = false;
  @override
  int readyState = WebSocket.open;
  @override
  String? protocol = '';
  @override
  String extensions = '';
  @override
  int? closeCode;
  @override
  String? closeReason;
  @override
  Duration? pingInterval;

  @override
  void add(dynamic data) => written.add(data);

  @override
  Future<void> addStream(Stream<dynamic> stream) {
    stream.listen((data) => written.add(data));
    if (failWrites) {
      return Future.error(StateError('write failed'));
    }
    final gate = Completer<void>();
    addStreamGates.add(gate);
    return gate.future;
  }

  @override
  Future<void> close([int? code, String? reason]) {
    final hasPendingWrite = addStreamGates.any((gate) => !gate.isCompleted);
    if (hasPendingWrite) {
      return Future.error(StateError('StreamSink is bound to a stream'));
    }
    closed = true;
    closeCode = code;
    closeReason = reason;
    readyState = WebSocket.closed;
    return Future.value();
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<dynamic>.multi((controller) {}).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingSocket implements Socket {
  _RecordingSocket(this._inner);

  final Socket _inner;
  final List<String> calls = [];
  final List<Completer<void>> flushGates = [];

  Future<void> releaseFlush() async {
    final gate = flushGates.removeAt(0);
    gate.complete();
    await _inner.flush();
  }

  @override
  void add(List<int> data) {
    calls.add('add');
    _inner.add(data);
  }

  @override
  Future<void> flush() {
    calls.add('flush');
    final gate = Completer<void>();
    flushGates.add(gate);
    return gate.future;
  }

  @override
  Future<void> close() {
    calls.add('close');
    return _inner.close();
  }

  @override
  void destroy() {
    calls.add('destroy');
    _inner.destroy();
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    calls.add('listen');
    return _inner.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late PluginManager manager;

  setUp(() {
    manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      fetchTimeout: const Duration(seconds: 2),
    );
  });

  tearDown(() async => manager.dispose());

  group('permissions', () {
    test(
      'websocket open without network.websocket is rejected before connect',
      () async {
        var connections = 0;
        final server = await startWsServer((ws) {
          connections += 1;
        });
        final result = await runPluginResult(
          manager,
          id: 'perm.plugin',
          permissions: const {PluginPermissions.emit},
          jsBody:
              '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/x"
          }).then(
            () => host.emit("result", "unexpected"),
            (e) => host.emit("result", JSON.stringify({ name: e.name, message: e.message }))
          );
        ''',
        );

        final error = jsonDecode(result as String) as Map<String, dynamic>;
        expect(error['name'], 'PluginPermissionError');
        expect(error['message'], contains('network.websocket'));
        expect(connections, 0);
      },
    );

    test('tls open without network.tls is rejected before connect', () async {
      var connections = 0;
      final server = await startTcpServer((socket) {
        connections += 1;
      });
      final result = await runPluginResult(
        manager,
        id: 'perm.plugin',
        permissions: const {PluginPermissions.emit},
        jsBody:
            '''
          host.transport.open({
            kind: "tls",
            host: "127.0.0.1",
            port: ${server.port}
          }).then(
            () => host.emit("result", "unexpected"),
            (e) => host.emit("result", JSON.stringify({ name: e.name, message: e.message }))
          );
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['name'], 'PluginPermissionError');
      expect(error['message'], contains('network.tls'));
      expect(connections, 0);
    });

    test(
      'Dart rejects direct transport bridge open without permission',
      () async {
        var connections = 0;
        final server = await startTcpServer((socket) {
          connections += 1;
        });
        final result = await runPluginResult(
          manager,
          id: 'perm.plugin',
          permissions: const {PluginPermissions.emit},
          jsBody:
              '''
          __transportRegister("direct_1", {
            bridgeToken: pluginBridgeToken,
            resolve: (r) => host.emit("result", "unexpected"),
            reject: (e) => host.emit("result", JSON.stringify({ name: e.name, message: e.message, code: e.code }))
          });
          globalThis.__reaprimePluginHostBridge.transportRequest(
            pluginBridgeToken, 1, "direct_1", "open",
            { kind: "tcp", host: "127.0.0.1", port: ${server.port} }
          );
        ''',
        );

        final error = jsonDecode(result as String) as Map<String, dynamic>;
        expect(error['message'], contains('PluginPermissionError'));
        expect(error['message'], contains('network.tcp'));
        expect(connections, 0);
      },
    );

    test('unknown transport kind is rejected', () async {
      final result = await runPluginResult(
        manager,
        id: 'kind.plugin',
        permissions: const {PluginPermissions.emit},
        jsBody: '''
          host.transport.open({ kind: "udp" }).then(
            () => host.emit("result", "unexpected"),
            (e) => host.emit("result", JSON.stringify({ message: e.message }))
          );
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('unknown transport kind'));
    });
  });

  group('websocket', () {
    test('text frame round-trips with dataType text', () async {
      final server = await startWsServer((ws) {
        ws.listen((data) {
          try {
            ws.add(data);
          } catch (_) {}
        });
      });
      final result = await runPluginResult(
        manager,
        id: 'ws.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/echo"
          }).then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") {
                host.emit("result", JSON.stringify(event));
              }
            });
            host.transport.send(opened.handle, { type: "text", data: "hello echo" });
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
      );

      final event = jsonDecode(result as String) as Map<String, dynamic>;
      expect(event['type'], 'data');
      expect(event['dataType'], 'text');
      expect(event['data'], 'hello echo');
    });

    test('binary frame round-trips random bytes as base64', () async {
      final random = Random(42);
      final original = List<int>.generate(512, (_) => random.nextInt(256));
      final b64 = base64Encode(original);
      final server = await startWsServer((ws) {
        ws.listen((data) {
          try {
            ws.add(data);
          } catch (_) {}
        });
      });
      final result = await runPluginResult(
        manager,
        id: 'ws.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/echo"
          }).then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") {
                host.emit("result", JSON.stringify(event));
              }
            });
            host.transport.send(opened.handle, { type: "binary", data: "$b64" });
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
      );

      final event = jsonDecode(result as String) as Map<String, dynamic>;
      expect(event['dataType'], 'binary');
      expect(base64Decode(event['data'] as String), original);
    });

    test('subprotocol negotiation returns negotiated protocol', () async {
      final server = await startWsServer(
        (ws) {
          ws.listen((data) {
            try {
              ws.add(data);
            } catch (_) {}
          });
        },
        protocolSelector: (protocols) =>
            protocols.contains('mqtt') ? 'mqtt' : null,
      );
      final result = await runPluginResult(
        manager,
        id: 'ws.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/mqtt",
            protocols: ["mqtt"]
          }).then((opened) => {
            host.emit("result", JSON.stringify({ protocol: opened.protocol, handle: opened.handle }));
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
      );

      final opened = jsonDecode(result as String) as Map<String, dynamic>;
      expect(opened['protocol'], 'mqtt');
      expect(opened['handle'], isNotEmpty);
    });

    test(
      'receives text JSON from the loopback sensor snapshot endpoint',
      () async {
        final server = await startWsServer((ws) {
          ws.add(jsonEncode({'groupTemperature': 93.5, 'sensor': 'sensor-1'}));
          ws.listen((data) {});
        });
        final result = await runPluginResult(
          manager,
          id: 'ws.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          jsBody:
              '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/ws/v1/sensors/sensor-1/snapshot"
          }).then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") {
                host.emit("result", JSON.stringify(event));
              }
            });
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
        );

        final event = jsonDecode(result as String) as Map<String, dynamic>;
        expect(event['dataType'], 'text');
        final snapshot =
            jsonDecode(event['data'] as String) as Map<String, dynamic>;
        expect(snapshot['groupTemperature'], 93.5);
        expect(snapshot['sensor'], 'sensor-1');
      },
    );

    test('plugin-initiated close resolves and closes the connection', () async {
      final closed = Completer<void>();
      final server = await startWsServer((ws) {
        ws.listen(
          (data) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });
      final result = await runPluginResult(
        manager,
        id: 'ws.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/x"
          }).then((opened) => {
            return host.transport.close(opened.handle);
          }).then(() => host.emit("result", "closed"))
            .catch((e) => host.emit("result", "err:" + e.message));
        ''',
      );

      expect(result, 'closed');
      await closed.future.timeout(const Duration(seconds: 5));
    });

    test(
      'close waits for an accepted write before closing the socket',
      () async {
        final ws = _GatedWebSocket();
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          fetchTimeout: const Duration(seconds: 2),
          connectWebSocket: (url, {protocols}) async => ws,
        );
        addTearDown(manager.dispose);
        final sent = Completer<void>();
        final result = Completer<Object?>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'sent' && !sent.isCompleted) sent.complete();
          if (e['event'] == 'result' && !result.isCompleted) {
            result.complete(e['payload']);
          }
        });
        addTearDown(sub.cancel);
        await manager.loadPlugin(
          id: 'closera.plugin',
          manifest: testManifest(
            'closera.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode: '''
          function createPlugin(host) {
            return {
              id: "closera.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:1/x"
                }).then((opened) => {
                  return host.transport.send(opened.handle, { type: "text", data: "accepted" })
                    .then(() => { host.emit("sent", 1); return host.transport.close(opened.handle); });
                }).then(() => host.emit("result", "closed"));
              }
            };
          }
        ''',
        );
        await sent.future.timeout(const Duration(seconds: 5));
        expect(ws.addStreamGates, hasLength(1));
        expect(ws.closed, isFalse);
        ws.addStreamGates.single.complete();
        expect(
          await result.future.timeout(const Duration(seconds: 5)),
          'closed',
        );
        expect(ws.closed, isTrue);
        expect(ws.written, ['accepted']);
      },
    );

    test('close rejects when an accepted write never drains', () async {
      final ws = _GatedWebSocket();
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        fetchTimeout: const Duration(seconds: 2),
        transportCloseTimeout: const Duration(milliseconds: 200),
        connectWebSocket: (url, {protocols}) async => ws,
      );
      addTearDown(manager.dispose);
      final result = await runPluginResult(
        manager,
        id: 'closetout.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody: '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:1/x"
          }).then((opened) => {
            return host.transport.send(opened.handle, { type: "text", data: "stuck" })
              .then(() => host.transport.close(opened.handle))
              .then(() => host.emit("result", "closed"))
              .catch((e) => host.emit("result", JSON.stringify({ message: e.message })));
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
      );

      final payload = jsonDecode(result as String) as Map<String, dynamic>;
      expect(payload['message'], contains('could not be closed'));
      expect(ws.closed, isFalse);
      expect(ws.addStreamGates, hasLength(1));
      expect(ws.addStreamGates.single.isCompleted, isFalse);
    });
  });

  group('tcp', () {
    test('binary bytes round-trip through a TCP echo server', () async {
      final random = Random(7);
      final original = List<int>.generate(1024, (_) => random.nextInt(256));
      final b64 = base64Encode(original);
      final server = await startTcpServer((socket) {
        socket.listen((chunk) {
          try {
            socket.add(chunk);
          } catch (_) {}
        });
      });
      final result = await runPluginResult(
        manager,
        id: 'tcp.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkTcp,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "tcp",
            host: "127.0.0.1",
            port: ${server.port}
          }).then((opened) => {
            host.transport.onEvent(opened.handle, (event) => {
              if (event.type === "data") {
                host.emit("result", JSON.stringify(event));
              }
            });
            host.transport.send(opened.handle, { type: "binary", data: "$b64" });
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
      );

      final event = jsonDecode(result as String) as Map<String, dynamic>;
      expect(event['dataType'], 'binary');
      expect(base64Decode(event['data'] as String), original);
    });

    test('text sends are rejected on TCP', () async {
      final server = await startTcpServer((socket) {
        socket.listen((chunk) {});
      });
      final result = await runPluginResult(
        manager,
        id: 'tcp.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkTcp,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "tcp",
            host: "127.0.0.1",
            port: ${server.port}
          }).then((opened) => {
            return host.transport.send(opened.handle, { type: "text", data: "nope" });
          }).then(() => host.emit("result", "unexpected"))
            .catch((e) => host.emit("result", JSON.stringify({ message: e.message, code: e.code })));
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('Text frames'));
      expect(error['code'], 'transport_error');
    });

    test(
      'close waits for accepted tcp writes to flush before closing',
      () async {
        final server = await startTcpServer((socket) {
          socket.listen((chunk) {}, onError: (Object _) {});
        });
        late _RecordingSocket recording;
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          fetchTimeout: const Duration(seconds: 2),
          connectSocket: (host, port) async {
            final inner = await Socket.connect(host, port);
            recording = _RecordingSocket(inner);
            return recording;
          },
        );
        addTearDown(manager.dispose);
        final sent = Completer<void>();
        final result = Completer<Object?>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'sent' && !sent.isCompleted) sent.complete();
          if (e['event'] == 'result' && !result.isCompleted) {
            result.complete(e['payload']);
          }
        });
        addTearDown(sub.cancel);
        await manager.loadPlugin(
          id: 'tcpclose.plugin',
          manifest: testManifest(
            'tcpclose.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkTcp,
            },
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            return {
              id: "tcpclose.plugin",
              onLoad() {
                host.transport.open({
                  kind: "tcp",
                  host: "127.0.0.1",
                  port: ${server.port}
                }).then((opened) => {
                  return host.transport.send(opened.handle, { type: "binary", data: "AQID" })
                    .then(() => { host.emit("sent", 1); return host.transport.close(opened.handle); });
                }).then(() => host.emit("result", "closed"));
              }
            };
          }
        ''',
        );
        await sent.future.timeout(const Duration(seconds: 5));
        expect(recording.flushGates, hasLength(1));
        expect(recording.calls, isNot(contains('close')));
        await recording.releaseFlush();
        expect(
          await result.future.timeout(const Duration(seconds: 5)),
          'closed',
        );
        expect(
          recording.calls.indexOf('close'),
          greaterThan(recording.calls.indexOf('flush')),
        );
      },
    );
  });

  group('lifecycle and isolation', () {
    test(
      'events arriving before onEvent registration are delivered in order',
      () async {
        final server = await startWsServer((ws) {
          for (final frame in ['first', 'second', 'third']) {
            ws.add(frame);
          }
          ws.listen((data) {});
        });
        final result = await runPluginResult(
          manager,
          id: 'order.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          jsBody:
              '''
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/x"
          }).then((opened) => {
            setTimeout(() => {
              const received = [];
              host.transport.onEvent(opened.handle, (event) => {
                if (event.type !== "data") return;
                received.push(event.data);
                if (received.length === 3) {
                  host.emit("result", JSON.stringify(received));
                }
              });
            }, 300);
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
        );

        expect(jsonDecode(result as String), ['first', 'second', 'third']);
      },
    );

    test('a handle cannot be used by another plugin', () async {
      final server = await startWsServer((ws) {
        ws.listen((data) {
          try {
            ws.add(data);
          } catch (_) {}
        });
      });
      final handle = Completer<String>();
      final echo = Completer<String>();
      final sub = manager.emitStream.listen((e) {
        if (e['event'] == 'handle' && !handle.isCompleted) {
          handle.complete(e['payload'] as String);
        }
        if (e['event'] == 'echo' && !echo.isCompleted) {
          echo.complete(e['payload'] as String);
        }
      });
      addTearDown(sub.cancel);

      await manager.loadPlugin(
        id: 'a.plugin',
        manifest: testManifest(
          'a.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: "a.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${server.port}/echo"
                }).then((opened) => {
                  host.emit("handle", opened.handle);
                  host.transport.onEvent(opened.handle, (event) => {
                    if (event.type === "data") host.emit("echo", JSON.stringify(event));
                  });
                  host.transport.send(opened.handle, { type: "text", data: "ping-A" });
                });
              }
            };
          }
        ''',
      );
      final aHandle = await handle.future.timeout(const Duration(seconds: 5));

      final result = await runPluginResult(
        manager,
        id: 'b.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.send(${jsonEncode(aHandle)}, { type: "text", data: "nope" })
            .then(() => host.emit("result", "unexpected"))
            .catch((e) => host.emit("result", JSON.stringify({ message: e.message })));
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('not owned'));
      final aEcho =
          jsonDecode(await echo.future.timeout(const Duration(seconds: 5)))
              as Map<String, dynamic>;
      expect(aEcho['data'], 'ping-A');
    });

    test(
      'plugins cannot replace transport bridge helpers to capture tokens',
      () async {
        final server = await startWsServer((ws) {
          ws.listen((data) {
            try {
              ws.add(data);
            } catch (_) {}
          });
        });
        final tamper = Completer<String>();
        final echo = Completer<String>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'tamper' && !tamper.isCompleted) {
            tamper.complete(e['payload'] as String);
          }
          if (e['event'] == 'echo' && !echo.isCompleted) {
            echo.complete(e['payload'] as String);
          }
        });
        addTearDown(sub.cancel);

        await manager.loadPlugin(
          id: 'attacker.plugin',
          manifest: testManifest(
            'attacker.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode: '''
          function createPlugin(host) {
            return {
              id: "attacker.plugin",
              onLoad() {
                const results = [];
                for (const name of [
                  "__transportRegister", "__handleTransportReply",
                  "__transportSetListener", "__transportRequest",
                  "__dispatchTransportEvent", "__transportRemoveListener"
                ]) {
                  try {
                    Object.defineProperty(globalThis, name, { value: () => {}, writable: true, configurable: true });
                    results.push(name + ":writable");
                  } catch (e) {
                    results.push(name + ":blocked");
                  }
                }
                host.emit("tamper", results.join(","));
              }
            };
          }
        ''',
        );
        expect(
          (await tamper.future.timeout(const Duration(seconds: 5))).split(','),
          everyElement(endsWith(':blocked')),
        );

        await manager.loadPlugin(
          id: 'victim.plugin',
          manifest: testManifest(
            'victim.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            return {
              id: "victim.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${server.port}/echo"
                }).then((opened) => {
                  host.transport.onEvent(opened.handle, (event) => {
                    if (event.type === "data") {
                      host.emit("echo", event.data);
                    }
                  });
                  host.transport.send(opened.handle, { type: "text", data: "victim ping" });
                });
              }
            };
          }
        ''',
        );
        expect(
          await echo.future.timeout(const Duration(seconds: 5)),
          'victim ping',
        );
      },
    );

    test(
      'a plugin cannot monkey-patch Map.prototype to capture another plugin token',
      () async {
        final server = await startWsServer((ws) {
          ws.listen((data) {
            try {
              ws.add(data);
            } catch (_) {}
          });
        });
        final armed = Completer<void>();
        final capture = Completer<String>();
        final echo = Completer<String>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'armed' && !armed.isCompleted) armed.complete();
          if (e['event'] == 'capture' && !capture.isCompleted) {
            capture.complete(e['payload'] as String);
          }
          if (e['event'] == 'echo' && !echo.isCompleted) {
            echo.complete(e['payload'] as String);
          }
        });
        addTearDown(sub.cancel);

        await manager.loadPlugin(
          id: 'attacker.plugin',
          manifest: testManifest(
            'attacker.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode: '''
          function createPlugin(host) {
            return {
              id: "attacker.plugin",
              onLoad() {
                const captured = [];
                const sniff = (value) => {
                  if (value && typeof value === "object" &&
                      typeof value.resolve === "function" &&
                      typeof value.reject === "function" &&
                      typeof value.bridgeToken === "string") {
                    captured.push("token:" + value.bridgeToken);
                    captured.push("resolve");
                    captured.push("reject");
                  }
                  return value;
                };
                const native = {
                  set: Map.prototype.set,
                  get: Map.prototype.get,
                  delete: Map.prototype.delete,
                  clear: Map.prototype.clear,
                  forEach: Map.prototype.forEach,
                  has: Map.prototype.has,
                  values: Map.prototype.values,
                  entries: Map.prototype.entries,
                  keys: Map.prototype.keys,
                  iterator: Map.prototype[Symbol.iterator]
                };
                Map.prototype.set = function (key, value) {
                  sniff(value);
                  return native.set.call(this, key, value);
                };
                Map.prototype.get = function (key) {
                  return native.get.call(this, key);
                };
                Map.prototype.delete = function (key) {
                  return native.delete.call(this, key);
                };
                Map.prototype.clear = function () {
                  return native.clear.call(this);
                };
                Map.prototype.forEach = function (callback, thisArg) {
                  return native.forEach.call(this, function (value, key, map) {
                    sniff(value);
                    return callback.call(thisArg, value, key, map);
                  }, thisArg);
                };
                Map.prototype.has = function (key) {
                  return native.has.call(this, key);
                };
                Map.prototype.values = function () {
                  return native.values.call(this);
                };
                Map.prototype.entries = function () {
                  return native.entries.call(this);
                };
                Map.prototype.keys = function () {
                  return native.keys.call(this);
                };
                Map.prototype[Symbol.iterator] = function () {
                  return native.iterator.call(this);
                };
                setTimeout(() => host.emit("capture", captured.join(",")), 500);
                host.emit("armed", true);
              }
            };
          }
        ''',
        );
        await armed.future.timeout(const Duration(seconds: 5));

        await manager.loadPlugin(
          id: 'victim.plugin',
          manifest: testManifest(
            'victim.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            return {
              id: "victim.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${server.port}/echo"
                }).then((opened) => {
                  host.transport.onEvent(opened.handle, (event) => {
                    if (event.type === "data") {
                      host.emit("echo", event.data);
                    }
                  });
                  host.transport.send(opened.handle, { type: "text", data: "victim ping" });
                });
              }
            };
          }
        ''',
        );
        expect(
          await echo.future.timeout(const Duration(seconds: 5)),
          'victim ping',
        );
        await manager.unloadPlugin('victim.plugin');
        expect(
          await capture.future.timeout(const Duration(seconds: 5)),
          isEmpty,
        );
      },
    );

    test('a handle cannot be reused by a newer plugin generation', () async {
      final server = await startWsServer((ws) {
        ws.listen((data) {
          try {
            ws.add(data);
          } catch (_) {}
        });
      });
      final handle = Completer<String>();
      final sub = manager.emitStream.listen((e) {
        if (!handle.isCompleted) handle.complete(e['payload'] as String);
      });
      addTearDown(sub.cancel);

      await manager.loadPlugin(
        id: 'gen.plugin',
        manifest: testManifest(
          'gen.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: "gen.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${server.port}/x"
                }).then((opened) => host.emit("handle", opened.handle));
              }
            };
          }
        ''',
      );
      final oldHandle = await handle.future.timeout(const Duration(seconds: 5));
      await manager.unloadPlugin('gen.plugin');

      final result = await runPluginResult(
        manager,
        id: 'gen.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkWebsocket,
        },
        jsBody:
            '''
          host.transport.send(${jsonEncode(oldHandle)}, { type: "text", data: "stale" })
            .then(() => host.emit("result", "unexpected"))
            .catch((e) => host.emit("result", JSON.stringify({ message: e.message })));
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['message'], contains('Unknown transport handle'));
    });

    test('plugin unload closes all owned connections', () async {
      final wsClosed = Completer<void>();
      final tcpClosed = Completer<void>();
      final wsServer = await startWsServer((ws) {
        ws.listen(
          (data) {},
          onDone: () {
            if (!wsClosed.isCompleted) wsClosed.complete();
          },
        );
      });
      final tcpServer = await startTcpServer((socket) {
        socket.listen(
          (chunk) {},
          onDone: () {
            if (!tcpClosed.isCompleted) tcpClosed.complete();
          },
        );
      });

      await manager.loadPlugin(
        id: 'unload.plugin',
        manifest: testManifest(
          'unload.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
            PluginPermissions.networkTcp,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: "unload.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${wsServer.port}/x"
                });
                host.transport.open({
                  kind: "tcp",
                  host: "127.0.0.1",
                  port: ${tcpServer.port}
                });
              }
            };
          }
        ''',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(manager.liveTransportCount, 2);

      await manager.unloadPlugin('unload.plugin');

      await wsClosed.future.timeout(const Duration(seconds: 5));
      await tcpClosed.future.timeout(const Duration(seconds: 5));
      expect(manager.liveTransportCount, 0);
    });

    test('manager disposal closes all remaining transports', () async {
      final closed = Completer<void>();
      final server = await startTcpServer((socket) {
        socket.listen(
          (chunk) {},
          onDone: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      });

      await manager.loadPlugin(
        id: 'dispose.plugin',
        manifest: testManifest(
          'dispose.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkTcp,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: "dispose.plugin",
              onLoad() {
                host.transport.open({
                  kind: "tcp",
                  host: "127.0.0.1",
                  port: ${server.port}
                });
              }
            };
          }
        ''',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(manager.liveTransportCount, 1);

      await manager.dispose();

      await closed.future.timeout(const Duration(seconds: 5));
      expect(manager.liveTransportCount, 0);
    });
  });

  group('resource limits', () {
    test(
      'a ninth live transport is rejected with transport_resource_limit',
      () async {
        final server = await startWsServer((ws) {
          ws.listen((data) {}, onError: (Object _) {});
        });
        final result = await runPluginResult(
          manager,
          id: 'limit.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          jsBody:
              '''
          const opens = [0,1,2,3,4,5,6,7].reduce(
            (p) => p.then(() => host.transport.open({
              kind: "websocket",
              url: "ws://127.0.0.1:${server.port}/x"
            })),
            Promise.resolve()
          );
          opens.then(() => host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:${server.port}/x"
          })).then(
            () => host.emit("result", "unexpected"),
            (e) => host.emit("result", JSON.stringify({ code: e.code, message: e.message }))
          );
        ''',
        );

        final error = jsonDecode(result as String) as Map<String, dynamic>;
        expect(error['code'], 'transport_resource_limit');
        expect(manager.liveTransportCount, 8);
      },
    );

    test('an oversize send is rejected atomically without writing', () async {
      var received = 0;
      final server = await startTcpServer((socket) {
        socket.listen((chunk) {
          received += chunk.length;
        });
      });
      final big = base64Encode(List<int>.filled(1048576 + 1, 0x41));
      final result = await runPluginResult(
        manager,
        id: 'out.plugin',
        permissions: const {
          PluginPermissions.emit,
          PluginPermissions.networkTcp,
        },
        jsBody:
            '''
          host.transport.open({
            kind: "tcp",
            host: "127.0.0.1",
            port: ${server.port}
          }).then((opened) => {
            return host.transport.send(opened.handle, { type: "binary", data: "$big" });
          }).then(() => host.emit("result", "unexpected"))
            .catch((e) => host.emit("result", JSON.stringify({ code: e.code })));
        ''',
      );

      final error = jsonDecode(result as String) as Map<String, dynamic>;
      expect(error['code'], 'transport_resource_limit');
      expect(received, 0);
    });

    test(
      'multiple sub-limit websocket sends accumulate pending outbound bytes',
      () async {
        final ws = _GatedWebSocket();
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          fetchTimeout: const Duration(seconds: 2),
          transportCloseTimeout: const Duration(milliseconds: 200),
          connectWebSocket: (url, {protocols}) async => ws,
        );
        addTearDown(manager.dispose);
        final result = await runPluginResult(
          manager,
          id: 'backpressure.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          jsBody: '''
          const big = "x".repeat(400 * 1024);
          host.transport.open({
            kind: "websocket",
            url: "ws://127.0.0.1:1/x"
          }).then((opened) => {
            const results = [];
            const attempt = (i) => {
              if (i >= 3) {
                host.emit("result", JSON.stringify(results));
                return;
              }
              host.transport.send(opened.handle, { type: "text", data: big })
                .then(() => { results.push("ok"); attempt(i + 1); })
                .catch((e) => { results.push(e.code); attempt(i + 1); });
            };
            attempt(0);
          }).catch((e) => host.emit("result", JSON.stringify({ error: e.message })));
        ''',
        );

        await pumpEventQueue();
        expect(jsonDecode(result as String), [
          'ok',
          'ok',
          'transport_resource_limit',
        ]);
        expect(ws.written.length, 1);
      },
    );

    test(
      'a failed websocket write terminates the transport and clears accounting',
      () async {
        final ws = _GatedWebSocket()..failWrites = true;
        final manager = PluginManager(
          kvStore: FakeKeyValueStoreService(),
          fetchTimeout: const Duration(seconds: 2),
          connectWebSocket: (url, {protocols}) async => ws,
        );
        addTearDown(manager.dispose);
        final errorResult = Completer<String>();
        final resendResult = Completer<String>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'result' && !errorResult.isCompleted) {
            errorResult.complete(e['payload'] as String);
          }
          if (e['event'] == 'result2' && !resendResult.isCompleted) {
            resendResult.complete(e['payload'] as String);
          }
        });
        addTearDown(sub.cancel);
        await manager.loadPlugin(
          id: 'failwrite.plugin',
          manifest: testManifest(
            'failwrite.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode: '''
          function createPlugin(host) {
            return {
              id: "failwrite.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:1/x"
                }).then((opened) => {
                  host.transport.onEvent(opened.handle, (event) => {
                    if (event.type === "error") {
                      host.emit("result", JSON.stringify({ code: event.code }));
                    }
                  });
                  host.transport.send(opened.handle, { type: "text", data: "boom" }).then(() => {
                    setTimeout(() => {
                      host.transport.send(opened.handle, { type: "text", data: "again" })
                        .then(() => host.emit("result2", "unexpected"))
                        .catch((e) => host.emit("result2", JSON.stringify({ code: e.code })));
                    }, 200);
                  });
                });
              }
            };
          }
        ''',
        );
        final error =
            jsonDecode(
                  await errorResult.future.timeout(const Duration(seconds: 5)),
                )
                as Map<String, dynamic>;
        expect(error['code'], 'transport_error');
        final resend =
            jsonDecode(
                  await resendResult.future.timeout(const Duration(seconds: 5)),
                )
                as Map<String, dynamic>;
        expect(resend['code'], 'transport_error');
        await pumpEventQueue();
        expect(manager.liveTransportCount, 0);
      },
    );

    test(
      'remotely closed transports without a listener count toward the limit',
      () async {
        final server = await startWsServer((ws) {
          ws.close(1000);
        });
        final result = await runPluginResult(
          manager,
          id: 'dead.plugin',
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.networkWebsocket,
          },
          jsBody:
              '''
          const opens = [0,1,2,3,4,5,6,7].map(() =>
            host.transport.open({
              kind: "websocket",
              url: "ws://127.0.0.1:${server.port}/x"
            })
          );
          Promise.all(opens).then(() => {
            setTimeout(() => {
              host.transport.open({
                kind: "websocket",
                url: "ws://127.0.0.1:${server.port}/x"
              }).then(() => host.emit("result", "unexpected"))
                .catch((e) => host.emit("result", JSON.stringify({ code: e.code })));
            }, 300);
          });
        ''',
        );

        final error = jsonDecode(result as String) as Map<String, dynamic>;
        expect(error['code'], 'transport_resource_limit');
        expect(manager.liveTransportCount, 0);
      },
    );

    test(
      'inbound overflow closes the transport with a resource limit error',
      () async {
        final chunk = List<int>.filled(64 * 1024, 0x42);
        final server = await startWsServer((ws) {
          for (var i = 0; i < 32; i++) {
            ws.add(chunk);
          }
          ws.listen((data) {}, onError: (Object _) {});
        });
        final errorResult = Completer<String>();
        final closeResult = Completer<String>();
        final sub = manager.emitStream.listen((e) {
          if (e['event'] == 'result' && !errorResult.isCompleted) {
            errorResult.complete(e['payload'] as String);
          }
          if (e['event'] == 'result2' && !closeResult.isCompleted) {
            closeResult.complete(e['payload'] as String);
          }
        });
        addTearDown(sub.cancel);

        await manager.loadPlugin(
          id: 'in.plugin',
          manifest: testManifest(
            'in.plugin',
            permissions: const {
              PluginPermissions.emit,
              PluginPermissions.networkWebsocket,
            },
          ),
          settings: {},
          jsCode:
              '''
          function createPlugin(host) {
            return {
              id: "in.plugin",
              onLoad() {
                host.transport.open({
                  kind: "websocket",
                  url: "ws://127.0.0.1:${server.port}/flood"
                }).then((opened) => {
                  setTimeout(() => {
                    host.transport.onEvent(opened.handle, (event) => {
                      if (event.type === "error") {
                        host.emit("result", JSON.stringify({ code: event.code }));
                      } else if (event.type === "close") {
                        host.emit("result2", JSON.stringify({ closed: true }));
                      }
                    });
                  }, 400);
                });
              }
            };
          }
        ''',
        );

        final error =
            jsonDecode(
                  await errorResult.future.timeout(const Duration(seconds: 10)),
                )
                as Map<String, dynamic>;
        expect(error['code'], 'transport_resource_limit');
        final closed =
            jsonDecode(
                  await closeResult.future.timeout(const Duration(seconds: 10)),
                )
                as Map<String, dynamic>;
        expect(closed['closed'], true);
      },
    );
  });
}
