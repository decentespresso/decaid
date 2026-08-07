import 'dart:async';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/hds_wifi_protocol.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/wifi_scale_id.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/web_socket_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:rxdart/subjects.dart';

typedef WebSocketTransportFactory = WebSocketTransport Function();

class HDSWifi implements Scale, TransportHandoffScale {
  final String host;
  final WebSocketTransportFactory _transportFactory;
  final Duration _recognitionTimeout;
  final Duration _watchdogInterval;
  late final Logger _log;

  static const int _stallTicks = 2;

  HDSWifi({
    required this.host,
    required WebSocketTransportFactory transportFactory,
    Duration recognitionTimeout = const Duration(seconds: 4),
    Duration watchdogInterval = const Duration(seconds: 4),
  }) : _transportFactory = transportFactory,
       _recognitionTimeout = recognitionTimeout,
       _watchdogInterval = watchdogInterval {
    _log = Logger('HDSWifi#${host.replaceAll(RegExp(r'\.+$'), '')}');
  }

  @override
  String get deviceId => WifiScaleId.forHost(host);

  @override
  DeviceImplementation get implementation => DeviceImplementation.hdsWifi;

  @override
  TransportType get transportType => TransportType.wifi;

  @override
  String get name => 'Half Decent Scale (WiFi)';

  @override
  DeviceType get type => DeviceType.scale;

  final BehaviorSubject<ConnectionState> _connectionSubject =
      BehaviorSubject.seeded(ConnectionState.discovered);
  @override
  Stream<ConnectionState> get connectionState => _connectionSubject.stream;

  ConnectionState get currentState => _connectionSubject.value;

  final BehaviorSubject<ScaleSnapshot> _snapshot = BehaviorSubject();
  @override
  Stream<ScaleSnapshot> get currentSnapshot => _snapshot.stream;

  WebSocketTransport? _transport;
  StreamSubscription<String>? _msgSub;
  StreamSubscription<ConnectionState>? _transportStateSub;
  Timer? _recognitionTimer;
  Timer? _watchdogTimer;

  int _generation = 0;
  int _ticksSinceFrame = 0;
  bool _recognized = false;
  int _batteryLevel = 100;
  Completer<void>? _connectCompleter;

  @override
  Future<void> onConnect() {
    final prev = _connectCompleter;
    if (prev != null && !prev.isCompleted) {
      prev.completeError(StateError('superseded by a new connect attempt'));
    }
    _log.info('onConnect (deviceId=$deviceId)');
    final completer = Completer<void>();
    _connectCompleter = completer;
    _attempt();
    return completer.future;
  }

  Future<void> _attempt() async {
    final gen = ++_generation;
    _recognized = false;
    _ticksSinceFrame = 0;
    _teardownTransport();
    _emit(ConnectionState.connecting);

    final transport = _transportFactory();
    _transport = transport;
    _msgSub = transport.messages.listen((raw) => _onFrame(gen, raw));
    _transportStateSub = transport.connectionState.listen((s) {
      if (gen != _generation) return;
      if (s != ConnectionState.disconnected) return;
      if (_recognized) {
        _reportLost(gen, 'socket closed');
      } else {
        _failAttempt(gen, StateError('socket closed before recognition'));
      }
    });

    try {
      await transport.connect();
    } catch (e) {
      _failAttempt(gen, e);
      return;
    }
    if (gen != _generation) return;

    for (final cmd in HdsWifiCommands.handshake) {
      try {
        await transport.sendMessage(cmd);
      } catch (e) {
        _log.fine('handshake "$cmd" failed', e);
      }
    }
    if (gen != _generation) return;

    _recognitionTimer = Timer(_recognitionTimeout, () {
      if (gen != _generation || _recognized) return;
      _failAttempt(gen, StateError('HDS recognition timeout'));
    });
  }

