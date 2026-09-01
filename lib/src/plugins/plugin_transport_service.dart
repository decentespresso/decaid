import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

enum PluginTransportKind { websocket, tcp, tls }

class PluginTransportException implements Exception {
  const PluginTransportException(this.message, {this.code = 'transport_error'});

  final String message;
  final String code;

  @override
  String toString() => message;
}

class TransportOpenResult {
  const TransportOpenResult({required this.handle, this.protocol});

  final String handle;
  final String? protocol;
}

typedef PluginTransportEventSink =
    void Function(
      String pluginId,
      int generation,
      String handle,
      Map<String, dynamic> event,
    );

typedef WebSocketConnector =
    Future<WebSocket> Function(String url, {Iterable<String>? protocols});
typedef SocketConnector = Future<Socket> Function(String host, int port);
typedef SecureSocketConnector =
    Future<SecureSocket> Function(String host, int port);

class PluginTransportService {
  PluginTransportService({
    required this.eventSink,
    this.maxTransportsPerGeneration = 8,
    this.maxPendingOutboundBytes = 1 << 20,
    this.maxQueuedInboundBytes = 1 << 20,
    this.closeTimeout = const Duration(seconds: 5),
    WebSocketConnector? connectWebSocket,
    SocketConnector? connectSocket,
    SecureSocketConnector? connectSecureSocket,
  }) : connectWebSocket = connectWebSocket ?? _connectWebSocket,
       connectSocket = connectSocket ?? _connectSocket,
       connectSecureSocket = connectSecureSocket ?? _connectSecureSocket;

  final PluginTransportEventSink eventSink;
  final int maxTransportsPerGeneration;
  final int maxPendingOutboundBytes;
  final int maxQueuedInboundBytes;
  final Duration closeTimeout;
  final WebSocketConnector connectWebSocket;
  final SocketConnector connectSocket;
  final SecureSocketConnector connectSecureSocket;

  static const String _resourceLimitCode = 'transport_resource_limit';

  final Map<String, _TransportRecord> _records = {};

  int get liveTransportCount =>
      _records.values.where((record) => !record.terminal).length;

  Future<TransportOpenResult> open({
    required String pluginId,
    required int generation,
    required Map<String, dynamic> options,
  }) async {
    final kind = switch (options['kind']) {
      'websocket' => PluginTransportKind.websocket,
      'tcp' => PluginTransportKind.tcp,
      'tls' => PluginTransportKind.tls,
      _ => throw const PluginTransportException('Unknown transport kind'),
    };
    _checkLiveLimit(pluginId, generation);
    final record = _TransportRecord(
      handle: _newHandle(),
      pluginId: pluginId,
      generation: generation,
      kind: kind,
    );
    _records[record.handle] = record;
    try {
      return switch (kind) {
        PluginTransportKind.websocket => await _openWebSocket(record, options),
        PluginTransportKind.tcp => await _openTcp(record, options),
        PluginTransportKind.tls => await _openTls(record, options),
      };
    } catch (_) {
      _records.remove(record.handle);
      rethrow;
    }
  }

  void onEventRegistered(String pluginId, int generation, String handle) {
    final record = _recordFor(pluginId, generation, handle);
    record.delivering = true;
    _drain(record);
  }

  Future<void> send(
    String pluginId,
    int generation,
    String handle,
    Map<String, dynamic> payload,
  ) async {
    final record = _recordFor(pluginId, generation, handle);
    _checkOpen(record);
    final type = payload['type'];
    if (type == 'text') {
      if (record.kind != PluginTransportKind.websocket) {
        throw const PluginTransportException(
          'Text frames are only supported on WebSocket transports',
        );
      }
      final data = payload['data'];
      if (data is! String) {
        throw const PluginTransportException('Text payload must be a string');
      }
      _enqueueOutbound(record, data, utf8.encode(data).length);
      return;
    }
    if (type == 'binary') {
      final data = payload['data'];
      if (data is! String) {
        throw const PluginTransportException(
          'Binary payload must be a base64 string',
        );
      }
      final Uint8List bytes;
      try {
        bytes = base64Decode(data);
      } on FormatException {
        throw const PluginTransportException(
          'Binary payload is not valid base64',
        );
      }
      final ws = record.webSocket;
      if (ws != null) {
        _enqueueOutbound(record, bytes, bytes.length);
        return;
      }
      final socket = record.socket!;
      _reserveOutbound(record, bytes.length);
      try {
        socket.add(bytes);
      } catch (_) {
        _releaseOutbound(record, bytes.length);
        rethrow;
      }
      final write = Completer<void>();
      record.tcpFlushes.add(write.future);
      unawaited(
        socket.flush().then<void>(
          (_) {
            _releaseOutbound(record, bytes.length);
            record.tcpFlushes.remove(write.future);
            if (!write.isCompleted) write.complete();
          },
          onError: (Object _) {
            _releaseOutbound(record, bytes.length);
            record.tcpFlushes.remove(write.future);
            if (!write.isCompleted) write.complete();
          },
        ),
      );
      return;
    }
    throw const PluginTransportException(
      'Send payload must have type "text" or "binary"',
    );
  }

