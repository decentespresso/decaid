import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/ble_service_identifier.dart';
import 'package:reaprime/src/models/device/device_implementation.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/subjects.dart';

import '../../grinder.dart';

class BookooGrinder implements Grinder {
  final Logger _log = Logger('BookooGrinder');

  static final BleServiceIdentifier serviceIdentifier =
      BleServiceIdentifier.long('4d543830-0001-4b80-8f00-424f4f4b4f4f');
  static final BleServiceIdentifier commandCharacteristic =
      BleServiceIdentifier.long('4d543830-0002-4b80-8f00-424f4f4b4f4f');
  static final BleServiceIdentifier statusCharacteristic =
      BleServiceIdentifier.long('4d543830-0003-4b80-8f00-424f4f4b4f4f');

  static const _startupQueries = <Map<String, dynamic>>[
    {
      'appHello': {'op': 'handshake'},
    },
    {
      'grindSection': {
        'op': 'get',
        'selector': {'type': 'all'},
      },
    },
    {
      'grindPreset': {
        'op': 'get',
        'selector': {'type': 'all'},
      },
    },
  ];

  final BLETransport _transport;
  final Duration _queryGap;

  final StreamController<GrinderSnapshot> _streamController =
      StreamController.broadcast();
  final StreamController<ConnectionState> _connectionStateController =
      BehaviorSubject.seeded(ConnectionState.discovered);

  int _seq = 0;
  ({int seq, int expect, BytesBuilder bytes})? _pending;

  GrinderDevState _devState = GrinderDevState.unknown;
  int? _feedingRpm;
  int? _grindRpm;
  int? _grindSetting;
  int? _humidity;
  int? _totalGrinds;
  bool? _cupDetect;
  bool? _autoStop;
  bool? _fastClean;
  int? _brightness;
  int? _standbySec;
  String? _wifiName;
  String? _netState;
  String? _snCode;
  String? _resetReason;
  String? _releaseVer;
  List<GrinderPreset> _presets = const [];
  List<GrindSection> _grindSections = const [];
  int? _selectedPresetIndex;

  BookooGrinder({
    required BLETransport transport,
    Duration queryGap = const Duration(milliseconds: 400),
  }) : _transport = transport,
       _queryGap = queryGap;

  final StreamController<GrinderLogEntry> _logController =
      StreamController.broadcast();

  @override
  Stream<GrinderSnapshot> get currentSnapshot => _streamController.stream;

  @override
  Stream<GrinderLogEntry> get logStream => _logController.stream;

  @override
  String get deviceId => _transport.id;

  @override
  DeviceImplementation get implementation => DeviceImplementation.bookooGrinder;

  @override
  TransportType get transportType => _transport.transportType;

