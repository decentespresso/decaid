import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';
import 'package:reaprime/src/models/device/impl/sensor/bengle_debug_port.dart';
import 'package:reaprime/src/models/device/impl/sensor/debug_port.dart';
import 'package:reaprime/src/models/device/impl/sensor/sensor_basket.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';

import 'mmr_codec.dart';
import 'serial_reconcile.dart';
import 'serial_writer.dart';
import 'usb_ids.dart';
import 'utils.dart';

import 'package:rxdart/subjects.dart';

// ignore: depend_on_referenced_packages
import 'package:libserialport/libserialport.dart';

class SerialServiceDesktop implements DeviceDiscoveryService {
  final _log = Logger("Serial service");

  List<Device> _devices = [];

  final Map<String, String> _portPathToDeviceId = {};

  final Map<String, _DesktopSerialPort> _portPathToTransport = {};

  final Map<String, Device> _portPathToDevice = {};

  Set<String> _lastEmittedIds = {};

  final Set<String> _selfDisconnectedPaths = {};

  final Set<String> _hdsPaths = {};

  final Set<String> _nonDecentPorts = {};
  int _livenessTick = 0;
  static const int _livenessEveryNReconciles = 3;

  bool _forceEmitOnNextScan = false;

  bool _isScanning = false;
  Future<void>? _currentScan;

  final Duration _reconcileInterval;
  Timer? _reconcileTimer;

  SerialServiceDesktop({this._reconcileInterval = const Duration(seconds: 8)});

  final BehaviorSubject<List<Device>> _machineSubject = BehaviorSubject.seeded(
    <Device>[],
  );
  @override
  Stream<List<Device>> get devices => _machineSubject.stream;

  @override
  Future<void> initialize() async {
    final list = SerialPort.availablePorts;
    _log.info("Initializing");
    _log.info("found ports: $list");
    _reconcileTimer ??= Timer.periodic(_reconcileInterval, (_) => _runScan());
  }

  Future<void> dispose() async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    for (final entry in _portPathToTransport.entries) {
      try {
        await entry.value.dispose();
      } catch (e, st) {
        _log.warning("dispose failed for ${entry.key}", e, st);
      }
    }
    _portPathToTransport.clear();
    _portPathToDevice.clear();
    _portPathToDeviceId.clear();
    _selfDisconnectedPaths.clear();
    _hdsPaths.clear();
    _nonDecentPorts.clear();
    if (!_machineSubject.isClosed) await _machineSubject.close();
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    final impl = remembered.implementation;
    final tt = remembered.transportType;
    if (impl == null || tt == null || tt != TransportType.serial) {
      return null;
    }

