import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/protocol.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

class HDSSerial implements Scale, TransportHandoffScale {
  late Logger _log;
  final SerialTransport _transport;

  static const _enableCommand = [0x03, 0x20, 0x01, 0x01];
  static const _initializationTimeout = Duration(seconds: 2);
  static const _weightFrameLength = 7;
  static const _watchdogInterval = Duration(seconds: 2);
  static const _warningTicks = 3;
  static const _disconnectTicks = 6;

  HDSSerial({required SerialTransport transport}) : _transport = transport {
    _log = Logger("Serial HDS#${_transport.name}");
  }

  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);
  @override
  Stream<ConnectionState> get connectionState =>
      _connectionSubject.asBroadcastStream();

  @override
  Stream<ScaleSnapshot> get currentSnapshot =>
      _snapshotHandler.asBroadcastStream();

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.hdsSerial;

  @override
  TransportType get transportType => _transport.transportType;

  bool _isDisconnecting = false;
  Timer? _watchdogTimer;
  Completer<void>? _initialization;
  bool _enableWriteComplete = false;
  bool _initialWeightReceived = false;
  int _ticksSinceLastData = 0;
  bool _retryAttempted = false;
  final List<int> _inputBuffer = [];

  @override
  disconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    final uptimeSec = _watchdogTotalTicks * _watchdogInterval.inSeconds;
    _log.info(
      "disconnecting (rawChunks=$_rawChunks, rawBytes=$_rawBytes, validWeightFrames=$_validWeightFrames, invalidFrames=$_invalidFrames, checksumFailures=$_checksumFailures, uptime=${uptimeSec}s)",
    );
    try {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
      if (_initialization case final initialization?
          when !initialization.isCompleted) {
        initialization.completeError(const DeviceNotConnectedException.scale());
      }
      _connectionSubject.add(ConnectionState.disconnected);
      _transportSubscription?.cancel();
      await _transport.disconnect();
    } catch (e) {
      _log.warning("Error during disconnect", e);
    } finally {
      _isDisconnecting = false;
    }
  }

  @override
  Future<void> disconnectForHandoff() => disconnect();

  @override
  String get name => "Half Decent Scale (USB)";

  StreamSubscription<Uint8List>? _transportSubscription;
  int _rawChunks = 0;
  int _rawBytes = 0;
  int _validWeightFrames = 0;
  int _invalidFrames = 0;
  int _checksumFailures = 0;

  @override
  Future<void> onConnect() async {
    _log.info("on connect (id=$deviceId, transport=${_transport.name})");
    _rawChunks = 0;
    _rawBytes = 0;
    _validWeightFrames = 0;
    _invalidFrames = 0;
    _checksumFailures = 0;
    _inputBuffer.clear();
    _enableWriteComplete = false;
    _initialWeightReceived = false;
    _connectionSubject.add(ConnectionState.connecting);
    await _transport.connect();
    final initialization = Completer<void>();
    _initialization = initialization;
    _transportSubscription = _transport.rawStream.listen(
      onData,
      onError: (Object error, StackTrace stackTrace) {
        _completeInitializationError(error, stackTrace);
        _log.warning("transport error", error);
        disconnect();
      },
      onDone: () {
        _completeInitializationError(
          StateError('HDS USB transport closed during initialization'),
        );
        disconnect();
      },
    );

    try {
      final enableWrite = _transport
          .writeHexCommand(Uint8List.fromList(_enableCommand))
          .then((_) {
            if (!identical(_initialization, initialization)) return;
            _enableWriteComplete = true;
            _completeInitializationIfReady();
          });
      await Future.wait<void>([
        enableWrite,
        initialization.future.timeout(
          _initializationTimeout,
          onTimeout: () {
            if (_initialWeightReceived) return initialization.future;
            throw const EndpointUnavailableException(
              'HDS USB weight stream',
              _initializationTimeout,
            );
          },
        ),
      ], eagerError: true);
    } catch (_) {
      if (identical(_initialization, initialization)) {
        _initialization = null;
      }
      await disconnect();
      rethrow;
    }
    if (identical(_initialization, initialization)) {
      _initialization = null;
    }
    _startWatchdog();
    _connectionSubject.add(ConnectionState.connected);
  }

  void _completeInitializationError(Object error, [StackTrace? stackTrace]) {
    if (_initialization case final initialization?
        when !initialization.isCompleted) {
      initialization.completeError(error, stackTrace);
    }
  }

  void _completeInitializationIfReady() {
    final initialization = _initialization;
    if (_enableWriteComplete &&
        _initialWeightReceived &&
        initialization != null &&
        !initialization.isCompleted) {
      initialization.complete();
    }
  }

  int _watchdogTotalTicks = 0;

  void _startWatchdog() {
    _ticksSinceLastData = 0;
    _retryAttempted = false;
    _watchdogTotalTicks = 0;
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      _ticksSinceLastData++;
      _watchdogTotalTicks++;

      if (_watchdogTotalTicks % 150 == 0) {
        final uptimeMin =
            (_watchdogTotalTicks * _watchdogInterval.inSeconds) ~/ 60;
        _log.fine(
          "heartbeat: ${uptimeMin}m uptime, $_validWeightFrames valid weight frames received",
        );
      }

      if (_ticksSinceLastData >= _disconnectTicks) {
        _log.severe(
          "No data for ${_disconnectTicks * _watchdogInterval.inSeconds}s "
          "(validWeightFrames=$_validWeightFrames, uptime=${_watchdogTotalTicks * _watchdogInterval.inSeconds}s), disconnecting",
        );
        disconnect();
      } else if (_ticksSinceLastData >= _warningTicks && !_retryAttempted) {
        _retryAttempted = true;
        _log.warning(
          "No data for ${_warningTicks * _watchdogInterval.inSeconds}s "
          "(validWeightFrames=$_validWeightFrames), resending enable command",
        );
        _transport.writeHexCommand(Uint8List.fromList(_enableCommand));
      }
    });
  }

  @override
  Future<void> tare() async {
    await _transport.writeHexCommand(
      buildDecentScaleCommand([0x0F, 0x00, 0x00, 0x00, 0x01]),
    );
  }

  @override
  Future<void> sleepDisplay() async {
    _log.info('Putting serial Decent Scale display to sleep');
    await _sendOledOff();
  }

  @override
  Future<void> wakeDisplay() async {
    _log.info('Waking serial Decent Scale display');
    await _sendOledOn();
  }

  Future<void> _sendOledOn() async {
    List<int> payload = [];
    payload = [0x03, 0x0A, 0x04, 0x00, 0x00, 0x01, 0x08];
    await _transport.writeHexCommand(Uint8List.fromList(payload));
  }

  Future<void> _sendOledOff() async {
    List<int> payload = [];
    payload = [0x03, 0x0A, 0x00, 0x01, 0x00, 0x01, 0x09];
    await _transport.writeHexCommand(Uint8List.fromList(payload));
  }

  final BehaviorSubject<ScaleSnapshot> _snapshotHandler = BehaviorSubject();

  @override
  DeviceType get type => DeviceType.scale;

  void onData(Uint8List data) {
    _rawChunks++;
    _rawBytes += data.length;
    _inputBuffer.addAll(data);
    _decodeWeightFrames();
  }

  void _decodeWeightFrames() {
    while (_inputBuffer.length >= 2) {
      final start = _weightFrameStart();
      if (start < 0) {
        final trailingStart = _inputBuffer.last == 0x03;
        _inputBuffer.removeRange(
          0,
          _inputBuffer.length - (trailingStart ? 1 : 0),
        );
        return;
      }
      if (start > 0) {
        _inputBuffer.removeRange(0, start);
      }
      if (_inputBuffer.length < _weightFrameLength) {
        return;
      }

      final frame = _inputBuffer.sublist(0, _weightFrameLength);
      final checksum = frame.take(6).fold(0, (value, byte) => value ^ byte);
      if (checksum != frame[6]) {
        _checksumFailures++;
        _invalidFrames++;
        _inputBuffer.removeAt(0);
        continue;
      }

      _inputBuffer.removeRange(0, _weightFrameLength);
      _handleWeightFrame(frame);
    }
  }

  int _weightFrameStart() {
    for (var i = 0; i < _inputBuffer.length - 1; i++) {
      if (_inputBuffer[i] == 0x03 && _inputBuffer[i + 1] == 0xCE) {
        return i;
      }
    }
    return -1;
  }

  void _handleWeightFrame(List<int> data) {
    _ticksSinceLastData = 0;
    _retryAttempted = false;
    _validWeightFrames++;
    _initialWeightReceived = true;
    _completeInitializationIfReady();
    final unsignedWeight = (data[2] << 8) | data[3];
    final signedWeight = unsignedWeight >= 0x8000
        ? unsignedWeight - 0x10000
        : unsignedWeight;
    _snapshotHandler.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: signedWeight / 10,
        batteryLevel: 100,
      ),
    );
  }

  @override
  Future<void> startTimer() async {
    Uint8List cmd = Uint8List(5);
    cmd[0] = 0x03;
    cmd[1] = 0x0B;
    cmd[2] = 0x03;
    await _transport.writeHexCommand(cmd);
  }

  @override
  Future<void> stopTimer() async {
    Uint8List cmd = Uint8List(5);
    cmd[0] = 0x03;
    cmd[1] = 0x0B;
    await _transport.writeHexCommand(cmd);
  }

  @override
  Future<void> resetTimer() async {
    Uint8List cmd = Uint8List(5);
    cmd[0] = 0x03;
    cmd[1] = 0x0B;
    cmd[2] = 0x02;
    await _transport.writeHexCommand(cmd);
  }
}