  Future<void> close(String pluginId, int generation, String handle) async {
    final record = _recordFor(pluginId, generation, handle);
    _checkOpen(record);
    record.closing = true;
    if (!await _closeNative(record)) {
      throw const PluginTransportException(
        'Transport could not be closed; outbound write did not drain',
      );
    }
    _terminate(record);
    _records.remove(record.handle);
  }

  Future<void> closeAllForPlugin(String pluginId, int generation) async {
    final owned = _records.values
        .where(
          (record) =>
              record.pluginId == pluginId && record.generation == generation,
        )
        .toList();
    for (final record in owned) {
      _records.remove(record.handle);
      if (record.terminal) continue;
      record.terminal = true;
      await _closeNative(record);
    }
  }

  Future<void> dispose() async {
    for (final record in _records.values) {
      if (record.terminal) continue;
      record.terminal = true;
      await _closeNative(record);
    }
    _records.clear();
  }

  Future<TransportOpenResult> _openWebSocket(
    _TransportRecord record,
    Map<String, dynamic> options,
  ) async {
    final url = options['url'];
    if (url is! String ||
        !(url.startsWith('ws://') || url.startsWith('wss://'))) {
      throw const PluginTransportException(
        'WebSocket transport requires a ws:// or wss:// url',
      );
    }
    final rawProtocols = options['protocols'];
    Iterable<String>? protocols;
    if (rawProtocols != null) {
      if (rawProtocols is! List || rawProtocols.any((p) => p is! String)) {
        throw const PluginTransportException(
          'WebSocket protocols must be an array of strings',
        );
      }
      protocols = rawProtocols.cast<String>();
    }
    final ws = await connectWebSocket(url, protocols: protocols);
    if (record.terminal) {
      unawaited(ws.close(1000).timeout(closeTimeout).catchError((Object _) {}));
      throw const PluginTransportException('Plugin unloaded during connect');
    }
    record.webSocket = ws;
    _listenWebSocket(record);
    final protocol = ws.protocol;
    return TransportOpenResult(
      handle: record.handle,
      protocol: (protocol == null || protocol.isEmpty) ? null : protocol,
    );
  }

  Future<TransportOpenResult> _openTcp(
    _TransportRecord record,
    Map<String, dynamic> options,
  ) async {
    final host = _hostOption(options);
    final port = _portOption(options);
    final socket = await connectSocket(host, port);
    if (record.terminal) {
      socket.destroy();
      throw const PluginTransportException('Plugin unloaded during connect');
    }
    record.socket = socket;
    _listenSocket(record);
    return TransportOpenResult(handle: record.handle);
  }

  Future<TransportOpenResult> _openTls(
    _TransportRecord record,
    Map<String, dynamic> options,
  ) async {
    final host = _hostOption(options);
    final port = _portOption(options);
    final socket = await connectSecureSocket(host, port);
    if (record.terminal) {
      socket.destroy();
      throw const PluginTransportException('Plugin unloaded during connect');
    }
    record.socket = socket;
    _listenSocket(record);
    return TransportOpenResult(handle: record.handle);
  }

  void _enqueueOutbound(_TransportRecord record, Object data, int size) {
    _reserveOutbound(record, size);
    record.outboundQueue.add(_OutboundFrame(data, size));
    unawaited(_drainOutbound(record));
  }