    final ports = (await SerialPort.availablePorts).toSet();
    final metadata = <SerialPortMetadata>[];
    for (final path in ports) {
      final port = SerialPort(path);
      try {
        metadata.add(_readPortMetadata(path, port));
      } finally {
        port.dispose();
      }
    }
    final candidates = dedupeSerialCandidates(metadata);
    for (final candidate in candidates) {
      if (!candidate.acceptedIds.contains(remembered.id)) continue;

      _log.info(
        'Quick-connect: found port ${candidate.path} for ${remembered.id}',
      );
      Device? device;
      try {
        device = await _detectDevice(candidate);
      } catch (e, st) {
        _log.warning(
          'Quick-connect: _detectDevice failed for ${candidate.path}',
          e,
          st,
        );
        continue;
      }
      if (device == null || device.implementation != impl) {
        _log.info(
          'Quick-connect: device mismatch on ${candidate.path}'
          ' (expected $impl, got ${device?.implementation})',
        );
        try {
          await device?.disconnect();
        } catch (_) {}
        final t = _portPathToTransport.remove(candidate.path);
        try {
          await t?.dispose();
        } catch (_) {}
        continue;
      }
      try {
        await device.onConnect().timeout(const Duration(seconds: 10));
        _portPathToDevice[candidate.path] = device;
        _portPathToDeviceId[candidate.path] = device.deviceId;
        late final StreamSubscription<ConnectionState> stateSub;
        stateSub = device.connectionState.listen((state) {
          if (state == ConnectionState.disconnected) {
            unawaited(
              _handleQuickConnectedDisconnect(candidate.path, stateSub),
            );
          }
        });
        _devices = _portPathToDevice.values.toList();
        _lastEmittedIds = _devices.map((d) => d.deviceId).toSet();
        _machineSubject.add(_devices);
        _log.info('Quick-connect succeeded for ${remembered.id}');
        return device;
      } catch (e, st) {
        _log.warning(
          'Quick-connect: onConnect failed for ${candidate.path}',
          e,
          st,
        );
        try {
          await device.disconnect();
        } catch (_) {}
        final t = _portPathToTransport.remove(candidate.path);
        try {
          await t?.dispose();
        } catch (_) {}
      }
    }
    return null;
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) =>
      _runScan(forceEmit: true);

  Future<void> _runScan({bool forceEmit = false}) async {
    if (forceEmit) _forceEmitOnNextScan = true;
    if (_isScanning) {
      await _currentScan;
      return;
    }
    _isScanning = true;
    _currentScan = _performScan();
    try {
      await _currentScan;
    } finally {
      _isScanning = false;
      _currentScan = null;
    }
  }

  Future<void> _performScan() async {
    final explicitScan = _forceEmitOnNextScan;
    if (explicitScan) _selfDisconnectedPaths.clear();

    final ports = (await SerialPort.availablePorts).toSet();
    _log.fine("Found ports: $ports");

    _nonDecentPorts.removeWhere((p) => !ports.contains(p));

    final tracked = <TrackedPortSnapshot>[];
    for (final path in _portPathToDevice.keys.toList()) {
      final device = _portPathToDevice[path]!;
      tracked.add(
        TrackedPortSnapshot(
          path: path,
          isHdsSerial: device is HDSSerial,
          present: ports.contains(path),
          state: await device.connectionState.first,
        ),
      );
    }

    final plan = planSerialReconcile(
      explicitScan: explicitScan,
      livenessTick: explicitScan ? _livenessTick : ++_livenessTick,
      livenessEveryN: _livenessEveryNReconciles,
      tracked: tracked,
      hdsPaths: _hdsPaths,
    );

    for (final path in plan.release) {
      await _dropAndDispose(path, reap: false);
    }
    for (final path in plan.reap) {
      _log.warning(
        "Reaping $path (reason="
        "${ports.contains(path) ? 'device disconnected' : 'port vanished'})"
        " — disposing",
      );
      await _dropAndDispose(path, reap: true);
    }
    _selfDisconnectedPaths.removeAll(plan.suppressRemove);
    _selfDisconnectedPaths.addAll(plan.suppressAdd);
    _hdsPaths.removeAll(plan.hdsForget);

    final trackedStableIds = _portPathToDevice.values
        .map((d) => d.deviceId)
        .toSet();
    final trackedIdentities = trackedSerialIdentities(
      trackedIds: trackedStableIds,
      trackedPaths: _portPathToDevice.keys,
    );

    final metadataByPath = <String, SerialPortMetadata>{};
    for (final path in ports) {
      final port = SerialPort(path);
      try {
        metadataByPath[path] = _readPortMetadata(path, port);
      } finally {
        port.dispose();
      }
    }

    final candidates = dedupeSerialCandidates(
      metadataByPath.values.where((metadata) {
        final path = metadata.path;
        if (_portPathToDevice.containsKey(path)) return false;
        if (_selfDisconnectedPaths.contains(path)) return false;
        if (_nonDecentPorts.contains(path)) return false;
        if (metadata.acceptedIds.any(trackedIdentities.contains)) return false;
        return serialPortMatchesCandidate(
          name: metadata.name,
          transport: metadata.transport,
          productName: metadata.productName,
        );
      }).toList(),
    );

    if (candidates.isNotEmpty) {
      _log.info(
        "Probing ${candidates.length} USB serial ports: "
        "${candidates.map((candidate) => candidate.path).toList()}",
      );
    }

    final detectedDevices = await Future.wait(
      candidates.map((candidate) async {
        try {
          return await _detectDevice(candidate);
        } catch (e, st) {
          _log.warning("Error detecting device on ${candidate.path}", e, st);
          return null;
        }
      }),
    );
    for (var i = 0; i < candidates.length; i++) {
      final device = detectedDevices[i];
      if (device != null) {
        _portPathToDevice[candidates[i].path] = device;
      }
    }

    if (plan.livenessPass) {
      _selfDisconnectedPaths.addAll(
        hdsResuppressionPaths(
          hdsPaths: _hdsPaths,
          presentPorts: ports,
          trackedPaths: _portPathToDevice.keys.toSet(),
        ),
      );
    }

    _devices = _portPathToDevice.values.toList();
    final ids = _devices.map((d) => d.deviceId).toSet();
    if (_forceEmitOnNextScan || serialDevicesChanged(ids, _lastEmittedIds)) {
      _forceEmitOnNextScan = false;
      _lastEmittedIds = ids;
      _machineSubject.add(_devices);
      _log.info("Devices: $_devices");
    }
  }

  Future<void> _handleQuickConnectedDisconnect(
    String path,
    StreamSubscription<ConnectionState> sub,
  ) async {
    try {
      await sub.cancel();
      await _dropAndDispose(path, reap: false);

      _devices = _portPathToDevice.values.toList();
      _lastEmittedIds = _devices.map((d) => d.deviceId).toSet();
      if (!_machineSubject.isClosed) {
        _machineSubject.add(List.unmodifiable(_devices));
      }
    } catch (e, st) {
      _log.warning('Quick-connect disconnect cleanup failed for $path', e, st);
    }
  }

  Future<void> _dropAndDispose(String path, {required bool reap}) async {
    _portPathToDevice.remove(path);
    _portPathToDeviceId.remove(path);
    final transport = _portPathToTransport.remove(path);
    if (transport == null) return;
    try {
      await transport.dispose();
    } catch (e, st) {
      if (reap) {
        _log.warning("dispose failed for $path", e, st);
      } else {
        _log.fine("liveness release: dispose failed for $path", e, st);
      }
    }
  }

  SerialPortMetadata _readPortMetadata(String path, SerialPort port) {
    String name = path;
    String transport = 'Unknown';
    String? productName;
    int? vid;
    int? pid;
    String? serial;
    int? interfaceNumber;
    try {
      name = port.name ?? path;
    } catch (_) {}
    try {
      transport = port.transport.toTransport();
    } catch (_) {}
    try {
      productName = port.productName;
    } catch (_) {}
    try {
      vid = port.vendorId;
    } catch (_) {}
    try {
      pid = port.productId;
    } catch (_) {}
    try {
      serial = port.serialNumber;
    } catch (_) {}
    try {
      interfaceNumber = port.interfaceNumber;
    } catch (_) {}
    return SerialPortMetadata(
      path: path,
      name: name,
      transport: transport,
      productName: productName,
      vid: vid,
      pid: pid,
      serial: serial,
      interfaceNumber: interfaceNumber,
    );
  }

  _DesktopSerialPort _registerTransport(
    SerialPort port,
    SerialPortMetadata candidate, {
    bool dtrOn = false,
    bool decodeUtf8Text = true,
  }) {
    try {
      final transport = _DesktopSerialPort(
        port: port,
        canonicalId: candidate.canonicalId,
        dtrOn: dtrOn,
        decodeUtf8Text: decodeUtf8Text,
      );
      _portPathToTransport[candidate.path] = transport;
      return transport;
    } catch (_) {
      try {
        port.dispose();
      } catch (_) {}
      rethrow;
    }
  }

  Future<Device?> _detectDevice(SerialPortMetadata candidate) async {
    final id = candidate.path;
    _log.info(
      "detecting: ${candidate.name} ; ${candidate.productName} ; ${candidate.transport}",
    );
    if (candidate.transport == "Bluetooth") return null;
    final port = SerialPort(candidate.path);

    final vid = candidate.vid;
    final pid = candidate.pid;
    final interfaceNumber = candidate.interfaceNumber;
    final productName = candidate.productName;
    if (isBengleEbusTap(
      vid: vid,
      pid: pid,
      interfaceNumber: interfaceNumber,
      productName: productName,
    )) {
      _log.info(
        "Bengle EBus tap on interface $interfaceNumber ($id)"
        " — no protocol probe",
      );
      final transport = _registerTransport(
        port,
        candidate,
        dtrOn: true,
        decodeUtf8Text: false,
      );
      final device = BengleDebugPort(transport: transport);
      _portPathToDeviceId[candidate.path] = device.deviceId;
      return device;
    }

    final transport = _registerTransport(port, candidate);
    if (productName == "DE1") {
      final device = UnifiedDe1(transport: transport);
      _portPathToDeviceId[candidate.path] = device.deviceId;
      return device;
    }

    if (productName == "Bengle") {
      final device = Bengle(transport: transport);
      _portPathToDeviceId[candidate.path] = device.deviceId;
      return device;
    }

    if (productName == "Half Decent Scale") {
      final device = HDSSerial(transport: transport);
      _portPathToDeviceId[candidate.path] = device.deviceId;
      _hdsPaths.add(candidate.path);
      return device;
    }

    final usbModel = matchUsbDevice(usbDeviceTable, vid: vid, pid: pid);
    if (usbModel != null) {
      final device = UnifiedDe1(transport: transport);
      _portPathToDeviceId[candidate.path] = device.deviceId;
      return device;
    }

    final rawData = <Uint8List>[];
    const readDuration = Duration(milliseconds: 1800);
    _log.fine("Inspecting: ${candidate.name}, ${candidate.productName}");

    try {
      await transport.connect().timeout(Duration(milliseconds: 300));

      final subscription = transport.rawStream.listen(rawData.add);

      await subscription.asFuture<void>().timeout(
        readDuration,
        onTimeout: () async {
          await subscription.cancel();
        },
      );

      final combined = rawData.expand((e) => e).toList();
      List<String> strings = [];
      try {
        strings = rawData
            .map((e) => utf8.decode(e, allowMalformed: true))
            .toList()
            .join()
            .split('\n');
      } catch (e) {
        _log.warning("failed to decode:", e);
      }
      _log.info(
        "Collected serial data: ${combined.map((e) => e.toRadixString(16).padLeft(2, '0'))}",
      );
      _log.info("parsed into strings: $strings");
      if (combined.isEmpty && strings.isEmpty) {
        throw ('no data collected');
      }
      if (strings.any((s) => s.startsWith('R '))) {
        final device = DebugPort(transport: transport);
        _portPathToDeviceId[candidate.path] = device.deviceId;
        return device;
      } else if (isDecentScale(strings, rawData)) {
        _log.info(
          "Detected: Decent Scale — releasing port until user connects",
        );
        final device = HDSSerial(transport: transport);
        _portPathToDeviceId[candidate.path] = device.deviceId;
        _hdsPaths.add(candidate.path);
        await transport.disconnect();
        return device;
      } else if (isSensorBasket(strings)) {
        _log.info("Detected: Sensor Basket");
        final device = SensorBasket(transport: transport);
        _portPathToDeviceId[candidate.path] = device.deviceId;
        return device;
      } else {
        final messages = <String>[];
        final stateSubscription = transport.readStream.listen(messages.add);

        await transport.writeCommand('<+M>');
        await transport.writeCommand('<+E>');

        final req = buildMmrReadRequest(address: 0x0080000C, length: 0);
        final reqHex = req
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        try {
          await transport.writeCommand('<E>$reqHex');
        } catch (e) {
          _log.fine('MMR read request failed during probe', e);
        }

        try {
          await stateSubscription.asFuture<void>().timeout(
            readDuration,
            onTimeout: () async {
              await stateSubscription.cancel();
            },
          );
        } finally {
          await transport.writeCommand('<-M>');
          await transport.writeCommand('<-E>');
        }

        if (isDE1(messages.join().split('\n'), combined)) {
          int? v13Model;
          for (final line in messages.join().split('\n')) {
            final v = decodeMmrInt32Response(
              line.trim(),
              expectedAddr: (0x80, 0x00, 0x0C),
            );
            if (v != null) {
              v13Model = v;
              break;
            }
          }

          final isBengle = v13Model != null && isBengleModelValue(v13Model);
          _log.info(
            "Detected: ${isBengle ? 'Bengle' : 'DE1'} (v13Model=$v13Model)",
          );
          final device = isBengle
              ? Bengle(transport: transport)
              : UnifiedDe1(transport: transport);
          _portPathToDeviceId[candidate.path] = device.deviceId;
          return device;
        }
      }

      _log.warning("Unknown device on port $id");
      _nonDecentPorts.add(candidate.path);
      _portPathToTransport.remove(candidate.path);
      await transport.dispose();
      return null;
    } catch (e, st) {
      _log.warning("Port $id is probably not a device we want", e, st);
      _nonDecentPorts.add(candidate.path);
      _portPathToTransport.remove(candidate.path);
      await transport.dispose();
      return null;
    }
  }
}

