import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/bengle_shot_sample.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/calibration_codec.dart';
import 'package:reaprime/src/models/device/transport/ble_timeout_exception.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/transport/logical_endpoint.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/serial_response_correlator.dart';
import 'package:rxdart/rxdart.dart';

const _defaultShotSettingsFrame = <int>[
  0x00, // steamSetting
  0x96, // targetSteamTemp (150)
  0x1e, // targetSteamDuration (30)
  0x4b, // targetHotWaterTemp (75)
  0x32, // targetHotWaterVolume (50)
  0x1e, // targetHotWaterDuration (30)
  0x24, // targetShotVolume (36)
  0x5e, // groupTemp (94.0)
  0x00,
];

class UnifiedDe1Transport {
  final DataTransport _transport;
  final TransportType transportType;
  final Logger _log;

  StreamSubscription<String>? _transportSubscription;
  StreamSubscription<device.ConnectionState>? _connectionStateSubscription;
  final _serialResponses = SerialResponseCorrelator();
  bool _cacheCleared = false;

  bool _recovering = false;

  Stream<device.ConnectionState> get connectionState => _transport
      .connectionState
      .where((s) => !(_recovering && s == device.ConnectionState.disconnected));

  String get id => _transport.id;

  BehaviorSubject<ByteData> _stateSubject = BehaviorSubject();
  BehaviorSubject<ByteData> _shotSampleSubject = BehaviorSubject();
  BehaviorSubject<ByteData> _shotSettingsSubject = BehaviorSubject();
  BehaviorSubject<ByteData> _waterLevelsSubject = BehaviorSubject();
  final PublishSubject<ByteData> _mmrSubject = PublishSubject();
  BehaviorSubject<ByteData> _fwMapRequestSubject = BehaviorSubject();
  ReplaySubject<ByteData> _bengleShotSampleSubject = ReplaySubject(maxSize: 1);
  PublishSubject<ByteData> _calibrationSubject = PublishSubject();
  bool _bengleShotSampleEnabled = false;

  Stream<ByteData> get state => _stateSubject.asBroadcastStream();
  Stream<ByteData> get shotSample => _shotSampleSubject.asBroadcastStream();
  Stream<ByteData> get shotSettings => _shotSettingsSubject.asBroadcastStream();
  Stream<ByteData> get waterLevels => _waterLevelsSubject.asBroadcastStream();
  Stream<ByteData> get mmr => _mmrSubject.asBroadcastStream();
  Stream<ByteData> get fwMapRequest => _fwMapRequestSubject.asBroadcastStream();
  Stream<ByteData> get bengleShotSample => _bengleShotSampleSubject.stream;
  Stream<ByteData> get calibration => _calibrationSubject.asBroadcastStream();

  String _currentBuffer = "";

  // Serial machines never push K (shot settings) on their own: a DE1
  // transmits the frame only when settings change on the machine, and
  // hardware verification showed no retransmit on subscribe, re-arm or
  // write. The app therefore owns the frame on serial: it seeds the subject
  // at connect from this mirror (firmware defaults initially) and updates
  // it from live frames and from every local write.
  Uint8List _localShotSettings = Uint8List.fromList(_defaultShotSettingsFrame);

  UnifiedDe1Transport({required DataTransport transport})
    : _transport = transport,
      transportType = transport.transportType,
      _log = Logger("UnifiedDe1Transport-${transport.id}");
  Future<void> connect() async {
    final wasConnected =
        transportType == TransportType.ble &&
        await _transport.connectionState.first ==
            device.ConnectionState.connected;

    if (wasConnected) {
      final bleTransport = _transport as BLETransport;
      bool linkIsLive = false;
      try {
        final osState = await bleTransport.getConnectionState().timeout(
          const Duration(seconds: 2),
        );
        linkIsLive = osState == device.ConnectionState.connected;
      } catch (e) {
        _log.fine('Stale-link probe inconclusive: $e');
      }

      if (linkIsLive) {
        _log.info(
          'Transport reports connected and OS probe confirms live link; '
          'skipping stale-link teardown',
        );
      } else {
        _log.info(
          'Transport reports connected but OS probe says link is dead; '
          'tearing down stale link before reconnect',
        );
        await _transport.disconnect();
      }
    }

    await _transport.connect();
    _cacheCleared = false;

    switch (transportType) {
      case TransportType.ble:
        await _bleConnect();
        break;
      case TransportType.serial:
        await _serialConnect();
        break;
      default:
        throw StateError('Unknown transport type: $transportType');
    }
  }