  @override
  String get name => 'MOTTO80 Grinder';

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
      await _transport.subscribe(
        serviceIdentifier.long,
        statusCharacteristic.long,
        _parseNotification,
      );
      _seq = 0;
      _pending = null;
      _connectionStateController.add(ConnectionState.connected);
      unawaited(_runStartupQueries());
    } catch (e) {
      _log.warning('Connect failed: $e');
      disconnectSub?.cancel();
      _connectionStateController.add(ConnectionState.disconnected);
      try {
        await _transport.disconnect();
      } catch (_) {}
    }
  }

  @override
  Future<void> disconnect() async {
    await _transport.disconnect();
  }

  @override
  DeviceType get type => DeviceType.grinder;

  @override
  Future<void> start() async {
    await _send({
      'grind': {'op': 'start'},
    });
  }

  @override
  Future<void> stop() async {
    await _send({
      'grind': {'op': 'stop'},
    });
  }

  @override
  Future<void> querySections() async {
    await _send({
      'grindSection': {
        'op': 'get',
        'selector': {'type': 'all'},
      },
    });
  }

  @override
  Future<void> queryPresets() async {
    await _send({
      'grindPreset': {
        'op': 'get',
        'selector': {'type': 'all'},
      },
    });
  }

  @override
  Future<void> setGrindSection({int? index, String? name}) async {
    final data = index != null
        ? <String, dynamic>{'index': index}
        : <String, dynamic>{'name': name};
    await _send({
      'grindSection': {'op': 'set', 'data': data},
    });
  }

  @override
  Future<void> setPreset({String? uid, int? index}) async {
    final data = uid != null
        ? <String, dynamic>{'uid': uid}
        : <String, dynamic>{'index': index};
    await _send({
      'grindPreset': {'op': 'set', 'data': data},
    });
  }

  @override
  Future<void> setFeedingRpm(int rpm) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'feedingRpm': rpm},
      },
    });
  }

  @override
  Future<void> setGrindRpm(int rpm) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'grindRpm': rpm},
      },
    });
  }

  @override
  Future<void> setGrindSetting(int value) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'bladeGap': value},
      },
    });
  }

  @override
  Future<void> setBrightness(int level) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'brightness': level},
      },
    });
  }

  @override
  Future<void> setStandbySec(int seconds) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'standbySec': seconds},
      },
    });
  }

  @override
  Future<void> setCupDetect(bool enabled) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'cupDetect': enabled},
      },
    });
  }

  @override
  Future<void> setAutoStop(bool enabled) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'autoStop': enabled},
      },
    });
  }

  @override
  Future<void> setFastClean(bool enabled) async {
    await _send({
      'geneSetting': {
        'op': 'set',
        'data': {'fastClean': enabled},
      },
    });
  }

  @override
  Future<void> reboot() async {
    await _send({
      'reboot': {'op': 'set', 'data': <String, dynamic>{}},
    });
  }

  Future<void> _runStartupQueries() async {
    for (final request in _startupQueries) {
      await Future<void>.delayed(_queryGap);
      try {
        await _send(request);
      } catch (e) {
        _log.warning('Startup query failed: $request', e);
      }
    }
  }

  Future<void> _send(Map<String, dynamic> request) async {
    final payload = utf8.encode(jsonEncode({'request': request}));
    final frame = Uint8List(8 + payload.length);
    final view = ByteData.sublistView(frame);
    frame[0] = 0xA5;
    frame[1] = 0x01;
    view.setUint16(2, _seq, Endian.little);
    view.setUint32(4, payload.length, Endian.little);
    frame.setRange(8, 8 + payload.length, payload);
    _seq = (_seq + 1) & 0xffff;
    _logController.add(
      GrinderLogEntry(
        kind: GrinderLogKind.send,
        seq: (_seq - 1) & 0xffff,
        text: jsonEncode({'request': request}),
      ),
    );
    try {
      await _transport.write(
        serviceIdentifier.long,
        commandCharacteristic.long,
        frame,
      );
      // ignore: empty_catches
    } on DeviceNotConnectedException {}
  }

  void _parseNotification(Uint8List chunk) {
    BytesBuilder bytes;
    int seq;
    int expect;
    if (chunk.length >= 8 && chunk[0] == 0xA5 && chunk[1] == 0x01) {
      final view = ByteData.sublistView(chunk);
      seq = view.getUint16(2, Endian.little);
      expect = view.getUint32(4, Endian.little);
      if (_pending == null || _pending!.seq != seq) {
        bytes = BytesBuilder();
        _pending = (seq: seq, expect: expect, bytes: bytes);
      } else {
        bytes = _pending!.bytes;
      }
      bytes.add(chunk.sublist(8));
    } else if (_pending != null) {
      bytes = _pending!.bytes;
      seq = _pending!.seq;
      expect = _pending!.expect;
      bytes.add(chunk);
    } else {
      return;
    }
    if (bytes.length < expect) return;
    _pending = null;
    _handleFrame(seq, utf8.decode(bytes.takeBytes(), allowMalformed: true));
  }

  void _handleFrame(int seq, String text) {
    _logController.add(
      GrinderLogEntry(
        kind: text.contains('"response"')
            ? GrinderLogKind.response
            : GrinderLogKind.broadcast,
        seq: seq,
        text: text,
      ),
    );
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) return;
    if (text.contains('"response"')) {
      _handleResponse(decoded);
    } else {
      _mergeBroadcast(decoded);
    }
    _streamController.add(_snapshot());
    _log.fine(
      'Snapshot: ${_devState.name} rpm=$_grindRpm feeding=$_feedingRpm '
      'gap=$_grindSetting presets=${_presets.length} sections=${_grindSections.length}',
    );
  }

  void _handleResponse(Map<String, dynamic> decoded) {
    final request = decoded['request'];
    if (request is Map<String, dynamic>) {
      if (request.containsKey('grindPreset')) {
        _presets = _extractPresets(decoded);
      }
      if (request.containsKey('grindSection')) {
        _grindSections = _extractSections(decoded);
      }
    }
    _mergeBroadcast(decoded);
  }

  List<GrinderPreset> _extractPresets(Map<String, dynamic> decoded) {
    final result = <GrinderPreset>[];
    void walk(dynamic node) {
      if (node is Map<String, dynamic>) {
        final uid = node['uid'];
        final name = node['name'];
        if (uid is String && name is String) {
          result.add(GrinderPreset(uid: uid, name: name));
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final value in node) {
          walk(value);
        }
      }
    }

    walk(decoded);
    return result;
  }

  List<GrindSection> _extractSections(Map<String, dynamic> decoded) {
    final result = <GrindSection>[];
    void walk(dynamic node) {
      if (node is Map<String, dynamic>) {
        final index = node['index'];
        final name = node['name'];
        if (index is int && name is String) {
          result.add(GrindSection(index: index, name: name));
        }
        for (final value in node.values) {
          walk(value);
        }
      } else if (node is List) {
        for (final value in node) {
          walk(value);
        }
      }
    }

    walk(decoded);
    return result;
  }

  void _mergeBroadcast(Map<String, dynamic> decoded) {
    final broadcast = decoded['broadcast'];
    final periodInfo = broadcast is Map<String, dynamic>
        ? broadcast['periodInfo']
        : null;
    final fields = decoded['fields'];
    final source = fields is Map<String, dynamic>
        ? fields
        : periodInfo is Map<String, dynamic>
        ? periodInfo
        : decoded;
    _feedingRpm = _asInt(source['feedingRpm']) ?? _feedingRpm;
    _grindRpm = _asInt(source['grindRpm']) ?? _grindRpm;
    _grindSetting =
        _asInt(source['bladeGap']) ?? _asInt(source['grindSetting']) ?? _grindSetting;
    _humidity = _asInt(source['humidity']) ?? _humidity;
    _totalGrinds = _asInt(source['totalGrinds']) ?? _totalGrinds;
    _cupDetect = _asBool(source['cupDetect']) ?? _cupDetect;
    _autoStop = _asBool(source['autoStop']) ?? _autoStop;
    _fastClean = _asBool(source['fastClean']) ?? _fastClean;
    _brightness = _asInt(source['brightness']) ?? _brightness;
    _standbySec = _asInt(source['standbySec']) ?? _standbySec;
    _wifiName = _asString(source['wifiName']) ?? _wifiName;
    _netState = _asString(source['netState']) ?? _netState;
    _snCode = _asString(source['snCode']) ?? _snCode;
    _resetReason = _asString(source['resetReason']) ?? _resetReason;
    _releaseVer = _asString(source['releaseVer']) ?? _releaseVer;
    _selectedPresetIndex =
        _asInt(source['selectPreset']) ?? _selectedPresetIndex;
    final devState = _asString(source['devState']);
    if (devState != null) {
      _devState = switch (devState) {
        'IDLE' => GrinderDevState.idle,
        'GRINDING' => GrinderDevState.grinding,
        'HIGHSPEEDCLEAN' => GrinderDevState.highspeedClean,
        'SETTING' => GrinderDevState.setting,
        _ => GrinderDevState.unknown,
      };
    }
  }

  GrinderSnapshot _snapshot() {
    return GrinderSnapshot(
      timestamp: DateTime.now(),
      devState: _devState,
      feedingRpm: _feedingRpm,
      grindRpm: _grindRpm,
      grindSetting: _grindSetting,
      humidity: _humidity,
      totalGrinds: _totalGrinds,
      cupDetect: _cupDetect,
      autoStop: _autoStop,
      fastClean: _fastClean,
      brightness: _brightness,
      standbySec: _standbySec,
      wifiName: _wifiName,
      netState: _netState,
      snCode: _snCode,
      resetReason: _resetReason,
      releaseVer: _releaseVer,
      presets: _presets,
      selectedPresetIndex: _selectedPresetIndex,
      grindSections: _grindSections,
    );
  }

  int? _asInt(dynamic value) => value is num ? value.toInt() : null;

  bool? _asBool(dynamic value) => value is bool ? value : null;

  String? _asString(dynamic value) => value is String ? value : null;
}
