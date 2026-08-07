part of '../webserver_service.dart';

/// Aggregates device, scanning, and charging state into a single broadcast
/// stream. One instance is shared across all WebSocket connections, avoiding
/// duplicate subscriptions and ensuring correct cleanup when devices
/// appear/disappear.
class DevicesStateAggregator {
  final DeviceController _controller;
  final BatteryController? _batteryController;
  final ConnectionManager _connectionManager;
  final RememberedDevicesController? _rememberedController;
  final String? Function()? _preferredScaleId;
  final Logger _log = Logger("DevicesStateAggregator");

  final List<StreamSubscription> _subscriptions = [];

  /// Per-device connectionState subscriptions keyed by deviceId.
  /// Stores both the Device reference (for identity comparison) and the
  /// subscription so we can detect same-ID-different-object replacements.
  final Map<String, (Device, StreamSubscription)> _deviceStateSubs = {};

  final BehaviorSubject<Map<String, dynamic>> _stateStream =
      BehaviorSubject<Map<String, dynamic>>();

  Timer? _debounceTimer;

  /// Broadcast stream of unified state snapshots.
  Stream<Map<String, dynamic>> get stateStream => _stateStream.stream;

  /// Number of active per-device connectionState subscriptions (for testing).
  int get activeDeviceSubscriptionCount => _deviceStateSubs.length;

  DevicesStateAggregator({
    required DeviceController controller,
    BatteryController? batteryController,
    required ConnectionManager connectionManager,
    RememberedDevicesController? rememberedController,
    String? Function()? preferredScaleId,
  }) : _controller = controller,
       _batteryController = batteryController,
       _connectionManager = connectionManager,
       _rememberedController = rememberedController,
       _preferredScaleId = preferredScaleId {
    _start();
  }

  void _start() {
    // Subscribe to device list changes (skip initial BehaviorSubject replay;
    // initial state is sent via the seeded emitState below)
    _subscriptions.add(
      _controller.deviceStream.skip(1).listen((devices) {
        _updateDeviceSubscriptions(devices);
        _emitState();
      }),
    );

    _subscriptions.add(
      _controller.scanningStream.skip(1).listen((_) => _emitState()),
    );

    if (_batteryController != null) {
      _subscriptions.add(
        _batteryController.chargingState.skip(1).listen((_) => _emitState()),
      );
    }

    _subscriptions.add(
      _connectionManager.status.skip(1).listen((_) => _emitState()),
    );

    // Re-emit when the remembered set changes (a device remembered/forgotten),
    // so available/unavailable entries appear/disappear promptly (skip replay).
    final remembered = _rememberedController;
    if (remembered != null) {
      _subscriptions.add(
        remembered.changes.skip(1).listen((_) => _emitState()),
      );
    }

    _updateDeviceSubscriptions(_controller.devices);

    _emitState(immediate: true);
  }

  void _updateDeviceSubscriptions(List<Device> devices) {
    final currentIds = devices.map((d) => d.deviceId).toSet();

    final staleIds = _deviceStateSubs.keys
        .where((id) => !currentIds.contains(id))
        .toList();
    for (final id in staleIds) {
      _deviceStateSubs.remove(id)?.$2.cancel();
    }

    for (final device in devices) {
      final existing = _deviceStateSubs[device.deviceId];
      if (existing != null) {
        if (identical(existing.$1, device)) {
          continue; // Same object, subscription is still valid
        }
        // Different object with same ID (BLE reconnect) — replace subscription
        existing.$2.cancel();
      }
      // New device or replacement: subscribe (skip initial replay — the
      // current state is already captured by _buildSnapshot)
      final sub = device.connectionState.skip(1).listen((_) => _emitState());
      _deviceStateSubs[device.deviceId] = (device, sub);
    }
  }

