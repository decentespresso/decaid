import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/disconnect_expectations.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart'
    show ConnectionPhase;
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/device.dart' as device;

class DisconnectSupervisor {
  static final _log = Logger('DisconnectSupervisor');

  final Stream<De1Interface?> _machineStream;
  final Stream<device.ConnectionState> _scaleStream;
  final StatusPublisher _statusPublisher;
  final DisconnectExpectations _expectations;
  final bool Function() _isConnectingMachine;
  final bool Function() _isConnectingScale;
  final String? Function() _scaleLastConnectedId;
  final String? Function() _preferredScaleId;
  final void Function()? _onMachineConnected;
  final void Function()? _onMachineDisconnected;
  final void Function()? _onUnexpectedMachineDisconnect;
  final void Function()? _onScaleConnected;
  final void Function()? _onScaleDisconnected;

  De1Interface? _latestDe1;
  device.ConnectionState _latestScaleState = device.ConnectionState.discovered;
  String? _lastKnownMachineId;

  Completer<void>? _machineSeenCompleter;
  String? _awaitedMachineId;

  Future<void> waitForMachine(String deviceId) {
    if (_latestDe1?.deviceId == deviceId) return Future<void>.value();
    final completer = Completer<void>();
    _awaitedMachineId = deviceId;
    _machineSeenCompleter = completer;
    return completer.future;
  }

  StreamSubscription<De1Interface?>? _machineSub;
  StreamSubscription<device.ConnectionState>? _scaleSub;

  DisconnectSupervisor({
    required Stream<De1Interface?> machineStream,
    required Stream<device.ConnectionState> scaleStream,
    required StatusPublisher statusPublisher,
    required DisconnectExpectations expectations,
    required bool Function() isConnectingMachine,
    required bool Function() isConnectingScale,
    required String? Function() scaleLastConnectedId,
    required String? Function() preferredScaleId,
    void Function()? onMachineConnected,
    void Function()? onMachineDisconnected,
    void Function()? onUnexpectedMachineDisconnect,
    void Function()? onScaleConnected,
    void Function()? onScaleDisconnected,
  }) : _machineStream = machineStream,
       _scaleStream = scaleStream,
       _statusPublisher = statusPublisher,
       _expectations = expectations,
       _isConnectingMachine = isConnectingMachine,
       _isConnectingScale = isConnectingScale,
       _scaleLastConnectedId = scaleLastConnectedId,
       _preferredScaleId = preferredScaleId,
       _onMachineConnected = onMachineConnected,
       _onMachineDisconnected = onMachineDisconnected,
       _onUnexpectedMachineDisconnect = onUnexpectedMachineDisconnect,
       _onScaleConnected = onScaleConnected,
       _onScaleDisconnected = onScaleDisconnected {
    _start();
  }

  bool get isMachineConnected => _latestDe1 != null;

  De1Interface? get latestMachine => _latestDe1;

  bool get isScaleConnected =>
      _latestScaleState == device.ConnectionState.connected;

  void markMachineOffline() {
    _latestDe1 = null;
  }

  void _start() {
    _machineSub = _machineStream.listen((de1) {
      final hadMachine = _latestDe1 != null;
      _latestDe1 = de1;
      if (de1 != null) {
        _lastKnownMachineId = de1.deviceId;
        if (de1.deviceId == _awaitedMachineId) {
          _awaitedMachineId = null;
          _machineSeenCompleter?.complete();
          _machineSeenCompleter = null;
        }
        _onMachineConnected?.call();
        return;
      }
      if (hadMachine && !_isConnectingMachine()) {
        _log.fine('Machine disconnected');
        _onMachineDisconnected?.call();
        _statusPublisher.publish(
          _statusPublisher.current.copyWith(phase: ConnectionPhase.idle),
        );
        final id = _lastKnownMachineId;
        if (id != null) {
          final unexpected = _handleMachineDisconnect(id);
          if (unexpected) {
            _onUnexpectedMachineDisconnect?.call();
          }
        }
      }
    });

    _scaleSub = _scaleStream.listen((state) {
      final wasConnected =
          _latestScaleState == device.ConnectionState.connected;
      _latestScaleState = state;
      _log.fine('scale connection update: ${state.name}');
      if (!wasConnected && state == device.ConnectionState.connected) {
        _onScaleConnected?.call();
      }
      if (wasConnected &&
          state == device.ConnectionState.disconnected &&
          !_isConnectingScale()) {
        final id = _scaleLastConnectedId() ?? _preferredScaleId();
        if (id != null) {
          final unexpected = _handleScaleDisconnect(id);
          if (unexpected) {
            _onScaleDisconnected?.call();
          }
        } else {
          _onScaleDisconnected?.call();
        }
      }
    });
  }

  bool _handleMachineDisconnect(String deviceId) {
    if (_expectations.consume(deviceId)) {
      _log.fine('Machine $deviceId: expected disconnect, suppressing error');
      return false;
    }
    _statusPublisher.emitError(
      ConnectionError(
        kind: ConnectionErrorKind.machineDisconnected,
        severity: ConnectionErrorSeverity.error,
        timestamp: DateTime.now().toUtc(),
        deviceId: deviceId,
        message: 'Machine disconnected unexpectedly.',
        suggestion:
            'Check the machine is powered on and in range, then reconnect.',
      ),
    );
    return true;
  }

  bool _handleScaleDisconnect(String deviceId) {
    if (_expectations.consume(deviceId)) {
      _log.fine('Scale $deviceId: expected disconnect, suppressing error');
      return false;
    }
    _statusPublisher.emitError(
      ConnectionError(
        kind: ConnectionErrorKind.scaleDisconnected,
        severity: ConnectionErrorSeverity.warning,
        timestamp: DateTime.now().toUtc(),
        deviceId: deviceId,
        message: 'Scale disconnected unexpectedly.',
        suggestion:
            'The scale may have powered off or moved out of range. '
            'Wake the scale and reconnect.',
      ),
    );
    return true;
  }

  void notifyMachineDisconnected(String deviceId) =>
      _handleMachineDisconnect(deviceId);

  void notifyScaleDisconnected(String deviceId) =>
      _handleScaleDisconnect(deviceId);

  void dispose() {
    _machineSub?.cancel();
    _scaleSub?.cancel();
    _machineSub = null;
    _scaleSub = null;
    _awaitedMachineId = null;
    _machineSeenCompleter?.complete();
    _machineSeenCompleter = null;
  }
}
