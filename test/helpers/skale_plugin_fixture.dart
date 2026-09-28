import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:reaprime/src/models/device/device.dart' as device;
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'plugin_ble_fixture.dart';

const skalePluginPath = 'examples/plugins/skale.reaplugin';
const skaleServiceUuid = '0000ff08-0000-1000-8000-00805f9b34fb';
const skaleWeightCharacteristicUuid = '0000ef81-0000-1000-8000-00805f9b34fb';
const skaleCommandCharacteristicUuid = '0000ef80-0000-1000-8000-00805f9b34fb';
const skaleButtonCharacteristicUuid = '0000ef82-0000-1000-8000-00805f9b34fb';
const skaleBatteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const skaleBatteryCharacteristicUuid = '00002a19-0000-1000-8000-00805f9b34fb';
const skaleDeviceInformationServiceUuid =
    '0000180a-0000-1000-8000-00805f9b34fb';
const skaleFirmwareCharacteristicUuid = '00002a26-0000-1000-8000-00805f9b34fb';

class SkaleSettingsFixture {
  final values = <String, Map<String, bool>>{};
  var defaultUsbPower = false;
  var defaultSquareAction = false;
  var error = false;
  var delay = Duration.zero;
  var machineDelay = Duration.zero;
  Map<String, dynamic> scaleConnections = {
    'primary': null,
    'auxiliary': <Map<String, dynamic>>[],
  };
  Map<String, dynamic> machineState = {
    'deviceId': 'MockDe1',
    'connectionGeneration': 1,
    'state': {'state': 'idle', 'substate': 'idle'},
  };
  Map<String, dynamic> machineInfo = {
    'version': '1.0',
    'model': 'MockDe1',
    'serialNumber': 'mock',
    'GHC': false,
  };
  final machineRequests = <Map<String, dynamic>>[];
  Completer<void>? holdStartResponse;
  Completer<void>? startRequestStarted;
  FutureOr<shelf.Response> Function(shelf.Request request)? apiHandler;
  HttpServer? _server;

  List<Map<String, dynamic>> get connectedScaleInventory {
    final entries = <Map<String, dynamic>>[];
    final primary = scaleConnections['primary'];
    if (primary is Map && primary['deviceId'] is String) {
      entries.add({
        'id': primary['deviceId'],
        'type': 'scale',
        'state': 'connected',
        'available': true,
        'connectionRole': 'primary',
      });
    }
    final auxiliary = scaleConnections['auxiliary'];
    if (auxiliary is List) {
      for (final entry in auxiliary.whereType<Map>()) {
        if (entry['deviceId'] is String) {
          entries.add({
            'id': entry['deviceId'],
            'type': 'scale',
            'state': 'connected',
            'available': true,
            'connectionRole': 'auxiliary',
          });
        }
      }
    }
    return entries;
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final response = request.response;
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (machineDelay > Duration.zero &&
          request.uri.path.startsWith('/api/v1/machine/')) {
        await Future<void>.delayed(machineDelay);
      }
      final hostApiRoute =
          request.uri.path == '/api/v1/scale/connections' ||
          request.uri.path == '/api/v1/machine/state' ||
          request.uri.path == '/api/v1/machine/info' ||
          request.uri.path.startsWith('/api/v1/machine/state/');
      if (!error && apiHandler != null && hostApiRoute) {
        final body = await utf8.decoder.bind(request).join();
        final requestHeaders = <String, String>{};
        request.headers.forEach(
          (name, values) => requestHeaders[name] = values.join(', '),
        );
        final hostResponse = await apiHandler!(
          shelf.Request(
            request.method,
            Uri(
              scheme: 'http',
              host: '127.0.0.1',
              port: 8080,
              path: request.uri.path,
              query: request.uri.query,
            ),
            headers: requestHeaders,
            body: body,
          ),
        );
        response.statusCode = hostResponse.statusCode;
        hostResponse.headers.forEach(response.headers.set);
        response.write(await hostResponse.readAsString());
      } else if (error) {
        response.statusCode = HttpStatus.internalServerError;
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/v1/devices') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(connectedScaleInventory));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/v1/scale/connections') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(scaleConnections));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/v1/machine/state') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(machineState));
      } else if (request.method == 'GET' &&
          request.uri.path == '/api/v1/machine/info') {
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(machineInfo));
      } else if (request.method == 'PUT' &&
          request.uri.path.startsWith('/api/v1/machine/state/')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        machineRequests.add({
          'target': request.uri.path.split('/').last,
          'body': body,
        });
        final current = Map<String, dynamic>.from(machineState);
        current['state'] = {
          'state': request.uri.path.split('/').last,
          'substate': request.uri.path.split('/').last,
        };
        machineState = current;
        if (request.uri.path.endsWith('/espresso') &&
            holdStartResponse != null) {
          if (!(startRequestStarted?.isCompleted ?? true)) {
            startRequestStarted!.complete();
          }
          await holdStartResponse!.future;
        }
        response.headers.contentType = ContentType.json;
        response.write('{}');
      } else if (request.method == 'GET') {
        final key = request.uri.pathSegments.last;
        final value = values.putIfAbsent(
          key,
          () => {
            'usbPower': defaultUsbPower,
            'squareAction': defaultSquareAction,
          },
        );
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(value));
      } else if (request.method == 'POST') {
        final key = request.uri.pathSegments.last;
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        values[key] = {
          'usbPower': body['usbPower'] as bool,
          'squareAction': body['squareAction'] == true,
        };
        response.headers.contentType = ContentType.json;
        response.write(jsonEncode(values[key]));
      } else {
        response.statusCode = HttpStatus.methodNotAllowed;
      }
      await response.close();
    });
  }

  Future<void> close() => _server?.close(force: true) ?? Future<void>.value();

  HttpClient createHttpClient(SecurityContext? context) {
    final client = HttpClient(context: context);
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      final host = uri.host == '127.0.0.1' && uri.port == 8080
          ? '127.0.0.1'
          : uri.host;
      final port = uri.host == '127.0.0.1' && uri.port == 8080
          ? _server!.port
          : uri.port;
      return Future.value(
        ConnectionTask.fromSocket(Socket.connect(host, port), () {}),
      );
    };
    return client;
  }
}

