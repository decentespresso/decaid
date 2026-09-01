import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:reaprime/src/models/device/impl/bookoo/bookoo_grinder.dart';
import 'package:reaprime/src/models/device/transport/ble_transport.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:rxdart/rxdart.dart';

class _BookooTransport extends BLETransport {
  final BehaviorSubject<ConnectionState> states = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );
  final List<List<int>> writes = [];
  void Function(Uint8List)? notification;
  Object? writeError;
  bool failConnect = false;
  List<String> discoverServicesOverride = [];

  @override
  Future<List<String>> discoverServices() async =>
      discoverServicesOverride.isEmpty
      ? [BookooGrinder.serviceIdentifier.long]
      : discoverServicesOverride;

  @override
  String get id => 'motto80-test';

  @override
  String get name => 'MOTTO80 BLE';

  @override
  Stream<ConnectionState> get connectionState => states.stream;

  @override
  Future<ConnectionState> getConnectionState() async => states.value;

  @override
  Future<void> connect() async {
    if (failConnect) throw StateError('connect failed');
    states.add(ConnectionState.connected);
  }

  @override
  Future<void> disconnect() async => states.add(ConnectionState.disconnected);

  @override
  Future<Uint8List> read(
    String serviceUUID,
    String characteristicUUID, {
    Duration? timeout,
  }) async => Uint8List(0);

  @override
  Future<void> subscribe(
    String serviceUUID,
    String characteristicUUID,
    void Function(Uint8List) callback,
  ) async {
    notification = callback;
  }

  @override
  Future<void> write(
    String serviceUUID,
    String characteristicUUID,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    writes.add(data.toList());
    final error = writeError;
    if (error != null) throw error;
  }

  void emit(List<int> data) => notification!(Uint8List.fromList(data));

  @override
  Future<void> setTransportPriority(bool prioritized) async {}

  @override
  Future<void> dispose() async => states.close();
}

Uint8List _frame(int seq, String jsonPayload) {
  final payload = utf8.encode(jsonPayload);
  final frame = Uint8List(8 + payload.length);
  final view = ByteData.sublistView(frame);
  frame[0] = 0xA5;
  frame[1] = 0x01;
  view.setUint16(2, seq & 0xffff, Endian.little);
  view.setUint32(4, payload.length, Endian.little);
  frame.setRange(8, 8 + payload.length, payload);
  return frame;
}

BookooGrinder _grinder(_BookooTransport transport) =>
    BookooGrinder(transport: transport, queryGap: Duration.zero);

