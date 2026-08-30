import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
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
import 'package:reaprime/src/models/device/usb_attach_probe.dart';
import 'mmr_codec.dart';
import 'usb_ids.dart';
import 'utils.dart';
import 'package:rxdart/subjects.dart';

// ignore: depend_on_referenced_packages
import 'package:usb_serial/usb_serial.dart';

class SerialServiceAndroid
    implements DeviceDiscoveryService, DeviceAttachNotifier, UsbAttachProbe {
  final _log = Logger("Android Serial service");
  final Future<List<UsbDevice>> Function() _listDevices;
  final Stream<UsbEvent>? Function() _usbEventStream;
  final Future<Device?> Function(UsbDevice device)? _detectOverride;

  final List<Device> _devices = [];
  StreamSubscription<UsbEvent>? _usbEventSubscription;
  bool _disposed = false;

  SerialServiceAndroid({
    Future<List<UsbDevice>> Function()? listDevices,
    Stream<UsbEvent>? Function()? usbEventStream,
    Future<Device?> Function(UsbDevice device)? detectDevice,
  }) : _listDevices = listDevices ?? UsbSerial.listDevices,
       _usbEventStream = usbEventStream ?? (() => UsbSerial.usbEventStream),
       _detectOverride = detectDevice;

  final Map<String, AndroidSerialPort> _transportForDeviceId = {};

  bool _isScanning = false;
  Future<void>? _currentScan;

  final BehaviorSubject<List<Device>> _machineSubject = BehaviorSubject.seeded(
    <Device>[],
  );
  @override
  Stream<List<Device>> get devices => _machineSubject.stream;

  final PublishSubject<DeviceAttachedEvent> _attachedSubject =
      PublishSubject<DeviceAttachedEvent>();

  @override
  Stream<DeviceAttachedEvent> get deviceAttached => _attachedSubject.stream;

  @override
  Future<void> initialize() async {
    try {
      _usbEventSubscription = _usbEventStream()?.listen(handleUsbEvent);
    } catch (e, st) {
      _log.warning('USB event stream unavailable', e, st);
    }
    if (_disposed) return;
    try {
      final devices = await _listDevices();
      _log.info("found $devices");
      if (devices.isNotEmpty && !_disposed) {
        _announceAttach(null);
      }
    } catch (e, st) {
      _log.warning('USB enumeration unavailable during initialization', e, st);
    }
  }

  @visibleForTesting
  void handleUsbEvent(UsbEvent data) {
    if (_disposed) return;
    switch (data.event) {
      case UsbEvent.ACTION_USB_DETACHED:
        _log.info(
          "USB_DETACHED: device=${data.device?.productName ?? 'null'} "
          "raw=${data.device?.deviceId}",
        );
        if (data.device != null) {
          final vid = data.device!.vid;
          final pid = data.device!.pid;
          final detachedStableId = computeUsbStableId(
            vid: vid,
            pid: pid,
            serial: data.device!.serial,
          );
          final vidPidPrefix = (vid != null && pid != null)
              ? 'usb-${vid.toRadixString(16)}-${pid.toRadixString(16)}-'
              : null;
          _log.info(
            "USB_DETACHED: stableId=${detachedStableId ?? 'none'}, "
            "prefix=$vidPidPrefix",
          );
          final match = _devices.firstWhereOrNull(
            (d) =>
                d.deviceId == detachedStableId ||
                (vidPidPrefix != null && d.deviceId.startsWith(vidPidPrefix)) ||
                d.deviceId == "${data.device!.deviceId}",
          );
          if (match != null) {
            _log.info(
              "USB_DETACHED: disconnecting ${match.name}(${match.deviceId})",
            );
            match.disconnect();
            _devices.remove(match);
          } else {
            _log.warning("USB_DETACHED: no matching device in $_devices");
          }
        } else {
          _log.warning(
            "USB_DETACHED: device is null, disconnecting "
            "${_devices.length} serial device(s)",
          );
          for (final d in _devices) {
            d.disconnect();
          }
          _devices.clear();
        }
        _machineSubject.add(_devices);
        break;
      case UsbEvent.ACTION_USB_ATTACHED:
        _announceAttach(data.device);
        break;
      default:
        _log.info(
          "USB event: ${data.event}, device=${data.device?.productName ?? 'null'}",
        );
        break;
    }
  }

  void _announceAttach(UsbDevice? device) {
    final stableId = device == null
        ? null
        : computeUsbStableId(
            vid: device.vid,
            pid: device.pid,
            serial: device.serial,
          );
    _log.info(
      "USB_ATTACHED: device=${device?.productName ?? 'null'} "
      "id=${stableId ?? device?.deviceId}",
    );
    if (!_attachedSubject.isClosed) {
      _attachedSubject.add(
        DeviceAttachedEvent(deviceId: stableId, name: device?.productName),
      );
    }
  }

  @override
  Future<AttachProbeResult> connectAttachedMachine(
    DeviceAttachedEvent event,
  ) async {
    if (_disposed) return const AttachProbeUnsupported();
    final devices = await _listDevices();
    final candidates = _attachedCandidates(event, devices);
    if (candidates.isEmpty) {
      _log.fine('Attach probe: no USB device correlates with $event');
      return const AttachProbeUnsupported();
    }
    AttachProbeFailed? failure;
    for (final device in candidates) {
      final result = await _connectAttachedMachine(device);
      if (result is AttachProbeConnected) return result;
      if (result is AttachProbeFailed) failure = result;
    }
    return failure ?? const AttachProbeUnsupported();
  }

  List<UsbDevice> _attachedCandidates(
    DeviceAttachedEvent event,
    List<UsbDevice> devices,
  ) {
    final id = event.deviceId;
    if (id != null && id.isNotEmpty) {
      return devices.where((d) => _stableIdOf(d) == id).toList();
    }
    final known = _devices.map((d) => d.deviceId).toSet();
    return devices.where((d) => !known.contains(_stableIdOf(d))).toList();
  }

  String _stableIdOf(UsbDevice device) =>
      computeUsbStableId(
        vid: device.vid,
        pid: device.pid,
        serial: device.serial,
      ) ??
      '${device.deviceId}';

  Future<AttachProbeResult> _connectAttachedMachine(UsbDevice device) async {
    final stableId = _stableIdOf(device);
    if (_devices.any((d) => d.deviceId == stableId)) {
      _log.fine('Attach probe: $stableId already known, skipping');
      return const AttachProbeUnsupported();
    }
    if (!serialProbeAllowsProductName(device.productName)) {
      _log.fine(
        'Attach probe: ${device.productName} is not a supported product',
      );
      return const AttachProbeUnsupported();
    }
    Device? detected;
    try {
      detected = await _runDetection(device);
    } catch (e, st) {
      _log.warning('Attach probe: detection failed for $stableId', e, st);
      return const AttachProbeUnsupported();
    }
    if (detected == null) {
      _log.fine('Attach probe: no supported device on $stableId');
      return const AttachProbeUnsupported();
    }
    final machine = detected;
    if (machine is! De1Interface) {
      _log.info('Attach probe: ${machine.name} is not a machine, rejecting');
      await _rejectAttachedDevice(machine);
      return const AttachProbeUnsupported();
    }
    try {
      await machine.onConnect().timeout(const Duration(seconds: 10));
    } catch (e, st) {
      _log.warning(
        'Attach probe: connect failed for ${machine.deviceId}',
        e,
        st,
      );
      await _rejectAttachedDevice(machine);
      return AttachProbeFailed(
        deviceId: machine.deviceId,
        deviceName: machine.name,
      );
    }
    _devices.add(machine);
    machine.connectionState.listen((state) {
      if (state == ConnectionState.disconnected) {
        _devices.remove(machine);
        _machineSubject.add(_devices);
        final t = _transportForDeviceId.remove(machine.deviceId);
        try {
          t?.dispose();
        } catch (_) {}
      }
    });
    _machineSubject.add(_devices);
    _log.info('Attach probe: connected ${machine.name} (${machine.deviceId})');
    return AttachProbeConnected(machine);
  }

  Future<void> _rejectAttachedDevice(Device detected) async {
    try {
      await detected.disconnect();
    } catch (e, st) {
      _log.fine('Attach probe: rejected device disconnect failed', e, st);
    }
    final t = _transportForDeviceId.remove(detected.deviceId);
    try {
      await t?.dispose();
    } catch (_) {}
  }

  Future<Device?> _runDetection(UsbDevice device) =>
      (_detectOverride ?? _detectDevice)(device);

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) async {
    final impl = remembered.implementation;
    final tt = remembered.transportType;
    if (impl == null || tt == null || tt != TransportType.serial) {
      return null;
    }

    final devices = await _listDevices();
    for (final d in devices) {
      final stableId =
          computeUsbStableId(vid: d.vid, pid: d.pid, serial: d.serial) ??
          '${d.deviceId}';
      if (stableId != remembered.id) continue;

      _log.info(
        'Quick-connect: found USB device ${d.productName} for ${remembered.id}',
      );
      Device? device;
      try {
        device = await _runDetection(d);
      } catch (e, st) {
        _log.warning('Quick-connect: _detectDevice failed', e, st);
        continue;
      }
      if (device == null || device.implementation != impl) {
        _log.info(
          'Quick-connect: device mismatch'
          ' (expected $impl, got ${device?.implementation})',
        );
        try {
          await device?.disconnect();
        } catch (_) {}
        final t = _transportForDeviceId.remove(device?.deviceId);
        try {
          await t?.dispose();
        } catch (_) {}
        continue;
      }
      try {
        await device.onConnect().timeout(const Duration(seconds: 10));
        final connected = device;
        _devices.add(connected);
        connected.connectionState.listen((state) {
          if (state == ConnectionState.disconnected) {
            _devices.remove(connected);
            _machineSubject.add(_devices);
            final t = _transportForDeviceId.remove(connected.deviceId);
            try {
              t?.dispose();
            } catch (_) {}
          }
        });
        _machineSubject.add(_devices);
        _log.info('Quick-connect succeeded for ${remembered.id}');
        return device;
      } catch (e, st) {
        _log.warning('Quick-connect: onConnect failed', e, st);
        try {
          await device.disconnect();
        } catch (_) {}
        final t = _transportForDeviceId.remove(device.deviceId);
        try {
          await t?.dispose();
        } catch (_) {}
      }
    }
    return null;
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    if (_isScanning) {
      _log.info("Scan already in progress, waiting for completion");
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
    List<Device> connected = [];
    final devicesCopy = List<Device>.from(_devices);
    for (var d in devicesCopy) {
      final state = await d.connectionState.first;
      if (state == ConnectionState.connected) {
        connected.add(d);
      }
    }

    final removed = _devices.where((d) => !connected.contains(d)).toList();
    if (removed.isNotEmpty) {
      _log.info(
        "Removing ${removed.length} non-connected devices: "
        "${removed.map((d) => '${d.name}(${d.deviceId})').join(', ')}",
      );
    }
    _devices.removeWhere((d) => connected.contains(d) == false);
    if (connected.isNotEmpty) {
      _log.fine(
        "Keeping ${connected.length} connected: "
        "${connected.map((d) => '${d.name}(${d.deviceId})').join(', ')}",
      );
    }

    var devices = await _listDevices();
    _log.info(
      "USB enumeration: ${devices.length} ports "
      "(${devices.map((d) => '${d.productName ?? d.deviceName}[${computeUsbStableId(vid: d.vid, pid: d.pid, serial: d.serial) ?? d.deviceId}]').join(', ')})",
    );

    final enumeratedIds = devices
        .map(
          (d) =>
              computeUsbStableId(vid: d.vid, pid: d.pid, serial: d.serial) ??
              "${d.deviceId}",
        )
        .toSet();
    final orphans = connected
        .where((d) => !enumeratedIds.contains(d.deviceId))
        .toList();
    for (final orphan in orphans) {
      _log.warning(
        "Orphan GC: ${orphan.name}(${orphan.deviceId}) not in USB enumeration, forcing disconnect",
      );
      await orphan.disconnect();
      connected.remove(orphan);
      _devices.remove(orphan);
    }

    devices.removeWhere((d) {
      final usbStableId = computeUsbStableId(
        vid: d.vid,
        pid: d.pid,
        serial: d.serial,
      );
      final isDuplicate = usbStableId != null
          ? _devices.any((t) => t.deviceId == usbStableId)
          : _devices.any((t) => t.deviceId == "${d.deviceId}");
      if (isDuplicate) {
        _log.fine(
          "Skipping ${d.productName ?? d.deviceName}: "
          "already connected as ${usbStableId ?? d.deviceId}",
        );
      }
      return isDuplicate;
    });

    _log.info("${devices.length} new devices to detect");
    final results = await Future.wait(
      devices.map((d) async {
        try {
          final device = await _runDetection(d);
          _log.info("Port $d -> ${device ?? 'no device'}");
          return device;
        } catch (e, st) {
          _log.warning("Error detecting device on $d", e, st);
          return null;
        }
      }),
    );
    _devices.addAll(results.whereType<Device>());
    _machineSubject.add(_devices);
  }

  Future<Device?> _detectDevice(UsbDevice device) async {
    _log.info("device name: ${device.productName}");
    if (!serialProbeAllowsProductName(device.productName)) {
      return null;
    }
    UsbPort? port;
    try {
      port = await device.create(UsbSerial.CDC);
    } catch (e) {
      port = await device.create(UsbSerial.CH34x);
    }
    if (port == null) {
      _log.warning("failed to add $device, port is null");
      return null;
    }
    final transport = AndroidSerialPort(device: device, port: port);
    _transportForDeviceId[transport.id] = transport;

    if (device.productName == "DE1") {
      _log.info("short circuit to de1");
      return UnifiedDe1(transport: transport);
    }

    if (device.productName == "Bengle") {
      _log.info("short circuit to bengle");
      return Bengle(transport: transport);
    }

    if (device.productName == "Half Decent Scale") {
      _log.info("short circuit to Half Decent Scale");
      return HDSSerial(transport: transport);
    }

    final usbModel = matchUsbDevice(
      usbDeviceTable,
      vid: device.vid,
      pid: device.pid,
    );
    if (usbModel != null) {
      _log.info("short circuit via VID:PID -> $usbModel");
      return UnifiedDe1(transport: transport);
    }

    final List<Uint8List> rawData = [];
    final duration = const Duration(seconds: 3);

    try {
      await transport.connect().timeout(Duration(milliseconds: 300));

      final subscription = transport.rawStream.listen(
        (chunk) {
          rawData.add(chunk);
        },
        onError: (err, st) => _log.warning("Serial read error", err, st),
        cancelOnError: false,
      );

      await Future.delayed(duration);
      await subscription.cancel();

      final combined = rawData.expand((e) => e).toList();
      List<String> strings = [];
      try {
        strings = rawData.map(utf8.decode).toList().join().split('\n');
      } catch (_) {}
      _log.info(
        "Collected serial data: ${combined.map((e) => e.toRadixString(16).padLeft(2, '0'))}",
      );
      _log.info("parsed into strings: $strings");

      if (strings.any((s) => s.startsWith('R '))) {
        return DebugPort(transport: transport);
      } else if (isDecentScale(strings, rawData)) {
        _log.info("Detected: Decent Scale");
        return HDSSerial(transport: transport);
      } else if (isSensorBasket(strings)) {
        _log.info("Detected: Sensor Basket");
        return SensorBasket(transport: transport);
      } else {
        final List<String> messages = [];
        final sub = transport.readStream.listen((line) {
          messages.add(line);
        });
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

        await Future.delayed(duration);
        await transport.writeCommand('<-M>');
        await transport.writeCommand('<-E>');
        sub.cancel();
        final List<String> lines = messages.join().split('\n');
        if (isDE1(lines, combined)) {
          int? v13Model;
          for (final line in lines) {
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
          return isBengle
              ? Bengle(transport: transport)
              : UnifiedDe1(transport: transport);
        }
      }

      _log.warning("Unknown device on port $device");
      await _disposeRejectedTransport(transport);
      return null;
    } catch (e, st) {
      _log.warning("Port $device is probably not a device we want", e, st);
      await _disposeRejectedTransport(transport);
      return null;
    }
  }

  Future<void> _disposeRejectedTransport(AndroidSerialPort transport) async {
    try {
      await transport.disconnect();
    } catch (e, st) {
      _log.fine('Rejected transport disconnect failed', e, st);
    }
    _transportForDeviceId.remove(transport.id);
    await transport.dispose();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _usbEventSubscription?.cancel();
    _usbEventSubscription = null;
    for (final transport in _transportForDeviceId.values.toSet()) {
      await transport.dispose();
    }
    _transportForDeviceId.clear();
    await _attachedSubject.close();
    await _machineSubject.close();
  }
}

class AndroidSerialPort implements SerialTransport {
  final UsbDevice _device;
  final UsbPort _port;
  late Logger _log;
  final BehaviorSubject<ConnectionState> _open = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );

  @override
  Stream<ConnectionState> get connectionState => _open.asBroadcastStream();

  AndroidSerialPort({required UsbDevice device, required UsbPort port})
    : _device = device,
      _port = port {
    _log = Logger("Serial:${_device.deviceName}");
  }
  @override
  Future<void> disconnect() async {
    _log.info("disconnecting (id=$id, path=${_device.deviceName})");
    _open.add(ConnectionState.disconnected);
    _portSubscription?.cancel();
    await _port.close();
  }

  @override
  String get id {
    final stable = computeUsbStableId(
      vid: _device.vid,
      pid: _device.pid,
      serial: _device.serial,
    );
    return stable ?? "${_device.deviceId}";
  }

  @override
  String get name => _device.deviceName;

  @override
  TransportType get transportType => TransportType.serial;

  StreamSubscription<Uint8List>? _portSubscription;
  @override
  Future<void> connect() async {
    if (await _open.first == ConnectionState.connected) {
      _log.fine('port already open');
      return;
    }
    if (await _port.open() == false) {
      throw "Failed to open port";
    }

    await _port.setDTR(false);
    await _port.setRTS(false);

    _port.setPortParameters(
      115200,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    final inputStream = _port.inputStream;
    if (inputStream == null) {
      _log.warning("inputStream is null after port.open() — no data will flow");
    }
    _portSubscription = inputStream?.listen(
      (Uint8List event) {
        _rawController.add(event);
        try {
          final input = utf8.decode(event);
          _log.finest("received serial input: $input");
          _outputController.add(input);
        } catch (e) {
          _log.fine("unable to parse to string", e);
        }
      },
      onError: (error) {
        _log.severe("port read failed", error);
        disconnect();
      },
      onDone: () {
        _log.warning("inputStream closed (onDone) — USB pipe may be dead");
        disconnect();
      },
    );
    _log.info("port connected (id=$id, path=${_device.deviceName})");
    _open.add(ConnectionState.connected);
  }

  final StreamController<Uint8List> _rawController =
      StreamController<Uint8List>.broadcast();

  @override
  Stream<Uint8List> get rawStream => _rawController.stream;

  final StreamController<String> _outputController =
      StreamController<String>.broadcast();

  @override
  Stream<String> get readStream => _outputController.stream;

  @override
  Future<void> writeCommand(String command) async {
    final toSend = "$command\n";
    await writeHexCommand(utf8.encode(toSend));
    _log.fine("wrote string: $command");
  }

  @override
  Future<void> writeHexCommand(Uint8List command) async {
    await _port.write(command);
    _log.fine("wrote request: ${command.map((e) => e.toRadixString(16))}");
  }

  @override
  Future<void> dispose() async {
    await _portSubscription?.cancel();
    _portSubscription = null;
    if (!_open.isClosed) _open.close();
    if (!_rawController.isClosed) _rawController.close();
    if (!_outputController.isClosed) _outputController.close();
  }
}
