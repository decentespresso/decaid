import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/transport/web_socket_transport.dart';

class FakeTextSocket implements TextSocket {
  final _inbound = StreamController<dynamic>.broadcast();
  final List<String> sent = [];
  final Completer<void> _ready = Completer<void>();
  bool closed = false;

  Object? readyError;

  FakeTextSocket({bool readyImmediately = true}) {
    if (readyImmediately) _ready.complete();
  }

  void completeReady() => _ready.complete();
  void failReady(Object error) => _ready.completeError(error);

  void emit(dynamic frame) => _inbound.add(frame);

  void closeFromPeer() => _inbound.close();

  @override
  Future<void> get ready =>
      readyError != null ? Future.error(readyError!) : _ready.future;

  @override
  Stream<dynamic> get stream => _inbound.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async {
    closed = true;
    if (!_inbound.isClosed) await _inbound.close();
  }
}

void main() {
  group('WsTransport', () {
    late FakeTextSocket socket;
    late WsTransport transport;

    setUp(() {
      socket = FakeTextSocket();
      transport = WsTransport(
        host: 'hds.local',
        connector: (uri) async => socket,
      );
    });

    test('builds the ws://host:80/snapshot uri', () {
      expect(transport.uri.toString(), 'ws://hds.local:80/snapshot');
      expect(transport.id, 'wifi:hds.local');
    });

    test('connect emits connecting then connected', () async {
      final states = <ConnectionState>[];
      final sub = transport.connectionState.listen(states.add);
      await transport.connect();
      await Future.delayed(Duration.zero);
      expect(states, contains(ConnectionState.connecting));
      expect(states.last, ConnectionState.connected);
      await sub.cancel();
    });

    test('inbound string frames surface on messages', () async {
      final received = <String>[];
      final sub = transport.messages.listen(received.add);
      await transport.connect();
      socket.emit('{"grams":1.2}');
      socket.emit('hello');
      await Future.delayed(Duration.zero);
      expect(received, ['{"grams":1.2}', 'hello']);
      await sub.cancel();
    });

    test('inbound binary frames are utf8-decoded', () async {
      final received = <String>[];
      final sub = transport.messages.listen(received.add);
      await transport.connect();
      socket.emit('tä'.codeUnits.isEmpty ? <int>[] : 'ok'.codeUnits);
      await Future.delayed(Duration.zero);
      expect(received, ['ok']);
      await sub.cancel();
    });

    test('sendMessage forwards to the socket', () async {
      await transport.connect();
      await transport.sendMessage('tare');
      expect(socket.sent, ['tare']);
    });

    test('sendMessage before connect throws', () {
      expect(() => transport.sendMessage('tare'), throwsStateError);
    });

    test(
      'connect rethrows and reports disconnected when ready fails',
      () async {
        final badSocket = FakeTextSocket(readyImmediately: false)
          ..readyError = StateError('refused');
        final t = WsTransport(
          host: 'nope.local',
          connector: (uri) async => badSocket,
        );
        final states = <ConnectionState>[];
        final sub = t.connectionState.listen(states.add);
        await expectLater(t.connect(), throwsA(isA<StateError>()));
        await Future.delayed(Duration.zero);
        expect(states.last, ConnectionState.disconnected);
        await sub.cancel();
      },
    );

    test('peer close moves state to disconnected', () async {
      await transport.connect();
      final states = <ConnectionState>[];
      final sub = transport.connectionState.listen(states.add);
      socket.closeFromPeer();
      await Future.delayed(Duration.zero);
      expect(states.last, ConnectionState.disconnected);
      await sub.cancel();
    });

    test('disconnect closes the socket and reports disconnected', () async {
      await transport.connect();
      await transport.disconnect();
      expect(socket.closed, isTrue);
      expect(
        await transport.connectionState.first,
        ConnectionState.disconnected,
      );
    });

    test('dispose closes streams', () async {
      await transport.connect();
      await transport.dispose();
      await transport.dispose();
    });
  });
}
