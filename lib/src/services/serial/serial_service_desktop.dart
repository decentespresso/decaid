import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/impl/decent_scale/scale_serial.dart';
import 'package:reaprime/src/models/device/impl/sensor/debug_port.dart';
import 'package:reaprime/src/models/device/impl/sensor/sensor_basket.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/models/device/remembered_device.dart';
import 'mmr_codec.dart';
import 'serial_reconcile.dart';
import 'usb_ids.dart';
import 'utils.dart';

import 'package:rxdart/subjects.dart';

// libserialport is supplied via dependency_overrides (git fork).
// ignore: depend_on_referenced_packages
import 'package:libserialport/libserialport.dart';

class SerialServiceDesktop implements DeviceDiscoveryService {
  final _log = Logger("Serial service");

  List<Device> _devices = [];

  final Map<String, String> _portPathToDeviceId = {};

  final Map<String, _DesktopSerialPort> _portPathToTransport = {};

  // Path -> the Device bound to that path. Liveness is checked through this
  // (the device's own connectionState), NOT through deviceId. On macOS the
  // CH34x serial chip reports null vid/pid/serial via libserialport, so a
  // serial device's id falls back to `_DesktopSerialPort`'s port-address
  // handle, which changes on every `SerialPort()` construction. Keying
  // liveness by deviceId therefore churned — a present device failed the id
  // check, got reaped, and was re-probed; each re-probe re-opened the port,
  // which (for the Half Decent Scale, with limited client slots) contended
  // with a WiFi connection to the same physical scale. Holding the Device by
  // stable port path is immune to that.
  final Map<String, Device> _portPathToDevice = {};

  Set<String> _lastEmittedIds = {};

  // Paths whose bound device SELF-disconnected (watchdog/serial error/explicit
  // disconnect) while the OS port was still present. The timer reconcile must
  // NOT auto-re-probe these: a Half Decent Scale that's currently serving
  // another transport (BLE/WiFi) streams no data over USB, so its watchdog
  // disconnects ~12s in; immediately re-probing reconnects it, it disconnects
  // again, and so on — a reap→re-probe→reconnect churn loop. An explicit user
  // scan clears this set and retries (intentional, user-initiated recovery); a
  // physical unplug (port vanished) also clears the path so a replug re-detects
  // fresh.
  final Set<String> _selfDisconnectedPaths = {};

  // Paths that were ever detected as a Half Decent Scale. The HDS streams
  // weight to every connected transport (BLE/USB/WiFi) at once, but its server
  // has only a few client slots — so the contention comes from holding the USB
  // port open *persistently* as an extra client (see `_portPathToDevice` and
  // the HDS branch in `_detectDevice`), NOT from reading data. A *discovered*
  // (not-connected) HDS therefore releases its port and would otherwise linger
  // as "available" forever even after the physical scale is switched off, since
  // nothing re-reads it. Every Nth reconcile we re-verify these by re-probing
  // the port: still streaming → keep; silent → reap (scale off). A quick
  // open-read-close is safe precisely because the scale serves all transports
  // simultaneously — the transient probe sees live data without displacing a
  // live WiFi/BLE client.
  final Set<String> _hdsPaths = {};

  // Ports we probed and confirmed are NOT a Decent device (LG Monitor
  // Controls, Valve VR Radio, etc.). Skipped on subsequent timer reconciles
  // so we don't spam them with DE1-protocol probes every ~8s. Cleared when
  // the OS port vanishes, so a replaced device (different physical hardware
  // on the same path, e.g. Linux /dev/ttyUSB0) gets re-probed.
  final Set<String> _nonDecentPorts = {};
  int _livenessTick = 0;
  static const int _livenessEveryNReconciles = 3;

  // Force the next reconcile to emit even if the device set is unchanged.
  // Set by an explicit `scanForDevices()`: DeviceController clears `discovered`
  // devices from its own map at scan start and relies on each service
  // RE-EMITTING its current devices during the scan to repopulate. Without
  // this, a discovered (but unchanged) serial device gets cleared by
  // DeviceController and never handed back — it vanishes from the device list
  // while still tracked here. The timer-driven reconcile does not set this, so
  // steady-state ticks stay silent.
  bool _forceEmitOnNextScan = false;

  bool _isScanning = false;
  Future<void>? _currentScan;

  final Duration _reconcileInterval;
  Timer? _reconcileTimer;

  SerialServiceDesktop({
    Duration reconcileInterval = const Duration(seconds: 8),
  }) : _reconcileInterval = reconcileInterval;

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

