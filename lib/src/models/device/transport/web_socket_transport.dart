import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/wifi_scale_id.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

abstract class WebSocketTransport extends DataTransport {
  @override
  TransportType get transportType => TransportType.wifi;

  Future<void> sendMessage(String message);

  Stream<String> get messages;
}

abstract class TextSocket {
  Future<void> get ready;

  Stream<dynamic> get stream;

  void send(String message);

  Future<void> close();
}

typedef TextSocketConnector = Future<TextSocket> Function(Uri uri);

Future<TextSocket> _defaultConnector(Uri uri) async {
  return _ChannelSocket(WebSocketChannel.connect(uri));
}

class _ChannelSocket implements TextSocket {
  final WebSocketChannel _channel;
  _ChannelSocket(this._channel);

  @override
  Future<void> get ready => _channel.ready;

  @override
  Stream<dynamic> get stream => _channel.stream;

  @override
  void send(String message) => _channel.sink.add(message);

  @override
  Future<void> close() => _channel.sink.close();
}

class WsTransport implements WebSocketTransport {
  final String host;
  final int port;
  final String path;
  final TextSocketConnector _connector;
  late final Logger _log;

  WsTransport({
    required this.host,
    this.port = 80,
    this.path = '/snapshot',
    TextSocketConnector? connector,
  }) : _connector = connector ?? _defaultConnector {
    _log = Logger('WsTransport#$host');
  }

  Uri get uri => Uri(scheme: 'ws', host: host, port: port, path: path);

  @override
  String get id => WifiScaleId.forHost(host);

  @override
  String get name => host;

  @override
  TransportType get transportType => TransportType.wifi;

  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);
  @override
  Stream<ConnectionState> get connectionState => _connectionSubject.stream;

  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  @override
  Stream<String> get messages => _messages.stream;

  TextSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;

  @override
  Future<void> connect() async {
    _emitState(ConnectionState.connecting);
    try {
      final socket = await _connector(uri);
      await socket.ready;
      _socket = socket;
      _socketSub = socket.stream.listen(
        _onFrame,
        onError: (Object e, StackTrace st) {
          _log.warning('socket error', e, st);
          _emitState(ConnectionState.disconnected);
        },
        onDone: () => _emitState(ConnectionState.disconnected),
      );
      _emitState(ConnectionState.connected);
    } catch (e, st) {
      _log.warning('connect failed for $uri', e, st);
      _emitState(ConnectionState.disconnected);
      rethrow;
    }
  }

  void _onFrame(dynamic data) {
    if (_messages.isClosed) return;
    if (data is String) {
      _messages.add(data);
    } else if (data is List<int>) {
      try {
        _messages.add(utf8.decode(data));
      } catch (e) {
        _log.warning('failed to decode binary frame', e);
      }
    }
  }

  @override
  Future<void> sendMessage(String message) async {
    final s = _socket;
    if (s == null) throw StateError('WsTransport not connected');
    s.send(message);
  }

  @override
  Future<void> disconnect() async {
    await _socketSub?.cancel();
    _socketSub = null;
    try {
      await _socket?.close();
    } catch (e) {
      _log.fine('socket close failed', e);
    }
    _socket = null;
    _emitState(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    if (!_connectionSubject.isClosed) await _connectionSubject.close();
    if (!_messages.isClosed) await _messages.close();
  }

  void _emitState(ConnectionState state) {
    if (_connectionSubject.isClosed) return;
    if (_connectionSubject.value == state) return;
    _connectionSubject.add(state);
  }
}