  void _onFrame(int gen, String raw) {
    if (gen != _generation) return;
    try {
      final frame = HdsWifiFrame.parse(raw);
      if (frame == null) return;
      _ticksSinceFrame = 0;

      if (!_recognized && frame.confirmsHds) {
        _markRecognized(gen);
      }
      if (frame.batteryPercent != null) {
        _batteryLevel = frame.batteryPercent!;
      }
      if (frame.hasWeight) {
        _snapshot.add(
          ScaleSnapshot(
            timestamp: DateTime.now(),
            weight: frame.grams!,
            batteryLevel: _batteryLevel,
          ),
        );
      }
      if (frame.isPowerOff) {
        _log.info('scale reported power_off');
        _reportLost(gen, 'power_off');
      }
    } catch (e, st) {
      _log.warning('error handling frame (ignored)', e, st);
    }
  }

  void _markRecognized(int gen) {
    if (gen != _generation) return;
    _recognized = true;
    _recognitionTimer?.cancel();
    _emit(ConnectionState.connected);
    _startWatchdog(gen);
    final c = _connectCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _log.info('recognized as HDS — connected');
  }

  void _startWatchdog(int gen) {
    _watchdogTimer?.cancel();
    _ticksSinceFrame = 0;
    _watchdogTimer = Timer.periodic(_watchdogInterval, (_) {
      if (gen != _generation) return;
      _ticksSinceFrame++;
      if (_ticksSinceFrame >= _stallTicks) {
        _reportLost(
          gen,
          'watchdog: no frames for '
          '${_watchdogInterval.inMilliseconds * _ticksSinceFrame}ms',
        );
      }
    });
  }

  void _reportLost(int gen, String reason) {
    if (gen != _generation) return;
    _generation++;
    _log.warning('connection lost ($reason) — reporting disconnected');
    _teardownTransport();
    _emit(ConnectionState.disconnected);
  }

  void _failAttempt(int gen, Object error) {
    if (gen != _generation) return;
    _generation++;
    _log.warning('connect attempt failed', error);
    _teardownTransport();
    _emit(ConnectionState.disconnected);
    final c = _connectCompleter;
    if (c != null && !c.isCompleted) c.completeError(error);
  }

  @override
  Future<void> disconnect() async {
    _log.info('disconnect (user/manager-initiated)');
    _generation++;
    _teardownTransport();
    _emit(ConnectionState.disconnected);
    final c = _connectCompleter;
    if (c != null && !c.isCompleted) {
      c.completeError(StateError('disconnected'));
    }
  }

  @override
  Future<void> disconnectForHandoff() => disconnect();

  Future<void> dispose() async {
    _generation++;
    _teardownTransport();
    _emit(ConnectionState.disconnected);
    if (!_connectionSubject.isClosed) await _connectionSubject.close();
    if (!_snapshot.isClosed) await _snapshot.close();
    final c = _connectCompleter;
    if (c != null && !c.isCompleted) {
      c.completeError(StateError('disposed'));
    }
  }

  void _teardownTransport() {
    _recognitionTimer?.cancel();
    _watchdogTimer?.cancel();
    _recognitionTimer = null;
    _watchdogTimer = null;
    _msgSub?.cancel();
    _transportStateSub?.cancel();
    _msgSub = null;
    _transportStateSub = null;
    final t = _transport;
    _transport = null;
    if (t != null) {
      unawaited(t.disconnect().catchError((_) {}));
    }
  }

  void _emit(ConnectionState state) {
    if (_connectionSubject.isClosed) return;
    if (_connectionSubject.value == state) return;
    _connectionSubject.add(state);
  }

  @override
  Future<void> tare() => _send(HdsWifiCommands.tare);

  @override
  Future<void> startTimer() => _send(HdsWifiCommands.timerStart);

  @override
  Future<void> stopTimer() => _send(HdsWifiCommands.timerStop);

  @override
  Future<void> resetTimer() => _send(HdsWifiCommands.timerReset);

  @override
  Future<void> sleepDisplay() => _send(HdsWifiCommands.displayOff);

  @override
  Future<void> wakeDisplay() => _send(HdsWifiCommands.displayOn);

  Future<void> _send(String cmd) async {
    final t = _transport;
    if (t == null) {
      _log.warning('cannot send "$cmd": not connected');
      return;
    }
    try {
      await t.sendMessage(cmd);
    } catch (e) {
      _log.warning('send "$cmd" failed', e);
    }
  }
}