@visibleForTesting
SerialTransport createDesktopSerialPortForTest(SerialPort port) =>
    _DesktopSerialPort(port: port, canonicalId: 'test-serial');

class _DesktopSerialPort implements SerialTransport {
  final SerialPort _port;
  final bool _dtrOn;
  final bool _decodeUtf8Text;
  late Logger _log;
  final BehaviorSubject<ConnectionState> _open = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );

  @override
  Stream<ConnectionState> get connectionState => _open.asBroadcastStream();

  final String _id;
  late final String _cachedName = _safePortName() ?? "Unknown port";

  _DesktopSerialPort({
    required this._port,
    required String canonicalId,
    this._dtrOn = false,
    this._decodeUtf8Text = true,
  }) : _id = canonicalId {
    _log = Logger("SerialPort:${_safePortName() ?? 'unknown'}");
    _cachedName;
  }

  String? _safePortName() {
    try {
      return _port.name;
    } catch (_) {
      return null;
    }
  }

  bool _disposed = false;
  int _disconnectRequests = 0;
  Future<void> _lifecycle = Future<void>.value();
  Future<void>? _disposeFuture;
  SerialPortReader? _reader;
  SerialWriter? _writer;

  Future<void> _serialize(Future<void> Function() operation) async {
    final previous = _lifecycle;
    final done = Completer<void>();
    _lifecycle = done.future;
    await previous;
    try {
      await operation();
    } finally {
      done.complete();
    }
  }

  @override
  Future<void> disconnect() {
    if (_disposed) return _disposeFuture ?? Future<void>.value();
    _disconnectRequests++;
    return _serialize(() async {
      try {
        await _disconnect();
      } finally {
        _disconnectRequests--;
      }
    });
  }

  Future<void> _disconnect() async {
    final reader = _reader;
    final writer = _writer;
    final subscription = _portSubscription;
    _reader = null;
    _writer = null;
    _portSubscription = null;
    await Future.wait([
      if (reader != null) reader.close(),
      if (writer != null) writer.close(),
      if (subscription != null) subscription.cancel(),
    ]);
    final address = _port.address;
    await Isolate.run(() => _closePort(address));
    if (!_open.isClosed) _open.add(ConnectionState.disconnected);
  }

  static Future<void> _closePort(int address) async {
    final port = SerialPort.fromAddress(address);
    port.flush(SerialPortBuffer.output);
    await port.close();
  }

  @override
  Future<void> dispose() {
    _disposed = true;
    return _disposeFuture ??= _serialize(() async {
      await _disconnect();
      _port.dispose();
      await _rawStreamController.close();
      await _readController.close();
      await _open.close();
    });
  }

  @override
  String get id => _id;

  @override
  String get name => _cachedName;

  @override
  TransportType get transportType => TransportType.serial;

  StreamSubscription<Uint8List>? _portSubscription;

  final StreamController<Uint8List> _rawStreamController =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get rawStream => _rawStreamController.stream;

  @override
  Future<void> connect() {
    if (_disposed) {
      return Future.error(StateError('Serial transport is disposed'));
    }
    return _serialize(() async {
      try {
        await _connect();
      } catch (_) {
        await _disconnect();
        rethrow;
      }
    });
  }

  Future<void> _connect() async {
    if (_disposed) {
      throw StateError("serial transport disposed (id=$id) — cannot connect");
    }
    final instanceTag = "instance=${identityHashCode(this).toRadixString(16)}";
    String? description;
    String? manufacturer;
    try {
      description = _port.description;
    } catch (_) {}
    try {
      manufacturer = _port.manufacturer;
    } catch (_) {}
    _log.info(
      "connect() name=${_port.name} id=$id $instanceTag "
      "description=$description manufacturer=$manufacturer isOpen=${_port.isOpen}",
    );

    if (_port.isOpen) {
      _log.warning(
        "already open (id=$id $instanceTag) — bailing out of connect()",
      );
      return;
    }
    await Future.microtask(() async {
      if (_disposed) {
        throw StateError("serial transport disposed (id=$id) during open");
      }
      if (await _port.open(mode: 3) == false) {
        _log.warning("could not open port");
        throw "failed to open port: ${SerialPort.lastError}";
      }
      final SerialPortConfig cfg = SerialPortConfig();
      cfg.baudRate = 115200;
      cfg.bits = 8;
      cfg.parity = 0;
      cfg.stopBits = 1;
      cfg.rts = 0;
      cfg.cts = 0;
      cfg.dtr = _dtrOn ? 1 : 0;
      cfg.dsr = 0;
      cfg.xonXoff = 0;
      cfg.setFlowControl(0);
      await _port.setConfig(cfg);
      _log.finest("current config: ${_port.config.bits}");
      _log.finest("current config: ${_port.config.parity}");
      _log.finest("current config: ${_port.config.stopBits}");
      _log.finest("current config: ${_port.config.baudRate}");

      _log.fine("port opened");
      if (_disposed || _disconnectRequests > 0) {
        throw StateError('Serial connection cancelled');
      }
      final reader = SerialPortReader(_port);
      _reader = reader;
      _writer = SerialWriter(_port);
      final readerTag = "reader=${identityHashCode(reader).toRadixString(16)}";
      _log.info("subscribing reader (id=$id $instanceTag $readerTag)");
      _portSubscription = reader.stream.listen(
        (data) {
          if (!identical(_reader, reader) ||
              _disposed ||
              _disconnectRequests > 0) {
            return;
          }
          _rawStreamController.add(data);
          if (!_decodeUtf8Text) return;
          try {
            final input = utf8.decode(data);
            _log.finest("received serial input: $input");
            _readController.add(input);
          } catch (e) {
            _log.finest("unable to parse serial input to string", e);
          }
        },
        onError: (error) {
          if (!identical(_reader, reader) ||
              _disposed ||
              _disconnectRequests > 0) {
            return;
          }
          _log.severe("port error (id=$id $instanceTag $readerTag): $error");
          _readController.addError(error);
          disconnect();
        },
        onDone: () {
          if (!identical(_reader, reader) ||
              _disposed ||
              _disconnectRequests > 0) {
            return;
          }
          _log.warning(
            "serial stream closed (onDone) — cable unplug or reader isolate "
            "death. id=$id $instanceTag $readerTag",
          );
          disconnect();
        },
      );
      _log.fine("port subscribed: $_portSubscription ($readerTag)");
    });
    _open.add(ConnectionState.connected);
  }

  final StreamController<String> _readController =
      StreamController<String>.broadcast();
  @override
  Stream<String> get readStream => _readController.stream;

  @override
  Future<void> writeCommand(String command) async {
    await _write(utf8.encode("$command\n"));
    _log.fine("wrote: $command");
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {
    await _write(command);
  }

  Future<void> _write(Uint8List command) async {
    final writer = _writer;
    if (_disposed || _disconnectRequests > 0 || writer == null) {
      throw StateError(
        "serial transport is not connected (id=$id) — cannot write",
      );
    }
    try {
      await writer.write(command);
      _log.fine("wrote: ${command.map((e) => e.toRadixString(16))}");
    } catch (e) {
      _log.warning("Serial write error, disconnecting", e);
      if (identical(_writer, writer)) await disconnect();
      rethrow;
    }
  }
}

extension IntToString on int {
  String toHex() => '0x${toRadixString(16)}';
  String toPadded([int width = 3]) => toString().padLeft(width, '0');
  String toTransport() {
    switch (this) {
      case SerialPortTransport.usb:
        return 'USB';
      case SerialPortTransport.bluetooth:
        return 'Bluetooth';
      case SerialPortTransport.native:
        return 'Native';
      default:
        return 'Unknown';
    }
  }
}