  /// Stop the reconcile timer and release tracked transports. Safe to call
  /// more than once.
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
    for (final portPath in ports) {
      final port = SerialPort(portPath);
      try {
        final meta = _readPortMetadata(portPath, port);
        final stableId = meta.stableId ?? 'serial-${portPath.split("/").last}';
        if (stableId != remembered.id) continue;
      } finally {
        port.dispose();
      }

      _log.info('Quick-connect: found port $portPath for ${remembered.id}');
      Device? device;
      try {
        device = await _detectDevice(portPath);
      } catch (e, st) {
        _log.warning(
          'Quick-connect: _detectDevice failed for $portPath',
          e,
          st,
        );
        continue;
      }
      if (device == null || device.implementation != impl) {
        _log.info(
          'Quick-connect: device mismatch on $portPath'
          ' (expected $impl, got ${device?.implementation})',
        );
        try {
          await device?.disconnect();
        } catch (_) {}
        final t = _portPathToTransport.remove(portPath);
        try {
          await t?.dispose();
        } catch (_) {}
        continue;
      }
      try {
        await device.onConnect().timeout(const Duration(seconds: 10));
        _portPathToDevice[portPath] = device;
        _portPathToDeviceId[portPath] = device.deviceId;
        late final StreamSubscription<ConnectionState> stateSub;
        stateSub = device.connectionState.listen((state) {
          if (state == ConnectionState.disconnected) {
            unawaited(_handleQuickConnectedDisconnect(portPath, stateSub));
          }
        });
        _devices = _portPathToDevice.values.toList();
        _lastEmittedIds = _devices.map((d) => d.deviceId).toSet();
        _machineSubject.add(_devices);
        _log.info('Quick-connect succeeded for ${remembered.id}');
        return device;
      } catch (e, st) {
        _log.warning('Quick-connect: onConnect failed for $portPath', e, st);
        try {
          await device.disconnect();
        } catch (_) {}
        final t = _portPathToTransport.remove(portPath);
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

  /// Run a reconcile, coalescing with any in-flight one. Called both by an
  /// explicit `scanForDevices()` ([forceEmit] true — always re-emit, honoring
  /// DeviceController's clear-and-repopulate contract) and by the periodic
  /// reconcile timer ([forceEmit] false — emit only on change). Both do the
  /// same path-keyed reconcile (reap vanished/disconnected, probe untracked
  /// candidates).
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

    // Decide the pre-probe transition (liveness releases, reaps, suppression).
    // The `++_livenessTick` only advances on a timer reconcile (an explicit
    // scan is always a liveness pass and must not shift the timer's phase).
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

    final scanPorts = ports.where((p) {
      // Already tracked → never re-probe. THIS is what stops the contention:
      // an identified device (e.g. the HDS, which releases its port after
      // discovery) is never re-opened, so it can't fight a WiFi connection to
      // the same physical scale. Untracked candidate ports are still probed
      // every reconcile, so a transient open failure self-heals on the next
      // tick and a newly-plugged device is picked up.
      if (_portPathToDevice.containsKey(p)) return false;
      if (_selfDisconnectedPaths.contains(p)) return false;
      if (_nonDecentPorts.contains(p)) return false;
      final port = SerialPort(p);
      final meta = _readPortMetadata(p, port);
      port.dispose();
      if (meta.stableId != null && trackedStableIds.contains(meta.stableId)) {
        return false;
      }
      return serialPortMatchesCandidate(
        name: meta.name,
        transport: meta.transport,
        productName: meta.productName,
      );
    }).toList();

    if (scanPorts.isNotEmpty) {
      _log.info("Probing ${scanPorts.length} USB serial ports: $scanPorts");
    }

    await Future.wait(
      scanPorts.map((portId) async {
        try {
          final device = await _detectDevice(portId);
          if (device != null) {
            _portPathToDevice[portId] = device;
          }
        } catch (e, st) {
          _log.warning("Error detecting device on $portId", e, st);
        }
      }),
    );

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

  /// Drop a tracked path from all maps and dispose its transport. [reap]
  /// distinguishes the log level for a stale-port reap (warning) from a
  /// liveness re-verify release (fine) — both are non-actionable on failure.
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

  _PortMetadata _readPortMetadata(String path, SerialPort port) {
    // libserialport reads USB descriptors from sysfs on Linux; some drivers
    // (or missing udev rules / permissions) cause getters to throw
    // `SerialPortError: No such file or directory, errno = 2`. Any throw here
    // must not abort the whole scan — fall back to name-based matching.
    String name = path;
    String transport = 'Unknown';
    String? productName;
    int? vid;
    int? pid;
    String? serial;
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
    final stableId = computeUsbStableId(vid: vid, pid: pid, serial: serial);
    return _PortMetadata(
      name: name,
      transport: transport,
      productName: productName,
      stableId: stableId,
    );
  }

  Future<Device?> _detectDevice(String id) async {
    final port = SerialPort(id);
    _log.info(
      "detecting: ${port.name} ; ${port.productName} ; ${port.transport.toTransport()}",
    );
    if (port.transport.toTransport() == "Bluetooth") {
      port.dispose();
      return null;
    }

    final transport = _DesktopSerialPort(port: port);
    _portPathToTransport[id] = transport;
    if (port.productName == "DE1") {
      final device = UnifiedDe1(transport: transport);
      _portPathToDeviceId[id] = device.deviceId;
      return device;
    }

    if (port.productName == "Bengle") {
      final device = Bengle(transport: transport);
      _portPathToDeviceId[id] = device.deviceId;
      return device;
    }

    if (port.productName == "Half Decent Scale") {
      final device = HDSSerial(transport: transport);
      _portPathToDeviceId[id] = device.deviceId;
      _hdsPaths.add(id);
      return device;
    }

    int? vid;
    int? pid;
    try {
      vid = port.vendorId;
    } catch (_) {}
    try {
      pid = port.productId;
    } catch (_) {}
    final usbModel = matchUsbDevice(usbDeviceTable, vid: vid, pid: pid);
    if (usbModel != null) {
      final device = UnifiedDe1(transport: transport);
      _portPathToDeviceId[id] = device.deviceId;
      return device;
    }

    final rawData = <Uint8List>[];
    const readDuration = Duration(milliseconds: 1800);
    _log.fine("Inspecting: ${port.name}, ${port.productName}");

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
        _portPathToDeviceId[id] = device.deviceId;
        return device;
      } else if (isDecentScale(strings, rawData)) {
        _log.info(
          "Detected: Decent Scale — releasing port until user connects",
        );
        final device = HDSSerial(transport: transport);
        _portPathToDeviceId[id] = device.deviceId;
        _hdsPaths.add(id);
        await transport.disconnect();
        return device;
      } else if (isSensorBasket(strings)) {
        _log.info("Detected: Sensor Basket");
        final device = SensorBasket(transport: transport);
        _portPathToDeviceId[id] = device.deviceId;
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
          _portPathToDeviceId[id] = device.deviceId;
          return device;
        }
      }

      _log.warning("Unknown device on port $id");
      _nonDecentPorts.add(id);
      _portPathToTransport.remove(id);
      await transport.dispose();
      return null;
    } catch (e, st) {
      _log.warning("Port $id is probably not a device we want", e, st);
      _nonDecentPorts.add(id);
      _portPathToTransport.remove(id);
      await transport.dispose();
      return null;
    }
  }
}

