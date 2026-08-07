import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/web_socket_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

class FakeWebSocketTransport implements WebSocketTransport {
  final String host;
  bool failConnect;

  FakeWebSocketTransport({this.host = 'hds.local', this.failConnect = false});

  final BehaviorSubject<ConnectionState> _conn = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<String> _msgs = StreamController<String>.broadcast();

  final List<String> sent = [];
  bool connected = false;
  bool disconnectCalled = false;

  @override
  String get id => 'wifi:$host';

  @override
  String get name => host;

  @override
  TransportType get transportType => TransportType.wifi;

  @override
  Stream<ConnectionState> get connectionState => _conn.stream;

  @override
  Stream<String> get messages => _msgs.stream;

  @override
  Future<void> connect() async {
    _conn.add(ConnectionState.connecting);
    if (failConnect) {
      _conn.add(ConnectionState.disconnected);
      throw StateError('connect refused');
    }
    connected = true;
    _conn.add(ConnectionState.connected);
  }

  void emit(String frame) {
    if (!_msgs.isClosed) _msgs.add(frame);
  }

  void dropFromPeer() {
    connected = false;
    if (!_conn.isClosed) _conn.add(ConnectionState.disconnected);
  }

  @override
  Future<void> sendMessage(String message) async {
    if (!connected) throw StateError('not connected');
    sent.add(message);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalled = true;
    connected = false;
    if (!_conn.isClosed) _conn.add(ConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    if (!_conn.isClosed) await _conn.close();
    if (!_msgs.isClosed) await _msgs.close();
  }
}