  Future<void> _drainOutbound(_TransportRecord record) {
    final existing = record.outboundDrain;
    if (existing != null) return existing;
    final drain = _runOutboundDrain(record);
    record.outboundDrain = drain;
    return drain;
  }

  Future<void> _runOutboundDrain(_TransportRecord record) async {
    try {
      while (!record.terminal && record.outboundQueue.isNotEmpty) {
        final frame = record.outboundQueue.first;
        final ws = record.webSocket;
        if (ws == null) break;
        final controller = StreamController<dynamic>();
        record.pendingWrite = controller;
        try {
          final write = ws.addStream(controller.stream);
          controller.add(frame.data);
          await Future.wait([controller.close(), write]);
        } on Object {
          record.outboundQueue.clear();
          record.outboundBytes = 0;
          _terminate(record, error: 'WebSocket write failed; transport closed');
          break;
        } finally {
          record.pendingWrite = null;
        }
        record.outboundQueue.removeFirst();
        _releaseOutbound(record, frame.size);
      }
    } finally {
      record.outboundDrain = null;
    }
  }

  Future<bool> _awaitOutbound(_TransportRecord record) async {
    final ws = record.webSocket;
    if (ws != null) {
      final drain = record.outboundDrain;
      if (drain == null) return true;
      try {
        await drain.timeout(closeTimeout);
        return true;
      } on TimeoutException {
        return false;
      }
    }
    final pending = record.tcpFlushes.toList();
    if (pending.isEmpty) return true;
    try {
      await Future.wait(pending).timeout(closeTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  String _hostOption(Map<String, dynamic> options) {
    final host = options['host'];
    if (host is! String || host.isEmpty) {
      throw const PluginTransportException('Transport requires a host');
    }
    return host;
  }

  int _portOption(Map<String, dynamic> options) {
    final port = options['port'];
    if (port is! int || port < 1 || port > 65535) {
      throw const PluginTransportException(
        'Transport requires a port 1..65535',
      );
    }
    return port;
  }

  void _listenWebSocket(_TransportRecord record) {
    record.webSocket!.listen(
      (dynamic data) {
        if (record.terminal) return;
        if (data is String) {
          _enqueue(record, {
            'type': 'data',
            'dataType': 'text',
            'data': data,
          }, size: utf8.encode(data).length);
        } else if (data is List<int>) {
          _enqueue(record, {
            'type': 'data',
            'dataType': 'binary',
            'data': base64Encode(data),
          }, size: data.length);
        }
      },
      onError: (Object error) =>
          _terminate(record, error: 'WebSocket error: $error'),
      onDone: () => _terminate(record),
      cancelOnError: true,
    );
  }

  void _listenSocket(_TransportRecord record) {
    record.socket!.listen(
      (List<int> chunk) {
        if (record.terminal) return;
        _enqueue(record, {
          'type': 'data',
          'dataType': 'binary',
          'data': base64Encode(chunk),
        }, size: chunk.length);
      },
      onError: (Object error) =>
          _terminate(record, error: 'Socket error: $error'),
      onDone: () => _terminate(record),
      cancelOnError: true,
    );
  }

  void _enqueue(
    _TransportRecord record,
    Map<String, dynamic> event, {
    required int size,
  }) {
    if (record.terminal) return;
    if (record.inboundBytes + size > maxQueuedInboundBytes) {
      _terminate(
        record,
        error: 'Inbound data limit exceeded; transport closed',
        code: _resourceLimitCode,
      );
      return;
    }
    record.inboundQueue.add(_QueuedEvent(event, size));
    record.inboundBytes += size;
    _drain(record);
  }

  void _drain(_TransportRecord record) {
    if (!record.delivering) return;
    while (record.inboundQueue.isNotEmpty) {
      final queued = record.inboundQueue.removeFirst();
      record.inboundBytes -= queued.size;
      eventSink(
        record.pluginId,
        record.generation,
        record.handle,
        queued.event,
      );
    }
    if (record.terminal) _records.remove(record.handle);
  }

  void _terminate(
    _TransportRecord record, {
    String? error,
    String code = 'transport_error',
  }) {
    if (record.terminal) return;
    record.terminal = true;
    if (error != null) {
      record.inboundQueue.add(
        _QueuedEvent({'type': 'error', 'code': code, 'message': error}, 0),
      );
    }
    record.inboundQueue.add(_QueuedEvent(_closeEvent(record), 0));
    _drain(record);
    unawaited(_closeNative(record));
  }

  Future<bool> _closeNative(_TransportRecord record) async {
    var graceful = await _awaitOutbound(record);
    if (!graceful) {
      record.terminal = true;
      final controller = record.pendingWrite;
      if (controller != null && !controller.isClosed) {
        await controller.close();
      }
      final drain = record.outboundDrain;
      if (drain != null) {
        try {
          await drain.timeout(const Duration(milliseconds: 100));
        } catch (_) {}
      }
    }
    final ws = record.webSocket;
    if (ws != null) {
      try {
        await ws.close(1000).timeout(closeTimeout);
        return true;
      } on Object {
        return false;
      }
    }
    final socket = record.socket;
    if (socket != null) {
      if (graceful) {
        try {
          await socket.close().timeout(closeTimeout);
        } catch (_) {
          socket.destroy();
        }
      } else {
        try {
          socket.destroy();
        } catch (_) {}
      }
      return true;
    }
    return true;
  }

  Map<String, dynamic> _closeEvent(_TransportRecord record) {
    final ws = record.webSocket;
    if (ws != null) {
      final code = ws.closeCode;
      final reason = ws.closeReason;
      return {
        'type': 'close',
        'code': ?code,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      };
    }
    return {'type': 'close'};
  }

  _TransportRecord _recordFor(String pluginId, int generation, String handle) {
    final record = _records[handle];
    if (record == null) {
      throw const PluginTransportException('Unknown transport handle');
    }
    if (record.pluginId != pluginId || record.generation != generation) {
      throw const PluginTransportException(
        'Transport handle is not owned by this plugin',
      );
    }
    return record;
  }

  void _checkOpen(_TransportRecord record) {
    if (record.terminal || record.closing) {
      throw const PluginTransportException('Transport already closed');
    }
  }

  void _checkLiveLimit(String pluginId, int generation) {
    final retained = _records.values.where(
      (record) =>
          record.pluginId == pluginId &&
          record.generation == generation &&
          (!record.terminal || !record.delivering),
    );
    if (retained.length >= maxTransportsPerGeneration) {
      throw const PluginTransportException(
        'Too many open transports for this plugin',
        code: _resourceLimitCode,
      );
    }
  }

  void _reserveOutbound(_TransportRecord record, int size) {
    if (size > maxPendingOutboundBytes ||
        record.outboundBytes + size > maxPendingOutboundBytes) {
      throw const PluginTransportException(
        'Outbound data limit exceeded; send rejected',
        code: _resourceLimitCode,
      );
    }
    record.outboundBytes += size;
  }

  void _releaseOutbound(_TransportRecord record, int size) {
    record.outboundBytes -= size;
  }

  String _newHandle() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

Future<WebSocket> _connectWebSocket(
  String url, {
  Iterable<String>? protocols,
}) => WebSocket.connect(url, protocols: protocols);

Future<Socket> _connectSocket(String host, int port) =>
    Socket.connect(host, port);

Future<SecureSocket> _connectSecureSocket(String host, int port) =>
    SecureSocket.connect(host, port);

class _TransportRecord {
  _TransportRecord({
    required this.handle,
    required this.pluginId,
    required this.generation,
    required this.kind,
  });

  final String handle;
  final String pluginId;
  final int generation;
  final PluginTransportKind kind;

  WebSocket? webSocket;
  Socket? socket;
  bool delivering = false;
  bool terminal = false;
  bool closing = false;
  int outboundBytes = 0;
  final Queue<_OutboundFrame> outboundQueue = Queue();
  Future<void>? outboundDrain;
  StreamController<dynamic>? pendingWrite;
  final List<Future<void>> tcpFlushes = [];
  final Queue<_QueuedEvent> inboundQueue = Queue();
  int inboundBytes = 0;
}

class _OutboundFrame {
  const _OutboundFrame(this.data, this.size);

  final Object data;
  final int size;
}

class _QueuedEvent {
  const _QueuedEvent(this.event, this.size);

  final Map<String, dynamic> event;
  final int size;
}
