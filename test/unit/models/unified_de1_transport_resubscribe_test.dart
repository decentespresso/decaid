import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1_transport.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _Fake extends BLETransport {
  _Fake(ConnectionState initial, {ConnectionState? osProbeState})
    : _connState = BehaviorSubject<ConnectionState>.seeded(initial),
      _osProbeState = osProbeState ?? ConnectionState.disconnected;

  final BehaviorSubject<ConnectionState> _connState;

  final ConnectionState _osProbeState;

  bool throwOnGetConnectionState = false;

  final List<String> callOrder = [];

  final Map<String, void Function(Uint8List)> subscribers = {};

  @override
  String get id => 'fake-id';
  @override
  String get name => 'Fake';
  @override
  Stream<ConnectionState> get connectionState => _connState.stream;
  @override
  Future<ConnectionState> getConnectionState() async {
    if (throwOnGetConnectionState) {
      throw Exception('platform error');
    }
    return _osProbeState;
  }

  @override
  Future<void> connect() async {
    callOrder.add('connect');
    _connState.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    callOrder.add('disconnect');
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
  ) async {
    callOrder.add('subscribe:$c');
    subscribers[c] = cb;
  }

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
  Future<void> dispose() async {}
}

void main() {
  late StreamSubscription<LogRecord> logSub;
  late List<LogRecord> records;

  setUp(() {
    Logger.root.level = Level.ALL;
    records = [];
    logSub = Logger.root.onRecord.listen(records.add);
  });

  tearDown(() async {
    await logSub.cancel();
  });

  test(
    'no-op reconnect tears down stale link before connect and re-subscribe',
    () async {
      final fake = _Fake(ConnectionState.connected);
      final transport = UnifiedDe1Transport(transport: fake);

      await transport.connect();

      final disconnectAt = fake.callOrder.indexOf('disconnect');
      final connectAt = fake.callOrder.indexOf('connect');
      final firstSubscribeAt = fake.callOrder.indexWhere(
        (e) => e.startsWith('subscribe:'),
      );
      expect(
        disconnectAt,
        greaterThanOrEqualTo(0),
        reason: 'no-op reconnect should disconnect the stale link first',
      );
      expect(connectAt, greaterThan(disconnectAt));
      expect(firstSubscribeAt, greaterThan(connectAt));
    },
  );

  test('no-op reconnect no longer records DuplicateBleSubscription (handled '
      'by clean teardown)', () async {
    final transport = UnifiedDe1Transport(
      transport: _Fake(ConnectionState.connected),
    );

    await transport.connect();

    expect(
      records.any((r) => r.error is DuplicateBleSubscription),
      isFalse,
      reason:
          'the no-op reconnect is now handled by a clean disconnect, so '
          'the measurement non-fatal should no longer fire',
    );
  });

  test(
    'first connect (transport disconnected) does not disconnect first',
    () async {
      final fake = _Fake(ConnectionState.disconnected);
      final transport = UnifiedDe1Transport(transport: fake);

      await transport.connect();

      expect(
        fake.callOrder,
        isNot(contains('disconnect')),
        reason: 'a fresh connect must not tear down a link that is not there',
      );
      expect(fake.callOrder, contains('connect'));
    },
  );

  test('re-subscribe after reconnect wires a new stateInfo callback that '
      'drives the state stream', () async {
    final fake = _Fake(ConnectionState.connected);
    final transport = UnifiedDe1Transport(transport: fake);

    await transport.connect();
    final stateInfoUuid = Endpoint.stateInfo.uuid;
    final firstCb = fake.subscribers[stateInfoUuid];
    expect(
      firstCb,
      isNotNull,
      reason: '_bleConnect should subscribe stateInfo on connect',
    );

    final firstSeen = <ByteData>[];
    final sub = transport.state.listen(firstSeen.add);
    firstCb!(Uint8List.fromList([0x05, 0x00, 0x00, 0x00]));
    await Future<void>.delayed(Duration.zero);
    expect(
      firstSeen,
      isNotEmpty,
      reason: 'first listener should receive the pushed state frame',
    );

    await transport.connect();
    final secondCb = fake.subscribers[stateInfoUuid];
    expect(
      secondCb,
      isNot(same(firstCb)),
      reason: 're-subscribe must wire a NEW callback',
    );

    final secondSeen = <ByteData>[];
    final sub2 = transport.state.listen(secondSeen.add);
    secondCb!(Uint8List.fromList([0x06, 0x00, 0x00, 0x00]));
    await Future<void>.delayed(Duration.zero);
    expect(
      secondSeen,
      isNotEmpty,
      reason:
          'new listener must drive the state stream on a post-reconnect '
          'push',
    );

    await sub.cancel();
    await sub2.cancel();
  });

  group('#431 probe-before-teardown', () {
    test(
      'live link: OS probe says connected → teardown does NOT fire',
      () async {
        final fake = _Fake(
          ConnectionState.connected,
          osProbeState: ConnectionState.connected,
        );
        final transport = UnifiedDe1Transport(transport: fake);

        await transport.connect();

        expect(
          fake.callOrder,
          isNot(contains('disconnect')),
          reason: 'teardown must not fire when OS probe confirms live link',
        );
        expect(
          fake.callOrder,
          contains('connect'),
          reason: 'connect must still run to re-establish GATT',
        );
        expect(
          records.any(
            (r) => r.message.contains('skipping stale-link teardown'),
          ),
          isTrue,
        );
      },
    );

    test(
      'dead link: OS probe says disconnected → teardown DOES fire',
      () async {
        final fake = _Fake(
          ConnectionState.connected,
          osProbeState: ConnectionState.disconnected,
        );
        final transport = UnifiedDe1Transport(transport: fake);

        await transport.connect();

        final disconnectAt = fake.callOrder.indexOf('disconnect');
        final connectAt = fake.callOrder.indexOf('connect');
        expect(
          disconnectAt,
          greaterThanOrEqualTo(0),
          reason: 'teardown must fire when OS probe confirms dead link',
        );
        expect(
          connectAt,
          greaterThan(disconnectAt),
          reason: 'connect must come after teardown',
        );
      },
    );

    test(
      'inconclusive probe: throws → teardown DOES fire (safe default)',
      () async {
        final fake = _Fake(ConnectionState.connected);
        fake.throwOnGetConnectionState = true;
        final transport = UnifiedDe1Transport(transport: fake);

        await transport.connect();

        expect(
          fake.callOrder,
          contains('disconnect'),
          reason: 'teardown must fire on inconclusive probe (safe default)',
        );
        expect(fake.callOrder, contains('connect'));
      },
    );
  });
}