  void _emitState({bool immediate = false}) {
    if (immediate) {
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _emitStateNow();
      return;
    }
    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: 100), () {
      _emitStateNow();
    });
  }

  void _emitStateNow() async {
    try {
      final snapshot = await _buildSnapshot();
      _stateStream.add(snapshot);
    } catch (e, st) {
      _log.warning("failed to build devices state snapshot", e, st);
    }
  }

  Future<Map<String, dynamic>> _buildSnapshot() async {
    final devList = await buildAvailabilityDeviceList(
      _controller.devices,
      _rememberedController?.remembered ?? const [],
      preferredScaleId: _preferredScaleId?.call(),
    );

    final snapshot = <String, dynamic>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'devices': devList,
      'scanning': _controller.isScanning,
    };
    if (_batteryController?.currentChargingState != null) {
      snapshot['charging'] = _batteryController!.currentChargingState!.toJson();
    }
    final cs = _connectionManager.currentStatus;
    snapshot['connectionStatus'] = {
      'phase': cs.phase.name,
      'foundMachines': cs.foundMachines
          .map(
            (m) => {
              'name': m.name,
              'id': m.deviceId,
              'state': 'discovered',
              'type': DeviceType.machine.name,
            },
          )
          .toList(),
      'foundScales': cs.foundScales
          .map(
            (s) => {
              'name': s.name,
              'id': s.deviceId,
              'state': 'discovered',
              'type': DeviceType.scale.name,
            },
          )
          .toList(),
      'pendingAmbiguity': cs.pendingAmbiguity?.name,
      'error': cs.error?.toJson(),
    };
    return snapshot;
  }

  void dispose() {
    _debounceTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    for (final entry in _deviceStateSubs.values) {
      entry.$2.cancel();
    }
    _deviceStateSubs.clear();
    _stateStream.close();
  }
}

class DevicesHandler {
  final DeviceController _controller;
  final ConnectionManager _connectionManager;
  final RememberedDevicesController? _rememberedController;
  final String? Function()? _preferredScaleId;
  final Logger _log = Logger("Devices handler");
  final DevicesStateAggregator _aggregator;

  DevicesHandler({
    required DeviceController controller,
    BatteryController? batteryController,
    required ConnectionManager connectionManager,
    RememberedDevicesController? rememberedController,
    String? Function()? preferredScaleId,
  }) : _controller = controller,
       _connectionManager = connectionManager,
       _rememberedController = rememberedController,
       _preferredScaleId = preferredScaleId,
       _aggregator = DevicesStateAggregator(
         controller: controller,
         batteryController: batteryController,
         connectionManager: connectionManager,
         rememberedController: rememberedController,
         preferredScaleId: preferredScaleId,
       );

  void dispose() {
    _aggregator.dispose();
  }

  void addRoutes(RouterPlus app) {
    app.get('/api/v1/devices', () async {
      log.info("handling devices");
      try {
        return await _deviceList();
      } catch (e, st) {
        return jsonError({'e': e.toString(), 'st': st.toString()});
      }
    });
    app.get('/api/v1/devices/scan', (Request req) async {
      final bool quickScan =
          req.requestedUri.queryParametersAll["quick"]?.firstOrNull == "true";
      final bool connect =
          req.requestedUri.queryParametersAll["connect"]?.firstOrNull !=
          "false";
      log.info("running scan, quick = $quickScan, connect = $connect");
      if (connect) {
        if (quickScan) {
          _connectionManager.scanAndConnect();
          return [];
        }
        await _connectionManager.scanAndConnect();
      } else {
        if (quickScan) {
          _controller.scanForDevices();
          return [];
        }
        _controller.scanForDevices();
        await _controller.scanningStream.firstWhere((s) => s);
        await _controller.scanningStream.firstWhere((s) => !s);
      }

      return await _deviceList();
    });

    app.put('/api/v1/devices/connect', _handleConnect);
    app.put('/api/v1/devices/disconnect', _handleDisconnect);

    // Forget a remembered device: drop it from the persistent registry. If the
    // device isn't currently present it then no longer appears in the list.
    // deviceId comes from the body/query (not the path) since serial ids are
    // paths like /dev/cu.* and WiFi ids contain ':', neither URL-path-safe.
    app.put('/api/v1/devices/forget', _handleForget);

    app.get('/ws/v1/devices', sws.webSocketHandler(_handleDevicesSocket));
  }

  Future<List<Map<String, dynamic>>> _deviceList() async {
    return buildAvailabilityDeviceList(
      _controller.devices,
      _rememberedController?.remembered ?? const [],
      preferredScaleId: _preferredScaleId?.call(),
    );
  }

