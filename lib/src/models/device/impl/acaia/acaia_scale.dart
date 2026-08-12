import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

enum AcaiaProtocol { ips, pyxis }

enum _AcaiaFrameResult { accepted, ignored, malformed }

/// Hardware settle delays used during Acaia initialization.
///
/// Production keeps the real hardware-safe defaults; unit tests that only
/// need an initialized scale can inject zero durations.
class AcaiaTimings {
  const AcaiaTimings({
    this.initialIpsSettle = const Duration(milliseconds: 100),
    this.initialPyxisSettle = const Duration(milliseconds: 500),
    this.identSettle = const Duration(milliseconds: 200),
    this.configSettle = const Duration(milliseconds: 500),
  });

  final Duration initialIpsSettle;
  final Duration initialPyxisSettle;
  final Duration identSettle;
  final Duration configSettle;
}

class AcaiaScale implements Scale {
  static final _ipsService = BleServiceIdentifier.short('1820');
  static final _ipsCharacteristic = BleServiceIdentifier.short('2a80');
  static final _pyxisService = BleServiceIdentifier.long(
    '49535343-fe7d-4ae5-8fa9-9fafd205e455',
  );
  static final _pyxisStatusChar = BleServiceIdentifier.long(
    '49535343-1e4d-4bd9-ba61-23c647249616',
  );
  static final _pyxisCmdChar = BleServiceIdentifier.long(
    '49535343-8841-43f4-a8d4-ecbe34729bb3',
  );

  static const advertisedServiceUuids = [
    '49535343-fe7d-4ae5-8fa9-9fafd205e455',
    '49535343-1e4d-4bd9-ba61-23c647249616',
    '49535343-8841-43f4-a8d4-ecbe34729bb3',
  ];

  static const _maxInitRetries = 10;
  static const _header1 = 0xEF;
  static const _header2 = 0xDD;
  static const _metadataLength = 5;
  static const _checksumLength = 2;
  static const _weightBodyLength = 6;
  static const _maxPayloadLength = 64;
  static const _recordBodyLengths = <int, int>{5: 6, 6: 1, 7: 3, 8: 1, 11: 2};
  static const _identPayload = [
    0x30,
    0x31,
    0x32,
    0x33,
    0x34,
    0x35,
    0x36,
    0x37,
    0x38,
    0x39,
    0x30,
    0x31,
    0x32,
    0x33,
    0x34,
  ];
  static const _configPayload = [
    0x09,
    0x00,
    0x01,
    0x01,
    0x02,
    0x02,
    0x05,
    0x03,
    0x04,
  ];
  static const _heartbeatPayload = [0x02, 0x00];

  final Logger _log = Logger('AcaiaScale');
  final BLETransport _transport;
  final String _deviceId;
  final StreamController<ScaleSnapshot> _streamController =
      StreamController.broadcast();
  final BehaviorSubject<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  AcaiaProtocol? _protocol;
  StreamSubscription<ConnectionState>? _disconnectSubscription;
  Timer? _maintenanceTimer;
  Timer? _watchdogTimer;
  List<int> _buffer = [];
  bool _partialFramePending = false;
  DateTime _lastValidFrame = clock.now();
  int _batteryLevel = 0;
  int _generation = 0;
  bool _hasValidWeight = false;
  bool _badBatteryLogged = false;

  AcaiaScale({
    required BLETransport transport,
    AcaiaTimings timings = const AcaiaTimings(),
    DateTime Function() now = _defaultNow,
  }) : _transport = transport,
       _deviceId = transport.id,
       _timings = timings,
       _now = now;

  final AcaiaTimings _timings;
  final DateTime Function() _now;

  static DateTime _defaultNow() => clock.now();

  @override
  Stream<ScaleSnapshot> get currentSnapshot => _streamController.stream;

  @override
  String get deviceId => _deviceId;

  @override
  DeviceImplementation get implementation => DeviceImplementation.acaiaScale;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name =>
      _transport.name.isNotEmpty ? _transport.name : 'Acaia Scale';

  @override
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  DeviceType get type => DeviceType.scale;

  String get _serviceUuid =>
      _protocol == AcaiaProtocol.pyxis ? _pyxisService.long : _ipsService.long;

