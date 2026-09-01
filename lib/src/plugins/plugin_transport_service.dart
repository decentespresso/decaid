import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Kinds of outbound transport exposed to plugins.
enum PluginTransportKind { websocket, tcp, tls }

/// Error surfaced to the JS bridge. [code] is the stable machine-readable
/// error code carried on the rejected Promise.
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

/// Delivers a decoded transport event to the JS runtime. Implemented by
/// [PluginManager] so it can validate plugin generation before evaluating JS.
typedef PluginTransportEventSink =
    void Function(
      String pluginId,
      int generation,
      String handle,
      Map<String, dynamic> event,
    );

/// Owns native WebSocket/TCP/TLS connections opened by plugins.
///
/// Every handle is owned by a (pluginId, generation) pair. The service
/// enforces connection and byte limits, bounds the inbound queue, and
/// guarantees that unload/dispose close every native connection.
class PluginTransportService {
  PluginTransportService({
    required this.eventSink,
    this.maxTransportsPerGeneration = 8,
    this.maxPendingOutboundBytes = 1 << 20,
    this.maxQueuedInboundBytes = 1 << 20,
  });

  final PluginTransportEventSink eventSink;
  final int maxTransportsPerGeneration;
  final int maxPendingOutboundBytes;
  final int maxQueuedInboundBytes;

  static const Duration _closeTimeout = Duration(seconds: 5);
  static const String _resourceLimitCode = 'transport_resource_limit';

  final Map<String, _TransportRecord> _records = {};

  int get liveTransportCount =>
      _records.values.where((record) => !record.terminal).length;

  /// Opens a transport and resolves once the connection is established.
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

  /// Registers the single event listener for [handle]. Calling it again
  /// replaces the previous listener. Flushes the bounded inbound queue in
  /// order.
  void onEventRegistered(String pluginId, int generation, String handle) {
    final record = _recordFor(pluginId, generation, handle);
    record.delivering = true;
    _drain(record);
  }

  /// Resolves once the payload is accepted into the native transport's
  /// bounded outbound write path. Rejects atomically with
  /// `transport_resource_limit` if accepting the whole payload would exceed
  /// the outbound limit.
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
      final size = utf8.encode(data).length;
      _reserveOutbound(record, size);
      record.webSocket!.add(data);
      _releaseOutbound(record, size);
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
      _reserveOutbound(record, bytes.length);
      final ws = record.webSocket;
      if (ws != null) {
        ws.add(bytes);
        _releaseOutbound(record, bytes.length);
        return;
      }
      final socket = record.socket!;
      socket.add(bytes);
      unawaited(
        socket.flush().then<void>(
          (_) => _releaseOutbound(record, bytes.length),
          onError: (Object _) => _releaseOutbound(record, bytes.length),
        ),
      );
      return;
    }
    throw const PluginTransportException(
      'Send payload must have type "text" or "binary"',
    );
  }

  /// Closes the transport and releases the handle. Resolves once the native
  /// transport is closed.
  Future<void> close(String pluginId, int generation, String handle) async {
    final record = _recordFor(pluginId, generation, handle);
    _checkOpen(record);
    final ws = record.webSocket;
    if (ws != null) {
      try {
        await ws.close(1000).timeout(_closeTimeout);
      } catch (_) {
        // The peer may already have closed or never respond to the close
        // frame; the handle is released below regardless.
      }
      _terminate(record);
      return;
    }
    final socket = record.socket;
    if (socket != null) {
      try {
        await socket.close().timeout(_closeTimeout);
      } catch (_) {
        socket.destroy();
      }
      _terminate(record);
      return;
    }
    _terminate(record);
  }

  /// Closes every live transport owned by (pluginId, generation). Used on
  /// plugin unload; cleanup is deterministic even if plugin JS misbehaves.
  Future<void> closeAllForPlugin(String pluginId, int generation) async {
    final owned = _records.values
        .where(
          (record) =>
              record.pluginId == pluginId &&
              record.generation == generation &&
              !record.terminal,
        )
        .toList();
    for (final record in owned) {
      try {
        await close(pluginId, generation, record.handle);
      } catch (_) {}
    }
  }

  /// Closes all remaining transports. Called on manager disposal.
  void dispose() {
    for (final record in _records.values) {
      if (record.terminal) continue;
      record.terminal = true;
      _closeNative(record);
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
    final ws = await WebSocket.connect(url, protocols: protocols);
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
    final socket = await Socket.connect(host, port);
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
    final socket = await SecureSocket.connect(host, port);
    record.socket = socket;
    _listenSocket(record);
    return TransportOpenResult(handle: record.handle);
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
    _closeNative(record);
  }

  void _closeNative(_TransportRecord record) {
    final ws = record.webSocket;
    if (ws != null) {
      unawaited(
        ws.close(1000).timeout(_closeTimeout).catchError((Object _) {}),
      );
      return;
    }
    final socket = record.socket;
    if (socket != null) {
      try {
        socket.destroy();
      } catch (_) {}
    }
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
    if (record.terminal) {
      throw const PluginTransportException('Transport already closed');
    }
  }

  void _checkLiveLimit(String pluginId, int generation) {
    final live = _records.values.where(
      (record) =>
          record.pluginId == pluginId &&
          record.generation == generation &&
          !record.terminal,
    );
    if (live.length >= maxTransportsPerGeneration) {
      throw const PluginTransportException(
        'Too many live transports for this plugin',
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
  int outboundBytes = 0;
  final Queue<_QueuedEvent> inboundQueue = Queue();
  int inboundBytes = 0;
}

class _QueuedEvent {
  const _QueuedEvent(this.event, this.size);

  final Map<String, dynamic> event;
  final int size;
}
