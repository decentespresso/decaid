import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/device_identity.dart';
import 'package:reaprime/src/models/device/device_attach_notifier.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
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
  final Future<UsbPort?> Function(UsbDevice device, int iface)? _createTapPort;

  final List<Device> _devices = [];
  StreamSubscription<UsbEvent>? _usbEventSubscription;
  bool _disposed = false;

  SerialServiceAndroid({
    Future<List<UsbDevice>> Function()? listDevices,
    Stream<UsbEvent>? Function()? usbEventStream,
    Future<Device?> Function(UsbDevice device)? detectDevice,
    Future<UsbPort?> Function(UsbDevice device, int iface)? createTapPort,
    Duration probeDuration = const Duration(seconds: 3),
  }) : _listDevices = listDevices ?? UsbSerial.listDevices,
       _usbEventStream = usbEventStream ?? (() => UsbSerial.usbEventStream),
       _detectOverride = detectDevice,
       _createTapPort = createTapPort,
       _probeDuration = probeDuration;

  final Duration _probeDuration;
  final Map<String, AndroidSerialPort> _transportForDeviceId = {};
  final Map<int, String> _canonicalSerialByPhysicalId = {};
  Future<void> _admission = Future.value();
  int _usbRevision = 0;
  final Map<int, int> _usbGenerationByPhysicalId = {};
  final Map<Device, StreamSubscription<ConnectionState>> _deviceSubscriptions =
      {};

  /// Logical device ID -> physical `UsbDevice.deviceId` it was created from.
  ///
  /// Identical-serial Bengle boards share VID/PID/serial, so stable IDs
  /// cannot distinguish them; detach and cleanup follow physical-instance
  /// ownership instead.
  final Map<String, int> _logicalToPhysicalDeviceId = {};
  final Set<int> _detachedPhysicalIds = {};

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
    final revision = _usbRevision;
    try {
      final devices = await _listDevices();
      _log.info("found $devices");
      if (devices.isNotEmpty && _isCurrent(revision)) {
        for (final device in devices) {
          _canonicalSerialOf(device);
        }
        _announceAttach(null);
      }
    } catch (e, st) {
      _log.warning('USB enumeration unavailable during initialization', e, st);
    }
  }

  @visibleForTesting
  Future<void> handleUsbEvent(UsbEvent data) async {
    if (_disposed) return;
    if (data.event == UsbEvent.ACTION_USB_ATTACHED) {
      _announceAttach(data.device);
      return;
    }
    if (data.event != UsbEvent.ACTION_USB_DETACHED) return;
    final physical = data.device;
    final physicalId = physical?.deviceId;
    if (physicalId != null) {
      _usbGenerationByPhysicalId[physicalId] =
          (_usbGenerationByPhysicalId[physicalId] ?? 0) + 1;
      _detachedPhysicalIds.add(physicalId);
      _canonicalSerialByPhysicalId.remove(physicalId);
    } else {
      _usbRevision++;
    }
    await _serializeAdmission(() async {
      List<Device> detached;
      if (physicalId != null) {
        detached = _devices.where((device) {
          return _logicalToPhysicalDeviceId[device.deviceId] == physicalId ||
              device.deviceId == '$physicalId';
        }).toList();
      } else {
        detached = await _findMissingDevicesAfterEnumeration();
      }
      for (final device in detached) {
        _devices.remove(device);
        await device.disconnect();
      }
      await _releaseDisconnected(detached);
      if (!_disposed) _machineSubject.add(List.of(_devices));
    });
  }

  Future<T> _serializeAdmission<T>(Future<T> Function() action) {
    final result = _admission.then((_) => action());
    _admission = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  /// True when some already-known device owns the primary (non-tap)
  /// endpoint of this physical USB attachment.
  bool _ownsPrimaryEndpoint(int physicalId) => _devices.any(
    (device) =>
        device is! BengleDebugPort &&
        _logicalToPhysicalDeviceId[device.deviceId] == physicalId,
  );

  int _physicalGeneration(int? physicalId) =>
      physicalId == null ? 0 : (_usbGenerationByPhysicalId[physicalId] ?? 0);

  bool _isCurrent(
    int revision, {
    int? physicalId,
    int? expectedPhysicalGeneration,
  }) =>
      !_disposed &&
      _usbRevision == revision &&
      (physicalId == null ||
          _physicalGeneration(physicalId) == expectedPhysicalGeneration);

  Future<List<Device>> _findMissingDevicesAfterEnumeration() async {
    List<UsbDevice> devices;
    try {
      devices = await _listDevices();
    } catch (e, st) {
      _log.warning(
        'USB enumeration unavailable during detach reconciliation',
        e,
        st,
      );
      return const [];
    }
    for (final device in devices) {
      _canonicalSerialOf(device);
    }
    final livePhysicalIds = devices
        .map((device) => device.deviceId)
        .whereType<int>()
        .toSet();
    final liveStableIds = devices.map(_stableIdOf).toSet();
    final knownPhysicalIds = <int>{
      ..._logicalToPhysicalDeviceId.values,
      ..._canonicalSerialByPhysicalId.keys,
    };
    for (final physicalId in knownPhysicalIds) {
      if (!livePhysicalIds.contains(physicalId)) {
        _detachedPhysicalIds.add(physicalId);
        _usbGenerationByPhysicalId[physicalId] =
            (_usbGenerationByPhysicalId[physicalId] ?? 0) + 1;
      }
    }
    _canonicalSerialByPhysicalId.removeWhere(
      (physicalId, _) => !livePhysicalIds.contains(physicalId),
    );
    return _devices.where((device) {
      final physicalId = _logicalToPhysicalDeviceId[device.deviceId];
      if (physicalId != null) return !livePhysicalIds.contains(physicalId);
      final logicalId = withoutUsbInterfaceSuffix(device.deviceId);
      return !liveStableIds.any(
        (stableId) =>
            stableId == device.deviceId ||
            withoutUsbInterfaceSuffix(stableId) == logicalId,
      );
    }).toList();
  }

  void _announceAttach(UsbDevice? device) {
    final physicalId = device?.deviceId;
    if (physicalId != null) {
      _detachedPhysicalIds.remove(physicalId);
    }
    final stableId = device == null
        ? null
        : computeUsbAttachmentId(
            vid: device.vid,
            pid: device.pid,
            serial: _canonicalSerialOf(device),
            physicalId: physicalId,
          );
    _log.info(
      "USB_ATTACHED: device=${device?.productName ?? 'null'} "
      "id=${stableId ?? device?.deviceId}",
    );
    if (!_attachedSubject.isClosed) {
      _attachedSubject.add(
        DeviceAttachedEvent(
          deviceId: stableId,
          name: device?.productName,
          physicalDeviceId: physicalId,
        ),
      );
    }
  }

  @override
  Future<AttachProbeResult> connectAttachedMachine(DeviceAttachedEvent event) {
    final revision = _usbRevision;
    final generationSnapshot = Map<int, int>.from(_usbGenerationByPhysicalId);
    final physicalId = event.physicalDeviceId;
    final physicalGeneration = generationSnapshot[physicalId] ?? 0;
    return _serializeAdmission(() async {
      if (!_isCurrent(
        revision,
        physicalId: physicalId,
        expectedPhysicalGeneration: physicalGeneration,
      )) {
        return const AttachProbeUnsupported();
      }
      final devices = await _listDevices();
      if (!_isCurrent(
        revision,
        physicalId: physicalId,
        expectedPhysicalGeneration: physicalGeneration,
      )) {
        return const AttachProbeUnsupported();
      }
      for (final device in devices) {
        _canonicalSerialOf(device);
      }
      AttachProbeFailed? failure;
      for (final device in _attachedCandidates(event, devices)) {
        final result = await _connectAttachedMachine(
          device,
          revision,
          generationSnapshot[device.deviceId] ?? 0,
        );
        if (result is AttachProbeConnected) return result;
        if (result is AttachProbeFailed) failure = result;
      }
      return failure ?? const AttachProbeUnsupported();
    });
  }

  List<UsbDevice> _attachedCandidates(
    DeviceAttachedEvent event,
    List<UsbDevice> devices,
  ) {
    final physicalId = event.physicalDeviceId;
    if (physicalId != null) {
      return devices.where((d) => d.deviceId == physicalId).toList();
    }
    final id = event.deviceId;
    if (id != null && id.isNotEmpty) {
      return devices.where((d) => _stableIdOf(d) == id).toList();
    }
    final known = _devices.map((d) => d.deviceId).toSet();
    return devices.where((d) => !known.contains(_stableIdOf(d))).toList();
  }

  String? _canonicalSerialOf(UsbDevice device) {
    final serial = device.serial?.trim();
    if (serial != null && serial.isNotEmpty) {
      final physicalId = device.deviceId;
      if (physicalId != null) {
        _canonicalSerialByPhysicalId[physicalId] = serial;
      }
      return serial;
    }
    final physicalId = device.deviceId;
    return physicalId == null ? null : _canonicalSerialByPhysicalId[physicalId];
  }

  String _stableIdOf(UsbDevice device) =>
      computeUsbAttachmentId(
        vid: device.vid,
        pid: device.pid,
        serial: _canonicalSerialOf(device),
        physicalId: device.deviceId,
      ) ??
      'usb-session-unavailable';

  void _watchDevice(Device device) {
    if (_deviceSubscriptions.containsKey(device)) return;
    final subscription = device.connectionState.listen((state) async {
      if (state != ConnectionState.disconnected) return;
      if (!_devices.remove(device)) return;
      if (!_disposed) _machineSubject.add(List.of(_devices));
      _logicalToPhysicalDeviceId.remove(device.deviceId);
      final transport = _transportForDeviceId.remove(device.deviceId);
      try {
        await transport?.dispose();
      } catch (_) {}
      final old = _deviceSubscriptions.remove(device);
      await old?.cancel();
    });
    _deviceSubscriptions[device] = subscription;
  }

  Future<AttachProbeResult> _connectAttachedMachine(
    UsbDevice physical,
    int revision,
    int expectedPhysicalGeneration,
  ) async {
    if (!_isCurrent(
          revision,
          physicalId: physical.deviceId,
          expectedPhysicalGeneration: expectedPhysicalGeneration,
        ) ||
        _detachedPhysicalIds.contains(physical.deviceId) ||
        !serialProbeAllowsProductName(physical.productName)) {
      return const AttachProbeUnsupported();
    }
    final stableId = _stableIdOf(physical);
    final existing = _devices.firstWhereOrNull(
      (device) =>
          device is De1Interface &&
          (physical.deviceId != null
              ? _logicalToPhysicalDeviceId[device.deviceId] == physical.deviceId
              : device.deviceId == stableId),
    );
    Device? detected = existing;
    try {
      if (existing != null) {
        final state = await existing.connectionState.first;
        if (state == ConnectionState.connected ||
            state == ConnectionState.connecting) {
          return const AttachProbeUnsupported();
        }
        if (existing.deviceId != stableId) {
          _devices.remove(existing);
          await _releaseDisconnected([existing]);
          detected = await _runDetection(physical);
        }
      } else if (_devices.any((device) => device.deviceId == stableId)) {
        return const AttachProbeUnsupported();
      } else {
        detected = await _runDetection(physical);
      }
      if (detected == null) return const AttachProbeUnsupported();
      if (!_isCurrent(
            revision,
            physicalId: physical.deviceId,
            expectedPhysicalGeneration: expectedPhysicalGeneration,
          ) ||
          detected is! De1Interface) {
        await _rejectAttachedDevice(detected);
        return const AttachProbeUnsupported();
      }
      await detected.onConnect().timeout(const Duration(seconds: 10));
      if (!_isCurrent(
        revision,
        physicalId: physical.deviceId,
        expectedPhysicalGeneration: expectedPhysicalGeneration,
      )) {
        await _rejectAttachedDevice(detected);
        return const AttachProbeUnsupported();
      }
      _recordPhysicalOwnership(detected.deviceId, physical);
      _addDevices([detected]);
      _watchDevice(detected);
      _machineSubject.add(List.of(_devices));
      return AttachProbeConnected(detected);
    } catch (e, st) {
      _log.warning('Attach probe failed for $stableId', e, st);
      if (detected == null) return const AttachProbeUnsupported();
      await _rejectAttachedDevice(detected);
      return AttachProbeFailed(
        deviceId: detected.deviceId,
        deviceName: detected.name,
      );
    }
  }

  Future<void> _rejectAttachedDevice(Device detected) async {
    _devices.remove(detected);
    final subscription = _deviceSubscriptions.remove(detected);
    await subscription?.cancel();
    _logicalToPhysicalDeviceId.remove(detected.deviceId);
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

  Future<Device?> _runDetection(UsbDevice device) {
    if (device.deviceId == null && _canonicalSerialOf(device) == null) {
      return Future.value(null);
    }
    final detectOverride = _detectOverride;
    return detectOverride != null
        ? detectOverride(device)
        : _detectDevice(device, _canonicalSerialOf(device));
  }

  @override
  void stopScan() {}

  @override
  Future<Device?> tryQuickConnect(RememberedDevice remembered) {
    final revision = _usbRevision;
    final generationSnapshot = Map<int, int>.from(_usbGenerationByPhysicalId);
    return _serializeAdmission(() async {
      if (!_isCurrent(revision) ||
          remembered.implementation == null ||
          remembered.transportType != TransportType.serial) {
        return null;
      }
      final devices = await _listDevices();
      if (!_isCurrent(revision)) return null;
      for (final device in devices) {
        _canonicalSerialOf(device);
      }
      for (final physical in devices) {
        final physicalGeneration = generationSnapshot[physical.deviceId] ?? 0;
        if (!_isCurrent(
              revision,
              physicalId: physical.deviceId,
              expectedPhysicalGeneration: physicalGeneration,
            ) ||
            _detachedPhysicalIds.contains(physical.deviceId) ||
            _stableIdOf(physical) != remembered.id) {
          continue;
        }
        final existing = _devices.firstWhereOrNull(
          (device) => (physical.deviceId == null
              ? device.deviceId == remembered.id
              : device is! BengleDebugPort &&
                    _logicalToPhysicalDeviceId[device.deviceId] ==
                        physical.deviceId),
        );
        if (existing != null) {
          final state = await existing.connectionState.first;
          if (state == ConnectionState.connected &&
              _isCurrent(
                revision,
                physicalId: physical.deviceId,
                expectedPhysicalGeneration: physicalGeneration,
              )) {
            return existing;
          }
          if (state == ConnectionState.connecting) return null;
          _devices.remove(existing);
          await _releaseDisconnected([existing]);
        }
        Device? detected;
        try {
          detected = await _runDetection(physical);
          if (detected == null) continue;
          if (!_isCurrent(
                revision,
                physicalId: physical.deviceId,
                expectedPhysicalGeneration: physicalGeneration,
              ) ||
              detected.implementation != remembered.implementation) {
            await _rejectAttachedDevice(detected);
            continue;
          }
          await detected.onConnect().timeout(const Duration(seconds: 10));
          if (!_isCurrent(
            revision,
            physicalId: physical.deviceId,
            expectedPhysicalGeneration: physicalGeneration,
          )) {
            await _rejectAttachedDevice(detected);
            continue;
          }
          _recordPhysicalOwnership(detected.deviceId, physical);
          _addDevices([detected]);
          _watchDevice(detected);
          _machineSubject.add(List.of(_devices));
          return detected;
        } catch (e, st) {
          _log.warning('Quick-connect failed for ${remembered.id}', e, st);
          if (detected != null) await _rejectAttachedDevice(detected);
        }
      }
      return null;
    });
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    if (_isScanning) {
      _log.info("Scan already in progress, waiting for completion");
      await _currentScan;
      return;
    }

    _isScanning = true;
    final revision = _usbRevision;
    final generationSnapshot = Map<int, int>.from(_usbGenerationByPhysicalId);
    _currentScan = _serializeAdmission(() async {
      if (_isCurrent(revision)) {
        await _performScan(revision, generationSnapshot);
      }
    });

    try {
      await _currentScan;
    } finally {
      _isScanning = false;
      _currentScan = null;
    }
  }

  void _recordPhysicalOwnership(String logicalDeviceId, UsbDevice physical) {
    final physicalId = physical.deviceId;
    if (physicalId != null) {
      _logicalToPhysicalDeviceId[logicalDeviceId] = physicalId;
    }
  }

  void _addDevices(Iterable<Device> devices) {
    for (final device in devices) {
      _devices.removeWhere((known) => known.deviceId == device.deviceId);
      _devices.add(device);
    }
  }

  /// Removes ownership and transport mappings for [devices] that left the
  /// registry and disposes their adapters, so a later redetection does not
  /// overwrite the map entry and leak the old `UsbDeviceConnection`.
  Future<void> _releaseDisconnected(List<Device> devices) async {
    for (final d in devices) {
      _logicalToPhysicalDeviceId.remove(d.deviceId);
      final subscription = _deviceSubscriptions.remove(d);
      await subscription?.cancel();
      final t = _transportForDeviceId.remove(d.deviceId);
      try {
        await t?.dispose();
      } catch (e, st) {
        _log.fine('transport dispose failed for ${d.deviceId}', e, st);
      }
    }
  }

  Future<void> _performScan(
    int revision,
    Map<int, int> generationSnapshot,
  ) async {
    List<Device> connected = [];
    final devicesCopy = List<Device>.from(_devices);
    for (var d in devicesCopy) {
      final state = await d.connectionState.first;
      if (state == ConnectionState.connected ||
          state == ConnectionState.connecting) {
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
    await _releaseDisconnected(removed);
    if (connected.isNotEmpty) {
      _log.fine(
        "Keeping ${connected.length} connected: "
        "${connected.map((d) => '${d.name}(${d.deviceId})').join(', ')}",
      );
    }

    var devices = await _listDevices();
    if (!_isCurrent(revision)) return;
    final detachedInEnumeration = devices
        .where(
          (device) =>
              device.deviceId != null &&
              _detachedPhysicalIds.contains(device.deviceId),
        )
        .toSet();
    if (detachedInEnumeration.isNotEmpty) {
      _log.fine(
        "Ignoring ${detachedInEnumeration.length} detached USB attachment(s) "
        "still present in enumeration",
      );
      devices = devices
          .where((d) => !detachedInEnumeration.contains(d))
          .toList();
    }
    for (final device in devices) {
      _canonicalSerialOf(device);
    }
    final missingPhysicalIds = _canonicalSerialByPhysicalId.keys
        .where((id) => !devices.any((device) => device.deviceId == id))
        .toList();
    for (final id in missingPhysicalIds) {
      _canonicalSerialByPhysicalId.remove(id);
    }
    _log.info(
      "USB enumeration: ${devices.length} ports "
      "(${devices.map((d) => '${d.productName ?? d.deviceName}[${_stableIdOf(d)}]').join(', ')})",
    );

    final enumeratedPhysicalIds = devices
        .map((d) => d.deviceId)
        .whereType<int>()
        .toSet();
    final enumeratedStableIds = devices.map((d) => _stableIdOf(d)).toSet();

    // Devices with recorded physical ownership are reconciled against the
    // enumerated physical IDs — identical-serial boards reduce to the same
    // stable base, so only physical ownership can tell them apart. Devices
    // without ownership fall back to the stable base ID.
    bool isOrphan(Device d) {
      final physicalId = _logicalToPhysicalDeviceId[d.deviceId];
      if (physicalId != null) {
        return !enumeratedPhysicalIds.contains(physicalId);
      }
      return !enumeratedStableIds.contains(
        withoutUsbInterfaceSuffix(d.deviceId),
      );
    }

    final orphan = connected.where(isOrphan).toList();
    for (final orphan in orphan) {
      _log.warning(
        "Orphan GC: ${orphan.name}(${orphan.deviceId}) not in USB enumeration, forcing disconnect",
      );
      await orphan.disconnect();
      connected.remove(orphan);
      _devices.remove(orphan);
    }
    await _releaseDisconnected(orphan);

    _log.info("${devices.length} new devices to detect");
    final seenMachineIds = <String>{};
    final detectedPhysicalIds = <Device, int?>{};
    final detectedGenerations = <Device, int>{};
    final results = await Future.wait(
      devices.map((d) async {
        final found = <Device>[];
        final physicalId = d.deviceId;
        final physicalGeneration = generationSnapshot[physicalId] ?? 0;
        try {
          final machineId = _stableIdOf(d);
          final alreadyOwned =
              physicalId != null && _ownsPrimaryEndpoint(physicalId);
          if (!alreadyOwned &&
              !_devices.any((t) => t.deviceId == machineId) &&
              seenMachineIds.add(machineId) &&
              _isCurrent(
                revision,
                physicalId: physicalId,
                expectedPhysicalGeneration: physicalGeneration,
              )) {
            final device = await _runDetection(d);
            if (device != null &&
                _isCurrent(
                  revision,
                  physicalId: physicalId,
                  expectedPhysicalGeneration: physicalGeneration,
                )) {
              found.add(device);
              detectedPhysicalIds[device] = physicalId;
              detectedGenerations[device] = physicalGeneration;
              _recordPhysicalOwnership(device.deviceId, d);
            } else if (device != null) {
              await _rejectAttachedDevice(device);
            }
          }
        } catch (e, st) {
          _log.warning("Error detecting device on $d", e, st);
        }
        try {
          final tap = await _detectTap(d, revision, physicalGeneration);
          if (tap != null &&
              _isCurrent(
                revision,
                physicalId: physicalId,
                expectedPhysicalGeneration: physicalGeneration,
              )) {
            found.add(tap);
            detectedPhysicalIds[tap] = physicalId;
            detectedGenerations[tap] = physicalGeneration;
          } else if (tap != null) {
            await _rejectAttachedDevice(tap);
          }
        } catch (e, st) {
          _log.warning("Error detecting Bengle tap on $d", e, st);
        }
        return found;
      }),
    );
    final detected = results.expand((e) => e).toList();
    final currentDetected = <Device>[];
    for (final device in detected) {
      final physicalId = detectedPhysicalIds[device];
      final generation = detectedGenerations[device];
      if (_isCurrent(
        revision,
        physicalId: physicalId,
        expectedPhysicalGeneration: generation,
      )) {
        currentDetected.add(device);
      } else {
        await _rejectAttachedDevice(device);
      }
    }
    if (!_isCurrent(revision)) {
      for (final device in currentDetected) {
        await _rejectAttachedDevice(device);
      }
      return;
    }
    _addDevices(currentDetected);
    _machineSubject.add(List.of(_devices));
  }

  /// Detects the Bengle EBus tap on a composite Bengle device.
  ///
  /// Gated on VID/PID, interface count, and the exact product name — never
  /// by probing or writing to the interface. The tap is opened through the
  /// Android bulk-data interface 3 (the usb_serial fork derives the
  /// control interface as `iface - 1`), while the logical identity and ID
  /// keep denoting interface 2 (`-if02`). Identical-serial boards are
  /// disambiguated by the physical `UsbDevice.deviceId` in the tap ID.
  Future<Device?> _detectTap(
    UsbDevice device,
    int revision,
    int expectedPhysicalGeneration,
  ) async {
    if (!_isCurrent(
          revision,
          physicalId: device.deviceId,
          expectedPhysicalGeneration: expectedPhysicalGeneration,
        ) ||
        _detachedPhysicalIds.contains(device.deviceId)) {
      return null;
    }
    if (device.deviceId == null && _canonicalSerialOf(device) == null) {
      return null;
    }
    if (!isBengleCompositeWithTap(
      vid: device.vid,
      pid: device.pid,
      interfaceCount: device.interfaceCount,
      productName: device.productName,
    )) {
      return null;
    }
    final tapStableId = computeUsbStableId(
      vid: device.vid,
      pid: device.pid,
      serial: _canonicalSerialOf(device),
      interfaceNumber: bengleEbusTapInterface,
    );
    final physicalId = device.deviceId;
    final tapId = tapStableId == null
        ? null
        : physicalId == null
        ? tapStableId
        : '$tapStableId-$physicalId';
    if (tapId != null &&
        (_devices.any((d) => d.deviceId == tapId) ||
            (physicalId != null &&
                _devices.any(
                  (d) =>
                      d is BengleDebugPort &&
                      _logicalToPhysicalDeviceId[d.deviceId] == physicalId,
                )))) {
      return null;
    }
    final port = await (_createTapPort ?? _defaultCreateTapPort)(
      device,
      bengleEbusAndroidDataInterface,
    );
    if (port == null) {
      _log.warning(
        "failed to open Bengle tap data interface "
        "$bengleEbusAndroidDataInterface on $device",
      );
      return null;
    }
    if (!_isCurrent(
      revision,
      physicalId: device.deviceId,
      expectedPhysicalGeneration: expectedPhysicalGeneration,
    )) {
      await port.close();
      return null;
    }
    final transport = AndroidSerialPort(
      device: device,
      port: port,
      interfaceNumber: bengleEbusTapInterface,
      physicalInstanceId: physicalId,
      identityOverride: computeUsbStableId(
        vid: device.vid,
        pid: device.pid,
        serial: _canonicalSerialOf(device),
      ),
      dtrOn: true,
      // The tap is binary-only: never enter the UTF-8/text log path.
      decodeUtf8Text: false,
    );
    _transportForDeviceId[transport.id] = transport;
    _recordPhysicalOwnership(transport.id, device);
    _log.info(
      "Bengle EBus tap on interface $bengleEbusTapInterface"
      " (${transport.id})",
    );
    return BengleDebugPort(transport: transport);
  }

  static Future<UsbPort?> _defaultCreateTapPort(UsbDevice device, int iface) =>
      device.create(UsbSerial.CDC, iface);

  Future<Device?> _detectDevice(
    UsbDevice device,
    String? canonicalSerial,
  ) async {
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
    final isDebugProbe = device.productName == 'Debug Probe (CMSIS-DAP)';
    late final AndroidSerialPort transport;
    transport = AndroidSerialPort(
      device: device,
      port: port,
      baudRate: isDebugProbe ? 460800 : 115200,
      physicalInstanceId: device.deviceId,
      canonicalIdentity: () {
        if (!identical(_transportForDeviceId[transport.id], transport)) {
          return null;
        }
        final serial = _canonicalSerialByPhysicalId[device.deviceId];
        if (serial == null) return null;
        return computeUsbStableId(
          vid: device.vid,
          pid: device.pid,
          serial: serial,
        );
      },
      identityOverride: canonicalSerial == null
          ? null
          : computeUsbStableId(
              vid: device.vid,
              pid: device.pid,
              serial: canonicalSerial,
            ),
    );
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
    final duration = _probeDuration;

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
      } else if (isDebugProbe) {
        _log.info("Rejecting unclassified Debug Probe without DE1 writes");
        await _disposeRejectedTransport(transport);
        return null;
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
    for (final subscription in _deviceSubscriptions.values.toList()) {
      await subscription.cancel();
    }
    _deviceSubscriptions.clear();
    _transportForDeviceId.clear();
    _logicalToPhysicalDeviceId.clear();
    _canonicalSerialByPhysicalId.clear();
    _usbGenerationByPhysicalId.clear();
    _detachedPhysicalIds.clear();
    await _attachedSubject.close();
    await _machineSubject.close();
  }
}

class AndroidSerialPort implements SerialTransport, CanonicalDeviceIdentity {
  final UsbDevice _device;
  final UsbPort _port;
  final int? _interfaceNumber;
  final int? _physicalInstanceId;
  final String? _identityOverride;
  final String? Function()? _canonicalIdentity;
  final bool _dtrOn;
  final bool _decodeUtf8Text;
  final int _baudRate;
  late Logger _log;
  bool _disposed = false;
  final BehaviorSubject<ConnectionState> _open = BehaviorSubject.seeded(
    ConnectionState.discovered,
  );

  @override
  Stream<ConnectionState> get connectionState => _open.asBroadcastStream();

  AndroidSerialPort({
    required UsbDevice device,
    required UsbPort port,
    int? interfaceNumber,
    int? physicalInstanceId,
    String? identityOverride,
    String? Function()? canonicalIdentity,
    bool dtrOn = false,
    bool decodeUtf8Text = true,
    int baudRate = 115200,
  }) : _device = device,
       _port = port,
       _interfaceNumber = interfaceNumber,
       _physicalInstanceId = physicalInstanceId,
       _identityOverride = identityOverride,
       _canonicalIdentity = canonicalIdentity,
       _dtrOn = dtrOn,
       _decodeUtf8Text = decodeUtf8Text,
       _baudRate = baudRate {
    _log = Logger("Serial:${_device.deviceName}");
  }
  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _connectionRevision++;
    _log.info("disconnecting (id=$id, path=${_device.deviceName})");
    if (!_open.isClosed) _open.add(ConnectionState.disconnected);
    _portSubscription?.cancel();
    await _port.close();
  }

  @override
  String get id {
    final physicalInstanceId = _physicalInstanceId ?? _device.deviceId;
    final identityOverride = _identityOverride;
    if (identityOverride == null) {
      final base =
          computeUsbAttachmentId(
            vid: _device.vid,
            pid: _device.pid,
            serial: _device.serial,
            physicalId: physicalInstanceId,
            interfaceNumber: _interfaceNumber,
          ) ??
          'usb-session-unavailable';
      final hasSerial = _device.serial?.trim().isNotEmpty == true;
      final hasInterface = _interfaceNumber != null && _interfaceNumber > 0;
      return physicalInstanceId != null && hasSerial && hasInterface
          ? '$base-$physicalInstanceId'
          : base;
    }
    final interfaceNumber = _interfaceNumber;
    if (interfaceNumber == null || interfaceNumber <= 0) {
      return identityOverride;
    }
    final base =
        '$identityOverride-if${interfaceNumber.toRadixString(16).padLeft(2, '0')}';
    return physicalInstanceId == null ? base : '$base-$physicalInstanceId';
  }

  @override
  String? get canonicalDeviceId => _canonicalIdentity?.call();

  @override
  String get name => _device.deviceName;

  @override
  TransportType get transportType => TransportType.serial;

  StreamSubscription<Uint8List>? _portSubscription;
  Future<void>? _connecting;
  int _connectionRevision = 0;

  @override
  Future<void> connect() {
    if (_disposed) return Future.error(StateError('Serial port is disposed'));
    final pending = _connecting;
    if (pending != null) return pending;
    if (_open.value == ConnectionState.connected) return Future.value();
    final revision = _connectionRevision;
    _open.add(ConnectionState.connecting);
    final connection = _connectPort(
      revision,
    ).whenComplete(() => _connecting = null);
    _connecting = connection;
    return connection;
  }

  Future<void> _connectPort(int revision) async {
    try {
      await _openPort(revision);
    } catch (_) {
      if (!_disposed && revision == _connectionRevision) {
        _open.add(ConnectionState.disconnected);
      }
      rethrow;
    }
  }

  Future<void> _openPort(int revision) async {
    if (await _port.open() == false) {
      throw StateError('Failed to open serial port');
    }
    if (_disposed || revision != _connectionRevision) {
      await _port.close();
      throw StateError('Serial connection cancelled');
    }

    await _port.setDTR(_dtrOn);
    await _port.setRTS(false);
    if (_disposed || revision != _connectionRevision) {
      await _port.close();
      throw StateError('Serial connection cancelled');
    }

    await _port.setPortParameters(
      _baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    if (_disposed || revision != _connectionRevision) {
      await _port.close();
      throw StateError('Serial connection cancelled');
    }

    final inputStream = _port.inputStream;
    if (inputStream == null) {
      _log.warning("inputStream is null after port.open() — no data will flow");
    }
    _portSubscription = inputStream?.listen(
      (Uint8List event) {
        _rawController.add(event);
        if (!_decodeUtf8Text) return;
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
    if (_disposed) return;
    _disposed = true;
    _connectionRevision++;
    await _portSubscription?.cancel();
    _portSubscription = null;
    try {
      await _port.close();
    } catch (e, st) {
      _log.warning("dispose: _port.close failed", e, st);
    }
    if (!_open.isClosed) _open.close();
    if (!_rawController.isClosed) _rawController.close();
    if (!_outputController.isClosed) _outputController.close();
  }
}
