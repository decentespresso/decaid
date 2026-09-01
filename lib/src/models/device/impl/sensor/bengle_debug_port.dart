import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

/// Lossless raw byte tunnel for the Bengle EBus tap (USB interface 2).
///
/// Each serial read chunk becomes one snapshot with the chunk base64-encoded
/// under `bytes`; concatenating decoded chunks reproduces the exact serial
/// byte stream. ReaPrime does not interpret or modify the stream.
class BengleDebugPort implements Sensor {
  late final Logger _log;
  final SerialTransport _transport;

  BengleDebugPort({required SerialTransport transport})
    : _transport = transport {
    _log = Logger("Bengle EBus Tap(${transport.name})");
  }

  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionSubject.asBroadcastStream();

  final StreamController<Map<String, dynamic>> _streamSubject =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get data => _streamSubject.stream;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation =>
      DeviceImplementation.bengleDebugPort;

  @override
  TransportType get transportType => _transport.transportType;

  StreamSubscription<Uint8List>? _transportSubscription;
  bool _disconnected = false;

  /// Shared in-flight connect so concurrent [onConnect] calls produce exactly
  /// one raw subscription and one transport connect (one-reader ownership).
  Future<void>? _inFlightConnect;

  @override
  Future<void> onConnect() => _ensureConnected();

  Future<void> _ensureConnected() async {
    if (await _connectionSubject.first == ConnectionState.connected) return;
    await (_inFlightConnect ??= _doConnect());
  }

  Future<void> _doConnect() async {
    _disconnected = false;
    final subscription = _transport.rawStream.listen(
      (chunk) {
        _streamSubject.add({
          'timestamp': DateTime.now().toIso8601String(),
          'bytes': base64Encode(chunk),
        });
      },
      onError: (Object error) {
        _log.warning("transport error", error);
        disconnect();
      },
      onDone: () {
        disconnect();
      },
    );
    try {
      await _transport.connect();
    } catch (e, st) {
      _log.warning("connect failed", e, st);
      await subscription.cancel();
      _inFlightConnect = null;
      rethrow;
    }
    if (_disconnected) {
      // A disconnect raced the shared connect; the transport was already
      // released by that disconnect.
      await subscription.cancel();
      _inFlightConnect = null;
      return;
    }
    _transportSubscription = subscription;
    _connectionSubject.add(ConnectionState.connected);
    _inFlightConnect = null;
  }

  @override
  Future<void> disconnect() async {
    if (_disconnected) return;
    _disconnected = true;
    _connectionSubject.add(ConnectionState.disconnected);
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    await _transport.disconnect();
  }

  @override
  Future<Map<String, dynamic>> execute(
    String commandId,
    Map<String, dynamic>? parameters,
  ) async {
    if (commandId != "write") {
      throw 'Invalid command: $commandId';
    }
    final encoded = parameters?["bytes"];
    if (encoded is! String) {
      throw 'Parameter "bytes" (base64 string) required';
    }
    final bytes = base64Decode(encoded);
    await _transport.writeHexCommand(bytes);
    return {'bytesWritten': bytes.length};
  }

  @override
  SensorInfo get info => SensorInfo(
    name: "Bengle EBus Tap",
    vendor: "Decent Espresso",
    dataChannels: [DataChannel(key: "bytes", type: "string", unit: "base64")],
    commands: [
      CommandDescriptor(
        id: "write",
        name: "write",
        description: "Write raw bytes to the EBus tap",
        paramsSchema: {"bytes": "string"},
        resultsSchema: null,
      ),
    ],
  );

  @override
  String get name => "Bengle EBus Tap";

  @override
  DeviceType get type => DeviceType.sensor;
}