  String get _notifyCharacteristic => _protocol == AcaiaProtocol.pyxis
      ? _pyxisStatusChar.long
      : _ipsCharacteristic.long;

  String get _writeCharacteristic => _protocol == AcaiaProtocol.pyxis
      ? _pyxisCmdChar.long
      : _ipsCharacteristic.long;

  bool get _withResponse => _protocol == AcaiaProtocol.pyxis;

  @override
  Future<void> onConnect() async {
    if (_connectionStateController.value == ConnectionState.connected &&
        await _transport.getConnectionState() == ConnectionState.connected) {
      return;
    }
    _invalidateConnection();
    final generation = _generation;
    _connectionStateController.add(ConnectionState.connecting);

    try {
      await _disconnectSubscription?.cancel();
      _disconnectSubscription = null;
      if (generation != _generation) {
        throw const DeviceNotConnectedException.scale();
      }
      await _transport.connect();
      await _ensureCurrentConnection(generation);
      _disconnectSubscription = _transport.connectionState
          .where((state) => state == ConnectionState.disconnected)
          .listen((_) {
            if (generation != _generation) return;
            _invalidateConnection();
            _connectionStateController.add(ConnectionState.disconnected);
          });

      final services = await _transport.discoverServices();
      await _ensureCurrentConnection(generation);
      if (_pyxisService.matchesAny(services)) {
        _protocol = AcaiaProtocol.pyxis;
      } else if (_ipsService.matchesAny(services)) {
        _protocol = AcaiaProtocol.ips;
      } else {
        throw StateError('No supported Acaia service found');
      }

      await _initialize(generation);
      await _ensureCurrentConnection(generation);
      _connectionStateController.add(ConnectionState.connected);
      _startMaintenance(generation);
    } catch (error, stackTrace) {
      if (generation != _generation) return;
      _log.warning('Failed to initialize scale', error, stackTrace);
      _invalidateConnection();
      _connectionStateController.add(ConnectionState.disconnected);
      final cancellation = _disconnectSubscription?.cancel();
      _disconnectSubscription = null;
      try {
        await _transport.disconnect();
      } catch (_) {}
      await cancellation;
    }
  }

  Future<void> _initialize(int generation) async {
    _hasValidWeight = false;
    _badBatteryLogged = false;
    _buffer = [];
    _partialFramePending = false;
    await _transport.subscribe(
      _serviceUuid,
      _notifyCharacteristic,
      _parseNotification,
    );
    await _ensureCurrentConnection(generation);
    await Future<void>.delayed(
      _protocol == AcaiaProtocol.pyxis
          ? _timings.initialPyxisSettle
          : _timings.initialIpsSettle,
    );
    await _ensureCurrentConnection(generation);

    for (
      var attempt = 0;
      attempt < _maxInitRetries && !_hasValidWeight;
      attempt++
    ) {
      if (!await _write(_encode(0x0B, _identPayload))) {
        throw StateError('Acaia ident write failed');
      }
      await _ensureCurrentConnection(generation);
      await Future<void>.delayed(_timings.identSettle);
      await _ensureCurrentConnection(generation);
      if (!await _write(_encode(0x0C, _configPayload))) {
        throw StateError('Acaia config write failed');
      }
      await _ensureCurrentConnection(generation);
      await Future<void>.delayed(_timings.configSettle);
      await _ensureCurrentConnection(generation);
    }

    if (!_hasValidWeight) {
      throw StateError('Acaia scale produced no valid weight');
    }
  }

  Future<void> _ensureCurrentConnection(int generation) async {
    if (generation != _generation ||
        await _transport.getConnectionState() != ConnectionState.connected ||
        generation != _generation) {
      throw const DeviceNotConnectedException.scale();
    }
  }

  static Uint8List _encode(int messageType, List<int> payload) {
    var evenChecksum = 0;
    var oddChecksum = 0;
    for (var i = 0; i < payload.length; i++) {
      if (i.isEven) {
        evenChecksum = (evenChecksum + payload[i]) & 0xFF;
      } else {
        oddChecksum = (oddChecksum + payload[i]) & 0xFF;
      }
    }
    return Uint8List.fromList([
      _header1,
      _header2,
      messageType,
      ...payload,
      evenChecksum,
      oddChecksum,
    ]);
  }