  Future<void> _bleConnect() async {
    if (_transport is! BLETransport) {
      throw "wrong transport type";
    }
    final services = await _transport.discoverServices();
    final de1Service = BleServiceIdentifier.parse(de1ServiceUUID);
    if (!de1Service.matchesAny(services)) {
      throw Exception(
        'Expected DE1 service ${de1Service.long} not found. '
        'Discovered services: $services',
      );
    }

    _stateNotification(
      ByteData.sublistView(
        await _transport.read(de1ServiceUUID, Endpoint.stateInfo.uuid),
      ),
    );

    _shotSettingsNotification(
      ByteData.sublistView(
        await _transport.read(de1ServiceUUID, Endpoint.shotSettings.uuid),
      ),
    );

    await _transport.subscribe(de1ServiceUUID, Endpoint.stateInfo.uuid, (d) {
      _stateNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(de1ServiceUUID, Endpoint.shotSample.uuid, (d) {
      _shotSampleNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(de1ServiceUUID, Endpoint.waterLevels.uuid, (d) {
      _waterLevelsNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(de1ServiceUUID, Endpoint.shotSettings.uuid, (d) {
      _shotSettingsNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(de1ServiceUUID, Endpoint.readFromMMR.uuid, (d) {
      _mmrNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(de1ServiceUUID, Endpoint.fwMapRequest.uuid, (d) {
      _fwMapNotification(ByteData.sublistView(Uint8List.fromList(d)));
    });
    await _transport.subscribe(
      de1ServiceUUID,
      Endpoint.calibration.uuid,
      (d) =>
          _calibrationNotification(ByteData.sublistView(Uint8List.fromList(d))),
    );
  }

  Future<void> subscribeBengleShotSample() async {
    switch (transportType) {
      case TransportType.ble:
        if (_transport is! BLETransport) {
          throw StateError('Expected BLE transport');
        }
        await _transport.subscribe(
          de1ServiceUUID,
          Endpoint.bengleShotSample.uuid,
          (data) => _bengleShotSampleNotification(
            ByteData.sublistView(Uint8List.fromList(data)),
          ),
        );
      case TransportType.serial:
        if (_transport is! SerialTransport) {
          throw StateError('Expected serial transport');
        }
        await _transport.writeCommand(
          '<+${Endpoint.bengleShotSample.representation}>',
        );
        _bengleShotSampleEnabled = true;
        await _transport.writeCommand(
          '<-${Endpoint.shotSample.representation}>',
        );
        return;
      case TransportType.unknown:
      case TransportType.wifi:
        throw StateError('Unsupported transport type: $transportType');
    }
    _bengleShotSampleEnabled = true;
  }

  Future<void> _serialConnect() async {
    if (_transport is! SerialTransport) {
      throw "Wrong transport type";
    }
    await _transportSubscription?.cancel();
    await _connectionStateSubscription?.cancel();

    _transportSubscription = _transport.readStream.listen(_processSerialInput);
    _connectionStateSubscription = _transport.connectionState.listen((state) {
      if (state == device.ConnectionState.disconnected) {
        _serialResponses.failAll(StateError('Serial transport disconnected'));
        _resetCachedState();
      }
    });

    await _transport.writeCommand("<+${Endpoint.stateInfo.representation}>");
    await _transport.writeCommand("<+${Endpoint.shotSample.representation}>");
    await _transport.writeCommand("<+${Endpoint.waterLevels.representation}>");
    await _transport.writeCommand("<+${Endpoint.shotSettings.representation}>");
    await _transport.writeCommand("<+${Endpoint.readFromMMR.representation}>");
    await _transport.writeCommand("<+${Endpoint.fwMapRequest.representation}>");
    await _transport.writeCommand("<+${Endpoint.calibration.representation}>");

    await _transport.writeCommand("<B>02");

    // Seed the subject from the local mirror so reads succeed without any
    // machine cooperation; live frames and local writes refresh the mirror.
    _shotSettingsSubject.add(
      ByteData.sublistView(Uint8List.fromList(_localShotSettings)),
    );
  }

  Future<void> dispose() async {
    _serialResponses.failAll(StateError('Serial transport disposed'));
    await _transportSubscription?.cancel();
    _transportSubscription = null;
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    if (!_stateSubject.isClosed) _stateSubject.close();
    if (!_shotSampleSubject.isClosed) _shotSampleSubject.close();
    if (!_shotSettingsSubject.isClosed) _shotSettingsSubject.close();
    if (!_waterLevelsSubject.isClosed) _waterLevelsSubject.close();
    if (!_mmrSubject.isClosed) _mmrSubject.close();
    if (!_fwMapRequestSubject.isClosed) _fwMapRequestSubject.close();
    if (!_bengleShotSampleSubject.isClosed) {
      _bengleShotSampleSubject.close();
    }
    if (!_calibrationSubject.isClosed) _calibrationSubject.close();

    await _transport.dispose();
  }

  Future<void> disconnect() async {
    _serialResponses.failAll(StateError('Serial transport disconnected'));
    _log.warning('disconnect() called by app code', null, StackTrace.current);
    switch (transportType) {
      case TransportType.serial:
        if (_transport is! SerialTransport) {
          throw "Wrong transport type";
        }
        await _transportSubscription?.cancel();
        _transportSubscription = null;
        await _connectionStateSubscription?.cancel();
        _connectionStateSubscription = null;
        await _transport.writeCommand(
          "<-${Endpoint.stateInfo.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.shotSample.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.waterLevels.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.shotSettings.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.readFromMMR.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.fwMapRequest.representation}>",
        );
        await _transport.writeCommand(
          "<-${Endpoint.calibration.representation}>",
        );
        if (_bengleShotSampleEnabled) {
          await _transport.writeCommand(
            '<-${Endpoint.bengleShotSample.representation}>',
          );
        }
        break;
      case TransportType.ble:
        break;
      case TransportType.unknown:
        throw StateError('Unknown transport type: $transportType');
      case TransportType.wifi:
        throw StateError(
          'WiFi transport not supported for DE1: $transportType',
        );
    }

    await _transport.disconnect();
    _resetCachedState();
  }

  void _resetCachedState() {
    if (_cacheCleared) return;
    _cacheCleared = true;
    _stateSubject.close();
    _shotSampleSubject.close();
    _shotSettingsSubject.close();
    _waterLevelsSubject.close();
    _fwMapRequestSubject.close();
    _bengleShotSampleSubject.close();
    _calibrationSubject.close();
    _stateSubject = BehaviorSubject();
    _shotSampleSubject = BehaviorSubject();
    _shotSettingsSubject = BehaviorSubject();
    _waterLevelsSubject = BehaviorSubject();
    _fwMapRequestSubject = BehaviorSubject();
    _bengleShotSampleSubject = ReplaySubject(maxSize: 1);
    _calibrationSubject = PublishSubject();
    _bengleShotSampleEnabled = false;
  }

  static final _messagePattern = RegExp(r'(\[[A-Z]\][0-9A-Fa-f\s]*?)(?=\[|\n)');

  static String _sampleForLog(String s, int max) {
    final head = s.length <= max ? s : '${s.substring(0, max)}…';
    final escaped = head
        .replaceAll('\\', r'\\')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t')
        .replaceAllMapped(
          RegExp(r'[^\x20-\x7e]'),
          (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}',
        );
    return '"$escaped"';
  }

  void _processSerialInput(String input) {
    _currentBuffer += input;

    final firstBracket = _currentBuffer.indexOf('[');
    if (firstBracket < 0) {
      _currentBuffer = '';
      return;
    }
    if (firstBracket > 0) {
      _log.finest(
        "Discarding non-message data: '${_currentBuffer.substring(0, firstBracket)}'",
      );
      _currentBuffer = _currentBuffer.substring(firstBracket);
    }

    final matches = _messagePattern.allMatches(_currentBuffer).toList();

    if (matches.isEmpty) {
      if (_currentBuffer.length > 4096) {
        _log.warning(
          'Serial buffer overflow (${_currentBuffer.length} bytes), discarding. '
          'Head sample: ${_sampleForLog(_currentBuffer, 200)}',
        );
        _currentBuffer = '';
      }
      return;
    }

    final completeCount = matches.length;

    for (int i = 0; i < completeCount; i++) {
      final message = matches[i].group(1)!.trim();
      if (message.isNotEmpty) {
        _log.finest("received complete response: $message");
        _processDe1Response(message);
      }
    }

    if (completeCount > 0) {
      _currentBuffer = _currentBuffer.substring(matches[completeCount - 1].end);
      _currentBuffer = _currentBuffer.replaceAll(RegExp(r'^\n+'), '');
    }
  }

  void _processDe1Response(String input) {
    _log.finest("processing input: $input");
    try {
      final Uint8List payload = hexToBytes(input.substring(3));
      final ByteData data = ByteData.sublistView(payload);
      final representation = input[1];
      switch (representation) {
        case "M":
          _shotSampleNotification(data);
        case "N":
          _stateNotification(data);
        case "Q":
          _waterLevelsNotification(data);
        case "K":
          _shotSettingsNotification(data);
        case "E":
          _mmrNotification(data);
        case "I":
          _fwMapNotification(data);
        case "R":
          _calibrationNotification(data);
        case "S":
          _bengleShotSampleNotification(data);
        default:
          if (!_serialResponses.complete(representation, data)) {
            _log.warning("unhandled de1 message: $input");
          }
          break;
      }
    } on FormatException catch (e) {
      _log.warning("malformed serial message, skipping: '$input' ($e)");
    }
  }

  Uint8List hexToBytes(String hex) {
    hex = hex.replaceAll(RegExp(r'\s+'), '');
    if (hex.length.isOdd) {
      throw FormatException('Invalid input length, must be even', hex);
    }
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < hex.length; i += 2) {
      final byteStr = hex.substring(i, i + 2);
      result[i ~/ 2] = int.parse(byteStr, radix: 16);
    }
    return result;
  }

  static const _minShotSampleBytes = 19;
  static const _minStateBytes = 2;
  static const _minCalibrationBytes = De1CalibrationCodec.packetLength;

  void _shotSampleNotification(ByteData d) {
    if (d.lengthInBytes < _minShotSampleBytes) {
      _log.warning(
        'Dropping short shotSample frame '
        '(${d.lengthInBytes} < $_minShotSampleBytes bytes)',
      );
      return;
    }
    _shotSampleSubject.add(d);
  }

  void _bengleShotSampleNotification(ByteData data) {
    if (data.lengthInBytes < bengleShotSampleLength) {
      _log.warning(
        'Dropping short Bengle shot sample frame '
        '(${data.lengthInBytes} < $bengleShotSampleLength bytes)',
      );
      return;
    }
    _bengleShotSampleSubject.add(data);
  }

  void _stateNotification(ByteData d) {
    if (d.lengthInBytes < _minStateBytes) {
      _log.warning(
        'Dropping short state frame '
        '(${d.lengthInBytes} < $_minStateBytes bytes)',
      );
      return;
    }
    _stateSubject.add(d);
  }

  void _waterLevelsNotification(ByteData d) {
    _waterLevelsSubject.add(d);
  }

  void _shotSettingsNotification(ByteData d) {
    _localShotSettings = Uint8List.fromList(d.buffer.asUint8List());
    _shotSettingsSubject.add(d);
  }

  void _fwMapNotification(ByteData d) {
    _fwMapRequestSubject.add(d);
  }

  void _calibrationNotification(ByteData d) {
    if (d.lengthInBytes < _minCalibrationBytes) {
      _log.warning(
        'Dropping short calibration frame '
        '(${d.lengthInBytes} < $_minCalibrationBytes bytes)',
      );
      return;
    }
    _calibrationSubject.add(d);
  }

  void _mmrNotification(ByteData d) {
    _mmrSubject.add(d);
  }

  Future<ByteData> read(LogicalEndpoint endpoint, {Duration? timeout}) async {
    if (await _transport.connectionState.first !=
        device.ConnectionState.connected) {
      throw const DeviceNotConnectedException.machine();
    }

    try {
      switch (transportType) {
        case TransportType.ble:
          if (endpoint.uuid == null) {
            throw StateError(
              'UnifiedDe1Transport.read: endpoint ${endpoint.name} has no BLE wire support',
            );
          }
          return await _bleRead(endpoint, timeout: timeout);
        case TransportType.serial:
          if (endpoint is! Endpoint) {
            throw StateError(
              'UnifiedDe1Transport.read: endpoint ${endpoint.name} is not a DE1 Endpoint, serial read not supported',
            );
          }
          // ignore: unnecessary_null_comparison, dead_code
          if (endpoint.representation == null) {
            // ignore: dead_code
            throw StateError(
              'UnifiedDe1Transport.read: endpoint ${endpoint.name} has no serial wire support',
            );
          }
          return await _serialRead(
            endpoint,
            timeout ?? const Duration(seconds: 4),
          );
        default:
          throw ("Unknown transport type: $transportType");
      }
    } catch (e, st) {
      if (_isBleTimeout(e)) {
        if (await _handleBleTimeout(e, st)) {
          _log.info('Retrying read of ${endpoint.name} after reconnect');
          return read(endpoint, timeout: timeout);
        }
      }
      if (e is TimeoutException) {
        _log.warning('read of ${endpoint.name} timed out', e, st);
      } else {
        _log.severe("failed to read", e, st);
      }
      rethrow;
    }
  }

  Future<ByteData> _bleRead(LogicalEndpoint e, {Duration? timeout}) async {
    if (_transport is! BLETransport) {
      throw "Invalid transport type, expected BLE";
    }
    var data = await _transport.read(de1ServiceUUID, e.uuid!, timeout: timeout);
    ByteData response = ByteData.sublistView(Uint8List.fromList(data));
    return response;
  }

  Future<ByteData> _serialRead(Endpoint e, Duration timeout) async {
    if (transportType != TransportType.serial) {
      throw "Invalid transport type, expected Serial";
    }

    switch (e) {
      case Endpoint.versions:
      case Endpoint.temperatures:
        return _serialOneShotRead(e, timeout);
      case Endpoint.requestedState:
        throw UnsupportedError(
          'Endpoint ${e.name} has no serial response frame',
        );
      case Endpoint.setTime:
      case Endpoint.shotDirectory:
        throw UnsupportedError('Endpoint ${e.name} has no serial read path');
      case Endpoint.readFromMMR:
        throw UnsupportedError('MMR reads require address correlation');
      case Endpoint.writeToMMR:
        throw UnsupportedError('Endpoint ${e.name} is write-only');
      case Endpoint.shotMapRequest:
      case Endpoint.deleteShotRange:
        throw UnsupportedError('Endpoint ${e.name} has no serial read path');
      case Endpoint.fwMapRequest:
        return _latestSerialFrame(e, _fwMapRequestSubject, timeout);
      case Endpoint.shotSettings:
        return _latestSerialFrame(e, _shotSettingsSubject, timeout);
      case Endpoint.deprecatedShotDesc:
        throw UnsupportedError('Endpoint ${e.name} has no serial read path');
      case Endpoint.shotSample:
        return _latestSerialFrame(e, _shotSampleSubject, timeout);
      case Endpoint.bengleShotSample:
        return _latestSerialFrame(e, _bengleShotSampleSubject, timeout);
      case Endpoint.stateInfo:
        return _latestSerialFrame(e, _stateSubject, timeout);
      case Endpoint.calibration:
        return _latestSerialFrame(e, _calibrationSubject, timeout);
      case Endpoint.headerWrite:
      case Endpoint.frameWrite:
        throw UnsupportedError('Endpoint ${e.name} is write-only');
      case Endpoint.waterLevels:
        return _latestSerialFrame(e, _waterLevelsSubject, timeout);
    }
  }

  Future<ByteData> _latestSerialFrame(
    Endpoint endpoint,
    Stream<ByteData> frames,
    Duration timeout,
  ) {
    return frames.first.timeout(
      timeout,
      onTimeout: () =>
          throw EndpointUnavailableException(endpoint.name, timeout),
    );
  }

  void recordLocalShotSettings(ByteData data) {
    _localShotSettings = Uint8List.fromList(data.buffer.asUint8List());
    _shotSettingsSubject.add(data);
  }

  Future<ByteData> _serialOneShotRead(
    Endpoint endpoint,
    Duration timeout,
  ) async {
    final representation = endpoint.representation;
    final stopwatch = Stopwatch()..start();
    Duration remainingBudget() {
      final remaining = timeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Serial $representation response timed out',
          timeout,
        );
      }
      return remaining;
    }

    final response = _serialResponses.register(representation, timeout);
    Object? failure;
    try {
      await (_transport as SerialTransport)
          .writeCommand('<+$representation>')
          .timeout(remainingBudget());
      return await response;
    } catch (error, stackTrace) {
      failure = error;
      _serialResponses.fail(representation, error, stackTrace);
      try {
        await response;
      } catch (_) {}
      rethrow;
    } finally {
      _serialResponses.remove(representation);
      final cleanup = (_transport as SerialTransport).writeCommand(
        '<-$representation>',
      );
      try {
        await cleanup.timeout(remainingBudget());
      } catch (error, stackTrace) {
        if (error is TimeoutException && stopwatch.elapsed >= timeout) {
          unawaited(
            cleanup.catchError((Object cleanupError, StackTrace cleanupStack) {
              _log.warning(
                'Failed to unsubscribe from serial $representation',
                cleanupError,
                cleanupStack,
              );
            }),
          );
        }
        if (failure == null) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        _log.warning(
          'Failed to unsubscribe from serial $representation',
          error,
          stackTrace,
        );
      }
    }
  }

  Future<void> write(LogicalEndpoint endpoint, Uint8List data) async {
    if (await _transport.connectionState.first !=
        device.ConnectionState.connected) {
      throw const DeviceNotConnectedException.machine();
    }
    try {
      _log.fine('about to write to ${endpoint.name}');
      _log.fine(
        'payload: ${data.map((el) => el.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );

      switch (transportType) {
        case TransportType.ble:
          if (endpoint.uuid == null) {
            throw StateError(
              'UnifiedDe1Transport.write: endpoint ${endpoint.name} has no BLE wire support',
            );
          }
          await _bleWrite(endpoint, data, false);
          break;
        case TransportType.serial:
          if (endpoint.representation == null) {
            throw StateError(
              'UnifiedDe1Transport.write: endpoint ${endpoint.name} has no serial wire support',
            );
          }
          await _serialWrite(endpoint, data);
          break;
        default:
          throw ("Unknown transport type: $transportType");
      }
    } catch (e, st) {
      if (_isBleTimeout(e)) {
        if (await _handleBleTimeout(e, st)) {
          _log.info('Retrying write to ${endpoint.name} after reconnect');
          return write(endpoint, data);
        }
      }
      if (e is TimeoutException) {
        _log.warning('write to ${endpoint.name} timed out', e, st);
      } else {
        _log.severe("failed to write", e, st);
      }
      rethrow;
    }
  }

  Future<void> writeWithResponse(
    LogicalEndpoint endpoint,
    Uint8List data, {
    void Function()? beforeDispatch,
  }) async {
    if (await _transport.connectionState.first !=
        device.ConnectionState.connected) {
      throw const DeviceNotConnectedException.machine();
    }
    try {
      _log.fine('about to write to ${endpoint.name}');
      _log.fine(
        'payload: ${data.map((el) => el.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );
      switch (transportType) {
        case TransportType.ble:
          if (endpoint.uuid == null) {
            throw StateError(
              'UnifiedDe1Transport.writeWithResponse: endpoint ${endpoint.name} has no BLE wire support',
            );
          }
          beforeDispatch?.call();
          await _bleWrite(endpoint, data, true);
          break;
        case TransportType.serial:
          if (endpoint.representation == null) {
            throw StateError(
              'UnifiedDe1Transport.writeWithResponse: endpoint ${endpoint.name} has no serial wire support',
            );
          }
          beforeDispatch?.call();
          await _serialWrite(endpoint, data);
          break;
        default:
          throw ("Unknown transport type: $transportType");
      }
    } catch (e, st) {
      if (_isBleTimeout(e)) {
        if (await _handleBleTimeout(e, st)) {
          _log.info('Retrying write to ${endpoint.name} after reconnect');
          return writeWithResponse(
            endpoint,
            data,
            beforeDispatch: beforeDispatch,
          );
        }
      }
      if (e is TimeoutException) {
        _log.warning('writeWithResponse to ${endpoint.name} timed out', e, st);
      } else {
        _log.severe("failed to write", e, st);
      }
      rethrow;
    }
  }

  bool _isBleTimeout(Object error) {
    return transportType == TransportType.ble && error is BleTimeoutException;
  }

  Future<bool> _handleBleTimeout(Object error, StackTrace st) async {
    _log.warning('BLE write timed out, attempting reconnect');
    _recovering = true;
    final restoreBengleShotSample = _bengleShotSampleEnabled;
    try {
      await _transport.disconnect();
      await _transport.connect();
      await _bleConnect();
      if (restoreBengleShotSample) {
        await subscribeBengleShotSample();
      }
      _log.info('BLE reconnect successful after timeout');
      return true;
    } catch (reconnectError) {
      _log.severe('BLE reconnect failed, disconnecting', reconnectError);
      _recovering = false;
      try {
        _transport.disconnect();
      } catch (e, st) {
        _log.fine('transport.disconnect() during BLE recovery failed', e, st);
      }
      return false;
    } finally {
      _recovering = false;
    }
  }

  Future<void> _serialWrite(LogicalEndpoint e, Uint8List data) async {
    if (_transport is! SerialTransport) {
      throw "Invalid transport type, expected Serial";
    }
    if (e == Endpoint.writeToMMR && data.length > 20) {
      throw ArgumentError.value(
        data.length,
        'data.length',
        'must not exceed 20',
      );
    }
    final frame = e == Endpoint.writeToMMR && data.length < 20
        ? (Uint8List(20)..setAll(0, data))
        : data;
    final payload = frame
        .map((e) => e.toRadixString(16).padLeft(2, '0'))
        .join('');
    await _transport.writeCommand('<${e.representation!}>$payload');
  }

  Future<void> _bleWrite(
    LogicalEndpoint e,
    Uint8List data,
    bool withResponse,
  ) async {
    if (_transport is! BLETransport) {
      throw "Invalid transport type, expected BLE";
    }

    await _transport.write(
      de1ServiceUUID,
      e.uuid!,
      data,
      withResponse: withResponse,
    );
  }
}
