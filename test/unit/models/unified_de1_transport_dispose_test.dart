import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';

/// Fake BLE transport that tracks whether dispose was called.
class _Fake extends BLETransport {
  _Fake()
    : _connState = BehaviorSubject<ConnectionState>.seeded(
        ConnectionState.disconnected,
      );

  final BehaviorSubject<ConnectionState> _connState;
  bool disposeCalled = false;

  @override
  String get id => 'fake-dispose';
  @override
  String get name => 'FakeDispose';
  @override
  Stream<ConnectionState> get connectionState => _connState.stream;
  @override
  Future<ConnectionState> getConnectionState() async =>
      ConnectionState.disconnected;
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
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
  }) async {}
  @override
  Future<void> dispose() async {
    disposeCalled = true;
    if (!_connState.isClosed) _connState.close();
  }
}

// ignore: prefer_function_declarations_over_variables
void main() {
  test(
    'dispose closes all subjects and calls underlying transport dispose',
    () async {
      final fake = _Fake();
      final transport = UnifiedDe1Transport(transport: fake);

      expect(transport.state, isA<Stream>());
      expect(transport.shotSample, isA<Stream>());
      expect(transport.waterLevels, isA<Stream>());
      expect(transport.shotSettings, isA<Stream>());
      expect(transport.mmr, isA<Stream>());
      expect(transport.fwMapRequest, isA<Stream>());

      await transport.dispose();

      expect(fake.disposeCalled, isTrue);

      // After dispose, subjects are closed and complete without emitting
      // placeholder values.
      for (final stream in [
        transport.state,
        transport.shotSample,
        transport.waterLevels,
        transport.shotSettings,
        transport.mmr,
        transport.fwMapRequest,
      ]) {
        final events = await stream.toList();
        expect(events, isEmpty);
      }
    },
  );

  test('dispose is safe to call more than once', () async {
    final fake = _Fake();
    final transport = UnifiedDe1Transport(transport: fake);

    await transport.dispose();
    expect(fake.disposeCalled, isTrue);

    // Second call should not throw
    fake.disposeCalled = false;
    await transport.dispose();
    expect(fake.disposeCalled, isTrue);
  });
}
