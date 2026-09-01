import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/simulated_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

class MockGrinder implements Grinder, SimulatedDevice {
  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);
  final StreamController<GrinderSnapshot> _snapshotStream =
      StreamController.broadcast();

  Timer? _broadcastTimer;
  GrinderDevState _devState = GrinderDevState.idle;
  int _grindRpm = 750;
  int _feedingRpm = 30;
  int _grindSetting = 400;

  @override
  Stream<ConnectionState> get connectionState => _connectionSubject.stream;

  @override
  Stream<GrinderSnapshot> get currentSnapshot => _snapshotStream.stream;

  @override
  Stream<GrinderLogEntry> get logStream => const Stream.empty();

  @override
  String get deviceId => 'MockGrinder';

  @override
  DeviceImplementation get implementation => DeviceImplementation.bookooGrinder;

  @override
  TransportType get transportType => TransportType.unknown;

  @override
  String get name => 'Mock Grinder';

  @override
  Future<void> onConnect() async {
    _connectionSubject.add(ConnectionState.connected);
    _broadcastTimer ??= Timer.periodic(const Duration(milliseconds: 200), (_) {
      _snapshotStream.add(_snapshot());
    });
  }

  @override
  Future<void> disconnect() async {
    simulateDisconnect();
  }

  @override
  DeviceType get type => DeviceType.grinder;

  void simulateDisconnect() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _connectionSubject.add(ConnectionState.disconnected);
  }

  @override
  Future<void> start() async {
    _devState = GrinderDevState.grinding;
    _snapshotStream.add(_snapshot());
  }

  @override
  Future<void> stop() async {
    _devState = GrinderDevState.idle;
    _snapshotStream.add(_snapshot());
  }

  @override
  Future<void> querySections() async {}

  @override
  Future<void> queryPresets() async {}

  @override
  Future<void> setGrindSection({int? index, String? name}) async {}

  @override
  Future<void> setPreset({String? uid, int? index}) async {}

  @override
  Future<void> setFeedingRpm(int rpm) async {
    _feedingRpm = rpm;
    _snapshotStream.add(_snapshot());
  }

  @override
  Future<void> setGrindRpm(int rpm) async {
    _grindRpm = rpm;
    _snapshotStream.add(_snapshot());
  }

  @override
  Future<void> setGrindSetting(int value) async {
    _grindSetting = value;
    _snapshotStream.add(_snapshot());
  }

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

  GrinderSnapshot _snapshot() {
    return GrinderSnapshot(
      timestamp: DateTime.now(),
      devState: _devState,
      feedingRpm: _feedingRpm,
      grindRpm: _grindRpm,
      grindSetting: _grindSetting,
      presets: const [
        GrinderPreset(uid: 'mock-fine', name: 'Mock Fine'),
        GrinderPreset(uid: 'mock-coarse', name: 'Mock Coarse'),
      ],
      grindSections: const [
        GrindSection(index: 0, name: 'Fine'),
        GrindSection(index: 1, name: 'Coarse'),
      ],
    );
  }
}
