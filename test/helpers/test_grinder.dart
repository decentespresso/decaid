import 'dart:async';

import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/grinder_device.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/rxdart.dart';

class TestGrinder implements GrinderDevice {
  TestGrinder({
    required this.deviceId,
    this.connectGate,
    this.disconnectGate,
    this.connectError,
    this.emitInitialSnapshot = false,
  });

  @override
  final String deviceId;
  final Completer<void>? connectGate;
  final Completer<void>? disconnectGate;
  final Object? connectError;
  final bool emitInitialSnapshot;
  final BehaviorSubject<ConnectionState> _connection = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final PublishSubject<GrinderSnapshot> _snapshots = PublishSubject();
  final List<String> operations = [];
  int onConnectCalls = 0;
  int disconnectCalls = 0;

  void connect() => _connection.add(ConnectionState.connected);

  void emit(GrinderState state, {String? setting, int? rpm}) => _snapshots.add(
    GrinderSnapshot(
      timestamp: DateTime.now().toUtc(),
      state: state,
      setting: setting,
      rpm: rpm,
    ),
  );

  @override
  Set<GrinderCapability> get capabilities => GrinderCapability.values.toSet();
  @override
  Stream<GrinderSnapshot> get currentSnapshot => _snapshots.stream;
  @override
  Stream<ConnectionState> get connectionState => _connection.stream;
  @override
  DeviceImplementation get implementation => DeviceImplementation.plugin;
  @override
  String get name => deviceId;
  @override
  TransportType get transportType => TransportType.unknown;
  @override
  DeviceType get type => DeviceType.grinder;

  @override
  Future<void> onConnect() async {
    onConnectCalls++;
    await connectGate?.future;
    final error = connectError;
    if (error != null) throw error;
    connect();
    if (emitInitialSnapshot) emit(GrinderState.idle);
  }

  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    await disconnectGate?.future;
    _connection.add(ConnectionState.disconnected);
  }

  @override
  Future<void> start() async => operations.add('start');
  @override
  Future<void> stop() async => operations.add('stop');
  @override
  Future<void> setGrindSetting(String setting) async =>
      operations.add('setting:$setting');
  @override
  Future<void> setRpm(int rpm) async => operations.add('rpm:$rpm');

  Future<void> dispose() async {
    await _connection.close();
    await _snapshots.close();
  }
}