  /// Extract deviceId from JSON body or query parameter.
  /// Body takes precedence; query param is kept for backward compatibility.
  Future<String?> _extractDeviceId(Request req) async {
    String body;
    try {
      body = await req.readAsString();
    } catch (e, st) {
      _log.warning('failed to read request body', e, st);
      return req.requestedUri.queryParameters['deviceId'];
    }
    if (body.isNotEmpty) {
      try {
        final decoded = jsonDecode(body);
        // Tolerate a wrong-shape body (e.g. an array) by falling through to the
        // query param, rather than letting a cast throw.
        if (decoded is Map<String, dynamic> && decoded['deviceId'] is String) {
          return decoded['deviceId'] as String;
        }
      } on FormatException {
        // Not valid JSON — fall through to the query parameter.
      }
    }
    return req.requestedUri.queryParameters['deviceId'];
  }

  Future<Response> _handleForget(Request req) async {
    final remembered = _rememberedController;
    if (remembered == null) {
      // The feature is wired in normal operation; a null controller means it's
      // unavailable, not that the server broke — 503, not 500, so it doesn't
      // pollute error monitoring.
      return jsonServiceUnavailable({
        'error': 'remembered devices not available',
      });
    }
    final deviceId = await _extractDeviceId(req);
    if (deviceId == null) {
      return jsonBadRequest({'error': 'Missing deviceId'});
    }
    await remembered.forget(deviceId);
    return jsonOk(null);
  }

  Future<Response> _handleConnect(Request req) async {
    final devices = _controller.devices;
    final deviceId = await _extractDeviceId(req);
    if (deviceId == null) {
      return jsonBadRequest({'error': 'Missing deviceId'});
    }
    final device = devices.firstWhereOrNull((e) => e.deviceId == deviceId);
    if (device == null) {
      return jsonNotFound({'error': 'Device not found: $deviceId'});
    }
    final result = await _connectDevice(device);
    final body = await _connectResultBody(device, result);
    return switch (result.outcome) {
      ConnectionOutcome.connected ||
      ConnectionOutcome.alreadyConnected => jsonOk(body),
      ConnectionOutcome.conflict => jsonConflict(body),
      ConnectionOutcome.failed => jsonServiceUnavailable(body),
      ConnectionOutcome.timedOut => jsonGatewayTimeout(body),
    };
  }

  Future<Response> _handleDisconnect(Request req) async {
    final devices = _controller.devices;
    final deviceId = await _extractDeviceId(req);
    if (deviceId == null) {
      return jsonBadRequest({'error': 'Missing deviceId'});
    }
    final device = devices.firstWhereOrNull((e) => e.deviceId == deviceId);
    if (device == null) {
      return jsonNotFound({'error': 'Device not found: $deviceId'});
    }
    _connectionManager.markExpectingDisconnect(device.deviceId);
    await device.disconnect();

    return jsonOk(null);
  }

  void _handleDevicesSocket(WebSocketChannel socket, String? protocol) {
    _log.fine("devices websocket connected");

    // Subscribe to the shared aggregator stream — each WebSocket connection
    // gets a lightweight listener on the single broadcast output instead of
    // creating its own set of upstream subscriptions.
    final sub = _aggregator.stateStream.listen((snapshot) {
      try {
        socket.sink.add(jsonEncode(snapshot));
      } catch (e, st) {
        _log.warning("failed to send devices state to websocket", e, st);
      }
    });
    var commandQueue = Future<void>.value();

    socket.stream.listen(
      (message) {
        commandQueue = commandQueue
            .catchError((Object _, StackTrace _) {})
            .then((_) async {
              try {
                final data =
                    jsonDecode(message.toString()) as Map<String, dynamic>;
                await _handleCommand(data, socket);
              } catch (e) {
                socket.sink.add(jsonEncode({'error': 'Invalid JSON: $e'}));
              }
            });
      },
      onDone: () {
        _log.fine("devices websocket disconnected");
        sub.cancel();
      },
      onError: (e, st) {
        _log.warning("devices websocket error", e, st);
        sub.cancel();
      },
    );
  }