class SkaleSettingsHttpOverrides extends HttpOverrides {
  SkaleSettingsHttpOverrides(this.fixture);

  final SkaleSettingsFixture fixture;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final previous = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      return fixture.createHttpClient(context);
    } finally {
      HttpOverrides.global = previous;
    }
  }
}

PluginManifest skaleManifest() => PluginManifest.fromJson(
  jsonDecode(File('$skalePluginPath/manifest.json').readAsStringSync()),
);

Future<void> loadSkalePlugin(PluginManager manager) => manager.loadPlugin(
  id: skaleManifest().id,
  manifest: skaleManifest(),
  settings: {},
  jsCode: File('$skalePluginPath/plugin.js').readAsStringSync(),
);

List<int> skaleFourBytePacket(double grams) {
  final raw = (grams * 2560).round();
  final value = ByteData(4)..setInt32(0, raw, Endian.little);
  return value.buffer.asUint8List().toList();
}

List<int> skaleFiveBytePacket(double grams) {
  final scaled = (grams * 100).round();
  final mantissa = scaled & 0xffffff;
  return [
    0,
    mantissa & 0xff,
    (mantissa >> 8) & 0xff,
    ((mantissa >> 16) & 0x7f) | (scaled < 0 ? 0x80 : 0),
    0xfe,
  ];
}

List<int> skaleNineBytePacket(double grams) => [
  ...skaleFiveBytePacket(grams),
  0,
  0,
  0,
  0,
];

class SkalePluginTransport extends PluginBleFixtureTransport {
  SkalePluginTransport(
    super.physicalId, {
    this.firstPacket,
    this.servicePresent = true,
    this.batteryPresent = true,
    this.batteryLevel = 80,
    this.batteryReadDelay = Duration.zero,
    this.deviceInformationPresent = false,
    this.firmwareValue,
  });

  final List<int>? firstPacket;
  final bool servicePresent;
  final bool batteryPresent;
  final int batteryLevel;
  final Duration batteryReadDelay;
  final bool deviceInformationPresent;
  final List<int>? firmwareValue;
  final batteryValues = <int>[];
  final weightSubscribed = Completer<void>();
  final buttonSubscribed = Completer<void>();
  final finalEnable = Completer<void>();
  var batteryReads = 0;

  @override
  Future<void> connect() async {
    connectCalls++;
    states.add(device.ConnectionState.connected);
  }

  @override
  Future<List<String>> discoverServices() async => [
    if (servicePresent) skaleServiceUuid,
    if (batteryPresent) skaleBatteryServiceUuid,
    if (deviceInformationPresent) skaleDeviceInformationServiceUuid,
  ];

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    if (service != skaleServiceUuid ||
        (characteristic != skaleWeightCharacteristicUuid &&
            characteristic != skaleButtonCharacteristicUuid)) {
      throw StateError(
        'Unexpected Skale subscription $service/$characteristic',
      );
    }
    subscribers[characteristic] = callback;
    if (characteristic == skaleWeightCharacteristicUuid) {
      if (firstPacket != null) callback(Uint8List.fromList(firstPacket!));
      if (!weightSubscribed.isCompleted) weightSubscribed.complete();
    } else if (!buttonSubscribed.isCompleted) {
      buttonSubscribed.complete();
    }
  }

  @override
  Future<Uint8List> read(
    String service,
    String characteristic, {
    Duration? timeout,
  }) async {
    if (service == skaleBatteryServiceUuid &&
        characteristic == skaleBatteryCharacteristicUuid) {
      batteryReads++;
      if (batteryReadDelay > Duration.zero) {
        await Future<void>.delayed(batteryReadDelay);
      }
      final value = batteryValues.isEmpty
          ? batteryLevel
          : batteryValues.removeAt(0);
      return Uint8List.fromList([value]);
    }
    if (service == skaleDeviceInformationServiceUuid &&
        characteristic == skaleFirmwareCharacteristicUuid &&
        firmwareValue != null) {
      return Uint8List.fromList(firmwareValue!);
    }
    throw StateError('Unexpected Skale read $service/$characteristic');
  }

  @override
  Future<void> write(
    String service,
    String characteristic,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (service != skaleServiceUuid ||
        characteristic != skaleCommandCharacteristicUuid) {
      throw StateError('Unexpected Skale write $service/$characteristic');
    }
    await super.write(
      service,
      characteristic,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
    if (data.length == 1 && data[0] == 0x03 && !finalEnable.isCompleted) {
      finalEnable.complete();
    }
  }

  void emitWeight(List<int> packet) =>
      subscribers[skaleWeightCharacteristicUuid]?.call(
        Uint8List.fromList(packet),
      );

  void emitButton(int button) => subscribers[skaleButtonCharacteristicUuid]
      ?.call(Uint8List.fromList([button]));

  void dropLink() {
    if (!states.isClosed) states.add(device.ConnectionState.disconnected);
  }
}
