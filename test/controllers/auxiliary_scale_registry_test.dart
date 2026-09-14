import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/connection/connection_selection_session.dart';
import 'package:reaprime/src/controllers/connection/policy_resolver.dart';
import 'package:reaprime/src/controllers/connection/scan_report_builder.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';

class _FakeScale extends Scale {
  _FakeScale(this.deviceId, {this.connectsTo = ConnectionState.connected});

  @override
  final String deviceId;

  final ConnectionState connectsTo;

  final _connection = StreamController<ConnectionState>.broadcast();
  final _snapshots = StreamController<ScaleSnapshot>.broadcast();

  ConnectionState _state = ConnectionState.disconnected;
  int tareCount = 0;
  int disconnectCount = 0;
  int connectCount = 0;

  @override
  String get name => 'Fake $deviceId';

  @override
  DeviceType get type => DeviceType.scale;

  @override
  DeviceImplementation get implementation => DeviceImplementation.decentScale;

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<ConnectionState> get connectionState async* {
    yield _state;
    yield* _connection.stream;
  }

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshots.stream;

  @override
  Future<void> onConnect() async {
    connectCount++;
    emitConnection(connectsTo);
  }

  @override
  Future<void> disconnect() async {
    disconnectCount++;
    emitConnection(ConnectionState.disconnected);
  }

  @override
  Future<void> tare() async => tareCount++;

  @override
  Future<void> sleepDisplay() async {}

  @override
  Future<void> wakeDisplay() async {}

  void emitConnection(ConnectionState state) {
    _state = state;
    _connection.add(state);
  }

  void emitWeight(double grams) {
    _snapshots.add(
      ScaleSnapshot(timestamp: DateTime.now(), weight: grams, batteryLevel: 80),
    );
  }

  Future<void> close() async {
    await _connection.close();
    await _snapshots.close();
  }
}

ConnectionSelectionSession _session(
  List<Scale> scales, {
  Set<String> auxiliaryScaleIds = const {},
  String? preferredScaleId,
}) {
  return ConnectionSelectionSession(
    machines: const [],
    scales: scales,
    preferredMachineId: null,
    preferredScaleId: preferredScaleId,
    auxiliaryScaleIds: auxiliaryScaleIds,
    scanReport: ScanReportBuilder(scanStartTime: DateTime.now()),
  );
}