  Future<void> _handleCommand(
    Map<String, dynamic> data,
    WebSocketChannel socket,
  ) async {
    final command = data['command'] as String?;
    if (command == null) {
      socket.sink.add(jsonEncode({'error': 'Missing "command" field'}));
      return;
    }

    switch (command) {
      case 'scan':
        final connect = data['connect'] as bool? ?? true;
        final quick = data['quick'] as bool? ?? false;
        _log.fine("ws scan command: connect=$connect, quick=$quick");
        if (connect) {
          if (quick) {
            _connectionManager.scanAndConnect();
          } else {
            _connectionManager.scanAndConnect().catchError((e) {
              socket.sink.add(jsonEncode({'error': 'Scan failed: $e'}));
            });
          }
        } else {
          if (quick) {
            _controller.scanForDevices();
          } else {
            _controller.scanForDevices().then<void>(
              (_) {},
              onError: (e) {
                socket.sink.add(jsonEncode({'error': 'Scan failed: $e'}));
              },
            );
          }
        }

      case 'connect':
        final deviceId = data['deviceId'] as String?;
        if (deviceId == null) {
          socket.sink.add(
            jsonEncode({'error': 'Missing "deviceId" for connect'}),
          );
          return;
        }
        final device = _controller.devices.firstWhereOrNull(
          (e) => e.deviceId == deviceId,
        );
        if (device == null) {
          socket.sink.add(jsonEncode({'error': 'Device not found: $deviceId'}));
          return;
        }
        await _sendConnectResult(device, socket);

      case 'disconnect':
        final deviceId = data['deviceId'] as String?;
        if (deviceId == null) {
          socket.sink.add(
            jsonEncode({'error': 'Missing "deviceId" for disconnect'}),
          );
          return;
        }
        final device = _controller.devices.firstWhereOrNull(
          (e) => e.deviceId == deviceId,
        );
        if (device == null) {
          socket.sink.add(jsonEncode({'error': 'Device not found: $deviceId'}));
          return;
        }
        _connectionManager.markExpectingDisconnect(device.deviceId);
        device.disconnect().catchError((e) {
          socket.sink.add(jsonEncode({'error': 'Disconnect failed: $e'}));
        });

      default:
        socket.sink.add(jsonEncode({'error': 'Unknown command: $command'}));
    }
  }

  Future<void> _sendConnectResult(
    Device device,
    WebSocketChannel socket,
  ) async {
    try {
      final result = await _connectDevice(device);
      final body = await _connectResultBody(device, result);
      socket.sink.add(
        jsonEncode(
          result.success
              ? body
              : {
                  ...body,
                  'error':
                      body['connectionError']?['message'] ??
                      'Connect ${result.outcome.name}',
                },
        ),
      );
    } catch (e) {
      socket.sink.add(jsonEncode({'error': 'Connect failed: $e'}));
    }
  }

  Future<ConnectionResult> _connectDevice(Device device) async {
    switch (device.type) {
      case DeviceType.machine:
        final machine = device as De1Interface;
        if (_connectionManager.currentStatus.pendingAmbiguity ==
            AmbiguityReason.machinePicker) {
          return _connectionManager.selectMachine(machine);
        }
        return _connectionManager.connectMachine(machine);
      case DeviceType.scale:
        final scale = device as Scale;
        if (_connectionManager.currentStatus.pendingAmbiguity ==
            AmbiguityReason.scalePicker) {
          return _connectionManager.selectScale(scale);
        }
        return _connectionManager.connectScale(scale);
      case DeviceType.sensor:
        try {
          final sensor = device as Sensor;
          if (await sensor.connectionState.first == ConnectionState.connected) {
            return const ConnectionResult.alreadyConnected();
          }
          await sensor.onConnect();
          return const ConnectionResult.succeeded();
        } on TimeoutException catch (e) {
          return ConnectionResult.timedOut(e.toString());
        } catch (e) {
          return ConnectionResult.failed(e.toString());
        }
    }
  }

