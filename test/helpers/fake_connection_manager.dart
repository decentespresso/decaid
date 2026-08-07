import 'dart:async';

import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

import 'mock_de1_controller.dart';
import 'mock_device_scanner.dart';
import 'mock_scale_controller.dart';
import 'mock_settings_service.dart';

class FakeConnectionManager extends ConnectionManager {
  final BehaviorSubject<ConnectionStatus> _statusOverride =
      BehaviorSubject.seeded(const ConnectionStatus());

  int connectCalls = 0;
  int automaticConnectCalls = 0;
  int scanAndConnectCalls = 0;
  int cancelSelectionSessionCalls = 0;
  int cancelActiveScanCalls = 0;
  bool _scaleOnlyLastCall = false;
  bool get scaleOnlyLastCall => _scaleOnlyLastCall;

  FakeConnectionManager.forSubclass({
    required super.deviceScanner,
    required super.de1Controller,
    required super.scaleController,
    required super.settingsController,
  });

  factory FakeConnectionManager() {
    final scanner = MockDeviceScanner();
    final de1 = MockDe1Controller(controller: DeviceController([]));
    final scale = MockScaleController();
    final settings = SettingsController(MockSettingsService());
    return FakeConnectionManager.forSubclass(
      deviceScanner: scanner,
      de1Controller: de1,
      scaleController: scale,
      settingsController: settings,
    );
  }

  @override
  Stream<ConnectionStatus> get status => _statusOverride.stream;

  @override
  ConnectionStatus get currentStatus => _statusOverride.value;

  void emitStatus(ConnectionStatus status) => _statusOverride.add(status);

  void setError(ConnectionError? err) {
    _statusOverride.add(_statusOverride.value.copyWith(error: () => err));
  }

  @override
  Future<void> connect({bool scaleOnly = false}) async {
    connectCalls += 1;
    automaticConnectCalls += 1;
    _scaleOnlyLastCall = scaleOnly;
  }

  @override
  Future<void> scanAndConnect() async {
    connectCalls += 1;
    scanAndConnectCalls += 1;
    _scaleOnlyLastCall = false;
  }

  @override
  void cancelActiveScan() {
    cancelActiveScanCalls += 1;
  }

  @override
  void cancelSelectionSession() {
    cancelSelectionSessionCalls += 1;
  }

  @override
  Future<void> dispose() async {
    _statusOverride.close();
    await super.dispose();
  }
}
