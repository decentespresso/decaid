import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/grinder_controller.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _FakeGrinder implements Grinder {
  _FakeGrinder(this._id, {bool failConnect = false})
    : _failConnect = failConnect;

  final String _id;
  final bool _failConnect;

  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final StreamController<GrinderSnapshot> snapshots =
      StreamController.broadcast();

  @override
  String get deviceId => _id;

  @override
  String get name => 'Fake Grinder';

  @override
  DeviceImplementation get implementation => DeviceImplementation.bookooGrinder;

  @override
  TransportType get transportType => TransportType.ble;

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Stream<GrinderSnapshot> get currentSnapshot => snapshots.stream;

  @override
  DeviceType get type => DeviceType.grinder;

  @override
  Future<void> onConnect() async {
    if (_failConnect) throw StateError('connect failed');
    states.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async => states.add(ConnectionState.disconnected);

  @override
  Stream<GrinderLogEntry> get logStream => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> querySections() async {}

  @override
  Future<void> queryPresets() async {}

  @override
  Future<void> setGrindSection({int? index, String? name}) async {}

  @override
  Future<void> setPreset({String? uid, int? index}) async {}

  @override
  Future<void> setFeedingRpm(int rpm) async {}

  @override
  Future<void> setGrindRpm(int rpm) async {}

  @override
  Future<void> setGrindSetting(int value) async {}

  @override
  Future<void> setBrightness(int level) async {}

  @override
  Future<void> setStandbySec(int seconds) async {}

  @override
  Future<void> setCupDetect(bool enabled) async {}

  @override
  Future<void> setAutoStop(bool enabled) async {}

  @override
  Future<void> setFastClean(bool enabled) async {}

  @override
  Future<void> reboot() async {}
}

GrinderSnapshot _snapshot({GrinderDevState devState = GrinderDevState.idle}) {
  return GrinderSnapshot(timestamp: DateTime.now(), devState: devState);
}

void main() {
  test('connectToGrinder forwards snapshots and connection state', () async {
    final controller = GrinderController();
    final grinder = _FakeGrinder('grinder-1');
    final snapshots = <GrinderSnapshot>[];
    final states = <ConnectionState>[];
    controller.grinderSnapshot.listen(snapshots.add);
    controller.connectionState.listen(states.add);

    await controller.connectToGrinder(grinder);
    grinder.snapshots.add(_snapshot(devState: GrinderDevState.grinding));
    await Future<void>.delayed(Duration.zero);

    expect(controller.lastConnectedDeviceId, 'grinder-1');
    expect(controller.connectedGrinder(), same(grinder));
    expect(snapshots.single.devState, GrinderDevState.grinding);
    expect(controller.currentConnectionState, ConnectionState.connected);

    controller.dispose();
    await grinder.snapshots.close();
    await grinder.states.close();
  });

  test('connectToGrinder throws when onConnect fails', () async {
    final controller = GrinderController();
    final grinder = _FakeGrinder('grinder-2', failConnect: true);

    await expectLater(controller.connectToGrinder(grinder), throwsStateError);
    expect(controller.currentConnectionState, ConnectionState.disconnected);

    controller.dispose();
    await grinder.states.close();
  });

  test('connectedGrinder throws when no grinder is connected', () {
    final controller = GrinderController();
    expect(
      () => controller.connectedGrinder(),
      throwsA(isA<DeviceNotConnectedException>()),
    );
    controller.dispose();
  });

  test('adoptGrinder accepts an already-connected grinder', () async {
    final controller = GrinderController();
    final grinder = _FakeGrinder('grinder-3');
    await grinder.onConnect();

    await controller.adoptGrinder(grinder);
    await Future<void>.delayed(Duration.zero);
    expect(controller.lastConnectedDeviceId, 'grinder-3');
    expect(controller.currentConnectionState, ConnectionState.connected);

    controller.dispose();
    await grinder.states.close();
  });
}
