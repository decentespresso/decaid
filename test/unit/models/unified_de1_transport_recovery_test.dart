import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:rxdart/rxdart.dart';

/// Fake BLE transport that models the post-#243 behaviour: `disconnect()`
/// emits `ConnectionState.disconnected` onto the connection-state stream
/// (as `BluePlusTransport` does synchronously and `AndroidBluePlusTransport`
/// does via its native sub). The first `write()` times out to trigger
/// `UnifiedDe1Transport._handleBleTimeout`; reconnect success/failure is
/// controlled by [reconnectSucceeds].
class _RecoveryFakeTransport extends BLETransport {
  _RecoveryFakeTransport({required this.reconnectSucceeds});

  final bool reconnectSucceeds;

  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );

  int writeCount = 0;
  int connectCount = 0;
  int disconnectCount = 0;

  @override
  String get id => 'recovery-fake';

  @override
  String get name => 'RecoveryFake';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;

  @override
  Future<void> connect() async {
    connectCount++;
    if (!reconnectSucceeds) {
      throw StateError('reconnect failed');
    }
    _connState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    _connState.add(ConnectionState.disconnected);
  }

  @override
  Future<List<String>> discoverServices() async => [de1ServiceUUID];

  @override
  Future<Uint8List> read(String s, String c, {Duration? timeout}) async =>
      Uint8List(20);

  @override
  Future<void> subscribe(
    String s,
    String c,
    void Function(Uint8List) cb,
  ) async {}

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> write(
    String s,
    String c,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writeCount++;
    if (writeCount == 1) {
      throw BleTimeoutException('write');
    }
  }

  @override
  Future<void> dispose() async => _connState.close();
}

void main() {
  group('UnifiedDe1Transport timeout recovery', () {
    test('successful reconnect after timeout does not surface disconnected '
        'to upstream', () async {
      final fake = _RecoveryFakeTransport(reconnectSucceeds: true);
      addTearDown(fake.dispose);
      final unified = UnifiedDe1Transport(transport: fake);

      final seen = <ConnectionState>[];
      final sub = unified.connectionState.listen(seen.add);
      addTearDown(sub.cancel);

      await unified.write(Endpoint.requestedState, Uint8List.fromList([0x02]));
      await Future<void>.delayed(Duration.zero);

      expect(fake.disconnectCount, 1);
      expect(fake.connectCount, 1);
      expect(fake.writeCount, 2);

      // The deliberate recovery disconnect must stay invisible — otherwise
      // De1Controller would null the machine and tear down a connection
      // that's about to come right back.
      expect(seen, isNot(contains(ConnectionState.disconnected)));
    });

    test(
      'failed reconnect after timeout surfaces disconnected to upstream',
      () async {
        final fake = _RecoveryFakeTransport(reconnectSucceeds: false);
        addTearDown(fake.dispose);
        final unified = UnifiedDe1Transport(transport: fake);

        final seen = <ConnectionState>[];
        final sub = unified.connectionState.listen(seen.add);
        addTearDown(sub.cancel);

        await expectLater(
          unified.write(Endpoint.requestedState, Uint8List.fromList([0x02])),
          throwsA(isA<BleTimeoutException>()),
        );
        await Future<void>.delayed(Duration.zero);

        expect(seen, contains(ConnectionState.disconnected));
      },
    );
  });
}