  Future<bool> _write(Uint8List data) async {
    try {
      await _transport.write(
        _serviceUuid,
        _writeCharacteristic,
        data,
        withResponse: _withResponse,
      );
      return true;
    } on DeviceNotConnectedException {
      _log.fine('Acaia write skipped because the device disconnected');
      return false;
    }
  }

  void _startMaintenance(int generation) {
    _lastValidFrame = _now();
    _scheduleMaintenance(generation);
    if (_protocol == AcaiaProtocol.pyxis) _scheduleWatchdog(generation);
  }

  void _scheduleMaintenance(int generation) {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_runMaintenance(generation));
    });
  }

  Future<void> _runMaintenance(int generation) async {
    if (!_isCurrent(generation)) return;
    try {
      await _write(_encode(0x00, _heartbeatPayload));
    } on TimeoutException catch (error) {
      _log.warning('Acaia heartbeat timed out: $error');
    } catch (error, stackTrace) {
      _log.warning('Acaia heartbeat failed', error, stackTrace);
    } finally {
      if (_isCurrent(generation)) _scheduleMaintenance(generation);
    }
  }

  void _scheduleWatchdog(int generation) {
    _watchdogTimer?.cancel();
    final elapsed = _now().difference(_lastValidFrame);
    final remaining = const Duration(seconds: 5) - elapsed;
    _watchdogTimer = Timer(
      remaining.isNegative ? Duration.zero : remaining,
      () {
        unawaited(_runWatchdog(generation));
      },
    );
  }

  Future<void> _runWatchdog(int generation) async {
    if (!_isCurrent(generation)) return;
    if (_now().difference(_lastValidFrame) < const Duration(seconds: 5)) {
      _scheduleWatchdog(generation);
      return;
    }
    try {
      await disconnect();
    } catch (error, stackTrace) {
      _log.warning('Acaia watchdog disconnect failed', error, stackTrace);
    }
  }

  bool _isCurrent(int generation) =>
      generation == _generation &&
      _connectionStateController.value == ConnectionState.connected;

  void _invalidateConnection() {
    _generation++;
    _maintenanceTimer?.cancel();
    _maintenanceTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  @override
  Future<void> disconnect() async {
    _invalidateConnection();
    unawaited(_disconnectSubscription?.cancel());
    _disconnectSubscription = null;
    _connectionStateController.add(ConnectionState.disconnected);
    await _transport.disconnect();
  }

  @override
  Future<void> tare() async {
    final command = _encode(0x04, List<int>.filled(15, 0));
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await _write(command)) throw StateError('Acaia tare write failed');
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  @override
  Future<void> sleepDisplay() => disconnect();

  @override
  Future<void> wakeDisplay() async {}

  @override
  Future<void> startTimer() async {}

  @override
  Future<void> stopTimer() async {}

  @override
  Future<void> resetTimer() async {}

  void _parseNotification(List<int> data) {
    final continuationBoundary = _partialFramePending ? _buffer.length : null;
    _buffer = [..._buffer, ...data];
    while (true) {
      final headerIndex = _findHeader(_buffer);

      if (headerIndex < 0) {
        _buffer = _buffer.isNotEmpty && _buffer.last == _header1
            ? [_header1]
            : [];
        return;
      }
      if (headerIndex > 0) _buffer = _buffer.sublist(headerIndex);
      if (_buffer.length < _metadataLength) return;

      final messageType = _buffer[2];
      final declaredLength = _buffer[3];
      final eventType = _buffer[4];
      final lengthReason = _knownLengthError(
        messageType,
        declaredLength,
        eventType,
      );
      if (declaredLength > _maxPayloadLength || lengthReason != null) {
        _logRejectedFrame(
          command: messageType,
          declaredLength: declaredLength,
          eventType: eventType,
          reason: lengthReason ?? 'declared length exceeds maximum',
        );
        _buffer = _buffer.sublist(2);
        continue;
      }

      final frameLength = _metadataLength + declaredLength;
      if (_buffer.length < frameLength) {
        if (_resyncPartialWeightFrame(messageType, eventType)) {
          _partialFramePending = false;
          continue;
        }
        _partialFramePending = true;
        return;
      }
      final frame = List<int>.unmodifiable(_buffer.sublist(0, frameLength));
      final partialWeightHeader = _partialFramePending
          ? _partialWeightHeader(
              _buffer,
              messageType,
              eventType,
              continuationBoundary,
            )
          : null;
      _buffer = _buffer.sublist(frameLength);
      if (partialWeightHeader != null) {
        _partialFramePending = false;
        _buffer = [...frame.sublist(partialWeightHeader), ..._buffer];
        continue;
      }
      _partialFramePending = false;
      final result = _processFrame(frame);
      if (result == _AcaiaFrameResult.malformed) {
        _resyncMalformedFrame(frame);
      } else if (result == _AcaiaFrameResult.accepted) {
        _lastValidFrame = _now();
        if (_protocol == AcaiaProtocol.pyxis &&
            _connectionStateController.value == ConnectionState.connected) {
          _scheduleWatchdog(_generation);
        }
      }
    }
  }

  int _findHeader(List<int> data, {int start = 0}) {
    for (var i = start; i + 1 < data.length; i++) {
      if (data[i] == _header1 && data[i + 1] == _header2) return i;
    }
    return -1;
  }

  String? _knownLengthError(
    int messageType,
    int declaredLength,
    int eventType,
  ) {
    if (messageType == 0x08) {
      return declaredLength >= 3 ? null : 'settings frame is too short';
    }
    if (messageType != 0x0C) return null;
    final minimumLength = switch (eventType) {
      5 => 2 + _weightBodyLength,
      11 => 5,
      _ => 2,
    };
    return declaredLength >= minimumLength
        ? null
        : 'declared length is below the minimum for event type $eventType';
  }

  bool _resyncPartialWeightFrame(int messageType, int eventType) {
    if (messageType != 0x0C) return false;
    final weightOffset = _weightBodyOffset(_buffer, eventType);
    if (weightOffset < 0 || !_hasValidWeightBody(_buffer, weightOffset)) {
      final bodyEnd = weightOffset + _weightBodyLength;
      if (weightOffset >= 0 && _buffer.length >= bodyEnd) {
        final nextHeader = _findHeader(_buffer, start: 2);
        if (nextHeader >= 0 && nextHeader < bodyEnd) {
          _logRejectedFrame(
            command: messageType,
            declaredLength: _buffer[3],
            eventType: eventType,
            innerTag: eventType == 11 ? _buffer[7] : null,
            reason: 'invalid weight body before the next frame',
          );
          _buffer = _buffer.sublist(nextHeader);
          return true;
        }
      }
    }
    return false;
  }

  int _weightBodyOffset(List<int> frame, int eventType) {
    return switch (eventType) {
      5 => _metadataLength,
      11
          when frame.length > _metadataLength + 2 &&
              frame[_metadataLength + 2] == 5 =>
        _metadataLength + 3,
      _ => -1,
    };
  }

  int? _partialWeightHeader(
    List<int> frame,
    int messageType,
    int eventType,
    int? continuationBoundary,
  ) {
    if (messageType != 0x0C || continuationBoundary == null) return null;
    final weightOffset = _weightBodyOffset(frame, eventType);
    if (weightOffset < 0) return null;
    final bodyEnd = weightOffset + _weightBodyLength;
    if (continuationBoundary == bodyEnd - 1) {
      return frame[continuationBoundary] == _header1 &&
              continuationBoundary + 1 < frame.length &&
              frame[continuationBoundary + 1] == _header2
          ? continuationBoundary
          : null;
    }
    if (continuationBoundary < bodyEnd) return null;
    for (final headerIndex in [
      continuationBoundary,
      continuationBoundary - 1,
    ]) {
      if (headerIndex >= 2 &&
          headerIndex + 1 < frame.length &&
          frame[headerIndex] == _header1 &&
          frame[headerIndex + 1] == _header2) {
        return headerIndex;
      }
    }
    return null;
  }

  void _resyncMalformedFrame(List<int> frame) {
    final nextHeader = _findHeader(frame, start: 2);
    if (nextHeader >= 0) {
      _buffer = [...frame.sublist(nextHeader), ..._buffer];
    }
  }

  void _logRejectedFrame({
    required int command,
    required int declaredLength,
    int? eventType,
    int? innerTag,
    required String reason,
  }) {
    final event = eventType == null ? '' : ' eventType=$eventType';
    final inner = innerTag == null ? '' : ' innerTag=$innerTag';
    _log.fine(
      'Rejected Acaia frame command=$command declaredLength=$declaredLength'
      '$event$inner: $reason',
    );
  }

  _AcaiaFrameResult _rejectFrame(
    List<int> frame,
    String reason, {
    int? innerTag,
  }) {
    _logRejectedFrame(
      command: frame[2],
      declaredLength: frame[3],
      eventType: frame[4],
      innerTag: innerTag,
      reason: reason,
    );
    return _AcaiaFrameResult.malformed;
  }

  _AcaiaFrameResult _processFrame(List<int> frame) {
    final messageType = frame[2];
    final eventType = frame[4];

    if (messageType == 0x08) {
      final battery = frame[4] & 0x7F;
      if (battery <= 100) {
        _batteryLevel = battery;
      } else if (!_badBatteryLogged) {
        _badBatteryLogged = true;
        _log.warning('Ignoring out-of-range Acaia battery value $battery');
      }
      return _AcaiaFrameResult.accepted;
    }
    if (messageType != 0x0C) return _AcaiaFrameResult.ignored;

    final payload = frame.sublist(
      _metadataLength,
      frame.length - _checksumLength,
    );
    if (eventType == 5) {
      if (payload.length < _weightBodyLength) {
        return _rejectFrame(frame, 'incomplete direct weight body');
      }
      if (!_hasValidWeightBody(payload, 0)) {
        return _rejectFrame(frame, 'invalid direct weight body');
      }
      _decodeWeight(payload.sublist(0, _weightBodyLength));
      return _AcaiaFrameResult.accepted;
    }
    if (eventType != 11) return _AcaiaFrameResult.ignored;
    if (payload.length < 3) {
      return _rejectFrame(frame, 'incomplete heartbeat wrapper');
    }

    final innerTag = payload[2];
    final innerBodyLength = _recordBodyLengths[innerTag];
    if (innerBodyLength == null) {
      return _rejectFrame(
        frame,
        'unknown heartbeat inner tag',
        innerTag: innerTag,
      );
    }
    final innerBodyStart = 3;
    if (payload.length < innerBodyStart + innerBodyLength) {
      return _rejectFrame(
        frame,
        'incomplete heartbeat inner record',
        innerTag: innerTag,
      );
    }
    if (innerTag == 5) {
      if (!_hasValidWeightBody(payload, innerBodyStart)) {
        return _rejectFrame(
          frame,
          'invalid heartbeat weight body',
          innerTag: innerTag,
        );
      }
      _decodeWeight(
        payload.sublist(innerBodyStart, innerBodyStart + _weightBodyLength),
      );
      return _AcaiaFrameResult.accepted;
    }
    if (!_hasCompleteRecordChain(payload, innerBodyStart + innerBodyLength)) {
      return _rejectFrame(
        frame,
        'incomplete or unknown heartbeat trailing record',
        innerTag: innerTag,
      );
    }
    return _AcaiaFrameResult.accepted;
  }

  bool _hasValidWeightBody(List<int> payload, int offset) {
    if (offset + _weightBodyLength > payload.length) return false;
    final unit = payload[offset + 4];
    return unit >= 1 && unit <= 4;
  }

  bool _hasCompleteRecordChain(List<int> payload, int offset) {
    while (offset < payload.length) {
      final bodyLength = _recordBodyLengths[payload[offset]];
      if (bodyLength == null || offset + 1 + bodyLength > payload.length) {
        return false;
      }
      offset += 1 + bodyLength;
    }
    return true;
  }

  void _decodeWeight(List<int> body) {
    final magnitude = (body[2] << 16) | (body[1] << 8) | body[0];
    final exponent = body[4];
    var weight = magnitude / pow(10, exponent);
    if ((body[5] & 0x02) != 0) weight *= -1;
    _hasValidWeight = true;
    _streamController.add(
      ScaleSnapshot(
        timestamp: DateTime.now(),
        weight: weight,
        batteryLevel: _batteryLevel,
      ),
    );
  }
}
