import 'dart:async';
import 'dart:typed_data';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

import 'package:reaprime/src/models/device/device.dart';

import 'package:reaprime/src/models/errors.dart';
import '../../scale.dart';

class HiroiaScale implements Scale {
  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.long('06c31822-8682-4744-9211-febc93e3bece');
  static final BleServiceIdentifier dataCharacteristic =
      BleServiceIdentifier.long('06c31824-8682-4744-9211-febc93e3bece');
  static final BleServiceIdentifier writeCharacteristic =
      BleServiceIdentifier.long('06c31823-8682-4744-9211-febc93e3bece');

  final String _deviceId;

  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();

  final BLETransport _transport;

  HiroiaScale({required BLETransport transport})
    : _transport = transport,
      _deviceId = transport.id;

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.hiroiaScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => "Hiroia Jimmy";

  final StreamController<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  Future<void> onConnect() async {
    if (await _transport.connectionState.first == ConnectionState.connected) {
      return;
    }
    _connectionStateController.add(ConnectionState.connecting);

    StreamSubscription<ConnectionState>? disconnectSub;

    try {
      await _transport.connect();

      disconnectSub = _transport.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            _connectionStateController.add(ConnectionState.disconnected);
            disconnectSub?.cancel();
          });

      final services = await _transport.discoverServices();
      if (!serviceIdentifier.matchesAny(services)) {
        throw Exception(
          'Expected service ${serviceIdentifier.long} not found. '
          'Discovered services: $services',
        );
      }
      await _registerNotifications();
      _connectionStateController.add(ConnectionState.connected);
    } catch (e) {
      disconnectSub?.cancel();
      _connectionStateController.add(ConnectionState.disconnected);
      try {
        await _transport.disconnect();
      } catch (_) {}
    }
  }

  @override
  disconnect() async {
    await _transport.disconnect();
  }

  @override
  DeviceType get type => DeviceType.scale;

  /// Safe write — catches [DeviceNotConnectedException] so a write to a
  /// disconnected scale doesn't escape as a FATAL (Crashlytics fa51312d).
  Future<void> _safeWrite(Uint8List data) async {
    try {
      await _transport.write(
        serviceIdentifier.long,
        writeCharacteristic.long,
        data,
        withResponse: false,
      );
    } on DeviceNotConnectedException {
      // Transport already emitted disconnected.
    }
  }

  @override
  Future<void> tare() async {
    await _safeWrite(Uint8List.fromList([0x07, 0x00]));
  }

  @override
  Future<void> sleepDisplay() async {
    await disconnect();
  }

  @override
  Future<void> wakeDisplay() async {}

  Future<void> _registerNotifications() async {
    await _transport.subscribe(
      serviceIdentifier.long,
      dataCharacteristic.long,
      _parseNotification,
    );
  }

  /// Send toggle unit command to switch the scale back to grams
  Future<void> _sendToggleUnit() async {
    await _safeWrite(Uint8List.fromList([0x0b, 0x00]));
  }

  void _parseNotification(List<int> data) {
    if (data.length < 7) return;

    int mode = data[0];

    if (mode > 0x08) {
      _sendToggleUnit();
      return;
    }

    int sign = data[6];
    int msw = data[5];
    int lsw = data[4];
    int weight = 256 * msw + lsw;

    if (sign == 255) {
      weight = (65536 - weight) * -1;
    }

    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight / 10.0,
        batteryLevel: 0,
      ),
    );
  }

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}
}
