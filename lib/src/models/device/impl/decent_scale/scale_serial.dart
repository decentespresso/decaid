import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

/// Implements [TransportHandoffScale]: a USB disconnect only releases the
/// serial port (no power-off command), so handing the active-scale role to
/// another transport of the same physical HDS is non-destructive. Declaring the
/// capability makes that a compile-checked property.
class HDSSerial implements Scale, TransportHandoffScale {
  late Logger _log;
  final SerialTransport _transport;

  static const _enableCommand = [0x03, 0x20, 0x01];
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
  int _ticksSinceLastData = 0;
  bool _retryAttempted = false;

  @override
  disconnect() async {
    if (_isDisconnecting) return;
    _isDisconnecting = true;
    final uptimeSec = _watchdogTotalTicks * _watchdogInterval.inSeconds;
    _log.info(
      "disconnecting (totalFrames=$_totalFrames, uptime=${uptimeSec}s)",
    );
    try {
      _watchdogTimer?.cancel();
      _watchdogTimer = null;
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
  int _totalFrames = 0;

  @override
  Future<void> onConnect() async {
    _log.info("on connect (id=$deviceId, transport=${_transport.name})");
    _totalFrames = 0;
    // Announce `connecting` BEFORE opening the port so the serial reconcile's
    // liveness pass won't release (dispose) this transport mid-connect.
    _connectionSubject.add(ConnectionState.connecting);
    await _transport.connect();
    _transportSubscription = _transport.rawStream.listen(
      onData,
      onError: (error) {
        _log.warning("transport error", error);
        disconnect();
      },
      onDone: () {
        disconnect();
      },
    );

    await _transport.writeHexCommand(Uint8List.fromList(_enableCommand));
    _startWatchdog();
    _connectionSubject.add(ConnectionState.connected);
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
          "heartbeat: ${uptimeMin}m uptime, $_totalFrames frames received",
        );
      }

      if (_ticksSinceLastData >= _disconnectTicks) {
        _log.severe(
          "No data for ${_disconnectTicks * _watchdogInterval.inSeconds}s "
          "(totalFrames=$_totalFrames, uptime=${_watchdogTotalTicks * _watchdogInterval.inSeconds}s), disconnecting",
        );
        disconnect();
      } else if (_ticksSinceLastData >= _warningTicks && !_retryAttempted) {
        _retryAttempted = true;
        _log.warning(
          "No data for ${_warningTicks * _watchdogInterval.inSeconds}s "
          "(totalFrames=$_totalFrames), resending enable command",
        );
        _transport.writeHexCommand(Uint8List.fromList(_enableCommand));
      }
    });
  }

  @override
  Future<void> tare() async {
    Uint8List cmd = Uint8List(5);
    cmd[0] = 0x03;
    cmd[1] = 0x0F;

    await _transport.writeHexCommand(cmd);
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
    // payload = [0x03, 0x0A, 0x01, 0x00, 0x00, 0x01, 0x08];
    // await _transport.writeHexCommand(Uint8List.fromList(payload));
    payload = [0x03, 0x0A, 0x04, 0x00, 0x00, 0x01, 0x08];
    await _transport.writeHexCommand(Uint8List.fromList(payload));
  }

  Future<void> _sendOledOff() async {
    List<int> payload = [];
    // payload = [0x03, 0x0A, 0x04, 0x01, 0x00, 0x01, 0x09];
    // await _transport.writeHexCommand(Uint8List.fromList(payload));
    payload = [0x03, 0x0A, 0x00, 0x01, 0x00, 0x01, 0x09];
    await _transport.writeHexCommand(Uint8List.fromList(payload));
  }

  final BehaviorSubject<ScaleSnapshot> _snapshotHandler = BehaviorSubject();

  @override
  DeviceType get type => DeviceType.scale;

  void onData(Uint8List data) {
    _ticksSinceLastData = 0;
    _retryAttempted = false;
    _totalFrames++;
    try {
      _log.finest("got message: $data");
    } catch (_) {}
    if (data.length < 5 || data[0] != 0x03 || data[1] != 0xCE) {
      _log.finest("data is not weight data (len=${data.length})");
      return;
    }
    var d = ByteData(2);
    d.setInt8(0, data[2]);
    d.setInt8(1, data[3]);
    var weight = d.getInt16(0) / 10;
    _snapshotHandler.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
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