  Future<Map<String, dynamic>> _connectResultBody(
    Device device,
    ConnectionResult result,
  ) async {
    final state = await device.connectionState.first;
    return {
      'deviceId': device.deviceId,
      'operation': 'connect',
      'outcome': result.outcome.name,
      'state': state.name,
      'connectionError': _connectionError(device, result)?.toJson(),
    };
  }

  ConnectionError? _connectionError(Device device, ConnectionResult result) {
    if (result.success || result.outcome == ConnectionOutcome.conflict) {
      return null;
    }
    final currentError = _connectionManager.currentStatus.error;
    if (currentError?.deviceId == device.deviceId) return currentError;
    final timedOut = result.outcome == ConnectionOutcome.timedOut;
    return ConnectionError(
      kind: switch (device.type) {
        DeviceType.machine => ConnectionErrorKind.machineConnectFailed,
        DeviceType.scale => ConnectionErrorKind.scaleConnectFailed,
        DeviceType.sensor => ConnectionErrorKind.sensorConnectFailed,
      },
      severity: ConnectionErrorSeverity.error,
      timestamp: DateTime.now().toUtc(),
      deviceId: device.deviceId,
      deviceName: device.name,
      message: timedOut
          ? '${device.name} did not respond before the connection timed out.'
          : '${device.name} failed to connect.',
      suggestion: 'Check that the device is available and try again.',
    );
  }
}

/// One entry in the API device list. `available` (is the device currently
/// present) is a SEPARATE axis from `state` (a live device can be
/// discovered-but-disconnected while still available), so it gets its own field.
/// The two factories make the illegal pairings unrepresentable: a remembered
/// entry is always unavailable + `disconnected`; a live entry carries its real
/// state. Both REST and WebSocket surfaces serialize via [toJson], so the wire
/// shape can't drift between them.
class DeviceListEntry {
  final String id;
  final String name;
  final DeviceType type;
  final ConnectionState state;
  final bool available;

  const DeviceListEntry._({
    required this.id,
    required this.name,
    required this.type,
    required this.state,
    required this.available,
  });

  /// A currently-present device, with its real connection state.
  DeviceListEntry.live(Device device, ConnectionState state)
    : this._(
        id: device.deviceId,
        name: device.name,
        type: device.type,
        state: state,
        available: true,
      );

  /// A remembered device that isn't currently present.
  DeviceListEntry.remembered(RememberedDevice r)
    : this._(
        id: r.id,
        name: r.name,
        type: r.type,
        state: ConnectionState.disconnected,
        available: false,
      );

  Map<String, dynamic> toJson() => {
    'name': name,
    'id': id,
    'state': state.name,
    'type': type.name,
    'available': available,
  };
}

/// Builds the API device list: currently-present devices (`available: true`)
/// merged with remembered devices that aren't present (`available: false`,
/// reported as `disconnected`). A remembered device that IS present is listed
/// once, as available. Shared by the REST `_deviceList` and the WebSocket
/// `_buildSnapshot` so both surfaces agree.
Future<List<Map<String, dynamic>>> buildAvailabilityDeviceList(
  List<Device> liveDevices,
  List<RememberedDevice> remembered, {
  String? preferredScaleId,
}) async {
  final entries = <DeviceListEntry>[];
  final liveIds = <String>{};
  for (final device in liveDevices) {
    final state = await device.connectionState.first;
    liveIds.add(device.deviceId);
    entries.add(DeviceListEntry.live(device, state));
  }
  for (final r in remembered) {
    if (liveIds.contains(r.id)) continue;
    entries.add(DeviceListEntry.remembered(r));
  }
  // Stable order: the preferred scale first, then a deterministic order that
  // does NOT depend on connection state — so entries don't shift around as
  // devices connect/disconnect (the underlying live list reorders on every
  // scan/state change). Key by (type, id); both are stable per device.
  entries.sort((a, b) {
    final aPref = preferredScaleId != null && a.id == preferredScaleId;
    final bPref = preferredScaleId != null && b.id == preferredScaleId;
    if (aPref != bPref) return aPref ? -1 : 1;
    final byType = a.type.name.compareTo(b.type.name);
    if (byType != 0) return byType;
    return a.id.compareTo(b.id);
  });
  return entries.map((e) => e.toJson()).toList();
}