void main() {
  group('a held scale is not a candidate for brewing', () {
    test('auto-selection skips it and takes the other one', () {
      final brew = _FakeScale('brew-1');
      final held = _FakeScale('held-1');
      final session = _session([brew, held], auxiliaryScaleIds: {'held-1'});

      expect(session.acceptsScale(brew), isTrue);
      expect(session.acceptsScale(held), isFalse);
      expect(session.isAuxiliaryScale('held-1'), isTrue);
    });

    test('with nothing held every scale is a candidate', () {
      final one = _FakeScale('scale-1');
      final two = _FakeScale('scale-2');
      final session = _session([one, two]);

      expect(session.acceptsScale(one), isTrue);
      expect(session.acceptsScale(two), isTrue);
      expect(session.isAuxiliaryScale('scale-1'), isFalse);
    });

    test('holding an id no scan saw changes nothing', () {
      final one = _FakeScale('scale-1');
      final session = _session([one], auxiliaryScaleIds: {'absent-1'});

      expect(session.acceptsScale(one), isTrue);
    });

    test('an inactive session accepts nothing, held or not', () {
      final one = _FakeScale('scale-1');
      final session = _session([one], auxiliaryScaleIds: {'held-1'});
      session.invalidate();

      expect(session.acceptsScale(one), isFalse);
    });
  });

  // The list the brewing policy is handed is the real decision point;
  // acceptsScale guards the late arrivals. This mirrors the filter the
  // connection manager applies before resolving the policy.
  group('the list brewing is offered', () {
    List<Scale> brewCandidates(List<Scale> scales, Set<String> held) =>
        held.isEmpty
        ? scales
        : scales.where((s) => !held.contains(s.deviceId)).toList();

    test('one held, one free: brewing connects the free one unprompted', () {
      final brew = _FakeScale('brew-1');
      final held = _FakeScale('held-1');
      final offered = brewCandidates([brew, held], {'held-1'});

      expect(offered, [brew]);
      final action = resolveScalePolicy(
        scales: offered,
        preferredScaleId: null,
      );
      expect(action, isA<ConnectScaleAction>());
      expect((action as ConnectScaleAction).scale.deviceId, 'brew-1');
    });

    test('without the filter, two scales would ask the user to choose', () {
      final brew = _FakeScale('brew-1');
      final held = _FakeScale('held-1');
      final action = resolveScalePolicy(
        scales: [brew, held],
        preferredScaleId: null,
      );
      expect(action, isA<ScalePickerAction>());
    });

    test('nothing held leaves the list untouched', () {
      final one = _FakeScale('scale-1');
      final two = _FakeScale('scale-2');
      expect(brewCandidates([one, two], const {}), [one, two]);
    });

    test('only a held scale in range leaves brewing with nothing', () {
      final held = _FakeScale('held-1');
      final offered = brewCandidates([held], {'held-1'});

      expect(offered, isEmpty);
      expect(
        resolveScalePolicy(scales: offered, preferredScaleId: null),
        isA<NoScaleAction>(),
      );
    });

    test('a preferred scale still wins among the rest', () {
      final brew = _FakeScale('brew-1');
      final other = _FakeScale('brew-2');
      final held = _FakeScale('held-1');
      final offered = brewCandidates([brew, other, held], {'held-1'});

      final action = resolveScalePolicy(
        scales: offered,
        preferredScaleId: 'brew-2',
      );
      expect(action, isA<ConnectScaleAction>());
      expect((action as ConnectScaleAction).scale.deviceId, 'brew-2');
    });

    test('holding the remembered scale asks rather than silently swapping', () {
      final held = _FakeScale('held-1');
      final other = _FakeScale('brew-2');
      final offered = brewCandidates([held, other], {'held-1'});

      expect(offered, [other]);
      expect(
        resolveScalePolicy(scales: offered, preferredScaleId: 'held-1'),
        isA<ScalePickerAction>(),
      );
    });

    test('holding the remembered scale with nothing else connects nothing', () {
      final held = _FakeScale('held-1');
      final offered = brewCandidates([held], {'held-1'});

      expect(
        resolveScalePolicy(scales: offered, preferredScaleId: 'held-1'),
        isA<NoScaleAction>(),
      );
    });
  });

  group('AuxiliaryScaleSession', () {
    late _FakeScale scale;

    setUp(() => scale = _FakeScale('aux-1'));
    tearDown(() async => scale.close());

    test('starts disconnected and refuses to tare', () async {
      final session = AuxiliaryScaleSession(scale);
      expect(session.currentConnectionState, ConnectionState.disconnected);
      expect(session.tare, throwsA(isA<DeviceNotConnectedException>()));
      await session.dispose();
    });

    test('connects, then reports weight on its own stream', () async {
      final session = AuxiliaryScaleSession(scale);
      await session.connect();
      expect(session.currentConnectionState, ConnectionState.connected);

      final seen = <double>[];
      final sub = session.snapshot.listen((s) => seen.add(s.weight));
      scale.emitWeight(18.2);
      await Future<void>.delayed(Duration.zero);

      expect(seen, [18.2]);
      expect(session.currentSnapshot?.weight, 18.2);
      await sub.cancel();
      await session.dispose();
    });

    test('tare reaches the scale it is connected to', () async {
      final session = AuxiliaryScaleSession(scale);
      await session.connect();
      await session.tare();
      expect(scale.tareCount, 1);
      await session.dispose();
    });

    test('forgets the reading when the scale drops', () async {
      final session = AuxiliaryScaleSession(scale);
      await session.connect();
      scale.emitWeight(12.0);
      await Future<void>.delayed(Duration.zero);
      expect(session.currentSnapshot, isNotNull);

      scale.emitConnection(ConnectionState.disconnected);
      await Future<void>.delayed(Duration.zero);
      expect(session.currentSnapshot, isNull);
      expect(session.currentConnectionState, ConnectionState.disconnected);
      await session.dispose();
    });

    test('disconnect releases the device and bumps the generation', () async {
      final session = AuxiliaryScaleSession(scale);
      await session.connect();
      final before = session.generation;
      await session.disconnect();

      expect(scale.disconnectCount, 1);
      expect(session.generation, greaterThan(before));
      expect(session.currentConnectionState, ConnectionState.disconnected);
      await session.dispose();
    });

    test('a scale that never reaches connected throws and lets go', () async {
      final refuses = _FakeScale(
        'aux-2',
        connectsTo: ConnectionState.disconnected,
      );
      final session = AuxiliaryScaleSession(refuses);
      await expectLater(session.connect(), throwsA(isA<StateError>()));
      expect(session.currentConnectionState, ConnectionState.disconnected);
      await session.dispose();
      await refuses.close();
    });

    test('adopting an already connected scale needs no new connect', () async {
      scale.emitConnection(ConnectionState.connected);
      final session = AuxiliaryScaleSession(scale);
      await session.adopt();

      expect(scale.connectCount, 0);
      expect(session.currentConnectionState, ConnectionState.connected);
      await session.dispose();
    });
  });

  group('AuxiliaryScaleRegistry', () {
    late AuxiliaryScaleRegistry registry;

    setUp(() => registry = AuxiliaryScaleRegistry());
    tearDown(() async => registry.dispose());

    test('holds a scale and hands the same session back', () async {
      final scale = _FakeScale('aux-1');
      final first = await registry.connect(scale);
      final second = await registry.connect(scale);

      expect(identical(first, second), isTrue);
      expect(scale.connectCount, 1);
      expect(registry.holds('aux-1'), isTrue);
      expect(registry.deviceIds, {'aux-1'});
      await scale.close();
    });

    test('two scales coexist, each with its own readings', () async {
      final one = _FakeScale('aux-1');
      final two = _FakeScale('aux-2');
      final sessionOne = await registry.connect(one);
      final sessionTwo = await registry.connect(two);

      final seenOne = <double>[];
      final seenTwo = <double>[];
      final subOne = sessionOne.snapshot.listen((s) => seenOne.add(s.weight));
      final subTwo = sessionTwo.snapshot.listen((s) => seenTwo.add(s.weight));

      one.emitWeight(18.0);
      two.emitWeight(36.0);
      await Future<void>.delayed(Duration.zero);

      expect(seenOne, [18.0]);
      expect(seenTwo, [36.0]);

      await sessionOne.tare();
      expect(one.tareCount, 1);
      expect(two.tareCount, 0);

      await subOne.cancel();
      await subTwo.cancel();
      await one.close();
      await two.close();
    });

    test('releasing one leaves the other connected', () async {
      final one = _FakeScale('aux-1');
      final two = _FakeScale('aux-2');
      await registry.connect(one);
      final sessionTwo = await registry.connect(two);

      await registry.release('aux-1');

      expect(registry.holds('aux-1'), isFalse);
      expect(registry.holds('aux-2'), isTrue);
      expect(one.disconnectCount, 1);
      expect(two.disconnectCount, 0);
      expect(sessionTwo.currentConnectionState, ConnectionState.connected);

      two.emitWeight(21.0);
      await Future<void>.delayed(Duration.zero);
      expect(sessionTwo.currentSnapshot?.weight, 21.0);

      await one.close();
      await two.close();
    });

    test('releasing an id nobody holds is not an error', () async {
      await registry.release('never-held');
      expect(registry.deviceIds, isEmpty);
    });

    test('a failed connect leaves nothing held', () async {
      final refuses = _FakeScale(
        'aux-1',
        connectsTo: ConnectionState.disconnected,
      );
      await expectLater(registry.connect(refuses), throwsA(isA<StateError>()));
      expect(registry.holds('aux-1'), isFalse);
      await refuses.close();
    });

    test('changes announce what is held after each add and remove', () async {
      final one = _FakeScale('aux-1');
      final two = _FakeScale('aux-2');
      final seen = <Set<String>>[];
      final sub = registry.changes.listen(seen.add);

      await registry.connect(one);
      await registry.connect(two);
      await registry.release('aux-1');
      await Future<void>.delayed(Duration.zero);

      expect(seen, [
        {'aux-1'},
        {'aux-1', 'aux-2'},
        {'aux-2'},
      ]);

      await sub.cancel();
      await one.close();
      await two.close();
    });

    test('releaseAll lets go of everything', () async {
      final one = _FakeScale('aux-1');
      final two = _FakeScale('aux-2');
      await registry.connect(one);
      await registry.connect(two);

      await registry.releaseAll();

      expect(registry.deviceIds, isEmpty);
      expect(one.disconnectCount, 1);
      expect(two.disconnectCount, 1);
      await one.close();
      await two.close();
    });

    test('a released scale becomes an ordinary brewing candidate', () async {
      final scale = _FakeScale('aux-1');
      await registry.connect(scale);
      expect(
        _session([
          scale,
        ], auxiliaryScaleIds: registry.deviceIds).acceptsScale(scale),
        isFalse,
      );

      await registry.release('aux-1');
      expect(
        _session([
          scale,
        ], auxiliaryScaleIds: registry.deviceIds).acceptsScale(scale),
        isTrue,
      );
      await scale.close();
    });
  });
}