const int _serialWriteTimeoutMs = 500;

class _DesktopSerialPort implements SerialTransport {
  final SerialPort _port;
  late Logger _log;
  final BehaviorSubject<ConnectionState> _open = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );

  @override
  Stream<ConnectionState> get connectionState => _open.asBroadcastStream();

  // Identity is cached ONCE at construction. The libserialport getters
  // (vendorId/productId/serialNumber/name) read the native `sp_port` struct
  // over FFI; once `dispose()` calls `_port.dispose()` (sp_free_port), any
  // later read is a use-after-free on freed C memory — observed as an
  // EXC_BAD_ACCESS / pointer-authentication SIGSEGV surfacing in a Dart
  // microtask (e.g. the scan reconcile reading `device.deviceId` AFTER it
  // disposed the transport for a vanished/unplugged port). Port path and USB
  // descriptors are static per physical device, so caching is correct and the
  // getters never touch the port again after this point.
  late final String _cachedId = _computeId();
  late final String _cachedName = _safePortName() ?? "Unknown port";

  _DesktopSerialPort({required SerialPort port}) : _port = port {
    _log = Logger("SerialPort:${port.name}");
    _cachedId;
    _cachedName;
  }

  String? _safePortName() {
    try {
      return _port.name;
    } catch (_) {
      return null;
    }
  }

  String _computeId() {
    int? vid;
    int? pid;
    String? serial;
    try {
      vid = _port.vendorId;
    } catch (_) {}
    try {
      pid = _port.productId;
    } catch (_) {}
    try {
      serial = _port.serialNumber;
    } catch (_) {}
    final stable = computeUsbStableId(vid: vid, pid: pid, serial: serial);
    if (stable != null) return stable;
    final portName = _safePortName();
    if (portName != null) {
      final basename = portName.split('/').last;
      return 'serial-$basename';
    }
    return 'serial-${_port.address}';
  }

  bool _disposed = false;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _portSubscription?.cancel();
    _port.close();
    if (!_open.isClosed) _open.add(ConnectionState.disconnected);
  }

  /// End-of-life cleanup. Calls `disconnect()` to stop the reader isolate +
  /// close the tty, then frees the libserialport `sp_port` FFI handle and
  /// closes the exposed stream controllers. Safe to call more than once.
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    // Mark disposed BEFORE freeing native so a racing connect()/disconnect()/
    // write() bails instead of touching freed memory. Inline the close here
    // (disconnect() now no-ops once disposed).
    _disposed = true;
    try {
      _portSubscription?.cancel();
      _port.close();
      if (!_open.isClosed) _open.add(ConnectionState.disconnected);
    } catch (e) {
      _log.warning("dispose: close failed", e);
    }
    try {
      _port.dispose();
    } catch (e) {
      _log.warning("dispose: _port.dispose failed", e);
    }
    if (!_rawStreamController.isClosed) {
      await _rawStreamController.close();
    }
    if (!_readController.isClosed) {
      await _readController.close();
    }
    if (!_open.isClosed) {
      await _open.close();
    }
  }

  @override
  String get id => _cachedId;

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
  Future<void> connect() async {
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
      cfg.dtr = 0;
      cfg.dsr = 0;
      cfg.xonXoff = 0;
      cfg.setFlowControl(0);
      await _port.setConfig(cfg);
      _log.finest("current config: ${_port.config.bits}");
      _log.finest("current config: ${_port.config.parity}");
      _log.finest("current config: ${_port.config.stopBits}");
      _log.finest("current config: ${_port.config.baudRate}");

      _log.fine("port opened");
      final reader = SerialPortReader(_port);
      final readerTag = "reader=${identityHashCode(reader).toRadixString(16)}";
      _log.info("subscribing reader (id=$id $instanceTag $readerTag)");
      _portSubscription = reader.stream.listen(
        (data) {
          _rawStreamController.add(data);
          try {
            final input = utf8.decode(data);
            _log.finest("received serial input: $input");
            _readController.add(input);
          } catch (e) {
            _log.finest("unable to parse serial input to string", e);
          }
        },
        onError: (error) {
          _log.severe("port error (id=$id $instanceTag $readerTag): $error");
          _readController.addError(error);
          disconnect();
        },
        onDone: () {
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
    if (_disposed) {
      throw StateError("serial transport disposed (id=$id) — cannot write");
    }
    try {
      // Write all bytes, handling short writes by looping.
      // Finite timeout (not 0 = block-forever): scan probes non-Decent
      // USB-serial devices, and a device that never accepts the bytes must
      // not be able to wedge the isolate. A zero-progress write means the
      // device isn't draining — stop instead of spinning.
      int offset = 0;
      while (offset < command.length) {
        final chunk = offset == 0
            ? command
            : Uint8List.sublistView(command, offset);
        final written = await _port.write(
          chunk,
          timeout: _serialWriteTimeoutMs,
        );
        if (written < 0) {
          throw StateError('Serial write failed: ${SerialPort.lastError}');
        }
        if (written == 0) {
          throw StateError(
            'Serial write stalled (0 bytes in ${_serialWriteTimeoutMs}ms)',
          );
        }
        offset += written;
      }
      // Bounded stand-in for the native `_port.drain()`, which blocks the
      // isolate forever on a device that never transmits the buffer.
      await drainWithTimeout(bytesToWrite: () => _port.bytesToWrite);
      _log.fine("wrote: ${command.map((e) => e.toRadixString(16))}");
      if (Platform.isLinux || Platform.isMacOS) {
        await Future.delayed(Duration(milliseconds: 20), () {
          _log.finest("delaying next write");
        });
      }
    } catch (e) {
      _log.warning("Serial write error, disconnecting", e);
      await disconnect();
      rethrow;
    }
  }
}

class _PortMetadata {
  final String name;
  final String transport;
  final String? productName;
  final String? stableId;
  _PortMetadata({
    required this.name,
    required this.transport,
    required this.productName,
    required this.stableId,
  });
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