void main() {
  late _BookooTransport transport;
  late BookooGrinder grinder;
  late List<GrinderSnapshot> snapshots;

  setUp(() async {
    transport = _BookooTransport();
    grinder = _grinder(transport);
    snapshots = [];
    await grinder.onConnect();
    for (var i = 0; i < 3; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    grinder.currentSnapshot.listen(snapshots.add);
  });

  tearDown(() async {
    await grinder.disconnect();
    await transport.dispose();
  });

  test('onConnect subscribes and sends the startup query sequence', () {
    final encoded = transport.writes.map(_decodeWrite).toList();
    expect(encoded[0], {
      'request': {
        'appHello': {'op': 'handshake'},
      },
    });
    expect(encoded[1], {
      'request': {
        'grindSection': {
          'op': 'get',
          'selector': {'type': 'all'},
        },
      },
    });
    expect(encoded[2], {
      'request': {
        'grindPreset': {
          'op': 'get',
          'selector': {'type': 'all'},
        },
      },
    });
  });

  test('frames carry the A5 01 header, little-endian seq, and length', () {
    final first = transport.writes[0];
    expect(first[0], 0xA5);
    expect(first[1], 0x01);
    expect(first[2], 0x00); // seq 0
    expect(first[3], 0x00);
    final second = transport.writes[1];
    expect(second[2], 0x01); // seq 1
    final third = transport.writes[2];
    expect(third[2], 0x02); // seq 2
    final payloadLen = ByteData.sublistView(
      Uint8List.fromList(first),
    ).getUint32(4, Endian.little);
    expect(payloadLen, first.length - 8);
  });

  test('decodes a real broadcast.periodInfo frame into a snapshot', () async {
    transport.emit(
      _frame(
        0x1001,
        jsonEncode({
          'broadcast': {
            'periodInfo': {
              'devState': 'SETTING',
              'feedingRpm': 50,
              'grindRpm': 750,
              'grindSetting': 250,
              'humidity': 35,
              'totalGrinds': 26,
              'cupDetect': true,
              'autoStop': true,
              'fastClean': true,
              'brightness': 4,
              'standbySec': 480,
              'netState': 'CONNECTED',
              'selectPreset': -1,
            },
          },
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final s = snapshots.single;
    expect(s.devState, GrinderDevState.setting);
    expect(s.feedingRpm, 50);
    expect(s.grindRpm, 750);
    expect(s.grindSetting, 250);
    expect(s.humidity, 35);
    expect(s.totalGrinds, 26);
    expect(s.cupDetect, isTrue);
    expect(s.autoStop, isTrue);
    expect(s.fastClean, isTrue);
    expect(s.brightness, 4);
    expect(s.standbySec, 480);
    expect(s.netState, 'CONNECTED');
    expect(s.selectedPresetIndex, -1);
  });

  test('decodes a legacy flat broadcast frame into a snapshot', () async {
    transport.emit(
      _frame(
        0x1001,
        jsonEncode({
          'fields': {
            'devState': 'GRINDING',
            'feedingRpm': 30,
            'grindRpm': 800,
            'grindSetting': 400,
            'humidity': 55,
            'totalGrinds': 1234,
            'cupDetect': true,
            'autoStop': false,
            'fastClean': false,
            'brightness': 5,
            'standbySec': 300,
            'snCode': 'M80-0001',
            'releaseVer': '1.0.0',
          },
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final s = snapshots.single;
    expect(s.devState, GrinderDevState.grinding);
    expect(s.feedingRpm, 30);
    expect(s.grindRpm, 800);
    expect(s.grindSetting, 400);
    expect(s.humidity, 55);
    expect(s.totalGrinds, 1234);
    expect(s.cupDetect, isTrue);
    expect(s.autoStop, isFalse);
    expect(s.snCode, 'M80-0001');
  });

  test('later broadcasts merge, retaining missing fields', () async {
    transport.emit(
      _frame(
        0x2001,
        jsonEncode({
          'fields': {'devState': 'IDLE'},
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    transport.emit(
      _frame(
        0x2002,
        jsonEncode({
          'fields': {'grindRpm': 900},
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.last.devState, GrinderDevState.idle);
    expect(snapshots.last.grindRpm, 900);
  });

  test('parses presets and sections from query responses', () async {
    transport.emit(
      _frame(
        0x3001,
        jsonEncode({
          'request': {
            'grindPreset': {
              'op': 'get',
              'response': [
                {'uid': 'aabb', 'name': 'Espresso Fine'},
                {'uid': 'ccdd', 'name': 'Pour Over'},
              ],
            },
          },
        }),
      ),
    );
    transport.emit(
      _frame(
        0x3002,
        jsonEncode({
          'request': {
            'grindSection': {
              'op': 'get',
              'response': [
                {'index': 0, 'name': 'Fine'},
                {'index': 1, 'name': 'Coarse'},
              ],
            },
          },
        }),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final s = snapshots.last;
    expect(s.presets.map((p) => p.name), ['Espresso Fine', 'Pour Over']);
    expect(s.presets.first.uid, 'aabb');
    expect(s.grindSections.map((g) => g.name), ['Fine', 'Coarse']);
    expect(s.grindSections.first.index, 0);
  });

  test('reassembles a fragmented frame with repeated header', () async {
    final full = _frame(
      0x4001,
      jsonEncode({
        'fields': {'devState': 'GRINDING', 'grindRpm': 750},
      }),
    );
    transport.emit(full.sublist(0, 10));
    transport.emit([...full.sublist(0, 8), ...full.sublist(10, 20)]);
    transport.emit(full.sublist(20));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.devState, GrinderDevState.grinding);
    expect(snapshots.single.grindRpm, 750);
  });

  test('reassembles headerless continuation fragments', () async {
    final full = _frame(
      0x4002,
      jsonEncode({
        'fields': {'devState': 'IDLE', 'grindSetting': 300},
      }),
    );
    transport.emit(full.sublist(0, 12));
    transport.emit(full.sublist(12, 20));
    transport.emit(full.sublist(20));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.devState, GrinderDevState.idle);
    expect(snapshots.single.grindSetting, 300);
  });

  test('decodes UTF-8 split across fragment boundaries', () async {
    final payload = utf8.encode(
      jsonEncode({
        'request': {
          'grindPreset': {
            'op': 'get',
            'response': [
              {'uid': 'aa', 'name': '意式中深'},
            ],
          },
        },
      }),
    );
    // Split inside the multibyte characters of 意式中深
    final split = _findMultibyteSplit(payload);
    final frame = Uint8List(8 + payload.length);
    final view = ByteData.sublistView(frame);
    frame[0] = 0xA5;
    frame[1] = 0x01;
    view.setUint32(4, payload.length, Endian.little);
    frame.setRange(8, 8 + payload.length, payload);
    transport.emit(frame.sublist(0, split));
    transport.emit(frame.sublist(split));
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.presets.single.name, '意式中深');
  });

  test('different-seq new frame drops stale pending', () async {
    final first = _frame(
      0x5001,
      jsonEncode({
        'fields': {'devState': 'GRINDING'},
      }),
    );
    final second = _frame(
      0x5002,
      jsonEncode({
        'fields': {'devState': 'IDLE'},
      }),
    );
    transport.emit(first.sublist(0, 12));
    transport.emit(second);
    await Future<void>.delayed(Duration.zero);
    expect(snapshots.single.devState, GrinderDevState.idle);
  });

  test('start and stop write the expected command frames', () async {
    final before = transport.writes.length;
    await grinder.start();
    await grinder.stop();
    final commands = transport.writes
        .sublist(before)
        .map(_decodeWrite)
        .toList();
    expect(commands[0], {
      'request': {
        'grind': {'op': 'start'},
      },
    });
    expect(commands[1], {
      'request': {
        'grind': {'op': 'stop'},
      },
    });
  });

  test('geneSetting setters write the expected payloads', () async {
    final before = transport.writes.length;
    await grinder.setGrindSetting(400);
    await grinder.setGrindRpm(850);
    await grinder.setCupDetect(true);
    final commands = transport.writes
        .sublist(before)
        .map(_decodeWrite)
        .toList();
    expect(commands[0], {
      'request': {
        'geneSetting': {
          'op': 'set',
          'data': {'bladeGap': 400},
        },
      },
    });
    expect(commands[1], {
      'request': {
        'geneSetting': {
          'op': 'set',
          'data': {'grindRpm': 850},
        },
      },
    });
    expect(commands[2], {
      'request': {
        'geneSetting': {
          'op': 'set',
          'data': {'cupDetect': true},
        },
      },
    });
  });

  test('disconnected command failure is ignored', () async {
    transport.writeError = const DeviceNotConnectedException.grinder();
    await expectLater(grinder.start(), completes);
  });

  test('unrelated command failure propagates', () async {
    transport.writeError = StateError('write failed');
    await expectLater(grinder.start(), throwsStateError);
  });

  test('connect failure emits disconnected', () async {
    final failedTransport = _BookooTransport()..failConnect = true;
    final failedGrinder = _grinder(failedTransport);
    await failedGrinder.onConnect();
    expect(
      await failedGrinder.connectionState.first,
      ConnectionState.disconnected,
    );
    await failedTransport.dispose();
  });

  test('missing service emits disconnected', () async {
    final wrongTransport = _BookooTransport()
      ..discoverServicesOverride = ['0000ffe0-0000-1000-8000-00805f9b34fb'];
    final wrongGrinder = _grinder(wrongTransport);
    await wrongGrinder.onConnect();
    expect(
      await wrongGrinder.connectionState.first,
      ConnectionState.disconnected,
    );
    await wrongTransport.dispose();
  });
}

Map<String, dynamic> _decodeWrite(List<int> bytes) {
  final payload = bytes.sublist(8);
  return jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
}

int _findMultibyteSplit(List<int> payload) {
  for (var i = 8; i < payload.length - 1; i++) {
    if (payload[i] > 0x7F && payload[i + 1] > 0x7F) {
      return i;
    }
  }
  return payload.length ~/ 2;
}
